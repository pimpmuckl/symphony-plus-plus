# MCP Tools Contract

This document mirrors `mcp_tools_contract.json` in readable form.

## Worker tools

| Tool | Purpose |
|---|---|
| claim_work_key | Claim a one-time work key/secret with required `claimed_by` owner identity and bind the current MCP session to the grant role for legacy/recovery bootstrap. |
| get_current_assignment | Return the scoped assignment for the bound grant. |
| read_context | Read context.md for the current work package. |
| read_task_plan | Read task_plan.md for the current work package. |
| update_task_plan | Patch the plan with optimistic concurrency. |
| append_finding | Append a finding to the current work package. |
| append_progress | Append a progress event to the current work package. |
| set_status | Request a valid state transition. |
| report_blocker | Record an active blocker. |
| resolve_blocker | Record that an active blocker was cleared. |
| add_comment | Add a redacted contextual note to a scoped WorkPackage, linked planned slice, or parent WorkRequest. |
| list_comments | List redacted comments for a scoped WorkPackage, linked planned slice, or parent WorkRequest. |
| resolve_comment | Mark a scoped comment resolved with server-owned worker attribution. |
| create_guidance_request | Create a package-scoped guidance request for product, architecture, dependency, or slice-boundary ambiguity. |
| read_guidance_request | Read a package-scoped guidance request visible to the current worker assignment. |
| request_scope_expansion | Request broader scope; does not approve it. |
| attach_branch | Attach branch metadata with the current branch head SHA. |
| attach_pr | Attach PR metadata. |
| sync_pr | Refresh metadata for the already attached PR. |
| submit_review_package | Attach summary/tests/artifacts for the current head review package. |
| attach_review_suite_result | Attach canonical Review Suite result evidence for the current WorkPackage head. |
| mark_ready | Move to ready state only if gates pass. |

Valid current-head review package or passing Review Suite evidence may normalize
stale active package statuses (`ready_for_worker`, `claimed`, `planning`, or
`implementing`) to `reviewing`. `attach_review_suite_result` accepts passing
status values `passed`, `pass`, `green`, `success`, `completed` and passing
verdict values `green`, `clean`, `passed`, `pass`, `success`, `approved`.

`claim_private_handoff` is intentionally not a bound worker mutation tool in
this table. It is listed under Bootstrap tools for explicit legacy/recovery
claim paths.

Worker comment tools stay inside the bound WorkPackage assignment. They do not
broaden worker authority, mutate sibling targets, or expose raw note text after
the normal planning redactor has matched a secret-like value. Worker comment
author and resolver attribution are derived from the claimed MCP session rather
than accepted from caller input. Comment bodies are capped at 4,000 characters,
resolution notes at 1,000 characters, and list responses at 100 comments per
target.

## Bootstrap tools

| Tool | Purpose |
|---|---|
| claim_local_assignment | Claim the normal V2.1 ledger-backed local WorkPackage assignment and bind the current MCP session without raw secrets. |
| claim_local_architect_assignment | Claim or reconnect a normal ledger-backed local WorkRequest architect assignment and bind the current MCP session without private handoff files. |
| claim_work_key | Claim a one-time work key/secret with required `claimed_by` owner identity and bind the current MCP session to the grant role for legacy/recovery bootstrap. |
| claim_private_handoff | Claim an existing worker or architect grant from `local-private-file` handoff metadata for legacy/recovery bootstrap. |
| create_work_request | Create a local WorkRequest with creator provenance and return a redacted architect handoff/bootstrap payload. |

`claim_work_key` appears in both surfaces because the runtime advertises the
legacy/recovery claim tool before and after binding. It is not the normal V2.1
worker claim path.

## Local operator tools

| Tool | Purpose |
|---|---|
| add_work_request_comment | Append a redacted local-operator comment to a WorkRequest by id. |
| record_work_request_operator_decision | Record a redacted local-operator decision on a WorkRequest by id. |

Local operator note tools require an unbound trusted local HTTP MCP session
with explicit state-key continuity and a file-backed local ledger. They do not
grant WorkRequest ownership, dispatch authority, lifecycle authority, or sibling
package visibility. Text and provenance are redacted before storage/response;
responses never include raw secrets, private handoff payloads, work keys,
bearer tokens, or MCP auth tokens.

## Health tool

`sympp.health` returns server status, version/source revision, mode, and
`ledger.reachable` as before. It also includes `ledger.identity`, a JSON-safe
ledger identity for operator diagnosis:

- Local SQLite ledgers report `kind: "sqlite"`, `source: "default"` when the
  MCP database option is omitted or `source: "explicit"` when an explicit
  SQLite database was configured, plus `display_path` and `default_home`.
- SQLite file URI query parameters are not echoed; `display_path` is derived
  from the URI path only.
- Remote/server-style ledger configuration reports `kind: "server"` and a
  redacted `endpoint` containing only scheme, host, and port. Userinfo,
  passwords, tokens, query strings, fragments, and raw credential-bearing
  connection strings are never returned.

## Architect tools

| Tool | Purpose |
|---|---|
| create_child_work_package | Create a `phase_child` work package inside the architect grant's current phase; child repo, phase, parent, and base branch are constrained to the architect phase anchor. |
| mint_child_worker_key | Mint a child-scoped worker grant for a same-phase `phase_child` package; worker capabilities are limited to the child worker set, and explicit expiry cannot exceed an explicitly expiring architect grant. |
| revoke_child_worker_key | Revoke one live child-delegated worker grant for a same-phase child package inside the architect grant's frozen scope, reset active/interrupted children to `ready_for_worker`, and make immediate remint available. |
| list_work_requests | List WorkRequests scoped to the architect assignment repo/base branch; trusted local unbound HTTP sessions may list redacted local-ledger summaries. Accepts only optional `status`. |
| read_work_request | Read one scoped WorkRequest with clarification questions, decision log entries, visible planned slices, and count/status summaries. |
| read_work_request_delivery_board | Read the scoped WorkRequest delivery-board projection for visible planned-slice closeout without broad package visibility. |
| set_work_request_status | Move a scoped WorkRequest between valid statuses with optimistic `current_status` checking. |
| ask_work_request_question | Add a clarification question to a scoped WorkRequest, optionally with a structured human decision prompt. |
| answer_work_request_question | Answer an open clarification question that belongs to a scoped WorkRequest. |
| answer_work_request_question_and_record_decision | Answer an open clarification question and atomically record the resulting WorkRequest decision. |
| close_work_request_question | Close an open clarification question that belongs to a scoped WorkRequest without recording an answer. |
| record_work_request_decision | Record a durable decision log entry on a scoped WorkRequest. |
| add_work_request_planned_slice | Add a planned slice to a scoped WorkRequest. |
| approve_work_request_planned_slice | Approve a planned slice that belongs to a scoped WorkRequest. |
| skip_work_request_planned_slice | Skip a planned slice that belongs to a scoped WorkRequest. |
| mark_work_request_sliced | Mark a scoped WorkRequest sliced using the existing approved-slice requirement. |
| dispatch_work_request_planned_slice | Dispatch one approved planned slice into a WorkPackage with ledger-backed local worker claim metadata. |
| prepare_work_package_worktree | Prepare a scoped WorkPackage git worktree under `CODEX_HOME/worktrees/spp_worktrees` and record only `worktree_path`. |
| cleanup_work_package_worktree | Clean up a scoped WorkPackage git worktree after validating the recorded path and dirty state. |
| read_child_status | Read the architect grant's scoped anchor package status, or a same-phase child work-package status when the architect grant has child read capabilities. |
| read_phase_board | Read the architect grant's scoped phase board, filtered to the frozen repo/base branch for explicit phase grants, including merged-child phase progress. |
| request_child_replan | Phase 7 stub for child replan requests; returns `phase7_not_implemented` after architect authorization. |
| approve_child_ready_state | Approve a same-phase `phase_child` in `ready_for_architect_merge` after readiness gates still pass; records a local audit event and moves the child to `merging_into_phase`. Optional `request_id` is the explicit retry identity. |
| merge_child_into_phase | Record a local merge artifact for an approved phase child and move it to `merged_into_phase`; does not perform a live Git merge. |
| split_work_package | Phase 7 stub for child package splitting; returns `phase7_not_implemented` after architect authorization. |
| publish_phase_update | Phase 7 stub for phase updates; returns `phase7_not_implemented` after architect authorization. |

Architect tools require a live architect grant session and the matching
architect capability from the permission model, except for the trusted local
unbound WorkRequest read-only discovery path documented below. Worker grants
and architect grants without the required capability are denied at call time.
Worker grants cannot be minted with architect-only MCP capabilities such as
`read:phase`, `read:child_progress`, or `mint:child_worker_key`. `tools/list`
is predictable session-shape discovery, not authorization:

- Healthy unbound generic sessions advertise health, Solo Session bootstrap
  tools, `claim_work_key`, `claim_private_handoff`, and
  `create_work_request`. They do not advertise architect schemas or bound
  worker WorkPackage schemas.
- Unbound HTTP sessions additionally advertise `claim_local_assignment` and
  `claim_local_architect_assignment` so local worker and architect sessions can
  claim or reconnect without private handoff files.
- Trusted unbound local HTTP sessions with explicit state-key continuity may
  additionally advertise the local operator note tools described above and
  WorkRequest read-only discovery tools: `list_work_requests`,
  `read_work_request`, and `read_work_request_delivery_board`.
- Bound worker sessions advertise health, `get_current_assignment`, and bound
  worker WorkPackage tools. They do not advertise Solo tools, architect-only
  tool schemas, or claim/bootstrap tools.
- Bound architect sessions advertise health, `get_current_assignment`, and the
  static architect schema set. Target, capability, phase, and scope
  authorization still runs when an architect tool is called.

Claim calls still require trusted local HTTP state-key continuity and scope
validation, and worker WorkPackage calls before a valid worker claim return a
claim-required denial without mutating state. For trusted local HTTP sessions
that denial points callers at `claim_local_assignment`; generic unbound
sessions still point at `claim_work_key`.
Architect calls still require a live claimed architect grant with the required
capability and scope, and unclaimed architect calls return a claim-required
denial. Stale bound sessions expose only health, `claim_work_key`,
`claim_private_handoff`, and, on HTTP sessions, `claim_local_assignment` and
`claim_local_architect_assignment` for refresh; duplicate
`initialize` on that same stale explicit MCP session
does not downgrade it into generic unbound discovery. Bound architect sessions
may call `get_current_assignment` and read `sympp://assignment/current` to
recover their scoped `work_package_id` after reconnect, but architect sessions
still cannot use worker package read/write tools. Phase-board readers are
limited to the session's phase scope; explicit phase grants with a frozen
repo/base snapshot
materialize only matching package cards across MCP, API, and browser board
surfaces, and explicit phase grants missing that snapshot fail closed rather
than being treated as phase-wide. Existing lifecycle
capabilities such as
`architect:lifecycle.transition` do not imply MCP architect tool authorization;
P3-003 requires the explicit MCP capability strings listed in the permission
model at call time. WorkRequest mutation and dispatch schemas are discoverable
before claim and for bound architect sessions even when the current grant lacks
capability or usable frozen scope; direct mutation and dispatch calls fail
closed until an explicit phase-scoped architect grant with the required frozen
repo/base-branch scope and `write:work_request` or `dispatch:work_request`
capability is live. WorkRequest read schemas are also discoverable before
claim, but only the trusted local unbound read-only discovery path below may
execute without an architect grant. Legacy null-`phase_id` architect grants do
not authorize those tools. Phase-dependent
architect tools revalidate the grant's explicit phase scope plus the anchor
repo/base-branch scope frozen when the phase architect grant was minted.
Legacy null-`phase_id` grants may still derive the current
explicit anchor phase for non-delegation phase reads, but P7 child
delegation/status operations fail closed when the frozen repo/base-branch
snapshot is missing. `create_child_work_package` always creates a `phase_child`
package under the architect phase anchor, rejects mismatched `phase_id`,
`parent_id`, `repo`, or `base_branch`, inherits the anchor base branch because
there is no separate phase base-branch policy field, requires concrete nonempty
child file globs, and revalidates anchor scope in the insert transaction. Empty
anchor file globs are allowed only when the child explicitly supplies nonempty,
non-overbroad globs; nonempty anchor globs remain the upper bound. It does not
support context-slice input in this contract. `mint_child_worker_key` only mints
single-package worker grants for same-phase child packages; the minted worker
grant cannot include architect capabilities, cannot include capabilities outside
the child worker capability set, rejects new mints while any active
child-delegated worker grant already exists for that child, ignores unrelated
normal worker grants, and cannot outlive the transaction-current architect
grant when that architect grant has an explicit expiry. With a non-expiring
architect grant, the child worker grant defaults to non-expiring and may use a
future explicit expiry. This is the pre-production v1 contract and does not provide implicit
replacement/remint behavior. The tool stores the newly minted child worker
secret through the private SecretHandoff store and returns only redacted
metadata under `worker_grant.secret_handoff`; `worker_grant.secret_in_response`
is always `false`, and `secret` / `secret_returned_once` are not part of the
response. Returned handoff metadata includes non-secret bootstrap fields,
including the resolved `claimed_by` identity and `run_mcp_command` when
generated by SecretHandoff; those fields must not embed the raw worker secret.
The MCP server must be configured with `repo_root`/`--repo-root` before child
minting so handoff scripts are resolved from an operator-chosen repository root;
minting fails before grant creation if the expected handoff script is missing
there. `template.secret_handoff` may specify only `mode`, `store_dir`, and
`claimed_by`; unexpected fields or blank values are rejected and do not alter
worker-grant capabilities. `revoke_child_worker_key` requires
`revoke:child_worker_key`, revalidates the live architect grant and frozen
phase anchor scope, and revokes only a live child-delegated worker grant for a
same-phase child package. If the child is active/interrupted (`claimed`,
`planning`, `implementing`, `reviewing`, `ci_waiting`, or `blocked`), the tool
resets it to `ready_for_worker` so `mint_child_worker_key` can immediately
remint. It rejects unrelated grants, normal worker grants, sibling/out-of-scope
children, already revoked or expired grants, and children already in
architect-controlled/closed/merged or terminal states. The response and durable
audit/progress event are redacted and include only safe child package/grant
metadata, previous and new child statuses, and the redacted recycle reason;
persisted private handoff cleanup is not performed in this v1 package.
For claimed architect sessions, `list_work_requests`, `read_work_request`, and
`read_work_request_delivery_board` require `read:work_request`, are read-only,
and require an explicit phase-scoped architect grant with frozen
repo/base-branch scope. They do not accept caller-supplied repo or base-branch
arguments. Legacy null `phase_id` architect grants are not supported for
WorkRequest MCP reads and fail closed rather than deriving scope from a mutable
anchor package. Trusted local unbound HTTP sessions with explicit state-key
continuity and a file-backed local ledger may also call the same read-only
tools without an architect claim for non-secret local-ledger discovery.
`list_work_requests` returns redacted WorkRequest summaries for that local
ledger, accepts only optional `status`, and reports scope as
`visibility: "local_ledger"` rather than a repo/base authorization snapshot.
`read_work_request` requires `work_request_id` and accepts optional
`include_planning_scratch`; `read_work_request_delivery_board` accepts the same
visibility flag. The unbound read path may inspect only visible local
WorkRequest state and planned-slice/delivery-board projections. It does not
grant WorkRequest ownership, dispatch authority, lifecycle authority, secret
access, worker package write authority, or arbitrary local file access.
Skipped never-dispatched planned slices with no WorkPackage and no
planned-slice delivery record are hidden by default as planning scratch, not
delivery work. When included, delivery-board slices are classified as
`planning_scratch`. Missing or out-of-scope WorkRequests fail closed as not
found without leaking sibling content. Payloads are JSON-safe and redacted:
they exclude work-key secrets, grant verifiers, bearer/API/GitHub tokens,
private handoff payloads, and worker secret material. MCP tools must not be
bypassed with direct SQLite deletion for planning scratch cleanup.
`set_work_request_status`, `ask_work_request_question`,
`answer_work_request_question`, `answer_work_request_question_and_record_decision`,
`close_work_request_question`, and `record_work_request_decision` require
`write:work_request`, the same explicit phase-scoped frozen repo/base-branch
scope, and `work_request_id` on every mutation. They do not accept
caller-supplied repo or base-branch arguments. Answer and close calls also
verify that `question_id` belongs to the scoped WorkRequest before mutating and
default the expected question status to `open`. Callers should omit question
status; optional `expected_question_status=open` and deprecated
`current_status=open` are accepted only as legacy guards. Other values return a
structured `invalid_question_status` error. Sibling question ids fail closed as
not found.
Responses return JSON-safe redacted updated question or decision objects plus a
minimal parent WorkRequest status projection and scope/status metadata; they do
not return the full `read_work_request` detail shape. These tools cover only
the clarification and decision loop; they do not author, approve, skip, or
dispatch planned slices, create WorkPackages, alter SecretHandoff, mutate
Linear, or change dashboard behavior. They expose the existing WorkRequest
service primitives: status movement is explicit through
`set_work_request_status`, and question/decision tools do not mirror
dashboard-only helper guards, auto-transition parent status, or add a new
lifecycle/status transition matrix.
`record_work_request_decision.source_type` must be one of `human`,
`architect`, `operator`, or `ask_pro_advisory`; the live MCP input schema
advertises this enum.
`ask_work_request_question` may include an optional `decision_prompt` object
with redacted `tl_dr`, `details`, one to four answer `options`, and optional
`custom_redirect_label`. Responses include the redacted structured prompt when
present while preserving plain-text question fields for fallback clients.
`custom_redirect_label` only customizes the visible freeform redirect label;
the local operator redirect path remains available when the field is omitted and
stores only the operator's replacement guidance note.
`add_work_request_planned_slice`, `approve_work_request_planned_slice`,
`skip_work_request_planned_slice`, and `mark_work_request_sliced` also require
`write:work_request`, the same explicit phase-scoped frozen repo/base-branch
scope, and `work_request_id` on every mutation. Approve and skip verify that
`planned_slice_id` belongs to the scoped WorkRequest before mutating and fail
closed as not found for sibling slices. Add and approve validate
`owned_file_globs` against the parent WorkRequest path constraints before
mutation. `docs` slices also require documentation-only owned globs. `**` must be a complete path segment: `scripts/**/deploy*.ps1` and
`.github/workflows/**` are valid; `scripts/**deploy**`,
`scripts/**server**`, and `packages/**kraken_batch**` are invalid and return
structured validation details with field, value, and reason. `mark_work_request_sliced` uses the
existing WorkRequest service behavior, including the approved-or-dispatched
slice requirement. Responses return JSON-safe redacted planned-slice or
WorkRequest status projections plus scope/status metadata. These tools do not
dispatch planned slices, create WorkPackages, alter SecretHandoff, mutate
Linear, run automatic slicing/package generation, or change dashboard behavior.
`add_work_request_planned_slice.work_package_kind` must be one of the
standalone dispatchable WorkPackage kinds advertised by the live MCP input
schema: `quick_fix`, `hotfix`, `docs`, `investigation`, `adapter`, `mcp`,
`skill`, or `hooks`.
`add_work_request_planned_slice.branch_pattern`, when supplied, must be an
exact branch or a `{{placeholder}}` template. Git wildcard patterns such as `*`
are rejected with structured branch-pattern validation details before dispatch
or worker claim.
`record_planned_slice_delivery` with `outcome=abandoned` is the supported repair
path for a linked no-code dispatch that failed before implementation, including
a `ready_for_worker` package whose managed worktree has already been cleaned.
It may retire unclaimed worker-grant and stale claim-lease evidence for that
linked package only. It still rejects claimed worker authority, active agent
runs, paused leases, active blockers, or an uncleared recorded worktree.
`revoke_planned_slice_worker_key` remains limited to closeout-ready packages and
is not required before this abandoned no-code repair path.
`dispatch_work_request_planned_slice` is separate from those mutation tools and
requires `dispatch:work_request` because it creates a WorkPackage, worker grant,
and worker bootstrap side effects. It does not prepare or record worktree scope;
that belongs to `prepare_work_package_worktree` or the equivalent operator
worktree flow before worker launch. It requires
`work_request_id`, `planned_slice_id`, and `claimed_by`, with optional
`symphony_repo_root`, `legacy_private_handoff`, `secret_handoff`, and
`secret_store_dir`, uses the same frozen repo/base-branch WorkRequest scope, and
calls the existing `PlannedSliceDispatch.dispatch` orchestration. MCP dispatch
has a statically discoverable schema, and direct calls fail closed if
the supplied `symphony_repo_root`, legacy hidden `repo_root` alias, configured
`repo_root`, or local Symphony++ repo root is missing, invalid, or does not
point at a repository containing the worker secret helper script under
`scripts/` when explicit legacy private handoff recovery is requested. This
root is the Symphony++ helper/namespace repo root, not the target product
repository root. `secret_handoff` and `secret_store_dir` are rejected unless
`legacy_private_handoff` is true. Dispatch requires a file-backed live ledger
so worker bootstrap metadata reconnects to the same ledger; in-memory database configuration
fails closed before dispatch side effects. Blank database configuration is
treated as absent and uses the live ledger. Matching configured SQLite file URI
options are preserved in the worker bootstrap metadata when they resolve to the
same live ledger, including default
repo database configuration; divergent explicit MCP database configuration fails
closed, and matching read-only SQLite URI options such as `mode=ro` or
`immutable=1` are rejected before dispatch. Missing, out-of-scope,
non-approved, invalid-status, unsupported-kind, and
unsupported branch-pattern wildcard, and slice-scope violations fail closed
before returning sibling content or raw
secret material. The response is intentionally narrower than CLI output:
WorkRequest id, planned slice id/status/linkage, WorkPackage id metadata,
non-secret worker bootstrap metadata for `claim_local_assignment`, and any
redacted worker handoff or grant metadata the current runtime still emits.
Dispatch-link failure responses may include sanitized recovery identifiers such
as WorkPackage id, worker grant id, cleanup status, and redacted bootstrap
metadata. It must not include raw worker secrets,
work keys, bearer tokens, API tokens, MCP auth tokens, private-store secret
payloads, or secret-bearing claim URLs.
`prepare_work_package_worktree` and `cleanup_work_package_worktree` are
architect dispatch tools gated by `dispatch:work_request`. They require the
target `work_package_id` to be linked from a planned slice on a WorkRequest in
the architect grant's frozen repo/base-branch/phase scope, and out-of-scope or
unlinked packages fail closed as not found. `prepare_work_package_worktree`
requires `target_repo_root`, `base_branch`, and a concrete `branch`; accepts
validates `target_repo_root` against the scoped WorkPackage repository,
validates git ref names against `target_repo_root`; requires `base_branch` to
match the WorkPackage; resolves `CODEX_HOME` with fallback to `~/.codex`;
builds a safe
path under
`CODEX_HOME/worktrees/spp_worktrees/<repo-name>-<repo-hash>/<package-id>-<sanitized-branch>-<branch-hash>`,
fetches `origin/<base_branch>` into the local remote-tracking ref, creates the
linked worktree from that remote branch, records only `worktree_path`, and
returns a compact worker launch block. Git failures return sanitized status,
stderr, target repo root, worktree destination, branch, and base branch
diagnostics. Replays with the same recorded existing path return
`already_prepared`.
`cleanup_work_package_worktree` requires `target_repo_root`; reads the recorded
path, verifies it remains inside the managed S++ worktree root, refuses dirty
worktrees, removes the git worktree through the supplied target repository after
proving the recorded worktree belongs to that repository, prunes stale worktree
metadata, clears
`worktree_path`, and appends redacted progress/audit evidence. It does not
run worktree-local Git commands from missing, empty, or unusable non-git
managed directories; missing recorded paths, verified empty non-git directories,
and directories containing only a broken `.git` metadata file under the managed
root are treated as stale cleanup metadata, with removal allowed only after
ownership/root checks. It does not force-remove dirty worktrees, clean arbitrary
paths, clean non-empty non-git directories with non-metadata files, clean
worktrees from a different repository, alter worker secrets, or perform
automatic cleanup when package statuses change.
`read_child_status` requires both `read:child_progress` and
`read:child_findings` because its summary includes progress, findings, and
artifact counts. `approve_child_ready_state` revalidates the ready child against
current readiness evidence, active phase state, and the frozen phase-child
repo/base/file scope before recording approval. There is no approval override in
this contract. Exact approval retries replay across renewed architect grants for
the same actor only when the caller supplies the same `request_id`; the human
`rationale` is audit text and is not idempotency key material.
Same-`request_id` retries within the same ready-state cycle replay the original
approval audit event; retry rationale edits do not mutate the recorded audit
rationale. Re-approval after a real blocked/reworked/readied cycle records a new
approval audit event even when the same `request_id` and rationale text are
reused. Approved children are architect-controlled, except the child worker may
move `merging_into_phase` back to `blocked` to represent a merge blocker before
further worker follow-up.
`merge_child_into_phase` accepts only local merge artifacts with
`status: "merged_into_phase"` and a nonempty `uri`, records them as a
`phase_merge` artifact on the child package, and marks the child
`merged_into_phase`. The full accepted `merge_artifact` is preserved as artifact
metadata. Exact merge retries replay across renewed scoped architect grants even
when the renewed grant has a different `claimed_by`; after the child is merged,
a new valid merge artifact updates the local `phase_merge` record and appends
an audit event without another lifecycle transition while the phase remains
active; exact older retries do not overwrite newer artifact data. Merge
finalization and post-merge artifact updates are rejected after the phase
closes. Phase-board progress summary totals are computed after backend
authorization and frozen repo/base scope filters, then remain stable across
client-side board filters; abandoned children are excluded, and closed children
still count in the merge-progress denominator but are not open work. Remaining
Phase 7-dependent tools perform authorization first and then return an explicit
`phase7_not_implemented` error; they do not publish phase state in P7-003.

## Resources

```text
sympp://assignment/current
sympp://work-packages/{id}/context.md
sympp://work-packages/{id}/task_plan.md
sympp://work-packages/{id}/findings.md
sympp://work-packages/{id}/progress.md
sympp://work-packages/{id}/acceptance.md
sympp://work-packages/{id}/review_suite.md
sympp://work-packages/{id}/handoff.md
```

Resources may include compact `text/vnd.toon` content for agent-facing context
presentation. TOON is never the MCP input contract and is not the canonical
machine-readable response. MCP tool arguments stay JSON/schema-native, and tool
results keep `structuredContent` as the schema-native source of truth.

`claim_local_assignment` requires `repo`, `base_branch`, `work_package_id`,
`branch`, `worktree_path`, `caller_id`, and `claimed_by`; `work_request_id` is
accepted for planned-slice dispatch. It is the normal V2.1 local worker claim.
The tool validates package repo/base/branch/worktree scope, requires a trusted
local HTTP MCP session, creates or heartbeats a claim lease, reclaims stale
leases with audit evidence, rejects paused leases, same local owner claims that
change `caller_id` before the live-grant authority check, or active other
owners, and binds the current MCP session to the package worker grant.

`claim_local_architect_assignment` requires `work_request_id`,
`architect_anchor_work_package_id`, `repo`, `base_branch`, `caller_id`, and
`claimed_by`; `phase_id` may be supplied for validation. It is the normal local
WorkRequest architect claim. The tool is visible only on HTTP discovery
surfaces, requires a trusted local HTTP MCP session with explicit state-key
continuity and a file-backed local ledger, validates the WorkRequest repo/base,
architect anchor package, phase, and live architect grant authority, then binds
the current MCP session to the existing architect grant. Replays with the same
local owner heartbeat the claim lease; stale leases may be reclaimed with audit
evidence. Remote, untrusted, stateless, scope-mismatched, terminal, revoked, or
private-file-dependent paths fail closed.

Identity fields are deliberately separate:

| Field | Meaning | Reconnect rule |
| --- | --- | --- |
| `claimed_by` | Durable grant/authority owner. For generated local architect handoffs, pass `local_architect_claim.arguments.claimed_by` unchanged, normally `symphony-architect`. | Do not replace with `Codex`, account names, or user names. |
| `caller_id` | Current local MCP runtime, launcher, or thread identity. | Generate a stable value for this runtime and reuse it for reconnects from the same runtime. |

If `claim_lease_active_for_other_actor` appears, do not guess a new
`claimed_by`. Retry with the handoff `claimed_by`, or ask the operator to
recycle a stale local claim.

`claim_work_key` requires `secret` and `claimed_by`. It can bind an existing
worker or architect grant during explicit legacy bootstrap/recovery; it does
not mint new grants and is not the normal worker planning surface. Reconnects
are accepted only when the same owner identity presents the same secret proof.

`claim_private_handoff` is the legacy/recovery local-private-file bootstrap
path. It accepts `claimed_by` plus either a `private_handoff` object or explicit
redacted fields: `mode`, `path`, `target`, `grant_id`, `display_key`,
`work_package_id`, and optional `database`. The only supported mode is
`local-private-file`. The MCP server reads the secret server-side from the
configured Symphony++ private handoff store, validates the path is the managed
handoff path rather than an arbitrary local file, rejects missing, directory,
oversized, traversal, and metadata-mismatched files, verifies the stored hash,
claims the grant for `claimed_by`, and returns the same redacted
assignment/session metadata as `claim_work_key`. Raw secrets, secret hashes,
secret-bearing commands, and private-store payloads are not accepted in
arguments and are not returned in responses or errors.

`create_work_request` is the local/operator-safe WorkRequest intake bootstrap.
It accepts repo, base branch, title, request kind, either `description` or
`human_description`, optional workflow mode, constraints, status, `claimed_by`,
and provenance fields
`creator_kind`, `creator_name`, and `created_via`. When provenance is omitted,
MCP-created requests default to `agent`/`mcp`, using caller-supplied
`claimed_by` as the maker display name when available and `mcp-agent`
otherwise. A successful response includes the WorkRequest summary with creator
provenance, non-secret `local_architect_claim` metadata for
`claim_local_architect_assignment` when the creator session is trusted local
HTTP with a file-backed ledger, redacted recovery handoff metadata, a
non-secret claim owner for `claim_private_handoff`, and a copyable launch
prompt. If architect handoff
creation fails after the
WorkRequest is created, the tool returns a partial-success shape with the
WorkRequest id and a non-duplicating manual architect-handoff replay hint while
still withholding raw secret material.

WorkRequest repo scopes are persisted as explicit ledger rows for future
multi-repo requests. The existing `repo` and `base_branch` fields remain the
primary compatibility scope used by current MCP intake, list, read, dispatch,
and worker-claim flows. P8 does not add caller-facing multi-repo dashboard or
per-slice repo selection; future tools may expose repo-scope input only after
their policy checks and denial tests cover service A/service B allow and
service C deny behavior.

Explicit `state_key` values retain initialized handshake continuity for
stateless transports, but they do not restore claimed worker sessions. A
reconnecting worker normally replays `claim_local_assignment` with the same
ledger and local scope. Legacy/recovery workers must present the same secret
proof and `claimed_by` identity again. The continuity namespace is the active
ledger, so a reconnect to the same SQLite ledger can restore handshake state
even when the dynamic repo process changes.
Explicit state-key handshakes use a bounded retention window for transport
continuity. They remain continuity metadata until overwritten,
cleared by a failed explicit reconnect initialize, or expired by the explicit
state-key retention window. Local grants do not expire by default; reconnect
failure should be diagnosed through revoke, missing grant, scope drift, or an
explicit expired `expires_at`. A newer explicit initialize for the same state
key invalidates stale live sessions that were claimed before that initialize.
Duplicate initialize on the same active or stale explicit-state connection is
still rejected as already initialized and does not clear the live session.
Implicit response-state continuity is for a single logical connection; a fresh
implicit `initialize` clears stored session state before any new worker claim.

`append_finding` idempotency is work-package scoped, including at the database
uniqueness boundary, for retry stability. A
matching idempotency key and finding content replays the original success even
after worker grant renewal; changed content or a changed caller-supplied finding
id returns `idempotency_conflict`.

JSON-RPC batch items are not an ordered session transaction. Each item is
evaluated against the batch's initial server/session state, so workers must not
rely on `claim_local_assignment`, `claim_work_key`, `claim_private_handoff`, or
any other stateful call in one batch item to authorize later items in the same
batch. A successful claim inside a batch still binds the returned server/session
for later standalone requests. After one claim succeeds in a batch, later claim
entries in that same batch are rejected as rebinding attempts so a connection
cannot claim multiple assignments.
The stdio transport is newline-delimited JSON. Long one-shot stdio invocations
that include `tools/list` or `read_work_request` can produce large response
lines, so callers must drain stdout concurrently or redirect stdout to a file.
Waiting for process exit while stdout is not being read can deadlock the caller
before later requests are processed. The private-file wrapper provides
`run-mcp-local-file-once` for legacy/recovery diagnostics that need to send a
JSONL request file and spool stdout/stderr to files while keeping the work key
out of prompts and logs. Caller-supplied output/error files must not already
exist; generated spool files are created when output/error files are omitted.

`attach_branch` requires `branch` and `head_sha`. When no PR head is attached,
review packages are matched to the latest attached branch head so stale
branch-only reviews cannot satisfy readiness after new commits. If branch and
PR metadata disagree, the latest branch head remains the current code head and
merge readiness waits for PR metadata for that head.

`submit_review_package` requires explicit `head_sha` on every submission. For
merge readiness, review packages require an attached current branch head, and
the latest review package for that current head is authoritative; older
packages for that same head are superseded. Exact idempotent retries of an
already recorded review package replay the recorded success even if the branch
head has since advanced, but that replayed older-head evidence remains stale
for readiness and does not satisfy merge/readiness gates. `tests` and
`artifacts` entries are trimmed before persistence and default idempotency-key
calculation.

Once `mark_ready` succeeds, worker evidence for that package is immutable: new
progress, finding, blocker, branch/PR, scope-request, and review-package writes
return `already_ready`, while idempotent replays of previously recorded writes
remain available.

CI readiness is controlled by policy `required_gates`. If `ci_waiting` is
present, `mark_ready` requires the package to be in `ci_waiting`. If it is
absent, `mark_ready` may move the package directly from `reviewing` to its
terminal ready status once the remaining readiness gates pass. Use
`mcp_ci_required` for MCP packages that explicitly require the CI wait.

For non-merge-gated policies such as `quick_fix`, generic `append_progress`
events can satisfy focused-test and review-profile readiness by recording
statuses `tests_passed` and `review_<profile>_green`, for example
`review_brief_green`. Tool-owned metadata, blocker, status, and scope events
are ignored for these fallback gates. Non-merge policies that do not require
branch metadata may also count explicit-head `submit_review_package` evidence
before a branch head is attached. Once a branch head is attached, readiness is
evaluated against that current head and older review-package evidence is stale.
Fallback progress gates use the latest relevant generic status after the
current branch head attachment: later `tests_failed`,
`review_<profile>_red`, or `review_<profile>_failed` evidence supersedes
earlier green evidence until a newer pass/green status is recorded. Merge-gated
packages still use current-head `submit_review_package` evidence and persisted
review artifacts.

For investigation policies, `request_scope_expansion` records the required
scope recommendation evidence but never approves the expansion itself. Generic
`append_progress` payloads do not satisfy this recommendation gate.
