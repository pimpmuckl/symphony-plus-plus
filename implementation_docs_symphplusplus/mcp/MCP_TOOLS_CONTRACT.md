# MCP Tools Contract

This document mirrors `mcp_tools_contract.json` in readable form.

## Worker tools

| Tool | Purpose |
|---|---|
| claim_work_key | Claim a one-time work key/secret with required `claimed_by` owner identity and bind it to the current worker session. |
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

`claim_work_key` requires `secret` and `claimed_by`. Reconnects are accepted
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
state-key retention window.

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
current head and older review-package evidence is stale. Merge-gated packages
still use current-head `submit_review_package` evidence and persisted review
artifacts. When a branch head is attached, fallback progress evidence must be
recorded after the latest branch head attachment.

For investigation policies, `request_scope_expansion` records the required
scope recommendation evidence but never approves the expansion itself. Generic
`append_progress` payloads do not satisfy this recommendation gate.
