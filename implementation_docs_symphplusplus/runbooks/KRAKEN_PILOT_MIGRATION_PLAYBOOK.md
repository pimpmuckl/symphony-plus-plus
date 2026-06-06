# Kraken Pilot Migration Playbook

The historical pilot bootstrap has been superseded by simplified ledger claims.
Use this current flow for any new or replayed Kraken pilot work.

## Architect

1. Claim the WorkRequest with `claim_local_architect_assignment`.
2. Read the WorkRequest, product tree, and delivery board.
3. Dispatch approved planned slices with `dispatch_work_request_planned_slice`.

## Worker

1. Claim the dispatched WorkPackage with `claim_local_assignment`.
2. Read MCP context and task plan.
3. Record progress, findings, blockers, branch/PR metadata, review evidence,
   and readiness through MCP.

## Closeout

Use `record_planned_slice_delivery` with merged PR evidence, no-PR evidence,
supersession evidence, or abandoned rationale.

Do not use historical secret bootstrap snippets from older pilot notes.
