---
name: symphony-solo-session
description: Use when Codex needs lightweight local planning memory for one normal single-agent repo, worktree, or task without Symphony++ WorkRequest or WorkPackage orchestration. Creates or attaches a local Solo Session, appends task plan, finding, progress, blocker, decision, and validation entries, reads the ledger, and completes or archives the session through the Symphony++ plugin wrapper.
---

# Symphony++ Solo Session

Use Solo Sessions for ordinary single-agent work that needs durable local
planning memory without WorkRequest or WorkPackage orchestration. This is the
default Symphony++ planning path for real agents.

Do not use this for assigned WorkPackages, WorkKeys, WorkRequests, architect
orchestration, worker dispatch, bound MCP planning resources, or merge gates.
Use `symphony-plus-plus-mcp:symphony-work-package` for WorkPackages and
`symphony-plus-plus-mcp:symphony-architect` for WorkRequest orchestration.

## Source Of Truth

The Solo Session ledger replaces local `task_plan.md`, `findings.md`, and
`progress.md` for this task. Keep entries small and non-secret.
Do not create local `task_plan.md`, `findings.md`, or `progress.md` files for
Solo Session state.

Never store raw API keys, bearer/GitHub/Linear/MCP tokens, worker secrets, raw
WorkKeys, access grants, secret hashes, private handoff payloads, or
secret-bearing commands.

## Tools

Prefer MCP tools when available in an unbound session:

```text
solo_attach
solo_append
solo_show
solo_list
solo_update_status
```

Otherwise use the wrapper:

```powershell
pwsh <plugin-root>/scripts/sympp-solo.ps1 -Help
pwsh <plugin-root>/scripts/sympp-solo.ps1 -ValidateOnly
```

By default the wrapper uses the shared local ledger at
`$HOME/.agents/splusplus/symphony_plus_plus.sqlite3`. Set `SYMPP_DATABASE` or
`--database` only for an intentional isolated ledger.

## Attach

Attach once near the start and retain the returned `solo_session.id`.

Derive:

- `workspace_path`: repo root from `git rev-parse --show-toplevel`, else
  absolute current directory.
- `repo`: stable remote slug or directory name.
- `base_branch`: assigned target base, upstream/default branch, or current
  branch as fallback.
- `caller_id`: stable local id like `codex:<repo>:<workspace-leaf>`.
- `title`: short task title.

```powershell
pwsh <plugin-root>/scripts/sympp-solo.ps1 attach `
  --repo <repo> --base-branch <base> --workspace-path <path> `
  --caller-id <caller> --title "<task title>"
```

## Append

Append only meaningful state changes. Use non-secret idempotency keys.

Entry kinds:

- `task_plan`: phases, strategy changes, current next steps.
- `finding`: durable discovery, root cause, rejected hypothesis, evidence.
- `progress`: implementation step, handoff, or status update.
- `blocker`: active issue requiring user/operator input.
- `decision`: local technical decision with rationale.
- `validation_note`: command result, blocked validation, residual risk.

```powershell
pwsh <plugin-root>/scripts/sympp-solo.ps1 append `
  --session-id <id> --entry-kind validation_note `
  --title "Focused tests passed" --body "<command> passed." `
  --status passed --idempotency-key "solo:<id>:validation:focused"
```

Keep large logs out of the ledger; summarize and reference local files if
needed.

## Read And Lifecycle

Use `show` after pauses, before major decisions, and before final response.
Use `list` to recover active sessions by repo/base/workspace/caller.

Lifecycle:

- `active`: work in progress.
- `paused`: intentionally stopped but resumable.
- `completed`: requested work done and validation/review status recorded.
- `archived`: stale or no-longer-needed history.

```powershell
pwsh <plugin-root>/scripts/sympp-solo.ps1 show --session-id <id>
pwsh <plugin-root>/scripts/sympp-solo.ps1 complete --session-id <id>
```
