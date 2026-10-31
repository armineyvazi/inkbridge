# InkBridge Protocol v2

Status: **v2, implemented** (2026-10-31; v1 superseded by [ADR-006](../decisions/ADR-006-infinite-canvas-and-sync.md)) in `apps/macos/Sources/InkBridgeCore/Protocol` (Swift) and
`apps/android/core/src/main/kotlin/app/inkbridge/core/protocol` (Kotlin). Both are
tested against the same fixtures in [`protocol/fixtures`](../../protocol/fixtures).

The protocol is transport-independent. USB (`adb reverse`), Wi-Fi (LAN TCP), and the
planned native USB (AOA) transport all carry exactly the same bytes.

## 1. Framing

```
+--------------------+-------------------------------+
| length: u32, BE    | payload: `length` bytes UTF-8 |
+--------------------+-------------------------------+
```

- `length` is 1 … 65 536 (64 KiB). A receiver rejects a header outside that range
  **before** buffering the payload, then sends `error {code: bad_frame}` and closes:
  after a bad header the stream cannot be resynchronised.
- One frame holds exactly one JSON object.
- TCP reads may contain partial frames or several frames. Both decoders
  (`FrameDecoder`) are tested byte-by-byte and with coalesced input.

**Why a length prefix rather than newline-delimited JSON?** The reader knows where a
message ends without scanning, and it can refuse an oversized message from the header
alone. A newline-delimited reader would have to buffer until it found a newline, and
the 64 KiB limit would be harder to enforce.

## 2. Envelope

Every message has these fields:

| Field          | Type       | Rules |
|----------------|------------|-------|
| `version`      | integer    | Must equal `3`, otherwise the message is rejected (`unsupported protocol version`). v1, v2 and v3 peers refuse each other. |
| `type`         | string     | See §3. Unknown types are a **recoverable** error: the receiver ignores them, which leaves room for additive changes. |
| `sequence`     | integer ≥ 0 | Per-sender counter, strictly increasing. On the device it is scoped to `stream_id` (one per app process) and continues across reconnects. |
| `timestamp_ns` | integer    | Send time on the sender's **monotonic** clock (Android `System.nanoTime()`, Mac `DispatchTime.uptimeNanoseconds`). Never wall-clock time. |

Keys are snake_case. Booleans must be JSON booleans (`1` is rejected). Strings are
non-empty and at most 128 UTF-8 bytes, except `error.message` (512).

## 3. Messages

Direction: **D→H** means device to host, **H→D** host to device.

| Type | Dir | Fields | Purpose |
|------|-----|--------|---------|
| `auth.challenge` | H→D | `nonce` (hex, 32 bytes), `required` (bool), `host_id` (string) | The first message on every connection. `required` is `false` on the loopback (USB) listener and `true` on the LAN (TLS) listener. `host_id` is the Mac's stable identity; a device never sends a token proof to a different `host_id`. |
| `device.hello` | D→H | `device_id`, `device_name`, `model`, `android_api`, `stream_id`, `surface_width_px`, `surface_height_px`, `capabilities{pressure,tilt,eraser,stylus_button}`, optional `auth_mode` (`pair`\|`token`) and `auth` (hex) | Identifies the device. `auth = HMAC-SHA256(key, label ‖ 0x00 ‖ nonce ‖ fingerprint)`, where key/label are the normalized code / `inkbridge-v3-pair`, or the token bytes / `inkbridge-v3-token`, and fingerprint is SHA-256 of the TLS certificate the device saw (empty over USB). |
| `pair.granted` | H→D | `host_id`, `host_name`, `token` (hex, 32 bytes), `proof` (hex) | After a correct `pair` proof, before `device.ready`. `proof` uses label `inkbridge-v3-host`; the device checks it before storing `token` and the certificate pin. |
| `device.ready` | H→D | `host_name`, `session_id` | Handshake accepted; strokes may flow. |
| `device.disconnect` | both | `reason` | Orderly close. |
| `device.surface` | D→H | `surface_width_px`, `surface_height_px` | The drawing surface changed size, e.g. on rotation. |
| `stroke.begin` | both | `stroke_id`, `tool`, `point`; H→D also `style` | Pen down (D→H), or the start of a stroke the device lacks (H→D: undo of an erase, redo, resync). |
| `stroke.point` | both | `stroke_id`, `points` (1 … 256) | Samples, oldest first. |
| `stroke.end` | both | `stroke_id` | Stroke complete. |
| `stroke.style` | H→D | `stroke_id`, `tool`, `style` | How the host resolved a device stroke (toolbar tool, colour, width). Sent once at `stroke.begin`. |
| `canvas.viewport` | both | `x`, `y`, `zoom` (0.02 … 50) | The view moved. The device sends it after the handshake, on gesture end (throttled to ≥ 100 ms while dragging), and on zoom/Fit/Home; the host sends it for Mac-side Fit all and Home. |
| `canvas.command` | D→H | `command`: `undo` \| `redo` \| `clear` | Tablet buttons. The host applies the command to its document; the result comes back as doc messages. |
| `doc.reset` | H→D | — | Drop every confirmed stroke; a full resync follows. Sent once per connection. |
| `doc.remove` | H→D | `stroke_ids` (1 … 256) | These strokes left the document (erase, undo, clear, or a device eraser/laser stroke the host did not keep). |
| `stroke.cancel` | D→H | `stroke_id` | The system cancelled the gesture: discard the stroke and roll back an eraser gesture. |
| `session.start` / `.pause` / `.resume` / `.save` | either | optional `session_id` | Defined and validated; **not yet acted on** by the Mac app (Phase 4). |
| `connection.ping` | both | `ping_id` (integer ≥ 0) | Keep-alive and RTT probe. |
| `connection.pong` | both | `ping_id`, `echo_timestamp_ns` | Reply. The replier's own `timestamp_ns` lets the pinger estimate the clock offset (§6). |
| `error` | both | `code`, `message` | See §7. |

### Point

```json
{"x": 702.5, "y": -1840.25, "p": 0.8, "t": 123456789}
```

- `x`, `y`: **canvas px** on the infinite canvas (ADR-006). 1 unit is 1 tablet pixel
  at zoom 1, the origin is the top-left of the home view, and y points down. Values are
  unbounded in principle; receivers reject anything outside ±10⁷ and anything NaN
  or infinite. The device converts view px with `canvas = viewport.origin + px / zoom`
  and rounds to 0.01. **No viewport state is ever baked into stroke data.**
- `p`: pressure 0 … 1. Devices without pressure send a constant. The host ignores
  pressure when `capabilities.pressure` is false.
- `t`: sample time in ns, on the same monotonic clock as `timestamp_ns`. On Android it
  comes from `MotionEvent.getEventTimeNanos()` (API 34+) or `getEventTime() × 10⁶`.

### Style

```json
{"color": "#eb3b33ff", "width": 5.6}
```

`color` is `#rrggbbaa` (sRGB, straight alpha). `width` is the nominal width at full
pressure, in **canvas px** (0.01 … 10 000), so ink scales with zoom.

### Deviation from the original brief

The brief's example puts one `x/y` on `stroke.point`. v1 carries a **`points` array**
instead. Android delivers several digitizer samples per `MotionEvent` (the historical
samples). Sending them in one frame keeps per-sample overhead low and preserves the
digitizer's sampling. Sending one frame per sample would multiply frame and JSON
overhead with no latency benefit, since the samples become available together anyway.

### Tool semantics

The device reports its **physical** tool: `pen`, or `eraser` when Android reports
`TOOL_TYPE_ERASER` or the primary stylus button is held. The host maps `pen` to the
tool selected on its toolbar (pen, highlighter or laser). A device `eraser` always
erases. `highlighter` and `laser` are valid on the wire for future device-side tool
selection.

## 4. Handshake

See [`diagrams/connection-flow.mmd`](../diagrams/connection-flow.mmd).

1. The device connects. The host immediately sends `auth.challenge`.
2. The device sends `device.hello`, adding `auth` if `required`.
3. For a `pair` proof the host sends `pair.granted`. Then `device.ready{host_name, session_id, host_id, resume_sequence}`, or an `error` and closes.
4. `resume_sequence` is the highest sequence the host already holds for this `stream_id`. The device re-sends (with new sequence numbers) any document message it wrote after that on a link that died, but only when `host_id` and `session_id` match the previous connection.
4. Anything other than `device.hello` before `ready` gets
   `error{handshake_required}` and a close. With no hello within 5 s the host sends
   `error{handshake_timeout}` and closes.

The host speaks first so that the device knows, before it sends anything, whether
it must authenticate.

## 5. Document sync (v2)

The host owns the document; the device keeps a mirror for display
(see [`diagrams/document-sync.mmd`](../diagrams/document-sync.mmd)).

1. **On connect:** the device sends `canvas.viewport`. The host sends `doc.reset`,
   then every stroke as `stroke.begin(style)` / `stroke.point` / `stroke.end`.
2. **Device draws:** the device shows the stroke immediately (optimistic) and sends it.
   The host replies `stroke.style`. If the host does not keep the stroke (eraser or
   laser), it later sends `doc.remove` for it.
3. **Any other change** (erase, undo, redo, clear, from either side): the host diffs
   stroke IDs against what the device has, and sends only `doc.remove` for strokes that
   left and full stroke messages for strokes the device lacks. There are no snapshots.
4. **Outage:** strokes the device drew but had not finished sending survive
   `doc.reset`, and reach the host from the device's queue.

## 6. Ordering and duplicates

- TCP preserves order within a connection. The device assigns sequence numbers and
  writes frames under a single lock, so the order of numbers equals the order on the
  wire.
- The host keeps the last sequence number per `stream_id` and drops any message whose
  sequence is ≤ that number. This prevents double rendering if a message is replayed
  across a reconnect, or if two transports ever deliver the same stream.
- A new app process gets a new `stream_id`, so starting again at 1 is valid.
- `stroke.point` for an unknown `stroke_id` is ignored. This happens when the link
  dropped mid-stroke: the host committed what it had, and the remaining points are
  discarded.

## 7. Keep-alive, RTT and clock offset

- Each side pings every 2 s (the probe uses 0.5 s) and answers pings immediately.
- If a side receives no bytes for 7 s, it treats the peer as gone and closes.
- RTT = pong receive time − ping send time.
- Clock offset (NTP-style): for a host ping sent at t0, answered at device time td,
  received back at t3, `offset ≈ td − (t0 + t3)/2`. The host keeps the sample with the
  smallest RTT out of the last 16.
- Pen-to-host latency of a sample = `hostReceive − (point.t − offset)`.

## 8. Errors

| `code` | Sent by | Effect |
|--------|---------|--------|
| `auth_required` / `not_paired` | host | Close. The device drops its pairing and asks the user to pair again. |
| `pairing_closed` | host | Close. No Connect Device window is open, or its code expired or was voided. |
| `auth_failed` | host | Close. The device stops retrying (`ClientState.Failed`). Five failures within 60 s from one IP lock that IP out of the LAN listener for 30 s, doubling per repeat (max 15 min); Wi-Fi handshake timeouts count as failures. |
| `handshake_required`, `handshake_timeout` | host | Close. |
| `bad_frame` | host | Close (framing lost). |
| `invalid_message` | host | The message is dropped and the connection continues. More than 50 invalid messages per connection ⇒ `too_many_errors` and close. |

## 9. Limits

| Limit | Value |
|-------|-------|
| Frame payload | 64 KiB |
| Points per `stroke.point` | 256 (senders split larger batches) |
| IDs per `doc.remove` | 256 |
| Coordinates | ±10⁷ canvas px |
| Zoom | 0.02 … 50 |
| String fields | 128 bytes (`error.message` 512) |
| Surface dimension | 1 … 32 768 px |
| Concurrent authenticated peers per host | 4 |
| Pending handshakes per transport | 4 |
| Device outbound queue | 4 096 messages, kept across reconnects; overflow is counted, not blocked |

## 10. Versioning

Additive changes (new optional fields, new message types) keep the version. Receivers
ignore unknown fields and unknown types. Anything that changes the meaning of an
existing field bumps `version`. That is why v2 exists (point coordinates changed
meaning, from normalized to canvas px) and v3 (proofs are bound to the TLS certificate,
and `device.ready` gained `resume_sequence`). Peers refuse a mismatched version with an
error, so it is visible instead of silently misdrawn.

## 11. Future: binary encoding

JSON is used for debuggability. Measured cost is 8.5 µs to decode one `stroke.point`
on the Mac (debug build) and 1.9–2.5 µs to process, encode and frame one on the JVM.
At ~200 samples/s that is far below 1 % of a core, so Protobuf/CBOR is not justified
yet. If it ever is, the framing stays and a `content-type` in the hello selects the
encoding.
