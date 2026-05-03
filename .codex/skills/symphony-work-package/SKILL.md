---
name: symphony-work-package
description: Use when assigned a Symphony++ work key or WorkPackage; keeps scoped planning, findings, progress, branch/PR metadata, review evidence, and readiness synchronized through the Symphony++ MCP server.
---

# Symphony++ Work Package

Use this skill when a Symphony++ assignment provides a work key, WorkPackage id,
or Symphony++ MCP server context.

## Start

1. Claim the assignment with `claim_work_key(secret, claimed_by)`.
2. Use the same stable `claimed_by` identity for reconnects.
3. Call `get_current_assignment()` and treat the returned WorkPackage as the
   only authority for scope.
4. Read the virtual planning resources before implementation:
   - `read_context()`
   - `read_task_plan()`
   - `sympp://work-packages/{id}/findings.md`
   - `sympp://work-packages/{id}/progress.md`
   - `sympp://work-packages/{id}/acceptance.md`
   - `sympp://work-packages/{id}/review_suite.md`
   - `sympp://work-packages/{id}/handoff.md`

Do not create local `task_plan.md`, `findings.md`, or `progress.md` files as
the source of truth for the WorkPackage. Local scratch notes are only temporary
process aids when the operator explicitly asks for them.

## Work Loop

- Update the virtual plan with `update_task_plan(patch, expected_version)`
  before implementation and after meaningful plan changes.
- Record durable discoveries with `append_finding(finding, idempotency_key)`.
- Record meaningful implementation and validation events with
  `append_progress(event, idempotency_key)`.
- Use `report_blocker(summary, idempotency_key, blocker_id?)` for active
  blockers.
- Use `resolve_blocker(blocker_id, resolution, summary, idempotency_key)` once
  the blocker is cleared.
- Use `set_status(status, reason, expected_status)` for allowed non-ready
  lifecycle transitions.
- Use `request_scope_expansion(summary, idempotency_key, payload)` when the
  needed work exceeds the assignment. This records a request; it does not
  approve the expansion.
- Stay inside the assigned WorkPackage. Do not inspect or mutate sibling
  WorkPackages unless Symphony++ exposes a specific context slice.

## Branch, PR, And Review Evidence

- Attach the implementation branch with `attach_branch(branch, head_sha)`.
- Attach the PR with `attach_pr(url, head_sha)` after it exists.
- Submit review evidence with
  `submit_review_package(summary, tests, artifacts, head_sha)`.
- Include review lane verdicts in the review package when the package policy
  requires them.
- Always use the current branch head SHA. Older review evidence can replay for
  lost-response stability, but readiness evaluates against the current head.

## Ready Gate

Before calling `mark_ready()`:

- Acceptance criteria are satisfied or explicitly blocked.
- Required tests and review lanes are complete.
- Virtual task plan, findings, and progress are current.
- Branch, PR, and review artifacts are attached when the policy requires them.
- No active blocker remains.

After `mark_ready()` succeeds, evidence is frozen. Do not append new progress,
findings, blockers, branch/PR metadata, scope requests, or review packages
unless replaying a previously recorded idempotent write.

## Permission Model

- Prompts, skills, hooks, and dashboards are workflow aids; the MCP server is
  the permission boundary.
- Worker grants are scoped to exactly one WorkPackage.
- Worker grants cannot mint keys, approve scope expansion, merge PRs, advance
  phase state, or use architect tools.
- Never print, store, or commit raw grant secrets, bearer tokens, GitHub tokens,
  Linear tokens, MCP auth tokens, full secret-bearing claim URLs, or grant
  verifiers.

## Reconnect Notes

`state_key` preserves initialized MCP handshake continuity only. It is not a
bearer capability and does not restore claimed worker authorization. After
reconnect initialize, call `claim_work_key(secret, claimed_by)` again with the
same owner identity.

## References

- `references/worker_prompt.md` has a paste-ready worker prompt.
- `references/mcp_wiring.md` describes the MCP dependency wiring.
- `references/handoff.md` has the final handoff format.
