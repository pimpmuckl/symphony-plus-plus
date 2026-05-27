# Dashboard Specification

## Goal

Give the human overseer fast situational awareness without reading agent transcripts.

## Local Operator Mode

Start the local operator cockpit from `elixir/` with:

```powershell
mix sympp.cockpit
```

The launcher binds to `127.0.0.1:4057` by default, prints
`http://127.0.0.1:4057/sympp/board`, enables `sympp_local_operator: true`, and
serves Streamable HTTP MCP at `http://127.0.0.1:4057/mcp`. Pass `--port 0` for
an OS-assigned port during manual or test runs, or `--port <n>` for a different
stable port. Omit `--database` to use the shared local ledger at
the preferred `$HOME/.agents/splusplus/symphony_plus_plus.sqlite3` or
`%USERPROFILE%\.agents\splusplus\symphony_plus_plus.sqlite3` home, falling back
under a temp/relative `.agents/splusplus` root if home is unavailable; pass
`--database <ledger.sqlite3>` only for isolation, tests, or manual experiments.

When the Phoenix endpoint is configured with `sympp_local_operator: true`, the
local browser dashboard can open `/sympp/board` as the operator cockpit without
first entering a board work key. This mode is for the human machine owner
inspecting local Symphony++ state and creating or managing local WorkRequests
before WorkPackages exist.

For live React dashboard development, register the friendly local hostname once
from an elevated PowerShell session if Windows does not already resolve it:

```powershell
.\scripts\register-spp-localhost.ps1
```

Then start the API bridge and Vite shell as separate processes:

```powershell
cd elixir
mix sympp.cockpit --dashboard-origin http://spp.localhost:19999

cd assets
npm run dev
```

The Vite shell binds to `127.0.0.1:19999`, accepts `spp.localhost`, and redirects
`http://spp.localhost:19999/` to `/sympp/board`.

Local operator mode:

- requires a direct loopback request to a local host name with browser Fetch
  Metadata;
- rejects forwarded/proxy headers for operator entry;
- renders redacted dashboard projections only;
- shows `/sympp/work-requests/new` with explicit repo and base branch fields;
- lets the local operator create draft WorkRequests and use a human-owned
  `Start agent questions` action to move draft requests to
  `ready_for_clarification`;
- lets the local operator dispatch approved, undispatched planned slices into
  WorkPackages through the ledger-backed local assignment claim flow;
- lets the local operator prepare/replay a WorkRequest architect handoff with a
  scoped phase, architect anchor package, unclaimed architect grant, and
  redacted private handoff metadata;
- lets the local operator add and resolve contextual comments on WorkRequests,
  planned slices, and WorkPackages from detail views;
- shows package guidance requests that need human input in the operator
  priority watchlist and lets the local operator answer only
  `human_info_needed` guidance from the WorkPackage detail page;
- records local operator WorkRequest answers with the stable actor label
  `local-operator`;
- records local browser planned-slice dispatch grants with the stable worker
  identity `local-operator-worker`;
- keeps board-grant WorkRequest intake locked to the grant's frozen repo/base
  scope and ignores submitted repo/base values in board-grant mode;
- preserves explicit `?auth=work_key` paths for grant-scoped board and package
  views.

This is not a worker/agent permission grant. Worker and architect write access
still comes from scoped MCP grants and ledger-backed assignment claims.

## Views

### Board view

Columns:

```text
created
ready_for_worker
claimed
planning
implementing
reviewing
ci_waiting
ready_for_human_merge
ready_for_architect_merge
merged
blocked
abandoned
```

Card fields:

```text
WorkPackage ID
Title
Kind
Repo/base branch
Assigned agent run
Last progress timestamp
PR link
CI/review status
Active blocker count
Scope guard status
Plan completion
Open/total comment count
```

WorkPackage card payloads preserve the raw lifecycle `status` for backend
control and board grouping. They also include a read-only `operational_state`
projection for human delivery truth:

```text
key
label
tone
reason
raw_status
has_started
has_active_worker
last_activity_at
is_stale
attention_items
```

The projection is derived from raw package status, active blockers, worker or
runtime activity, progress events, PR/review/readiness evidence, and merge
metadata. Active blockers override otherwise healthy-looking cards to blocked
operational truth and add an attention item. Contradictions, including merged
PR metadata while a package remains open or merge-ready, ready packages missing
readiness evidence, or `ready_for_worker` packages with delivery activity, are
reported as `attention_items` instead of changing raw lifecycle status.
Historical activity is separate from currently active work: terminal AgentRun
or runtime history, old progress, or metadata evidence may set `has_started`
and project as `Started / Paused` or `Needs Attention`, while `Active` is
reserved for visible active worker, AgentRun, or runtime evidence.

WorkPackage card and detail payloads also include a backend-derived `lineage`
projection. It is recorded as explicit operational lineage evidence, not inferred
from titles or prose. The v1 payload includes:

```text
original_work
successor_work
superseded_by
recut_as
oracle_for
oracle_work
oracle_status
available
unavailable
cleanup_attention
```

Lineage relationships are limited to `superseded_by`, `recut_as`, and
`oracle_for`. Each entry carries source and target WorkPackage ids, branch
snapshots, current package statuses when available, reason text, decision
linkage, recorded event id/time, and the oracle-preserved flag. Cleanup
attention is projected when original work that points to a successor still has
an open raw lifecycle status, including from the successor side. If lineage
storage cannot be read, the backend reports an explicit unavailable lineage
payload and warning attention instead of returning the empty no-lineage shape.
Scoped board payloads only serialize relationships where both the source and
target WorkPackage are already visible in that board scope.

Planned-slice payloads include `operational_state` only when dispatch linkage is
included. Approved slices without linked delivery activity can project as
`ready_for_worker`; linked slices promote the linked WorkPackage operational
truth once the package is active, started/paused, needs attention, reviewing,
merge-ready, merged, blocked, or has active runtime evidence. The raw slice
`status` remains the authoring/dispatch lifecycle, so a dispatched slice linked
to a merged package still reports raw `status: dispatched` while its operational
state reports `Merged`. If a slice still appears idle while the linked package
has started, the slice projection includes an attention item.

WorkRequest-led delivery closeout is projected through the backend delivery
board. Delivery closeout, not raw dispatched slice status, is the source of
human delivery truth after work lands. A stale dispatched slice linked to a raw
`ready_for_worker` or otherwise stale package can project as `Needs Closeout`
from structured merged-PR evidence before closeout, then as `Delivered`,
`Completed Without PR`, `Superseded`, or `Abandoned` after closeout while raw
status remains available for audit.

WorkRequest, planned-slice, and WorkPackage projections may include
`comment_count`, `open_comment_count`, and `comments` detail arrays. Comment
bodies, author names, resolver names, and resolution notes are redacted in
dashboard projections. Cards show an attention signal only when comments remain
open; detail views show the scoped comment list and local operator add/resolve
controls. The local operator mutation surface stamps operator provenance
server-side, caps comment bodies at 4,000 characters and resolution notes at
1,000 characters, and returns at most 100 comments per target in detail arrays.

Local operator cockpit stream rail:

- Local operator mode renders a compact Projects / Work Streams rail above the
  operator priority summary.
- Streams are repo/base-branch pairs derived from local WorkPackages,
  WorkRequests, package guidance requests, and Solo Sessions. Each stream shows
  compact counts for package, request-side work, and solo-session surfaces;
  package guidance requests count with request-side work.
- Selecting a stream is stream-first navigation: it sets the repo and
  base-branch query filters for the whole cockpit and clears package-only
  `kind` and `phase` filters. This prevents request-only or solo-only streams
  from looking empty because of stale package filters.
- After a stream is selected, the toolbar remains available for explicit
  intersections such as selecting a package kind, phase, or editing the visible
  base-branch filter.
- `Show All` clears all cockpit filters and restores the complete local
  cockpit.
- Pin and unpin controls store pinned stream ids in browser `localStorage`.
  Pins only affect local visual priority/highlight; they are not persisted to
  the Symphony++ ledger, MCP state, or any backend schema.
- Board-grant mode does not render the stream rail or depend on browser-local
  pins.

### Work package detail

Sections:

```text
Overview
Product outcome
Engineering scope
Acceptance criteria
Guidance requests
Virtual task plan
Findings
Progress timeline
Comments
Artifacts
Branch/PR state
Review-suite state
Grant/agent run state
Controls
```

Controls should start minimal:

```text
Pause package
Revoke grant
Request replan
Approve/deny scope expansion
Mark abandoned
```

Do not add dangerous controls like merge-to-main until Phase 7+ and branch protection is proven.

The WorkPackage detail guidance section shows package guidance request status,
summary, question, context, requester, blocker id, escalation language, and any
recorded answer. In local operator mode, a request in `human_info_needed`
renders a compact answer form. Submitting it records the answer with
`answered_by = local-operator`, moves the guidance request to answered, and
records a matching blocker resolution event so the existing readiness gate no
longer fails on that guidance blocker. Ordinary open guidance remains an
architect responsibility and is not answerable from the local cockpit.
Board-grant and package-grant views can inspect safe guidance fields but cannot
submit guidance answers.

### WorkRequest intake and detail

`/sympp/work-requests` lists visible WorkRequests. In local operator mode it
shows all local WorkRequests plus a `New WorkRequest` action. In board-grant
mode it remains filtered by the grant's board scope.

WorkRequest cards and detail payloads preserve raw lifecycle `status` and also
include `operational_state` with the same projection shape as WorkPackages.
The WorkRequest projection aggregates planned-slice and linked WorkPackage
truth so a request with active, reviewing, merge-ready, merged, blocked, or
paused package work no longer presents `ready_for_slicing` as its primary human
state. Raw WorkRequest status remains available for controls and lifecycle
transitions. Grant-scoped WorkRequest list and detail responses promote only
linked WorkPackages that remain inside the grant's frozen repo/base scope;
out-of-scope links are treated as unavailable instead of leaking hidden package
state.

The delivery-board projection is the closeout detail source for WorkRequest-led
delivery. It shows per-slice delivery outcomes, closeout evidence summaries,
linked package raw status, attention reason codes, successor links, and counts
such as `needs_closeout`. Dashboard clients should display those backend
projections rather than deriving delivery truth from package cards or decision
text.

`/sympp/work-requests/new` behaves differently by mode:

- local operator mode requires the operator to enter repo and base branch
  explicitly;
- board-grant mode displays the locked repo/base branch and server-side creation
  uses only the frozen grant scope.

The intake form captures common constraints through structured fields for
allowed paths, forbidden paths, compatibility stance, validation expectations,
dependencies or notes, and stop conditions. Those values are stored in the
existing WorkRequest constraints map. Advanced JSON remains available for
uncommon constraint keys and complex shapes.

`/sympp/work-requests/:id` exposes WorkRequest controls based on product
ownership. In local operator mode, the page stays human-owned: the operator can
start agent questions for a draft request, answer product questions,
prepare/replay an architect handoff, inspect architect-owned context, and
dispatch approved slices. It does not expose architect authoring controls for
questions, decisions, or planned slices.

Scoped board-grant detail remains the architect/planning surface:

```text
Mark ready for clarification
Ask / answer / close clarification questions
Record decisions
Mark human info needed
Mark ready for slicing
Add / approve / skip planned slices
Mark sliced
```

Local operator detail keeps this smaller action set:

```text
Start agent questions
Answer open human questions
Prepare architect handoff
Dispatch approved planned slices
```

Architect handoff is local-operator-only and appears for WorkRequests in
`ready_for_clarification`, `clarifying`, `human_info_needed`,
`ready_for_slicing`, or `sliced`. It creates or reuses the WorkRequest-scoped
phase and architect anchor WorkPackage, mints an unclaimed architect grant with
WorkRequest/guidance capabilities, and stores the secret through private
handoff. Repeated use replays the existing active unclaimed handoff when
possible, otherwise reuses the same phase/anchor and renews the unclaimed grant.
Active handoff metadata that can be safely proven stale is retired before
renewal; missing or otherwise unverifiable metadata fails closed rather than
minting a duplicate active grant.
On reload, local-operator detail may display an already prepared active
unclaimed handoff only when the existing metadata is safely readable and
replayable; the load-time path is read-only and does not mint, renew, revoke, or
clean up handoffs.
The panel may show WorkRequest id, phase id, anchor package id, grant display
metadata, capability/scope metadata, redacted handoff coordinates, and the
plugin skill prompt. It must not show raw work-key secrets, secret hashes, or
full MCP secret-retrieval commands. Board-grant WorkRequest detail does not show
or run this control.

Planned-slice dispatch is local-operator-only. Approval and slice authoring stay
in the architect workflow; dispatch is the explicit operator action that turns
an already approved slice into a WorkPackage. It reuses the existing
`PlannedSliceDispatch` flow to create a WorkPackage, return ledger-backed local
assignment bootstrap metadata, link the planned slice, and refresh the page
with the WorkPackage id/status. It does not prepare worktrees or record
worktree scope; operators must complete the separate worktree preparation flow
before launching a worker. The browser may show only non-secret claim metadata
such as WorkPackage id, repo/base, optional WorkRequest id, claim owner, and
the prepared branch/worktree/caller id values after they exist. It must not
show raw worker secrets, secret-bearing commands, or private-store payloads.
Dispatch does not spawn Codex agents and does not call Linear.
Board-grant WorkRequest detail remains scoped to planning controls and does not
show the local dispatch control.

The WorkPackage detail handoff panel reads durable handoff metadata only from
the dashboard's configured/default local secret store. If a CLI or MCP dispatch
uses a per-call custom secret store, that command output remains the handoff
source of truth unless the dashboard app is configured to the same store.
The panel uses the dashboard's configured ledger database identity and local
repo root when deriving non-secret bootstrap commands.
It shows handoff rows only for non-expired, non-revoked worker grants, and it
emits runnable legacy/recovery private-handoff commands only when the repo root
is configured or discovered with the worker-secret helper script present.

### Runtime view

Show:

```text
Active runs
Queued packages
Retry state
Last heartbeat
Workspace path
Orchestrator events
Recent failures
```

## Readiness indicators

Use distinct indicators for:

```text
Agent says ready
Review suite says ready
GitHub says ready
Architect says ready
Human says ready
```

Do not collapse these into one boolean.

## Future: Execution Atlas

The current operator cockpit remains the live V2 dashboard contract: it shows
WorkRequests, WorkPackages, reviews, handoffs, blockers, and runtime activity.
The V3 direction is documented separately as the Execution Atlas:

```text
implementation_docs_symphplusplus/docs/execution_atlas/README.md
```

Execution Atlas is the proposed human-first projection that groups slices and
packages into nested topics, dependency-aware capability rows, attention items,
and next moves. It should build on the cockpit data instead of replacing raw
ledger records. Until V3 is implemented, dashboard changes should continue to
preserve the V2 operational truth model documented above.
