---
name: Symphony-work-package
description: Use when assigned a Symphony++ work key or WorkPackage. Keeps planning, findings, progress, PR links, and readiness synchronized through the Symphony++ MCP server.
---

# Symphony++ Work Package Workflow

You are working on a scoped Symphony++ WorkPackage.

## Rules

1. Start by calling `claim_work_key` with both the provided key/secret and a stable `claimed_by` worker identity.
2. Then call `get_current_assignment`.
3. Read:
   - `context.md`
   - `task_plan.md`
   - `findings.md`
   - `progress.md`
   - `acceptance.md`
   - `review_suite.md`
4. Do not create local `task_plan.md`, `findings.md`, or `progress.md` as the source of truth.
5. Before implementation, update the task plan.
6. After meaningful discovery, call `append_finding`.
7. After meaningful implementation, call `append_progress`.
8. If the required fix is outside scope, call `request_scope_expansion`.
9. Attach the branch and PR when created.
10. Before marking ready, ensure:
    - acceptance criteria are satisfied,
    - required tests/review suite were run,
    - progress is current,
    - findings are summarized,
    - no active blocker remains.
11. Never claim authority outside the assignment returned by Symphony++.
12. Never read or mutate sibling WorkPackages unless explicitly exposed by Symphony++ context.

`claimed_by` is required for the worker MCP API. Use the same identity for
reconnects; Symphony++ accepts reconnect only when the same owner identity
presents the same secret proof.

An explicit `state_key` only preserves initialized MCP handshake state. It does
not restore a claimed assignment, so reconnecting workers must call
`claim_work_key` again with the secret and same `claimed_by` identity.

After `mark_ready` succeeds, the package evidence is frozen. Do not attempt to
append new progress, findings, blockers, branch/PR metadata, scope requests, or
review packages unless replaying a previously recorded idempotent write.

## Handoff summary format

```markdown
## Handoff

WorkPackage: <id>
Status: <status>
PR: <url>
Head SHA: <sha>

### What changed

### Acceptance criteria evidence

### Tests run

### Findings / risks

### Follow-ups
```
