# Execution Atlas Architect And MCP Workflow

Historical design context only. Execution Atlas was an earlier V3 brainstorm;
the active V3 contract is `../V3_PRODUCT_TREE_REWORK.md`.

Execution Atlas should be maintained primarily by the architect agent for work
that benefits from human-readable organization.

It should not become mandatory ceremony for every small task.

## When To Use An Atlas

Create or maintain an Execution Atlas when:

- A WorkRequest has multiple planned slices.
- A feature spans several product or engineering topics.
- Work has real dependencies.
- Work is recut, superseded, or preserved as an oracle.
- The human asks "what is going on?"
- A package escalates `human_info_needed`.
- The next safe action is not obvious.
- Several PRs are active against a feature branch.
- Some work is done while the overall capability remains partial.

Skip it for:

- Tiny direct-main bugfixes.
- Single bounded hotfix packages.
- Simple review-only tasks.
- Short solo sessions where the normal Solo Session ledger is enough.

## Architect Responsibilities

The architect agent owns the map as a human explanation layer.

Responsibilities:

- Create topics that match how the product is naturally understood.
- Keep topic depth shallow and scan-friendly.
- Add capability items with outcome-oriented titles.
- Link capability items to real WorkRequests, planned slices, WorkPackages,
  PRs, decisions, blockers, reviews, and lineage evidence.
- Record dependency edges only when they help actionability.
- Require a reason and decision reference for hard blocking edges.
- Mark deferrals explicitly with a reason and decision reference.
- Keep next moves short, ranked, and action-oriented.
- Reconcile the Atlas after dispatch, review, merge, recut, blocker, guidance,
  or major decision changes.
- Ask the human when product intent is missing.
- Avoid inventing completion.

The architect should not use Atlas curation to bypass lifecycle gates. The
Atlas explains the work; it does not grant authority to dispatch, merge, mint
grants, or answer human guidance.

## Local Operator Responsibilities

The local human/operator primarily consumes the Atlas.

Operator actions:

- Inspect the product map.
- Answer human guidance surfaced by attention items.
- Dispatch already-approved planned slices when the existing local operator
  flow allows it.
- Merge or decline merge-ready work through the normal human merge path.
- Ask the architect to reconcile the map when it looks stale or confusing.

The local operator cockpit should not become a full architect editing console
in V1.

## Suggested MCP Tools

The MCP surface should split read, proposal, and mutation operations.

### Read Tools

```text
list_execution_atlases(scope?)
read_execution_atlas(execution_atlas_id | work_request_id)
read_execution_atlas_projection(execution_atlas_id | work_request_id)
```

`read_execution_atlas` returns persisted curation.

`read_execution_atlas_projection` returns curation plus derived operational
state, completion marks, attention, staleness, dependency satisfaction, and
safe next moves.

### Proposal Tools

Proposal tools should not mutate state.

```text
suggest_execution_atlas(work_request_id)
suggest_execution_atlas_reconciliation(execution_atlas_id)
suggest_execution_atlas_next_moves(execution_atlas_id)
```

Use proposal tools when:

- The WorkRequest is newly clarified.
- The map is stale.
- The current next moves no longer match live package state.
- The architect wants a safe draft before applying curation.

### Mutation Tools

Mutation tools should be idempotent and scoped.

```text
create_execution_atlas(scope, title, summary?, idempotency_key)
upsert_execution_atlas_topics(execution_atlas_id, topics, reason, idempotency_key)
upsert_execution_atlas_items(execution_atlas_id, capability_items, reason, idempotency_key)
link_execution_atlas_item(execution_atlas_id, item_id, link_ref, role, reason, idempotency_key)
unlink_execution_atlas_item(execution_atlas_id, item_id, link_ref, reason, decision_ref?, idempotency_key)
record_execution_atlas_dependency(execution_atlas_id, source_ref, target_ref, kind, reason, decision_ref, idempotency_key)
mark_execution_atlas_item_deferred(execution_atlas_id, item_id, reason, decision_ref, idempotency_key)
set_execution_atlas_next_moves(execution_atlas_id, next_moves, reason, idempotency_key)
reconcile_execution_atlas(execution_atlas_id, mode, reason, idempotency_key)
```

Mutation responses should return only:

```text
execution_atlas_id
revision_number
changed ids
safe summary
redacted projection summary when useful
```

They should not return raw secret material or unrelated ledger detail.

## Tool Boundaries

Execution Atlas tools must not:

- Dispatch planned slices.
- Create WorkPackages.
- Mint worker or architect grants.
- Retrieve secrets.
- Spawn Codex agents.
- Change raw WorkRequest status.
- Mark WorkPackages merged.
- Answer guidance requests.
- Modify Linear state.

Those actions already belong to existing WorkRequest, dispatch, guidance,
package, and merge flows.

## Scoped Access

Atlas tools should follow the existing S++ scoping model:

- Architect sessions can read and mutate Atlas records only inside their frozen
  repo/base/phase/WorkRequest scope.
- Local operator mode can inspect local Atlas projections and eventually create
  or request Atlas maintenance.
- Worker sessions should generally not mutate Atlas maps. Workers can create
  guidance or progress that the architect later reconciles into the Atlas.
- Unbound/generic sessions may read only safe local operator summaries if the
  broader local product rules allow that; they should not mutate maps without
  an operator/architect path.

## Reconciliation Flow

Reconciliation is the bridge between live ledger truth and curated product
meaning.

Recommended flow:

1. Projection detects linked changes since the last reconcile marker.
2. Dashboard shows `map_stale` attention.
3. Architect reads `read_execution_atlas_projection`.
4. Architect calls `suggest_execution_atlas_reconciliation`.
5. Architect applies a small patch through mutation tools.
6. Backend records a revision with reason and updated cursor.
7. Dashboard clears stale attention or narrows it to unresolved issues.

Examples of changes that should trigger stale attention:

```text
planned slice dispatched
package moved into review
PR merged
blocker opened or resolved
guidance escalated to human_info_needed
lineage recorded
package abandoned
successor package created after recut
review evidence changed
```

## Architect Prompting Guidance

When an architect creates or reconciles an Atlas, it should write like a product
operator, not like a database admin.

Good item titles:

```text
Scheduler target selection and locks
Provider adapter trait surface
Repository split: idempotency and outbox
Human-readable Execution Atlas tree
Dependency-safe next moves
```

Weak item titles:

```text
PR 12
WorkPackage wp_abc
Implement files
Backend changes
Fix stuff
```

Good next moves:

```text
Answer outbox cursor product guidance.
Merge repository split 2B after review evidence is attached.
Dispatch scheduler target-selection slice.
Reconcile original oracle package after successor merge.
```

Weak next moves:

```text
Continue.
Do next task.
Check status.
Need review.
```

## Skill Updates

The `symphony-architect` skill should eventually tell architects:

- Use Execution Atlas for multi-slice or multi-topic WorkRequests.
- Create a map after initial clarification and before dispatching many slices.
- Keep map updates short and evidence-linked.
- Reconcile after dispatch, recut, blocker escalation, review, or merge.
- Do not mark capabilities done without linked evidence or explicit decision.
- Use structured human guidance when attention requires product input.
- Keep Atlas curation out of worker prompts unless it materially helps the
  worker understand their slice boundary.

The `symphony-work-package` skill should eventually tell workers:

- Do not mutate Execution Atlas directly in normal worker mode.
- Record progress, findings, blockers, review evidence, and guidance normally.
- If work reveals a map inconsistency, ask the architect for guidance.

## Review And Validation Expectations

Atlas PRs should be reviewed like state-projection work:

- Can the projection lie?
- Can stale curation hide real blockers?
- Can hidden scoped records leak?
- Can raw lifecycle state be confused with completion marks?
- Are deferrals and dependencies backed by decisions?
- Are token-like freeform fields redacted before persistence?
- Are map mutations idempotent?

Avoid process bloat: do not require separate reviewer packages unless the Atlas
change touches security, permissions, merge readiness, or high-risk projection
logic.
