# Symphony++ V3: Execution Atlas

Execution Atlas is the V3 product direction for the human-facing Symphony++
cockpit.

It turns WorkRequests, planned slices, WorkPackages, PRs, blockers, reviews,
lineage, and decisions into a human-readable product progress map. The goal is
not another ticket board. The goal is a local operator command center that lets
the human answer, at a glance:

- What is the product trying to become?
- Which areas are done, partial, missing, or deliberately deferred?
- What is actively happening?
- What needs human guidance?
- What is blocked, stale, recut, superseded, or merge-ready?
- What is the next safe move?

The key product split is:

```text
Raw ledger state
  Audit, control, permissions, grants, lifecycle, dispatch, readiness gates.

Operational projection
  Backend-derived delivery truth from lifecycle, activity, blockers, PRs,
  review evidence, merge evidence, and lineage.

Execution Atlas
  Human-readable product truth: topics, capability items, dependency edges,
  attention, and next moves.
```

Execution Atlas does not replace the existing Symphony++ control plane. It sits
above it, keeping the raw lifecycle and grant model authoritative while making
the overall work legible.

## Why This Exists

The current S++ dashboard already exposes a lot of real state, but raw state is
not always the same thing as human truth. A planned slice can still have raw
status `dispatched` after its linked package has merged. A WorkRequest can read
`ready_for_slicing` while several packages are already active. A package can be
preserved as an oracle after a recut, but still look like delivery work unless
the dashboard explains the story.

Execution Atlas turns those records into a product map that reads more like:

```text
Creator Data Service
|-- Core Platform
|   |-- [x] Rust workspace and health scaffold
|   |-- [x] Database pool and transaction substrate
|   |-- [~] Idempotency and outbox repository split
|   |-- [ ] Production CI and deploy shape
|
|-- Scheduler
|   |-- [~] Target selection contract
|   |-- [ ] Locking and backoff model
|   |-- [ ] Provider gating
|
|-- Attention
|   |-- [!] Human guidance needed: outbox cursor safety
|   |-- [!] Recut cleanup: original repository oracle still open
|
`-- Next Moves
    |-- [1] Merge repository split 2B
    |-- [2] Answer outbox cursor product guidance
    `-- [3] Dispatch scheduler target-selection slice
```

That view is not just prettier. It is the missing supervision layer for
multi-package agent work.

## Document Set

- `01_PRODUCT_SHAPE.md` defines the product framing, entities, relationships,
  and human-facing vocabulary.
- `02_DATA_MODEL_AND_PROJECTION.md` defines what should be persisted, what
  should be derived, and the proposed `progress_map.v1` payload.
- `03_ARCHITECT_AND_MCP_WORKFLOW.md` defines how architect agents maintain the
  map and which MCP tools should exist.
- `04_DASHBOARD_UX.md` defines the cockpit surfaces, nested tree view,
  attention center, dependency view, and detail drawers.
- `05_ROADMAP.md` breaks the work into PR-sized implementation slices and
  lists anti-patterns to avoid.

## Product Principles

- Keep raw lifecycle state authoritative for control and audit.
- Let the backend derive operational truth; do not make React guess.
- Store only semantic curation that cannot be inferred safely.
- Treat stale maps as first-class attention, not as hidden failure.
- Make maps optional for tiny tasks and natural for multi-slice product work.
- Link every pretty row back to real ledger evidence.
- Never expose work keys, private handoff payloads, secret hashes, tokens, or
  secret-bearing commands in Atlas views.
- Preserve explicit lineage instead of inventing recut or oracle stories from
  prose.
- Optimize for local-first operator delight before enterprise workflow
  generality.

## Relationship To V2

V2 makes Symphony++ operational:

- WorkRequests capture intent.
- Architect handoffs clarify and slice work.
- Planned slices dispatch into WorkPackages.
- Workers record planning, findings, progress, branches, PRs, reviews, and
  readiness evidence.
- The local cockpit gives the operator visibility and action controls.

V3 makes Symphony++ understandable:

- The architect organizes the work into topics and capability items.
- The backend reconciles map curation with live ledger truth.
- The dashboard renders progress as a nested human-readable atlas.
- The operator can see done, partial, missing, deferred, blocked, stale, active,
  and next work without reading transcripts.

The raw board remains useful for audit and operations. Execution Atlas becomes
the default view for feature/product supervision.
