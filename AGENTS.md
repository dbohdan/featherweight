# Agent instructions

## Sessions

Session files under `featherweight/sessions/` are **append-only**. Never rewrite,
truncate, or "tidy up" one: the file is the conversation itself, including anything
a compaction has cut away.

- A record is a Tcl list — a message (it has a `role`) or a marker (it has a `type`
  and no `role`). A record's text may span lines; the file stays readable as Tcl.
- There is **one** way to parse this, and both reading and writing use it:
  `::featherweight::session_records` and `::featherweight::join_session_records`. A
  write must never inspect the file's lines directly — a record that spans lines
  leaves a partial line with an unmatched brace, and the parse fails. This is what
  hung the harness once.
- A compaction appends a marker — `{type fold label … summary …}` — whose `summary`
  is the message list that stands in for what was dropped, followed by the kept tail.
  Everything above the marker is ignored from then on; the last marker decides what
  the conversation is. Nothing before it is touched, so a crash mid-compaction cannot
  lose history.

## Worklog

Maintain `LOG.md` as the handoff between sessions.

- At the end of every work session that changes files, documents behavior, or performs a
  substantive investigation, add an entry to `LOG.md` before responding to the user.
- Start each entry with the UTC date and the model that did the work (for example,
  `## YYYY-MM-DD — Kimi K3.1 Pro`).
- Record what changed and why, relevant design decisions, validation performed, and any
  tests that could not be run. Mention important limitations or follow-up work.
- Keep existing history. Add new entries near the top, below the title and prior model
  attribution, rather than replacing previous entries.
- Keep the log concise and useful to the next session; do not log secrets, API keys, or
  other credentials.

## Commits

Only commit when the user asks you to.

- Stage the files you touched, by name: `git add <path> ...`. Do not stage unrelated
  files, and never stage what `.gitignore` covers (`featherweight/`, `tests/.tmp/`,
  `*.log`, `*.bak*`).
- Commit with a signed trailer naming the model that did the work:

  ```
  git commit -S --trailer 'Assisted-by: [model] via Featherweight'
  ```

  Replace `[model]` with the model's name as it is written at the top of `LOG.md`, for
  example `Assisted-by: MiMo-V2.6-Flash via Featherweight`. If signing fails, say so
  rather than committing unsigned.
- Use the repository's conventional message style: a subject of the form
  `type(scope): summary`, and a short body saying what changed and why.
