---
name: symphony-work-package
description: Use when assigned a Symphony++ WorkPackage; claims the ledger-backed local assignment by WorkPackage id and keeps scoped planning, progress, branch/PR metadata, review evidence, and readiness synchronized through the Symphony++ MCP server.
---

# Symphony++ Work Package

Use this skill for an assigned Symphony++ WorkPackage. It is the MCP-backed
WorkPackage state adapter, not the generic worker contract. Pair it with
`symphony-plus-plus-mcp:symphony-worker`.

The MCP server is the permission boundary and the WorkPackage is the worker
scope boundary. V3 product progress lives on the WorkRequest/product tree;
this skill handles only the dispatched execution/audit record.

## Start

1. Use a dedicated S++ MCP-enabled session connected to the same ledger as
   dispatch.
   Sessions may show worker WorkPackage tool schemas before claim; schema
   visibility is not authority, so claim first.
2. Claim the package with `claim_local_assignment` using the WorkPackage id:
   `{"work_package_id":"<WP id>"}`. Include `claimed_by` only when the
   dispatch payload or operator provided a stable worker identity.
3. Replay the same local claim after reconnects. The server heartbeats the
   current lease, reclaims stale leases with audit evidence, and rejects paused
   leases or another active owner.
   Stop and report those blockers instead of minting your own replacement.
4. Call `get_current_assignment()` and treat that WorkPackage as authoritative.
5. Read `sympp://work-packages/{id}/acceptance.md` with the other MCP-backed
   package resources.
6. Read current context before coding: `read_context()`, `read_task_plan()`,
   acceptance/review/handoff resources, findings, and progress.
7. Do not create local `task_plan.md`, `findings.md`, or `progress.md` files as
   the source of truth.

## Context Format

S++ MCP resources may include compact TOON text alongside Markdown or JSON for
agent-readable context. Use TOON only as presentation; MCP tool arguments remain
JSON/schema-native, and tool `structuredContent` remains the canonical
machine-readable response.

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

Human-facing bodies, comments, blocker notes, findings, progress details, and
guidance context are Markdown. Keep titles, ids, statuses, branch names, and
other compact labels plain.

Make guidance human-answerable: state the blocked decision, checked evidence,
package impact, candidate answers if known, and the smallest answer that
unblocks you. Treat architect escalation to `human_info_needed` as a blocker.

Stay inside the assigned WorkPackage. Do not inspect or mutate siblings unless
S++ explicitly gives scoped context.

## Branch, PR, Review

- `attach_branch(branch, head_sha)` once implementation branch exists.
- `attach_pr(url, head_sha)` after PR creation.
- `sync_pr(url_or_number, metadata)` only for the attached PR.
- `submit_review_package(summary, tests, artifacts)` after branch metadata is
  current; include required review verdicts when Review Suite evidence will not
  supply them.
- `attach_review_suite_result` for passing Review Suite evidence; current
  results can satisfy the matching review proof.

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

Worker grants and local claim leases are scoped to exactly one WorkPackage.
Workers cannot mint keys, approve scope, merge PRs, advance phase state, or use
architect tools. `state_key` preserves initialized MCP handshake continuity
only; the ledger-backed claim is the worker authority.

Never print, store, commit, or paste raw grant secrets, worker secrets,
private handoff payloads, bearer/API/GitHub/Linear tokens, MCP auth tokens,
secret-bearing commands, grant verifiers, or claim lease internals.

## References

- `references/worker_prompt.md`
- `references/mcp_wiring.md`
- `references/handoff.md`
