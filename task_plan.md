# SYMPP-P3-003 Task Plan

## Scope

Implement only SYMPP-P3-003: architect-facing MCP tool contracts on the existing P3-001/P3-002 MCP foundation.

## Plan

1. Inspect MCP server, grant/session enforcement, package docs, and tests. Status: done.
2. Add architect MCP tool registry, argument schemas, and role/capability checks. Status: done.
3. Implement safe read-only architect status tool and explicit Phase 7 stubs. Status: done.
4. Update MCP contract docs and JSON. Status: done.
5. Add focused MCP tests for contract, worker denial, insufficient/invalid grants, read-only success, and Phase 7 stub errors. Status: done.
6. Run focused validation. Status: done.
7. Commit, push, open PR against `symphony-plus-plus/beta`, then run review-suite T1, T2, and GitHub review on the final PR head. Status: pending.

## Decisions

- No Phase 7 entities or delegation behavior will be created in this package.
- `read_child_status` will only read the currently scoped work package until Phase 7 phase-child relationships exist.
- Phase 7-dependent architect tools will require valid architect authorization first, then return a structured `not_yet_implemented` error.
