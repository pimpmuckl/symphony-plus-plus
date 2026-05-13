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

1. Human records a WorkRequest and marks it ready for clarification.
2. Architect asks product questions, records human answers, and writes durable
   decisions or assumptions before slicing.
3. Architect produces an architect plan and a slice plan. Feature work defaults
   to one feature branch with smaller PRs against it. Narrow fixes may target
   `main` directly when the plan records that choice.
4. Architect dispatches approved slices as normal WorkPackages.
5. After dispatch, workers ask the architect first when product or architecture
   ambiguity appears. The architect may use ask-pro for hard calls. Unresolved
   product ambiguity becomes `human_info_needed`.
6. Implementing workers run review-suite T1, T2, and GitHub review by default
   unless the package policy says otherwise. A dedicated reviewer package is
   optional for high-risk business logic or live smoke-test ownership.

This flow preserves existing WorkPackage grants, virtual planning resources,
readiness gates, review evidence, PR evidence, and human merge controls. It is
not a claim that MCP intake tooling, automatic slicing/planning, automatic
question generation, Linear state creation, or richer plugin packaging already
exists.

Runtime WorkRequest persistence, the read API, the dashboard list/detail view,
scoped dashboard intake, architect MCP WorkRequest reads, clarification and
decision mutations, planned-slice mutations, the manual clarification loop, and
manual planned-slice authoring now exist. Architect MCP planned-slice dispatch
also exists for explicit phase-scoped grants with `dispatch:work_request`.
Local-operator dashboard dispatch also exists for approved, undispatched
planned slices. Dashboard intake is board-authenticated and only appears for
board grants with frozen repo
and base-branch scope. The repo and base branch are displayed as locked values
and are enforced by the server when creating the draft. Humans can mark a draft
WorkRequest `ready_for_clarification` from the detail view. For board-visible, in-scope
WorkRequests, the detail view can also ask clarification questions, answer or
close open questions, record durable decisions, mark `human_info_needed`, and
mark `ready_for_slicing` only after no open clarification questions remain.
Once a request is `ready_for_slicing` or `sliced`, the detail view can add
planned slices, approve or skip mutable slices, and mark a request `sliced`
only after at least one planned slice has been approved. In local operator mode,
the detail view can also dispatch approved, undispatched planned slices into
WorkPackages. Board-grant WorkRequest detail remains scoped to planning
controls and does not expose planned-slice dispatch.

Explicit phase-scoped architect MCP sessions with `read:work_request` can call
`list_work_requests(status?)` and `read_work_request(work_request_id)` for the
same frozen repo/base-branch WorkRequest scope. These tools are read-only, do
not accept arbitrary repo or base-branch arguments, and hide missing or
out-of-scope requests as not found. Legacy null `phase_id` architect grants are
not supported for these WorkRequest reads and fail closed rather than reading
scope from a mutable anchor package.

Explicit phase-scoped architect MCP sessions with `write:work_request` can call
`set_work_request_status`, `ask_work_request_question`,
`answer_work_request_question`, `close_work_request_question`, and
`record_work_request_decision` for the same frozen repo/base-branch scope. The
same sessions can call `add_work_request_planned_slice`,
`approve_work_request_planned_slice`, `skip_work_request_planned_slice`, and
`mark_work_request_sliced`. Each mutation requires a scoped `work_request_id`;
answer and close calls also prove the `question_id` belongs to that WorkRequest
before mutating, while approve and skip prove the `planned_slice_id` belongs to
that WorkRequest before mutating. `mark_work_request_sliced` keeps the existing
approved-slice requirement. These write tools still do not dispatch planned
slices, create WorkPackages, alter SecretHandoff, change dashboard behavior, or
mutate Linear.

Explicit phase-scoped architect MCP sessions with `dispatch:work_request` can
call `dispatch_work_request_planned_slice(work_request_id, planned_slice_id,
claimed_by, secret_handoff?, secret_store_dir?)`. This is intentionally
separate from `write:work_request` because dispatch creates a WorkPackage,
worker grant, and private worker-secret handoff. The tool uses the existing
planned-slice dispatch orchestration and returns only WorkRequest id,
planned-slice linkage/status, WorkPackage id metadata, and redacted worker
handoff metadata. Start MCP dispatch sessions with `repo_root`/`--repo-root`
pointing at the repository that contains the worker secret handoff script;
otherwise the tool is not advertised and direct calls fail closed. Use a
file-backed live ledger; in-memory database configuration is rejected so the
worker handoff cannot point at an unclaimable ledger. Blank database
configuration is treated as absent and uses the live ledger. Matching configured
SQLite file URI options are
preserved for the worker command when they resolve to the same live ledger,
including default repo database configuration; divergent explicit MCP database
configuration is rejected. Do not start dispatch MCP with read-only SQLite URI
options such as `mode=ro` or `immutable=1`; those are rejected before dispatch
because workers must claim grants and write progress.

Planned-slice dispatch is available as an operator CLI, architect MCP tool, and
local-operator dashboard action. Each path dispatches one `approved` planned
slice by WorkRequest id and planned-slice id, validates the slice's owned file
globs against the parent WorkRequest path constraints before minting a
WorkPackage, creates the worker-ready package through private worker-secret
handoff, and then records the planned-slice linkage. The dashboard action
reuses the existing `PlannedSliceDispatch` orchestration, records the stable
worker identity `local-operator-worker`, and shows only non-secret
WorkPackage/linkage and handoff metadata. It does not spawn Codex agents and
does not call Linear. The validator is pure and does not inspect the host
filesystem. Missing or empty `allowed_paths` leaves the slice unrestricted by
allow-list, but `forbidden_paths` still block overlapping owned globs. As a
least-privilege rule, `allowed_paths: ["*"]` is not an implicit whole-repo
grant; wildcard allow entries without an explicit `**` only authorize their own
segment shape and do not authorize recursive owned globs such as `**/foo` or
bare `**`.

MCP intake, automatic question generation, automatic slicing/planning, MCP
planner tools, Linear state creation, and richer plugin packaging remain future
work. Until those exist, keep questions, answers, decisions, assumptions, and
slice-plan sections in runtime WorkRequest records where available, or in one
operator-approved Markdown artifact when the runtime surface is not available
for a lane. Give the architect package a durable reference plus a bounded
handoff summary before dispatch.

## Planned-Slice Dispatch CLI

Run planned-slice dispatch from `elixir/` after a slice is approved:

```powershell
mix sympp.dispatch_planned_slice `
  --database <sqlite-path> `
  --work-request-id <work-request-id> `
  --planned-slice-id <planned-slice-id> `
  --claimed-by <stable-worker-id> `
  --secret-handoff auto
```

The task also accepts `--secret-store-dir <path>` for local private-file
handoff storage. It validates required identifiers and `claimed_by` before
opening or creating the ledger database, migrates the Symphony++ repo, and
prints pretty JSON on success. Normal output is redacted: it includes the
created WorkPackage, redacted worker grant, non-secret handoff coordinates, and
planned-slice linkage metadata, but never the raw worker secret.

If WorkPackage creation succeeds but linkage fails, the dispatcher attempts to
delete the created WorkPackage ledger state and worker-secret handoff. When
cleanup is incomplete, the returned recovery payload contains non-secret
identifiers and handoff coordinates for operator recovery.

## Standalone Flow

1. Read `01_IMPLEMENTATION_GUIDE.md`, then choose the package policy.
2. Copy a `../templates/create_work_package.*.example.yaml` request into
   scratch space and edit the package-specific fields.
3. Run the create-work command from `elixir/` with the edited file, ledger
   database, and stable `--claimed-by <worker-id>`.
4. Confirm the returned handoff data is non-secret. Normal output should show
   the private-store handoff target and MCP bootstrap shape, not the raw worker
   secret.
5. Ensure the worker has the local plugin or skill and MCP stdio dependency
   configured through the private-store bootstrap. The installable Symphony++
   Codex plugin also exposes a generic MCP entry for plugin UI discovery, but
   that static entry is not a per-worker handoff and must not contain raw worker
   secrets, private-store handoff targets, bearer tokens, or operator-local
   secret material.
6. Dispatch the worker with package id, base/target branch guidance, owned
   paths, acceptance criteria, test plan, review lanes, handoff target, stable
   `claimed_by`, and stop conditions.
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
- Handoff target and stable `claimed_by` identity.
- Required review lanes and stop conditions.
- Links to non-secret docs, templates, and MCP wiring instructions.

Worker handoffs must not include raw grant secrets, bearer tokens, GitHub
tokens, Linear tokens, MCP auth tokens, full secret-bearing claim URLs, private
keys, or signed URLs.

For worker dispatch, use the private-store `run-mcp` command emitted by
`mix sympp.create_work` or planned-slice dispatch. Do not copy those
worker-specific handoff targets into static plugin files; the plugin's generic
MCP entry is only an installable capability entry and runtime launcher.

## Closeout Record

Before declaring a package ready or closing an operator lane, record:

- Package id, PR URL, final head SHA, and base branch.
- Changed files and confirmation they match package scope.
- Validation commands and results.
- Review-suite evidence for required lanes.
- Known limitations or explicit none.
- Any blocked validation with exact blocker and owner.
