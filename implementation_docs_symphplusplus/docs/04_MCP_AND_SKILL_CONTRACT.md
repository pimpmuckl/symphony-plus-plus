# MCP and Skill Contract

## Purpose

Codex workers should interact with Symphony++ through a narrow MCP interface and a repeatable Codex Skill.

## MCP resources

```text
sympp://assignment/current
sympp://work-packages/{id}/context.md
sympp://work-packages/{id}/task_plan.md
sympp://work-packages/{id}/findings.md
sympp://work-packages/{id}/progress.md
sympp://work-packages/{id}/acceptance.md
sympp://work-packages/{id}/review_suite.md
sympp://work-packages/{id}/handoff.md
```

## Worker MCP tools

```text
claim_work_key(secret, claimed_by)
get_current_assignment()
read_context()
read_task_plan()
update_task_plan(patch, expected_version)
append_finding(finding, idempotency_key)
append_progress(event, idempotency_key)
set_status(status, reason, expected_status)
report_blocker(blocker)
resolve_blocker(blocker_id, resolution)
request_scope_expansion(request)
request_context(request)
attach_branch(branch, head_sha)
attach_pr(pr_url, head_sha)
submit_review_package(summary, tests, artifacts, head_sha)
mark_ready()
```

`claim_work_key` intentionally requires both the one-time secret and a stable
`claimed_by` worker identity. Symphony++ uses that identity as part of the
worker MCP ownership contract: reconnects are accepted only when the same
secret proof is presented by the same `claimed_by` owner.

`attach_branch` intentionally requires both the branch name and the current
branch `head_sha`. Branch-only review evidence is matched to that head so a
later branch update cannot reuse stale review-package evidence.

`submit_review_package` must include `head_sha` on every submission. The latest
current-head review package is authoritative for review readiness; older
packages for the same head are superseded rather than implicitly merged.

## Architect MCP tools

```text
create_child_work_package(package)
mint_child_worker_key(work_package_id, template)
revoke_child_worker_key(grant_id, reason)
read_child_status(work_package_id)
read_phase_board(phase_id)
request_child_replan(work_package_id, reason)
approve_child_ready_state(work_package_id, rationale)
merge_child_into_phase(work_package_id, merge_artifact)
split_work_package(work_package_id, child_specs)
publish_phase_update(phase_id, update)
```

## Skill rules

The Codex Skill must instruct workers to:

1. Claim or load the current assignment first.
2. Read context, task plan, findings, progress, acceptance criteria, and review-suite requirements.
3. Update the task plan before implementation.
4. Append findings after meaningful discovery.
5. Append progress after meaningful implementation steps.
6. Request scope/context expansion instead of silently expanding work.
7. Attach branch/PR/artifacts.
8. Mark ready only after evidence is present.
9. Never create local planning files as the source of truth.
10. Never inspect or mutate sibling work unless explicit context slices are provided.

## Hook role

Hooks may remind agents to keep state updated, inject assignment context, and detect missing handoff, but hooks must not be treated as the permission boundary.
