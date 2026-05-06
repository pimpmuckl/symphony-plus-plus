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
report_blocker(summary, idempotency_key, blocker_id?)
resolve_blocker(blocker_id, resolution, summary, idempotency_key)
request_scope_expansion(summary, idempotency_key, payload)
attach_branch(branch, head_sha)
attach_pr(url, head_sha)
sync_pr(url_or_number, metadata)
submit_review_package(summary, tests, artifacts, head_sha)
mark_ready()
```

`claim_work_key` intentionally requires both the one-time secret and a stable
`claimed_by` owner identity. Symphony++ uses that identity as part of the MCP
ownership contract. The call binds the session to an existing worker or
architect grant and does not mint new grants. Reconnects are accepted only when
the same secret proof is presented by the same `claimed_by` owner.

For stateless MCP transports, an explicit `state_key` is continuity metadata for
the initialized handshake only. It is not a bearer capability for a claimed
worker assignment. After reconnect initialize, workers must call
`claim_work_key(secret, claimed_by)` again to bind the worker session. The
state namespace follows the active ledger rather than a transient dynamic repo
process, so handshake continuity survives reconnects to the same SQLite ledger.
Explicit state-key handshakes use a bounded retention window longer than the
current worker grant defaults and are not evicted by the shorter implicit
default response-state TTL. They remain continuity metadata until overwritten,
cleared by a failed explicit reconnect initialize, or expired by the explicit
state-key retention window. A newer explicit initialize for the same state key
invalidates stale live sessions claimed before that initialize.
Duplicate initialize on the same active explicit-state connection is still
rejected as already initialized and does not clear the live session.
Implicit response-state continuity is for a single logical connection; a fresh
implicit `initialize` clears stored session state before any new worker claim.

`append_finding` idempotency is scoped to the work package, including at the
database uniqueness boundary, for retry stability across grant renewal. A retry
with the same idempotency key and same finding content replays the original
success; changed content or a changed
caller-supplied finding id returns `idempotency_conflict`.

JSON-RPC batch items are not an ordered session transaction. Each item is
evaluated against the batch's initial server/session state, so a `claim_work_key`
call inside one batch item does not authorize later items in that same batch.
Workers should claim in a prior request, or run dependent worker tools outside
the batch. A successful `claim_work_key` inside a batch still binds the returned
server/session for later standalone requests. After one claim succeeds in a
batch, later `claim_work_key` entries in that same batch are rejected as
rebinding attempts so a connection cannot claim multiple assignments.

`attach_branch` intentionally requires both the branch name and the current
branch `head_sha`. Branch-only review evidence is matched to that head so a
later branch update cannot reuse stale review-package evidence. When both
branch and PR metadata exist, the latest branch head is the worker-declared
current code head; PR metadata proves that the PR is attached for that same
head.

`submit_review_package` must include `head_sha` on every submission. Merge
readiness evidence can only bind to the current attached branch head. The latest
current-head review package is authoritative for review readiness; older
packages for the same head are superseded rather than implicitly merged. The
`tests` and `artifacts` lists are normalized by trimming entries before
persistence and default idempotency-key calculation. If an exact idempotent
retry matches an already recorded review package, Symphony++ replays that
success even after the current branch head has moved forward. The replay does
not make older-head evidence current for readiness.

After `mark_ready` succeeds, worker evidence is frozen. Evidence-mutating tools
such as progress, findings, blockers, branch/PR metadata, scope requests, and
review packages reject new writes for the ready package while preserving
idempotent replay behavior for already-recorded operations.

For non-merge-gated policies such as `quick_fix`, workers may satisfy focused
test and review-lane readiness with ordinary generic `append_progress` statuses:
`tests_passed` and `<review_lane>_green` such as `review_t1_green`. Tool-owned
metadata, blocker, status, and scope events do not satisfy those gates. These
non-merge policies may also count explicit-head `submit_review_package` evidence
without branch metadata when branch metadata is not a required gate. Merge-gated
packages still require current-head review package evidence and artifacts. If a
branch head is attached, generic fallback evidence and review-package evidence
must be current to the latest branch head. Generic fallback gates use the latest
relevant status after that branch head: later `tests_failed`,
`<review_lane>_red`, or `<review_lane>_failed` supersedes earlier green evidence
until a newer pass/green status is recorded.

For investigation policies that require a scope recommendation,
`request_scope_expansion` records the worker's recommendation evidence and
persists a canonical `recommendation.md` recommendation artifact for new
events. Stored legacy `request_scope_expansion` rows do not satisfy readiness
unless the canonical artifact already exists. It does not approve expanded scope. Caller-controlled
generic `append_progress` payloads are not recommendation evidence.

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

Architect tools require a live architect grant and the matching architect
capability; worker grants and insufficient architect grants are denied. Worker
grants cannot be minted with architect-only MCP capabilities, including
unprefixed P3/P7 capability strings such as `read:phase` or
`mint:child_worker_key`. `tools/list` advertises architect tools only when an
architect session is already bound and filters them to the live grant's
capabilities. Stale sessions expose only health and `claim_work_key` for
refresh, while worker and anonymous sessions keep the worker-facing discovery
surface. Architect sessions may call `get_current_assignment()` and read
`sympp://assignment/current` to recover their scoped `work_package_id` after
reconnect, but they still cannot use worker package read/write tools.
Lifecycle capabilities such as `architect:lifecycle.transition` do not imply
MCP architect tool capabilities; the explicit MCP capability strings listed in
the permission model are required.

Phase-dependent architect tools revalidate the grant's explicit phase scope plus
the anchor repo/base-branch scope frozen when the phase architect grant was
minted. Legacy null `phase_id` grants may still derive the current explicit
anchor phase for non-delegation phase reads, but scoped explicit phase-board
reads and P7 child delegation/status operations fail closed when the frozen
repo/base-branch snapshot is missing; migrations do not backfill that snapshot
from mutable anchor state. MCP, API, and browser phase-board readers filter
explicit phase architect grants to the frozen repo/base-branch boundary before
package cards are materialized.
`create_child_work_package(package)` creates only `phase_child` work inside the
architect phase anchor, inherits the anchor base branch, and rejects mismatched
phase, parent, repo, or base branch input. Child creation requires concrete
nonempty file globs; empty anchor globs may be used only when the child supplies
explicit nonempty, non-overbroad globs, while nonempty anchor globs remain the
upper bound. Child creation revalidates that anchor scope in the insert
transaction. Context-slice input is not part of the current contract.
`mint_child_worker_key` mints only single-package worker grants for same-phase
children, revalidates the live architect grant in the mint transaction, rejects
claimed active child-delegated worker grants for the same child,
transactionally supersedes unclaimed active child-delegated worker grants,
ignores unrelated normal worker grants, and caps child capabilities and expiry
to that current grant.
`read_child_status(work_package_id)` requires both `read:child_progress` and
`read:child_findings`; it can read the architect anchor package or a same-phase
child package. The remaining architect tools return explicit
`phase7_not_implemented` errors after authorization and must not approve ready
children, merge into a phase, or publish phase state.

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

## Skill package and MCP wiring

The repo-local skill package lives at:

```text
.codex/skills/symphony-work-package/SKILL.md
```

Install or copy that directory into the worker repository's `.codex/skills/`
directory when Symphony++ runs against a downstream codebase. The skill expects a
configured Symphony++ MCP stdio server. From this repository's Elixir
implementation, the MCP server command is:

```bash
cd elixir
mise exec -- mix sympp.mcp --mode stdio --database <ledger-path>
```

Codex MCP configuration should start that command from the `elixir/` directory
as a stdio MCP dependency. Do not embed raw work-key secrets or bearer tokens in
that configuration; workers claim assignments with
`claim_work_key(secret, claimed_by)` after MCP initialize. For stateless
transports, `state_key` is only handshake continuity and does not replace the
claim call.

## Hook role

Hooks may remind agents to keep state updated, inject assignment context, and
detect missing handoff, but hooks must not be treated as the permission
boundary. Optional examples live under
`implementation_docs_symphplusplus/templates/codex_hooks/`; they are
operator-controlled templates, not runtime defaults. Keep hook behavior
deterministic and non-secret-bearing, and do not parse private transcripts or
chain-of-thought for security decisions.
