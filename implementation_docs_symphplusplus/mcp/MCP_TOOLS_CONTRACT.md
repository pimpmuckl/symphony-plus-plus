# MCP Tools Contract

This document mirrors `mcp_tools_contract.json` in readable form.

## Worker tools

| Tool | Purpose |
|---|---|
| claim_work_key | Claim a one-time work key/secret with required `claimed_by` owner identity and bind the current MCP session to the grant role. |
| get_current_assignment | Return the scoped assignment for the bound grant. |
| read_context | Read context.md for the current work package. |
| read_task_plan | Read task_plan.md for the current work package. |
| update_task_plan | Patch the plan with optimistic concurrency. |
| append_finding | Append a finding to the current work package. |
| append_progress | Append a progress event to the current work package. |
| set_status | Request a valid state transition. |
| report_blocker | Record an active blocker. |
| request_scope_expansion | Request broader scope; does not approve it. |
| attach_branch | Attach branch metadata with the current branch head SHA. |
| attach_pr | Attach PR metadata. |
| submit_review_package | Attach summary/tests/artifacts for the current head review package. |
| mark_ready | Move to ready state only if gates pass. |

## Architect tools

| Tool | Purpose |
|---|---|
| create_child_work_package | Phase 7 stub for creating phase-scoped child work; returns `phase7_not_implemented` after architect authorization. |
| mint_child_worker_key | Phase 7 stub for minting child worker keys; returns `phase7_not_implemented` after architect authorization. |
| revoke_child_worker_key | Phase 7 stub for revoking child worker keys; returns `phase7_not_implemented` after architect authorization. |
| read_child_status | Read the architect grant's scoped work-package status without Phase 7 delegation. |
| read_phase_board | Phase 7 stub for phase board reads; returns `phase7_not_implemented` after architect authorization. |
| request_child_replan | Phase 7 stub for child replan requests; returns `phase7_not_implemented` after architect authorization. |
| approve_child_ready_state | Phase 7 stub for child readiness approval; returns `phase7_not_implemented` after architect authorization. |
| merge_child_into_phase | Phase 7 stub for merge-to-phase recording; returns `phase7_not_implemented` after architect authorization. |
| split_work_package | Phase 7 stub for child package splitting; returns `phase7_not_implemented` after architect authorization. |
| publish_phase_update | Phase 7 stub for phase updates; returns `phase7_not_implemented` after architect authorization. |

Architect tools require a live architect grant session and the matching
architect capability from the permission model. Worker grants and architect
grants without the required capability are denied. Worker grants cannot be
minted with architect-only MCP capabilities such as `read:phase`,
`read:child_progress`, or `mint:child_worker_key`. `tools/list` advertises
architect tools only for an already-bound architect session; anonymous and
worker sessions see the worker tool surface. Until Phase 7 introduces phase
entities and phase-child scope checks, `read_child_status` requires both
`read:child_progress` and `read:child_findings` because its summary includes
progress, findings, and artifact counts, and it is intentionally limited to the
work package bound to the architect grant. Requests for unrelated work packages
are denied rather than guessed from absent phase relationships.
Phase 7-dependent tools perform authorization first and then return an explicit
`phase7_not_implemented` error; they do not create children, mint grants,
approve readiness, merge phase artifacts, or publish phase state in P3-003.

## Resources

```text
sympp://assignment/current
sympp://work-packages/{id}/context.md
sympp://work-packages/{id}/task_plan.md
sympp://work-packages/{id}/findings.md
sympp://work-packages/{id}/progress.md
sympp://work-packages/{id}/acceptance.md
sympp://work-packages/{id}/review_suite.md
sympp://work-packages/{id}/handoff.md
```

`claim_work_key` requires `secret` and `claimed_by`. It can bind an existing
worker or architect grant; it does not mint new grants. Reconnects are accepted
only when the same owner identity presents the same secret proof.

Explicit `state_key` values retain initialized handshake continuity for
stateless transports, but they do not restore claimed worker sessions. A
reconnecting worker must call `claim_work_key(secret, claimed_by)` again. The
continuity namespace is the active ledger, so a reconnect to the same SQLite
ledger can restore handshake state even when the dynamic repo process changes.
Explicit state-key handshakes use a bounded retention window longer than the
current worker grant defaults and are not evicted by the shorter implicit
default response-state TTL. They remain continuity metadata until overwritten,
cleared by a failed explicit reconnect initialize, or expired by the explicit
state-key retention window. A newer explicit initialize for the same state key
invalidates stale live sessions that were claimed before that initialize.
Duplicate initialize on the same active explicit-state connection is still
rejected as already initialized and does not clear the live session.
Implicit response-state continuity is for a single logical connection; a fresh
implicit `initialize` clears stored session state before any new worker claim.

`append_finding` idempotency is work-package scoped, including at the database
uniqueness boundary, for retry stability. A
matching idempotency key and finding content replays the original success even
after worker grant renewal; changed content or a changed caller-supplied finding
id returns `idempotency_conflict`.

JSON-RPC batch items are not an ordered session transaction. Each item is
evaluated against the batch's initial server/session state, so workers must not
rely on `claim_work_key` or any other stateful call in one batch item to
authorize later items in the same batch. A successful `claim_work_key` inside a
batch still binds the returned server/session for later standalone requests.
After one claim succeeds in a batch, later `claim_work_key` entries in that
same batch are rejected as rebinding attempts so a connection cannot claim
multiple assignments.

`attach_branch` requires `branch` and `head_sha`. When no PR head is attached,
review packages are matched to the latest attached branch head so stale
branch-only reviews cannot satisfy readiness after new commits. If branch and
PR metadata disagree, the latest branch head remains the current code head and
merge readiness waits for PR metadata for that head.

`submit_review_package` requires explicit `head_sha` on every submission. For
merge readiness, review packages require an attached current branch head, and
the latest review package for that current head is authoritative; older
packages for that same head are superseded. Exact idempotent retries of an
already recorded review package replay the recorded success even if the branch
head has since advanced, but that replayed older-head evidence remains stale
for readiness and does not satisfy merge/readiness gates. `tests` and
`artifacts` entries are trimmed before persistence and default idempotency-key
calculation.

Once `mark_ready` succeeds, worker evidence for that package is immutable: new
progress, finding, blocker, branch/PR, scope-request, and review-package writes
return `already_ready`, while idempotent replays of previously recorded writes
remain available.

For non-merge-gated policies such as `quick_fix`, generic `append_progress`
events can satisfy focused-test and review-lane readiness by recording statuses
`tests_passed` and `<review_lane>_green`, for example `review_t1_green`.
Tool-owned metadata, blocker, status, and scope events are ignored for these
fallback gates. Non-merge policies that do not require branch metadata may also
count explicit-head `submit_review_package` evidence before a branch head is
attached. Once a branch head is attached, readiness is evaluated against that
current head and older review-package evidence is stale. Fallback progress gates
use the latest relevant generic status after the current branch head attachment:
later `tests_failed`, `<review_lane>_red`, or `<review_lane>_failed` evidence
supersedes earlier green evidence until a newer pass/green status is recorded.
Merge-gated packages still use current-head `submit_review_package` evidence and
persisted review artifacts.

For investigation policies, `request_scope_expansion` records the required
scope recommendation evidence but never approves the expansion itself. Generic
`append_progress` payloads do not satisfy this recommendation gate.
