# WorkRequest Contract

A WorkRequest is the product-facing planning and delivery unit. It may contain
product plan nodes and planned slices. WorkPackages are execution/audit records
created from planned slices.

## Architect Bootstrap

`create_work_request` returns the created WorkRequest and a non-secret local
architect claim:

```json
{"tool":"claim_local_architect_assignment","arguments":{"work_request_id":"<WR id>"}}
```

## Planned Slice Dispatch

After all open clarification questions are answered or closed, there is no
separate clarification-complete step. `add_work_request_planned_slice` can
advance a `ready_for_clarification`, `clarifying`, or `human_info_needed`
WorkRequest with zero open questions to `ready_for_slicing` before it inserts
the slice. Open questions still block slicing.

Approved planned slices are dispatched with `work_request_id` and
`planned_slice_id`. Dispatch creates a linked WorkPackage and returns worker
bootstrap metadata for `claim_local_assignment`.

## Delivery

Closeout is recorded with `record_planned_slice_delivery` using PR evidence,
direct no-PR evidence, supersession evidence, or an abandoned rationale.
Skipped scratch planning slices remain hidden from normal delivery projection
unless explicitly requested.

All WorkRequest payloads must redact tokens, grant verifiers, secret hashes, and
secret-like prose.
