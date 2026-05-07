# Task Plan: SYMPP-P3-002 Worker MCP Tools and Resources

> Active lane note, 2026-05-07: this worktree is currently assigned to SYMPP-P8-004 Dialyzer release-gate cleanup. Older SYMPP-P3-002 entries below are historical carry-forward and are not active tasks for this PR.

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
- [x] Commit and push thirty-fifth T2 fix.
- [x] Run fresh full-diff T2 on pushed head `d385aec` and close valid findings gate.
- [x] Fix thirty-sixth T2 newest metadata head selection finding locally.
- [x] Commit and push thirty-sixth T2 fix.
- [x] Run fresh full-diff T2 on pushed head `2ca972b` and close valid findings gate.
- [x] Fix thirty-seventh T2 metadata idempotency and explicit ID normalization findings locally.
- [x] Commit and push thirty-seventh T2 fix.
- [x] Run fresh full-diff T2 on pushed head `e2d5809` and close valid findings gate.
- [x] Fix thirty-eighth T2 strict worker argument-schema finding locally.
- [x] Commit and push thirty-eighth T2 fix.
- [x] Run fresh full-diff T2 on pushed head `0a1114e` and close valid findings gate.
- [x] Fix thirty-ninth T2 current-head merge metadata and `claim_work_key` strict-schema bypass findings locally.
- [x] Commit and push thirty-ninth T2 fix.
- [x] Run fresh full-diff T2 on pushed head `b3b51db` and close valid findings gate.
- [x] Fix fortieth T2 response-only state and `update_task_plan` schema findings locally.
- [x] Commit and push fortieth T2 fix.
- [x] Run fresh full-diff T2 on pushed head `a31a410` and close valid findings gate.
- [x] Fix forty-first T2 response-only state TTL/process-boundary findings locally.
- [x] Commit and push forty-first T2 fix.
- [x] Run fresh full-diff T2 on pushed head `f63106e` and close valid findings gate.
- [x] Fix forty-second T2 serialized state-store and nested schema findings locally.
- [x] Commit and push forty-second T2 fix.
- [x] Run fresh full-diff T2 on pushed head `22d21f6` and close valid findings gate.
- [x] Fix forty-third T2 config namespace, idle TTL, and nested strict-runtime findings locally.
- [x] Commit and push forty-third T2 fix.
- [x] Run fresh full-diff T2 on pushed head `a8f70e3` and close valid findings gate.
- [x] Fix forty-fourth T2 default-state retention and progress replay race findings locally.
- [x] Commit and push forty-fourth T2 fix.
- [x] Run fresh full-diff T2 on pushed head `e1f02c1` and close valid findings gate.
- [x] Fix forty-fifth T2 plan concurrency, mixed update arguments, current-head review-package gate, and brief/incident plan gate findings locally.
- [x] Commit and push forty-fifth T2 fix.
- [x] Run fresh full-diff T2 on pushed head `564338f` and close valid findings gate.
- [x] Fix forty-sixth T2 expired-grant transactional revalidation finding locally.
- [x] Commit and push forty-sixth T2 fix.
- [x] Run fresh full-diff T2 on pushed head `34aefd4` and close valid findings gate.
- [x] Fix forty-seventh T2 replay authorization, task-plan schema/scope, and ready-lock findings locally.
- [x] Commit and push forty-seventh T2 fix.
- [x] Run fresh full-diff T2 on pushed head `6abb443` and close valid findings gate.
- [x] Resolve T2 artifact-aggregation conflict with overseer before changing review readiness semantics.
- [x] Implement overseer Option 2: latest current-head review package is authoritative, require explicit review `head_sha` once branch/PR metadata exists, and scope implicit response-only handle retention per MCP namespace.
- [x] Validate Option 2 fixes locally.
- [x] Commit and push Option 2 fixes.
- [x] Run fresh full-diff T2 on pushed head `facc90b` and close valid findings gate.
- [x] Fix forty-ninth T2 explicit plan patch id and stdio response-state findings locally.
- [x] Validate forty-ninth T2 fixes locally.
- [x] Commit and push forty-ninth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `7412155` and close valid findings gate.
- [x] Fix fiftieth T2 ready-evidence drift and partial plan-patch clarity findings locally.
- [x] Validate fiftieth T2 fixes locally.
- [x] Commit and push fiftieth T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `7204b5c` and close valid findings gate.
- [x] Fix fifty-first T2 invalid request-id and review-head race findings locally.
- [x] Validate fifty-first T2 fixes locally.
- [x] Commit and push fifty-first T2 fixes.
- [x] Run fresh full-diff T2 on pushed head `98af078` and close valid findings gate.
- [x] Fix fifty-second T2 nil/blank explicit state-key isolation finding locally.
- [x] Validate fifty-second T2 fix locally.
- [x] Commit and push fifty-second T2 fix.
- [ ] Commit and push fifty-sixth T2 fix.
- [ ] Run T2 follow-up/full T2 until green, then GitHub review.
- [ ] Reply to and resolve GitHub inline findings where applicable.
- **Status:** active: fifty-sixth T2 fix is validated locally, docs/planning updated, pending commit/push plus fresh full-diff T2.

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
- Before the next T2, the approach remains coherent because the latest fix only changes current-head selection from PR-first to newest branch-or-PR metadata overall.
- Findings remain converged on head freshness semantics for the same P3-002 metadata/review tools, not on broader design.
- Before the next T2, the approach remains coherent because the latest fix only honors the already-advertised metadata idempotency key and applies the existing trim-normalization rule to explicit plan/finding IDs.
- Findings are still localized to identifier/idempotency edges on the worker MCP tool contract.
- Before the next T2, the approach remains coherent because the latest fix only enforces the strict `additionalProperties: false` schemas already advertised by the worker MCP tools.
- Findings remain localized to API contract enforcement for the same P3-002 tool dispatcher.
- Before the next T2, the approach remains coherent because the latest change only applies existing strict-schema and current-head readiness rules to two bypass edges in the same worker MCP surface.
- Findings remain localized to contract enforcement and merge-readiness evidence freshness, not a broader design or scope problem.
- Before the next T2, the approach remains coherent because the latest fix only aligns the advertised task-plan schema with existing append/patch behavior and tightens response-only MCP state retention.
- Findings remain localized to generated-client schema accuracy and response-only transport state edges inside P3-002.
- Before the next T2, the approach remains coherent because the latest change only moves response-only continuation state to a BEAM-global store and refreshes active default sessions.
- Findings remain localized to response-only transport durability for the same P3-002 MCP API.
- Before the next T2, the approach remains coherent because the latest fix only serializes the response-only continuation registry and tightens nested JSON schemas to match existing tool validation.
- Findings remain localized to concurrency/cleanup and schema-contract hardening in the same P3-002 worker MCP API.
- Before the next T2, the approach remains coherent because the latest fix only scopes response-only continuation state by MCP config, lengthens stale expiry for real worker idle gaps, and enforces nested schemas already advertised.
- Findings remain localized to response-only transport isolation and nested input contract enforcement in P3-002.
- Before the next T2, the approach remains coherent because the latest fix only bounds implicit default response-state retention and gives progress-event idempotency the same retry window already used for finding replays.
- Findings remain localized to response-only memory hygiene and idempotent retry race hardening in P3-002.
- Before the next T2, the approach remains coherent because the latest fix only serializes task-plan mutation, rejects ambiguous update shapes, and aligns readiness gates with current-head review evidence plus existing planning-depth policy.
- Findings remain localized to worker MCP contract/concurrency/readiness edge cases within P3-002, not a broader scope or design blocker.
- Before the next T2, the approach remains coherent because the latest fix only makes the existing live-grant transactional revalidation enforce the same expiry rule as session creation.
- Findings remain localized to worker authorization recheck hardening inside P3-002 write paths, not a broader package design issue.
- Before the next T2, the approach remains coherent because the latest fix only applies live-grant revalidation to progress replay, makes advertised task-plan schema/scope match runtime behavior, and locks ready checks before transition.
- Findings remain localized to worker MCP replay, schema, and readiness race hardening within P3-002.
- The latest T2 includes fixable edge cases for per-namespace default handle retention and explicit `head_sha` once branch/PR metadata exists, but also conflicts with the overseer’s prior product/API decision to aggregate review artifacts across all current-head review-package submissions.
- Pause before changing review artifact readiness semantics because this is a direct product-contract conflict, not an implementation ambiguity.
- Overseer selected Option 2 on 2026-05-03: review readiness uses the latest current-head `submit_review_package` as the authoritative evidence package, and stale older same-head packages are superseded rather than implicitly merged.
- Before the next T2, the approach remains coherent because the latest changes only align the review readiness contract with the current product decision and tighten response-only state retention within the existing P3-002 MCP server.
- Findings remain localized to review evidence freshness and response-state hygiene inside P3-002, so continuing the mandated T2/GitHub loop is appropriate.
- Before the next T2, the approach remains coherent because the latest follow-up only makes the advertised task-plan patch schema consistent with runtime append behavior and applies the existing response-only persistence helper to the stdio line-response path.
- Findings remain narrow contract-consistency and helper-path state retention hardening inside P3-002, not a broader package design problem.
- Before the next T2, the approach remains coherent because the latest fix only prevents worker evidence mutations after a successful ready transition and makes partial plan-node updates explicit in the existing changeset.
- Findings remain bounded to readiness immutability and task-plan patch contract clarity within P3-002.
- Before the next T2, the approach remains coherent because the latest fix only restores JSON-RPC request/error semantics for malformed `tools/call` ids and locks the current-head read before review-package persistence.
- Findings remain localized to protocol error handling and review-evidence race hardening inside the same P3-002 MCP surface.
- Before the next T2, the approach remains coherent because the latest fix only treats nil/blank explicit `state_key` values as absent so response-only continuation cannot share a missing-token sentinel.
- Findings remain localized to response-state isolation within P3-002.
- Fresh T2 on pushed head `73de389` produced four valid edge findings: reject headless review packages before orphaning evidence, classify expired worker grants as auth failures, block `report_blocker` after ready, and revalidate assignment before reading review-package head state.
- Before the next T2, the approach remains coherent because these fixes only tighten the existing P3-002 worker MCP write/readiness contract: review packages now always require explicit head proof, post-ready evidence remains immutable, and expired grants fail consistently as authorization errors.
- Findings remain localized to worker MCP evidence and authorization edge cases, not a broader design or scope blocker.
- Fresh T2 on pushed head `53df735` produced three valid findings: latest review packages inherited stale acceptance, idempotent finding insert-conflict replay lacked live-grant revalidation, and response-only state namespaces could collide across dynamic ledgers when `Config.database` was nil.
- Before the next T2, the approach remains coherent because this follow-up only aligns acceptance evidence with the latest-package-authoritative decision, applies the existing live-grant replay rule to findings, and keys response-only continuation by resolved ledger identity.
- Findings remain narrow correctness hardening inside the P3-002 MCP server; there is no current design or scope blocker.
- Fresh T2 on pushed head `4e9bb4f` produced a valid non-merge policy finding: `quick_fix` readiness required review/test gates but could only satisfy them through merge-style review-package evidence.
- Before the next T2, the approach remains coherent because the fix keeps merge-gated packages on current-head review-package evidence while allowing non-merge policies to use ordinary worker progress statuses for focused tests and review lanes.
- Findings remain constrained to policy-gate evidence mapping inside P3-002, not a broader package design issue.
- Fresh T2 on pushed head `3b8eeff` produced valid findings around explicit state retention on failed initialize, implicit response-state retention, investigation recommendation evidence, and post-ready evidence immutability.
- Before the next T2, the approach remains coherent because the latest fix only preserves explicit response-only state until initialize succeeds, retains active implicit sessions by MCP namespace without count eviction, treats `request_scope_expansion` as investigation recommendation evidence, and freezes generic worker evidence writes after ready.
- Findings remain narrow response-state and readiness-contract hardening within P3-002, not evidence of a broader design or scope problem.
- Fresh T2 on pushed head `181b745` produced valid findings around explicit reconnect initialize continuity, stale PR metadata retry ordering, and source filtering for non-merge progress readiness evidence.
- Before the next T2, the approach remains coherent because this follow-up only restores explicit `state_key` session continuity, prevents old PR metadata from overriding a newer branch head, and narrows non-merge readiness fallbacks to generic `append_progress` evidence.
- Findings remain localized to response-state continuity and readiness evidence trust boundaries in the P3-002 worker MCP API.
- Fresh T2 on pushed head `9a8c3cc` produced two valid Alpha findings: stale PR metadata could still override a fresh branch head on the first lagging sync, and explicit `state_key` entries were subject to the implicit 24-hour cleanup.
- Before the next T2, the approach remains coherent because this fix only makes branch head the current-code authority for worker readiness and keeps explicit `state_key` retention aligned with grant lifetime instead of the implicit response-state TTL.
- Findings remain narrow readiness-head and explicit reconnect retention hardening within P3-002.
- Fresh T2 on pushed head `1c28dbd` was not converging: Bravo required newest branch/PR metadata to win for current head selection, while Alpha flagged explicit session restoration from `state_key` alone as a security issue and wanted review-package evidence ignored without an attached current head.
- Overseer decided on 2026-05-03: explicit `state_key` retains initialized handshake state only and workers must re-run `claim_work_key(secret, claimed_by)` after reconnect initialize; latest attached branch head is the worker-declared current code head and PR metadata must match it for merge readiness; review packages require an attached current branch head and cannot satisfy readiness without one.
- Before the next T2, the approach is coherent because the latest implementation applies those product/security decisions directly inside the existing P3-002 state and review-head gates without broadening scope.
- Fresh T2 on pushed head `c55749e` produced valid findings around cleanup of explicit handshake-only state, decoded stdio response-state retention, and transient busy handling during finding replay.
- Before the next T2, the approach remains coherent because this follow-up only applies bounded cleanup and helper-path/retry consistency to the same P3-002 response-state and idempotency mechanisms.
- Fresh T2 on pushed head `ff9919a` produced valid findings around dynamic-ledger state namespaces, review-package idempotent replay after branch-head movement, update-task-plan schema precision, and review-package list normalization.
- Before the next T2, the approach remains coherent because the latest follow-up only makes the published schemas and replay/normalization behavior match the existing P3-002 product contract while preserving the overseer-decided branch-head authority and handshake-only state model.
- Fresh T2 on pushed head `234574c` produced valid findings around failed explicit reconnect initialize state, post-ready task-plan mutation, and caller-controlled investigation recommendation spoofing.
- Before the next T2, the approach remains coherent because these fixes only close remaining readiness/state trust gaps inside the existing P3-002 MCP contract: reconnect initialize must succeed before worker tools, ready packages are immutable, and investigation recommendation evidence must come from the dedicated tool.
- Fresh T2 on pushed head `f7b6229` produced valid findings around same-process failed explicit reinitialize cleanup, non-merge fallback evidence staleness after branch changes, and transactional grant invalidation error classification.
- Before the next T2, the approach remains coherent because the fix keeps the current product contract intact: failed reconnect initialize removes both persisted and live handshake/session state, generic fallback evidence is current-head-relative once a branch exists, and lost grants are authorization failures.
- Fresh T2 on pushed head `45de223` produced three straightforward valid findings plus one product-contract conflict. `attach_branch`/`attach_pr` should revalidate session/scope, and non-merge review-package evidence should count when branch metadata is not required. The stale `submit_review_package` replay finding conflicts with the prior T2-required replay behavior after branch movement.
- Overseer chose replay stability on 2026-05-03: an exact idempotent retry of a previously successful `submit_review_package(head_sha: A)` must replay the original success after branch head B is attached, but that replayed head-A evidence stays stale for readiness and cannot satisfy merge/readiness gates against head B.
- Before the next T2, the approach remains coherent because the latest fix only separates lost-response idempotent replay semantics from readiness evidence freshness, scopes branch/PR metadata writes through the existing session guard, and allows branchless review-package evidence only for non-merge policies where branch metadata is not a required gate.
- Fresh T2 on pushed head `4aef958` produced one valid finding: explicit `state_key` handshake continuity was being cleaned up by the implicit default response-state TTL before longer-lived worker grants could expire.
- Before the next T2, the approach remains coherent because this follow-up only restores the intended distinction between implicit default response-state cleanup and explicit state-key handshake continuity; it does not restore claimed sessions from `state_key`.
- Fresh T2 on pushed head `94e5f16` produced one valid finding: `append_finding` exact idempotent replay could be blocked after `mark_ready`, unlike the other evidence tools.
- Before the next T2, the approach remains coherent because the fix only reorders existing finding replay checks before the ready-state mutation guard, preserving post-ready immutability for new writes.
- Fresh T2 on pushed head `fdc2781` produced valid findings that explicit `state_key` retention was now unbounded and existing plan-node patch updates could accept whitespace-only titles.
- Before the next T2, the approach remains coherent because the fix bounds explicit handshake retention with a longer TTL than current worker grants and applies the existing nonblank title contract to patch updates.
- Fresh T2 on pushed head `90485d6` produced one valid Bravo finding: JSON-RPC batch handling threaded session mutations from earlier items into later items.
- Before the next T2, the approach remains coherent because the fix only isolates batch items against the batch's initial MCP server state while preserving standalone request/session behavior and fire-and-forget notification execution.
- Fresh T2 on pushed head `01b7da1` produced two valid Bravo findings: explicit state-key reinitialize could leave an older live server's cached session usable, and append-finding idempotency duplicated successful writes across worker grant renewal.
- Before the next T2, the approach remains coherent because the fix only tightens the existing handshake-only state-key contract and aligns finding replay with the same lost-response stability expected of worker evidence tools.
- Fresh T2 on pushed head `babe432` produced four valid follow-up findings: single-item batch claims should persist for later requests, finding idempotency needs a work-package-scoped DB uniqueness boundary, non-merge fallback readiness must use the latest relevant status, and non-worker sessions should return authorization errors.
- Before the next T2, the approach remains coherent because these fixes refine the existing P3-002 worker protocol guarantees without changing package boundaries: batch items remain isolated within a batch, idempotency replay is backed by storage, readiness uses latest current-head evidence, and non-worker access is consistently unauthorized.
- Fresh T2 on pushed head `ccc3624` produced two valid findings: successful batched `claim_work_key` should persist the final server session for later standalone requests even in multi-item batches, and the published `submit_review_package` schema should advertise non-empty nonblank `tests` and `artifacts`.
- Before the next T2, the approach remains coherent because these are contract-precision fixes: batch items still do not authorize each other within the batch, but final claim state is retained for the connection, and the advertised schema now matches runtime validation.
- Fresh T2 on pushed head `020cb19` produced two valid findings: multiple successful `claim_work_key` entries in one batch could bypass the one-assignment-per-connection guard, and blank-path SQLite ledgers could share explicit response-state namespaces.
- Before the next T2, the approach remains coherent because the fixes narrow the existing protocol guarantees: a batch can retain one successful claim for later standalone requests but cannot claim multiple grants, and response-state continuity stays ledger-scoped even for blank-path SQLite databases.
- Fresh T2 on pushed head `af3311a` produced valid response-state findings: blank-path SQLite ledgers with nil configured database still needed a non-nil namespace, and implicit response-state sessions should reset on a fresh initialize. Bravo also repeated a finding to grant-scope `append_finding` idempotency, which conflicts with earlier T2 and implemented contract text requiring work-package-scoped replay across grant renewal.
- Before the next T2, the approach remains coherent because the applied fixes stay within response-state isolation and lifecycle semantics; the finding idempotency scope is left unchanged unless the overseer reverses the prior work-package-scoped idempotency decision.
- Fresh T2 on pushed head `08eb4ce` produced one valid finding: duplicate `initialize` on an already-live explicit-state server should return `already_initialized` and preserve the active worker session, while recreated explicit-state servers may still initialize for reconnect continuity.
- Before the next T2, the approach remains coherent because this only separates active-connection duplicate-initialize semantics from recreated-server reconnect semantics.
- Fresh T2 on pushed head `c671891` produced valid findings that live implicit stdio servers also need duplicate-initialize preservation, and explicit duplicate-initialize errors should not delete persisted handshake continuity.
- Before the next T2, the approach remains coherent because this completes the same active-versus-recreated initialize distinction across both implicit stdio and explicit state-key transports.
- Fresh T2 on pushed head `29636e6` produced valid findings that batch claim bookkeeping should only count actual successful `claim_work_key` items and that later non-claim batch items must not overwrite a refreshed claim session.
- Before the next T2, the approach remains coherent because this only refines the existing batch contract: non-claim items remain isolated, claim items can refresh the final connection state, and only successful claims trip the one-claim-per-batch guard.

## Blockers

- Potential T2 conflict to watch: latest T2 Alpha asked public response-only `Server.handle/2` explicit `state_key` callers to preserve claimed sessions across calls, but the overseer previously decided explicit `state_key` is handshake/initialize continuity only and workers must call `claim_work_key(secret, claimed_by)` again after reconnect initialize. If this repeats after the valid review-package fix, pause for an overseeing product/security decision instead of making `state_key` a bearer session capability.

## Boundaries

- Do not implement P3-003 architect tools, P3-004 skill package, dashboard/API, GitHub sync beyond attach metadata, or unrelated cleanup.
- Do not create live Linear state.
- Do not log or expose raw work keys, bearer tokens, API keys, or secrets.
- Ask the overseeing architecture agent before making backward-compatibility-sensitive or broader-scope decisions.

## SYMPP-P8-004 Dialyzer Release-Gate Follow-Up - 2026-05-07

### Goal

Make `make -C elixir dialyzer` meaningful and green for the release gate without broad suppressions or product-behavior drift.

### Scope Boundaries

- Own only the Dialyzer cleanup split from SYMPP-P8-004 after PR #38.
- Preserve upstream Symphony and Linear behavior unless current tests/code prove a branch is impossible.
- Prefer truthful specs, helper return types, and control-flow tightening over ignores.
- Keep defensive runtime branches when the warning is caused by underspecified repository/API typing.

### Warning Classification

| Class | Examples | Likely fix | Risk |
|---|---|---|---|
| Underspecified return/specs | repository `{:error, _}` branches, phase/artifact lookups, MCP tool helpers | Broaden or correct specs/typespecs to include real error shapes | Medium: must not delete defensive handling for storage/service failures |
| Over-narrow helper success typing | tool result helpers, dashboard/MCP guards, return-shape mismatches | Normalize helper specs and call sites to the actual tagged result shape | Medium: product-visible tool errors must stay stable |
| Impossible/dead control flow | covered pattern matches, impossible guards, unused private helper | Remove redundant clause or simplify branch only where runtime shape is truly impossible | Low/medium: verify tests for touched user-facing paths |
| Opaque MapSet misuse | tracker state sets and tracker adapter set ops | Use `MapSet.t(...)` specs and pass MapSets to MapSet APIs | Low: mechanical typing cleanup |
| Macro/module attribute match artifact | planning redactor module-level pattern | Rewrite to a direct compile-time conditional or simple module body | Low: no product behavior intended |
| CLI task exception typing | `mix sympp.create_work` error formatting | Use exception-message API that matches `rescue` typing | Low: preserve CLI output semantics |

### Implementation Plan

1. Confirm the current Dialyzer output in this worktree and capture any drift from the parent-observed list.
2. Inspect each touched seam and group edits by truthful cause, keeping the diff reviewable.
3. Apply minimal code/spec fixes and focused tests for behavior-sensitive seams.
4. Run formatting, focused tests, `git diff --check`, `make -C elixir dialyzer`, and `make -C elixir all` if Dialyzer is green.
5. Commit, push, create PR with the required title/template, then run T1, T2, and GitHub review-suite lanes.

### Current Status

- Completed: baseline Dialyzer output was confirmed at 53 warnings and classified by cause/risk before code edits.
- Completed: warning cleanup is implemented as targeted spec, storage-error typing, opaque MapSet, and dead-control-flow fixes without broad Dialyzer suppression.
- Completed: `make -C elixir dialyzer` is green with `Total errors: 0`.
- Completed: T1 review produced two follow-up findings; the valid claim-error classification concern is fixed and focused MCP/access-grants validation is green.
- Completed: T2 found storage-error propagation gaps in planning assignment validation and phase-board authorization; both now preserve database-busy/storage failures instead of collapsing them into auth denials.
- Completed: second T2 found two valid follow-up regressions; the planning assignment mismatch fallback is restored and MCP session parsing accepts explicit nil assignment fields that `public_assignment/1` can emit.
- In progress: validate the second T2 follow-up, commit/push it, then rerun T2 and GitHub review-suite lanes on the pushed head.
