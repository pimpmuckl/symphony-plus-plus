# MCP Tools Contract

This document mirrors `mcp_tools_contract.json` in readable form. The JSON file
is the compact machine-readable index of tool names plus required and optional
arguments. Removed legacy bootstrap paths are intentionally absent.

Human-facing long text fields are Markdown unless a field is explicitly a
compact label, status, identifier, branch, PR URL, or other machine-readable
value. Dashboard renderers must not turn raw Markdown HTML into executable or
trusted HTML.

## Bootstrap

Agents claim existing ledger records by id:

| Tool | Required | Optional | Purpose |
|---|---|---|---|
| `claim_local_assignment` | `work_package_id` | `claimed_by`, `work_request_id`, `repo`, `base_branch`, `branch`, `worktree_path`, `caller_id` | Bind the current session to one WorkPackage. Runtime metadata is validation context only; the WorkPackage id is the normal claim coordinate. |
| `claim_local_architect_assignment` | `work_request_id` | `claimed_by`, `architect_anchor_work_package_id`, `repo`, `base_branch`, `phase_id`, `caller_id` | Bind the current session to the architect grant for one WorkRequest. |
| `create_work_request` | `repo`, `base_branch`, `title`, `request_kind`, plus `description` or `human_description` | status/workflow/creator fields | In a trusted local HTTP session, create a WorkRequest and return a ledger claim bootstrap for the architect. |

Dispatch and mint responses return non-secret `worker_bootstrap` metadata:

```json
{"type":"ledger_claim","mode":"local_assignment","tool":"claim_local_assignment","args":{"work_package_id":"...","claimed_by":"..."}}
```

`claimed_by` is useful for stable audit ownership but is no longer a secret
carrier. Raw grant secrets, private files, and secret stores are not part of the
agent-facing surface. `caller_id`, when present, is correlation metadata only;
the active local claim owner is the ledger id plus `claimed_by`. Id-only
architect claims default to the standard architect handoff owner.

Local claim leases use heartbeat freshness. Successful bound MCP calls refresh
the current lease, and replayed claims may reclaim stale no-heartbeat residue.
Fresh worker leases continue to block other workers, while paused leases remain
operator-controlled.

## Worker Tools

Bound worker sessions expose health, assignment release, and:

```text
get_current_assignment
read_context
read_task_plan
update_task_plan
append_finding
append_progress
set_status
report_blocker
resolve_blocker
add_comment
list_comments
resolve_comment
create_guidance_request
read_guidance_request
request_scope_expansion
attach_branch
attach_pr
sync_pr
submit_review_package
attach_review_suite_result
mark_ready
```

Workers are scoped to exactly one WorkPackage. Worker tools never mint grants,
approve scope, merge PRs, advance phases, or close WorkRequest delivery.

For Review Suite evidence, call `attach_review_suite_result` with `round_id`
when local Review Suite state is available. The server infers suite, profile,
lane, head SHA, status, verdict, summary, and anchor for a passing round.
Verbose fields remain a fallback when the round cannot be resolved; `suite`
must still identify Review Suite. Omit `round_id` when using verbose fallback
fields because a present `round_id` selects the local-round resolution path.

## Health, Solo, And Local Operator Tools

Unbound sessions expose `sympp.health`, `release_current_assignment`, Solo
Session tools, scoped worker/architect schemas, and the local claim tools.
Trusted local HTTP sessions with explicit state-key continuity and a
file-backed ledger also expose safe local bootstrap/operator tools:

```text
create_work_request
add_work_request_comment
list_comments
record_work_request_operator_decision
```

Trusted local sessions keep `create_work_request` and these safe local
operator tools visible even when the wrapper is bound to a worker or architect
assignment, or when that binding needs refresh. They do not widen the active
assignment's package or WorkRequest authority.

Solo Session tools are for ordinary local planning memory. They do not claim a
WorkRequest or WorkPackage and do not grant dispatch or lifecycle authority.
The unbound Solo MCP surface is intentionally intent-shaped:

```text
solo_attach
solo_show
solo_list
solo_record_task_plan
solo_append_progress
solo_append_finding
solo_record_decision
solo_report_blocker
solo_resolve_blocker
solo_record_validation
solo_pause
solo_resume
solo_complete
solo_archive
```

## Architect Tools

Bound architect sessions expose WorkRequest, product-tree, planned-slice,
phase-child, guidance, closeout, and delivery tools listed in the JSON contract.
Architect claims are WorkRequest-centric; WorkPackage anchor, repo, base branch,
and phase fields are derived from the ledger when omitted.

Some names are shared across worker and architect sessions. For example,
`resolve_blocker` is worker-scoped for workers and descendant-package-scoped
for architects; the live handler applies the role-specific authorization and
target-scope checks.

`dispatch_work_request_planned_slice` requires only `work_request_id` and
`planned_slice_id`; `claimed_by` is optional. It creates the linked WorkPackage,
mints a worker grant, and returns the same simple `claim_local_assignment`
bootstrap shape.

`cleanup_work_request_planned_slice_runtime` is the WR architect cleanup path
for linked planned-slice runtime that has been superseded or abandoned by
delivery truth. It requires `outcome` plus the same superseded or abandoned
evidence that will be used for closeout. It revokes linked worker grants,
releases non-paused local claim leases, clears recoverable worker MCP session
bindings for the linked WorkPackage, and records audit progress. Paused leases
and fresh active AgentRun evidence fail closed; after cleanup, record the
delivery outcome with
`record_planned_slice_delivery`.

`mint_child_worker_key` accepts an optional `template` object. The template may
set non-secret `claimed_by`, `capabilities`, and `expires_at`; it cannot provide
secret handoff options.

## Discovery And Authorization

`tools/list` is schema discovery, not authorization. Healthy unbound sessions
show health, Solo tools, scoped schemas, and local claim tools. Trusted local
HTTP sessions with explicit state also show `create_work_request` and safe local
operator tools when a file-backed local ledger is available. Bound worker
sessions show worker tools plus trusted local bootstrap/operator tools when
available. Bound architect sessions show architect tools plus trusted local
bootstrap/operator tools when available.
Calls still enforce live session role, capabilities, grant scope, lifecycle
state, local daemon trust, and handler-specific checks.

Stale or revoked sessions recover by replaying the relevant local claim tool on
the same id or by starting a new session and claiming the same id.
`release_current_assignment` is safe to call repeatedly; absent, stale, or
mismatched bindings return a compact ok-style cleanup result. Normal visible
claim/release text omits claim lease ids, grant ids, caller ids, and raw
recovery maps; `structuredContent` keeps non-secret audit details.

## Resources

Bound sessions may read:

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

Resources may include compact `text/vnd.toon` alongside Markdown or JSON for
agent-facing context. Tool inputs and structured results remain schema-native
JSON.

## Safety

Responses must redact bearer/API/GitHub/Linear/MCP tokens, grant verifiers,
secret hashes, and secret-like prose. Agent prompts, docs, launch payloads, and
tool responses must not ask for raw grant secrets or local private-file handoff
metadata.
