# Dogfood: MCP Activation

This dogfood note tracks the current activation shape after simplified local
claims.

## Expected Smoke

- Unbound HTTP MCP smoke exposes health, Solo tools, scoped schemas,
  `claim_local_assignment`, `claim_local_architect_assignment`, and
  `create_work_request`.
- Bound worker smoke calls `claim_local_assignment` with a WorkPackage id, then
  verifies `get_current_assignment`, resources, and bound worker tools.
- Bound architect smoke calls `claim_local_architect_assignment` with a
  WorkRequest id, then verifies WorkRequest/product-tree/delivery-board reads.

## Safety

Dogfood ledgers should use synthetic ids and disposable local data. Do not place
tokens, grant verifiers, or claim lease internals in dogfood notes.
