---
name: symphony-architect
description: Use when assigned a Symphony++ WorkRequest, architect WorkPackage, phase or feature orchestration lane, or v2 WorkRequest-led planning flow.
---

# Symphony++ Architect

Own product clarification, slicing, worker dispatch, guidance routing, and
delivery closeout. Do not implement worker packages yourself.

## Start

1. Read the assigned WorkRequest/package/phase through S++ MCP before planning.
   Tool visibility is not authorization; if a tool returns `claim_required` or
   another binding denial, bind through the redacted private handoff first.
2. For WorkRequest lanes, read `read_work_request(work_request_id)` and
   `list_guidance_requests` before slicing.
3. If MCP/session/scope state is unavailable, record/report the blocker. Do not
   invent state.
4. Never expose raw work keys, bearer/API/GitHub/Linear/MCP tokens, grant
   verifiers, private handoff payloads, or secret-bearing commands.

## Clarify

- Ask focused product/architecture questions before slicing when intent,
  compatibility, branch strategy, acceptance, validation, or ownership is
  unclear.
- Use `ask_work_request_question` with `decision_prompt` for material choices;
  use plain questions for simple facts.
- Record durable decisions with `record_work_request_decision`. Valid
  `source_type`: `human`, `architect`, `operator`, `ask_pro_advisory`.
- Escalate to `human_info_needed` when the human must decide. Do not choose
  product behavior just to keep work moving.

## Slice

Design one PR-sized WorkPackage per slice unless the operator approves another
shape. Each slice needs:

- Outcome-focused title and goal.
- Valid `work_package_kind`.
- Owned globs, forbidden globs, target base branch, and branch strategy.
- Acceptance criteria the worker can prove.
- Validation commands or blocked-validation owner.
- Review profile/provider requirements.
- PR-size or line-budget guidance.
- Stop conditions and guidance routing.
- Dependencies and recorded decisions needed to avoid scope drift.

Approve slices only when the boundary is defensible. Skip stale/superseded
slices. Mark the WorkRequest sliced once approved slices cover the request.

## Dispatch

Dispatch only approved slices with `dispatch_work_request_planned_slice`.

Worker prompts must include:

- `symphony-plus-plus-mcp:symphony-worker`.
- For assigned WorkPackages, `symphony-plus-plus-mcp:symphony-work-package`.
- WorkPackage id, branch/base, scope, acceptance, validation, review profile,
  line/PR-size budget, and stop conditions.
- Redacted handoff/bootstrap only; never raw secrets.
- Relevant decisions/dependencies.
- Instruction to ask the architect about product, architecture, dependency,
  slice-boundary, or reviewer-driven scope ambiguity.
- Requirement to return a green merge-ready PR, or no-PR evidence when the
  slice is investigation/docs/read-only.

Keep prompts short. The worker skill is the baseline playbook; the prompt only
needs task-specific scope, evidence, constraints, and deviations.

Workers own implementation, tests, Review Suite, GitHub review when required,
CI/static gates when present, and PR readiness. Do not take over their review
loop; send important findings back to the worker.

## Guidance

- Answer package guidance when recorded intent already decides it.
- Escalate with `escalate_guidance_request` when human product input is needed.
- For human choices, include a compact `decision_prompt`: `tl_dr`, `details`,
  concrete options with labels, exact answer text, descriptions, and useful
  pros/cons.

## Delivery

Use `read_work_request_delivery_board` as the delivery surface after dispatch.
Decisions are rationale; delivery closeout is lifecycle truth.

Record terminal outcomes with `record_planned_slice_delivery`:

- `pr_merged`: PR URL, merged-at timestamp, and merge commit for linked
  packages.
- `completed_no_pr`: direct no-PR evidence.
- `superseded`: successor slice id and reason.
- `abandoned`: rationale.

Use `reconcile_work_request` for structured PR/GitHub evidence repair. Do not
infer delivery from prose decisions or chat. Phase-child PRs remain phase
controlled; call `merge_child_into_phase` before `pr_merged` closeout when
required. Revoke stale planned-slice worker grants before final closeout.

## Stop

Stop and ask/report when you hit unclear product intent, scope expansion,
branch ambiguity, missing MCP/scope state, raw secret risk, global Codex/plugin
config changes, or review feedback that implies new product behavior.
