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
not a claim that MCP intake tooling, automatic slicing, dispatch, or Linear
state creation already exists.

Runtime WorkRequest persistence, the read API, the dashboard list/detail view,
and scoped dashboard intake now exist. Dashboard intake is board-authenticated
and only appears for board grants with frozen repo and base-branch scope. The
repo and base branch are displayed as locked values and are enforced by the
server when creating the draft. Humans can mark a draft WorkRequest
`ready_for_clarification` from the detail view.

MCP intake, automatic question generation, automatic slicing, dispatch into
WorkPackages, and Linear state creation remain future work. Until those exist,
keep questions, answers, decisions, assumptions, and slice-plan sections in the
runtime WorkRequest records where available, or in one operator-approved
Markdown artifact when the runtime surface is not available for a lane. Give
the architect package a durable reference plus a bounded handoff summary before
dispatch.

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
   configured through the private-store bootstrap.
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

## Closeout Record

Before declaring a package ready or closing an operator lane, record:

- Package id, PR URL, final head SHA, and base branch.
- Changed files and confirmation they match package scope.
- Validation commands and results.
- Review-suite evidence for required lanes.
- Known limitations or explicit none.
- Any blocked validation with exact blocker and owner.
