# Operational Runbook

For role boundaries and examples, read `12_OPERATOR_TRAINING.md`. This file is
the short command-flow reference for operators.

## v2 WorkRequest Intake

Use this flow before WorkPackages exist when the human request still needs
product clarification or slicing. In local operator mode, the browser cockpit is
the preferred front door for this flow.

1. Start the local operator cockpit from `elixir/` with `mix sympp.cockpit` and
   open the printed local `/sympp/board` URL. Omitted database options use the
   shared local ledger, preferring
   `$HOME/.agents/splusplus/symphony_plus_plus.sqlite3` on POSIX-style shells or
   `%USERPROFILE%\.agents\splusplus\symphony_plus_plus.sqlite3` on Windows and
   falling back under a temp/relative `.agents/splusplus` root if home is
   unavailable; use `--database <ledger.sqlite3>` only for isolation.
2. Open `/sympp/work-requests` and choose `New WorkRequest`.
3. Enter repo and base branch explicitly, then set work type, desired dispatch
   shape, human description, and the structured constraint fields for paths,
   compatibility stance, validation expectations, dependencies or notes, and
   stop conditions. Use Advanced JSON only for uncommon constraint keys or
   complex shapes. The created request is a draft WorkRequest in the local
   ledger.
4. Human chooses `Start agent questions`, which marks the request
   `ready_for_clarification`.
5. Architect asks product questions and records decisions or explicit
   assumptions before slicing.
6. Human answers open product questions from the local WorkRequest detail page.
7. Architect marks the request ready for slicing, adds planned slices, and
   approves or skips slices.
8. Human dispatches approved slices that should become WorkPackages.
9. Browser dispatch creates the WorkPackage, worker grant, and ledger-backed
   worker bootstrap through the existing `PlannedSliceDispatch` flow. Use the
   visible WorkPackage id/status and non-secret `claim_local_assignment`
   metadata to continue the normal worker setup.
10. Mark the request sliced when at least one slice is approved or dispatched.
11. Dispatched slices become normal WorkPackages with existing readiness,
    review-suite, PR, and human merge machinery.

Board-grant mode keeps its locked-scope behavior: the WorkRequest intake form
shows the grant's repo/base branch and creation ignores any submitted repo/base
values. Local operator mode is the only browser mode where repo and base branch
are manually supplied.

If the browser surface is unavailable, record the WorkRequest with project/repo,
base branch, work type, human description, constraints, and desired dispatch
shape in one operator-approved Markdown artifact. Do not split canonical request
state across chat, generated ask-pro output, or local scratch notes.

Architect plans still decide how approved slices become packages. Feature work
defaults to a feature branch with smaller PRs against that branch; narrow fixes
may use direct `main` PRs when the plan explains why that is appropriate.

When an architect package is created, record the current WorkRequest artifact's
durable reference, optionally attach the artifact, and include a bounded summary
of the current status, decisions, assumptions, open questions, and intended
slices. Do not paste a long clarification history into package prompts.

Local operator planned-slice dispatch creates worker grants and ledger-backed
local claim metadata. It does not spawn Codex agents, call Linear, or replace
package-scoped permissions. Board-grant WorkRequest detail remains scoped to
planning controls and does not expose planned-slice dispatch. Use
`templates/worker_agent_prompt.md` for planned-slice ledger workers.

## Standalone Package

Standalone `mix sympp.create_work` still emits private-store
`worker_secret_handoff` bootstrap metadata for explicitly requested recovery
lanes. Use planned-slice dispatch for the normal ledger-backed
`claim_local_assignment` path; treat standalone create-work as legacy/recovery
unless a later WorkRequest explicitly changes that product contract.

To inspect local Symphony++ package state and manage pre-package WorkRequests,
start the local operator cockpit from `elixir/`:

```powershell
mix sympp.cockpit --dashboard-origin http://127.0.0.1:19999
```

The command binds to `127.0.0.1:19998` by default, prints
`http://127.0.0.1:19999/sympp/board` when a dashboard origin is supplied, serves
MCP at `http://127.0.0.1:19998/mcp`, initializes the shared local SQLite ledger in the
preferred `$HOME/.agents/splusplus/` home or the existing fallback root, and
blocks until interrupted. Use `--database <ledger.sqlite3>` only when you
intentionally need an isolated ledger. Use `--port 0` only when you
intentionally need a dynamic local URL; public bind hosts are rejected.

1. Choose `quick_fix`, `hotfix`, `investigation`, or another package policy
   that matches the work. Keep repo, base branch, owned paths, acceptance
   criteria, and tests narrow.
2. Copy the nearest request template from `../templates/` into scratch space and
   edit the copy. Do not edit shared templates for one incident.
3. From `elixir/`, run
   `mise exec -- mix sympp.create_work --file ../scratch/<request>.yaml --claimed-by <worker-id>`
   with the edited request path and stable worker identity. Add `--database`
   only for an intentionally isolated ledger.
4. Confirm command output contains only non-secret package and private-store
   handoff metadata. Raw worker grant secrets must not be printed into stdout,
   prompts, PR text, or logs.
5. Make sure the worker has the opt-in `symphony-plus-plus-mcp` Codex plugin from
   `plugins/symphony-plus-plus-mcp/` or the repo-local
   `.codex/skills/symphony-work-package/` copy. For this standalone
   legacy/recovery bootstrap, use the private-store wrapper flow documented in
   the `Legacy/Recovery Bootstrap` section of
   `../../.codex/skills/symphony-work-package/references/mcp_wiring.md`, not the
   planned-slice `claim_local_assignment` worker-claim flow.
6. Prepare the worker git worktree through the normal repo worktree flow when
   needed. Standalone create-work does not record ledger worktree scope or emit
   `claim_local_assignment` metadata.
7. Dispatch the worker with the package id, base branch, target branch
   convention, owned paths, acceptance criteria, required validation/review
   lanes, the emitted private-store bootstrap metadata, prepared worktree path,
   stable `claimed_by` identity, and a legacy/recovery private-store prompt such
   as the one in `../runbooks/HOTFIX_RUNBOOK.md`.
8. Watch the dashboard/API or MCP-visible package state for claim, plan,
   findings, progress, blockers, branch, PR, validation, and review evidence.
9. For PR-required packages, review the PR with
   `../review/REVIEWER_CHECKLIST.md` and confirm evidence is current for the
   attached branch head.
10. Close non-PR packages only after their policy gates pass. Merge PR-required
   packages only after readiness gates, branch protection, required review-suite
   lanes, and any package-specific release-validation requirements pass.

## Architect-Led Package

1. Confirm the operator-approved package/phase scope, base branch, owned path
   boundary, and dependency constraints.
2. Give the architect `00_ARCHITECT_AGENT_HANDOFF.md`, the live assignment,
   and any operator decisions needed to split child work.
3. Architect creates child packages only inside the explicit phase anchor and
   mints narrower child worker grants.
4. Each child worker follows the standalone worker lifecycle for its package.
5. Architect reviews child readiness, checks current-head PR evidence, and
   approves only packages whose readiness gates still pass.
6. Any actual Git integration remains a separate branch/PR operation governed
   by branch protection and human review. `merge_child_into_phase` records a
   local Symphony++ merge artifact; it does not run Git.
7. Promote or merge the aggregate branch only after the architect can summarize
   merged packages, validation, blockers, and residual risks.

## Blockers

Classify the blocker before changing the package:

- Scope: approve or deny a scope-expansion request; do not let the worker
  self-approve.
- Dependency: expose a context slice, reorder work, or block the package until
  the dependency lands.
- Design: ask the architect/operator for a decision before implementation
  drifts.
- CI/validation: require failure evidence, current branch head, and a concrete
  owner for the fix.
- Access/secret: revoke or rotate first, then diagnose from preserved logs.

For v2 dispatched work, workers route product or architecture ambiguity to the
architect first. The architect may consult ask-pro for hard calls. If the
decision still depends on unavailable human intent, record `human_info_needed`
rather than filling the gap silently.

Record the resolution in package progress and leave blocked validation explicit
when it cannot be completed safely.

## Revoking A Worker

1. Revoke the affected grant.
2. Stop or pause the active run if the runner supports it.
3. Preserve workspace and logs for audit.
4. Record the revocation and reason in package progress.
5. Reassign by preparing a new scoped worker worktree and ledger claim when the
   package should continue. Use private handoff only for explicit
   legacy/recovery cases.

## Hotfixes And Incidents

- Hotfix procedure: `../runbooks/HOTFIX_RUNBOOK.md`
- Permission or secret leak: `../runbooks/INCIDENT_PERMISSION_OR_SECRET_LEAK.md`
- Release evidence: `11_RELEASE_VALIDATION.md`

Historical pilot runbooks remain available under `../runbooks/` but are not the
default starting point for new work unless an operator explicitly assigns that
pilot.
