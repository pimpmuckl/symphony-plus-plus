# Execution Atlas Roadmap

Historical design context only. Execution Atlas was an earlier V3 brainstorm;
the active V3 contract is `../V3_PRODUCT_TREE_REWORK.md`.

Execution Atlas should be built in small PR-sized slices. The V1 target is a
useful nested progress view, not a complete graph product.

## Roadmap Summary

```text
PR 1: Persist progress_map.v1 JSON and revisions
PR 2: Project Atlas + ledger truth into completion, attention, and next moves
PR 3: Render the nested Atlas tree in the local cockpit
PR 4: Add architect MCP tools for Atlas maintenance
PR 5: Add dependency-safe next moves and Markdown export
```

## PR 1: progress_map.v1 Persistence

Goal:

Add the canonical persisted Atlas document and revision history.

Deliverables:

```text
execution_atlases table
execution_atlas_revisions table
ExecutionAtlas context/service module
progress_map.v1 validation
scope validation
typed link validation
freeform text redaction
basic create/read/update tests
```

Acceptance:

- A WorkRequest-scoped Atlas can be created.
- Topics, capability items, dependency edges, and next moves persist as
  validated JSON.
- Updates record revisions.
- Token-like text in notes, reasons, and deferral fields is redacted before
  persistence.
- Raw WorkRequest, planned-slice, and WorkPackage lifecycle state is not
  changed by Atlas writes.

Recommended owned files:

```text
elixir/lib/symphony_elixir/symphony_plus_plus/execution_atlas/**
elixir/priv/symphony_plus_plus/repo/migrations/*execution_atlas*.exs
elixir/test/symphony_elixir/symphony_plus_plus/execution_atlas*_test.exs
implementation_docs_symphplusplus/docs/execution_atlas/**
```

Stop conditions:

- The implementation wants to normalize a large enterprise hierarchy before the
  JSON contract is proven.
- The implementation needs to read host files to validate links.
- Any path would store raw secrets or private handoff payloads.

## PR 2: Backend Projection

Goal:

Combine persisted Atlas curation with live ledger truth.

Deliverables:

```text
ExecutionAtlas.Projection module
completion mark derivation
topic rollups
attention aggregation
staleness detection
lineage inclusion
dependency satisfaction basics
dashboard API projection endpoint
tests around raw status vs completion mark separation
```

Acceptance:

- Projection preserves raw lifecycle status separately from `completion_mark`.
- Linked merged packages can make a capability done or partial based on Atlas
  context.
- Active blockers produce attention.
- `human_info_needed` guidance produces attention.
- Planned slices linked to merged packages project as done/merged while raw
  slice status remains unchanged.
- Unavailable lineage produces explicit attention.
- Out-of-scope links do not leak hidden package state.
- Stale map state is visible when linked ledger state changed after reconcile.

Stop conditions:

- The projection starts duplicating WorkPackage or WorkRequest lifecycle logic
  instead of consuming existing services.
- The UI is asked to infer safety or blockers itself.

## PR 3: Local Cockpit Atlas Tree

Goal:

Make the human-facing nested view real.

Deliverables:

```text
Execution Atlas tab or primary view in local operator cockpit
nested topic/capability tree
completion marks [x], [~], [ ], [>], [?]
topic rollup counts
attention rail
next moves rail
links to WorkRequest and WorkPackage detail
empty state for WorkRequests without an Atlas
```

Acceptance:

- A human can understand a multi-slice WorkRequest without reading raw package
  rows.
- The view remains usable on narrow screens.
- Attention is visible without replacing completion marks.
- Raw lifecycle evidence is reachable from rows.
- No secret or private handoff material is rendered.

Stop conditions:

- The implementation becomes a graph canvas before the tree view is solid.
- The frontend infers operational truth that should come from the backend.

## PR 4: Architect MCP Tools

Goal:

Let architect agents create and maintain Atlas maps.

Deliverables:

```text
list_execution_atlases
read_execution_atlas
read_execution_atlas_projection
create_execution_atlas
upsert_execution_atlas_topics
upsert_execution_atlas_items
link_execution_atlas_item
record_execution_atlas_dependency
mark_execution_atlas_item_deferred
set_execution_atlas_next_moves
reconcile_execution_atlas
architect skill updates
```

Acceptance:

- Architect sessions can mutate Atlas records only inside their frozen scope.
- Mutations are idempotent.
- Hard dependency edges require reason and decision reference.
- Deferrals require reason and decision reference.
- Responses are redacted and small.
- Atlas tools cannot dispatch slices, mint grants, answer guidance, or mark
  packages merged.

Stop conditions:

- Tool design overlaps with existing dispatch, guidance, or merge authority.
- The tool response wants to include raw secret or handoff material.

## PR 5: Dependency-Safe Next Moves And Markdown Export

Goal:

Make the Atlas actionable and exportable.

Deliverables:

```text
dependency satisfaction projection
safe_to_do explanations
blocked-by and unblocks view
dependency cycle attention
Markdown export endpoint
stale/reconcile banner
tests for dependency safety and export shape
```

Acceptance:

- Next moves explain why they are safe or blocked.
- Blocking dependency edges require decision linkage.
- Dependency cycles are surfaced as attention.
- Exported Markdown resembles the nested progress file style.
- The exported Markdown is not treated as canonical state.

Stop conditions:

- The implementation treats every relationship as a hard blocker.
- The export path becomes the source of truth.

## Later V3 Work

After the V1 Atlas is useful:

```text
visual dependency graph
topic merge/split controls
drag-and-drop topic ordering
repo/base stream-level Atlas rollups
Atlas templates for common work types
automatic draft Atlas suggestion after clarification
operator comments on Atlas items
Atlas snapshots for release notes
cross-WorkRequest portfolio view
```

These should wait until the nested tree and backend projection prove valuable.

## Anti-Patterns

### Enterprise Workflow Gravity

Avoid names and shapes that pull S++ toward enterprise project-management
software:

```text
epic
initiative
portfolio
program
sprint
RACI
quarterly objective
```

Use local-first names:

```text
atlas
topic
capability item
dependency edge
attention item
next move
completion mark
```

### UI-Only Truth

Do not let React decide whether something is blocked, stale, safe, or merged.
The backend projection must do that.

### Raw Status Confusion

Do not call Atlas progress `status`.

Use:

```text
raw_status
operational_state
completion_mark
attention_items
safe_to_do
```

### Stale Pretty Maps

A stale Atlas should be visible and actionable.

Bad:

```text
The map looks confident after linked work changed.
```

Good:

```text
Map stale: 3 linked changes since last architect reconcile.
```

### Duplicated Lineage

Do not create a separate recut/oracle truth inside Atlas.

Use existing operational lineage and link/project it.

### Review Process Bloat

Do not create reviewer packages just because an Atlas item exists. Workers keep
normal review-suite responsibility. Dedicated reviewer packages remain for
high-risk business logic, security, smoke-test ownership, or cross-package
release verification.

### Mandatory Ceremony For Tiny Work

Execution Atlas is a power tool for multi-slice product work. It should not make
small hotfixes annoying.

## First Dogfood Candidate

The first real dogfood should be an existing multi-slice feature branch where
the human already wants better visibility.

Good candidate traits:

- Several planned slices.
- Several WorkPackages and PRs.
- At least one dependency.
- At least one partial capability.
- At least one stale or confusing raw status.
- A human operator actively watching the cockpit.

The creator-data service lane is a strong candidate once the V1 persistence and
projection exist.
