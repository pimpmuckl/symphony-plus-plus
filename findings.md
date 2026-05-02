# Findings & Decisions: SYMPP-P3-002

## Requirements

- Implement worker MCP tools/resources from `implementation_docs_symphplusplus/work_packages/SYMPP-P3-002_worker-mcp-tools-and-resources.md`.
- Acceptance requires a worker lifecycle for its own package, sibling package denial, readiness gate enforcement, and actor/grant-scoped idempotent writes where appropriate.
- Hard scope excludes architect tools, skill package, dashboard/API, broader GitHub sync, Linear live state, and unrelated cleanup.

## Initial Discovery

- P3-001 scaffold already provides JSON-RPC/MCP initialization, STDIO, health tool, version/current-assignment resources, session proof revalidation, and protected-resource denial stubs.
- Current P3-001 behavior intentionally returns `worker_resources_not_implemented` for authorized work-package resource reads; P3-002 owns replacing that stub with virtual planning resources.
- MCP contract lists worker tools: `claim_work_key`, `get_current_assignment`, `read_context`, `read_task_plan`, `update_task_plan`, `append_finding`, `append_progress`, `set_status`, `report_blocker`, `request_scope_expansion`, `attach_branch`, `attach_pr`, `submit_review_package`, and `mark_ready`.
- Required resources are `sympp://assignment/current` plus scoped work-package Markdown resources for context, task plan, findings, progress, acceptance, review suite, and handoff.
- Planning renderers already own all required virtual Markdown file rendering, so P3-002 can expose them without duplicating Markdown formatting.
- Existing audited progress events already provide grant-scoped idempotency for progress-like writes; branch, PR, review package, blocker, and scope-expansion metadata are recorded as typed scoped progress events.
- The core lifecycle service only supports selected policy kinds from P1-003. To avoid broad lifecycle changes, P3-002 keeps `set_status` on the lifecycle service and implements `mark_ready` as the MCP readiness tool with local gates and terminal ready status selection.

## Open Questions

- Full P6 readiness concerns such as changed-file scope, CI sync, stale review artifacts, and GitHub merge state remain out of scope for P3-002.

## Decisions

- Keep tool registration and dispatch inside the existing MCP server unless discovery shows a local P3-001 extension point intended for worker tools.
- Use existing access-grant/session proof checks for every scoped read/write rather than trusting request-supplied work package ids.
- Require explicit `idempotency_key` for general `append_progress`; derive deterministic keys for branch/PR/review metadata tools.
- Reject request-supplied sibling `work_package_id` values on worker writes instead of silently applying them to the current package.
- T1 found `mark_ready` should use the lifecycle service rather than direct status updates so worker capability checks still apply.
- T1 found readiness evidence must come from protected metadata tools rather than free-form `append_progress` payloads.
- T1 found blocker and scope-expansion tool-owned payload fields must override caller-supplied payload metadata.
- T1 found non-map progress payloads should return a structured tool error rather than crashing during payload merge.
- T1 found skipped plan nodes should not block readiness; only pending plan nodes remain incomplete.
- Lifecycle support was widened only to the worker package kinds needed by P3 tooling (`mcp`, `skill`, `hooks`) plus existing supported kinds, leaving broader kinds such as `docs` and `standard_pr` unchanged to preserve current tracker behavior.
- Second T1 found batch requests must thread the updated MCP server state so `claim_work_key` can bind a session for later batch items.
- Second T1 found `tools/list` should advertise real per-tool worker argument schemas instead of the generic unconstrained object schema.
- T2 found `update_task_plan` must support the documented patch plus `expected_version` contract so existing pending plan nodes can be completed instead of duplicated.
- T2 found `report_blocker` needs a matching worker path to clear transient blockers before readiness; the MCP surface now includes `resolve_blocker`.
- T2 found `submit_review_package` must reject empty review evidence before satisfying readiness.
- T2 found `append_finding` needs idempotency across client retries; the worker MCP path now derives a stable finding id from the grant/package/idempotency key.
- T2 found new lifecycle-supported worker package kinds need policy templates so review-suite resources do not render unknown-policy output.
- Second T2 found every `update_task_plan` write path must require `expected_version`; append-style node creation now also goes through version checking.
- Second T2 found multi-node plan patches must be atomic; patch application now runs inside a repo transaction and rolls back on any failed node.
- Second T2 found `mark_ready` must enforce required review lanes from policy templates, not only the presence of arbitrary review metadata.
- Third T2 found `set_status` must not bypass readiness gates by transitioning directly to ready statuses; ready transitions now require `mark_ready`.
- Third T2 found review-lane readiness evidence must be structured review entries, not arbitrary free text in summary/tests/artifacts.
- Third T2 found malformed plan patch nodes must return tool errors instead of crashing during transaction rollback.
- Third T2 found storage/transaction failure classes should surface as MCP service errors rather than invalid user params.

## Takeover Findings

- The handoff's dirty `server.ex` change is no longer dirty in this worktree; it was committed and pushed as `55748aa` (`fix(mcp): tighten worker readiness gates`).
- `review-state` on `55748aa` recommends a fresh full-diff `review_t2` because the current branch has exceeded the narrow follow-up churn threshold.
- PR #15 currently has no GitHub comments, reviews, or status checks reported by `gh pr view`.
- Fresh T2 round `phase_gate-symphony-plus-plus-sympp-p3-002-e4d006-20260502T190153Z-5b4edd37` produced valid findings: `submit_review_package` schema omitted required `reviews` evidence, malformed patch ids could append duplicate nodes, and review readiness was not tied to the latest attached PR head.
- Fourth T2 fix keeps scope inside P3-002: advertise `reviews`/`head_sha`, reject non-string patch ids with `invalid_patch_node`, and accept review-lane evidence only for the latest attached PR `head_sha` when one is known.
- Fresh T2 round `phase_gate-symphony-plus-plus-sympp-p3-002-e4d006-20260502T190914Z-8b11cd9e` produced valid findings: `attach_pr` still allowed missing `head_sha`, `update_task_plan` schema did not require `expected_version`, and malformed review lane/verdict values could crash readiness checks.
- Fifth T2 fix requires PR `head_sha` at schema and runtime, advertises `expected_version` as required, and ignores review entries whose lane/verdict fields are not strings.
- Fresh T2 round `phase_gate-symphony-plus-plus-sympp-p3-002-e4d006-20260502T191607Z-dbf3be27` produced valid findings: non-map `patch` payloads could append nodes, `claim_work_key` performed a second post-claim grant read, investigation readiness skipped recommendation evidence, and metadata tools honored caller idempotency keys.
- Sixth T2 fix rejects non-map patches, builds claim sessions from the returned assignment, requires investigation recommendation evidence via `request_scope_expansion`, and forces metadata tools to use deterministic tool-owned idempotency keys.
- Fresh T2 round `phase_gate-symphony-plus-plus-sympp-p3-002-e4d006-20260502T192507Z-23d427e8` produced valid findings: claim replay after a lost response needed same-secret recovery, finding idempotency needed package scope and conflict detection, no-op plan patches needed rejection, and investigation recommendation evidence should not be modeled as scope expansion.
- Seventh T2 fix recovers claimed sessions from the same work-key secret, derives finding ids from package plus idempotency key, rejects conflicting finding retries, rejects no-op plan-node patches, and accepts a dedicated `append_progress` recommendation payload for investigation readiness.
