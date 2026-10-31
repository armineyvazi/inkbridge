# InkBridge Protocol v1

Status: **implemented** in `apps/macos/Sources/InkBridgeCore/Protocol` (Swift) and
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
| `version`      | integer    | Must equal `1`, otherwise the message is rejected (`unsupported protocol version`). |
| `type`         | string     | See §3. Unknown types are a **recoverable** error: the receiver ignores them, which leaves room for additive changes. |
| `sequence`     | integer ≥ 0 | Per-sender counter, strictly increasing. On the device it is scoped to `stream_id` (one per app process) and continues across reconnects. |
| `timestamp_ns` | integer    | Send time on the sender's **monotonic** clock (Android `System.nanoTime()`, Mac `DispatchTime.uptimeNanoseconds`). Never wall-clock time. |

Keys are snake_case. Booleans must be JSON booleans (`1` is rejected). Strings are
non-empty and at most 128 UTF-8 bytes, except `error.message` (512).

## 3. Messages

Direction: **D→H** means device to host, **H→D** host to device.

| Type | Dir | Fields | Purpose |
|------|-----|--------|---------|
| `auth.challenge` | H→D | `nonce` (hex, 32 bytes), `required` (bool) | The first message on every connection. `required` is `false` on the loopback (USB) listener and `true` on the LAN listener. |
| `device.hello` | D→H | `device_id`, `device_name`, `model`, `android_api`, `stream_id`, `surface_width_px`, `surface_height_px`, `capabilities{pressure,tilt,eraser,stylus_button}`, optional `auth` (hex) | Identifies the device. `auth = HMAC-SHA256(key = normalize(pairing code), msg = nonce bytes)`. |
| `device.ready` | H→D | `host_name`, `session_id` | Handshake accepted; strokes may flow. |
| `device.disconnect` | both | `reason` | Orderly close. |
| `device.surface` | D→H | `surface_width_px`, `surface_height_px` | The drawing surface changed size, e.g. on rotation. |
| `stroke.begin` | D→H | `stroke_id`, `tool` (`pen`\|`eraser`), `point` | Pen down. |
| `stroke.point` | D→H | `stroke_id`, `points` (1 … 256) | Samples since the last message, oldest first. |
| `stroke.end` | D→H | `stroke_id` | Pen up: commit the stroke. |
| `stroke.cancel` | D→H | `stroke_id` | The system cancelled the gesture: discard the stroke and roll back an eraser gesture. |
| `session.start` / `.pause` / `.resume` / `.save` | either | optional `session_id` | Defined and validated; **not yet acted on** by the Mac app (Phase 4). |
| `connection.ping` | both | `ping_id` (integer ≥ 0) | Keep-alive and RTT probe. |
| `connection.pong` | both | `ping_id`, `echo_timestamp_ns` | Reply. The replier's own `timestamp_ns` lets the pinger estimate the clock offset (§6). |
| `error` | both | `code`, `message` | See §7. |

### Point

```json
{"x": 0.45, "y": 0.72, "p": 0.8, "t": 123456789}
```

- `x`, `y`: normalized to the device drawing surface, origin top-left. Senders clamp
  them to 0 … 1. Receivers accept −0.1 … 1.1 (digitizer edge overshoot) and the drawing
  engine clamps. NaN or infinite values are rejected.
- `p`: pressure 0 … 1. Devices without pressure send a constant. The host ignores
  pressure when `capabilities.pressure` is false.
- `t`: sample time in ns, on the same monotonic clock as `timestamp_ns`. On Android it
  comes from `MotionEvent.getEventTimeNanos()` (API 34+) or `getEventTime() × 10⁶`.

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
3. The host replies `device.ready`, or `error{auth_failed}` and closes.
4. Anything other than `device.hello` before `ready` gets
   `error{handshake_required}` and a close. With no hello within 5 s the host sends
   `error{handshake_timeout}` and closes.

The host speaks first so that the device knows, before it sends anything, whether
it must authenticate.

## 5. Ordering and duplicates

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

## 6. Keep-alive, RTT and clock offset

- Each side pings every 2 s (the probe uses 0.5 s) and answers pings immediately.
- If a side receives no bytes for 7 s, it treats the peer as gone and closes.
- RTT = pong receive time − ping send time.
- Clock offset (NTP-style): for a host ping sent at t0, answered at device time td,
  received back at t3, `offset ≈ td − (t0 + t3)/2`. The host keeps the sample with the
  smallest RTT out of the last 16.
- Pen-to-host latency of a sample = `hostReceive − (point.t − offset)`.

## 7. Errors

| `code` | Sent by | Effect |
|--------|---------|--------|
| `auth_failed` | host | Close. The device stops retrying (`ClientState.Failed`). Five failures within 60 s lock out the LAN listener (connections refused) until the window passes. |
| `handshake_required`, `handshake_timeout` | host | Close. |
| `bad_frame` | host | Close (framing lost). |
| `invalid_message` | host | The message is dropped and the connection continues. More than 50 invalid messages per connection ⇒ `too_many_errors` and close. |

## 8. Limits

| Limit | Value |
|-------|-------|
| Frame payload | 64 KiB |
| Points per `stroke.point` | 256 (the device splits larger batches) |
| String fields | 128 bytes (`error.message` 512) |
| Surface dimension | 1 … 32 768 px |
| Concurrent peers per host | 4 |
| Device outbound queue | 4 096 messages, kept across reconnects; overflow is counted, not blocked |

## 9. Versioning

Additive changes (new optional fields, new message types) keep `version: 1`. Receivers
ignore unknown fields and unknown types. Anything that changes the meaning of an
existing field bumps `version`. v1 peers reject v2 with an error, so a mismatch is
visible instead of silently misdrawn.

## 10. Future: binary encoding

JSON is used for debuggability. Measured cost is 8.5 µs to decode one `stroke.point`
on the Mac (debug build) and 1.9–2.5 µs to process, encode and frame one on the JVM.
At ~200 samples/s that is far below 1 % of a core, so Protobuf/CBOR is not justified
yet. If it ever is, the framing stays and a `content-type` in the hello selects the
encoding.
