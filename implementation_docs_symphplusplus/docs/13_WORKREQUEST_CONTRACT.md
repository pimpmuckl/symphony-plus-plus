# v2 WorkRequest Product Contract

This document defines the v2 WorkRequest product contract. It is operator-facing
product documentation only. It preserves the existing WorkPackage ledger,
AccessGrant permissions, virtual planning resources, readiness gates,
review-suite evidence, PR evidence, and human merge controls.

WorkRequest core persistence, planned-slice persistence, read API/list/detail
dashboard views, scoped dashboard intake, read-only architect MCP WorkRequest
reads, the board-authenticated manual clarification loop, and manual
planned-slice authoring/approval controls exist. Planned-slice dispatch linkage
persistence and the core planned-slice dispatch CLI exist. MCP intake tools,
automatic question generation, automatic slicing, dashboard/MCP dispatch
actions, Linear state creation, and plugin packaging remain future work.

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

## Runtime And Artifact Source Of Truth

When runtime intake is available, the canonical WorkRequest fields live in the
Symphony++ ledger and can be read through the dashboard API or dashboard UI.
The dashboard create path is intentionally scoped: it is available only to
board-authenticated grants with frozen repo and base-branch scope. The create
form accepts title, work type, desired dispatch shape, human description, and
constraints JSON. Repo and base branch are visible locked values, and submitted
repo/base fields are ignored in favor of the grant scope.

The dashboard detail path is also scoped to board-visible WorkRequests. It can
move a `draft` request to `ready_for_clarification`, ask clarification
questions, answer or close open questions, record decision log entries, mark
`human_info_needed`, and mark `ready_for_slicing`. The ready-for-slicing action
is blocked while any clarification question remains open. For
`ready_for_slicing` or `sliced` requests, the same detail page can manually add
planned slices, approve or skip existing mutable slices, and mark a
`ready_for_slicing` request `sliced` only after at least one planned slice is
approved.

Architect MCP sessions with `read:work_request` can read the same scoped
WorkRequest surface through `list_work_requests(status?)` and
`read_work_request(work_request_id)`. The list tool accepts only optional
`status` and always derives repo/base-branch scope from the live architect
assignment. The detail tool returns the WorkRequest, clarification questions,
decision log entries, planned slices, and count/status summaries. Missing or
out-of-scope WorkRequests fail closed as not found, and payloads are JSON-safe
and redacted so work-key secrets, API tokens, private handoff payloads, and
worker secret material are not returned.

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

1. Human records the WorkRequest and marks it ready for clarification.
2. Architect reads the request and asks product questions before slicing.
3. Human answers are recorded as durable request context.
4. Architect records decisions and explicit assumptions before creating the
   slice plan.
5. If human intent is still missing, the request or package records
   `human_info_needed`. Agents do not invent product behavior to keep moving.

Clarification is about product and architecture intent. It is not a place for
workers to broaden scope after dispatch.

The dashboard detail view can move a `draft` WorkRequest to
`ready_for_clarification` with a stale-status-safe action. If another process
has already changed the status, the UI reports a safe retry message instead of
overwriting the newer state.

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
  validation, review lanes, and stop conditions.
- Parent/child relationships when an architect-led phase is needed.
- The intended PR target for each slice.
- Any package that should be investigation-only or reviewer-only.

Runtime planned-slice records belong to the WorkRequest until dispatch. Their
canonical statuses are `planned`, `approved`, `dispatched`, and `skipped`.
The dashboard manual authoring path stores title, goal, WorkPackage kind,
target base branch, branch pattern, owned files, forbidden files, acceptance
criteria, validation steps, review lanes, and stop conditions. List fields are
entered as newline-delimited text and stored as ordered string lists.
Planned-slice persistence and approval do not themselves create WorkPackages or
mint worker grants. The create path starts rows as `planned`, approve moves
`planned` rows to `approved`, skip moves `planned` or `approved` rows to
`skipped`, and dispatch linkage moves `approved` rows to `dispatched` while
recording the linked `work_package_id` and `dispatched_at` timestamp. The linked
WorkPackage must match the parent WorkRequest and planned-slice contract.
Dispatched slices are read-only in this UI. Approved slices become WorkPackages
only through the explicit planned-slice dispatch CLI or a future
operator-approved dispatch surface.

Before planned-slice dispatch can mint a WorkPackage from an approved planned
slice, it must call the WorkRequest path-scope validator contract. The validator
checks the slice `owned_file_globs` against the parent WorkRequest
`constraints.allowed_paths` and `constraints.forbidden_paths` without reading
the host filesystem. Missing or empty `allowed_paths` means there is no
allow-list restriction, but `forbidden_paths` are still enforced.

The validator accepts only repo-relative slash-separated paths/globs. It rejects
absolute paths, drive-qualified paths, backslash separators, empty path
segments, and dot segments. `*` and `?` match inside one segment, while `**` is
only a full segment and may match zero or more path segments. Allowed-path
checks must prove every possible owned-glob match is equal to or beneath an
allowed path; forbidden-path checks reject any owned glob that can match a
forbidden path or any path below it.

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
sympp.dispatch_planned_slice`. The task accepts `--database`,
`--work-request-id`, `--planned-slice-id`, `--claimed-by`, `--secret-handoff`,
and `--secret-store-dir`. It validates required identifiers and `claimed_by`
before opening or creating the ledger database, migrates the repo, validates the
slice scope through `ScopeConstraints.validate_owned_file_globs/2`, creates a
worker-ready standalone WorkPackage with private worker-secret handoff, and
links the planned slice. Dispatched planned-slice rows retain `work_package_id`
and `dispatched_at` as linkage metadata. From that point, existing WorkPackage
machinery is authoritative:

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

- MCP WorkRequest intake tools, WorkRequest mutation tools, or architect-planner tools.
- Plugin packaging changes.
- Automatic question generation.
- Automatic WorkPackage slicing.
- Dashboard or MCP dispatch actions.
- Live Linear state creation.
- Historical runbook rewrites.

Future implementation packages may build those pieces, but each package must
state its own allowed files, acceptance criteria, validation, and readiness
requirements.
