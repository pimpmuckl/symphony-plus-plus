# Dashboard Specification

## Goal

Give the human overseer fast situational awareness without reading agent transcripts.

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
