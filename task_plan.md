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
- [x] Run review-state and obtain usable T1 findings.
- [x] Fix valid T1 findings.
- [x] Commit and push initial T1 fixes.
- [x] Fix second T1 batch/schema findings locally.
- [x] Commit and push second T1 fixes.
- [x] Run T1 follow-up/full T1 until green.
- [x] Run T2 and close findings gate for valid signoff findings.
- [x] Fix valid T2 findings locally.
- [x] Commit and push first T2 fixes.
- [x] Run fresh T2 and close findings gate for plan atomicity/review-gate findings.
- [x] Fix second T2 findings locally.
- [ ] Commit and push second T2 fixes.
- [ ] Run T2 follow-up/full T2 until green, then GitHub review.
- [ ] Reply to and resolve GitHub inline findings where applicable.
- **Status:** second T2 fixes implemented locally; validation green; pending commit/push and T2 rerun.

## Boundaries

- Do not implement P3-003 architect tools, P3-004 skill package, dashboard/API, GitHub sync beyond attach metadata, or unrelated cleanup.
- Do not create live Linear state.
- Do not log or expose raw work keys, bearer tokens, API keys, or secrets.
- Ask the overseeing architecture agent before making backward-compatibility-sensitive or broader-scope decisions.
