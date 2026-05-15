---
name: symphony-solo-session
description: Use when Codex needs lightweight local planning memory for one normal single-agent repo, worktree, or task without Symphony++ WorkRequest or WorkPackage orchestration. Creates or attaches a local Solo Session, appends task plan, finding, progress, blocker, decision, and validation entries, reads the ledger, and completes or archives the session through the Symphony++ plugin wrapper.
---

# Symphony++ Solo Session

Use Solo Sessions for ordinary single-agent Codex work that needs durable local
planning memory. Do not use this skill for assigned WorkPackages, WorkKeys,
WorkRequests, architect orchestration, worker dispatch, Linear state, MCP
planning resources, or merge-readiness gates.

Use `symphony-work-package` instead when assigned a WorkPackage or WorkKey. Use
`symphony-architect` for WorkRequest-led planning or package dispatch.

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

Set `SYMPP_DATABASE` to a durable local SQLite ledger path, or pass
`--database <sqlite-path>` on each command when you need a specific ledger.
When neither is supplied, the wrapper derives the caller workspace from the
original current directory and uses
`<caller-workspace>/.sympp/solo-sessions.sqlite3`. Relative `--database` and
`SYMPP_DATABASE` paths resolve against the caller workspace. Treat
`SYMPP_DATABASE` as a path only; do not echo secret-bearing environment values.

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

Before final response, append validation/review status and any remaining risk.
If work is incomplete, leave an active `blocker` or progress entry that states
the exact next step.
