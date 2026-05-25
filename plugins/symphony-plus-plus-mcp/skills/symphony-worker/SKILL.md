---
name: symphony-worker
description: Use when spawned as an implementation worker expected to deliver a scoped task through implementation, validation, review, CI/static gates when present, and a merge-ready PR or explicit no-PR evidence packet.
---

# Symphony++ Worker

Use this skill when you are the implementing worker for a bounded task,
WorkPackage, or PR-sized assignment.

## Contract

1. Understand the assignment, owned paths, acceptance criteria, validation,
   review profile, branch/base target, stop conditions, and any line or PR-size
   budget before coding.
2. Track work in Symphony++:
   - Assigned WorkPackage or WorkKey: use
     `symphony-plus-plus-mcp:symphony-work-package`.
   - No WorkPackage: use `symphony-plus-plus:symphony-solo-session`.
3. Implement only the assigned scope.
4. Run required tests, static checks, CI/check status when present, Review
   Suite profile, and GitHub review when required.
5. Return a fully green, merge-ready PR, or a no-PR evidence packet for
   investigation/docs/read-only work.

## Scope Rules

- Stay inside owned files and the package boundary.
- Escalate product ambiguity, architecture ambiguity, dependency surprises,
  reviewer-driven scope creep, missing evidence, or line-budget risk to the
  calling architect/operator before broadening.
- If no line or PR-size budget is provided and the PR is becoming large, stop
  and ask for a split/continue decision.
- Do not invent product behavior just to satisfy a review.

## Validation And Review

- Run the focused tests first, then the broader validation requested by the
  assignment.
- If CI/checks exist, make sure they are green or report the exact blocked
  reason. If no CI exists, say so.
- Use the required Review Suite profile. After material changes, rerun the
  same required profile; do not step down to a lower review level.
- Treat GitHub review as a separate anchored review when the assignment
  requires it.
- Record validation and review evidence in the active Symphony++ state.

## Delivery

- For PR work, provide PR URL, changed files, tests run, review status,
  CI/check status, and residual risk.
- For no-PR work, provide direct evidence and say it should close as
  `completed_no_pr`, not `merged`.
- Workers do not record WorkRequest delivery closeout or mark product delivery
  merged/closed unless explicitly assigned that architect/operator duty.

## Safety

Never print, store, commit, or paste raw API keys, bearer tokens, GitHub tokens,
Linear tokens, MCP auth tokens, worker secrets, WorkKeys, grant verifiers,
private handoff payloads, or full secret-bearing commands.
