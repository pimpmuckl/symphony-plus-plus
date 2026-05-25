---
name: symphony-work-package
description: Use when assigned a Symphony++ work key or WorkPackage; keeps scoped planning, findings, progress, branch/PR metadata, review evidence, and readiness synchronized through the Symphony++ MCP server.
---

# Symphony++ Work Package

Use this skill only for an assigned Symphony++ WorkPackage or WorkKey. It is
the MCP-backed WorkPackage state adapter, not the generic worker contract. Pair
it with `symphony-plus-plus:symphony-worker`.

The MCP server is the permission boundary and the WorkPackage is the scope
boundary.

## Start

1. Bind through the configured private-store MCP bootstrap. Never ask for or
   paste the raw secret.
2. If given a claimable WorkKey, call `claim_work_key` through the bootstrap
   using `--work-key-secret-env <env-var> --claimed-by <stable-worker-id>`.
   Do not ask for, paste, print, or log the raw secret.
3. Call `get_current_assignment()` and treat that WorkPackage as authoritative.
4. Read `sympp://work-packages/{id}/acceptance.md` with the other MCP-backed
   package resources.
5. Read current context before coding: `read_context()`, `read_task_plan()`,
   acceptance/review/handoff resources, findings, and progress.
6. Do not create local `task_plan.md`, `findings.md`, or `progress.md` files as
   the source of truth.

## Work Loop

Keep S++ current as the work changes:

- `update_task_plan(patch, expected_version)`.
- `append_finding(finding, idempotency_key)`.
- `append_progress(event, idempotency_key)`.
- `report_blocker` / `resolve_blocker`.
- `add_comment(target_kind, target_id, body)`, `list_comments`, and
  `resolve_comment(comment_id, resolution_note?)` for scoped notes.
- `set_status` for allowed lifecycle transitions.
- `request_scope_expansion` when the assignment must grow.
- `create_guidance_request` when product, architecture, dependency, or
  slice-boundary ambiguity would otherwise force guessing.

Make guidance human-answerable: state the blocked decision, checked evidence,
package impact, candidate answers if known, and the smallest answer that
unblocks you. Treat architect escalation to `human_info_needed` as a blocker.

Stay inside the assigned WorkPackage. Do not inspect or mutate siblings unless
S++ explicitly gives scoped context.

## Branch, PR, Review

- `attach_branch(branch, head_sha)` once implementation branch exists.
- `attach_pr(url, head_sha)` after PR creation.
- `sync_pr(url_or_number, metadata)` only for the attached PR.
- `submit_review_package(summary, tests, artifacts, head_sha)` with current
  head SHA and required review verdicts.

Run the required Review Suite profile. If unavailable, use the package-approved
provider and record review progress. After material changes, rerun the same
required profile; do not step down.

## Ready

Before `mark_ready()`:

- Acceptance is satisfied or explicitly blocked.
- Required tests, static checks, review, and CI/check status are complete or
  accurately reported as absent/blocked.
- Task plan, findings, progress, branch, PR, and review evidence are current.
- No active blocker remains.

After `mark_ready()` succeeds, evidence is frozen except idempotent replay of
already-recorded writes.

## Safety

Worker grants are scoped to exactly one WorkPackage. Workers cannot mint keys,
approve scope, merge PRs, advance phase state, or use architect tools.
`state_key` preserves initialized MCP handshake continuity only.

Never print, store, commit, or paste raw grant secrets, bearer/API/GitHub/Linear
tokens, MCP auth tokens, WorkKeys, private handoff payloads, full
secret-bearing commands, or grant verifiers.

## References

- `references/worker_prompt.md`
- `references/mcp_wiring.md`
- `references/handoff.md`
