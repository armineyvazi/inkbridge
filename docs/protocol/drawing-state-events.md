# Drawing state events

These are additive messages within protocol v3: older peers ignore unknown types, so the version did not change.

## `canvas.background` (Phase 1)

```json
{"version":3,"type":"canvas.background","sequence":12,"timestamp_ns":12000,
 "mode":"studio","color":"#000000ff","pattern":"graph","revision":7}
```

| Field | Type | Rule |
|---|---|---|
| `mode` | `"overlay"` \| `"studio"` | Anything else is rejected (`invalid field mode`) |
| `color` | `#rrggbbaa` | sRGB |
| `pattern` | `"none"`, `"grid"`, `"dots"`, `"graph"`, `"engineering"` | |
| `revision` | uint64 | H→D: the Mac's revision; apply only if ≥ the held one. D→H: the last revision the device saw (informational); the Mac assigns the next one |

The fixtures are `protocol/fixtures/valid/canvas.background.json` and `invalid/bad-background-mode.json`, and both test suites decode them.

## Engineering and journal (built)

| Message | Direction | Fields |
|---|---|---|
| `diagram.state` | H→D | `nodes[{id,kind,label,shape,x,y,w,h}]`, `edges[{id,from,to,kind,style,label,dashed,points[]}]`, `revision`. Paths are already routed; labels may be empty or up to 512 bytes |
| `journal.state` | H→D | `active`, `day` (yyyy-MM-dd), `today`, `title`, `entries[{id,kind note/task/ink,text,done,created_ms UTC}]` (last 100), `revision` |
| `journal.request` | D→H | `action` ∈ open, close, today, prev, next, day, add_note, add_task; `name?` (day id or text) |

## Planned (not implemented yet)

| Message | Phase | Purpose |
|---|---|---|
| `tool.state {tool, color, width, opacity, revision}` | 2 | Tool selection synced both ways |
| `object.add / object.update / object.remove` | 2–3 | Shapes, text, and transformations of any object (move, resize, rotate) |
| `layer.state {layers[], revision}` | 4 | Order, names, visibility, lock |
