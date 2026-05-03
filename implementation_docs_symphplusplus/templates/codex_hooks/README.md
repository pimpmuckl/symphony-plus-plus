# Optional Codex Hook Nudges

These templates are optional reliability aids for Symphony++ workers. They do
not install themselves, do not grant authority, and do not replace server-side
permission checks.

Use them when an operator wants Codex lifecycle reminders for assignment scope,
progress updates, and final handoff hygiene:

1. Enable hooks in the active Codex config layer:

   ```toml
   [features]
   codex_hooks = true
   ```

2. On macOS/Linux, copy `hooks.posix.json` into this repository's
   `.codex/hooks.json`. On native Windows, first confirm your Codex build loads
   project `hooks.json`; if it does, copy `hooks.windows.json`. If Codex reports
   that Windows lifecycle hooks are disabled, keep the Windows template as
   reference-only until that build supports discovery.
3. Review the messages and matchers before use. Keep them short and explicit.

Codex loads matching hooks from every active config layer. Project-local hooks
only load when the project `.codex/` layer is trusted. Keep these examples out
of runtime defaults unless the operator chooses to install them.

The checked-in commands resolve the helper from the current git root, so they
are intended for repo-local use in the Symphony++ checkout. For a user-global or
managed hook installation, first rewrite the command to an absolute managed path
where the helper is installed.

## Templates

- `hooks.posix.json` uses `bash` to launch the helper from the git root.
- `hooks.windows.json` is the native Windows template for builds that load
  project `hooks.json`; it is reference-only on builds that report Windows
  lifecycle hooks as disabled.
- `scripts/sympp_hook_nudge.py` emits fixed JSON reminders from the hook event
  name only.
- `scripts/sympp_hook_nudge.ps1` locates `py -3`, `python3`, or a Python 3
  `python` on Windows, verifies the candidate, and runs the Python helper. If
  no Python 3 runtime is available, hook launchers exit successfully without
  output.

Both templates cover:

- `SessionStart`: remind the worker to load the assigned WorkPackage context.
- `UserPromptSubmit`: remind the worker to keep scope and planning state current.
- `PreToolUse`: nudge before Bash/file-edit tool use without approving or denying.
- `PostToolUse`: nudge after Bash/file-edit tool use without hiding tool output.
- `Stop`: surface a post-reply handoff warning without forcing a rewritten
  reply, blocker report, or clarification question.

## Guardrails

- Hooks are not a permission boundary. Symphony++ permissions stay server-side.
- Do not embed grant secrets, bearer tokens, GitHub tokens, Linear tokens, MCP
  auth tokens, or claim URLs in hook commands or output.
- Do not read private transcripts or chain-of-thought for security decisions.
- Keep helper output based on hook event metadata only; do not echo prompts,
  tool input, tool output, or transcript content. Helpers should avoid parsing
  full prompt/tool payloads when a small event-name scan is enough.
- Prefer fixed, deterministic reminders over heuristic blocking.
- Do not make `Stop` hooks continue turns by default; that rewrites normal
  final replies. If a local deployment needs a continuation, make it an
  explicit operator-owned variant with separate tests.
- If a hook must block in a local deployment, make the condition explicit,
  test it separately, and keep operator override behavior clear.
- On Windows, prefer an explicit shell or interpreter command such as `pwsh`
  or `powershell` instead of invoking raw `.js` or other extension-associated
  files.
