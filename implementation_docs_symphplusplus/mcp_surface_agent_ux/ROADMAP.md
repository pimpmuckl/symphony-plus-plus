# MCP Surface Agent UX Roadmap

## Scope And Evidence

This roadmap inventories the current agent-facing Symphony++ MCP surface and
ranks follow-up PR slices for simplifying it. It intentionally treats
`claim_local_assignment` verbosity as one symptom, not the whole problem.
`TOOL_SCHEMA_INVENTORY.md` contains a point-in-time table extracted from the
checked-in MCP contract for every tool; the contract JSON remains the source of
truth.

Evidence used:

- `implementation_docs_symphplusplus/mcp/mcp_tools_contract.json`: compact
  contract with 79 tool schemas.
- `implementation_docs_symphplusplus/mcp/MCP_TOOLS_CONTRACT.md`: human contract
  for discovery, claims, resources, and safety rules.
- `elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex`: live tool
  lists, schema definitions, authorization gates, response shaping, and error
  payloads.
- `elixir/lib/symphony_elixir/symphony_plus_plus/mcp/solo_tools.ex`: Solo
  Session schemas and error shape.
- `elixir/lib/symphony_elixir/symphony_plus_plus/agent_format/*.ex`: compact
  agent text rendering and `structuredContent` source-of-truth behavior.
- `elixir/test/symphony_elixir/symphony_plus_plus/mcp/*`: current coverage for
  claim, WorkRequest, worker, Solo, delivery, and phase surfaces.

No generated schema, runtime state, DB state, installed plugin cache, or source
behavior was mutated for this inventory.

## Surface Summary

Current discovery groups:

| Area | Count | Agent-facing concern |
|---|---:|---|
| Unbound and claim/bootstrap tools | 19 | Mixes useful local bootstrap with repo/base/caller/worktree hints that should usually be inferred. |
| Solo Session tools | 14 | Simple intent model, but `solo_attach` still requires caller/workspace/base metadata on every new local memory. |
| Worker tools | 21 | Mostly current-assignment scoped, but many tools still accept redundant `work_package_id`, idempotency keys, `head_sha`, and status guards. |
| Architect tools | 42 | Broad, powerful surface; many repeated WorkRequest/planned-slice/status arguments are defensible but painful. |
| Shared worker/architect names | 5 | Useful names, but role-dependent meaning needs clearer output and error wording. |
| Local operator HTTP tools | 2 | Keep restricted; names and args are clear enough. |
| Phase 7 stubs | 3 | Should not be prominent to agents until implemented. |

The contract is already moving in the right direction: claim docs say durable
ids are the normal coordinates, and `structuredContent` is the source of truth.
The remaining agent pain is in validation hints, recovery flows, generic
descriptions, repeated optimistic-lock/status fields, and implementation
vocabulary leaking into the tool surface.

## Ranked Findings

### P0 - Claim And Recovery Errors Block Work Before Context Exists

Classification: normalize error/output, infer/default, relax guardrail.

Current examples:

- `claim_local_assignment` schema requires only `work_package_id`, but still
  exposes optional `repo`, `base_branch`, `work_request_id`, `branch`,
  `worktree_path`, `caller_id`, and `claimed_by`.
- `claim_local_architect_assignment` requires `work_request_id`, but exposes
  optional `architect_anchor_work_package_id`, `repo`, `base_branch`,
  `phase_id`, `caller_id`, and `claimed_by`.
- Source tests cover linked WorkRequests whose parent base differs from the
  slice delivery base: claims are accepted when `planned_slice.target_base_branch`
  matches `work_package.base_branch`, and drift returns
  `package_delivery_base_mismatch`.
- Source tests also cover the `ready_for_clarification` missing-handoff symptom:
  existing WorkRequests without prepared handoff return
  `architect_handoff_not_prepared` plus expected anchor and phase ids.

Why it hurts agents:

- The agent cannot tell whether to retry with fewer args, ask the architect to
  prepare handoff, wait for lease turnover, or stop.
- Optional validation hints look like required claim coordinates, so prompts
  over-specify them and increase mismatch risk.
- A pre-context claim failure prevents the worker from using the very tools
  that would explain the package.

High-confidence simplifications:

- Keep schemas compatible, but change claim bootstrap prompts and generated
  handoffs to show durable ids by default. Optional `claimed_by` remains an
  accepted stable audit owner, but generated architect handoff prompts omit it.
- Return a stable recovery envelope for claim failures:
  `reason`, `classification`, `can_retry_with_id_only`, `operator_action`,
  `safe_next_tool`, and redacted `scope_snapshot`.
- For optional scope hints, downgrade mismatches to warnings when the durable
  id resolves to a valid live assignment and the hint came from agent prompt
  boilerplate rather than trusted runtime context.

Operator-decision behavior changes:

- Whether a claim with a valid `work_package_id` should hard-fail, warn, or
  ignore stale optional `repo`/`base_branch`/`work_request_id` hints. The
  existing source-backed delivery-base invariant should stay: linked claims are
  valid when the planned slice target base matches the WorkPackage base.

2026-06-12 implementation update:

- Worker and architect claim tool descriptions now state the normal id-only
  claim shape and label extra repo/base/phase/branch/worktree scope fields as
  advanced/debug validation hints.
- Generated architect handoff prompt references now carry only the sanitized
  `work_request_id`, optional `ledger_database`, and `local_architect_claim`
  payload with id-only claim arguments. Repo, base branch, phase, scope, and
  optional `claimed_by` remain in the ledger-backed handoff record, but are no
  longer copied into the prompt reference block.
- Planned-slice dispatch launch prompts show the minimal JSON claim arguments
  returned in `worker_bootstrap.claim.arguments`.
- Optional hint mismatches initially remained hard failures for authority
  safety, but included `classification: optional_scope_hint_mismatch`,
  `can_retry_with_id_only: true`, and `safe_next_tool` recovery fields.
- Deliberately deferred in that pass: silently ignoring mismatched optional
  hints, omitting status guards, inferring git/PR metadata, or removing
  compatible parser support for existing optional fields.

2026-06-12 recovery guardrails update:

- Caller-supplied optional scope hints are now warning-only when the durable
  `work_package_id` or `work_request_id` resolves to a valid live assignment.
  Successful claims include `recovery.reason: optional_scope_hints_ignored`,
  `ignored_optional_scope_hints`, and an id-only retry payload.
- The relaxation does not apply to server-recorded authority boundaries.
  Recorded WorkPackage worktree branch/git metadata, WorkRequest package
  linkage, slice delivery-base scope, persisted architect handoff anchor/phase
  drift, active ownership, paused leases, and terminal package state continue to
  fail closed.

### P1 - Tool Descriptions Are Too Generic For Agents

Classification: rename/reword, keep with rationale.

Current examples:

- Worker tool specs use the description `Symphony++ worker tool <name>` for
  all worker tools.
- Several architect descriptions are precise, but tool titles still mirror raw
  snake_case names.
- Phase 7 tools are exposed as schemas even though their behavior is stubbed.

Why it hurts agents:

- Tool choice relies on names alone. Similar verbs like `attach_pr`,
  `sync_pr`, `submit_review_package`, and `attach_review_suite_result` are easy
  to misuse.
- Shared names like `resolve_blocker` and `read_guidance_request` have different
  scope semantics depending on role, but discovery does not teach that.

High-confidence simplifications:

- Add short, role-specific descriptions for every worker and shared tool.
- Reword phase-stub descriptions to begin with "Not implemented" and include
  the expected fallback (`request_child_replan` should tell the architect to
  comment or create a guidance request instead).
- Add "use when" descriptions to metadata tools:
  `attach_pr` creates/records PR identity, `sync_pr` refreshes PR metadata,
  `submit_review_package` freezes delivery evidence, and
  `attach_review_suite_result` records structured Review Suite proof.

Compatibility impact: none if only descriptions and docs change.

### P1 - Redundant Current-Scope Arguments Still Leak Into Worker Tools

Classification: infer/default, remove/simplify.

Current examples:

- Current-assignment worker tools accept optional `work_package_id` even though
  bound worker sessions already have exactly one WorkPackage.
- Comment tools require `target_kind` plus `target_id` even when the common
  target is the current WorkPackage.
- `attach_branch`, `attach_pr`, `sync_pr`, `submit_review_package`, and
  `attach_review_suite_result` ask for `head_sha`, PR identity, idempotency
  keys, or metadata that can often be inferred from git/Review Suite/attached
  PR state.

Why it hurts agents:

- Agents repeat the same ids and SHAs, sometimes from stale context.
- The schema invites accidental cross-package targeting, then the server has to
  reject it with low-context errors.

High-confidence simplifications:

- Keep optional `work_package_id` for architect/shared compatibility, but hide
  it from worker prompt examples and tolerate omission everywhere.
- Add convenience defaults for comments: no `target_kind`/`target_id` means the
  current WorkPackage.
- Allow metadata tools to infer `head_sha` from current git state when the
  session has a recorded worktree path or branch attachment.
- Generate idempotency keys server-side for append-only worker progress when
  the caller omits one; preserve explicit keys for replay-sensitive clients.

Operator-decision behavior changes:

- Server-side git inference needs a clear trust boundary. It should only read
  the recorded worktree path and should fail closed when the path is absent,
  dirty in a relevant way, or outside the expected repo.

2026-06-12 implementation update:

- Worker progress, finding, blocker, scope-expansion, and guidance-request
  writes now accept omitted idempotency keys and generate server-side keys for
  the append-only case. Explicit keys still preserve replay behavior.
- Worker `add_comment` and `list_comments` default to the current WorkPackage
  when the caller omits `target_kind` and `target_id`.
- PR/review metadata writes infer `head_sha` from the latest recorded
  `attach_branch`; `sync_pr` can also infer PR identity from the latest
  recorded `attach_pr`.
- Missing recorded branch or PR context fails closed with compact recovery
  guidance instead of accepting ambiguous evidence.
- Deliberately deferred: reading live git worktrees for head inference, hiding
  `work_package_id` from every schema, changing architect defaults, or changing
  Review Suite round resolution semantics.

### P1 - Error Payloads Are Not Normalized Around Recovery

Classification: normalize error/output.

Current examples:

- Some errors include actionable `message` fields and fallback fields, for
  example Review Suite round resolution and blocker closeout.
- Many errors are only `Invalid params` plus `tool` and `reason`.
- Authorization errors sometimes include `action` and `hint`; others return
  terse policy reasons such as `work_request_scope_mismatch`.
- Solo normalization errors are structured differently from worker/architect
  errors.

Why it hurts agents:

- The agent must infer whether an error is caller-correctable, operator-needed,
  stale-state recovery, authority denial, or a real product blocker.
- Terse reason atoms become user-facing vocabulary.

High-confidence simplifications:

- Introduce a common MCP error envelope:
  `reason`, `category`, `recoverability`, `next_action`, `retryable`,
  `safe_to_retry_with_same_args`, and optional `operator_action`.
- Keep existing fields for compatibility, but add normalized fields everywhere.
- Map internal reason atoms to agent-facing text at the boundary.
- Add tests that assert recovery shape, not only reason atoms.

Compatibility impact: additive if existing reason fields remain.

### P2 - Status Guard Arguments Are Useful But Too Manual

Classification: keep with rationale, infer/default.

Current examples:

- Worker `set_status` requires `expected_status`.
- Architect status tools require `current_status` or
  `expected_question_status`.
- Deprecated `current_status` aliases remain for clarification-question tools.

Why it hurts agents:

- Agents have to re-read state just to supply an optimistic-lock token.
- Stale prompt context causes unnecessary failures even when the intended
  transition is obvious.

Keep rationale:

- Optimistic status checks prevent overwriting human/architect decisions and
  protect lifecycle integrity.

High-confidence simplifications:

- Keep explicit expected fields, but on mismatch return the current status,
  allowed next actions, and the exact retry payload.
- For low-risk close/read transitions, consider allowing omission to mean
  "use current state if it is still in the allowed domain."
- Remove deprecated alias examples from prompts and docs; keep parser support
  until the operator accepts a breaking MCP contract revision.

Operator-decision behavior changes:

- Omitting current status on mutating architect tools is data-integrity
  sensitive. Treat it as a separate PR with explicit approval.

### P2 - Product Tree And Planned Slice APIs Require Too Much Repetition

Classification: infer/default, keep with rationale.

Current examples:

- Most product-tree and planned-slice architect tools require
  `work_request_id` plus a child id.
- `add_work_request_planned_slice` requires a full execution package contract:
  acceptance criteria, globs, review lanes, validation, stop conditions, target
  base branch, kind, goal, and title.
- `move_work_request_planned_slice_to_product_node` exposes
  `product_tree_node_id`, `role`, and `position`.

Why it hurts agents:

- Architect agents repeat parent ids and long boilerplate arrays.
- The product truth model is right, but tool calls are heavier than the common
  action: "add this slice under the current WorkRequest" or "move this slice."

Keep rationale:

- These tools create durable product and execution records. Required fields are
  a useful quality gate when adding slices or changing product truth.

High-confidence simplifications:

- For claimed architect sessions, allow `work_request_id` omission where the
  session scope has exactly one WorkRequest.
- Add template helpers or defaults for common slice kinds, but keep explicit
  owned/forbidden globs and stop conditions required unless a named template is
  supplied.
- Reword `product_tree_node_id` as "plan_node_id" in docs and descriptions
  while preserving the schema field until a compatibility window is chosen.

Operator-decision behavior changes:

- Renaming schema fields is backwards-incompatible. Do this only through a
  versioned contract or alias period.

### P2 - Output Text Is Safer But Still Too Verbose And Duplicative

Classification: normalize error/output, keep with rationale.

Current examples:

- Tool responses include both text content and `structuredContent`.
- Worker/architect context encoders compact the text view and redact sensitive
  fields, but large payloads still project repo/base/branch/policy details into
  agent text.
- Resource reads include Markdown plus TOON.

Why it hurts agents:

- Agents may reason from the text content instead of the canonical
  `structuredContent`.
- Repeated operational metadata competes with the next action.

Keep rationale:

- The dual output is necessary for MCP clients that render text while still
  preserving machine-readable state.
- Redaction and payload key limits are important safety controls.

High-confidence simplifications:

- Make routine successful write-tool text `ok` by default, with at most one
  compact next-action or value line when the agent needs it immediately.
- Trim repeated repo/base/branch fields from text when they are unchanged from
  current assignment; leave them in `structuredContent`.
- Add per-tool text summaries for common worker metadata writes:
  "progress recorded", "PR attached", "review result accepted", and "ready
  marked" rather than full object dumps.

Compatibility impact: low if `structuredContent` remains unchanged.

2026-06-12 implementation update:

- Pruned agent-visible success text for high-noise MCP mutations while leaving
  `structuredContent` unchanged as the machine and audit source of truth.
- Covered worktree lifecycle, local assignment claim/release, worker progress
  and finding writes, Solo Session writes, planned-slice dispatch, and
  planned-slice delivery closeout with terse `ok` receipts and no visible
  `audit_event`, `claim_lease`, `grant_id`, `idempotency_key`, `payload`,
  `source_tool`, `source_of_truth`, `state_key`, `target_repo_root`, or
  `worker_grant` fields.
- Prepared worktree receipts deliberately keep only `workspace_path` and
  `branch`, because launching a worker needs those exact values. Dispatch and
  claim/release receipts may include one compact `next:` line; routine cleanup,
  progress, comment, decision, delivery, and Solo writes default to plain `ok`.
  Read-oriented `get_current_assignment`, `solo_show`, and `solo_list` keep
  compact summaries so agents can recover the current binding and Solo history
  from visible text without exposing claim leases, session keys, or entry
  payloads. `solo_show` preserves returned/truncated counts.
- Deliberately deferred read-heavy WorkRequest/product-tree/delivery-board
  views and MCP resources. Those surfaces still need compact context, not a
  one-line mutation receipt. Error payloads also remain structurally detailed
  until a separate error-output pass defines which recovery fields can be
  hidden from text.

### P3 - Lifecycle Vocabulary Leaks Internal Implementation

Classification: rename/reword.

Current examples:

- Agent-facing words still expose low-level assignment ownership,
  authority-reset, phase-routing, source-root, and local-correlation details.
- Some terms are accurate for operators but noisy for worker agents.

Why it hurts agents:

- Agents focus on implementation artifacts instead of the action they can take.
- Error recovery becomes harder because low-level ownership words sound like
  separate actions to a caller.

High-confidence simplifications:

- Introduce an agent-facing glossary:
  assignment, current package, current WorkRequest, recovery, stale session,
  operator action, and authority.
- Keep internal terms in structured audit payloads, but map them in human text.
- Rename docs/prompts before schema fields.

Compatibility impact: none for text-only rewording.

2026-06-12 implementation update:

- Added a shared presentation vocabulary for dashboard and delivery-board
  projections. To avoid breaking current board and product-tree consumers,
  existing `operational_state.key` values remain detailed, while the compact
  vocabulary is exposed as `presentation_key`/`presentation_label`:
  `ready`, `working`, `blocked`, `needs_review`, `delivered`,
  `stale_recoverable`, or `operator_action`.
- Existing detailed projection states are preserved as `key` and `source_key`,
  while persisted audit states remain in `raw_status`, `work_package_status`,
  `delivery_outcome`, and `attention_reason_codes`. Delivery-board `counts`
  stays detailed; `presentation_counts` carries the compact aggregate and
  `source_counts` preserves recorded delivery outcomes such as `pr_merged`.
- Product-tree completion treats terminal delivery source outcomes such as
  `superseded` and `abandoned` as done, so detailed keys can remain stable
  without regressing product-tree summaries.
- Current mapping:
  - `ready`: `created`, `draft`, `not_started`, `planned`, `prepared`,
    `ready_for_worker`, `ready_for_slicing`, `sliced`, and hidden linked
    `dispatched` states.
  - `working`: `active` and `merging`.
  - `blocked`: `blocked`.
  - `needs_review`: `reviewing`, `ci_waiting`, and `merge_ready`.
  - `delivered`: recorded delivery outcomes and terminal/completed states,
    including `delivered`, `completed_no_pr`, `completed`, `merged`, `closed`,
    `skipped`, `superseded`, and `abandoned`.
  - `stale_recoverable`: `started_paused`, `stale`, `recycled`, and recovered
    runtime lifecycle projections.
  - `operator_action`: `human_info_needed`, `clarifying`, `needs_attention`,
    `needs_closeout`, `paused`, `unknown`, and unmapped source states.
- Reworded normal MCP and architect handoff descriptions away from low-level
  ownership, scope-routing, and reset-authority language where field names or
  audit payloads did not require those terms.
- Deliberately deferred: persisted DB status removal, migration work, MCP field
  renames/removal, audit reason-code pruning, and delivery closeout semantic
  changes. Those need a separately approved compatibility/migration decision.

### P3 - Phase And Child-Package Stubs Should Be Less Visible

Classification: remove/simplify, rename/reword.

Current examples:

- `request_child_replan`, `split_work_package`, and `publish_phase_update` are
  exposed as Phase 7 architect tools while behavior is not implemented.
- Phase child tools are valid for a narrow authority model, but most architects
  work through WorkRequest/product-tree slices.

Why it hurts agents:

- Discoverable stubs encourage calls that cannot succeed.
- The agent may choose a phase-child path when planned slices are the product
  truth surface.

High-confidence simplifications:

- Hide unimplemented stubs from default discovery, or mark them as disabled
  with clear descriptions and deterministic "not implemented" errors.
- Keep implemented phase-child tools only for sessions that actually carry
  phase authority.

Compatibility impact: hiding tools may affect clients that expect schemas.
Prefer description/error rewording first unless the operator approves a
contract revision.

## Full Tool Inventory

See `TOOL_SCHEMA_INVENTORY.md` for a point-in-time table extracted from the checked-in contract with all 79 MCP tool schemas, discovery groups, required args, required argument sets, optional args, and scout classifications. The source of truth remains `implementation_docs_symphplusplus/mcp/mcp_tools_contract.json`; this roadmap keeps only ranked findings and follow-up PR sequencing.

## Proposed PR Sequence

1. Claim recovery and id-first bootstrap cleanup.
   - Update worker/architect prompt generation and contract docs to show
     id-only claim examples.
   - Normalize claim failure envelopes.
   - Preserve the existing delivery-base invariant for linked feature-branch
     slices; add coverage only for newly reproduced `work_request_scope_mismatch`
     recovery paths.
   - Operator decision needed for any guardrail relaxation.

2. Tool descriptions and vocabulary pass.
   - Replace generic worker descriptions with action-oriented descriptions.
   - Reword internal lifecycle vocabulary in text responses and docs.
   - Mark Phase 7 stubs as disabled/not implemented in descriptions and errors.
   - No behavior change.

3. Worker current-scope defaults.
   - Default comments to the current WorkPackage.
   - Hide optional `work_package_id` in worker docs/examples.
   - Add server-generated idempotency for low-risk append-only worker/Solo
     events while preserving explicit key replay behavior.
   - Add tests for omitted optional package ids and generated keys.

4. Metadata inference for branch, PR, and review evidence.
   - Infer `head_sha` from a recorded safe worktree path when available.
   - Let `sync_pr` use the attached PR when no PR identity is supplied.
   - Improve Review Suite round error recovery messages.
   - Fail closed when git state is absent, dirty in relevant files, or outside
     recorded scope.

5. Common MCP error envelope.
   - Add normalized `category`, `recoverability`, `next_action`, and retry
     fields to worker, architect, Solo, and local-operator errors.
   - Keep existing `reason` fields for compatibility.
   - Add contract tests that compare shape across representative tools.

6. Architect scoped-default pilot.
   - Allow claimed architect sessions with exactly one WorkRequest scope to
     omit `work_request_id` for read-only tools first.
   - If successful, extend to selected low-risk mutating tools with explicit
     operator approval.
   - Keep planned-slice creation and delivery closeout explicit unless a named
     template supplies missing contract fields.

7. Versioned compatibility cleanup.
   - Decide whether to remove deprecated aliases like `current_status` for
     question status.
   - Decide whether to rename schema fields such as `product_tree_node_id` or
     keep docs-only aliases.
   - Publish a new MCP contract version only after clients have an alias window.

## Review Notes

High-confidence changes are mostly additive: docs, descriptions, output text,
error envelopes, and defaults that preserve explicit arguments. Authority and
data-integrity-sensitive changes are explicitly separated:

- Relaxing claim scope mismatches.
- Omitting status guards on mutating architect tools.
- Reading git state to infer `head_sha`.
- Hiding tools from discovery instead of merely marking them disabled.
- Renaming schema fields.

Those need operator approval before implementation because the repository
instructions say not to assume backwards compatibility.

## Validation Plan For Follow-Up PRs

Each implementation PR should update both source and the compact contract, then
run focused MCP tests for the touched category. Candidate test targets:

- Claim/recovery: `elixir/test/symphony_elixir/symphony_plus_plus/mcp/claim_session_transport_*_test.exs`
- Worker defaults: `elixir/test/symphony_elixir/symphony_plus_plus/mcp/worker_tools_*_test.exs`
- Architect defaults: `elixir/test/symphony_elixir/symphony_plus_plus/mcp/work_request_tools_*_test.exs`
- Solo defaults: `elixir/test/symphony_elixir/symphony_plus_plus/mcp/solo_schema_*_test.exs`
- Error normalization: `elixir/test/symphony_elixir/symphony_plus_plus/authorization/mcp_error_test.exs` plus representative MCP tool tests.
- Contract drift: whatever generator/check currently owns
  `implementation_docs_symphplusplus/mcp/mcp_tools_contract.json`.

For this scout PR, validation is documentation-only: schema/source searches and
`git diff --check` are sufficient unless Review Suite brief can run cleanly.
