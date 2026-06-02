# MCP and Skill Contract

## Purpose

Codex workers should interact with Symphony++ through a narrow MCP interface and a repeatable Codex Skill.

## Target MCP topology

The target installation shape is a single HTTP MCP endpoint rather than a
per-session stdio Elixir process.

Default local mode should run one local Symphony++ daemon on loopback. That
daemon owns the cockpit, Solo Session planning memory, and MCP endpoint for the
machine. The opt-in Codex plugin uses a command-backed launcher so Codex startup
can start or reuse that daemon and dashboard before MCP tools are listed:

```toml
[mcp_servers.symphony_plus_plus]
command = "cmd.exe"
args = ["/d", "/s", "/c", "plugins/symphony-plus-plus-mcp/scripts/start-sympp-mcp.cmd"]
cwd = "<repo>"
```

The launcher bridges stdio MCP traffic into the backend HTTP endpoint, which
defaults to `http://127.0.0.1:19998/mcp`. A URL-only config can still be used
for explicit local experiments, but it requires the backend to be listening on
the configured port before Codex starts and cannot follow dynamic fallback port
selection. Normal worker claim still requires a dedicated MCP session that
preserves the returned `Mcp-Session-Id`/state key across initialize, discovery,
claim, and follow-up calls; a stateless one-shot URL probe is not a
worker-claim session.

The current minimal HTTP slice exposes only the local Streamable HTTP MCP
endpoint contract:

- `POST /mcp` accepts one JSON-RPC MCP message body, rejects JSON-RPC arrays
  or batches, and returns JSON responses from the existing route-free
  `HTTPTransport`.
- A successful initialize response includes `Mcp-Session-Id`; subsequent
  requests must send that same header. Missing follow-up sessions fail with
  HTTP 400, and unknown sessions fail with HTTP 404.
- After `claim_local_assignment`, `claim_work_key`, or `claim_private_handoff`
  succeeds, the same local HTTP `Mcp-Session-Id` retains the bound WorkPackage
  worker or WorkRequest architect session for
  later `tools/list`, resource reads, and tool calls. Protected follow-ups use
  the live dashboard repo path and revalidate the stored session proof against
  the current grant before returning scoped data. For claimed sessions, treat
  `Mcp-Session-Id` as sensitive local continuity material: do not print it,
  commit it, paste it into prompts, or include it in logs.
- Dispatch uses the existing dashboard lazy-repo access path so the configured
  local ledger is live and migrated before MCP tools run. Ledger startup or
  migration failures fail closed with a JSON-RPC server error.
- `sympp.health` includes `ledger.reachable` and `ledger.identity`. The
  identity distinguishes omitted/default SQLite configuration from explicit
  SQLite configuration with `kind`, `source`, `display_path`, and
  `default_home`; remote/server-style configuration is reduced to a safe
  scheme/host/port endpoint and never includes credentials or query strings.
- Notifications that do not produce JSON-RPC responses return HTTP 202 with no
  body.
- `GET /mcp` returns HTTP 405 because this slice does not implement SSE.
- The endpoint is local-only: requests must arrive from loopback, use a
  localhost/loopback host, avoid forwarded headers, and any browser `Origin`
  must exactly match the local scheme, host, and port. It does not emit CORS
  headers.

Operators can verify the local HTTP contract from the repository root while
`mix sympp.cockpit` is running:

```powershell
.\scripts\smoke-sympp-mcp-http.ps1 -RepoRoot .
```

Pass `-Url http://127.0.0.1:<port>/mcp` for a cockpit started on a non-default
port and `-Json` for machine-readable output. This check proves daemon
handshake, session-header continuity, source-revision match against the
checkout, `tools/list`, and the expected unbound tool surface. It is
intentionally separate from Codex app plugin visibility: if this smoke passes
but MCP tools are absent in a Codex session, troubleshoot the opt-in
plugin/config/session startup path rather than the daemon. If the smoke reports
`stale_or_unverified_daemon` or `stale_daemon_source_revision_mismatch`,
restart `mix sympp.cockpit` from the current checkout and rerun it.

The operator-safe diagnostic for that split-brain state is:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -MarketplaceName symphony-plus-plus -Doctor
```

`solo_ready_mcp_companion_not_enabled` means the default skill-only
`symphony-plus-plus` plugin is enabled and the MCP companion package is
installed, but `symphony-plus-plus-mcp` was not enabled before the current
Codex session started. Enable it only through the explicit opt-in command
against the dedicated S++ MCP config/session:

```powershell
.\plugins\symphony-plus-plus\scripts\diagnose-mcp-lifecycle.ps1 -CodexHome <dedicated-codex-home> -MarketplaceName symphony-plus-plus -EnableMcpCompanion
```

That command validates the installed companion cache and manifest, creates a
timestamped backup before changing an existing `config.toml`, and writes only
`[plugins."symphony-plus-plus-mcp@<marketplace>"] enabled = true`. It does not
write `[mcp_servers.*]` or generic worker/review config, and it refuses the
default `~/.codex` home. Restart or reload that dedicated session afterward and
keep generic worker, review-suite, and
`codex review` configs on the skill-only default.
The doctor checks source/cache/config and the local HTTP daemon; it does not
inspect the tool list already registered inside an open Codex model session.
After enablement or cache changes, the operator must restart or reload the
dedicated MCP-enabled session before expecting tools to appear. During V2.1
feature-branch work, local plugin/cache sync is not part of the normal loop;
perform cache adoption only at final feature-branch cutover.
For source-only repair commands such as cockpit startup and HTTP smoke
verification, the doctor uses `-RepoRoot`, the current source checkout, or a
single usable `.sympp-source-root` hint from the selected activation package
caches to print absolute commands. If it cannot infer a source checkout from
those selected caches, it says so and asks the operator to rerun with
`-RepoRoot <path-to-symphony-plus-plus-checkout>` instead of printing a relative
command that only works from the repo root.
When multiple Symphony++ marketplaces are installed, pass the intended
`-MarketplaceName`; the doctor avoids package-specific repair commands until
that selection is explicit. `global_footgun_present` means a top-level
`[mcp_servers.symphony_plus_plus]` entry is present and should be removed from
generic configs or relocated into a dedicated S++ MCP config/session.

To prove the legacy/recovery secret-proof worker path, pass the work key
through an environment variable name and provide the stable owner identity:

```powershell
$env:SYMPP_WORK_KEY_SECRET = Get-Content -LiteralPath "<private-secret-file>" -Raw
.\scripts\smoke-sympp-mcp-http.ps1 `
  -Bound `
  -WorkKeySecretEnv SYMPP_WORK_KEY_SECRET `
  -ClaimedBy <stable-worker-id>
Remove-Item Env:\SYMPP_WORK_KEY_SECRET -ErrorAction SilentlyContinue
```

The bound smoke initializes a local HTTP MCP session, verifies the unbound
surface unless `-SkipUnboundTools` is supplied, calls `claim_work_key`, then
uses the claimed `Mcp-Session-Id` for `tools/list`, `get_current_assignment`,
`resources/read sympp://assignment/current`, and `resources/list`. Text and
JSON output redact claimed session ids and the raw work key. Do not use pasted
logs from a custom debug path that prints the environment value or claimed
`Mcp-Session-Id`. Normal V2.1 worker dispatch validates through
`claim_local_assignment` instead.

This slice intentionally does not add browser CORS/preflight support, cookies,
Phoenix-session client binding, reconnect semantics, SSE streaming,
remote/company authentication, or daemon startup/plugin install configuration.

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

The current stdio MCP wrapper remains a development and private-store recovery
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

## Bootstrap Claim Tools

```text
claim_work_key(secret, claimed_by)
claim_private_handoff(claimed_by, private_handoff | mode, path, target, grant_id, display_key, work_package_id, database?)
claim_local_assignment(repo, base_branch, work_package_id, branch, worktree_path, caller_id, claimed_by, work_request_id?)
claim_local_architect_assignment(work_request_id, architect_anchor_work_package_id, repo, base_branch, caller_id, claimed_by, phase_id?)
```

## Bound Worker MCP Tools

```text
get_current_assignment()
read_context()
read_task_plan()
update_task_plan(patch, expected_version)
append_finding(finding, idempotency_key)
append_progress(event, idempotency_key)
set_status(status, reason, expected_status)
report_blocker(summary, idempotency_key, blocker_id?)
resolve_blocker(blocker_id, resolution, summary, idempotency_key)
add_comment(target_kind, target_id, body)
list_comments(target_kind, target_id)
resolve_comment(comment_id, resolution_note?)
request_scope_expansion(summary, idempotency_key, payload)
attach_branch(branch, head_sha)
attach_pr(url, head_sha)
sync_pr(url_or_number, metadata)
submit_review_package(summary, tests, artifacts, head_sha)
mark_ready()
```

Worker comment tools are scoped to the current WorkPackage assignment. Workers
can comment on their own WorkPackage, a planned slice linked to that package,
or the parent WorkRequest of a linked planned slice. Sibling WorkPackages,
unlinked planned slices, and unrelated WorkRequests fail closed as out of
scope. Comment provenance is derived from the claimed MCP session rather than
caller input, and comment payloads are redacted before they are returned
through MCP. Comment bodies are capped at 4,000 characters, resolution notes
are capped at 1,000 characters, and list responses are capped at 100 comments
per target.
Human-facing long bodies passed through these tools are Markdown, including
findings, progress bodies, blocker notes, comments, guidance context/answers,
and decision rationale/scope impact. Compact titles, statuses, ids, branch
names, PR metadata, and other machine-readable values remain plain text.

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
existing planning redactor. Solo entry bodies are Markdown; titles and statuses
remain plain text. `solo_show` intentionally returns only the latest
50 entries in this first slice; callers can use `entry_count`,
`entries_returned`, and `entries_truncated` to detect when history was bounded.
`solo_update_status` reuses the Solo Session lifecycle service contract for
pause, resume, complete, and archive transitions, including optimistic
`current_status` checking.

Agent-facing resource reads may include compact `text/vnd.toon` content. That
TOON text is presentation context for agents only: MCP tool inputs remain
JSON/schema-native, and tool `structuredContent` remains the canonical
machine-readable response. Human-facing Markdown rendering is a dashboard
presentation rule, not the MCP input encoding.

Solo MCP tools are deliberately not advertised to bound worker or architect
WorkPackage sessions. Direct calls from a bound session fail with
`solo_tools_require_unbound_session` before mutation so Solo planning cannot be
confused with WorkPackage orchestration. The denial includes safe current
assignment context (`role`, repo/base, WorkPackage or WorkRequest id when
available, `claimed_by`, and matching claim lease id/status when available) and
points agents at `release_current_assignment`. That tool clears only the current
MCP session binding, releases the matching current claim lease when one exists,
redacts any supplied release reason before storage, and returns whether the
same MCP session can immediately retry Solo tools. If the matching lease exists
but cannot be released safely, the binding remains active and the response
names the retry action instead of silently orphaning the lease. If the current
session does not carry enough safe claim-lease identity to prove ownership, the
binding also remains active and the response sets `fresh_mcp_session_required`
with `start_fresh_mcp_session` as the next action. If that tool is not available
or reports that a fresh session is required, start a fresh MCP session before
using `solo_*` tools.

## Local Operator MCP tools

Trusted unbound local HTTP sessions with explicit state-key continuity and a
file-backed local ledger may also advertise:

```text
add_work_request_comment(work_request_id, body, created_by)
record_work_request_operator_decision(work_request_id, decision, rationale, scope_impact, created_by, source_id?)
```

These tools append redacted local-operator comments and decisions to a
WorkRequest by id. They do not grant WorkRequest ownership, dispatch authority,
lifecycle authority, or sibling package visibility. Text/provenance fields are
bounded and redacted before storage and response.

Unbound/generic MCP sessions also advertise `sympp.health`, the recovery
`claim_work_key` tool, `claim_private_handoff`, `create_work_request`, Solo
Session tools, and static architect schemas. They do not advertise other worker
mutation tools until a valid grant is bound. Trusted local HTTP sessions with
explicit state-key continuity may additionally advertise
`claim_local_assignment`, `claim_local_architect_assignment`, worker-only bound
WorkPackage schemas except `claim_work_key`, and the local operator note tools
described above. Shared names such as `read_guidance_request` remain covered by
static architect schemas. Those worker schemas are discovery-only before claim:
worker calls fail `claim_required` without mutating state, and trusted local
HTTP denials point callers at `claim_local_assignment`.

`sympp.health` is safe to run before or after claim. It reports only server
version/source, mode, ledger reachability, and a redacted ledger identity; it
does not expose WorkPackage data, raw worker secrets, bearer tokens, database
passwords, or private-store handoff contents.

`claim_local_assignment` is the normal V2.1 WorkPackage worker claim. It
requires `repo`, `base_branch`, `work_package_id`, `branch`, `worktree_path`,
`caller_id`, and `claimed_by`; `work_request_id` is accepted when dispatch
linked the package to a planned slice. It is available only on trusted local
HTTP MCP sessions with explicit state-key continuity. The server validates
repo/base/branch/worktree scope against the ledger, rejects terminal packages,
and binds the newest live worker grant for that package.

`claim_local_assignment` also owns reclaim behavior. Replaying the same local
claim heartbeats the active claim lease. A stale lease may be reclaimed and
records `claim_lease_reclaimed` audit evidence. A paused lease, scope mismatch,
terminal package, missing recorded worktree, same local owner with a different
`caller_id`, or another active owner with live authority fails closed. The
same-owner `caller_id` mismatch is rejected before the live-grant authority
check; reuse the same stable `caller_id` for reconnects.

`claim_local_architect_assignment` is the normal local WorkRequest architect
claim. It requires `work_request_id`, `architect_anchor_work_package_id`,
`repo`, `base_branch`, `caller_id`, and `claimed_by`; `phase_id` may be supplied
for validation. It is available only on trusted local HTTP MCP sessions with
explicit state-key continuity and a file-backed local ledger. The server
validates WorkRequest repo/base, architect anchor package, phase, and live
architect grant authority, then binds the current MCP session to the existing
architect grant. Replays with the same local owner heartbeat the claim lease;
stale leases may be reclaimed with audit evidence. Remote, untrusted,
stateless, scope-mismatched, terminal, revoked, or private-file-dependent paths
fail closed.

Identity fields are deliberately separate:

| Field | Meaning | Reconnect rule |
| --- | --- | --- |
| `claimed_by` | Durable grant/authority owner. For generated local architect handoffs, pass `local_architect_claim.arguments.claimed_by` unchanged, normally `symphony-architect`. | Do not replace with `Codex`, account names, or user names. |
| `caller_id` | Current local MCP runtime, launcher, or thread identity. | Generate a stable value for this runtime and reuse it for reconnects from the same runtime. |

If `claim_lease_active_for_other_actor` appears, do not guess a new
`claimed_by`. Retry with the handoff `claimed_by`, or ask the operator to
recycle a stale local claim.

`claim_work_key` intentionally requires both the one-time secret and a stable
`claimed_by` owner identity. Symphony++ uses that identity as part of the MCP
ownership contract. The call binds the session to an existing worker or
architect grant and does not mint new grants. It remains available to unbound
sessions only as a legacy/recovery bridge, not as the normal worker planning
surface. Reconnects are accepted only when the same secret proof is presented
by the same `claimed_by` owner. Successful work-package claims attach a
non-secret claim lease identity to the live session so
`release_current_assignment` can release the matching lease. Persisted HTTP
`state_key` recovery remains nonrecoverable for secret-backed claims after
runtime reset.

`claim_private_handoff` is a legacy/recovery local-private-file bootstrap path.
It accepts `claimed_by` and either a redacted `private_handoff` object or
explicit redacted fields: `mode`, `path`, `target`, `grant_id`, `display_key`,
`work_package_id`, and optional `database`. v1 supports only
`mode: "local-private-file"`. The MCP server reads the secret server-side from
the known Symphony++ private handoff store, requires the supplied path to match
the managed metadata path, rejects arbitrary paths, traversal, directories,
missing or oversized files, and mismatched grant/display/work-package metadata,
then binds the current session the same way a successful `claim_work_key` call
does. It never accepts or returns raw secrets, secret hashes, or secret-bearing
commands.

`create_work_request` is the local/operator-safe MCP intake tool for agent-led
WorkRequest creation. It creates a WorkRequest in the local ledger from repo,
base branch, title, request kind, either `description` or `human_description`,
optional workflow mode, constraints, status, `claimed_by`, and provenance
fields. Provenance supports `creator_kind` values `human`, `agent`, `operator`,
and `system`, optional `creator_name`, and optional `created_via`; omitted MCP
provenance defaults to `agent`/`mcp`, using caller-supplied `claimed_by` as the
maker display name when present and `mcp-agent` otherwise. The response returns
the WorkRequest summary, non-secret `local_architect_claim` metadata for
`claim_local_architect_assignment` when the creator session is trusted local
HTTP with a file-backed ledger, redacted recovery handoff metadata, a
non-secret claim owner for `claim_private_handoff`, and a launch prompt. If handoff
mint/replay fails after creation, the tool
returns partial success with the WorkRequest id and a non-duplicating manual
architect-handoff replay hint and still does not expose raw secret material.

For Codex first-use worker dispatch, the preferred path is the ledger-backed
local claim. Dispatch returns non-secret `worker_bootstrap` metadata with
`claim.tool: claim_local_assignment`; workers add local runtime `branch`,
`worktree_path`, and `caller_id`, then call `get_current_assignment()`.
`caller_id` is the stable local MCP session/launcher identity, not a field
returned by worktree preparation; reuse it for reconnects because changing it
within the same local owner is a hard claim rejection.
Private-store MCP bootstrap is a legacy/recovery path after ledger-claim
cutover, not a normal worker-claim or reconnect path.

For the local HTTP transport, `Mcp-Session-Id` is connection continuity
metadata for both initialized and claimed sessions. After claim, it is
sensitive local bearer-continuity material for that daemon session, while the
grant remains the scope authority: the stored session contains assignment
metadata plus the grant secret hash proof, not the raw work-key secret, and
protected follow-ups revalidate that proof against the live ledger. If the
grant is revoked, explicitly expired, missing, or scope-drifted, bound worker and
architect operations fail closed and discovery falls back to refresh/bootstrap
tools where applicable.

For reconnects, the state namespace follows the active ledger rather than a
transient dynamic repo process, so handshake continuity survives reconnects to
the same SQLite ledger. Worker authority is restored by replaying
`claim_local_assignment`; legacy/recovery workers must present the same secret
proof and `claimed_by` identity again.
Explicit state-key handshakes use a bounded retention window for transport
continuity. They remain continuity metadata until overwritten,
cleared by a failed explicit reconnect initialize, or expired by the explicit
state-key retention window. Local grants do not expire by default; reconnect
failure should be diagnosed through grant revocation, missing grant, scope drift,
or an explicit expired `expires_at`, not by watching a default grant clock. A
newer explicit initialize for the same state key invalidates stale live sessions
claimed before that initialize.
Duplicate initialize on the same active or stale explicit-state connection is
still rejected as already initialized and does not clear the live session.
Implicit response-state continuity is for a single logical connection; a fresh
implicit `initialize` clears stored session state before any new worker claim.

`append_finding` idempotency is scoped to the work package, including at the
database uniqueness boundary, for retry stability across grant renewal. A retry
with the same idempotency key and same finding content replays the original
success; changed content or a changed
caller-supplied finding id returns `idempotency_conflict`.

JSON-RPC batch items are not an ordered session transaction. Each item is
evaluated against the batch's initial server/session state, so
`claim_local_assignment`, `claim_work_key`, `claim_private_handoff`, or another
stateful call inside one batch item does not authorize later items in that same
batch. Workers should claim in a prior request, or run dependent worker tools
outside the batch. A successful claim inside a batch still binds the returned
server/session for later standalone requests. After one claim succeeds in a
batch, later claim entries in that same batch are rejected as rebinding attempts
so a connection cannot claim multiple assignments.

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

Valid current-head review evidence can normalize stale active package lifecycle
bookkeeping to `reviewing`. This applies when `submit_review_package` or a
passing `attach_review_suite_result` is accepted while the raw package status is
`ready_for_worker`, `claimed`, `planning`, or `implementing`. Passing Review
Suite status values are `passed`, `pass`, `green`, `success`, and `completed`;
passing verdict values are `green`, `clean`, `passed`, `pass`, `success`, and
`approved`.

After `mark_ready` succeeds, worker evidence is frozen. Evidence-mutating tools
such as progress, findings, blockers, branch/PR metadata, scope requests, and
review packages reject new writes for the ready package while preserving
idempotent replay behavior for already-recorded operations.

CI is policy-controlled. A package policy requires the lifecycle `ci_waiting`
step only when its `required_gates` includes `ci_waiting`; otherwise
`mark_ready` may move directly from `reviewing` to the terminal ready status
after all non-CI readiness gates pass. The `mcp_ci_required` policy template is
the explicit MCP policy variant for packages that must preserve the CI wait.

For non-merge-gated policies such as `quick_fix`, workers may satisfy focused
test and review-profile readiness with ordinary generic `append_progress`
statuses: `tests_passed` and `review_<profile>_green`, such as
`review_brief_green`. Tool-owned metadata, blocker, status, and scope events do
not satisfy those gates. These non-merge policies may also count explicit-head
`submit_review_package` evidence without branch metadata when branch metadata is
not a required gate. Merge-gated packages still require current-head review
package evidence and artifacts. If a branch head is attached, generic fallback
evidence and review-package evidence must be current to the latest branch head.
Generic fallback gates use the latest relevant status after that branch head:
later `tests_failed`, `review_<profile>_red`, or
`review_<profile>_failed` supersedes earlier green evidence until a newer
pass/green status is recorded.

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
read_work_request_delivery_board(work_request_id)
reconcile_work_request(work_request_id, apply?, recorded_by?)
record_planned_slice_delivery(work_request_id, planned_slice_id, outcome, idempotency_key, recorded_by?, pr_url?, pr_number?, pr_repository?, pr_merged_at?, merge_commit_sha?, no_pr_evidence?, successor_planned_slice_id?, successor_work_package_id?, superseded_reason?, abandoned_rationale?)
revoke_planned_slice_worker_key(work_request_id, planned_slice_id, grant_id, reason)
set_work_request_status(work_request_id, current_status, next_status)
ask_work_request_question(work_request_id, category, question, why_needed, asked_by_agent_run_id?, decision_prompt?)
answer_work_request_question(work_request_id, question_id, answer, answered_by?, expected_question_status?, current_status?)
answer_work_request_question_and_record_decision(work_request_id, question_id, answer, source_type, decision, rationale, scope_impact, answered_by?, created_by?, source_id?, expected_question_status?, current_status?)
close_work_request_question(work_request_id, question_id, expected_question_status?, current_status?)
record_work_request_decision(work_request_id, source_type, decision, rationale, scope_impact, created_by, source_id?)
add_work_request_planned_slice(work_request_id, title, goal, work_package_kind, target_base_branch, owned_file_globs, forbidden_file_globs, acceptance_criteria, validation_steps, review_lanes, stop_conditions, branch_pattern?)
approve_work_request_planned_slice(work_request_id, planned_slice_id, current_status)
skip_work_request_planned_slice(work_request_id, planned_slice_id, current_status)
mark_work_request_sliced(work_request_id, current_status)
dispatch_work_request_planned_slice(work_request_id, planned_slice_id, claimed_by, symphony_repo_root?, legacy_private_handoff?, secret_handoff?, secret_store_dir?)
prepare_work_package_worktree(work_package_id, target_repo_root, base_branch, branch, worktree_parent?)
cleanup_work_package_worktree(work_package_id, target_repo_root)
read_child_status(work_package_id)
read_phase_board(phase_id)
request_child_replan(work_package_id, reason)
approve_child_ready_state(work_package_id, rationale, request_id?)
merge_child_into_phase(work_package_id, merge_artifact)
split_work_package(work_package_id, child_specs)
publish_phase_update(phase_id, update)
```

`add_work_request_planned_slice.work_package_kind` accepts the standalone
dispatchable kinds `quick_fix`, `hotfix`, `docs`, `investigation`, `adapter`,
`mcp`, `skill`, and `hooks`. `docs` slices require documentation-only
`owned_file_globs`.

Architect tools require a live architect grant and the matching architect
capability; worker grants and insufficient architect grants are denied. Worker
grants cannot be minted with architect-only MCP capabilities, including
unprefixed P3/P7 capability strings such as `read:phase` or
`mint:child_worker_key`. `tools/list` uses static architect schema discovery:
healthy unbound generic sessions advertise health, Solo Session tools,
`release_current_assignment`, `claim_work_key`, `claim_private_handoff`,
`create_work_request`, architect tool schemas, and worker WorkPackage schemas
so fresh Codex sessions can discover WorkRequest, WorkPackage, architect flows,
and the safe bound-session recovery tool before claim. Calling
`release_current_assignment` still requires a bound assignment. Unbound HTTP sessions also advertise
`claim_local_assignment` and `claim_local_architect_assignment` for
first-claim/reclaim schema discovery, but schema visibility is not
authorization. Claim calls still
require trusted local HTTP state-key continuity and scope validation, and worker
WorkPackage calls before a valid worker claim return a claim-required denial
without mutating state. Architect calls still require a live claimed architect
grant with the required capability and scope, and unclaimed architect calls
return a claim-required denial. Stale bound sessions expose only health,
`claim_work_key`, `claim_private_handoff`, and, on HTTP sessions,
`claim_local_assignment` and `claim_local_architect_assignment` for refresh; duplicate
`initialize` on that same stale explicit MCP session does not downgrade it into
generic unbound discovery.
Worker sessions keep the bound worker-facing discovery surface, including
`release_current_assignment`, without Solo tools or architect-only schemas.
Bound architect sessions advertise `release_current_assignment`, the static
architect schema set, and may call `get_current_assignment()` and read
`sympp://assignment/current` to recover their scoped `work_package_id` after
reconnect, but they still cannot use worker package read/write tools.
Lifecycle capabilities such as `architect:lifecycle.transition` do not authorize
MCP architect tool calls; the explicit MCP capability strings listed in the
permission model are required at call time. WorkRequest read, mutation, and
dispatch schemas are discoverable before claim and for bound architect sessions
even when the current grant lacks capability or usable frozen scope; direct
calls fail closed until an explicit phase-scoped architect grant with the
required frozen repo/base-branch scope and specific WorkRequest capability is
live. Legacy null `phase_id` architect grants do not authorize those tools.

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

`read_work_request_delivery_board(work_request_id)` is the primary
WorkRequest-led delivery view for closeout. It is read-only and gated by
`read:work_request`. It returns the scoped WorkRequest, ordered planned-slice
delivery rows, counts, scope, raw slice status, linked WorkPackage summaries,
delivery outcome summaries, operational state, attention reason codes, and
successor context. It preserves raw lifecycle state while projecting human
delivery truth; out-of-scope linked packages are reported as hidden instead of
leaking package details.

`record_planned_slice_delivery` is the write path for lifecycle truth. It is
gated by `write:work_request`, requires `work_request_id`, `planned_slice_id`,
`outcome`, and `idempotency_key`, verifies the planned slice and any linked or
successor package stay inside the architect grant's frozen repo/base-branch
scope, records one delivery outcome for the planned slice, and returns a fresh
delivery board. Exact retries with the same idempotency key and evidence replay
the existing delivery. Conflicting outcome/evidence for the same key or an
already closed-out slice is rejected.

Delivery outcomes are:

- `pr_merged`: requires `pr_url` and ISO-8601 `pr_merged_at`; linked packages
  also require `merge_commit_sha` as strong merge evidence. Malformed PR URLs
  and GitHub URL metadata that conflicts with provided PR number/repository are
  rejected. Standalone linked packages move to `merged`; when strong evidence
  proves a stale linked package already merged, live worker grants are revoked
  and active/stale local claim leases are released and audited as part of
  closeout. Stale AgentRun rows that are no longer operationally active are
  ignored but audited with closeout progress. Active blockers, paused claim
  leases, fresh active agent runs, and other non-worker runtime evidence still
  reject. Phase-child PR delivery
  requires
  `merge_child_into_phase` first; after the child is already
  `merged_into_phase`, closeout records the delivery without redoing the phase
  merge.
- `completed_no_pr`: requires `no_pr_evidence` and closes a compatible linked
  package to `closed`. Stale AgentRun rows that are no longer operationally
  active under delivery-board freshness rules are ignored but audited with
  closeout progress; fresh active AgentRun rows still reject.
- `superseded`: requires `successor_planned_slice_id` and
  `superseded_reason`; optional `successor_work_package_id` must be linked to
  that successor slice and in scope. A compatible linked package closes to
  `closed`. Active blocker events on the superseded package do not block this
  recut closeout; they remain historical evidence and are echoed in the
  closeout progress event and delivery-board attention. Unclaimed live worker
  grants and stale active local claim leases are retired and audited as stale
  recut cleanup; claimed worker grants, fresh/current claim leases, paused claim
  leases, fresh active AgentRun rows, and unrelated runtime evidence still
  reject.
- `abandoned`: requires `abandoned_rationale` and moves a compatible linked
  package to `abandoned`.

Linked package mutation is transactional with the delivery record. The normal
path rejects mismatched package metadata, active blockers, active runtime
evidence, stale terminal status conflicts, weak PR evidence, and closeout
progress idempotency collisions. The recovery exceptions are limited to
strong-evidence `pr_merged` closeout and intentional `superseded` recut
closeout. When all planned slices are terminal, closeout refreshes the
WorkRequest completion projection. Decision-log entries remain rationale and
scope history; they do not prove delivery happened.

`reconcile_work_request` repairs stale closeout state only from structured
PR/GitHub evidence. Omitted or false `apply` is a `read:work_request` dry-run
that reports proposed actions and the current delivery board without writing.
`apply: true` requires `write:work_request` and applies proposed PR-merged
closeouts through `record_planned_slice_delivery`. The reconciler checks
repository, base branch, current head, merged-at, and merge-commit evidence; it
does not infer no-PR completion from decision prose or terminal package status.
For the compact operator sequence and stale-board verification fixture, see
`implementation_docs_symphplusplus/runbooks/WORK_REQUEST_DELIVERY_CLOSEOUT.md`.

Example no-PR closeout:

```json
{
  "work_request_id": "wr_example",
  "planned_slice_id": "wrs_docs",
  "outcome": "completed_no_pr",
  "idempotency_key": "closeout-wrs-docs-direct",
  "no_pr_evidence": "Operator confirmed the docs-only change landed directly."
}
```

Example supersession closeout:

```json
{
  "work_request_id": "wr_example",
  "planned_slice_id": "wrs_old",
  "outcome": "superseded",
  "idempotency_key": "closeout-wrs-old-recut",
  "successor_planned_slice_id": "wrs_new",
  "successor_work_package_id": "wp_new",
  "superseded_reason": "Recut with narrower owned files."
}
```

`revoke_planned_slice_worker_key` is gated by `write:work_request` and revokes
one live worker grant for the WorkPackage linked to the scoped planned slice
after the worker has reached a closeout-ready state. It accepts the grant id
and a redacted reason, records redacted audit evidence, and never accepts or
returns raw worker secrets.

`set_work_request_status`, `ask_work_request_question`,
`answer_work_request_question`, `answer_work_request_question_and_record_decision`,
`close_work_request_question`, and `record_work_request_decision` are architect
mutation tools gated by `write:work_request`. They use the same explicit
phase-scoped frozen repo/base-branch scope model as the read tools and require
`work_request_id` on every call before mutating. Out-of-scope WorkRequests fail
closed as not found or scoped denial without leaking sibling content.
`answer_work_request_question`, `answer_work_request_question_and_record_decision`,
and `close_work_request_question` also verify that `question_id` belongs to the
scoped WorkRequest before calling the mutation service and default the expected
question status to `open`. Callers should omit question status; optional
`expected_question_status=open` and deprecated `current_status=open` are accepted
only as legacy guards, and any other value returns a structured
`invalid_question_status` error. Sibling question ids fail closed as not found.
The combined answer-and-decision tool commits both records atomically. The tools
return JSON-safe redacted payloads for the updated
clarification question or decision entry, plus a minimal parent WorkRequest
status projection, scope, and status metadata. Mutation responses do not expose
the full `read_work_request` detail shape. They expose the existing WorkRequest
service primitives: status movement is explicit through `set_work_request_status`,
and question/decision tools do not mirror dashboard-only helper guards,
auto-transition the parent request, or introduce a new lifecycle/status
transition matrix.

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

`add_work_request_planned_slice` and `approve_work_request_planned_slice`
validate `owned_file_globs` against the parent WorkRequest path constraints
before mutating. `**` must be a full path segment: `scripts/**/deploy*.ps1`
and `.github/workflows/**` are valid; `scripts/**deploy**`,
`scripts/**server**`, and `packages/**kraken_batch**` are invalid and return
safe structured details with the field, offending value, and reason such as
`unsupported_globstar`.

`dispatch_work_request_planned_slice` is an architect dispatch tool gated by
`dispatch:work_request`, not by generic `write:work_request`. It uses the same
explicit phase-scoped frozen repo/base-branch scope, requires `work_request_id`,
`planned_slice_id`, and `claimed_by`, returns `worker_bootstrap` metadata for
`claim_local_assignment`, and keeps `secret_handoff`/`secret_store_dir` only as
legacy/recovery options gated by `legacy_private_handoff: true`. It calls the existing
`PlannedSliceDispatch.dispatch`
orchestration. MCP dispatch has a statically discoverable schema, and direct
calls fail closed if the supplied `symphony_repo_root`, legacy hidden
`repo_root` alias, configured `repo_root`, or discoverable local Symphony++
repo root is missing, invalid, or does not point at the Symphony++ helper root
that contains the worker secret helper script under `scripts/` when legacy
private handoff recovery is requested. This is not the target product
repository root. MCP
dispatch requires a file-backed live ledger so the returned worker
bootstrap metadata reconnects to the same ledger; in-memory database
configuration fails closed before dispatch side effects. Blank database
configuration is treated as absent and uses the live local ledger. Matching
configured SQLite file URI options are preserved in the worker bootstrap metadata
when they resolve to the same live ledger, including the default local ledger;
divergent explicit MCP database configuration fails closed, and matching
read-only SQLite URI options such as `mode=ro` or `immutable=1` are rejected
before dispatch. The tool verifies the WorkRequest and planned slice are in scope before
mutation and fails closed for missing, out-of-scope, non-approved,
invalid-status, unsupported-kind, and slice-scope-violation cases. Responses
include WorkRequest id, planned-slice status/linkage, WorkPackage id metadata,
non-secret worker bootstrap metadata, and any redacted worker handoff or grant
metadata the current runtime still emits. They must not include raw worker
secrets, work keys, bearer tokens, API tokens, MCP auth tokens, private-store
secret payloads, or secret-bearing claim URLs.

`prepare_work_package_worktree` and `cleanup_work_package_worktree` are
architect dispatch tools gated by `dispatch:work_request`. They act only on
WorkPackages linked from planned slices on WorkRequests in the current
architect grant's frozen repo/base-branch/phase scope. `prepare` takes a
WorkPackage id, target product repo root, base branch, concrete branch name,
and optional safe worktree parent; resolves `CODEX_HOME` with fallback to
`~/.codex`; verifies the target repo root belongs to the scoped WorkPackage
repository; creates a path below
`CODEX_HOME/worktrees/spp_worktrees/<repo-name>-<repo-hash>/<package-id>-<sanitized-branch>-<branch-hash>`;
fetches `origin/<base_branch>` into the local remote-tracking ref; runs the
equivalent of `git worktree add -b <branch> <path> origin/<base_branch>`;
records only `worktree_path`; and returns workspace path, branch, base branch,
target repo root, and use-this-worktree-only launch guidance. Git failures
return sanitized status, stderr, target repo root, worktree destination,
branch, and base branch diagnostics. `cleanup` takes the WorkPackage id and
target product repo root, reads the recorded path,
proves it remains below the managed S++ worktree root, refuses dirty worktrees,
proves the recorded worktree belongs to the supplied target product repository,
removes the git worktree, prunes stale worktree metadata, clears
`worktree_path`, and records redacted audit/progress evidence. These tools do
not add frontend UI, mutate secrets, clean worktrees from a different
repository, or run automatic cleanup on package lifecycle transitions.

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
to the current grant. Expiry is also capped when the architect grant has an
explicit expiry: child expiry defaults to the architect expiry and cannot exceed
it. When the architect grant is non-expiring, child worker grants default to
non-expiring and may specify a future explicit expiry. This is the
pre-production v1 contract and is not a backwards-compatible replacement/remint
promise. The raw child worker
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
cannot be broadened through handoff settings. `revoke_child_worker_key` requires
`revoke:child_worker_key`, revalidates the live architect grant and frozen
phase anchor scope, and revokes only a live child-delegated worker grant for a
same-phase child package. If the child is in `claimed`, `planning`,
`implementing`, `reviewing`, `ci_waiting`, or `blocked`, revoke resets it to
`ready_for_worker` so the architect can immediately remint. It rejects unrelated
grants, normal worker grants, sibling/out-of-scope children, already revoked or
expired grants, and children already in architect-controlled/closed/merged or
terminal states. The response and durable audit/progress event are redacted and
identify only safe child package and grant metadata, previous and new child
statuses, and the redacted recycle reason; persisted private handoff cleanup is
not performed in this v1 package.
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

1. Claim the assignment first through `claim_local_assignment`.
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
dedicated Symphony++ local HTTP MCP session connected to the same ledger as
dispatch. The stdio server remains a legacy/recovery fallback. From this
repository's Elixir implementation, the fallback command is:

```bash
cd elixir
mise exec -- mix sympp.mcp --mode stdio
```

Codex MCP configuration should start that command from the `elixir/` directory
as a stdio MCP dependency. Omit `--database` for the normal local ledger,
preferring `$HOME/.agents/splusplus/symphony_plus_plus.sqlite3` and falling
back under a temp/relative `.agents/splusplus` root if home is unavailable; add
it only for isolated tests or manual experiments. Do not embed raw work-key secrets or bearer tokens
in that configuration. For first-use worker dispatch, use the
`claim_local_assignment` metadata documented in `mcp_wiring.md`. The
private-store wrapper is a legacy/recovery fallback. For HTTP transports,
`state_key` provides continuity and may restore local claim-lease-backed
sessions while the matching lease remains live, but it does not replace the
ledger claim or legacy secret proof plus owner identity when recovery is
unavailable.

## Hook role

Hooks may remind agents to keep state updated, inject assignment context, and
detect missing claim context, but hooks must not be treated as the permission
boundary. Optional examples live under
`implementation_docs_symphplusplus/templates/codex_hooks/`; they are
operator-controlled templates, not runtime defaults. Keep hook behavior
deterministic and non-secret-bearing, and do not parse private transcripts or
chain-of-thought for security decisions.
