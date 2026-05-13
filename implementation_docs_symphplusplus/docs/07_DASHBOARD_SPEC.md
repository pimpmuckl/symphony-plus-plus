# Dashboard Specification

## Goal

Give the human overseer fast situational awareness without reading agent transcripts.

## Local Operator Mode

Start the local operator cockpit from `elixir/` with:

```powershell
mix sympp.cockpit --database <ledger.sqlite3>
```

The launcher binds to `127.0.0.1` and an OS-assigned port by default, prints
the exact `/sympp/board` URL, enables `sympp_local_operator: true`, and keeps
the process running until interrupted. Omit `--database` to use the default
Symphony++ ledger for the current workflow.

When the Phoenix endpoint is configured with `sympp_local_operator: true`, the
local browser dashboard can open `/sympp/board` as a read-only operator cockpit
without first entering a board work key. This mode is for the human machine
owner inspecting local Symphony++ state.

Local operator mode:

- requires a direct loopback request to a local host name with browser Fetch
  Metadata;
- rejects forwarded/proxy headers for operator entry;
- renders redacted dashboard projections only;
- keeps WorkRequest mutation controls hidden and server-side scoped to board
  grants;
- preserves explicit `?auth=work_key` paths for grant-scoped board and package
  views.

This is not a worker/agent permission grant. Worker and architect write access
still comes from scoped work keys and MCP grants.

## Views

### Board view

Columns:

```text
created
ready_for_worker
claimed
planning
implementing
reviewing
ci_waiting
ready_for_human_merge
ready_for_architect_merge
merged
blocked
abandoned
```

Card fields:

```text
WorkPackage ID
Title
Kind
Repo/base branch
Assigned agent run
Last progress timestamp
PR link
CI/review status
Active blocker count
Scope guard status
Plan completion
```

### Work package detail

Sections:

```text
Overview
Product outcome
Engineering scope
Acceptance criteria
Virtual task plan
Findings
Progress timeline
Artifacts
Branch/PR state
Review-suite state
Grant/agent run state
Controls
```

Controls should start minimal:

```text
Pause package
Revoke grant
Request replan
Approve/deny scope expansion
Mark abandoned
```

Do not add dangerous controls like merge-to-main until Phase 7+ and branch protection is proven.

### Runtime view

Show:

```text
Active runs
Queued packages
Retry state
Last heartbeat
Workspace path
Orchestrator events
Recent failures
```

## Readiness indicators

Use distinct indicators for:

```text
Agent says ready
Review suite says ready
GitHub says ready
Architect says ready
Human says ready
```

Do not collapse these into one boolean.
