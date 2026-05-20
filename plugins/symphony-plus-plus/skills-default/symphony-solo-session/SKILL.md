---
name: symphony-solo-session
description: Use when Codex needs lightweight local planning memory for one normal single-agent repo, worktree, or task without Symphony++ WorkRequest or WorkPackage orchestration. Creates or attaches a local Solo Session, appends task plan, finding, progress, blocker, decision, and validation entries, reads the ledger, and completes or archives the session through the Symphony++ plugin wrapper.
---

# Symphony++ Solo Session

Use Solo Sessions for ordinary single-agent Codex work that needs durable local
planning memory. This is the default Symphony++ planning path for real agents
that do not need WorkPackage MCP orchestration, including visible desktop app
threads where the default plugin must stay skill-only. Do not use this skill
for assigned WorkPackages, WorkKeys, WorkRequests, architect orchestration,
worker dispatch, Linear state, bound MCP planning resources, or merge-readiness
gates.

Use the opt-in `symphony-plus-plus-mcp:symphony-work-package` skill instead
when assigned a WorkPackage or WorkKey. Use
`symphony-plus-plus-mcp:symphony-architect` for WorkRequest-led planning or
package dispatch. A repo-local `.codex/skills/symphony-work-package/` copy is
also acceptable inside a Symphony++ checkout.

## Source Of Truth

Treat the Solo Session ledger as the source of truth. Do not create local
`task_plan.md`, `findings.md`, or `progress.md` as authoritative planning files
when this skill is active. If a user explicitly asks for file-backed planning,
follow that request and keep the two workflows separate.

Never store raw API keys, bearer tokens, GitHub tokens, Linear tokens, MCP auth
tokens, worker secrets, raw WorkKeys, access grants, secret hashes, or private
handoff payloads in Solo Session entries, titles, payload JSON, idempotency
keys, command lines, PR text, or logs.

## Wrapper

Use the plugin wrapper so the current shell can stay in any repo:

```powershell
pwsh <plugin-root>/scripts/sympp-solo.ps1 -Help
pwsh <plugin-root>/scripts/sympp-solo.ps1 -ValidateOnly
```

The wrapper resolves the Symphony++ checkout from `SYMPP_REPO_ROOT`, the
installed plugin cache `.sympp-source-root` hint, or source-checkout inference,
then runs from the resolved `elixir/` directory. It accepts the same launcher
environment as the MCP wrapper: `SYMPP_LAUNCHER=direct|mise`, `SYMPP_MIX`, and
`SYMPP_MISE`.

When neither `--database` nor `SYMPP_DATABASE` is supplied, the wrapper lets
`mix sympp.solo` use the shared local Symphony++ default ledger, preferring
`$HOME/.agents/splusplus/symphony_plus_plus.sqlite3`
(`%USERPROFILE%\.agents\splusplus\symphony_plus_plus.sqlite3` on Windows) and
falling back under a temp/relative `.agents/splusplus` root if home is
unavailable,
matching cockpit and WorkRequest/WorkPackage CLI defaults. Set
`SYMPP_DATABASE` or pass `--database <sqlite-path>` only when you need a
specific isolated ledger. Relative `--database` and `SYMPP_DATABASE` paths
resolve against the caller workspace. Treat `SYMPP_DATABASE` as a path only; do
not echo secret-bearing environment values.

## MCP Tools

If the generic `symphony_plus_plus` MCP server is loaded and the session is
unbound, prefer the Solo MCP tools for attach, append, show, list, and lifecycle
status updates:

```text
solo_attach
solo_append
solo_show
solo_list
solo_update_status
```

Those tools use the MCP server's configured repo/database and are intentionally
not advertised to bound worker or architect WorkPackage sessions.
`solo_update_status(session_id, current_status, next_status)` reuses the Solo
lifecycle service for pause, resume, complete, and archive transitions with
optimistic current-status checking. Full-history reads still use the wrapper;
`solo_show` returns the latest 50 entries plus count/truncation metadata.

## Start Or Attach

Derive scope before attaching:

- `workspace_path`: absolute repo root from `git rev-parse --show-toplevel`;
  otherwise use the current workspace directory after resolving it to an
  absolute path.
- `repo`: prefer the repository remote slug or directory name; keep it stable
  across worktrees for the same repo.
- `base_branch`: use the assigned target base if present; otherwise inspect the
  upstream/default branch, falling back to the current branch only when there is
  no better base signal.
- `caller_id`: use a stable local caller identity such as
  `codex:<repo>:<workspace-leaf>` or an operator-provided id. It must not be a
  raw thread id, token, WorkKey, or secret.
- `title`: short user-facing task title.

Attach once near the start of work and retain the returned `solo_session.id`:

```powershell
$workspace = (git rev-parse --show-toplevel)
$repo = Split-Path -Leaf $workspace
$base = "main"
$caller = "codex:$repo:solo"

pwsh <plugin-root>/scripts/sympp-solo.ps1 attach `
  --repo $repo `
  --base-branch $base `
  --workspace-path $workspace `
  --caller-id $caller `
  --title "Investigate local failure"
```

## Append Entries

Append small entries as the work changes. Use non-secret idempotency keys so a
retry does not create duplicate ledger rows. A good key is deterministic from
session id, entry kind, phase, and a short local slug, for example
`solo:<session-id>:progress:validation-ruff`.

Entry kinds:

- `task_plan`: planned phases, changed strategy, or current next steps.
- `finding`: durable discovery, evidence, file reference, root cause, or
  important rejected hypothesis.
- `progress`: meaningful implementation step, validation run, or handoff state.
- `blocker`: active issue that prevents progress and needs user/operator input.
- `decision`: local technical decision with rationale and scope impact.
- `validation_note`: command, result, blocked validation, or residual risk.

Examples:

```powershell
pwsh <plugin-root>/scripts/sympp-solo.ps1 append `
  --session-id <solo-session-id> `
  --entry-kind task_plan `
  --title "Plan implementation" `
  --body "Inspect failing test, patch owning module, rerun focused suite." `
  --idempotency-key "solo:<solo-session-id>:task-plan:initial"

pwsh <plugin-root>/scripts/sympp-solo.ps1 append `
  --session-id <solo-session-id> `
  --entry-kind validation_note `
  --title "Focused tests passed" `
  --body "uv run pytest tests/test_example.py -q passed." `
  --status "passed" `
  --idempotency-key "solo:<solo-session-id>:validation:focused-tests"
```

Use `--payload-json '{"command":"...","exit_code":0}'` only for non-secret
structured metadata. Keep large logs out of the ledger; summarize the result
and reference local files when needed.

## Read And Continue

Use `show` to recover the current ledger and `list` to find sessions by local
scope:

```powershell
pwsh <plugin-root>/scripts/sympp-solo.ps1 show --session-id <solo-session-id>

pwsh <plugin-root>/scripts/sympp-solo.ps1 list `
  --repo $repo `
  --base-branch $base `
  --workspace-path $workspace `
  --caller-id $caller `
  --status active
```

Before major decisions, after long pauses, or before final response, read the
ledger and reconcile it with the actual repo state.

## Lifecycle

- Keep the session `active` while making progress.
- Use `pause` when work is intentionally stopped but should remain attachable.
- Use `resume` before appending after a pause.
- Use `complete` when the requested work is done and final validation/review
  notes are recorded.
- Use `archive` for stale or no-longer-needed history. Archived sessions are
  readable but not mutable.

```powershell
pwsh <plugin-root>/scripts/sympp-solo.ps1 pause --session-id <solo-session-id>
pwsh <plugin-root>/scripts/sympp-solo.ps1 resume --session-id <solo-session-id>
pwsh <plugin-root>/scripts/sympp-solo.ps1 complete --session-id <solo-session-id>
pwsh <plugin-root>/scripts/sympp-solo.ps1 archive --session-id <solo-session-id>
```

When using MCP instead of the wrapper, pass the explicit status transition:

```text
solo_update_status(session_id, current_status, next_status)
```

Before final response, append validation/review status and any remaining risk.
If work is incomplete, leave an active `blocker` or progress entry that states
the exact next step.
