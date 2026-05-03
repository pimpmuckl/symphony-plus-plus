# SYMPP-P3-002 — Worker MCP tools and resources

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 3 — Agent interface |
| Kind | mcp |
| Owner role | worker |
| Dependencies | SYMPP-P3-001, SYMPP-P1-004, SYMPP-P1-005 |

## Summary

Implement scoped worker MCP tools/resources for claim, virtual planning files, progress, findings, PR attachment, blockers, and readiness.

## Implementation tasks

- Implement claim_work_key with required secret plus claimed_by owner identity.
- Implement get_current_assignment.
- Implement virtual planning file resources.
- Implement update_task_plan, append_finding, append_progress.
- Implement set_status/report_blocker/request_scope_expansion.
- Implement attach_branch(branch, head_sha)/attach_pr/mark_ready with readiness checks.
- Implement submit_review_package so `head_sha` is required on every submission and the latest current-head review package is authoritative for readiness.
- Add permission-denial tests.

## Acceptance criteria

- [ ] Worker can complete basic state lifecycle for own package.
- [ ] Worker cannot read or mutate sibling package.
- [ ] mark_ready enforces gates.
- [ ] All writes are actor/grant scoped and idempotent where appropriate.

## Test plan

### Unit tests

- Each tool success path.
- Each tool denial path.
- mark_ready fails without required artifacts.
- request_scope_expansion records request but does not approve.

### Integration / E2E tests

- Claim key then read resources and append updates.
- Create two packages; verify worker A cannot access worker B.
- Attach PR and attempt readiness.

### Negative / regression tests

- Worker cannot mark merged.
- Worker cannot mint grants.
- Worker cannot list all packages.

### Claim contract

Workers must call `claim_work_key(secret, claimed_by)`. The `claimed_by`
identity is required so reconnect ownership is explicit; reconnects are accepted
only for the same owner identity and secret proof.

Explicit `state_key` values are continuity metadata for initialized stateless
transports, not bearer capabilities. After reconnect initialize, workers must
call `claim_work_key(secret, claimed_by)` again before assignment-scoped tools
can run. The continuity namespace follows the active ledger, not a transient
dynamic repo process. Explicit state-key handshakes use a bounded retention
window longer than the current worker grant defaults and are not evicted by the
shorter implicit default response state TTL. They remain continuity metadata
until overwritten, cleared by a failed explicit reconnect initialize, or expired
by the explicit state-key retention window. A newer explicit initialize for the
same state key invalidates stale live sessions claimed before that initialize.
Implicit response-state continuity is for a single logical connection; a fresh
implicit `initialize` clears stored session state before any new worker claim.

`append_finding` idempotent retries replay by work package, idempotency key, and
matching finding content, including after worker grant renewal. The database
uniqueness boundary is also work-package scoped. Changed content or a changed
caller-supplied finding id returns `idempotency_conflict`.

JSON-RPC batch items are evaluated independently against the batch's initial
server/session state. Workers must not rely on `claim_work_key` or another
stateful tool in one batch item to authorize later items in the same batch. A
successful `claim_work_key` inside a batch still binds the returned server for
later standalone requests. After one claim succeeds in a batch, later
`claim_work_key` entries in that same batch are rejected as rebinding attempts
so a connection cannot claim multiple assignments.

### Review package contract

Workers must include `submit_review_package.head_sha` on every submission. The
latest review package for the current head is authoritative for readiness;
older same-head packages are superseded. `tests` and `artifacts` values are
trimmed before persistence and default idempotency-key calculation. Exact
idempotent retries of an already recorded review package replay the original
success even after the branch head moves, but replayed older-head evidence is
stale for readiness and does not satisfy merge/readiness gates.

The latest attached branch head is the worker-declared current code head. PR
metadata must match that head for merge readiness; stale PR metadata does not
move readiness back to an older commit. Merge-gated review packages require an
attached current branch head and must bind to that head.

For non-merge-gated package policies such as `quick_fix`, workers can satisfy
focused-test and review-lane gates with generic `append_progress.status` values
`tests_passed` and `<review_lane>_green`. Tool-owned metadata, blocker, status,
and scope events do not satisfy those fallback gates. Non-merge policies that
do not require branch metadata may also count explicit-head
`submit_review_package` evidence before a branch head is attached. Merge-gated
package policies still use current-head review package evidence and review
artifacts. After a branch head is attached, fallback progress and review-package
evidence must be current to the latest branch head. Fallback progress gates use
the latest relevant generic status for the current head; later failing/red
evidence supersedes earlier green evidence until a newer pass/green status is
recorded.

After `mark_ready` succeeds, worker evidence writes for the package are frozen;
new progress, findings, blockers, branch/PR metadata, scope requests, and review
packages return `already_ready`. Investigation packages use
`request_scope_expansion` as the worker's recorded scope recommendation evidence;
the request itself does not approve any expanded scope. Generic `append_progress`
payloads do not satisfy the investigation recommendation gate.

## Deliverables

- Implementation PR for `SYMPP-P3-002`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P3-002: Worker MCP tools and resources.

Read this package spec fully. Implement only this package's scope. Do not implement dependent packages. If you discover that the package requires broader scope, stop and request scope expansion with a concrete reason.

Before coding:
1. Inspect the current repository state.
2. Confirm the dependency packages are merged or available.
3. Create a brief implementation plan.

During coding:
1. Keep changes limited to this package.
2. Add or update tests from the package test plan.
3. Preserve existing Symphony behavior unless this package explicitly changes it.

Before PR:
1. Run the relevant tests.
2. Verify every acceptance criterion is satisfied or explain any exception.
3. Write a PR summary with test results and risk notes.

Package dependencies: SYMPP-P3-001, SYMPP-P1-004, SYMPP-P1-005.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
