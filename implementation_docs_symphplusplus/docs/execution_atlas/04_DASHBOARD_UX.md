# Execution Atlas Dashboard UX

The Execution Atlas dashboard should be the default human cockpit for
architect-led feature work.

The raw board remains available for audit and operations. The Atlas answers the
human question first.

## Primary Human Question

The dashboard should optimize for:

```text
What is really happening, what needs attention, and what is safe to do next?
```

The first viewport should make progress understandable without opening agent
transcripts or scanning lifecycle tables.

## Main View: Nested Progress Tree

The nested progress tree is the heart of Execution Atlas.

Example:

```text
Creator Data Service
|-- Core Platform                                  [2 done, 1 partial, 1 todo]
|   |-- [x] Rust workspace and health scaffold
|   |-- [x] Database pool and transaction substrate
|   |-- [~] Repository split: idempotency and outbox
|   |   `-- Reviewing: successor package in T2 review
|   `-- [ ] Production CI and deploy shape
|
|-- Scheduler                                      [1 partial, 2 todo]
|   |-- [~] Target selection contract
|   |-- [ ] Locking and backoff model
|   `-- [ ] Provider gating
|
|-- Provider Adapters                              [1 partial, 2 blocked]
|   |-- [~] Adapter trait surface
|   |-- [!] Real provider fixture gating
|   `-- [!] Credential strategy decision
|
`-- Reports And Exports                            [1 deferred]
    |-- [>] PDF export
    `-- Deferred until report JSON stabilizes
```

Marks:

```text
[x] done
[~] partial
[ ] not done
[>] deferred
[?] unknown
[!] needs attention
```

`[!]` is an overlay, not a replacement for the completion mark. A row can be
done and still have cleanup attention.

## Suggested Layout

```text
+------------------------------------------------------+---------------------+
| Execution Atlas                                      | Attention           |
| Creator Data Service                                 |                     |
|                                                      | 2 human inputs      |
| Core Platform                                        | 1 stale map section |
| |-- [x] Rust workspace                               | 1 recut cleanup     |
| |-- [~] Repository split                             |                     |
|                                                      | Next Moves          |
| Scheduler                                            |                     |
| |-- [~] Target selection                             | 1. Answer guidance  |
| |-- [ ] Locking and backoff                          | 2. Merge split 2B   |
|                                                      | 3. Dispatch slice   |
+------------------------------------------------------+---------------------+
```

The left side is the product map. The right side is operator actionability.

## Topic Cards Or Bands

Each topic should show compact rollups:

```text
done
partial
not done
deferred
unknown
attention
active
reviewing
merge-ready
blocked
```

The rollup should come from backend projection, not frontend counting of CSS
badges.

## Capability Item Row

Each row should fit inside narrow screens and remain readable.

Recommended row fields:

```text
completion mark
title
short derived reason
primary operational state
attention count
linked evidence count
next action indicator
```

Expanded row or drawer fields:

```text
description
mark reason
linked WorkRequests
linked planned slices
linked WorkPackages
PR and review evidence
active blockers
guidance requests
decisions
lineage relationships
dependencies
safe next action
raw statuses
```

The compact row should be clean. The drawer should make the row trustworthy.

## Attention Center

Attention should be grouped by actionability:

```text
Needs human answer
Needs architect reconcile
Needs worker action
Needs review evidence
Needs merge decision
Needs cleanup
Contradiction or stale state
```

Examples:

```text
Needs human answer
|-- Outbox cursor safety decision
|   WorkPackage: wp_repository_split_2b
|   Why: architect escalated guidance to human_info_needed

Needs architect reconcile
|-- Scheduler target selection moved to reviewing after map update
|   Why: linked package changed after last Atlas reconciliation

Needs cleanup
|-- Original repository oracle is still open
|   Why: successor package merged, original work is preserved as oracle
```

Attention should link directly to the relevant detail page or human answer
surface.

## Next Moves Panel

Next moves should be short and ranked.

Each next move should include:

```text
title
owner
action kind
target
safe_to_do
why safe or blocked
```

Examples:

```text
[Safe] Merge repository split 2B
Reason: package is merge-ready, review evidence is present, dependencies are
satisfied.

[Blocked] Dispatch scheduler locks slice
Reason: depends on target selection contract, which is still reviewing.

[Human] Answer outbox cursor safety guidance
Reason: active human_info_needed guidance blocks readiness.
```

Do not show a next move as safe unless the backend can prove it.

## Dependency View

Start with a table, not a canvas.

```text
Item                         Depends on                   State
Repository split 2B          DB core substrate             satisfied
Scheduler locks              Target selection contract     blocked
PDF export                   Report JSON stabilization     deferred
```

Useful filters:

```text
Ready now
Blocked by
Unblocks
Started before dependency complete
Replaced, recut, or superseded
Oracle preserved
```

A visual graph can come later, once the edge model has proven itself.

## Detail Drawer

Clicking a row should open a detail drawer with traceability.

Sections:

```text
Overview
Completion mark and reason
Operational state
Linked ledger records
Dependencies
Attention
Lineage
Evidence
Raw lifecycle
Next safe action
```

The drawer should answer:

```text
Why does the Atlas say this?
What real records back it?
What should happen next?
What is unsafe or blocked?
```

## Markdown Export

The dashboard should offer:

```text
Export progress summary
```

The export should resemble the nested tree and next moves format:

```text
# Creator Data Service Progress

## Core Platform

Core Platform
|-- [x] Rust workspace and health scaffold
|-- [x] Database pool and transaction substrate
|-- [~] Repository split: idempotency and outbox
`-- [ ] Production CI and deploy shape

## Next Moves

1. [Operator] Merge repository split 2B.
2. [Human] Answer outbox cursor safety guidance.
3. [Architect] Dispatch scheduler target-selection slice.
```

The export is a report, not the canonical source. The ledger and Atlas JSON
remain canonical.

## Mobile And Narrow Canvas Behavior

The Atlas must work on slim widths.

Rules:

- Keep row titles readable and wrapping.
- Avoid half-page-squished panels.
- Use stacked sections below a breakpoint.
- Keep the Attention and Next Moves panels reachable near the top.
- Let the tree collapse by topic.
- Avoid tiny graph canvases as the primary mobile experience.
- Use detail drawers or full-page detail routes when the row needs depth.

## Visual Tone

The Atlas should feel:

```text
sleek
calm
scan-friendly
operator-grade
truthful
slightly fun
```

It should not feel:

```text
enterprise Jira clone
marketing landing page
raw database admin table
over-decorated graph toy
status-badge soup
```

## Relationship To Existing Board

Execution Atlas should become the primary view for multi-slice feature work.

The raw board still matters:

- Audit.
- Lifecycle debugging.
- Package-level operations.
- Grant and worker detail.
- Review/readiness evidence.
- Manual recovery.

The user should be able to move from Atlas row -> package detail -> raw evidence
without losing context.

## Contradictions To Surface

The Atlas should make contradictions visible:

- Slice raw status says `dispatched`, but linked package is merged.
- WorkRequest raw status says `ready_for_slicing`, but packages are active.
- Package is merge-ready, but review evidence is missing.
- PR is merged, but package remains open.
- Active blocker exists, but topic looks healthy.
- Worker activity exists on a ready-for-worker package.
- Recut original still appears as delivery work.
- Oracle branch lacks clear successor links.
- Dependency target started before predecessor is done.
- Map was not reconciled after linked state changed.

These are exactly the places where a human cockpit beats a raw board.
