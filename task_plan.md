# Task Plan: SYMPP-P3-002 Worker MCP Tools and Resources

## Goal

Implement only SYMPP-P3-002: worker-scoped MCP tools/resources for claim, current assignment, virtual planning files, plan/progress/finding writes, status/blocker/scope-expansion reporting, branch/PR attachment, and readiness checks.

## Current Phase

Phase 3

## Phases

### Phase 1: Requirements & Discovery
- [x] Read package spec and MCP tools contract.
- [x] Inspect P3-001 MCP scaffold and existing MCP tests.
- [x] Inspect planning, lifecycle, access-grant, audit/idempotency APIs.
- [x] Confirm exact readiness gates available from merged dependencies.
- **Status:** complete

### Phase 2: Implementation
- [x] Add worker tool/resource dispatch with strict auth and object params.
- [x] Wire writes through existing scoped services/repositories.
- [x] Preserve upstream Symphony/Linear behavior and avoid architect/dashboard/GitHub sync scope.
- **Status:** complete

### Phase 3: Tests & Validation
- [x] Add focused success, denial, idempotency, readiness, and sibling-scope tests.
- [x] Run focused MCP validation.
- [x] Run broader Symphony++ validation.
- [x] Document broad-test blockers if any Windows baseline issue appears.
- **Status:** complete

### Phase 4: PR & Reviews
- [x] Commit and push branch.
- [x] Open PR `[SYMPP-P3-002] Worker MCP tools and resources` to `symphony-plus-plus/beta`.
- [ ] Run review-t1, fix valid findings, then review-t2, fix valid findings, then GitHub review.
- [ ] Reply to and resolve GitHub inline findings where applicable.
- **Status:** blocked on review-suite T1 infrastructure: repeated review slots interrupted before usable output.

## Boundaries

- Do not implement P3-003 architect tools, P3-004 skill package, dashboard/API, GitHub sync beyond attach metadata, or unrelated cleanup.
- Do not create live Linear state.
- Do not log or expose raw work keys, bearer tokens, API keys, or secrets.
- Ask the overseeing architecture agent before making backward-compatibility-sensitive or broader-scope decisions.
