# Operational Runbook

For role boundaries and examples, read `12_OPERATOR_TRAINING.md`. This file is
the short command-flow reference for operators.

## Standalone Package

1. Choose `quick_fix`, `hotfix`, `investigation`, or another package policy
   that matches the work. Keep repo, base branch, owned paths, acceptance
   criteria, and tests narrow.
2. Copy the nearest request template from `../templates/` into scratch space and
   edit the copy. Do not edit shared templates for one incident.
3. From `elixir/`, run
   `mise exec -- mix sympp.create_work --database <ledger.sqlite3> --file ../scratch/<request>.yaml --claimed-by <worker-id>`
   with the edited request path and stable worker identity.
4. Confirm normal command output contains only non-secret handoff metadata. The
   worker grant secret must be stored in the private local handoff store, not
   printed into stdout, prompts, PR text, or logs.
5. Make sure the worker has the `symphony-plus-plus` Codex plugin from
   `plugins/symphony-plus-plus/` or the repo-local
   `.codex/skills/symphony-work-package/` copy, plus the MCP stdio dependency
   configured through the private-store bootstrap documented in
   `.codex/skills/symphony-work-package/references/mcp_wiring.md`.
6. Dispatch the worker with the package id, base branch, target branch
   convention, owned paths, acceptance criteria, required validation/review
   lanes, handoff target, stable `claimed_by` identity, and the prompt in
   `../templates/worker_agent_prompt.md`.
7. Watch the dashboard/API or MCP-visible package state for claim, plan,
   findings, progress, blockers, branch, PR, validation, and review evidence.
8. For PR-required packages, review the PR with
   `../review/REVIEWER_CHECKLIST.md` and confirm evidence is current for the
   attached branch head.
9. Close non-PR packages only after their policy gates pass. Merge PR-required
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

Record the resolution in package progress and leave blocked validation explicit
when it cannot be completed safely.

## Revoking A Worker

1. Revoke the affected grant.
2. Stop or pause the active run if the runner supports it.
3. Preserve workspace and logs for audit.
4. Record the revocation and reason in package progress.
5. Reassign only with a new grant and a new private handoff if the package
   should continue.

## Hotfixes And Incidents

- Hotfix procedure: `../runbooks/HOTFIX_RUNBOOK.md`
- Permission or secret leak: `../runbooks/INCIDENT_PERMISSION_OR_SECRET_LEAK.md`
- Release evidence: `11_RELEASE_VALIDATION.md`

Historical pilot runbooks remain available under `../runbooks/` but are not the
default starting point for new work unless an operator explicitly assigns that
pilot.
