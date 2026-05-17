# MCP and Skill Contract

## Purpose

Codex workers should interact with Symphony++ through a narrow MCP interface and a repeatable Codex Skill.

## Target MCP topology

The target installation shape is a single HTTP MCP endpoint rather than a
per-session stdio Elixir process.

Default local mode should run one local Symphony++ daemon on loopback. That
daemon owns the cockpit, Solo Session planning memory, and MCP endpoint for the
machine. Codex clients then connect to the daemon by URL, for example:

```toml
[mcp_servers.symphony_plus_plus]
url = "http://127.0.0.1:4057/mcp"
```

The current minimal HTTP slice exposes only the local Streamable HTTP MCP
endpoint contract:

- `POST /mcp` accepts one JSON-RPC MCP message body, rejects JSON-RPC arrays
  or batches, and returns JSON responses from the existing route-free
  `HTTPTransport`.
- A successful initialize response includes `Mcp-Session-Id`; subsequent
  requests must send that same header. Missing follow-up sessions fail with
  HTTP 400, and unknown sessions fail with HTTP 404.
- Dispatch uses the existing dashboard lazy-repo access path so the configured
  local ledger is live and migrated before MCP tools run. Ledger startup or
  migration failures fail closed with a JSON-RPC server error.
- Notifications that do not produce JSON-RPC responses return HTTP 202 with no
  body.
- `GET /mcp` returns HTTP 405 because this slice does not implement SSE.
- The endpoint is local-only: requests must arrive from loopback, use a
  localhost/loopback host, avoid forwarded headers, and any browser `Origin`
  must exactly match the local scheme, host, and port. It does not emit CORS
  headers.

This slice intentionally does not add browser CORS/preflight support, cookies,
Phoenix-session client binding, reconnect semantics, SSE streaming,
remote/company authentication, daemon startup/plugin install configuration, or
claimed-worker persistence over HTTP.

This keeps normal Codex app threads, implementation agents, and review-adjacent
tools from spawning a new PowerShell/Mix/Erlang process tree per session while
still making the lightweight Solo planning tools available wherever the plugin
is enabled.

The same client contract should support a company-hosted Symphony++ service for
shared repositories by changing only the endpoint and authentication settings,
for example:

```toml
[mcp_servers.symphony_plus_plus]
url = "https://sympp.example.com/mcp"
bearer_token_env_var = "SYMPP_TOKEN"
```

Remote/company mode centralizes the ledger, cockpit, WorkRequests, WorkPackages,
and planning history in a server-backed datastore. Codex agents still edit code
inside their local or cloud workspaces; Symphony++ remains the coordination,
planning, permission, and observability layer. Remote mode must enforce
repository, branch, project, WorkRequest, WorkPackage, and grant scope on the
server side before returning any board, planning, or orchestration data.

The current stdio MCP wrapper remains a development and private-store bootstrap
fallback. It should not be the long-term default for ordinary plugin install
because Codex hosts may eagerly start configured stdio MCP servers for generic
or review sessions. Heavy WorkPackage and architect orchestration may still
require explicit claim/bootstrap context; the local/remote HTTP server is the
transport target, not a shortcut around grant authorization.

## MCP resources

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

## Worker MCP tools

```text
claim_work_key(secret, claimed_by)
get_current_assignment()
read_context()
read_task_plan()
update_task_plan(patch, expected_version)
append_finding(finding, idempotency_key)
append_progress(event, idempotency_key)
set_status(status, reason, expected_status)
report_blocker(summary, idempotency_key, blocker_id?)
resolve_blocker(blocker_id, resolution, summary, idempotency_key)
request_scope_expansion(summary, idempotency_key, payload)
attach_branch(branch, head_sha)
attach_pr(url, head_sha)
sync_pr(url_or_number, metadata)
submit_review_package(summary, tests, artifacts, head_sha)
mark_ready()
```

## Generic Solo Session MCP tools

Unbound/generic MCP sessions advertise a small Solo Session tool family using
the `solo_*` naming style:

```text
solo_attach(repo, base_branch, workspace_path, caller_id, title?)
solo_append(session_id, entry_kind, title, body?, status?, idempotency_key?, payload?)
solo_show(session_id) -> latest 50 entries plus entry_count/entries_returned/entries_truncated
solo_list(repo?, base_branch?, workspace_path?, caller_id?, status?)
solo_update_status(session_id, current_status, next_status)
```

These tools are for lightweight local planning memory only. They call the
existing Solo Session service/repository and use the MCP server's configured
repo/database; they do not claim WorkKeys, mint grants, create WorkRequests,
create WorkPackages, dispatch agents, write Linear state, or participate in
merge-readiness gates. Returned structured content is redacted with the
existing planning redactor. `solo_show` intentionally returns only the latest
50 entries in this first slice; callers can use `entry_count`,
`entries_returned`, and `entries_truncated` to detect when history was bounded.
`solo_update_status` reuses the Solo Session lifecycle service contract for
pause, resume, complete, and archive transitions, including optimistic
`current_status` checking.

Solo MCP tools are deliberately not advertised to bound worker or architect
WorkPackage sessions. Direct calls from a bound session fail with
`solo_tools_require_unbound_session` before mutation so Solo planning cannot be
confused with WorkPackage orchestration.

Unbound/generic MCP sessions also advertise `sympp.health` and the temporary
`claim_work_key` bootstrap/recovery tool for explicit stdio WorkPackage flows.
They do not advertise any other worker mutation tools or architect tools until
a valid grant is bound.

`claim_work_key` intentionally requires both the one-time secret and a stable
`claimed_by` owner identity. Symphony++ uses that identity as part of the MCP
ownership contract. The call binds the session to an existing worker or
architect grant and does not mint new grants. It remains available to unbound
sessions only as a bootstrap/recovery bridge, not as a generic planning
surface. Reconnects are accepted only when the same secret proof is presented
by the same `claimed_by` owner.

For Codex first-use worker dispatch, the preferred path is private-store MCP
bootstrap rather than an explicit worker tool call containing the raw secret.
`sympp.mcp --work-key-secret-env <env-var> --claimed-by <worker-id>` reads the
secret from the MCP process environment, claims or reconnects the grant, and
binds the session before the worker calls `get_current_assignment()`.

For stateless MCP transports, an explicit `state_key` is continuity metadata for
the initialized handshake only. It is not a bearer capability for a claimed
worker assignment. After reconnect initialize, workers must call
`claim_work_key(secret, claimed_by)` again to bind the worker session. The
state namespace follows the active ledger rather than a transient dynamic repo
process, so handshake continuity survives reconnects to the same SQLite ledger.
Explicit state-key handshakes use a bounded retention window longer than the
current worker grant defaults and are not evicted by the shorter implicit
default response-state TTL. They remain continuity metadata until overwritten,
cleared by a failed explicit reconnect initialize, or expired by the explicit
state-key retention window. A newer explicit initialize for the same state key
invalidates stale live sessions claimed before that initialize.
Duplicate initialize on the same active explicit-state connection is still
rejected as already initialized and does not clear the live session.
Implicit response-state continuity is for a single logical connection; a fresh
implicit `initialize` clears stored session state before any new worker claim.

`append_finding` idempotency is scoped to the work package, including at the
database uniqueness boundary, for retry stability across grant renewal. A retry
with the same idempotency key and same finding content replays the original
success; changed content or a changed
caller-supplied finding id returns `idempotency_conflict`.

JSON-RPC batch items are not an ordered session transaction. Each item is
evaluated against the batch's initial server/session state, so a `claim_work_key`
call inside one batch item does not authorize later items in that same batch.
Workers should claim in a prior request, or run dependent worker tools outside
the batch. A successful `claim_work_key` inside a batch still binds the returned
server/session for later standalone requests. After one claim succeeds in a
batch, later `claim_work_key` entries in that same batch are rejected as
rebinding attempts so a connection cannot claim multiple assignments.

`attach_branch` intentionally requires both the branch name and the current
branch `head_sha`. Branch-only review evidence is matched to that head so a
later branch update cannot reuse stale review-package evidence. When both
branch and PR metadata exist, the latest branch head is the worker-declared
current code head; PR metadata proves that the PR is attached for that same
head.

`submit_review_package` must include `head_sha` on every submission. Merge
readiness evidence can only bind to the current attached branch head. The latest
current-head review package is authoritative for review readiness; older
packages for the same head are superseded rather than implicitly merged. The
`tests` and `artifacts` lists are normalized by trimming entries before
persistence and default idempotency-key calculation. If an exact idempotent
retry matches an already recorded review package, Symphony++ replays that
success even after the current branch head has moved forward. The replay does
not make older-head evidence current for readiness.

After `mark_ready` succeeds, worker evidence is frozen. Evidence-mutating tools
such as progress, findings, blockers, branch/PR metadata, scope requests, and
review packages reject new writes for the ready package while preserving
idempotent replay behavior for already-recorded operations.

For non-merge-gated policies such as `quick_fix`, workers may satisfy focused
test and review-lane readiness with ordinary generic `append_progress` statuses:
`tests_passed` and `<review_lane>_green` such as `review_t1_green`. Tool-owned
metadata, blocker, status, and scope events do not satisfy those gates. These
non-merge policies may also count explicit-head `submit_review_package` evidence
without branch metadata when branch metadata is not a required gate. Merge-gated
packages still require current-head review package evidence and artifacts. If a
branch head is attached, generic fallback evidence and review-package evidence
must be current to the latest branch head. Generic fallback gates use the latest
relevant status after that branch head: later `tests_failed`,
`<review_lane>_red`, or `<review_lane>_failed` supersedes earlier green evidence
until a newer pass/green status is recorded.

For investigation policies that require a scope recommendation,
`request_scope_expansion` records the worker's recommendation evidence and
persists a canonical `recommendation.md` recommendation artifact for new
events. Stored legacy `request_scope_expansion` rows do not satisfy readiness
unless the canonical artifact already exists. It does not approve expanded scope. Caller-controlled
generic `append_progress` payloads are not recommendation evidence.

## Architect MCP tools

```text
create_child_work_package(package)
mint_child_worker_key(work_package_id, template)
revoke_child_worker_key(grant_id, reason)
list_work_requests(status?)
read_work_request(work_request_id)
set_work_request_status(work_request_id, current_status, next_status)
ask_work_request_question(work_request_id, category, question, why_needed, asked_by_agent_run_id?, decision_prompt?)
answer_work_request_question(work_request_id, question_id, current_status, answer, answered_by?)
close_work_request_question(work_request_id, question_id, current_status)
record_work_request_decision(work_request_id, source_type, decision, rationale, scope_impact, created_by, source_id?)
add_work_request_planned_slice(work_request_id, title, goal, work_package_kind, target_base_branch, owned_file_globs, forbidden_file_globs, acceptance_criteria, validation_steps, review_lanes, stop_conditions, branch_pattern?)
approve_work_request_planned_slice(work_request_id, planned_slice_id, current_status)
skip_work_request_planned_slice(work_request_id, planned_slice_id, current_status)
mark_work_request_sliced(work_request_id, current_status)
dispatch_work_request_planned_slice(work_request_id, planned_slice_id, claimed_by, secret_handoff?, secret_store_dir?)
read_child_status(work_package_id)
read_phase_board(phase_id)
request_child_replan(work_package_id, reason)
approve_child_ready_state(work_package_id, rationale, request_id?)
merge_child_into_phase(work_package_id, merge_artifact)
split_work_package(work_package_id, child_specs)
publish_phase_update(phase_id, update)
```

Architect tools require a live architect grant and the matching architect
capability; worker grants and insufficient architect grants are denied. Worker
grants cannot be minted with architect-only MCP capabilities, including
unprefixed P3/P7 capability strings such as `read:phase` or
`mint:child_worker_key`. `tools/list` advertises architect tools only when an
architect session is already bound and filters them to the live grant's
capabilities. Unbound generic sessions expose only health, Solo Session tools,
and `claim_work_key` as the temporary bootstrap/recovery tool for explicit
stdio WorkPackage flows. Stale bound sessions expose only health and
`claim_work_key` for refresh, while worker sessions keep the bound
worker-facing discovery surface without Solo tools. Architect sessions may call
`get_current_assignment()` and read
`sympp://assignment/current` to recover their scoped `work_package_id` after
reconnect, but they still cannot use worker package read/write tools.
Lifecycle capabilities such as `architect:lifecycle.transition` do not imply
MCP architect tool capabilities; the explicit MCP capability strings listed in
the permission model are required. WorkRequest read, mutation, and dispatch tools are
advertised only for explicit phase-scoped architect grants with usable frozen
repo/base-branch scope and the specific WorkRequest capability; legacy null
`phase_id` architect grants do not discover those tools.

`list_work_requests(status?)` and `read_work_request(work_request_id)` are
read-only architect tools gated by `read:work_request`. They require an
explicit phase-scoped architect grant with frozen repo/base-branch scope and do
not accept caller supplied repo or base-branch arguments. Legacy null
`phase_id` architect grants are not supported for WorkRequest MCP reads and
fail closed instead of deriving scope from a mutable anchor package.
`list_work_requests` accepts only an optional WorkRequest `status` filter.
`read_work_request` returns the scoped WorkRequest plus clarification
questions, decision log entries, planned slices, and status/count summaries.
Missing and out-of-scope WorkRequests fail closed as not found without leaking
sibling request content. Returned payloads are JSON-safe and redact
secret-looking values; they do not include work-key secrets, private handoff
payloads, tokens, or worker secret material.

`set_work_request_status`, `ask_work_request_question`,
`answer_work_request_question`, `close_work_request_question`, and
`record_work_request_decision` are architect mutation tools gated by
`write:work_request`. They use the same explicit phase-scoped frozen
repo/base-branch scope model as the read tools and require `work_request_id` on
every call before mutating. Out-of-scope WorkRequests fail closed as not found
or scoped denial without leaking sibling content. `answer_work_request_question`
and `close_work_request_question` also verify that `question_id` belongs to the
scoped WorkRequest before calling the mutation service; sibling question ids
fail closed as not found. The tools return JSON-safe redacted payloads for the
updated clarification question or decision entry, plus a minimal parent
WorkRequest status projection, scope, and status metadata. Mutation responses
do not expose the full `read_work_request` detail shape. They expose the
existing WorkRequest service primitives: status movement is explicit through
`set_work_request_status`, and question/decision tools do not mirror
dashboard-only helper guards, auto-transition the parent request, or introduce
a new lifecycle/status transition matrix.

`ask_work_request_question` may include an optional `decision_prompt` object for
human-facing answer cards. The object contains redacted strings only:
`tl_dr`, `details`, one to four `options` with `id`, `label`, `answer`, and
optional `description`, `pros`, and `cons`, plus optional
`custom_redirect_label`. Plain-text `question` and `why_needed` remain required
and remain the fallback rendering when `decision_prompt` is absent.
`custom_redirect_label` is a label override only: local operator UIs always
offer a freeform redirect path, use the default redirect label when the field is
omitted, and persist only the operator's replacement guidance note for that
path.

`add_work_request_planned_slice`, `approve_work_request_planned_slice`,
`skip_work_request_planned_slice`, and `mark_work_request_sliced` are architect
planned-slice mutation tools gated by `write:work_request`. They use the same
explicit phase-scoped frozen repo/base-branch scope model and require a scoped
`work_request_id` before mutating. Approve and skip also verify that
`planned_slice_id` belongs to that scoped WorkRequest before calling the
mutation service; sibling slice ids fail closed as not found. `mark_work_request_sliced`
uses the existing `WorkRequestService.mark_sliced` behavior, including the
approved-or-dispatched slice requirement. Responses return JSON-safe redacted
planned-slice or WorkRequest status projections plus scope/status metadata.
These tools do not dispatch planned slices, create WorkPackages, alter
SecretHandoff, mutate Linear, run automatic slicing/package generation, or
change dashboard behavior.

`dispatch_work_request_planned_slice` is an architect dispatch tool gated by
`dispatch:work_request`, not by generic `write:work_request`. It uses the same
explicit phase-scoped frozen repo/base-branch scope, requires `work_request_id`,
`planned_slice_id`, and `claimed_by`, accepts optional `secret_handoff` and
`secret_store_dir`, and calls the existing `PlannedSliceDispatch.dispatch`
orchestration. MCP dispatch is advertised only when the MCP server is started
with `repo_root`/`--repo-root` pointing at a repository that contains the worker
secret handoff script, and direct calls fail closed if that root is missing or
invalid. MCP dispatch requires a file-backed live ledger so the returned worker
bootstrap command reconnects to the same ledger; in-memory database
configuration fails closed before dispatch side effects. Blank database
configuration is treated as absent and uses the live ledger. Matching configured
SQLite file URI options are preserved in the worker bootstrap command when they
resolve to the same live ledger, including default repo database configuration;
divergent explicit MCP database configuration fails closed, and matching
read-only SQLite URI options such as `mode=ro` or `immutable=1` are rejected
before dispatch. The tool verifies the WorkRequest and planned slice are in scope before
mutation and fails closed for missing, out-of-scope, non-approved,
invalid-status, unsupported-kind, and slice-scope-violation cases. Responses
include only WorkRequest id, planned-slice status/linkage, WorkPackage id
metadata, and redacted worker handoff metadata. They must not include raw worker
secrets, work keys, bearer tokens, API tokens, MCP auth tokens, private-store
secret payloads, or secret-bearing claim URLs.

Phase-dependent architect tools revalidate the grant's explicit phase scope plus
the anchor repo/base-branch scope frozen when the phase architect grant was
minted. Legacy null `phase_id` grants may still derive the current explicit
anchor phase for non-delegation phase reads, but scoped explicit phase-board
reads and P7 child delegation/status operations fail closed when the frozen
repo/base-branch snapshot is missing; migrations do not backfill that snapshot
from mutable anchor state. MCP, API, and browser phase-board readers filter
explicit phase architect grants to the frozen repo/base-branch boundary before
package cards are materialized.
`create_child_work_package(package)` creates only `phase_child` work inside the
architect phase anchor, inherits the anchor base branch, and rejects mismatched
phase, parent, repo, or base branch input. Child creation requires concrete
nonempty file globs; empty anchor globs may be used only when the child supplies
explicit nonempty, non-overbroad globs, while nonempty anchor globs remain the
upper bound. Child creation revalidates that anchor scope in the insert
transaction. Context-slice input is not part of the current contract.
`mint_child_worker_key` mints only single-package worker grants for same-phase
children, revalidates the live architect grant in the mint transaction, rejects
new mints while any active child-delegated worker grant already exists for the
same child, ignores unrelated normal worker grants, and caps child capabilities
and expiry to that current grant. This is the pre-production v1 contract and is
not a backwards-compatible replacement/remint promise. The raw child worker
secret is stored through the private SecretHandoff path and is not returned in
tool content; the response uses `worker_grant.secret_handoff` plus
`worker_grant.secret_in_response` set to `false`, and omits `secret` and
`secret_returned_once`. Returned handoff metadata is redacted to non-secret
bootstrap fields, including the resolved `claimed_by` identity and
`run_mcp_command` when generated by SecretHandoff; those fields must not embed
the raw worker secret. The MCP server must be
configured with `repo_root`/`--repo-root` before child minting so handoff
scripts are resolved from an operator-chosen repository root; minting fails
before grant creation if the expected handoff script is missing there.
`template.secret_handoff` is optional and narrow: only `mode`, `store_dir`, and
`claimed_by` are accepted, blank values are rejected, and grant capabilities
cannot be broadened through handoff settings. `revoke_child_worker_key` remains
a not-implemented Phase 7 stub in this package; deleting persisted child
handoffs on revoke belongs with the future child-revocation implementation.
`read_child_status(work_package_id)` requires both `read:child_progress` and
`read:child_findings`; it can read the architect anchor package or a same-phase
child package. `approve_child_ready_state(work_package_id, rationale, request_id?)` can
approve only a same-phase child already in `ready_for_architect_merge` after
readiness gates still pass; it records a local audit event and moves the child
to `merging_into_phase`. Exact approval retries replay across renewed architect
grants for the same actor only when the caller supplies the same `request_id`;
the human `rationale` is audit text and is not idempotency key material.
Same-`request_id` retries within the same ready-state cycle replay the original
approval audit event; retry rationale edits do not mutate the recorded audit
rationale. Re-approval after a real blocked/reworked/readied cycle records a new
approval audit event even when the same `request_id` and rationale text are
reused. Approved children are architect-controlled, except the child worker may
move `merging_into_phase` back to `blocked` to represent a merge blocker before
further worker follow-up.
`merge_child_into_phase(work_package_id, merge_artifact)` records a local
`phase_merge` artifact and moves the approved
child to `merged_into_phase`; the artifact must include
`status: "merged_into_phase"` and a nonempty `uri`, and no live Git or branch
merge side effect is performed. The full accepted `merge_artifact` is preserved
as artifact metadata. Exact merge retries replay across renewed scoped
architect grants even when the renewed grant has a different `claimed_by`;
after a child is already merged, a new valid merge artifact updates the local
`phase_merge` record and appends an audit event without another lifecycle
transition while the phase remains active; exact older retries do not overwrite
newer artifact data. Merge finalization and post-merge artifact updates are
rejected after the phase closes.
Phase-board reads include child progress summary counts so humans can inspect
merged-child progress. Summary counts are computed after backend authorization
and frozen repo/base scope filters, then remain stable across client-side board
filters; abandoned children are excluded from merge-progress totals, while
closed children still count in the merge denominator but are not open work. The
remaining
architect tools return explicit `phase7_not_implemented` errors after
authorization and must not publish phase state.

## Skill rules

The Codex Skill must instruct workers to:

1. Load the current assignment first through private-store MCP bootstrap.
2. Read context, task plan, findings, progress, acceptance criteria, and review-suite requirements.
3. Update the task plan before implementation.
4. Append findings after meaningful discovery.
5. Append progress after meaningful implementation steps.
6. Request scope/context expansion instead of silently expanding work.
7. Attach branch/PR/artifacts.
8. Mark ready only after evidence is present.
9. Never create local planning files as the source of truth.
10. Never inspect or mutate sibling work unless explicit context slices are provided.

## Skill package and MCP wiring

The repo-local skill package lives at:

```text
.codex/skills/symphony-work-package/SKILL.md
```

Install or copy that directory into the worker repository's `.codex/skills/`
directory when Symphony++ runs against a downstream codebase, or install the
Codex-local plugin from `plugins/symphony-plus-plus/`. The skill expects a
configured Symphony++ MCP stdio server. From this repository's Elixir
implementation, the MCP server command is:

```bash
cd elixir
mise exec -- mix sympp.mcp --mode stdio --database <ledger-path>
```

Codex MCP configuration should start that command from the `elixir/` directory
as a stdio MCP dependency. Do not embed raw work-key secrets or bearer tokens in
that configuration. For first-use worker dispatch, use the private-store wrapper
documented in `mcp_wiring.md`; it injects `SYMPP_WORK_KEY_SECRET` only into the
MCP child process and passes `--claimed-by <worker-id>`. For stateless
transports, `state_key` is only handshake continuity and does not replace the
same secret proof plus owner identity.

## Hook role

Hooks may remind agents to keep state updated, inject assignment context, and
detect missing handoff, but hooks must not be treated as the permission
boundary. Optional examples live under
`implementation_docs_symphplusplus/templates/codex_hooks/`; they are
operator-controlled templates, not runtime defaults. Keep hook behavior
deterministic and non-secret-bearing, and do not parse private transcripts or
chain-of-thought for security decisions.
