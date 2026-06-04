# Execution Atlas Data Model And Projection

Historical design context only. Execution Atlas was an earlier V3 brainstorm;
the active V3 contract is `../V3_PRODUCT_TREE_REWORK.md`.

Execution Atlas should be a small persisted semantic map plus a backend-derived
projection over the existing Symphony++ ledger.

The persistence model should stay boring. The projection should do the hard
truth-reconciliation work.

## Persistence Strategy

V1 should store Atlas curation as validated JSON with revisions.

Recommended tables:

```text
execution_atlases
execution_atlas_revisions
```

The backend contract inside the JSON document should be named
`progress_map.v1`. That keeps the product name pleasant while giving the code a
stable contract label.

### execution_atlases

```text
id
schema_version
scope_kind
repo
base_branch
work_request_id nullable
phase_id nullable
title
summary
map_json
based_on_ledger_cursor nullable
created_by
created_at
updated_by
updated_at
```

### execution_atlas_revisions

```text
id
execution_atlas_id
revision_number
map_json
reason
decision_ref_json nullable
created_by
created_at
```

The revision table matters because Atlas curation expresses product meaning.
Local-first does not mean unaudited.

## What To Persist

Persist semantic curation that cannot be safely inferred:

```text
atlas scope
atlas title and summary
topic ids, titles, descriptions, and ordering
capability item ids, titles, descriptions, and ordering
typed links to ledger records
explicit dependency edges
explicit deferrals
architect-written next moves
last reconciled cursor or timestamp
updated_by and updated_at
revision reason
decision refs for meaningful structure changes
```

Do not persist transient UI state:

```text
expanded or collapsed tree nodes
search text
hover state
selected topic
temporary filters
graph canvas coordinates
browser-local pins
```

Persist topic ordering because ordering is part of the human-readable map.
Avoid persisting graph coordinates in V1.

## What To Derive

Derive operational truth at read time:

```text
item computed completion mark
topic rollup mark
active blocker count
human guidance needed
PR, review, and readiness summary
map staleness
safe_to_do flags
dependency satisfaction
lineage projection
cleanup attention
contradictions
hidden or out-of-scope link warnings
```

The frontend should not decide whether an item is blocked, stale, safe, merged,
or contradictory. The frontend should render the backend projection.

## progress_map.v1 Payload

Recommended persisted JSON:

```json
{
  "schema_version": "progress_map.v1",
  "id": "pm_wr_123",
  "title": "Creator Data Service Execution Atlas",
  "summary": "Human-readable product map for the creator-data feature branch.",
  "scope": {
    "kind": "work_request",
    "repo": "nextide-saas-creator-data",
    "base_branch": "feature/creator-data",
    "work_request_id": "WR-CREATOR-DATA-ARCH-001",
    "phase_id": "phase_WR-CREATOR-DATA-ARCH-001"
  },
  "topics": [
    {
      "id": "topic_core_platform",
      "title": "Core Platform",
      "description": "Workspace, service shell, database substrate, and runtime health.",
      "kind": "engineering",
      "sort_order": 10
    }
  ],
  "capability_items": [
    {
      "id": "item_rust_workspace",
      "topic_id": "topic_core_platform",
      "title": "Rust workspace and health scaffold",
      "description": "Minimal workspace, Compose path, and health/readiness surface.",
      "completion_mark": "done",
      "completion_basis": "derived",
      "sort_order": 10,
      "links": [
        {
          "type": "work_package",
          "id": "wp_workspace_scaffold",
          "role": "execution_package"
        },
        {
          "type": "pull_request",
          "id": "https://github.com/example/repo/pull/1",
          "role": "merge_evidence"
        }
      ]
    }
  ],
  "dependency_edges": [
    {
      "id": "edge_db_before_repositories",
      "source": {
        "type": "capability_item",
        "id": "item_repository_split"
      },
      "target": {
        "type": "capability_item",
        "id": "item_db_core"
      },
      "kind": "depends_on",
      "reason": "Repository split work needs the DB core pool and transaction substrate first.",
      "decision_ref": {
        "type": "decision",
        "id": "decision_db_core_first"
      }
    }
  ],
  "next_moves": [
    {
      "id": "next_repository_split_2b",
      "title": "Merge repository split 2B.",
      "description": "This is ready after review and unblocks later migration work.",
      "owner_kind": "operator",
      "action_kind": "merge",
      "priority": 10,
      "target_ref": {
        "type": "work_package",
        "id": "wp_repository_split_2b"
      }
    }
  ],
  "updated_by": "creator-data-architect",
  "updated_at": "2026-05-22T00:00:00Z"
}
```

## Projection Payload

The projection endpoint should return persisted curation plus derived truth.

Recommended shape:

```json
{
  "execution_atlas": {
    "id": "pm_wr_123",
    "schema_version": "progress_map.v1",
    "title": "Creator Data Service Execution Atlas",
    "scope": {
      "kind": "work_request",
      "repo": "nextide-saas-creator-data",
      "base_branch": "feature/creator-data",
      "work_request_id": "WR-CREATOR-DATA-ARCH-001"
    }
  },
  "projection": {
    "available": true,
    "stale": false,
    "staleness": {
      "is_stale": false,
      "linked_changes_since_reconcile": 0,
      "reason": null
    },
    "topics": [
      {
        "id": "topic_core_platform",
        "title": "Core Platform",
        "completion_mark": "partial",
        "operational_state": {
          "key": "active",
          "label": "Active",
          "tone": "info",
          "reason": "One linked package is implementing."
        },
        "counts": {
          "done": 2,
          "partial": 1,
          "not_done": 2,
          "deferred": 0,
          "unknown": 0,
          "attention": 1
        }
      }
    ],
    "capability_items": [
      {
        "id": "item_repository_split",
        "topic_id": "topic_core_platform",
        "title": "Repository split: idempotency and outbox",
        "completion_mark": "partial",
        "computed_mark": "partial",
        "mark_reason": "One linked package is merged and one successor package is reviewing.",
        "raw_lifecycle_refs": [
          {
            "type": "planned_slice",
            "id": "ps_repository_split",
            "status": "dispatched"
          },
          {
            "type": "work_package",
            "id": "wp_repository_split_2a",
            "status": "merged"
          },
          {
            "type": "work_package",
            "id": "wp_repository_split_2b",
            "status": "reviewing"
          }
        ],
        "operational_state": {
          "key": "reviewing",
          "label": "Reviewing",
          "tone": "review",
          "reason": "A linked successor package is in review."
        },
        "attention_items": []
      }
    ],
    "attention_items": [
      {
        "key": "human_guidance_needed",
        "label": "Human guidance needed",
        "severity": "high",
        "target_ref": {
          "type": "guidance_request",
          "id": "gr_outbox_cursor_safety"
        }
      }
    ],
    "next_moves": [
      {
        "id": "next_repository_split_2b",
        "title": "Merge repository split 2B.",
        "safe_to_do": true,
        "why": "The linked package is merge-ready, required review evidence is present, and dependencies are satisfied."
      }
    ]
  }
}
```

## Completion Mark Rules

Use conservative derived rules.

```text
deferred
  Explicitly marked deferred with a reason and decision reference.

done
  All required linked delivery work is terminal-successful, or an explicit
  human/architect decision marks the capability complete with evidence.

partial
  Some linked work is active, merged, reviewing, or provides usable substrate,
  but the capability is not complete for the Atlas scope.

not_done
  Desired or planned, but no material linked delivery evidence exists.

unknown
  Links are missing, hidden, unavailable, contradictory, or too stale for the
  backend to make a safe call.
```

Attention items overlay marks. A completed item may still have cleanup
attention.

## Staleness Model

Atlas maps should not silently become beautiful lies.

Persist a reconciliation marker:

```text
based_on_ledger_cursor
based_on_event_cursor
last_reconciled_at
last_reconciled_by
```

The projection should compare linked records against that marker. If linked
state changed since the last reconciliation, return staleness attention.

Examples:

```text
linked WorkPackage status changed
linked planned slice dispatched
linked PR merged
linked guidance escalated to human_info_needed
linked package was abandoned
operational lineage was recorded
dependency target changed
review evidence changed
```

Staleness is not failure. Hidden staleness is failure.

## Scoping And Redaction

Atlas projection must obey the same visibility principles as the dashboard and
MCP surfaces:

- Do not serialize links to hidden out-of-scope packages as if visible.
- Do not leak sibling WorkRequests from frozen grant scopes.
- Do not include raw work keys, grant secrets, secret hashes, private handoff
  payloads, API tokens, or secret-bearing commands.
- Redact token-like text in freeform reason and notes fields before persistence.
- If lineage or linked state cannot be read, return explicit unavailable
  attention instead of pretending the relationship does not exist.

## Dependency Evaluation

Dependency edges should be explicit and typed.

Hard blockers:

```text
depends_on
blocks
```

Informational edges:

```text
related
validates
enables
```

Hard blocking edges should require:

```text
reason
decision_ref
```

Projection should compute:

```text
dependency_satisfied
dependency_blocked
dependency_unknown
cycle_detected
started_before_dependency_done
```

The UI should render uncertain relationships differently from blockers.

## Backend Modules

Names are suggested, not mandatory:

```text
SymphonyPlusPlus.ExecutionAtlas
SymphonyPlusPlus.ExecutionAtlas.Repository
SymphonyPlusPlus.ExecutionAtlas.Projection
SymphonyPlusPlus.ExecutionAtlas.Schema
SymphonyPlusPlus.ExecutionAtlas.Redaction
```

The projection module should consume existing repositories and services rather
than duplicating lifecycle logic.

## Validation Targets

Focused tests should prove:

- Atlas JSON is schema-validated.
- Revisions are recorded on updates.
- Token-like freeform text is redacted.
- Raw lifecycle status remains unchanged by Atlas updates.
- Derived completion marks differ from raw status when appropriate.
- Active blockers and human guidance become attention.
- Out-of-scope links do not leak hidden records.
- Unavailable lineage produces explicit attention.
- Dependency cycles are reported.
- Stale maps are reported after linked ledger changes.
