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
- [x] Fix third T2 readiness/status, structured review, atomicity, and storage-error findings locally.
- [x] Commit and push latest T2 fixes.
- [x] Run fresh full-diff T2 on `55748aa`/takeover head and close valid findings gate.
- [x] Fix fourth T2 schema, malformed patch id, and stale review-head findings locally.
- [x] Commit fourth T2 fixes.
- [x] Run fresh full-diff T2 on `5fdb925` and close valid findings gate.
- [x] Fix fifth T2 required PR head, schema, and malformed review-entry findings locally.
- [x] Commit fifth T2 fixes.
- [x] Run fresh full-diff T2 on `c9c036b` and close valid findings gate.
- [x] Fix sixth T2 malformed patch, claim retry, investigation recommendation, and metadata idempotency findings locally.
- [x] Commit sixth T2 fixes.
- [x] Run fresh full-diff T2 on `27786b6` and close valid findings gate.
- [x] Fix seventh T2 claim replay, package-scoped finding idempotency, no-op patch, recommendation artifact, and finding conflict findings locally.
- [x] Commit seventh T2 fixes.
- [x] Run fresh full-diff T2 on `8217287` and close valid findings gate.
- [x] Fix eighth T2 review-artifact and idempotency-scope findings locally.
- [x] Commit eighth T2 fixes.
- [x] Run fresh full-diff T2 on `ca9d750` and close valid findings gate.
- [x] Fix ninth T2 review-package validation, artifact persistence, and task-plan snapshot findings locally.
- [x] Commit ninth T2 fixes.
- [x] Run fresh full-diff T2 on `849ce9e` and close valid findings gate.
- [x] Fix tenth T2 review-package atomicity, blank artifact, schema, stale-head, and persisted-artifact readiness findings locally.
- [x] Commit tenth T2 fixes.
- [x] Run fresh full-diff T2 on `83c372a` and close valid findings gate.
- [x] Fix eleventh T2 one-time claim, review artifact per-head, and review-package scope findings locally.
- [x] Commit eleventh T2 fixes.
- [x] Run fresh full-diff T2 on `47e6f03` and close valid findings gate.
- [x] Fix twelfth T2 latest review verdict, full artifact-set, policy-derived readiness, plan-version, and malformed review-entry findings locally.
- [x] Commit and push twelfth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `0828704` and close valid findings gate.
- [x] Fix thirteenth T2 idempotent progress replay and claim ledger error-classification findings locally.
- [x] Commit and push thirteenth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `911f231` and close valid findings gate.
- [x] Fix fourteenth T2 atomic plan-version, duplicate artifact, and changed idempotent progress replay findings locally.
- [x] Commit and push fourteenth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `e300fb2` and close valid findings gate.
- [x] Fix fifteenth T2 claim-session persistence and rebind findings locally.
- [x] Commit and push fifteenth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `6f01410` and close valid findings gate.
- [x] Fix sixteenth T2 worker-claim role, replay revalidation, schema, normalization, and state-retention findings locally.
- [x] Commit and push sixteenth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `d07f6f6` and close valid findings gate.
- [x] Fix seventeenth T2 response-only handshake, non-worker preflight, and blocker-id validation findings locally.
- [x] Commit and push seventeenth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `c54d000` and close valid findings gate.
- [x] Perform high-pressure coherence review before another same-tier review.
- [x] Fix eighteenth T2 append-finding id/idempotency findings locally.
- [x] Commit and push eighteenth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `0546cbd` and close valid findings gate.
- [x] Fix nineteenth T2 normalized progress replay, finding idempotency, and latest review-artifact findings locally.
- [x] Commit and push nineteenth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `af68331` and close valid findings gate.
- [x] Fix twentieth T2 migration-upgrade and duplicate explicit finding id findings locally.
- [x] Commit and push twentieth T2 fixes.
- [x] Perform continued high-pressure coherence review before another same-tier review.
- [x] Run fresh full-diff T2 on pushed head `941170e` and close valid findings gate.
- [x] Fix twenty-first T2 readiness, latest-review, compatibility, worker-session, and finding-normalization findings locally.
- [x] Commit and push twenty-first T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `4dbed4f` and close valid findings gate.
- [x] Fix twenty-second T2 worker-resource, expected-status, and blocker-normalization findings locally.
- [x] Commit and push twenty-second T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `a0e600b` and close valid findings gate.
- [x] Fix twenty-third T2 claim-reconnect, assignment-role, review-array, and boolean-validation findings locally.
- [x] Commit and push twenty-third T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `3163976` and close valid findings gate.
- [x] Fix twenty-fourth T2 test-entry, status-reason, progress-idempotency, and empty-plan findings locally.
- [x] Commit and push twenty-fourth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `0b8bbbf` and close valid findings gate.
- [x] Fix twenty-fifth T2 status-reason validation, status-transition atomicity, expected-status race, and readiness race findings locally.
- [x] Commit and push twenty-fifth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `28d456e` and close valid findings gate.
- [x] Fix twenty-sixth T2 reconnect ownership, finding replay id, finding retry, quick-fix readiness, and response-state findings locally.
- [x] Commit and push twenty-sixth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `e16849c` and close valid findings gate.
- [x] Fix twenty-seventh T2 response-state isolation and required reconnect owner contract findings locally.
- [x] Commit and push twenty-seventh T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `136184b` and close valid findings gate.
- [x] Fix twenty-eighth T2 authenticated plan/finding writes, incremental review lanes, and repeated status-reason audit findings locally.
- [x] Commit and push twenty-eighth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `5da5404` and close valid findings gate.
- [x] Fix twenty-ninth T2 review-package transaction, acceptance carry-forward, and artifact retry findings locally.
- [x] Commit and push twenty-ninth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `c234740` and close valid findings gate.
- [x] Fix thirtieth T2 worker tool notification dispatch finding locally.
- [x] Commit and push thirtieth T2 fix.
- [x] Run fresh full-diff T2 on pushed head `7bb1915` and close valid findings gate.
- [x] Resolve thirty-first T2 findings after architecture decision on `claim_work_key.claimed_by` compatibility.
- [x] Validate thirty-first T2 fixes locally.
- [x] Commit and push thirty-first T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `5a13229` and close valid findings gate.
- [x] Fix thirty-second T2 head validation, pre-attach review evidence, and transactional grant revalidation findings locally.
- [x] Commit and push thirty-second T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `e2e4c2f` and close valid findings gate.
- [x] Fix thirty-third T2 headless-review evidence finding locally.
- [x] Commit and push thirty-third T2 fix.
- [x] Run fresh full-diff T2 on pushed head `5de9298` and close valid findings gate.
- [x] Fix thirty-fourth T2 response-only state-key reset finding locally.
- [x] Commit and push thirty-fourth T2 fix.
- [x] Run fresh full-diff T2 on pushed head `9fee4d9` and close valid findings gate.
- [x] Fix thirty-fifth T2 branch-head review freshness and string normalization findings locally.
- [ ] Commit and push thirty-fifth T2 fix.
- [ ] Run T2 follow-up/full T2 until green, then GitHub review.
- [ ] Reply to and resolve GitHub inline findings where applicable.
- **Status:** thirty-second T2 fixes pushed; pending fresh full-diff T2 rerun and GitHub review if clean.

### High-Pressure Coherence Review

- Full diff remains coherent for P3-002: the large changes are concentrated in the MCP worker server/test surface with small lifecycle/policy/planning support needed by the worker tools and resources.
- The latest T2 findings are converging to narrow contract/idempotency hardening, not a design or scope problem, so continuing the mandated T2/GitHub loop is appropriate.
- Before the next same-tier T2, the core approach is still right because the new fix set keeps the existing worker MCP architecture and only tightens policy evidence, session authorization, latest-review semantics, and retry normalization.
- The current findings remain small edge-case hardening against the same P3-002 API surface rather than evidence of a broader design split, so continuing one more full-diff T2 is still coherent.
- Before the next T2, the approach remains coherent because the latest fixes only extend the same worker-scoped authorization/idempotency/readiness contract to resource reads, lifecycle races, and blocker retries.
- Findings are still converging as narrow edge-case hardening around the worker MCP API rather than broad architecture churn.
- Before the next T2, the core remains coherent: this fix preserves the existing claim/session design while adding restart recovery for the same worker secret and tightening optional argument validation.
- The latest findings are still confined to worker MCP reconnect and validation edge cases, so the loop is converging rather than revealing a package split.
- Before the next T2, the core approach remains sound because the latest changes only align accepted inputs with readiness semantics and preserve documented audit context for the same worker MCP tools.
- The findings continue to converge as contract-shape and retry-normalization edge cases, not a broader scope or architecture concern.
- Before the next T2, the core approach remains coherent because the latest fix keeps the worker MCP lifecycle contract intact while moving status/reason/readiness writes into transactional checks.
- Findings are still converging on small race and input-validation hardening around the same P3-002 tools, not showing a need to split or redesign the package.
- Before the next T2, the approach remains coherent because the latest changes only tighten worker claim ownership, response-only state continuity, finding idempotency, and policy-gate alignment inside the same P3-002 MCP surface.
- The latest findings are still converging as small contract/race hardening, not as evidence of a broader design or scope problem.
- Before the next T2, the approach remains coherent because the latest change keeps default MCP state isolated while preserving explicit `state_key` continuity for stateless transports and making claim ownership explicit.
- Findings remain concentrated on the same worker MCP state/claim contract, so continuing the loop is still appropriate.
- Before the next T2, the core approach remains coherent because the latest fix only revalidates existing worker assignments inside transactional plan/finding writes and refines review/status audit semantics within the P3-002 MCP surface.
- Findings are still converging as small authorization, idempotency, and readiness edge cases around the same worker tools rather than a broader package design problem.
- Before the next T2, the approach remains coherent because the latest change only moves review-package head/default evidence decisions into the existing transaction and hardens deterministic artifact replay.
- Findings remain concentrated on review-package concurrency and incremental evidence edge cases, so continuing the P3-002 finish loop is still appropriate.
- Before the next T2, the approach remains coherent because the latest change only executes existing worker tool dispatch for JSON-RPC notifications while preserving fire-and-forget response semantics.
- The latest finding is a single protocol dispatch edge case inside P3-002 MCP behavior, not a broader design or scope problem.
- The current loop is blocked because T2 findings now conflict on the public `claim_work_key` contract: earlier review required explicit `claimed_by` for reconnect ownership, while the latest review says published docs/templates require `claim_work_key(secret)`.
- This is a backward-compatibility-sensitive API decision for P3-002 consumers, so implementation should pause until the overseeing architecture agent chooses the contract.
- Overseer selected Option A on 2026-05-03: keep `claim_work_key.claimed_by` required and update the published MCP docs/templates/package docs as an intentional pre-production API decision.
- Before the next T2, the approach remains coherent because the latest fixes only tighten worker grant revalidation inside existing write transactions and preserve already-accepted review evidence semantics.
- Findings remain narrow correctness hardening around the same P3-002 MCP write/readiness surface, so continuing the T2/GitHub loop is still appropriate.
- Before the next T2, the approach remains coherent because the latest change only narrows readiness evidence to review packages that explicitly match the current PR head once a PR head exists.
- Findings are still converging as current-head evidence hardening inside the P3-002 review gates, not a broader package design or scope problem.
- Before the next T2, the approach remains coherent because the latest fix only separates a fresh response-only MCP initialize from intentional stateless continuation through an explicit `state_key`.
- Findings remain localized to the worker MCP transport/session state surface; this is still edge-case hardening rather than a design or scope blocker.
- Before the next T2, the approach remains coherent because the latest fix extends the same head-based review-evidence contract from PR workflows to branch-only workflows by requiring `attach_branch` to publish the current head.
- Findings remain narrow API-contract and normalization hardening inside P3-002 worker MCP metadata tools, not evidence of a broader package split.

## Blockers

- None currently. The claim contract decision is resolved in favor of explicit `claimed_by` owner identity.

## Boundaries

- Do not implement P3-003 architect tools, P3-004 skill package, dashboard/API, GitHub sync beyond attach metadata, or unrelated cleanup.
- Do not create live Linear state.
- Do not log or expose raw work keys, bearer tokens, API keys, or secrets.
- Ask the overseeing architecture agent before making backward-compatibility-sensitive or broader-scope decisions.
