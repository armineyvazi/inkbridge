# Local coding agent integrations (proposed)

> Feasibility from official docs, 2026-11-03. **Not implemented.**

Cloud chat adapters and local agents share Context Builder output but differ in
auth, process lifecycle, and side effects (file edits).

## Claude Code CLI

**Docs:** https://code.claude.com/docs/en/headless · CLI reference  

| Capability | Support |
|------------|---------|
| Non-interactive run | `claude -p` / `--print` |
| Output | `--output-format text\|json\|stream-json` |
| Structured output | `--json-schema` (per docs) |
| Tool permissions | `--allowedTools`, permission modes |
| Faster/isolation | `--bare` (skips hooks/MCP/CLAUDE.md; may need API key) |
| Auth | Prefer existing CLI login; bare/CI may use `ANTHROPIC_API_KEY` |

**InkBridge adapter sketch:** discover `claude` on `PATH`; validate with a
version/status probe; write Context Package into a temp directory; spawn
`claude -p …` with cwd set; stream stdout; kill process tree on cancel;
default to restrictive tools (read-only) unless user opts into write mode.

**Clear distinctions:**

- Interactive CLI (user in terminal) — out of band; InkBridge may deep-link.
- Non-interactive `-p` — primary automation path.
- Capabilities needing human approval — surface as “open in Claude Code”.

## Cursor

Two documented automation surfaces (do not assume undocumented IDE IPC):

### A. Cursor Agent CLI (headless)

**Docs:** https://cursor.com/docs/cli/headless  

- `agent -p` / `--print` for non-interactive runs  
- `--force` / `--yolo` applies file changes (opt-in only)  
- `--output-format text|json|stream-json`  
- Auth: `agent login` or `CURSOR_API_KEY`  
- Images/context: pass **file paths** in the prompt; agent reads via tools  

### B. Cursor TypeScript / Python SDK

**Docs:** https://cursor.com/docs/sdk/typescript · `/docs/sdk/python`  

- `Agent.create({ apiKey, model, local: { cwd } })` then `send` + stream  
- Requires a Node or Python host — native Swift would need a helper process  
- Cloud Agents API exists for hosted VMs (plan-gated); not required for v1  

**Recommended Phase 7 path:** start with **CLI subprocess** (mirrors Claude
adapter, no Node dependency inside the Mac app). Consider SDK bridge later.

## Supported vs future workflows

| Workflow | Claude | Cursor |
|----------|--------|--------|
| Summarize notes from context dir | Supported via `-p` | Supported via `agent -p` |
| Explain handwriting package | Supported if files on disk | Supported if files on disk |
| Edit a coding repo | Opt-in tools / `--force` | Opt-in `--force` |
| Open IDE UI to a workspace | Partial (CLI/UX) | `cwd` / workspace flags — verify at impl |
| Assume Cursor hosts PDFs natively | **No** | **No** — hand off files |

## Safety

- No shell interpolation of user questions into unquoted scripts.
- Temp dirs with restrictive permissions; delete after run (unless user keeps).
- Never pass Keychain cloud keys into agent env unless that agent needs them.
- Cancel = SIGTERM then SIGKILL with timeout.
