## 2026-11-12 — MiMo-V2.6-Pro
- Fixed the state directory moving under the model's feet. `state_dir` computed `[file join [pwd] featherweight]` fresh on every call, and Tcl threads share one working directory, so a model's `cd` in `run_code` (or `/eval`) silently relocated everything -- sessions, config, attachments, `recall` -- and the next write would have created a new, empty state elsewhere while the real one sat untouched. Found by asking where the state directory actually comes from; the demonstration showed the paths moving from `/tmp/.../featherweight` to `/tmp/featherweight` after one `cd /tmp`.
- The launch directory is now recorded once, at source time, in `project_root`; `state_dir` reads that instead of `[pwd]`, and moving the state is then explicit only -- set `project_root` or `state_root`, never as a side effect. The same bug class was in `tool_about` ("Project root: [pwd]") and `debug_log`'s fallback log file; both now use `project_root` too. The window title is left alone on purpose: following the working directory is its tested feature.
- Validation: `make` passes — 8 scripts, 227 checks (storage 61, Tk 49, debug 31, compact 22, run_code 20, recall 17, tools 14, session_log 13). New checks in `tests/run_code.tcl` move the working directory from model code and assert the state paths have not moved; a probe confirmed `about` and the debug log land in the right place as well.
- Ctrl-A selects all in the input box, bound beside the existing Ctrl-Return; it calls the same `text_select_all` as the right-click menu, so the two cannot drift. The check generates the key and reads the selection back. `make` passes — 8 scripts, 225 checks.
- The conversation's fold markers use a fixed-width font. `[+]` and `[−]` differ in width in a proportional font — the minus sign is a little wider at some sizes — so the closing bracket moved between opening and closing. The marker's tag now carries TkFixedFont; the debug log was never affected, its whole widget being fixed width. `make` passes — 8 scripts, 224 checks.
- `font_size` sets the baseline font size of the whole window — conversation, debug log, labels, input. The default is 10, which is the size Tk gives its fonts here (TkTextFont, TkDefaultFont and TkFixedFont all measured 10 points, Noto Sans and DejaVu Sans Mono). It is applied by configuring the three named Tk fonts before anything derives from them; `role_font` is made from TkTextFont afterwards, so the bold labels follow. A size below 6 is refused. Validation: `make` passes — 8 scripts, 223 checks (storage 61, Tk 48, debug 31, compact 22, run_code 18, recall 17, tools 13, session_log 13).
- The folded-state marker is `[−]` — U+2212 MINUS SIGN, not a hyphen — beside its `[+]`, in both the debug log's entries and the conversation's reasoning blocks. The tests pin the code point; `make` passes — 8 scripts, 221 checks.
- `-m`/`--model` and `-s`/`--session` start the interface on a chosen model or session, saving the typing of `/model` and `/session` after it opens. They do exactly what those commands do — set the choice and keep it — so the two cannot drift apart: `startup_options` parses the leading options and `startup_configure` applies them through the same state. They compose with script mode too (`featherweight.tcl -m X debug request` shows the request that model would send). Validation: `make` passes — 8 scripts, 221 checks (storage 60, Tk 47, debug 31, compact 22, run_code 18, recall 17, tools 13, session_log 13). The checks for setting the model and session run last in `debug.tcl`, since changing them for good is what they do.
- The demo of those options exposed a long-standing bug in `json_tool`: `dict for` keeps one value per key, so a tool's repeated `-param` options collapsed and the request schema advertised only the *last* parameter of each tool while requiring them all. Models coped because the descriptions name the rest; the fix is `foreach`, and a check now proves every parameter reaches the schema.
- `featherweight.tcl` reorganized and commented for publication. The file now opens with what a harness is and the shape of a turn, then walks through the parts in the order they depend on each other: state and paths, the session record, counting and folding, the wire format, the tools (files, run_code, recall), one turn, the interface, script mode, main. Every block moved whole with its comments; a script did the moving and refused to write unless every procedure was placed. GPT-6.1 Terra (via `consult`) read the file as a skilled programmer new to harnesses, twice: the first pass named 27 uncommented procedures and 10 wrong or stale ones, the second said nothing was wrong or missing but nits, which are fixed too. A third pass copyedited the comments for style -- padding, indirect openers, em-dash chains -- and most of its rewrites were taken, keeping the "why" where its cuts left only the "what". It also caught a misspelt "Signall".
- The comment review earned its keep by catching a real bug: `recall_open` looked for the query's marks in the entry's own text, but `highlight` puts them in the separate marked copy, so the `>`-marking of matched lines never fired. The marks are now read from the marked copy and the display from the text; `tests/recall.tcl` pins it.
- Validation: `make` passes — 8 scripts, 216 checks (storage 60, Tk 47, compact 22, run_code 18, recall 17, debug 26, tools 13, session_log 13). `git diff --check` clean.
- The model's reasoning traces are now kept, shown, and never sent back. Kept: `clean_assistant_message` passes `reasoning` (or `reasoning_content`, as providers name it) into the stored message, so the session record holds it — the record is the log, and it is what recall searches. Shown: a `Thinking [+]` block, folded shut by default, in a quieter grey above the answer, opened by its marker the way the debug log's entries are; the date leads the message and the blocks after it take their labels without repeating it. Never sent: `json_message` leaves `reasoning` out the way it leaves `time` out — kept for the record and the display, neither sent back nor counted against the context budget.
- Recall indexes the reasoning with the rest of the message: it is the model's own prose, which is what a search of the record is most often for. The debug log needed no change: the raw response entry already holds the trace as it arrived.
- Validation: `make` passes — 8 scripts, 215 checks (storage 60, Tk 47, compact 22, run_code 18, recall 16, tools 13, debug 26, session_log 13). New checks cover the folded block and its toggle, reasoning surviving a fresh read from disk while staying out of the JSON, and a search finding what the model reasoned. `tag_value` moved from `tests/tk.tcl` to the shared `tests/lib.tcl` for the new checks. `git diff --check` clean.
- Tentative: a message's date now leads its heading on its own line, the bold label below it, instead of the two sharing a line. On one line the label's length set the date's indent and long headings like `Tool call: edit_file` pushed it far right. This supersedes the three-space gap settled earlier — the two are no longer on one line to need one. It applies to every heading (You, Assistant, Tool call, Result), since `ui_label` is shared; if it should be tool exchanges only, the callers can change. To be judged in use.
- Two legibility changes to what the conversation shows. Tool call arguments are separated by blank lines — where a value runs over several lines, that is the only mark of where the next name begins — and each name is followed by at least two spaces, padded so the values still line up under the longest name. And a `run_code` answer's `<output>`, `<result>` and `<options>` sections are separated by blank lines rather than jammed together.
- The conversation's tool headings read `Tool call: run_code` and `Result`. `Tool code` was left over from when only `run_code` existed; `Result` leads with a different word from `Tool call` so the eye can scan a tool exchange. The change is three strings in `ui_tool_code` and `ui_tool`, with the tests following.
- Tool calls in the conversation name the tool and show its parameters legibly. `ui_tool_code` parsed the arguments JSON only for `run_code`; any other tool printed the raw payload. It now parses the arguments for every tool, prints them one per line in the tool's own `-param` order (not the JSON's, which models may write in any order), the names padded so the values line up, and a value that runs over one line -- code, a path list -- goes on its own line beneath its name, not indented. The heading reads `Tool call: read_file` and the result `Tool result`; `run_code` keeps its `Tool code` heading and its code.
- The gap between a heading's bold label and its date is three spaces. A Tk text has no tab stops -- a tab character advances to a multiple of the font's space and lands wherever that is -- and an HTML table is a layout; three spaces is the only separator that looks the same at every label length.
- Two implementation notes worth keeping: `tools_available`'s `-param` is a flat list of option/value pairs, not a dict, so `dict get` returns only the first and the order has to be walked as a list; and a `regexp` pattern with a bare `}` or `]` closes the procedure body, so `tool_arguments_text`'s JSON-splitting pattern avoids both. `format %-*s` is meant for display columns and misaligns past the first (CJK names), so padding counts characters.
- Validation: `make` passes — 8 scripts, 207 checks (storage 58, Tk 47, debug 26, compact 22, run_code 17, recall 15, session_log 13, tools 9). New `tests/tools.tcl` covers the tool's parameter order, value alignment, multiline values on their own line, non-JSON arguments passed through, the heading naming the tool, the result label, the three-space gap, and `run_code` still showing its code. A rendered view was checked against the user's examples. `git diff --check` clean.
- The interval between clicking Send and curl starting was 270ms with the interface frozen; measured on the 789-message conversation it was mostly serialization done three times over: `fold_plan` and `prepare_request` each count tokens over the conversation, which calls `json_message` per message, and `json_payload` then serializes it all again — about 200ms — plus 33ms of `jq` pretty-printing a 1.1MB payload and inserting it as a folded debug body, plus ~30ms to spawn curl and feed it.
- Two fixes, measured per function. (1) Memoization: a message is immutable once appended, so `json_message` and `message_tokens` now keep what they computed in a bounded LRU cache (by entries and bytes, dropping the least recently used fifth in one pass). `json_message` ×792 goes 96.6ms cold → 2.9ms warm, `message_tokens` 15.4 → 2.6, `json_payload` 9.2 → 6.1, `fold_plan` 3 → 3. A leaf cache on `::json::write string` would add nothing: the inputs are unique per message, so every leaf call misses (measured, 25.5ms both times). (2) Debug bodies are no longer built at log time: a folded entry keeps its text and `debug_toggle` formats it with `jq` on first open (25ms, when the user asks for it, not on Send). The cache is warmed at session load in `after idle`, so the first request is not the one that pays the cold serialization.
- The interval is now 30ms warm and 30ms for the first request too. The remaining 30ms is curl's spawn plus feeding it 1.2MB — the request starting itself, which no thread can move elsewhere — so no request-builder thread is warranted on these numbers; on much slower machines the residual would grow, and the shape to reach for then is a builder thread carrying the serialization cache.
- Validation: `make` passes — 7 scripts, 198 checks (storage 58, Tk 47, debug 26, compact 22, run_code 17, recall 15, session_log 13). New checks cover the cache serving exactly what the uncached serializer computes, and debug bodies being built when a marker opens rather than at log time. `git diff --check` clean.
- Measured whether Tcl is fast enough for the session data now that `mimo-complete` is 3.4MB / 2159 records: it is, and no move to on-disk SQLite is needed. Against the real files (live conversation 710 messages, 269k tokens): startup end to end 59ms, switching to `mimo-complete` 36ms, `json_payload` 64ms and `fold_plan` 62ms per request (against seconds of network), `append_message` 0.04ms, a fold 20ms, `tool_recall` over the whole record 97ms. Parse is ~10ms per MB and recall is O(record), so a 10MB session would switch in ~100ms and recall in ~300ms; the per-request cost is bounded by the fold, which keeps the live conversation within the model's window. SQLite would pay only at tens of MB where startup matters, or if recall had to index incrementally. Note for future benches: a bench that reads `current_messages` must set `current_session` first, or it times the empty default session — the first pass here reported 0.0ms that way.
- Added the `recall` tool: the session record searched as memory, borrowing Strument's design and description (`internal/coder/recall.go`, the `2026-10-recall` experiments). Compaction keeps what the user said and drops what the work found out; asked later, the model can only say it does not know, with the answer one search away on disk. `recall` turns that gap into a lookup: grep-shaped, hits newest first, each with an id (`t4.3`, turn and message) that opens that message whole, matches still in the conversation counted rather than shown, `from` separating the conversation from tool output, and recall's own results left out so a search cannot find its previous answers. The query language is raw FTS5 instead of regexps — models write SQLite — with a phrase fallback and a note when a query is not valid FTS5.
- The index is an ephemeral FTS5 SQLite database in memory, rebuilt per call and thrown away: measured over the real 614-record `mimo` log, indexing takes 17ms and the whole call 10ms, queries 0.05ms, so there is nothing to cache or keep in step with the append-only file. `unicode61` tokenizing matches identifiers (`save_session`), phrases (`"save session"` matches `save_session`), prefixes and case and diacritics alike.
- Roll notes now point at the record, with Strument's recall wording: a clause in the label and the instruction after the quotes. Its experiments found models answer "I don't know" with the answer one search away unless the pointer is there.
- Validation: `make` passes — 7 scripts, 195 checks (storage 56, Tk 46, debug 26, compact 22, run_code 17, recall 15, session_log 13). New `tests/recall.tcl` covers search across a fold, counted in-conversation matches, opening by id, the `from` scopes and their hint, recall's own results being unsearchable, the phrase fallback, an id used as the pattern, and naming another session. Against the real `mimo` log the tool answers correctly; its searches report everything as still in the conversation, which is the case `mimo-complete` exists to fix. `git diff --check` clean.
- Sessions are append-only. A compaction — `/compact` or the automatic fold — no longer overwrites the session file: it appends a marker record, `{type fold label … summary …}`, whose summary is the message list that stands in for what was dropped (the kept system prompt and the note), followed by the kept tail. Everything above the marker is ignored from then on; the last marker decides what the conversation is. The cut-away history stays in the file above its marker, whole and recoverable, and a crash mid-compaction cannot lose it. AGENTS.md now says all this.
- The format stays Tcl: records are lists and a record's text may span lines. One-record-per-line (JSONL-like) was designed out — the alternatives that make a record self-contained escape newlines (`Dolor\ sit\ amet`), which is exactly the unreadable form we wanted to avoid.
- One parser reads and one writes, and the writer never inspects the file's lines: `session_records` / `join_session_records`, used by `read_session`, `save_session` and `append_session_records` alike. This is the lesson of the hang: my first attempt's save compared record *lines*, and a multi-line record's partial line leaves an unmatched brace — `lindex` raised inside `save_session`, the error escaped past `request_readable`, and the harness sat on "Working..." forever.
- Validation: `make` passes — 6 scripts, 180 checks (storage 56, Tk 46, debug 26, compact 22, run_code 17, session_log 13). New `tests/session_log.tcl` covers marker append, history preservation, last-marker-wins across two folds, markerless legacy files, a bare marker, and refused damage. All eight real session files (including the 566-record `mimo` and `mimo-2026-11-11`) parse and round-trip byte-identically; a fold on a copy of `mimo` kept the full 566-record prefix, and live == reloaded after both folds with two markers in the file. `git diff --check` clean.
- `run_code` now evaluates model code in a thread of its own, so code that hangs no longer hangs the interface. The hang that prompted this was not a child process at all but a Tcl loop of mine — `while {![eof $ch]} {}` against a non-blocking channel — and nothing bounded Tcl itself. Each call gets a fresh thread and a fresh interpreter: state does not persist between calls (use files for what must survive), and nothing one call does reaches the next. This overturns the earlier "why not threads" note: the Thread package is present here, and `thread::cancel` measurably stops a runaway loop at a bytecode boundary, which no same-thread design can do. Without the package the code runs in the harness as it always has.
- The harness is the watchdog. A call that runs past `run_code_timeout` (new, 300s) — or that the user stopped — has its child processes signalled, its evaluation cancelled, and its thread dropped, and answers "timed out after Ns: the code was still running and was stopped. Ask for more time with `::run_code::deadline`…". Stop does the same mid-call. In a Tk experiment an `after` tick fired during a `while 1 {}` and the call was stopped in 4s.
- Model code reaches the harness — its state, its sessions, its Tk — with `::run_code::harness {script}`, which runs there and returns its result. The name is `harness`, not `main_thread`: `main` already names the proc that drives the application, and `harness` stays honest in the no-Thread fallback, where there is no thread to name. `/eval` and `debug eval` keep running in the harness's own thread, stateful from one time to the next.
- The `exec` shadow learned what it lacked from real `exec`: a failing command reports what it wrote (close on a pipeline left non-blocking is quiet about the exit status, so the channel goes back to blocking first), one trailing newline is dropped as `exec` drops it, `-keepnewline` is honoured, options stop at the first command word, and a command that reads input sees end of file instead of waiting.
- Validation: `make` passes — 5 scripts, 167 checks (storage 56, Tk 46, debug 26, compact 22, run_code 17). New checks cover command output and errors, stdin at end of file, option words, durations, a timeout with nothing left running, children going with a hung command, state not surviving a call, the bridge, a loop that never ends with the harness ticking beside it, `::run_code::deadline`, and in-harness statefulness. A Tk experiment replayed the hangs: the loop stopped in 4s with the interface ticking, a `wish` GUI killed with nothing left running, `/eval` keeping state (21 then 42), tool calls not. `git diff --check` clean. Not tested here: the Windows paths (`taskkill /T`, graceful-then-forced) and a machine without the Thread package.

## 2026-11-11 — MiMo-V2.6-Pro
- A tool execution is folded like a tool call. `tool_run_code` logged `run_code code {…}` with no label, so a multi-line script stayed open in Debug and buried the entries around it — `no-fold.log` is one such. It now passes the tool's name as the label, so the entry folds under a `… (tool) run_code [+]` header exactly as the call beside it does; the text keeps the name in it for the log file.
- Validation: `make` passes — 4 scripts, 150 checks (storage 56, debug 26, compact 22, Tk 46). The new Tk check runs a multi-line `run_code` and asserts the entry is folded under a named header. A probe replayed the `no-fold.log` entry: five body lines render as one `run_code [+]` header at 51px, while a one-line tool note beside it stays visible. `git diff --check` clean.

## 2026-11-11 — MiMo-V2.6-Pro
- Fixed the `/attach` bug that left the harness saying "Working..." forever. Detaching deleted the stored copy while a sent message still referenced it, so the next request's `open` threw inside `json_payload`, which sat outside `request_async`'s catch: Tk put a dialog up behind the interface, nothing reached the Debug log but the traceback in `error.log`, and `busy` stayed 1. It persisted because every later request re-inlines that history.
- Attachments are now stored by content — `featherweight/attachments/<sha256 of the file>` — so the same picture is stored once however often it is attached and one name never means two things. Detaching takes an entry out of the list and leaves the blob, which messages already sent with it still need. The digest comes from tcllib's `sha256` package, whose namespace is `::sha2` and whose options are `-hex -filename`, neither of which its name suggests.
- A missing attachment no longer fails anything: `image_data_url` returns empty instead of throwing, and `json_content` sends `[image unavailable: name]` in its place with a note in the log, so the words around it still go out. Everything that builds a request now sits inside one catch in `request_async`, so an error like this one ends the turn rather than hanging it — that catch is the general fix, and the other two are what made this particular error reachable at all.
- Validation: `make` passes — 4 scripts, 149 checks (storage 56, debug 26, compact 22, Tk 45). New checks cover the content-addressed name, the same picture stored once and attached twice, detach keeping the stored copy, and a missing image reported rather than sent and never fatal. A probe replayed the reported sequence — attach, detach, attach again, then a message whose copy is gone — and the request returned without throwing with `busy` back to 0. `git diff --check` clean; not committed, per the commit rule in `AGENTS.md`.

## 2026-11-11 — MiMo-V2.6-Pro
- Basic image support. `/attach [path]` attaches an image to the next user message — a path, or the file dialog without one — and `/detach [N]` detaches one by number or all of them without an argument. The status bar lists what is waiting, `Ready (1) screenshot.png (2) IMG_20261111.JPG`, and a sent message takes its attachments with it. Each file is copied into `featherweight/attachments/` so the record survives the original being moved or deleted; detaching removes the copy.
- A message's content is now either a string or a list of parts — words and images — and `json_message` turns an image part into an `image_url` data URL, with the MIME taken from the file name. Display, the listings, and what a fold quotes go through `content_display`, which shows `[image: name]` for each image.
- Image tokens are estimated from the dimensions, following the research in `strument/internal/coder/imagetokens.go`: OpenAI's formula — 85 base plus 170 per 512-pixel tile, rounded up in both directions — since that is what an OpenRouter request meets, capped at 2600 where providers downscale before counting, and 1600 when the shape cannot be read, which that file argues must be on the high side: "a guard that under-counts lets a request through that the provider then refuses, which is the failure with a cost attached." The first cut here was a flat 1024, which under-counts a 1080p screenshot by half. `image_dimensions` reads PNG, GIF and JPEG headers; anything else falls to the high default. Staged attachments are counted in the `/context-size` report as well, for the reason that file's `countPending` gives: the number is wanted exactly while they are staged and still being decided on.
- Also repaired a bug in the previous commit, which brought in `debug_color` and the `dict for` over `debug_colors` but not the variable's definition — any folded entry threw `can't read "debug_colors"`.
- Validation: `make` passes — 4 scripts, 147 checks (storage 56, debug 26, compact 22, Tk 43). New checks cover the data URL and MIME in the request, the estimate from dimensions (765 for 888x655, 2600 capped, 1600 unknown), parts round-tripping and display, the status bar list, numbering, detach by number, detach all, and the staged row in the report. A probe against real PNG, JPEG, GIF and WebP files matched `identify` on every dimension it could read. `git diff --check` clean.

## 2026-11-10 — MiMo-V2.6-Pro
- The underline of a fold marker in Debug matched nothing: Tk draws underlines in its own default colour unless a tag says otherwise — `-underlinefg` has existed since 8.6.10 for exactly this — so the black line under a blue `(request) [+]` read as a separate element. Each `cat_*` tag now sets `-underlinefg` to its own foreground, and since the marker already carries that tag the underline takes the text's colour, with no per-entry work.
- Validation: `make` passes — 4 scripts, 133 checks (storage 51, debug 26, compact 22, Tk 34). The new Tk check compares each category's `-underlinefg` with its `-foreground`. `git diff --check` clean.

## 2026-11-10 — MiMo-V2.6-Pro
- Debug entries that carry something long are folded to their header line: `(request)` and `(response)` show `2026-11-10 15:52:52 +0300 (request) [+]` with the JSON body elided behind it, and a tool call shows `… (tool) run_code [+]` with its call dict folded. The marker is clickable: it flips to `[-]` and the body opens. Tool notes (`model set to …`, fold lines), errors and `/eval` lines stay visible, since they are one-liners and there would be nothing to fold. Folding is a view, so `featherweight-debug.log` keeps its one-line-per-entry format with the full body. The marker is underlined — it is the only thing in the log that responds to a click.
- `debug_log` takes an optional label, and folds when it has one or is in `request`/`response`. The label goes in the header, and a tool call passes its tool name, so the log stays navigable without clicking. Tk's text widget supplies both primitives — `-elide` hides without deleting, so an opened body is still selectable and copyable, and a tag can carry a click binding — and the fold state lives in a `debug_open` array, updated with the marker in the same procedure, so the two cannot disagree.
- Validation: `make` passes — 4 scripts, 132 checks (storage 51, debug 26, compact 22, Tk 33). The Tk checks cover a request folded to its `[+]` header with the body present but hidden, opening and closing it, the click binding, a tool call folded with its name in the header, and a tool note staying visible. A probe measured 85px folded against 153px opened. `git diff --check` clean.

## 2026-11-10 — MiMo-V2.6-Pro
- Requests the network drops are sent again instead of stopping the turn and leaving the user to type "continue". `retry_request` re-sends after 1, 2, 4, 8, 16 seconds (capped at 16) up to `retries` times — 5 by default, 0 to switch it off — and then gives up with `giving up after N retries: ...`. It is reached when curl could not complete (a non-zero exit: the SSL `ERROR_SYSCALL` that prompted this, timeouts, dropped connections), when the response cannot be read, and when the server answers 429 or 5xx; a client error or a malformed answer is not retried, since another attempt would fail the same way. `submit` and `stop` reset the counter, and a retry scheduled while the turn was stopped does nothing.
- A new `timeout` configuration key (300 seconds) becomes curl's `--max-time`, so a hung request turns into a failure the retry path can act on rather than a hung turn.
- The reason a run failed comes from curl's `--write-out` line (`%{exitcode}`/`%{errormsg}`), which survives a failing run: `curl_error` reads it and falls back to the error `close` reported. A probe confirmed both parts of that — `close` throws `CHILDSTATUS … 52` and the trailing line still holds `000 52 Empty reply from server` — so retries name the cause (`curl (52): Empty reply from server`) instead of guessing at it.
- Validation: `make` passes — 4 scripts, 126 checks (storage 51, debug 26, compact 22, Tk 27). Storage rejects a negative `retries` and a zero `timeout` and confirms the defaults; the Tk suite runs a real turn against a dead local port with `retries 2` and asserts both retries, the give-up, and the turn stopping. A probe with `retries 3` shows `retry 1 of 3 in 1 s` through `giving up after 3 retries`, 11s end to end. `git diff --check` clean.

## 2026-11-10 — MiMo-V2.6-Flash
- Replaced the size-matching gap between the input and Send (previous entry) with a real sash: `.root.input` now holds a horizontal `ttk::panedwindow` whose panes are the entry (`-weight 1`) and the button (`-weight 0`), so the row reads as `Conversation — Debug — [input — sash — Send]`, three resizable divisions under one geometry system. The `update`-and-measure block in `build_ui` is gone; `W entry` and `W send` now name `.root.input.p.e` / `.root.input.p.send`, the only external references.
- Probed ttk::panedwindow before committing to it: it takes no `-padding` (the outer frame keeps that), exposes no sash options (the handle is found through `identify`), and a real drag does not clamp panes to their requested widths — which is not a defect of this design but how panedwindows work: a probe confirmed the existing vertical sashes behave the same way (dragging Conversation collapses it to 1px). Window resizes are clamped by the pane weights, so Send holds its width as the entry grows.
- `build_ui` no longer takes an `update` (it had needed one only for the measurement), so geometry tests must update after construction before reading sizes; `tests/tk.tcl` does.
- Validation: `make` passes — 4 scripts, 121 checks (storage 48, debug 26, compact 22, Tk 25). Tk checks: the sash exists and `identify` reports it, Send spans the input's height, keeps its width across a window resize while the entry grows, and the old gap/pack checks are removed. A layout probe against `build_ui` confirmed entry/button geometry across widen, drag, and re-narrow. `git diff --check` clean.

## 2026-11-10 — MiMo-V2.6-Flash
- The horizontal gap between the input and the Send button was an arbitrary 4px (`-padx {4 0}`). It is now the height of the sash above the input: `build_ui` takes an `update` first, measures `sashpos 1` less the heights of the two panes above it (6px on this build), falls back to 6 when the window cannot be measured, and packs the button with that gap. A probe confirms padx `6 0` against a 6px sash.
- Measured rather than hardcoded because ttk::panedwindow offers no sash options at all (only `-orient`, `-width`, `-height`, `-takefocus`, `-cursor`, `-style`, `-class`) and the clam theme has no `Sash` layout element, so the thickness comes from Tk's own drawing and could differ elsewhere; reading it keeps the relationship the request asked for true.
- Validation: `make` passes — 4 scripts, 120 checks (storage 48, debug 26, compact 22, Tk 24). The Tk check recomputes the sash height from live geometry and compares it with what `pack info` reports for the button, so a hardcoded gap would fail it. `git diff --check` clean.

## 2026-11-10 — MiMo-V2.6-Flash
- Three cosmetic changes to the interface. The input frame is now the third pane of the panedwindow that already holds Conversation and Debug (`-weight 1`, `-padding {0 6 0 0}` to keep it clear of the sash), so a sash sets its height the same way it sets theirs; the Send/Stop button is packed `-fill y`, which makes it the height of the input instead of hugging its label.
- The title is now `Featherweight - <launch directory>/ - <model>`, dropping the session name. It is rebuilt from state rather than kept, and refreshed after every slash command that gets past its query cases and after every tool call in `apply_message`: `/eval` can cd, `/model` changes the model, and a tool can change either. `/model`'s own call was dropped as the general one covers it.
- Fixed a bug the layout probe turned up: `build_ui` called `update_window_title` before `W` existed, so the chat-widget guard bailed and the window kept Tk's default title until the first command. The call now runs once the widgets are in place.
- Validation: `make` passes — 4 scripts, 119 checks (storage 48, debug 26, compact 22, Tk 23). New Tk checks assert that the input is the third pane, the button's pack fill, and the title at build time, after `/model`, after `/eval`, after a tool call that changes state, and after a cd. A layout probe measured the input and button at the same 77px and a sash move resizing the input by exactly the amount moved. `git diff --check` clean.

## 2026-11-10 — MiMo-V2.6-Flash
- The timestamp beside each label was illegible in the interface: it used `timestamp_font`, `TkTextFont` two points down. The `timestamp` tag now uses `TkTextFont` itself, so the time is the size of the message text and only weight separates it from the label, which stays bold through `role_font` — the distinction the rendering relied on. `timestamp_font` is removed; nothing else used it.
- Tk 8.6 returns `text tag configure <tag> <option>` as a five-field record (option name, three empty fields, then the value) rather than the bare value, so `tests/tk.tcl` grew a `tag_value` helper that takes the value from wherever it appears instead of hard-coding an index. The font checks now assert the timestamp measures the same as `TkTextFont` and is normal weight while the label is bold, replacing the old "smaller than the text font" check.
- Validation: `make` passes — 4 scripts, 112 checks (storage 48, debug 26, compact 22, Tk 16). `git diff --check` clean; not committed, per the commit rule in `AGENTS.md`.

## 2026-11-10 — MiMo-V2.6-Flash
- Followed the rename of the source from `bootstrap.tcl` to `featherweight.tcl` (the rename itself was `035094d`): the `usage` text and the script-mode comment in `featherweight.tcl`, both lines of the `Makefile` recipe and its comment, the header comment of `tests/debug.tcl`, and the path `tests/lib.tcl` sources — which is what every test loads and what `run_cli` hands to each CLI invocation, so the suite could not run without it.
- Renamed `::test::bootstrap` to `::test::harness` (and its use in `tests/storage.tcl`) so the variable no longer names a file that does not exist.
- Nothing else referenced the old name. `AGENTS.md` and `.gitignore` are clean; `debug selftest` derives the tests directory from `info script`, and the main guard compares `file tail` values, so both hold under any file name. `LOG.md` keeps its historical mentions of `bootstrap.tcl` as history.
- Validation: `make` passes — 4 scripts, 111 checks — and `tclsh featherweight.tcl --help` prints the new name. `git diff --check` clean; not committed, per the commit rule in `AGENTS.md`.

## 2026-11-10 — MiMo-V2.6-Flash
- Timestamped the session log for record-keeping: every message written to a session now carries a Unix `time` field. `append_message` stamps what it stores and returns the stored message, so the interface shows the same time that was saved. The messages created outside it are stamped where they are made: the system message that seeds a new or empty session (`init_config`, `switch_session`) and the note a fold writes (`harness_note`).
- Messages written before this change keep no time rather than being given a false one. `message_time` reads a message's time or returns an empty string, and a message with none is displayed exactly as it was before, with the bare label.
- Displayed as local time in the configured format: `timestamp_format`, a new configuration key defaulting to `%Y-%m-%d %H:%M:%S %z`, added to configurations that predate it. The label stays bold and the time sits beside it in its own `timestamp` tag with a new `timestamp_font`, two points off `TkTextFont`. `ui_label` renders the heading line for `You`, `Assistant`, `Tool code` and `Tool`; a tool call carries the time of the assistant message that made it, in the live turn and in a replay alike.
- The debug log now uses that same format instead of its old time-only `%H:%M:%S`, and `debug session show` prints each message's time beside its role.
- The time is ours, not the API's: `json_message` leaves `time` out of the payload, so it is neither sent nor counted toward the context budget.
- Validation: `make` (== `debug selftest`) passes — 4 scripts, 111 checks (storage 48, debug 26, compact 22, Tk 15). New checks cover the config key and its round trip, an appended message's Unix time, the time's absence from the payload, pre-timestamp messages, the debug log's format, timestamps in the view, the smaller font, the timestamp's own tag, and a message with no time showing bare. A rendered tag dump confirms `You ` under `role` followed by the time under `timestamp`. Worth knowing: `clock format` refuses no format string (`%Q` prints a Stardate), so `timestamp_format` is taken as given rather than validated at startup. `git diff --check` clean; not committed, per the commit rule in `AGENTS.md`. No live API request was made.

## 2026-11-10 — MiMo-V2.6-Flash
- Replaced console mode with script mode. Console mode was dead on arrival: `console_main` had a malformed `lmap` that failed on entry, `console_turn` called `::http::geturl` with no `package require http`, and it was a third copy of the turn loop beside the GUI's async curl path — which is why it rotted. Deleted `console_main`/`console_turn` and the `tok` variable. With no arguments and no display, `main` now prints a hint pointing at `debug --help` and exits 1 instead of falling back into a parallel mode users would not touch.
- `tclsh bootstrap.tcl debug <subcommand>` is the non-GUI path: `request`, `fold`, `session list|show|check`, `eval`, `selftest`, plus `--help`. Exit codes are 0 for success, 1 for a runtime error, 2 for a usage error (usage goes to stderr). Script mode never sends a request; loading state creates missing files the way starting the interface does; only `debug eval` can change what is stored. The design's `--dry-run` flag was dropped rather than kept as a no-op: `request` and `fold` are read-only by construction, so there is nothing to turn off.
- `debug request` prints what would go out — model, endpoint, message count and tokens, tool schemas, the fold that would run first, then the payload — with no network. `--session name` inspects another session in memory only (the switch is never saved), `--last n` lists the tail of the history instead of the payload.
- `debug request --replay file [--keep]` runs one whole turn from a queue of recorded responses (one response body per line) against a throwaway copy of the state in the system temp directory, so the stored sessions are untouched; the recorded tools still run for real against the project. `--keep` retains the copy for inspection. `debug fold [--force]` reports the plan a fold would execute — cut, tokens before and after against the target, how many user messages the note would quote — without executing it; `debug session check` validates the configuration and every session file and exits non-zero on a problem, which is what it is for.
- The point of the exercise was not to grow a second implementation, so the logic was split out and shared: `fold_plan` is the whole of `compact_context` minus the writes (it returns cut, note, said, before, after, target and a `why` when it would not fold), and the response handling became `response_message` (body to message, or a specific error) plus `apply_message` (store the message, run its tool calls, return whether to re-request). `request_readable` and the replay both end in those two, and `/compact`, `debug fold` and `debug request` all ask `fold_plan`, so the three paths cannot disagree. `state_dir` gained a `state_root` override, which is how the replay points at its copy.
- The test suite moved into the repo as `tests/`: `lib.tcl` (harness: `test::start`, `ok`, `fails`, `run_cli`) plus `storage.tcl`, `compact.tcl`, `tk.tcl` and `debug.tcl`, with `fixtures/replay.jsonl`. `debug selftest` runs every `tests/*.tcl` except `lib.tcl`, each in its own `tclsh` with a 120 s guard, and exits non-zero if any fails. Each test gets its own `tests/.tmp/<name>` directory (gitignored), so the project's sessions are never touched — this is the part that would have survived the `/tmp` purge that deleted the earlier suites.
- Validation: `debug selftest` passes — 4 scripts, 101 checks (storage 43, debug 26, compact 21, Tk 11) — covering the storage layout, the automatic and forced folds and their reports, every CLI subcommand's output and exit code, a full replayed turn that runs a tool and leaves the real session at one message, and UI replay/switch/refresh. Headless start verified: exit 1 with the hint. `git diff --check` clean. No live API request was made.
- Not done: an offline test of the async transport itself (`request_async`/`request_readable` against a local HTTP server) — the replay exercises the shared turn logic, not curl or the fileevent loop, which is still covered only by daily use. `session_names` still lists `*.pid.tmp` crash leftovers as sessions, as recorded in the previous entry.

## 2026-11-09 — MiMo-V2.6-Flash
- Added `/compact`, which folds the current session's history on request. It shares `compact_context` with the automatic path, which gained a `force` argument: the automatic call is unchanged (still returns early when the history fits the budget, still aims at `context_size/2`), while a forced fold runs even when the history fits and aims at half of what is there rather than at half the budget.
- The forced target is `min(history/2, budget/2)`. The first term lets it fold a history sitting well inside a large window, where the automatic target is above the history and would pick the first cut — which drops nothing; the second keeps it from leaving a session over a window the automatic rule would have respected. With `context_size off` (`history_budget` is 0) it aims at `history/2`, so disabling automatic folding does not disable the manual one.
- The rest of the fold is the automatic one: cuts only at genuine user-turn boundaries, system prompt preserved, latest turn kept whole as the fallback, dropped user messages quoted verbatim in the marked note, result written through `set_current_messages` to `featherweight/sessions/<name>` and the conversation view refreshed.
- A forced fold that cannot help says so rather than doing nothing quietly: `nothing folded` when there is no user turn to cut at, or when keeping the latest turn whole and quoting the user's own words verbatim would leave no fewer tokens than the session has now — the fold never trades the user's words away, so a session that is mostly the user's own text may genuinely be unhalvable. Successful forced folds log `folded on request:` beside the automatic `compacted history:` line. `/compact` takes no arguments and reports `usage: /compact` otherwise.
- Validation in a separate `tclsh` process, 19 checks: the automatic fold still runs over budget, reaches half the budget, marks and persists the fold, logs itself, and is inert on a second pass; it stays off while history fits the budget; `/compact` refuses arguments, folds what the automatic fold left alone, halves the history, keeps the system prompt, quotes the dropped user text, writes to the session file, and logs `folded on request`; a session too small to halve is left alone with a `nothing folded` log line; with `context_size off` the automatic fold is inert while `/compact` still halves; `info complete` and all procedures compile. A separate Tk test (10 checks) passed the fold itself, the refreshed view, the folded-away assistant reply leaving the view, the dropped user text still quoted in it, the window title, agreement with the file on disk, and the refused fold leaving the view unchanged. `git diff --check` is clean. No live API request was made.

## 2026-11-09 — MiMo V2.6 Pro
- Reviewed `sessions-dir-mimo` vs `sessions-dir-deepseek` (both split state into `featherweight/config` + `featherweight/sessions/<name>`) to recommend a merge. Behavioral tests in separate `tclsh` processes covered fresh init, config byte-stability on append, lazy vs eager loading, corrupt-file handling at startup and at `/session` switch, hostile names, migration from `featherweight.conf`, and startup on the real 2.1 MB state (561 messages).
- Recommendation: merge `sessions-dir-mimo`. It loads sessions lazily (9 ms, 1 session vs 26 ms, all 4, on real data; grows with history), never overwrites an unreadable session file (errors instead), and reuses `write_text_file` rather than duplicating atomic-write logic. Verified DeepSeek's `switch_session` clobbers a corrupt session file with a bare system message (contradicting its own log's promise), and its log's claimed "latent bug" in master's `append_message` is incorrect — master appends correctly.
- Take from DeepSeek as follow-ups: one-time migration from `featherweight.conf` (MiMo abandons the old history by decision; moot here — the working tree was already migrated and its state loads cleanly under MiMo, verified), `default_config` fallback for hand-edited configs (MiMo errors on a missing key), and cached `state_dir` (MiMo re-resolves `[pwd]`).
- MiMo gaps found: `session_names` lists crash-leftover `write_text_file` temp files (`name.pid.clock.tmp`) as sessions and hides dot-file sessions that `switch_session` accepts; a corrupt *current* session aborts startup (fail-loud by design; never clobbers).
- No files besides `LOG.md` changed; test scripts stayed in `/tmp/fwtest`. Both branches pass `git diff --check`. No live API request was made.

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

