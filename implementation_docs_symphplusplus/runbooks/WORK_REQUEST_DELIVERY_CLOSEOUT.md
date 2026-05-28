# WorkRequest Delivery Closeout

Use this runbook after a WorkRequest planned slice has been dispatched and the
worker has produced current S++ evidence: implementation, review, CI/static
gates when present, and a mergeable green PR when a PR exists.

## Default Sequence

1. Read `read_work_request_delivery_board(work_request_id)`.
2. If the board shows merged PR evidence without a delivery outcome, dry-run
   `reconcile_work_request(work_request_id)`.
3. If the dry-run proposes the expected PR-merged repair, apply
   `reconcile_work_request(work_request_id, apply: true)` or record the same
   truth explicitly with `record_planned_slice_delivery`.
4. For no-PR completion, supersession, or abandonment, call
   `record_planned_slice_delivery` directly with the required evidence.
5. Re-read the delivery board and verify `needs_closeout` no longer describes
   the slice.

Decision log entries explain rationale and scope. They do not close delivery.
Worker WorkPackage progress proves what the worker did. It does not decide the
WorkRequest delivery outcome.

## Outcome Examples

No-PR completion:

```json
{
  "work_request_id": "wr_kraken_docs",
  "planned_slice_id": "wrs_docs_hygiene",
  "outcome": "completed_no_pr",
  "idempotency_key": "kraken-docs-hygiene-no-pr",
  "no_pr_evidence": "Operator confirmed the docs-only update landed directly."
}
```

Supersession:

```json
{
  "work_request_id": "wr_kraken_docs",
  "planned_slice_id": "wrs_broad_docs",
  "outcome": "superseded",
  "idempotency_key": "kraken-broad-docs-recut",
  "successor_planned_slice_id": "wrs_narrow_docs",
  "successor_work_package_id": "wp_narrow_docs",
  "superseded_reason": "Recut with narrower owned files."
}
```

## Kraken-Style Stale Delivery-Board Verification

Fixture shape:

- WorkRequest: `wr_kraken_closeout`.
- Planned slice: raw status `dispatched`.
- Linked WorkPackage: raw package status: `ready_for_worker`.
- Either structured merged-PR evidence exists, or the operator has direct
  no-PR completion evidence.

Expected projection before closeout:

- `read_work_request_delivery_board` preserves raw slice status `dispatched`.
- The linked package raw status remains visible as `ready_for_worker`.
- If merged-PR evidence is present, the slice reports `Needs Closeout` rather
  than pretending the stale package card is still the human next action.

Expected projection after closeout:

- `record_planned_slice_delivery` records the outcome idempotently.
- `pr_merged` moves the compatible linked package to `merged`;
  `completed_no_pr` and `superseded` move it to `closed`; `abandoned` moves it
  to `abandoned`.
- The delivery board reports the outcome (`Delivered`, `Completed Without PR`,
  `Superseded`, or `Abandoned`) and no longer presents the stale
  `ready_for_worker` package as dispatchable work.
- WorkRequest completion refreshes when every planned slice has terminal
  delivery truth.

Merged-PR recovery may close a compatible stale linked package even if its raw
lifecycle, worker grant, or local claim-lease state is stale, but it requires
strong PR evidence: `pr_url`, `pr_merged_at`, and `merge_commit_sha`. Live worker
grants are revoked, active/stale local claim leases are released, and both are
listed in the closeout progress event. Active blockers, paused claim leases,
active agent runs, malformed PR URLs, PR URL metadata mismatches, package
metadata mismatches, and weak merge evidence still fail closed.

Supersession may close a compatible stale linked package even when active
blocker events remain. The blocker events are not resolved or deleted; the
closeout progress event records the active blocker ids and the delivery board
keeps blocker attention on the terminal superseded slice.

If closeout rejects because of active runtime on an unsupported outcome,
package metadata mismatch, weak PR evidence, or stale terminal conflict, do not
paper over it with a decision note. Fix the evidence or ask the
operator/architect for the next lifecycle decision.
