# Symphony++ System Specification

## Core concepts

### WorkRequest

A v2 pre-WorkPackage intake object. A WorkRequest captures the human's intended
project or repo, base branch, work type, description, constraints, and desired
dispatch shape before an architect slices the work into WorkPackages.

WorkRequests are persisted in the Symphony++ runtime ledger. The local operator
dashboard can list, create, inspect, clarify, and prepare architect handoff for
WorkRequests, while scoped board views can create and manage WorkRequests only
inside their frozen repo/base-branch scope. Architect MCP sessions with explicit
WorkRequest capabilities can read, clarify, record decisions, author planned
slices, and dispatch approved planned slices through the existing private worker
handoff flow.

This is still a manual architect-led flow. MCP WorkRequest intake tools,
automatic question generation, automatic slicing/planning, live Linear state
creation, richer plugin packaging, and automatic Codex spawning remain future
work.

### WorkPackage

The atomic unit of agent work. It can represent a phase PR, hotfix PR, quick issue, investigation, review-only task, or architect-created child package.

Important fields:

```text
id
kind
title
repo
base_branch
branch_pattern
product_description
engineering_scope
acceptance_criteria
status
parent_id
owner_id
created_at
updated_at
```

### SoloSession

A future local/private planning ledger for one caller, stable local session
key, and canonical workspace path. A SoloSession records task plan, finding, progress,
blocker, decision, and validation-note entries for normal single-agent Codex
work without creating WorkRequests, WorkPackages, grants, Linear state, worker
dispatch, architect handoff, or cockpit UI.

Important fields:

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

SoloSession statuses are `active`, `paused`, `completed`, and `archived`.
Active and paused sessions may later be archived as stale after about 30 days
through an explicit helper; this specification does not require a scheduler.
See `14_SOLO_SESSION_CONTRACT.md` for the product boundary, data model
direction, follow-up MCP/skill/cockpit affordances, and runtime rebuild
constraints.

### AccessGrant

A scoped authority object. Every agent action against Symphony++ must be backed by an AccessGrant.

Important fields:

```text
id
work_package_id or container_scope
display_key
secret_hash
role
capabilities
constraints
expires_at
claimed_at
bound_agent_run_id
revoked_at
created_at
```

### WorkKey

The user/agent-facing claim handle. The display key may be short, but the actual claim secret must be high entropy.

Agent-visible example:

```text
KRAKEN-HF-91C2#91C2
```

Actual one-time secret example:

```text
sympp_live_KRAKEN-HF-91C2_91C2_<high_entropy_secret>
```

### AgentRun

The runtime identity for a worker, architect, reviewer, or orchestrator session.

### Virtual planning files

Rendered Markdown resources backed by canonical state:

```text
sympp://work-packages/{id}/context.md
sympp://work-packages/{id}/task_plan.md
sympp://work-packages/{id}/findings.md
sympp://work-packages/{id}/progress.md
sympp://work-packages/{id}/acceptance.md
```

## State machines

### Standalone quick/hotfix package

```text
created
ready_for_worker
claimed
planning
implementing
reviewing
ci_waiting
ready_for_human_merge
merged
closed
blocked
abandoned
```

### Phase-child package

```text
created
ready_for_worker
claimed
planning
implementing
reviewing
ci_waiting
ready_for_architect_merge
merging_into_phase
merged_into_phase
closed
blocked
abandoned
```

## Permission rule

A grant may only mint child grants narrower than itself.

Examples:

- A worker grant cannot mint grants.
- A phase architect grant can mint worker grants inside the same phase.
- A phase architect grant cannot mint grants against `main` unless explicitly allowed.
- A standalone hotfix worker grant cannot read sibling packages.

## Read model

Workers receive:

- Their own work package.
- Their own virtual planning files.
- Explicit dependency/context slices.
- Their own PR/review state.

Workers do not receive:

- Sibling packages by default.
- Phase-wide private architect notes.
- Global grant lists.
- Raw secrets.

## Write model

Workers may:

- Update their own plan.
- Append their own findings/progress.
- Attach their own branch/PR/artifacts.
- Request context or scope expansion.
- Mark ready subject to gates.

Workers may not:

- Mark merged.
- Advance phase state.
- Mint grants.
- Reassign work.
- Expand scope silently.

## Readiness gates

A package cannot be marked ready if:

- It has active blockers.
- Required plan nodes are incomplete.
- Required review-suite artifacts are missing.
- Required PR is missing.
- CI is required and not green.
- Changed files violate allowed scope.
- Acceptance evidence is missing.

## Source of truth split

```text
Symphony++ ledger
  agent state, work packages, virtual planning files, permissions, readiness

GitHub
  code, branches, PRs, commits, CI, review status

Linear
  optional mirror for human/product/project visibility

Codex/Symphony
  execution of isolated agent runs
```

## v2 intake boundary

A clarified WorkRequest becomes one architect-owned plan plus one or more
planned slices. Approved slices can then be dispatched into WorkPackages through
the local operator dashboard, the planned-slice dispatch CLI, or the architect
MCP dispatch tool when the session has explicit dispatch scope. Existing
WorkPackage status, grants, virtual planning resources, readiness gates, review
evidence, and human merge rules remain authoritative after packages are
created.

If a worker hits ambiguity after dispatch, it asks the architect first. The
architect may consult ask-pro for hard architecture or product calls. If the
architect still cannot make a defensible decision from durable request context,
the package records `human_info_needed` instead of inventing product behavior.
