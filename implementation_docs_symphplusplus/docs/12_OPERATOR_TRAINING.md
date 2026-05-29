# Operator Training

Use this guide when starting a Symphony++ lane from scratch. It explains the
roles and the normal evidence flow without relying on old implementation phase
history.

## Roles

The operator creates packages, controls private secret handoff, sets release
policy, makes merge decisions, and archives final evidence.

The architect sequences multi-package work, creates child packages inside the
operator-approved scope, mints narrower child worker grants, handles approved
scope decisions, and reports aggregate readiness.
Codex architect agents should use the plugin-installed
`symphony-plus-plus-mcp:symphony-architect` skill as their operating playbook for
WorkRequest clarification, decision recording, planned-slice authoring,
dispatch, and package guidance routing.

The worker owns exactly one assigned package: claim the grant, read MCP-backed
planning resources, keep progress/findings/current plan updated, implement the
bounded diff, attach branch/PR/review evidence, and stop for scope expansion.

The reviewer checks correctness, acceptance, validation, security, and scope on
the current PR head. Reviewers should not turn a focused package into broad doc
cleanup, old-doc deletion, runtime redesign, or compatibility-policy changes.

A v2 WorkRequest is the pre-WorkPackage product intake object. It lets the
human provide the repo/project, base branch, work type, description,
constraints, and desired dispatch shape before an architect asks clarification
questions and slices the work.

## WorkRequest Flow

1. Human records a WorkRequest and starts agent questions, which marks it
   `ready_for_clarification`.
2. Architect asks product questions, records human answers, and writes durable
   decisions or assumptions before slicing.
3. Architect produces an architect plan and a slice plan. Feature work defaults
   to one feature branch with smaller PRs against it. Narrow fixes may target
   `main` directly when the plan records that choice.
4. Architect dispatches approved slices as normal WorkPackages.
5. After dispatch, workers ask the architect first when product or architecture
   ambiguity appears. The architect may use ask-pro for hard calls. Unresolved
   product ambiguity becomes `human_info_needed`; the local operator answers it
   from the package cockpit, which clears the matching readiness blocker.
6. Implementing workers use the current Review Suite orchestrator profile when
   it is installed, or another approved review provider with Symphony++ MCP
   progress/evidence when it is not. A dedicated reviewer package is optional
   for high-risk business logic or live smoke-test ownership.

This flow preserves existing WorkPackage grants, virtual planning resources,
readiness gates, review evidence, PR evidence, and human merge controls. The
installable Codex plugin exposes current Symphony++ skills and a generic MCP
wrapper, but this flow is not a claim that MCP intake tooling, automatic
slicing/planning, automatic question generation, Linear state creation, or
richer planner/intake plugin surfaces or automatic Codex spawning already
exist.

Runtime WorkRequest persistence, the read API, the dashboard list/detail view,
scoped dashboard intake, architect MCP WorkRequest reads, clarification and
decision mutations, planned-slice mutations, the manual clarification loop, and
manual planned-slice authoring now exist. Architect MCP planned-slice dispatch
also exists for explicit phase-scoped grants with `dispatch:work_request`.
Local-operator dashboard detail can start agent questions for a draft
WorkRequest, dispatch approved undispatched planned slices, and prepare an
architect handoff for ready/active WorkRequest planning states. That handoff
creates or reuses the WorkRequest-scoped phase and architect anchor package,
mints an unclaimed architect grant for WorkRequest/guidance MCP capabilities,
stores the architect secret through the explicit private-handoff recovery
surface, and shows only non-secret/redacted bootstrap metadata plus a prompt for the
`symphony-plus-plus-mcp:symphony-architect` skill. The prompt is intended to be the
first message for a fresh owning architect session: it includes WorkRequest,
repo/base, phase, anchor WorkPackage, and ledger references as inert data
literals, names the required first MCP reads, states clarification and
decision-prompt expectations, preserves the approved-slice dispatch boundary,
and includes the stop condition for missing MCP/session/handoff without asking
for raw secrets.
Package-scoped guidance requests can be escalated by architects to
`human_info_needed`; the local operator cockpit shows those package guidance
items in the product guidance watchlist and can answer only that escalated state
with stable `local-operator` attribution. The answer records a matching blocker
resolution event so the existing readiness gates no longer fail on the resolved
guidance request. Ordinary open guidance remains architect-owned.
Dashboard intake is board-authenticated and only appears for board grants with
frozen repo and base-branch scope. The repo and base branch are displayed as
locked values and are enforced by the server when creating the draft. Humans
can mark a draft WorkRequest `ready_for_clarification` from the detail view.
In local operator mode, that human-owned action is labeled `Start agent
questions` and does not expose architect-owned question, decision, or
planned-slice authoring controls. For board-visible, in-scope WorkRequests,
the detail view can also ask clarification questions, answer or close open
questions, record durable decisions, mark `human_info_needed`, and mark
`ready_for_slicing` only after no open clarification questions remain.
Once a request is `ready_for_slicing` or `sliced`, the detail view can add
planned slices, approve or skip mutable slices, and mark a request `sliced`
only after at least one planned slice has been approved. In local operator mode,
the detail view can also dispatch approved, undispatched planned slices into
WorkPackages. Board-grant WorkRequest detail remains scoped to planning
controls and does not expose planned-slice dispatch.

Skipped planned slices that were never dispatched, have no linked WorkPackage,
and have no planned-slice delivery record are planning scratch. The WorkRequest
detail and delivery-board projections hide them from the main slice list by
default so corrected draft slices do not look like delivery work. Use the
supported `include_planning_scratch=true` inspection path when you need to audit
them. Do not clean this state with direct SQLite deletion.

For WorkRequests in `ready_for_clarification`, `clarifying`,
`human_info_needed`, `ready_for_slicing`, or `sliced`, local operator detail can
prepare an architect handoff before slicing or dispatch. Repeating the action
replays the existing active unclaimed handoff when available; otherwise it reuses
the same phase/anchor and mints a renewed unclaimed architect grant. If an
active unclaimed handoff can be safely proven stale from stored metadata, the
old grant is retired before renewal. Missing or otherwise unverifiable metadata
fails closed rather than minting a duplicate grant. The UI must not show raw
work-key secrets, secret hashes, or full MCP secret-retrieval commands.
Reloading local-operator detail can show the already prepared handoff again when
its active unclaimed metadata is safely readable and replayable; reload display
is read-only and does not mint, renew, revoke, or clean up handoffs.
Board-grant WorkRequest detail cannot create this handoff.

Local worker and architect grants are non-expiring by default. Operators should
recover stale or abandoned authority by revoking grants, completing/merging or
archiving packages, or recycling child workers, not by waiting for default grant
clocks. An explicit `expires_at` remains a deliberate narrowing constraint when
a package or tool passes one.

Explicit phase-scoped architect MCP sessions with `read:work_request` can call
`list_work_requests(status?)` and `read_work_request(work_request_id)` for the
same frozen repo/base-branch WorkRequest scope. For local architect handoff
phases, the deterministic phase id also pins these tools to the selected
WorkRequest, so sibling WorkRequests on the same repo/base branch are hidden as
not found. These tools are read-only, do not accept arbitrary repo or
base-branch arguments, and hide missing or out-of-scope requests as not found.
Legacy null `phase_id` architect grants are not supported for these WorkRequest
reads and fail closed rather than reading scope from a mutable anchor package.

Explicit phase-scoped architect MCP sessions with `write:work_request` can call
`set_work_request_status`, `ask_work_request_question`,
`answer_work_request_question`, `answer_work_request_question_and_record_decision`,
`close_work_request_question`, and `record_work_request_decision` for the same
frozen repo/base-branch scope. The same sessions can call
`add_work_request_planned_slice`,
`approve_work_request_planned_slice`, `skip_work_request_planned_slice`, and
`mark_work_request_sliced`. Each mutation requires a scoped `work_request_id`;
answer and close calls also prove the `question_id` belongs to that WorkRequest
before mutating and default the expected question status to `open`, while
approve and skip prove the `planned_slice_id` belongs to that WorkRequest before
mutating.
`mark_work_request_sliced` keeps the existing
approved-slice requirement. These write tools still do not dispatch planned
slices, create WorkPackages, alter SecretHandoff, change dashboard behavior, or
mutate Linear.

Explicit phase-scoped architect MCP sessions with `dispatch:work_request` can
call `dispatch_work_request_planned_slice(work_request_id, planned_slice_id,
claimed_by, symphony_repo_root?, legacy_private_handoff?, secret_handoff?,
secret_store_dir?)`. This is intentionally separate from `write:work_request`
because dispatch creates a WorkPackage, worker grant, and ledger-backed worker
claim metadata. The tool uses the existing
planned-slice dispatch orchestration and returns only WorkRequest id,
planned-slice linkage/status, WorkPackage id metadata, and non-secret worker
bootstrap metadata. The optional `symphony_repo_root` is needed only for
explicit legacy/recovery private handoff replay; when used, it is the
Symphony++ helper/namespace repo root containing the worker secret helper
script under `scripts/`, not the target product repository root. Dispatch also
accepts the configured `--repo-root`, a discoverable local Symphony++ root, or
the hidden legacy `repo_root` alias for stale sessions. Invalid helper roots
fail with an actionable error only in that legacy/recovery path.
`legacy_private_handoff` is the exposed MCP boolean and
`--legacy-private-handoff` CLI flag for that recovery path; `secret_handoff`
and `secret_store_dir` are accepted only when it is true. Use a file-backed
live ledger; in-memory database configuration is rejected so the worker claim
cannot point at an unclaimable ledger. Blank database
configuration is treated as absent and uses the live local ledger. Matching
configured SQLite file URI options are preserved for the worker command when
they resolve to the same live ledger, including the default local ledger;
divergent explicit MCP database configuration is rejected. Do not start dispatch
MCP with read-only SQLite URI
options such as `mode=ro` or `immutable=1`; those are rejected before dispatch
because workers must claim grants and write progress.

Planned-slice dispatch is available as an operator CLI, architect MCP tool, and
local-operator dashboard action. Each path dispatches one `approved` planned
slice by WorkRequest id and planned-slice id, validates the slice's owned file
globs against the parent WorkRequest path constraints before minting a
WorkPackage, creates ledger-backed worker claim metadata, and then records the
planned-slice linkage. The dashboard action
reuses the existing `PlannedSliceDispatch` orchestration, records the stable
worker identity `local-operator-worker`, and shows only non-secret
WorkPackage/linkage and bootstrap metadata. It does not spawn Codex agents and
does not call Linear. The validator is pure and does not inspect the host
filesystem. Missing or empty `allowed_paths` leaves the slice unrestricted by
allow-list, but `forbidden_paths` still block overlapping owned globs. As a
least-privilege rule, `allowed_paths: ["*"]` is not an implicit whole-repo
grant; wildcard allow entries without an explicit `**` only authorize their own
segment shape and do not authorize recursive owned globs such as `**/foo` or
bare `**`.
When authoring `owned_file_globs`, `**` must be a complete path segment. Valid
examples include `scripts/**/deploy*.ps1` and `.github/workflows/**`; invalid
examples include `scripts/**deploy**`, `scripts/**server**`, and
`packages/**kraken_batch**`. Add and approve reject invalid planned-slice globs
early with structured field/value/reason details, and dispatch keeps the same
validation as a final guard.

After a planned slice is dispatched, the same `dispatch:work_request` architect
session can call
`prepare_work_package_worktree(work_package_id, target_repo_root, base_branch, branch, worktree_parent?)`
for the linked WorkPackage. `target_repo_root` is the target product repository
used for git validation, fetch, and worktree operations. The tool creates the
branch worktree under
`CODEX_HOME/worktrees/spp_worktrees/<repo-name>-<repo-hash>/<package-id>-<sanitized-branch>-<branch-hash>`,
records only `worktree_path` on the WorkPackage, and returns workspace path plus
branch/base launch guidance for the worker. Git failures include sanitized
status, stderr, target repo root, worktree destination, branch, and base
branch diagnostics. After merge, skip, supersede, close, or intentional parking,
call `cleanup_work_package_worktree(work_package_id, target_repo_root)`.
Cleanup verifies the recorded path is still under the managed S++ worktree root,
refuses dirty worktrees by default, proves the recorded worktree belongs to the
target product repository, removes the git worktree, prunes git worktree
metadata, clears `worktree_path`, and records redacted audit/progress evidence.
Do not use these tools to force-delete dirty worktrees, clean paths outside the
managed S++ worktree root, or clean worktrees from a different repository.

MCP intake, automatic question generation, automatic slicing/planning, MCP
planner tools, Linear state creation, richer planner/intake plugin surfaces,
and automatic Codex spawning remain future work. Until those exist, keep
questions, answers, decisions, assumptions, and slice-plan sections in runtime
WorkRequest records where available, or in one operator-approved Markdown
artifact when the runtime surface is not available for a lane. Give the
architect package a durable reference plus a bounded handoff summary before
dispatch.

## Planned-Slice Dispatch CLI

Run planned-slice dispatch from `elixir/` after a slice is approved:

```powershell
mix sympp.dispatch_planned_slice `
  --work-request-id <work-request-id> `
  --planned-slice-id <planned-slice-id> `
  --claimed-by <stable-worker-id>
```

The task also accepts `--database <sqlite-path>` only for an intentionally
isolated ledger. Use `--legacy-private-handoff` plus `--secret-handoff` or
`--secret-store-dir` only for explicit legacy/recovery replay. It validates
required identifiers and `claimed_by` before opening or creating the ledger
database, migrates the Symphony++ repo, and prints pretty JSON on success.
Normal output is redacted: it includes the created WorkPackage, redacted worker
grant, non-secret ledger `worker_bootstrap` metadata, and planned-slice linkage
metadata, but never the raw worker secret.

If WorkPackage creation succeeds but linkage fails, the dispatcher attempts to
delete the created WorkPackage ledger state and any explicitly requested legacy
worker-secret handoff. When cleanup is incomplete, the returned recovery payload
contains non-secret identifiers and, for legacy/recovery dispatch only, handoff
coordinates for operator recovery.

## Standalone Flow

1. Read `01_IMPLEMENTATION_GUIDE.md`, then choose the package policy.
2. Copy a `../templates/create_work_package.*.example.yaml` request into
   scratch space and edit the package-specific fields.
3. Run the create-work command from `elixir/` with the edited file, ledger
   database, and stable `--claimed-by <worker-id>`.
4. Confirm the returned bootstrap data is non-secret. Standalone create-work
   currently returns legacy/recovery private-store handoff metadata, not
   `claim_local_assignment` metadata.
5. Ensure the worker has the local plugin or skill and a dedicated local HTTP
   MCP session connected to the same ledger. The installable Symphony++ Codex
   plugin entry is not a per-worker claim and must not contain raw worker
   secrets, private-store handoff targets, bearer tokens, or operator-local
   secret material.
6. Launch the standalone worker with package id, base/target branch guidance,
   owned paths, acceptance criteria, test plan, review profiles, the emitted
   legacy/recovery private-store bootstrap metadata, stable `claimed_by`, and
   stop conditions.
7. Monitor claim, plan, findings, progress, blockers, branch/PR attachment,
   validation, and review evidence through Symphony++ state.
8. For PR-required packages, review the PR against
   `../review/REVIEWER_CHECKLIST.md` and confirm
   `../review/READINESS_GATES.md` evidence is current for the final head.
9. Close non-PR packages after their policy gates pass. Merge PR-required
   packages only after branch protection, required review, package readiness,
   and release-validation requirements pass.

## Architect-Led Flow

1. Read `00_ARCHITECT_AGENT_HANDOFF.md`.
   Codex architect agents should also load the
   `symphony-plus-plus-mcp:symphony-architect` skill or the repo-local
   `plugins/symphony-plus-plus-mcp/skills/symphony-architect/SKILL.md` path.
2. Confirm the operator-approved scope, base branch, child package boundary,
   dependency order, and review policy.
3. Mint an architect grant for that explicit scope, not a broad worker grant.
4. Architect creates child packages and worker grants only inside that scope.
5. Each worker PR proves its own acceptance and review gates before architect
   approval.
6. Architect records phase or aggregate evidence after each accepted child.
7. Human merge remains separate from Symphony++ readiness and must respect
   GitHub branch protection.

## Handoff Hygiene

Worker handoffs may include:

- WorkPackage id, branch guidance, owned files, acceptance criteria, and tests.
- Ledger claim metadata and stable `claimed_by` identity.
- Required review profiles and stop conditions.
- Links to non-secret docs, templates, and MCP wiring instructions.

Worker handoffs must not include raw grant secrets, bearer tokens, GitHub
tokens, Linear tokens, MCP auth tokens, full secret-bearing claim URLs, private
keys, or signed URLs.

For normal planned-slice worker dispatch, use the `claim_local_assignment`
metadata emitted by planned-slice dispatch. For standalone `mix sympp.create_work`,
use only the explicitly legacy/recovery private-store bootstrap emitted by that
command. Do not copy worker-specific legacy handoff targets into static plugin
files; the plugin's generic MCP entry is only an installable capability entry
and runtime launcher.

## Closeout Record

Before declaring a package ready or closing an operator lane, record:

- Package id, PR URL, final head SHA, and base branch.
- Changed files and confirmation they match package scope.
- Validation commands and results.
- Review-suite evidence for required lanes.
- Known limitations or explicit none.
- Any blocked validation with exact blocker and owner.
