# Execution Atlas Product Shape

Historical design context only. Execution Atlas was an earlier V3 brainstorm;
the active V3 contract is `../V3_PRODUCT_TREE_REWORK.md`.

## Product Framing

Execution Atlas is the human-readable product map for Symphony++.

It answers a different question from the existing lifecycle board:

```text
Lifecycle board:
  Which raw WorkPackages are created, claimed, implementing, reviewing,
  merge-ready, merged, blocked, or abandoned?

Execution Atlas:
  What does all of this work mean for the product, what is done, what is
  partial, what is missing, what is deferred, what needs attention, and what
  should happen next?
```

The Atlas should feel like a living `implementation_progress.md` generated from
real ledger state and architect curation. It should be easy to scan, pleasant
to inspect, and traceable when the human wants detail.

## Core Mental Model

```text
ExecutionAtlas
|-- Topics
|   |-- CapabilityItems
|   |   |-- Links to WorkRequests, planned slices, WorkPackages, PRs,
|   |   |   decisions, blockers, guidance, reviews, and lineage evidence
|   |   `-- Derived operational truth
|   |
|   `-- DependencyEdges
|
|-- AttentionItems
`-- NextMoves
```

The Atlas is intentionally product-shaped, not ticket-shaped.

Topics are the human categories that make the work make sense. Capability
items are the concrete outcomes that make progress visible. Links connect those
items back to the existing Symphony++ ledger. Dependency edges explain order and
blocking relationships. Attention items highlight what needs action. Next moves
tell the human what is safe or blocked now.

## Layers Of Truth

### Raw Ledger State

Raw ledger state remains the source of truth for control and audit.

Examples:

- WorkRequest status.
- Planned-slice status.
- WorkPackage status.
- AccessGrant scope and lifecycle.
- Secret handoff metadata.
- PR, review, and readiness evidence.
- Guidance requests and blockers.
- Operational lineage events.

The Atlas must never mutate raw lifecycle state by implication.

### Operational Projection

Operational projection is backend-derived delivery truth.

Examples:

- A WorkPackage is raw `ready_for_worker`, but has old implementation events.
  The operational projection can call it `Started / Paused` or `Needs
  Attention`.
- A planned slice is raw `dispatched`, but its linked package is merged. The
  slice operational projection can say `Merged`.
- A package has a merged PR but raw status is still merge-ready. The projection
  can surface cleanup attention.
- A guidance request is `human_info_needed`. The projection can mark the linked
  area as blocked by human input.

The backend owns this reasoning. The UI renders it.

### Execution Atlas Curation

Atlas curation is the human-readable semantic layer.

Examples:

- Topic names and ordering.
- Capability item titles and descriptions.
- Which slices/packages provide evidence for a capability.
- Explicit deferrals.
- Hard dependency edges.
- Next-move wording.
- Architect-authored summaries.

This layer should be persisted because it expresses product meaning that cannot
be safely inferred from raw rows.

## Core Entities

### ExecutionAtlas

An Execution Atlas is scoped to one meaningful work surface.

Initial supported scopes should be:

```text
WorkRequest
WorkRequest + phase
repo + base_branch + phase
```

The recommended V1 default is one Atlas per multi-slice WorkRequest or
architect-led phase.

Fields:

```text
id
schema_version
title
summary
scope
topics
capability_items
dependency_edges
next_moves
updated_by
updated_at
based_on_ledger_cursor
```

### Topic

A topic is a human-meaningful grouping. It is not a lifecycle state.

Examples:

```text
Backend
Dashboard UX
MCP and plugin experience
Scheduler
Provider adapters
Reports
Product: Creator Safety Score
Operational safety
```

Fields:

```text
id
title
description
kind
sort_order
parent_topic_id
```

V1 should allow at most two topic levels. The best human progress views stay
shallow.

### CapabilityItem

A capability item is a product or engineering outcome under a topic.

Examples:

```text
Execution Atlas backend projection endpoint
Human-readable nested tree view
Architect MCP map maintenance tools
Dependency-safe next moves
Markdown export
```

Fields:

```text
id
topic_id
title
description
completion_mark
completion_basis
sort_order
links
notes
deferred_reason
```

Capability items can be backed by zero, one, or many ledger links. A product
item might require several packages. A deferred item might have no package yet.
A merged package might still leave the capability partial.

### LinkRef

A link ref connects Atlas curation to ledger or external evidence.

Supported link types:

```text
work_request
planned_slice
work_package
pull_request
review_evidence
readiness_evidence
guidance_request
blocker
decision
progress_event
operational_lineage
solo_session
external_doc
```

Roles should be flexible:

```text
intent_anchor
implementation_slice
execution_package
evidence
decision_basis
blocker
successor
oracle
export
```

Example:

```json
{
  "type": "planned_slice",
  "id": "ps_123",
  "role": "implementation_slice"
}
```

### DependencyEdge

A dependency edge records an explicit relationship.

Recommended edge kinds:

```text
depends_on
blocks
enables
validates
replaces
supersedes
recut_from
related
```

Hard blocking edges should require a reason and decision reference. This avoids
turning vague relatedness into fake blockers.

Fields:

```text
id
source_ref
target_ref
kind
reason
decision_ref
created_by
created_at
```

Operational lineage remains authoritative for recut, superseded, and oracle
relationships. Atlas edges may link to or project lineage, but should not fork
lineage truth.

### AttentionItem

An attention item is a human-facing issue or action need.

Most attention should be derived at read time.

Examples:

```text
human_guidance_needed
active_blocker
map_stale
dependency_blocked
dependency_cycle
linked_package_merged_but_raw_open
ready_for_worker_with_activity
lineage_unavailable
oracle_still_presented_as_delivery
review_evidence_missing
```

Attention overlays completion marks. It does not necessarily change them.

Example:

```text
[x] Initial workspace scaffold  [!] cleanup: raw package still merge-ready
```

### NextMove

A next move is a concise recommended action.

Fields:

```text
id
title
description
target_ref
owner_kind
action_kind
priority
safe_to_do
why_safe_or_blocked
links
```

Owner kinds:

```text
human
architect
worker
operator
system
```

Action kinds:

```text
ask_human
dispatch_slice
implement
review
merge
replan
defer
inspect
reconcile
archive
```

The wording can be persisted. Whether it is currently safe should be derived.

## Human-Facing Completion Marks

Do not call this field `status`. That word belongs to raw lifecycle records.

Use `completion_mark`:

```text
[x] done
[~] partial
[ ] not_done
[>] deferred
[?] unknown
```

Definitions:

- `done`: complete enough for the Atlas scope, backed by linked evidence or an
  explicit decision.
- `partial`: usable substrate exists, implementation has started, some linked
  work is done, or the capability is real but incomplete.
- `not_done`: planned or desired, but not materially delivered.
- `deferred`: intentionally postponed by an explicit decision.
- `unknown`: the backend cannot safely determine progress because links,
  evidence, or scoped state are missing or contradictory.

## Example Atlas

```text
Symphony++ V3 Execution Atlas
|-- Product Map Core
|   |-- [x] WorkRequest-led product intent
|   |-- [x] Planned-slice dispatch linkage
|   |-- [~] WorkRequest operational projection
|   |-- [ ] Execution Atlas persistence
|   `-- [ ] Execution Atlas projection endpoint
|
|-- Human Cockpit
|   |-- [x] Local operator dashboard
|   |-- [~] WorkRequest detail page
|   |-- [ ] Execution Atlas nested progress tree
|   |-- [ ] Attention center
|   `-- [>] Dependency canvas editor
|
|-- Agent Workflow
|   |-- [x] Architect handoff
|   |-- [x] Worker private handoff
|   |-- [~] Guidance escalation to human
|   |-- [ ] Architect MCP map maintenance tools
|   `-- [ ] Reconcile stale map flow
|
`-- Next Moves
    |-- [1] Add progress_map.v1 persistence
    |-- [2] Add backend projection with attention rollups
    |-- [3] Render Atlas tree in local cockpit
    `-- [4] Add architect MCP map tools
```

This is the target reading experience: a human should know where the project
stands before opening any package detail page.
