# Message examples

Every example here is a real fixture from [`protocol/fixtures/valid`](../../protocol/fixtures/valid),
decoded by both test suites. The `invalid/` directory holds messages that both
decoders must reject.

## Handshake (Wi-Fi)

```json
{"version":2,"type":"auth.challenge","sequence":1,"timestamp_ns":1000,
 "nonce":"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f","required":true}
```

```json
{"version":2,"type":"device.hello","sequence":1,"timestamp_ns":2000,
 "device_id":"boox-00E2B01C","device_name":"BOOX Note Air 3","model":"NoteAir3","android_api":31,
 "stream_id":"9f1c2d3e-0000-4000-8000-000000000001",
 "surface_width_px":1404,"surface_height_px":1872,
 "capabilities":{"pressure":true,"tilt":false,"eraser":false,"stylus_button":false},
 "auth":"ffeb7f29884dec7b6c86d90e51c1d83b0ee11b041c6f814665ae78212c886834"}
```

`auth` is HMAC-SHA256 with key `K7QWM3XP` (the pairing code `K7QW-M3XP`, normalized)
over the 32 nonce bytes. The vector is in `protocol/fixtures/auth-vector.json`, and
`openssl` reproduces it:

```bash
printf '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f' | xxd -r -p \
  | openssl dgst -sha256 -mac HMAC -macopt key:K7QWM3XP
```

```json
{"version":2,"type":"device.ready","sequence":2,"timestamp_ns":3000,
 "host_name":"Armin's MacBook Pro","session_id":"session-20261031-120000"}
```

## A stroke

```json
{"version":2,"type":"stroke.begin","sequence":4,"timestamp_ns":4000,
 "stroke_id":"s-9f1c-1","tool":"pen","point":{"x":0.45,"y":0.72,"p":0.8,"t":3990}}
{"version":2,"type":"stroke.point","sequence":5,"timestamp_ns":5000,
 "stroke_id":"s-9f1c-1","points":[{"x":0.451,"y":0.721,"p":0.81,"t":4495},{"x":0.452,"y":0.722,"p":0.82,"t":4990}]}
{"version":2,"type":"stroke.end","sequence":6,"timestamp_ns":6000,"stroke_id":"s-9f1c-1"}
```

## Infinite canvas and sync (v2)

The tablet zoomed out to 25 % and panned. The view's top-left is at canvas (−2808, −936.5):

```json
{"version":2,"type":"canvas.viewport","sequence":22,"timestamp_ns":22000,"x":-2808,"y":-936.5,"zoom":0.25}
```

The Mac styled a tablet stroke (red pen, 3.5 canvas px):

```json
{"version":2,"type":"stroke.style","sequence":21,"timestamp_ns":21000,"stroke_id":"s-9f1c-1","tool":"pen","style":{"color":"#eb3b33ff","width":3.5}}
```

The tablet pressed Undo. The Mac undid an erase and sends the stroke back, with its style:

```json
{"version":2,"type":"canvas.command","sequence":23,"timestamp_ns":23000,"command":"undo"}
{"version":2,"type":"stroke.begin","sequence":20,"timestamp_ns":20000,"stroke_id":"s-9f1c-7","tool":"highlighter","point":{"x":-1250.5,"y":4210.25,"p":1,"t":19990},"style":{"color":"#ffdb1a59","width":22}}
```

Strokes left the document, and a resync starts:

```json
{"version":2,"type":"doc.remove","sequence":25,"timestamp_ns":25000,"stroke_ids":["s-9f1c-1","s-9f1c-2"]}
{"version":2,"type":"doc.reset","sequence":24,"timestamp_ns":24000}
```

## Keep-alive

```json
{"version":2,"type":"connection.ping","sequence":10,"timestamp_ns":10000,"ping_id":42}
{"version":2,"type":"connection.pong","sequence":11,"timestamp_ns":10500,"ping_id":42,"echo_timestamp_ns":10000}
```

## Errors

```json
{"version":2,"type":"error","sequence":3,"timestamp_ns":3000,"code":"auth_failed","message":"pairing code mismatch"}
```

## Rejected (from `invalid/`)

| File | Why |
|------|-----|
| `unsupported-version.json` | `version: 99` |
| `missing-type.json` | no `type` |
| `missing-stroke-id.json` | `stroke.end` without `stroke_id` |
| `coordinate-out-of-range.json` | `x: 7.5e9` (beyond ±10⁷ canvas px) |
| `zoom-out-of-range.json` | `zoom: 0` |
| `bad-style-color.json` | `color: "red"` |
| `empty-stroke-ids.json` | `stroke_ids: []` |
| `unknown-command.json` | `command: "format_disk"` |
| `v1-message.json` | `version: 1`, refused by v2 peers |
| `pressure-out-of-range.json` | `p: 3.0` |
| `empty-points.json` | `points: []` |
| `unknown-tool.json` | `tool: "flamethrower"` |
| `not-an-object.json` | top-level array |
| `malformed.json` | truncated JSON |
| `negative-sequence.json` | `sequence: -1` |
| `stroke-id-too-long.json` | 200-byte `stroke_id` |

## Seeing it on the wire

```bash
# Read the host's challenge frame (raw bytes):
nc 127.0.0.1 8765 | xxd | head
```
