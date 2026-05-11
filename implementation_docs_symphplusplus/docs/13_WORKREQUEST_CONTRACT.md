# v2 WorkRequest Product Contract

This document defines the v2 WorkRequest product contract. It is operator-facing
product documentation only. It preserves the existing WorkPackage ledger,
AccessGrant permissions, virtual planning resources, readiness gates,
review-suite evidence, PR evidence, and human merge controls.

This document does not claim that runtime WorkRequest storage, dashboard intake,
MCP intake tools, automatic slicing, or plugin packaging already exists.

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
- Human description of the desired outcome.
- Constraints, including allowed paths, forbidden paths, compatibility stance,
  rollout limits, dependencies, secrets, validation limits, and stop conditions.
- Desired dispatch shape, one of `single_package`,
  `architect_led_feature_branch`, `direct_main_fix`, `investigation_first`, or
  `review_only`.

The request may include preferred branch names, known risks, relevant docs,
expected tests, desired reviewers, and links to existing issues or PRs.

## Docs-Only Source Of Truth

Until runtime WorkRequest intake exists, the canonical WorkRequest is one
versioned, operator-approved Markdown artifact. `implementation_docs_symphplusplus/`
defines the stable product contract; individual WorkRequest artifacts are
request state and should live in the operator-approved planning location for
that project or lane.

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

1. Human records the WorkRequest and marks it ready for clarification.
2. Architect reads the request and asks product questions before slicing.
3. Human answers are recorded as durable request context.
4. Architect records decisions and explicit assumptions before creating the
   slice plan.
5. If human intent is still missing, the request or package records
   `human_info_needed`. Agents do not invent product behavior to keep moving.

Clarification is about product and architecture intent. It is not a place for
workers to broaden scope after dispatch.

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
  validation, review lanes, and stop conditions.
- Parent/child relationships when an architect-led phase is needed.
- The intended PR target for each slice.
- Any package that should be investigation-only or reviewer-only.

Feature work defaults to one feature branch with smaller PRs targeting that
feature branch. Use direct `main` PRs for narrow direct-main changes when the
architect plan records why a feature branch would add overhead without reducing
risk.

## Dispatch Into WorkPackages

Approved slices become normal WorkPackages. From that point, existing
WorkPackage machinery is authoritative:

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

## Escalation Routing

After dispatch, workers ask the architect first for product, architecture,
dependency, or slice-boundary ambiguity.

The architect may consult ask-pro for hard architecture or product decisions
when current durable context is insufficient. The architect records the decision
or the unresolved question; generated ask-pro artifacts are not product truth by
themselves.

If the architect cannot make a defensible decision without more human intent,
the package records `human_info_needed` and blocks instead of inventing behavior.

## Review Responsibility

Implementing workers run review-suite T1, T2, and GitHub review by default
unless the package policy explicitly says otherwise. Review evidence must be
current for the attached branch head.

A dedicated reviewer package is optional. Use it when high-risk business logic,
security-sensitive behavior, live smoke-test ownership, or cross-package release
verification needs a separate owner. Do not create a reviewer package merely to
replace the implementing worker's normal review-suite responsibility.

## Non-Goals

This contract does not implement or require:

- Runtime WorkRequest schemas, migrations, or persistence.
- Dashboard WorkRequest intake screens.
- MCP WorkRequest intake tools or architect-planner tools.
- Plugin packaging changes.
- Automatic WorkPackage slicing.
- Live Linear state creation.
- Historical runbook rewrites.

Future implementation packages may build those pieces, but each package must
state its own allowed files, acceptance criteria, validation, and readiness
requirements.
