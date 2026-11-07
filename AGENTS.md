# Agent instructions

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
