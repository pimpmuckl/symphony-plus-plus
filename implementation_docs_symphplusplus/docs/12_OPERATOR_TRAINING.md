# Operator Training

Use this guide when starting a Symphony++ lane from scratch. It links the
existing contracts and runbooks without replacing them.

## Choose the flow

Use a standalone package when the work is one bounded fix, investigation, or
hotfix that does not need an architect-owned phase branch. Standalone work is
the right first proof because one human can create the package, hand one worker
a grant, review one PR, and land it after readiness gates pass.

Use a phase-based flow when the work needs sequencing across multiple packages,
shared dependency decisions, or an architect who can mint child worker grants.
The architect owns package order and phase summaries; workers still own only
their assigned packages.

## Standalone hotfix flow

1. Read `../runbooks/HOTFIX_RUNBOOK.md`.
2. Pick the correct base branch and keep the acceptance criteria narrow.
3. Create the package from an edited copy of
   `../templates/create_work_package.hotfix.example.yaml` with the
   incident-specific title, scope, tests, and base.
4. Run the create-work command from the runbook and capture the returned worker
   grant secret only in the private handoff channel.
5. Install or copy `.codex/skills/symphony-work-package/` into the worker repo
   and configure the Symphony++ MCP stdio dependency before dispatch.
6. Hand the worker the package id, base branch, target branch naming, worker
   prompt, and secret. Do not put the secret in files, logs, PR bodies, or chat
   transcripts that will be committed or archived broadly.
7. Watch the dashboard/API timeline for claim, plan, findings, progress,
   branch/PR attachment, validation, and review evidence.
8. Review the PR against `../review/REVIEWER_CHECKLIST.md`.
9. Confirm `../review/READINESS_GATES.md` and
   `11_RELEASE_VALIDATION.md` evidence are current for the PR head.
10. Merge only after branch protection and human review pass, then archive the
   package evidence and close the incident notes.

## Phase-based flow

1. Read `00_ARCHITECT_AGENT_HANDOFF.md`.
2. Create or select the phase branch and confirm dependency packages are merged.
3. Mint an architect grant for the phase, not a broad worker grant.
4. Give the architect `../work_packages/00_INDEX.md`, the relevant package
   specs, and the phase constraints.
5. Require one worker PR per package unless the architect explicitly splits or
   combines scope with rationale.
6. Require each worker to prove package acceptance and review gates on its own
   PR head before the architect merges it into the phase branch.
7. Promote the phase branch only after the architect can summarize merged
   packages, residual risks, validation, and any deferred limitations.

## Responsibility boundaries

The operator owns package creation, private secret handoff, release policy,
merge decisions, and final evidence archival.

The architect owns phase sequencing, child package creation, worker-key minting,
scope expansion decisions inside the phase, and phase-branch readiness.

The worker owns exactly one assigned package: claim the key, read scoped virtual
planning resources, keep progress/findings current, implement the bounded diff,
attach branch/PR evidence, run validation, submit review evidence, and stop for
scope expansion.

The reviewer owns correctness, acceptance, test evidence, security, and scope
checks. Reviewers should not turn a focused package into broad documentation
cleanup, old-doc deletion, or unrelated runtime redesign.

## Closeout record

Before declaring a package ready, record:

- Package id, PR URL, final head SHA, and base branch.
- Changed files and confirmation they match the package scope.
- Validation commands and results.
- Review-suite evidence for required lanes.
- Known limitations or explicit none.
- Any blocked validation with the exact blocker and owner.
