# v2 WorkRequest Product Contract

This document defines the v2 WorkRequest product contract. It is operator-facing
product documentation only. It preserves the existing WorkPackage ledger,
AccessGrant permissions, virtual planning resources, readiness gates,
review-suite evidence, PR evidence, and human merge controls.

Codex architect agents should apply this contract through the plugin-installed
`symphony-plus-plus-mcp:symphony-architect` skill, backed by the repo-local
`plugins/symphony-plus-plus-mcp/skills/symphony-architect/SKILL.md` playbook. That
skill is the practical agent workflow for clarification, decisions, planned
slices, dispatch, guidance routing, and stop conditions.

WorkRequest core persistence, planned-slice persistence, read API/list/detail
dashboard views, scoped dashboard intake, architect MCP WorkRequest reads and
clarification/decision mutations, the board-authenticated manual clarification
loop, and manual planned-slice authoring/approval controls exist. Planned-slice
dispatch linkage persistence, the core planned-slice dispatch CLI, the
architect MCP planned-slice dispatch tool, and local-operator dashboard
planned-slice dispatch exist. Package-scoped guidance request persistence and
MCP worker/architect routing exist for dispatched packages. Local-operator
dashboard handling for escalated `human_info_needed` package guidance also
exists. The installable Codex plugin exposes current Symphony++ skills and a
generic `symphony_plus_plus` MCP wrapper. The MCP `create_work_request` intake
tool exists for local/operator-safe agent creation. Automatic question
generation, automatic slicing, Linear state creation, richer planner/intake
plugin surfaces, and automatic Codex spawning remain future work.

## Purpose

A `WorkRequest` is the pre-WorkPackage intake object for work that needs product
clarification, architecture planning, or slicing before implementation starts.
It captures human intent before Symphony++ creates one or more bounded
WorkPackages.

Use a WorkRequest when the human knows the product goal but has not yet locked
the implementation slices, target branch model, assumptions, or review shape.
Skip it for already-bounded bugfixes, hotfixes, investigations, or
review-only tasks that can be expressed directly as one WorkPackage.

## Required Intake Fields

Every WorkRequest records:

- Project or repo.
- Base branch or branch constraint.
- Work type, one of `feature`, `bugfix`, `hotfix`, `refactor`,
  `investigation`, `docs`, or `review`.
- Creator provenance: `creator_kind` (`human`, `agent`, `operator`, or
  `system`), optional maker display name, and optional created-via channel.
- Human description of the desired outcome.
- Constraints, including allowed paths, forbidden paths, compatibility stance,
  rollout limits, dependencies, secrets, validation limits, and stop conditions.
- Desired dispatch shape, one of `single_package`,
  `architect_led_feature_branch`, `direct_main_fix`, `investigation_first`, or
  `review_only`.

The request may include preferred branch names, known risks, relevant docs,
expected tests, desired reviewers, and links to existing issues or PRs.

## Runtime And Artifact Source Of Truth

When runtime intake is available, the canonical WorkRequest fields live in the
Symphony++ ledger and can be read through the dashboard API or dashboard UI.
The dashboard create path is intentionally scoped: it is available only to
board-authenticated grants with frozen repo and base-branch scope. The create
form accepts title, work type, desired dispatch shape, human description, and
structured constraint fields for allowed paths, forbidden paths, compatibility
stance, validation expectations, dependencies or notes, and stop conditions.
Those fields persist into the existing constraints map, and Advanced JSON
remains available for uncommon keys or complex values. Repo and base branch are
visible locked values, and submitted repo/base fields are ignored in favor of
the grant scope.

The dashboard detail path is also scoped to board-visible WorkRequests. In
board-grant mode, it can move a `draft` request to
`ready_for_clarification`, ask clarification questions, answer or close open
questions, record decision log entries, mark `human_info_needed`, and mark
`ready_for_slicing`. The ready-for-slicing action is blocked while any
clarification question remains open. For
`ready_for_slicing` or `sliced` requests, the same detail page can manually add
planned slices, approve or skip existing mutable slices, and mark a
`ready_for_slicing` request `sliced` only after at least one planned slice is
approved. In local operator mode, the same detail page can also dispatch
approved, undispatched planned slices. Board-grant WorkRequest detail remains
scoped to planning controls and does not expose planned-slice dispatch.

In local operator mode, the human-owned draft action is `Start agent questions`.
It moves the WorkRequest from `draft` to `ready_for_clarification` using the
same stale-status-safe status update contract as the board-grant action, then
reloads the detail page so eligible requests can show the architect handoff
action. Local operator detail still does not expose architect-owned question
authoring, decision recording, or planned-slice add/approve/skip controls.

In local operator mode, eligible WorkRequests in `ready_for_clarification`,
`clarifying`, `human_info_needed`, `ready_for_slicing`, or `sliced` can prepare
an architect handoff from the detail page. The handoff creates or reuses a
deterministic phase and architect anchor WorkPackage scoped to the WorkRequest
repo and base branch, then mints an unclaimed phase-scoped architect grant with
`read:phase`, WorkRequest read/write/dispatch, and guidance read/write
capabilities. The local handoff grant is non-expiring by default; authority is
retired by revoke or lifecycle state, unless the caller deliberately passes an
explicit expiry through a lower-level grant API. Repeating the action replays the existing active unclaimed
handoff when possible; if the prior architect grant is claimed or otherwise not
replayable, the same phase and anchor are reused and a new unclaimed grant is
minted. Active handoff metadata that can be safely proven stale is retired
before renewal; missing or otherwise unverifiable metadata fails closed rather
than minting a duplicate grant or reporting cleanup that cannot be proven. The
browser shows only non-secret grant metadata, redacted private handoff metadata,
and a safe prompt referencing the
`symphony-plus-plus-mcp:symphony-architect` skill. This is the architect
bootstrap/recovery surface, not the normal worker dispatch path.
It must not show raw work-key secrets, secret hashes, or full MCP
secret-retrieval commands. Local-operator
detail may display the already prepared panel on reload only when the existing
active unclaimed handoff metadata is safely readable and replayable; that
load-time display path is read-only and does not mint, renew, revoke, or clean
up handoffs. Board-grant detail views cannot mint or display architect
handoffs.

The local MCP `create_work_request` tool can create the same ledger-backed
WorkRequest from an agent or operator session without a dashboard click. It
requires repo, base branch, title, request kind, and either `description` or
`human_description`, accepts optional workflow mode, constraints, initial
status, `claimed_by`, and creator provenance, and defaults omitted provenance
to `agent` via `mcp` with caller-supplied `claimed_by` as the maker display
name when available and `mcp-agent` otherwise. The response includes the
WorkRequest summary with provenance, non-secret `local_architect_claim`
metadata for `claim_local_architect_assignment` when the creator session is
trusted local HTTP with a file-backed ledger, a redacted recovery handoff, a
non-secret claim owner for `claim_private_handoff`, and a launch prompt for
the owning architect agent. `claim_private_handoff` remains explicit
architect recovery; worker dispatch uses ledger-backed local claims. If the
WorkRequest is created but architect handoff creation fails, the response must
be an explicit partial success with the WorkRequest id and a non-duplicating
manual architect-handoff replay hint, not a raw-secret fallback.

Explicit phase-scoped architect MCP sessions with `read:work_request` can read
the same scoped WorkRequest surface through `list_work_requests(status?)` and
`read_work_request(work_request_id)`. The list tool accepts only optional
`status` and always uses the grant's frozen repo/base-branch scope. For phases
created by local WorkRequest architect handoff, the deterministic phase id also
pins the MCP WorkRequest tools to that selected WorkRequest, so sibling
WorkRequests on the same repo/base branch fail closed as out of scope. Legacy
null `phase_id` architect grants are not supported for these MCP reads and fail
closed rather than deriving scope from a mutable anchor package. The detail tool
returns the WorkRequest, clarification questions, decision log entries,
planned slices, and count/status summaries. Missing or out-of-scope
WorkRequests fail closed as not found, and payloads are JSON-safe and redacted
so work-key secrets, API tokens, private handoff payloads, and worker secret
material are not returned.

Explicit phase-scoped architect MCP sessions with `write:work_request` can
mutate the same scoped clarification and decision surface through
`set_work_request_status`, `ask_work_request_question`,
`answer_work_request_question`, `answer_work_request_question_and_record_decision`,
`close_work_request_question`, and `record_work_request_decision`, and can mutate
planned slices through
`add_work_request_planned_slice`, `approve_work_request_planned_slice`,
`skip_work_request_planned_slice`, and `mark_work_request_sliced`. Each
mutation requires `work_request_id` and first verifies the target WorkRequest
is inside the frozen repo/base-branch scope. Answer and close calls also
require `question_id`, verify the question belongs to that scoped WorkRequest,
and default the expected question status to `open`; sibling question ids fail
closed as not found.
Approve and skip calls also require `planned_slice_id` and verify the planned
slice belongs to that scoped WorkRequest before mutation; sibling slice ids
fail closed as not found. Responses are JSON-safe and redacted and include the
updated question, decision, planned-slice, or WorkRequest status projection
plus scope/status metadata; they do not return the full `read_work_request`
detail shape. These tools do not dispatch planned slices, create WorkPackages,
change SecretHandoff, mutate Linear, or change dashboard behavior. MCP
WorkRequest mutation is an architect control-plane surface over existing
service primitives: status movement is explicit through
`set_work_request_status`, `mark_work_request_sliced` keeps the existing
approved-slice requirement, and the question/decision tools do not apply
dashboard-only auto-transition or lifecycle helper policy.

`ask_work_request_question` accepts an optional `decision_prompt` JSON object so
architects can persist human-readable answer cards without replacing the
plain-text `question` and `why_needed` fields. The shape is:

```json
{
  "tl_dr": "Short human-readable summary.",
  "details": "Full question/context.",
  "options": [
    {
      "id": "continue",
      "label": "Continue",
      "description": "Let the agent proceed with the proposed path.",
      "pros": ["Fastest path"],
      "cons": ["May leave one detail less polished"],
      "answer": "Continue with the proposed path."
    }
  ],
  "custom_redirect_label": "No, and tell the agent what to do differently"
}
```

The persisted object is optional, limited to one to four options, redacted in
MCP and dashboard projections, and rejected if malformed. Local operator
answers use the selected option's `answer` text plus any operator note; the
custom redirect path is always available as a human override. The
`custom_redirect_label` field only overrides that path's visible label; when it
is omitted, the cockpit uses the default "No, and tell the agent what to do
differently" label. Custom redirect answers persist only the operator's
replacement guidance note, not the UI label.

Explicit phase-scoped architect MCP sessions with `dispatch:work_request` can
dispatch one approved planned slice through
`dispatch_work_request_planned_slice`. The tool is separate from
`write:work_request` because it creates WorkPackage, AccessGrant, and worker
bootstrap side effects; worktree scope is prepared after dispatch and before
worker launch. It requires `work_request_id`,
`planned_slice_id`, and `claimed_by`, returns ledger-backed
`claim_local_assignment` metadata, and retains old handoff options only for
explicit legacy/recovery flows,
verifies the
WorkRequest and slice are inside the frozen repo/base-branch scope before
mutation, and fails closed for
out-of-scope, missing, non-approved, invalid, unsupported-kind, or slice-scope
violation cases. The response is safe JSON containing WorkRequest id,
planned-slice linkage/status, WorkPackage id metadata, and redacted worker
bootstrap metadata only.

When runtime intake is not available for a lane, the canonical WorkRequest is
one versioned, operator-approved Markdown artifact.
`implementation_docs_symphplusplus/` defines the stable product contract;
individual WorkRequest artifacts are request state and should live in the
operator-approved planning location for that project or lane.

Before slicing starts, the architect WorkPackage context or handoff must include
a durable reference to the canonical artifact and a bounded summary of the
current status, decisions, assumptions, open questions, and intended slices. Do
not paste a long clarification history into package prompts.

Do not split canonical WorkRequest state across chat history, generated ask-pro
output, local scratch notes, or reviewer comments. Those can inform the request,
but the architect plan must cite the canonical WorkRequest artifact as the
source of truth.

The artifact represents state with these sections:

- Header fields: id or short title, repo/project, base branch, work type,
  desired dispatch shape, and current status.
- Human description and constraints.
- Clarification questions and human answers.
- Decisions and explicit assumptions.
- Architect plan.
- Slice plan.
- Open risks, including any `human_info_needed` item.

Use these status labels until runtime tooling defines stricter states:

```text
draft
ready_for_clarification
clarifying
ready_for_slicing
human_info_needed
sliced
```

## Clarification Flow

1. Human records the WorkRequest and starts agent questions, which marks it
   `ready_for_clarification`.
2. Architect reads the request and asks product questions before slicing.
3. Human answers are recorded as durable request context.
4. Architect records decisions and explicit assumptions before creating the
   slice plan.
5. If human intent is still missing, the request or package records
   `human_info_needed`. Agents do not invent product behavior to keep moving.

Clarification is about product and architecture intent. It is not a place for
workers to broaden scope after dispatch.

The dashboard detail view can move a `draft` WorkRequest to
`ready_for_clarification` with a stale-status-safe action. In local operator
mode, the visible action is labeled `Start agent questions`; in board-grant
mode, the architect/planning action remains `Mark ready for clarification`.
If another process has already changed the status, the UI reports a safe retry
message instead of overwriting the newer state.

When the architect asks the first question from
`ready_for_clarification`, the dashboard uses a stale-status-safe transition to
`clarifying` before storing the open question. Answer and close actions are
stale-status-safe per question and do not overwrite questions that another
process already answered or closed. Decision entries record `source_type`,
`decision`, `rationale`, `scope_impact`, and `created_by` as durable request
context.

## Architect Outputs

The architect produces two durable outputs before dispatch.

The architect plan records:

- Product objective and non-goals.
- Repo, base branch, and branch strategy.
- Decisions, assumptions, and open risks.
- Dependency order and integration strategy.
- Validation and review expectations.
- Escalation points that require human or ask-pro input.

The slice plan records:

- WorkPackage candidates with titles, goals, owned files, acceptance criteria,
  validation, review profiles, and stop conditions.
- Parent/child relationships when an architect-led phase is needed.
- The intended PR target for each slice.
- Any package that should be investigation-only or reviewer-only.

Runtime planned-slice records belong to the WorkRequest until dispatch. Their
canonical statuses are `planned`, `approved`, `dispatched`, and `skipped`.
The dashboard manual authoring path stores title, goal, WorkPackage kind,
target base branch, branch pattern, owned files, forbidden files, acceptance
criteria, validation steps, review profiles, and stop conditions. List fields are
entered as newline-delimited text and stored as ordered string lists.
Planned-slice persistence and approval do not themselves create WorkPackages or
mint worker grants. The create path starts rows as `planned`, approve moves
`planned` rows to `approved`, skip moves `planned` or `approved` rows to
`skipped`, and dispatch linkage moves `approved` rows to `dispatched` while
recording the linked `work_package_id` and `dispatched_at` timestamp. The linked
WorkPackage must match the parent WorkRequest and planned-slice contract.
Dispatched slices are read-only in this UI. Approved slices become WorkPackages
only through explicit planned-slice dispatch: the operator CLI, architect MCP
dispatch tool, or local-operator dashboard dispatch control.

Skipped planned slices with no `work_package_id`, no `dispatched_at`, and no
planned-slice delivery record are planning scratch. They usually represent an
architect correcting an invalid draft slice before dispatch, not operational
delivery work. Human-facing WorkRequest delivery boards and main planned-slice
lists hide this scratch by default. Operator/API/MCP inspection paths may expose
them with `include_planning_scratch=true`; included scratch slices are
classified as `planning_scratch`. Operators must not use direct SQLite deletion
to clean these rows. If a future product path needs durable archive state for
planned slices, it requires an explicit schema-backed design.

Before planned-slice dispatch can mint a WorkPackage from an approved planned
slice, it must call the WorkRequest path-scope validator contract as a final
guard. MCP add and approve call the same validator earlier so malformed planned
slices fail before approval. The validator checks the slice `owned_file_globs`
against the parent WorkRequest
`constraints.allowed_paths` and `constraints.forbidden_paths` without reading
the host filesystem. Missing or empty `allowed_paths` means there is no
allow-list restriction, but `forbidden_paths` are still enforced. `docs`
planned slices add a docs-only scope check: owned globs must live under
documentation roots or target documentation-file globs.

The validator accepts only repo-relative slash-separated paths/globs. It rejects
absolute paths, drive-qualified paths, backslash separators, empty path
segments, and dot segments. `*` and `?` match inside one segment, while `**` is
only a full segment and may match zero or more path segments. Allowed-path
checks must prove every possible owned-glob match is equal to or beneath an
allowed path; forbidden-path checks reject any owned glob that can match a
forbidden path or any path below it.
Valid examples include `scripts/**/deploy*.ps1`, `scripts/**/server*.ps1`, and
`.github/workflows/**`; invalid examples include `scripts/**deploy**`,
`scripts/**server**`, and `packages/**kraken_batch**`. Invalid syntax returns
safe structured validation details with the field, offending value, and reason
such as `unsupported_globstar`.

Allowed-path validation is least-privilege. Missing or empty `allowed_paths`
is the explicit no-allow-list-restriction mode. A wildcard allow entry without
an explicit `**`, such as `*`, only grants that wildcard segment shape; it does
not authorize recursive owned globs such as `**/foo` or bare `**`. Recursive
ownership is valid only when the allow-list itself explicitly contains a
recursive `**` scope, such as `elixir/**` or `*/**`, or when the allow-list is
missing or empty.

Feature work defaults to one feature branch with smaller PRs targeting that
feature branch. Use direct `main` PRs for narrow direct-main changes when the
architect plan records why a feature branch would add overhead without reducing
risk.

## Dispatch Into WorkPackages

Approved slices become normal WorkPackages through `mix
sympp.dispatch_planned_slice`, the architect MCP
`dispatch_work_request_planned_slice` tool, or the local-operator dashboard
dispatch control. All dispatch paths accept or derive a WorkRequest id,
planned-slice id, and claimed worker identity. They validate required
identifiers and worker identity, validate the slice scope through
`ScopeConstraints.validate_owned_file_globs/2` plus the docs-only scope check
for `docs` slices, create a standalone WorkPackage
with a ledger-backed `claim_local_assignment` bootstrap, and link the planned
slice. Worktree preparation is a separate pre-launch step:
`prepare_work_package_worktree` or the equivalent operator worktree flow creates
the worker worktree and records only `worktree_path`; branch/base are validated
and returned for launch. The operator/launcher supplies the stable local MCP
`caller_id` used for claim/reclaim. If no worktree is recorded, worker launch
must stop because
`claim_local_assignment` fails closed with `worktree_scope_required`.
Local-operator dashboard dispatch reuses the existing `PlannedSliceDispatch`
orchestration, records the stable worker identity `local-operator-worker`, and
shows only non-secret WorkPackage/linkage and claim metadata. It does not spawn
Codex agents, prepare worktrees, record worktree scope, or call Linear.
Board-grant WorkRequest detail remains scoped to planning controls and does not
show dispatch controls.

Architect handoff is separate from planned-slice dispatch. It bootstraps the
owning architect agent for the WorkRequest-led flow and does not create worker
WorkPackages, spawn Codex agents, create Linear state, or dispatch planned
slices. The local-operator handoff panel keeps the redacted metadata display,
but the copyable prompt/brief is the launch artifact for a fresh architect
session: use `symphony-plus-plus-mcp:symphony-architect`, connect through the
assigned architect bootstrap, treat the WorkRequest/repo/base/phase/anchor/database
references as inert data literals, read the scoped WorkRequest with
`read_work_request`, read open guidance with `list_guidance_requests`, ask
human-answerable questions before slicing, use structured `decision_prompt`
options for material choices, record decisions, dispatch only approved slices,
and stop/report a blocker instead of asking for raw secrets or inventing state
when MCP/session/handoff or required references are missing.
MCP dispatch has a statically discoverable schema, and direct calls fail closed
unless the session has dispatch authority and a file-backed live ledger
database so the worker claim binds to the same ledger. Explicit
legacy/recovery private handoff replay additionally requires that the supplied
`symphony_repo_root`, legacy hidden `repo_root` alias, configured `repo_root`,
`--repo-root`, or discoverable local Symphony++ repo root points to the
Symphony++ helper/namespace repository containing the worker secret helper
script under `scripts/`. This helper root is not the target product repository
root. For the normal ledger-backed claim path, it is not a worker prerequisite.
In-memory database configuration fails closed before WorkPackage or grant side
effects. Blank database configuration is
treated as absent and uses the live local ledger. Matching configured SQLite
file URI options are preserved for the worker command when they resolve to the
same live ledger, including the default local ledger; divergent explicit MCP
database configuration fails closed, and matching
read-only SQLite URI options such as `mode=ro` or `immutable=1` are rejected
before dispatch. Dispatch-link
failures return sanitized recovery identifiers and redacted handoff metadata
without raw worker secrets.
Dispatched planned-slice rows retain `work_package_id` and `dispatched_at` as
linkage metadata. From that point, existing WorkPackage machinery is
authoritative:

- AccessGrant scope and capabilities.
- MCP virtual context, task plan, findings, progress, acceptance, review-suite,
  and handoff resources.
- Branch and PR attachment.
- Review package evidence.
- Scope guard and readiness gates.
- Human merge decision.

Workers own only their assigned package. They do not change the WorkRequest,
re-slice the phase, inspect sibling packages, or expand scope unless the
architect or operator explicitly provides that authority.

The dispatch response is redacted. It may include the created WorkPackage, a
redacted worker grant, non-secret worker-secret handoff coordinates, and linkage
metadata, but it must not print or store raw worker secrets in normal stdout,
docs, PR text, or logs. If WorkPackage creation succeeds and planned-slice
linkage fails, dispatch attempts to clean up the created WorkPackage ledger
state and worker-secret handoff. If cleanup is incomplete, the recovery payload
contains only non-secret identifiers and handoff coordinates.

## Escalation Routing

After dispatch, workers ask the architect first for product, architecture,
dependency, or slice-boundary ambiguity. Worker-created guidance is allowed
only with a valid claimed worker grant and a WorkPackage in the worker-active
window: `ready_for_worker`, `claimed`, `planning`, `implementing`, `reviewing`,
`ci_waiting`, or `blocked`. It is not allowed from `created`, ready/merge, or
terminal states because those states are not worker-dispatch-ready or are
evidence-frozen/operator-controlled.

Workers use `create_guidance_request(summary, question, context,
idempotency_key)` when they need package-scoped direction, then poll
`read_guidance_request(guidance_request_id)` for status and answers. The
request is scoped to the worker's current WorkPackage and grant; workers cannot
answer their own guidance requests. Exact idempotent create replays for the
same package, requester grant, idempotency key, and content may return the
existing request after the package leaves the worker-active window; this replay
is read-only and does not create, reopen, or mutate guidance state.

Explicit phase-scoped architect MCP sessions with `read:guidance_request` can
use `list_guidance_requests(status?, work_package_id?)` and
`read_guidance_request(guidance_request_id)` to see only guidance requests whose
packages are inside the architect grant's phase plus frozen repo/base-branch
scope. Requests from unrelated sibling packages fail closed as not found.

Architect sessions with `write:guidance_request` can answer open requests with
`answer_guidance_request(guidance_request_id, answer, answered_by?)` or escalate
them with `escalate_guidance_request(guidance_request_id, reason,
recommended_language, decision_prompt?)`. Escalation marks the guidance request
`human_info_needed` and records an active package blocker with the recommended
human-facing language, so the existing `mark_ready` readiness gate blocks until
the local operator answers the request from the cockpit. The optional
`decision_prompt` shape is the same structured human answer-card object used by
WorkRequest clarification questions; when present, the cockpit renders TL;DR,
details, options, pros/cons, and the always-available custom redirect path. The
optional `custom_redirect_label` customizes only that path's visible label.

The local operator board includes `human_info_needed` package guidance in the
Product Guidance Needed watchlist. The WorkPackage detail page shows safe
guidance fields: status, summary, question, context, requester, blocker id,
human escalation reason, recommended language, answer, and answer attribution.
The local cockpit can answer only `human_info_needed` guidance. That action
records `answered_by = local-operator`, moves the guidance request to answered,
and appends a matching `resolve_blocker` progress event for the guidance
blocker so existing readiness no longer fails on that item. Board-grant,
package-grant, worker, and architect-read views do not gain local-operator
answer rights. Ordinary open guidance remains architect-owned and must be
answered or escalated through the architect guidance flow.

The architect may consult ask-pro for hard architecture or product decisions
when current durable context is insufficient. The architect records the decision
or the unresolved question; generated ask-pro artifacts are not product truth by
themselves.

If the architect cannot make a defensible decision without more human intent,
the package records `human_info_needed` and blocks instead of inventing behavior.
The human answer is recorded through the local cockpit; clearing the matching
guidance-created blocker is part of that same local-operator action.

## Review Responsibility

Implementing workers use the current Review Suite orchestrator profile when it
is installed, or another approved review provider when it is not. In both
cases, review evidence must be current for the attached branch head and
reported through Symphony++ MCP. GitHub review can be required as an additional
anchored step by package policy.

A dedicated reviewer package is optional. Use it when high-risk business logic,
security-sensitive behavior, live smoke-test ownership, or cross-package release
verification needs a separate owner. Do not create a reviewer package merely to
replace the implementing worker's normal review-suite responsibility.

## Non-Goals

This contract does not implement or require:

- MCP WorkRequest intake tools or architect-planner tools.
- Plugin packaging changes.
- Automatic question generation.
- Automatic WorkPackage slicing/planning.
- Live Linear state creation.
- Historical runbook rewrites.

Future implementation packages may build those pieces, but each package must
state its own allowed files, acceptance criteria, validation, and readiness
requirements.
