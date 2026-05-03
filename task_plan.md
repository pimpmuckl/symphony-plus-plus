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
7. Commit, push, open PR against `symphony-plus-plus/beta`, then run review-suite T1, T2, and GitHub review on the final PR head. Status: blocked.

## Decisions

- No Phase 7 entities or delegation behavior will be created in this package.
- `read_child_status` will only read the currently scoped work package until Phase 7 phase-child relationships exist.
- Phase 7-dependent architect tools will require valid architect authorization first, then return a structured `not_yet_implemented` error.

## Blocker

- Review-suite T1 is not green on current pushed head `9340ee2c46b4d5c6b8bc1ace6346e287c7a46fc2`.
- Initial T1 found valid issues; those were fixed, committed, pushed, and revalidated locally.
- Required fresh T1 reruns after the fix repeatedly returned `review_interrupted` for both reviewers before usable output, including base-review and explicit commit-range invocations.
- Do not run T2 or GitHub review until T1 can complete cleanly or the overseer explicitly changes the review-gate instruction.
