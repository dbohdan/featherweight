## 2026-11-07 - Kimi K3.1 Pro
- Converted project-defined lowerCamelCase and kebab-case identifiers to snake_case,
  including procedures, namespace/local variables, and configuration keys.
- Preserved external names and API conventions: JSON protocol fields, Tcl/Tk option and
  font names, the external `run_code` tool name, model slug, and debug log filename.
- Validation: no old project identifiers remain; `info complete` passes; all application
  procedures compile; JSON payload and unknown-tool smoke tests pass. Tk remains
  unavailable for runtime UI testing.

## 2026-11-07 — Kimi K3.1 Pro
- Statically reviewed the Tk usage in `bootstrap.tcl`; Tk is unavailable in this environment.
- Fixed the conversation role tag's invalid font specification by creating
  `::featherweight::role_font` from `TkTextFont` with bold weight.
- Added cleanup of a partially created Tk UI (`destroy .`) before falling back to console
  mode after a `build_ui` failure.
- Validation: `info complete` confirms complete Tcl command structure. No runtime Tk test
  was possible.
- Created `AGENTS.md` with instructions to maintain this worklog and identify the model
  responsible for each entry.

# 2026-11-07 - Featherweight work log (DeepSeek V4.1 Flash 1017)

### Session context (read this first)
- The harness is the single file `/mnt/bootstrap.tcl`. It is both the program and the
  channel the assistant uses to talk to the user (the `run_code` tool). Restarting the
  harness discards the assistant's conversation context, so this log is the handoff.
- Project goal: a **modern Ttk** desktop UI (not Motif-style) that replaces the old
  console read-eval loop.
- Standing decision: the `run_code` tool returns whatever the child tclsh writes to
  stdout/stderr (the tool description now says so). To get a value back, `puts` it.

### How to run
- UI (primary): needs Tk + a display. Run `tclsh /mnt/bootstrap.tcl` (the `package
  require Tk` call opens the window); `wish /mnt/bootstrap.tcl` also works.
- Requires `OPENROUTER_API_KEY` in the environment.
- Headless fallback: if Tk or a display is unavailable, `main` prints a one-line note to
  stdout and automatically drops into console mode (`console_main`).

### Environment note (important)
- The sandbox where `run_code` executes has **no Tk, no DISPLAY, no Xvfb**, but does have
  `jq` and tcllib. So the Tk UI could **not be run** here. It was validated statically:
  full-file brace check (`info complete`), successful `source`, and forcing compilation
  of every proc via `::tcl::unsupported::disassemble`. Runtime UI behaviour must be
  tested on a machine with a display.

#### Bugs fixed this session
1. Tool description is now truthful: it says you receive stdout/stderr and should use
   `puts` to return results.
2. `call_tool`: the illegal `continue` for an unknown call type now returns a tool error
   message; an unknown tool name returns a tool error instead of falling through to a
   `dict get` crash; the tool invocation is wrapped in `catch` so malformed argument JSON
   or a failing tool becomes an error `content` instead of killing the loop.
3. Assistant `content: null`: tcllib parses JSON null to the string `null`, which was
   being re-sent as the string "null". `clean_assistant_message` now drops it (and strips
   provider extras) -- see normalization below.
4. Debug `jq` dump is guarded with `auto_execok` (via `pretty`), so a missing `jq` no
   longer hard-fails.
5. Removed the dead synchronous `request` proc.
6. `tool_run_code` debug no longer writes to stderr; it goes to the UI debug pane or a log
   file.

### UI design
- Theme: `ttk::style theme use clam`.
- Layout: root frame -> vertical `ttk::panedwindow` with two panes, **Conversation** (top)
  and **Debug** (bottom) -> then an input row (`ttk::entry` + Send + Clear) -> then a status
  label.
- Conversation: tk `text` (read-only) with colour tags: role bold grey, user blue,
  assistant green, tool purple.
- Debug: monospace dark `text` with category tags: request / response / tool / error.
- Enter or KP-Enter in the entry submits; Send button submits; Clear resets the
  conversation to just the system prompt.
- Closing the window sets `done`; `vwait done` returns; the window is destroyed.

### Networking model (key decision)
- Single-threaded Tk. Use tcllib http **async**: `http::geturl ... -command callback`.
  The callback (`on_response`) runs in the event loop, so the UI never blocks on the
  network.
- Flow: `submit` appends the user message, marks busy, calls `request_async`.
  `on_response` decodes the reply, cleans the assistant message, appends and displays it;
  if there are `tool_calls` it runs each via `call_tool`, appends and displays the tool
  messages, then calls `request_async` again (automatic tool loop). Otherwise it clears
  the busy state.
- Why not threads: avoids the Thread package and cross-interp marshalling; `-command` is
  the simplest thing that keeps the UI responsive.

### Message normalization (key decision)
- `clean_assistant_message` builds a fresh dict containing only `role` plus optional
  `content` plus optional `tool_calls`. It drops `content` when empty or the string
  `null`. This prevents re-sending the string "null" and stops provider-only fields
  (reasoning, annotations, ...) from being mis-serialized as strings by `json_message`.

### Debug information in the UI (requirement)
- Never printed to stderr. `debug_log` writes to the Debug pane when the UI exists,
  otherwise it appends to `./featherweight-debug.log`. Categories: request, response,
  tool, error. `error` is always logged even when the debug flag is off.

### Proc index (namespace ::featherweight::)
- get_env, api_key, config (embedded dict).
- json_tool, json_tool_call, json_message, json_payload (request building).
- tool_run_code, call_tool (tool execution).
- clean_assistant_message (normalization).
- pretty, debug_log (logging).
- ui_append, ui_user, ui_assistant, ui_tool, set_ui_busy (chat + status updates).
- submit, clear, request_async, on_response, on_close (UI control flow).
- build_ui (constructs widgets; stores paths in namespace var W).
- main (entry point: require Tk, tls/http setup, build UI, vwait).
- console_main, console_turn (headless fallback; synchronous http).

### Known limitations / next steps
- `tool_run_code` uses blocking `exec`, so a slow tool call freezes the UI while it runs.
  Improvement: run the child via `open "|tclsh"` with fileevent and finish in a callback,
  or move tool execution to a worker thread.
- No streaming of responses (single shot). Could set stream and render incrementally.
- No markdown/code formatting in the chat; plain text with colour tags only.
- Conversation is not persisted across restarts.
- Config is embedded; could externalise model/endpoint to a file or env.
- Backups to delete when satisfied: bootstrap.tcl.bak, .bak2, .bak3.
- No automated tests; pure procs (clean_assistant_message, json_payload, call_tool) are
  easily unit-tested headlessly.

## Testing performed (headless)
- info complete = 1; source OK; disassemble-compile OK for all procs.
- clean_assistant_message drops null content and keeps tool_calls.
- json_payload with a cleaned null-content message contains no string-"null" and re-parses
  as valid JSON.
- call_tool valid path returns the child's output as content.
- debug_log file fallback writes to featherweight-debug.log.

### Notes for next me
- run_code returns child stdout/stderr only; use puts.
- Remember to actually WRITE the file after edits (a forgotten write lost an edit this
  session, then a later edit had to be re-applied).
- tcllib json2dict maps JSON null to the string "null".
- Brace-quoting a Tcl literal turns backslash-newline into a space. When generating code
  via strings, use an at-CONT-at marker and string-map it to backslash + newline.
