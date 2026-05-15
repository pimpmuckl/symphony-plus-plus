# Solo Session Product Contract

Solo Session Mode is a lightweight Symphony++ local planning layer for normal
single-agent Codex work. It gives one caller a durable task plan, findings log,
progress log, blocker list, decision record, and validation notes without
creating a WorkRequest, WorkPackage, Linear record, architect handoff, or worker
dispatch.

This document is the product contract for the Solo Session runtime foundation.
The current CLI surface is `mix sympp.solo` in `elixir/`; MCP tools, plugin or
skill commands, cockpit UI, schedulers, and promotion workflows are follow-up
scope.

## Purpose

A Solo Session records one local caller's planning memory for one repo and
worktree/workspace. It is intended to replace ad hoc `planning-with-files` usage
for ordinary single-agent sessions once the runtime and tooling exist.

Use Solo Session Mode when the caller needs durable local memory for:

- Task plan entries.
- Findings.
- Progress notes.
- Blockers.
- Decisions.
- Validation notes.

Solo Session Mode is not an orchestration layer. It does not decide scope,
slice work, assign agents, create PRs, mark merge readiness, or coordinate
multiple workers.

## Non-Goals

Solo Session v1 does not include:

- Architect handoff or architect-owned planning.
- Worker dispatch, child-worker creation, or multi-agent control.
- Work slicing, phase planning, PR orchestration, or merge-readiness gates.
- Linear state creation, mutation, or mirroring.
- Access grants, worker secrets, private handoff payloads, or WorkKeys.
- WorkRequest or WorkPackage semantic changes.
- MCP Solo Session tools or resources.
- Plugin or skill command wiring.
- Local cockpit UI implementation.
- Background schedulers.

Solo Sessions must stay separate from WorkRequest and WorkPackage
orchestration. They must not alter existing WorkRequest, WorkPackage,
AccessGrant, MCP, dashboard, Linear, readiness, review, or dispatch behavior.

## Lifecycle

Solo Session lifecycle is intentionally small:

```text
active
paused
completed
archived
```

Expected transitions:

- `active` to `paused`, `completed`, or `archived`.
- `paused` to `active`, `completed`, or `archived`.
- `completed` to `archived`.
- `archived` is terminal.

`active` means the session is the current planning memory for a matching local
scope. `paused` keeps the session attachable but not currently being advanced.
`completed` records that the work ended and should not be reattached as the
current mutable session. `archived` keeps the history readable while excluding
the session from current-session attachment and new entry writes.

Do not add orchestration states such as `claimed`, `reviewing`,
`ready_for_merge`, `dispatching`, or `human_info_needed` to Solo Sessions.

## Session Scope

A Solo Session is scoped to a single local caller/session/worktree shape:

```text
id
repo
base_branch
workspace_path
caller_id
session_key
title
status
last_activity_at
archived_at
created_at
updated_at
```

`id` is the durable Solo Session identifier. The current-session lookup scope
for a caller is:

```text
repo
base_branch
workspace_path
caller_id
```

`workspace_path` is the canonical local location key. Callers may discover that
location from a worktree path, repository root, or workspace path, but storage
and uniqueness use one normalized absolute workspace path value after resolving
case, separators, symlinks where practical, and trailing separators according
to the host filesystem.

At most one `active` or `paused` Solo Session may exist for one lookup scope.
Concurrent create/attach calls for the same lookup scope must converge on that
single non-terminal record instead of splitting planning history.

Attaching with the same lookup scope should return the existing active or
paused session. Completed or archived sessions are historical records; a later
attach with the same lookup scope creates a new active session.

`session_key` is the stable local planning identity stored on the Solo Session
record after creation. It is product-owned local metadata, not a raw Codex
thread ID or throwaway run ID, and callers do not need to know it before
current-session attach. A volatile per-thread or per-run key may be recorded as
attachment metadata, but it is not part of the uniqueness scope.

The stable `session_key` must not be a bearer token, raw WorkKey, API key, MCP
auth token, GitHub token, Linear token, worker secret, or private handoff
payload.

`idempotency_key` values are also part of the secret-handling boundary. If an
idempotency key looks like a bearer token, raw WorkKey, API key, MCP auth token,
GitHub token, Linear token, worker secret, or private handoff payload, reject it
before persistence. Rejected idempotency keys do not create entries and do not
advance `last_activity_at`.

## Ledger Entries

Solo Session history is append-only. The canonical model is a normalized ledger
of entries rather than separate mutable files:

```text
id
solo_session_id
entry_kind
title
body
status
sequence
idempotency_key
payload
created_at
updated_at
```

Initial entry kinds:

```text
task_plan
finding
progress
blocker
decision
validation_note
```

Sequences are allocated by the repository per session. Callers may provide an
`idempotency_key`; repeated appends with the same accepted key for the same
session return the existing entry instead of creating a duplicate. Secret-like
idempotency keys are rejected before persistence instead of being stored raw or
redacted into a value that would break retry comparison.

Any future Markdown rendering of `task_plan.md`, `findings.md`, and
`progress.md` equivalents is a view of the ledger, not a second source of
truth.

## Privacy And Safety

Solo Sessions are local/private by default. They must not store raw API keys,
bearer tokens, GitHub tokens, Linear tokens, MCP auth tokens, worker secrets,
raw WorkKeys, access grants, secret hashes, or private handoff payloads as
structured fields.

Free-text entries are still a disclosure surface. Implementations must redact
or reject secret-like values before persistence and before rendering entries
through UI, MCP, plugin, skill, export, or log surfaces. Returned data should be
safe text or JSON-safe redacted data.

If validation depends on a secret, record the validation as blocked, externally
verified, or requiring operator action. Do not paste raw secret values into Solo
Session entries.

## Stale And Archive Behavior

Solo Session v1 should include a minimal archive helper direction, not an
immediate scheduler requirement. The helper archives `active` or `paused`
sessions whose `last_activity_at` is older than a configured threshold. The
default product expectation is roughly 30 days.

`last_activity_at` advances only when the session is created, an active or
paused session is attached as current, an entry append succeeds, or a lifecycle
transition changes status. Pure read, list, render, failed append, rejected
idempotency key, and no-op lifecycle requests do not advance `last_activity_at`.
No-op lifecycle requests also do not mutate lifecycle timestamps just to record
activity.

Archiving sets:

```text
status = archived
archived_at = current time
updated_at = current time
```

Archived sessions remain readable, cannot be reattached as current sessions,
and cannot receive new entries. Future cockpit, CLI, MCP, or maintenance
packages may call the helper explicitly.

## Cockpit Direction

Future cockpit support should expose a small Solo/Local Sessions surface:

- Per-repo visibility by default.
- List active, paused, completed, and archived local sessions.
- Show session details and ordered ledger entries.
- Keep Solo Sessions visually separate from WorkRequests and WorkPackages.
- Avoid cluttering the main WorkRequest/WorkPackage flow.

Solo Session records may be useful operator context, but they must not appear
as merge-readiness records, dispatched packages, or architect boards.

## MCP And Skill Direction

Follow-up MCP/plugin/skill affordances should be small and local:

- Create or attach the current Solo Session for the local repo/worktree scope.
- Read the current Solo Session and recent entries.
- Append task plan, finding, progress, blocker, decision, and validation-note
  entries.
- Pause, resume, complete, or archive the current session.
- Render planning-file-like views from the ledger.

These affordances must not claim WorkKeys, mint grants, create WorkRequests,
create WorkPackages, dispatch agents, or write Linear state.

## Mix CLI Surface

The first agent-facing surface is the `mix sympp.solo` task. Successful command
output is JSON; failures exit non-zero with normal `Mix.Error` messages. It is
a local operator tool over the existing Solo Session repository and service; it
does not add orchestration semantics.

Supported commands:

- `attach` creates or attaches the current session for `repo`, `base_branch`,
  `workspace_path`, and `caller_id`, with optional `title`.
- `append` records one `task_plan`, `finding`, `progress`, `blocker`,
  `decision`, or `validation_note` entry by `session_id`.
- `show` returns the session and ordered entries.
- `list` returns sessions filtered by local scope fields and status.
- `pause`, `resume`, `complete`, and `archive` call the lifecycle transition
  API for a session.

All commands accept `--database <sqlite-path>`. When `--database` is omitted,
the task resolves the current project `WORKFLOW.md` database path and fails
before ledger access if that file is unavailable. The resolved database must be
a durable local filesystem path; `:memory:` and SQLite `file:` URIs are
rejected because Solo Sessions must persist across separate CLI invocations.
`attach` may create the ledger database; `append`, `show`, `list`, and
lifecycle aliases require the resolved local database file to already exist.
The CLI uses the service redaction, idempotency, lifecycle, and validation
behavior directly.

## Future Promotion

A future package may add explicit promotion from a Solo Session into a
WorkRequest or WorkPackage. Promotion is optional, operator-visible, and not in
v1.

Promotion must be reviewable. A Solo Session must never silently become a
WorkRequest, WorkPackage, Linear issue, agent dispatch, architect handoff, PR
readiness record, or merge gate.

## Runtime Rebuild Constraints

When runtime implementation resumes, the first runtime PR should incorporate
the review lessons from the frozen Solo Session branch:

- Design create/attach for concurrent callers against the same local scope.
- Replay idempotent appends in a fresh transaction so stale transaction state
  does not leak into retry results.
- Allocate IDs, statuses, timestamps, and lifecycle fields server-side; callers
  must not own them.
- Reject secret-like idempotency keys and reject or redact secret-like free
  text before persistence.
- Keep list/read filters trimmed to the Solo Session scope fields and status;
  do not add broad orchestration filters.
- Avoid no-op lifecycle timestamp mutation. If a requested lifecycle transition
  leaves the status unchanged, do not mutate lifecycle timestamps just to record
  activity.

These are implementation constraints for follow-up runtime work. They do not
authorize runtime, migration, MCP, plugin, skill, cockpit, Linear, or
orchestration changes in this docs-only package.
