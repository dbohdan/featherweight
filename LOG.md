## 2026-11-09 — MiMo-V2.6-Flash
- Split conversations out of `featherweight.conf` (1.05 MB, nearly all of it the `sessions` dict, rewritten after every message). The configuration now lives in `featherweight/config` as a flat dict with no `sessions` key, and each conversation lives in `featherweight/sessions/<name>`: one file per session, a Tcl list of message dicts with one `list`-quoted message per line, exactly the shape each session had inside the old file.
- Sessions load lazily into a new `sessions` namespace variable (name -> messages) on first use, so startup reads only the current session and `/session` lists the directory rather than an in-memory dict. New procedures: `state_dir`, `sessions_dir`, `session_path`, `session_exists`, `session_names`, `read_session`, `load_session`, `save_session`.
- `save_config` now writes only the configuration and `save_session` only the session that changed, both through the existing atomic `write_text_file` (temporary file, permission copy, rename). Appending a message no longer rewrites every conversation; a 60-message conversation leaves the config at a few hundred bytes.
- A session name doubles as its file name, so `session_path` refuses empty names, `.`, `..`, and names containing `/` or `\`; `/session` with a bad name reports the error instead of writing outside the directory. A session file that is not a Tcl list of message dicts raises an error rather than reading as empty, so a broken file is never overwritten by the next save. A missing or empty current session is still seeded with the system message at startup.
- No migration, by decision: the old `featherweight.conf` is left untouched and is not read or rewritten, so the history it holds is not carried over. It remains in `.gitignore`, which now also covers `/featherweight/`.
- Validation in a separate `tclsh` process, 42 checks: fresh start creates the layout and the system message; append leaves the config file byte-identical; newlines, braces, quotes, backslashes, Unicode, and tool calls round trip through the file; an existing session file is not read until it is switched to; switching creates, seeds, and persists; `session_names` is sorted and skips directories; six invalid names plus `/session a/b` are refused with no stray file; non-list and non-message files error and stay untouched; every config key round trips; startup with a bad `current_session` or an empty session file; a legacy `featherweight.conf` is ignored and byte-identical afterwards; compaction persists to the session file; all procedures compile. A separate Tk test passed replay from the file, new-session and return switches, and window-title updates. `git diff --check` is clean. No live API request was made.

## 2026-11-09 — Kimi K3.1 Pro
- Added `context_size` (default 1,048,576 tokens), persisted `/context-size ?tokens|off?`, and approximate usage reporting. Estimates use Unicode characters divided by four and include serialized tool calls and schemas; `off` disables automatic folding.
- Added deterministic rolling compaction before GUI and console requests. When history exceeds `context_size/2` (minimum 2,048 tokens), old whole turns are dropped toward half that budget, with the latest turn kept whole as a fallback. Cuts occur only at genuine user-turn boundaries, preserving assistant/tool-result pairing.
- Dropped turns are replaced by a marked user-role note quoting their user messages verbatim; earlier notes are not duplicated. The system prompt is preserved, folds are saved, and oversized remaining requests fail with an actionable error instead of looping.
- Validation passed in separate processes: repeated folds, exact user-text retention, tool pairing, latest-turn and disabled behavior, config migration/validation, slash handling, and oversized requests. Tk tests covered `/context-size`, usage reporting, and refreshed history. Existing file-tool, Unicode/permission, procedure-compilation, and `git diff --check` tests pass. No live API request was made.

## 2026-11-08 — Kimi K3.1 Pro
- Implemented `read_file`, `write_file`, `edit_file`, and `about`, with conventional schemas and immediate tool results. `ask_user_question` was deferred by request.
- `read_file` returns numbered UTF-8 text windows (2,000 lines by default), validates paging arguments, and points to the next offset when truncated.
- Writes create parent directories and use temporary files plus atomic rename; existing Unix permissions are preserved. Edits require exact unique matches unless `replace_all` is enabled, and missing or ambiguous matches leave files unchanged.
- `about` reports process/script timestamps, current UTC/local time, Tcl/Tk and platform details, model, session, and project root. Updated the default system prompt to prefer the file tools.
- Post-restart live verification passed through the newly exposed tools: `about`, create/write, paged read, unique edit, ambiguity rejection, `replace_all`, and final Unicode-preserving read. The regression suite, Unicode/permission checks, procedure compilation, and `git diff --check` also passed; the temporary live-test file was removed.
- Validation in separate Tcl processes passed: all procedures compile; all five tool schemas decode; real tool dispatch works; create/overwrite, paged/empty reads, unique and replace-all edits, error paths, Unicode round trips, and Unix permission preservation pass. `git diff --check` is clean. No live API test was run.

## 2026-11-08 — Kimi K3.1 Pro
- Revised the Tk UI: removed Clear, replaced the single-line input with a four-line Text widget, and kept plain Enter/KP Enter as newline insertion while adding Ctrl+Enter and Ctrl+KP Enter to submit.
- The Send button now becomes Stop while a request/tool chain is active. Stop marks the chain inactive, unregisters request callbacks, terminates active curl processes (`kill` on Unix, `taskkill` on Windows), closes their channels, and restores Send/Ready. Closing the window also stops active work. Tool execution itself remains synchronous, so Stop cannot interrupt code already running inside a tool.
- Tool-call code is displayed before its result for new calls and replayed conversations. `run_code` JSON arguments are decoded to show the Tcl source; other or malformed calls fall back to their raw arguments.
- Added shared right-click context menus to Conversation, Debug, and input. Copy and Select All are available everywhere; Cut and Paste are input-only. Copy is enabled only with a selection, and Cut/Paste states reflect selection/clipboard availability.
- Validation: Tcl source check and `git diff --check` pass. Tk tests verified multiline Enter behavior, Ctrl+Enter submission, Send/Stop transitions, clipboard Cut/Copy/Paste and menu states, replayed code-before-result ordering, and termination/cleanup of a hanging curl process. No live API request was made.

## 2026-11-08 — Kimi K3.1 Pro
- Added persistence of the complete configuration, including `messages`, to `config.tcl` in the launch directory.
- Loads and restores saved conversations at startup, replays user/assistant/tool messages in the GUI, saves after every appended message and tool result, and persists Clear.
- Writes through a PID-specific temporary file followed by an atomic rename. Save errors are logged without discarding the in-memory turn.
- Headless tests pass for exact round trips, special characters and multiline content, tool calls, JSON serialization, Clear, replay logic, and compilation of all application procedures. No live Tk UI or API test was run.

## 2026-11-08 - DeepSeek V4.1 Flash 1017
- Changed the GUI curl request to pass its JSON payload through stdin using Tcl's `<<` redirection and `--data-binary @-`, avoiding command-line length limits.
- Validated with a local HTTP echo server using a 1.38 MB payload. Tcl syntax and procedure compilation checks pass. No live OpenRouter or Tk test was run.
## 2026-11-08 - Kimi K3.1 Pro
- Replaced per-call `exec` with a lazily created, persistent Tcl interpreter using `interp create`.
- Variables, procedures, loaded packages, and working-directory changes now persist between calls.
- Preserved stdout/stderr capture and file-channel writes.
- Preserved output produced before evaluation errors.
- Updated the tool description from "stateless" to "stateful".

Tests pass for persistence, errors, `exec`, package loading, and file I/O. `git diff --check` is clean.

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

# Session Log

## Environment-based HTTPS proxy and GUI fixes

- Replaced `autoproxy` in `bootstrap.tcl` with a small proxy detector that reads `http_proxy`, then `HTTP_PROXY`.
- Added parsing for HTTP proxy URLs, including host, optional port, credentials, and trailing slash. The default proxy port is `80`; proxy settings are cleared when no environment variable is set.
- Diagnosed the HTTPS handshake failure: Tcl's `http` package connected to the proxy, but `::tls::socket` attempted TLS directly with the proxy instead of tunneling to the destination.
- Implemented `::featherweight::tls_socket` to establish an HTTP `CONNECT` tunnel, validate its response, and then start TLS with the destination hostname for SNI. Direct HTTPS remains supported without a proxy.
- Verified plain HTTP through `http://192.168.1.101:20171`.
- Verified proxied HTTPS and repeated `POST` requests to the OpenRouter completions endpoint.
- Verified an authenticated proxied request using `OPENROUTER_API_KEY`: HTTP `200`, transport `ok`, assistant response `proxy OK`.
- Fixed the asynchronous GUI response handler to accept Tcl HTTP's successful `ok` status as well as `complete`.
- Updated failure logging to include `::http::error` and capture it before cleaning up the HTTP token.
- Verified an authenticated asynchronous request using the GUI request pattern: HTTP `200`, assistant response `async OK`.

