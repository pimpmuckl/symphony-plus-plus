# MCP And Skill Contract

The authoritative machine-readable MCP surface is
`implementation_docs_symphplusplus/mcp/mcp_tools_contract.json`; the readable
summary is `implementation_docs_symphplusplus/mcp/MCP_TOOLS_CONTRACT.md`.

## Normal Claims

Worker:

```json
{"tool":"claim_local_assignment","arguments":{"work_package_id":"<WP id>"}}
```

Architect:

```json
{"tool":"claim_local_architect_assignment","arguments":{"work_request_id":"<WR id>"}}
```

`claimed_by` may be supplied for stable audit identity; id-only architect claims
default to the standard architect handoff owner. `caller_id` is optional
correlation metadata, not claim ownership. Other claim fields are optional
validation context and should be omitted unless already known.

## Skill Responsibilities

- `symphony-plus-plus-mcp:symphony-work-package` claims by WorkPackage id, reads
  the assigned context, records plan/progress/findings/blockers/review evidence,
  and marks ready when gates pass.
- `symphony-plus-plus-mcp:symphony-architect` claims by WorkRequest id, slices
  product work, dispatches workers, answers/records decisions, and closes out
  delivery.
- `symphony-plus-plus-mcp:symphony-solo-session` is only for ordinary
  single-agent planning memory without WorkRequest or WorkPackage authority.

## Dispatch

`dispatch_work_request_planned_slice(work_request_id, planned_slice_id,
claimed_by?)` returns a `worker_bootstrap` payload for
`claim_local_assignment`. Workers should not need repository root, helper
script, private file, or raw secret metadata.

## Delivery Closeout

Architect delivery closeout uses:

```text
read_work_request_delivery_board(work_request_id)
cleanup_work_request_planned_slice_runtime(work_request_id, planned_slice_id, outcome, reason, ...)
record_planned_slice_delivery(work_request_id, planned_slice_id, outcome, idempotency_key, ...)
reconcile_work_request
```

Closeout outcomes include `pr_merged`, `completed_no_pr`, `superseded`, and
`abandoned`. `completed_no_pr` requires `no_pr_evidence`; `superseded` requires
`successor_planned_slice_id` and a rationale. `reconcile_work_request` may use
PR/GitHub evidence to propose deterministic closeout repairs. Use
`cleanup_work_request_planned_slice_runtime` before closeout when stale linked
worker grants, local claim leases, or recoverable worker MCP session bindings are the
remaining runtime blocker; include the same superseded or abandoned evidence
that will authorize closeout. See
`../runbooks/WORK_REQUEST_DELIVERY_CLOSEOUT.md` for the operator runbook.

## Discovery

`tools/list` may show schemas before authorization. A call is authorized only
after the relevant local claim succeeds and the live grant has the required
role, capability, scope, and lifecycle state.
