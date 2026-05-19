# MCP Tools Contract

This document mirrors `mcp_tools_contract.json` in readable form.

## Worker tools

| Tool | Purpose |
|---|---|
| claim_work_key | Claim a one-time work key/secret with required `claimed_by` owner identity and bind the current MCP session to the grant role for temporary bootstrap/recovery. |
| get_current_assignment | Return the scoped assignment for the bound grant. |
| read_context | Read context.md for the current work package. |
| read_task_plan | Read task_plan.md for the current work package. |
| update_task_plan | Patch the plan with optimistic concurrency. |
| append_finding | Append a finding to the current work package. |
| append_progress | Append a progress event to the current work package. |
| set_status | Request a valid state transition. |
| report_blocker | Record an active blocker. |
| resolve_blocker | Record that an active blocker was cleared. |
| request_scope_expansion | Request broader scope; does not approve it. |
| attach_branch | Attach branch metadata with the current branch head SHA. |
| attach_pr | Attach PR metadata. |
| sync_pr | Refresh metadata for the already attached PR. |
| submit_review_package | Attach summary/tests/artifacts for the current head review package. |
| mark_ready | Move to ready state only if gates pass. |

## Architect tools

| Tool | Purpose |
|---|---|
| create_child_work_package | Create a `phase_child` work package inside the architect grant's current phase; child repo, phase, parent, and base branch are constrained to the architect phase anchor. |
| mint_child_worker_key | Mint a child-scoped worker grant for a same-phase `phase_child` package; worker capabilities are limited to the child worker set and expiry cannot exceed the architect grant. |
| revoke_child_worker_key | Revoke one live child-delegated worker grant for a same-phase child package inside the architect grant's frozen scope, reset active/interrupted children to `ready_for_worker`, and make immediate remint available. |
| list_work_requests | List WorkRequests scoped to the architect assignment repo/base branch. Accepts only optional `status`. |
| read_work_request | Read one scoped WorkRequest with clarification questions, decision log entries, planned slices, and count/status summaries. |
| set_work_request_status | Move a scoped WorkRequest between valid statuses with optimistic `current_status` checking. |
| ask_work_request_question | Add a clarification question to a scoped WorkRequest, optionally with a structured human decision prompt. |
| answer_work_request_question | Answer an open clarification question that belongs to a scoped WorkRequest. |
| close_work_request_question | Close an open clarification question that belongs to a scoped WorkRequest without recording an answer. |
| record_work_request_decision | Record a durable decision log entry on a scoped WorkRequest. |
| add_work_request_planned_slice | Add a planned slice to a scoped WorkRequest. |
| approve_work_request_planned_slice | Approve a planned slice that belongs to a scoped WorkRequest. |
| skip_work_request_planned_slice | Skip a planned slice that belongs to a scoped WorkRequest. |
| mark_work_request_sliced | Mark a scoped WorkRequest sliced using the existing approved-slice requirement. |
| dispatch_work_request_planned_slice | Dispatch one approved planned slice into a WorkPackage and private worker handoff. |
| read_child_status | Read the architect grant's scoped anchor package status, or a same-phase child work-package status when the architect grant has child read capabilities. |
| read_phase_board | Read the architect grant's scoped phase board, filtered to the frozen repo/base branch for explicit phase grants, including merged-child phase progress. |
| request_child_replan | Phase 7 stub for child replan requests; returns `phase7_not_implemented` after architect authorization. |
| approve_child_ready_state | Approve a same-phase `phase_child` in `ready_for_architect_merge` after readiness gates still pass; records a local audit event and moves the child to `merging_into_phase`. Optional `request_id` is the explicit retry identity. |
| merge_child_into_phase | Record a local merge artifact for an approved phase child and move it to `merged_into_phase`; does not perform a live Git merge. |
| split_work_package | Phase 7 stub for child package splitting; returns `phase7_not_implemented` after architect authorization. |
| publish_phase_update | Phase 7 stub for phase updates; returns `phase7_not_implemented` after architect authorization. |

Architect tools require a live architect grant session and the matching
architect capability from the permission model. Worker grants and architect
grants without the required capability are denied. Worker grants cannot be
minted with architect-only MCP capabilities such as `read:phase`,
`read:child_progress`, or `mint:child_worker_key`. `tools/list` advertises
architect tools only for an already-bound architect session and filters them to
the live grant's capabilities. Unbound generic sessions expose only health,
Solo Session tools, and `claim_work_key` as the temporary bootstrap/recovery
tool for explicit stdio WorkPackage flows; they do not see the worker mutation
surface. Stale bound sessions expose only health and `claim_work_key` for
refresh. Worker sessions see the bound worker-facing discovery surface without
Solo tools. Architect sessions may call
`get_current_assignment` and read `sympp://assignment/current` to recover their
scoped `work_package_id` after reconnect, but architect sessions still cannot
use worker package read/write tools. Phase-board readers are limited to the
session's phase scope; explicit phase grants with a frozen repo/base snapshot
materialize only matching package cards across MCP, API, and browser board
surfaces, and explicit phase grants missing that snapshot fail closed rather
than being treated as phase-wide. Existing lifecycle
capabilities such as
`architect:lifecycle.transition` do not imply MCP architect tool capabilities;
P3-003 requires the explicit MCP capability strings listed in the permission
model. WorkRequest read, mutation, and dispatch tools are advertised only for explicit phase-scoped
architect grants with usable frozen repo/base-branch scope; legacy
null-`phase_id` architect grants do not discover those tools. WorkRequest
mutation tools use the same explicit phase-scoped discovery rule and additionally
require `write:work_request`; planned-slice dispatch additionally requires
`dispatch:work_request`. Phase-dependent
architect tools revalidate the grant's explicit phase scope plus the anchor
repo/base-branch scope frozen when the phase architect grant was minted.
Legacy null-`phase_id` grants may still derive the current
explicit anchor phase for non-delegation phase reads, but P7 child
delegation/status operations fail closed when the frozen repo/base-branch
snapshot is missing. `create_child_work_package` always creates a `phase_child`
package under the architect phase anchor, rejects mismatched `phase_id`,
`parent_id`, `repo`, or `base_branch`, inherits the anchor base branch because
there is no separate phase base-branch policy field, requires concrete nonempty
child file globs, and revalidates anchor scope in the insert transaction. Empty
anchor file globs are allowed only when the child explicitly supplies nonempty,
non-overbroad globs; nonempty anchor globs remain the upper bound. It does not
support context-slice input in this contract. `mint_child_worker_key` only mints
single-package worker grants for same-phase child packages; the minted worker
grant cannot include architect capabilities, cannot include capabilities outside
the child worker capability set, rejects new mints while any active
child-delegated worker grant already exists for that child, ignores unrelated
normal worker grants, and cannot outlive the transaction-current architect
grant. This is the pre-production v1 contract and does not provide implicit
replacement/remint behavior. The tool stores the newly minted child worker
secret through the private SecretHandoff store and returns only redacted
metadata under `worker_grant.secret_handoff`; `worker_grant.secret_in_response`
is always `false`, and `secret` / `secret_returned_once` are not part of the
response. Returned handoff metadata includes non-secret bootstrap fields,
including the resolved `claimed_by` identity and `run_mcp_command` when
generated by SecretHandoff; those fields must not embed the raw worker secret.
The MCP server must be configured with `repo_root`/`--repo-root` before child
minting so handoff scripts are resolved from an operator-chosen repository root;
minting fails before grant creation if the expected handoff script is missing
there. `template.secret_handoff` may specify only `mode`, `store_dir`, and
`claimed_by`; unexpected fields or blank values are rejected and do not alter
worker-grant capabilities. `revoke_child_worker_key` requires
`revoke:child_worker_key`, revalidates the live architect grant and frozen
phase anchor scope, and revokes only a live child-delegated worker grant for a
same-phase child package. If the child is active/interrupted (`claimed`,
`planning`, `implementing`, `reviewing`, `ci_waiting`, or `blocked`), the tool
resets it to `ready_for_worker` so `mint_child_worker_key` can immediately
remint. It rejects unrelated grants, normal worker grants, sibling/out-of-scope
children, already revoked or expired grants, and children already in
architect-controlled/closed/merged or terminal states. The response and durable
audit/progress event are redacted and include only safe child package/grant
metadata, previous and new child statuses, and the redacted recycle reason;
persisted private handoff cleanup is not performed in this v1 package.
`list_work_requests` and `read_work_request` require `read:work_request`, are
read-only, and require an explicit phase-scoped architect grant with frozen
repo/base-branch scope. They do not accept caller-supplied repo or base-branch
arguments. Legacy null `phase_id` architect grants are not supported for
WorkRequest MCP reads and fail closed rather than deriving scope from a mutable
anchor package. `list_work_requests` accepts only optional `status`;
`read_work_request` requires `work_request_id`. Missing or out-of-scope
WorkRequests fail closed as not found without leaking sibling content. Payloads
are JSON-safe and redacted: they exclude work-key secrets, tokens, private
handoff payloads, and worker secret material.
`set_work_request_status`, `ask_work_request_question`,
`answer_work_request_question`, `close_work_request_question`, and
`record_work_request_decision` require `write:work_request`, the same explicit
phase-scoped frozen repo/base-branch scope, and `work_request_id` on every
mutation. They do not accept caller-supplied repo or base-branch arguments.
Answer and close calls also verify that `question_id` belongs to the scoped
WorkRequest before mutating and fail closed as not found for sibling questions.
Responses return JSON-safe redacted updated question or decision objects plus a
minimal parent WorkRequest status projection and scope/status metadata; they do
not return the full `read_work_request` detail shape. These tools cover only
the clarification and decision loop; they do not author, approve, skip, or
dispatch planned slices, create WorkPackages, alter SecretHandoff, mutate
Linear, or change dashboard behavior. They expose the existing WorkRequest
service primitives: status movement is explicit through
`set_work_request_status`, and question/decision tools do not mirror
dashboard-only helper guards, auto-transition parent status, or add a new
lifecycle/status transition matrix.
`record_work_request_decision.source_type` must be one of `human`,
`architect`, `operator`, or `ask_pro_advisory`; the live MCP input schema
advertises this enum.
`ask_work_request_question` may include an optional `decision_prompt` object
with redacted `tl_dr`, `details`, one to four answer `options`, and optional
`custom_redirect_label`. Responses include the redacted structured prompt when
present while preserving plain-text question fields for fallback clients.
`custom_redirect_label` only customizes the visible freeform redirect label;
the local operator redirect path remains available when the field is omitted and
stores only the operator's replacement guidance note.
`add_work_request_planned_slice`, `approve_work_request_planned_slice`,
`skip_work_request_planned_slice`, and `mark_work_request_sliced` also require
`write:work_request`, the same explicit phase-scoped frozen repo/base-branch
scope, and `work_request_id` on every mutation. Approve and skip verify that
`planned_slice_id` belongs to the scoped WorkRequest before mutating and fail
closed as not found for sibling slices. `mark_work_request_sliced` uses the
existing WorkRequest service behavior, including the approved-or-dispatched
slice requirement. Responses return JSON-safe redacted planned-slice or
WorkRequest status projections plus scope/status metadata. These tools do not
dispatch planned slices, create WorkPackages, alter SecretHandoff, mutate
Linear, run automatic slicing/package generation, or change dashboard behavior.
`add_work_request_planned_slice.work_package_kind` must be one of the
standalone dispatchable WorkPackage kinds advertised by the live MCP input
schema.
`dispatch_work_request_planned_slice` is separate from those mutation tools and
requires `dispatch:work_request` because it creates a WorkPackage, worker grant,
and private SecretHandoff side effects. It requires `work_request_id`,
`planned_slice_id`, and `claimed_by`, with optional `secret_handoff` and
`secret_store_dir`, uses the same frozen repo/base-branch WorkRequest scope, and
calls the existing `PlannedSliceDispatch.dispatch` orchestration. MCP dispatch
is advertised only when `repo_root`/`--repo-root` points at a repository
containing the worker secret handoff script, and direct calls fail closed if that
root is missing or invalid. It requires a file-backed live ledger so worker
handoff commands reconnect to the same ledger; in-memory database configuration
fails closed before dispatch side effects. Blank database configuration is
treated as absent and uses the live ledger. Matching configured SQLite file URI
options are preserved in the worker
handoff command when they resolve to the same live ledger, including default
repo database configuration; divergent explicit MCP database configuration fails
closed, and matching read-only SQLite URI options such as `mode=ro` or
`immutable=1` are rejected before dispatch. Missing, out-of-scope,
non-approved, invalid-status, unsupported-kind, and
slice-scope violations fail closed before returning sibling content or raw
secret material. The response is intentionally narrower than CLI output:
WorkRequest id, planned slice id/status/linkage, WorkPackage id metadata, and
redacted worker handoff metadata only. Dispatch-link failure responses may include
sanitized recovery identifiers such as WorkPackage id, worker grant id, cleanup
status, and redacted handoff metadata. It must not include raw worker secrets,
work keys, bearer tokens, API tokens, MCP auth tokens, private-store secret
payloads, or secret-bearing claim URLs.
`read_child_status` requires both `read:child_progress` and
`read:child_findings` because its summary includes progress, findings, and
artifact counts. `approve_child_ready_state` revalidates the ready child against
current readiness evidence, active phase state, and the frozen phase-child
repo/base/file scope before recording approval. There is no approval override in
this contract. Exact approval retries replay across renewed architect grants for
the same actor only when the caller supplies the same `request_id`; the human
`rationale` is audit text and is not idempotency key material.
Same-`request_id` retries within the same ready-state cycle replay the original
approval audit event; retry rationale edits do not mutate the recorded audit
rationale. Re-approval after a real blocked/reworked/readied cycle records a new
approval audit event even when the same `request_id` and rationale text are
reused. Approved children are architect-controlled, except the child worker may
move `merging_into_phase` back to `blocked` to represent a merge blocker before
further worker follow-up.
`merge_child_into_phase` accepts only local merge artifacts with
`status: "merged_into_phase"` and a nonempty `uri`, records them as a
`phase_merge` artifact on the child package, and marks the child
`merged_into_phase`. The full accepted `merge_artifact` is preserved as artifact
metadata. Exact merge retries replay across renewed scoped architect grants even
when the renewed grant has a different `claimed_by`; after the child is merged,
a new valid merge artifact updates the local `phase_merge` record and appends
an audit event without another lifecycle transition while the phase remains
active; exact older retries do not overwrite newer artifact data. Merge
finalization and post-merge artifact updates are rejected after the phase
closes. Phase-board progress summary totals are computed after backend
authorization and frozen repo/base scope filters, then remain stable across
client-side board filters; abandoned children are excluded, and closed children
still count in the merge-progress denominator but are not open work. Remaining
Phase 7-dependent tools perform authorization first and then return an explicit
`phase7_not_implemented` error; they do not publish phase state in P7-003.

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
worker or architect grant during explicit bootstrap/recovery; it does not mint
new grants and is not the normal generic planning surface. Reconnects are
accepted only when the same owner identity presents the same secret proof.

Explicit `state_key` values retain initialized handshake continuity for
stateless transports, but they do not restore claimed worker sessions. A
reconnecting worker must present the same secret proof and `claimed_by` identity
again, preferably through the private-store MCP bootstrap rather than a raw
secret tool call. The continuity namespace is the active ledger, so a reconnect
to the same SQLite ledger can restore handshake state even when the dynamic repo
process changes.
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
The stdio transport is newline-delimited JSON. Long one-shot stdio invocations
that include `tools/list` or `read_work_request` can produce large response
lines, so callers must drain stdout concurrently or redirect stdout to a file.
Waiting for process exit while stdout is not being read can deadlock the caller
before later requests are processed. The private-file wrapper provides
`run-mcp-local-file-once` for diagnostics that need to send a JSONL request
file and spool stdout/stderr to files while keeping the work key out of
prompts and logs. Caller-supplied output/error files must not already exist;
generated spool files are created when output/error files are omitted.

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
