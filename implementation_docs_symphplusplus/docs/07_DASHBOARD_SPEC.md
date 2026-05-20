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
  WorkPackages through the existing private worker handoff flow;
- lets the local operator prepare/replay a WorkRequest architect handoff with a
  scoped phase, architect anchor package, unclaimed architect grant, and
  redacted private handoff metadata;
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
still comes from scoped work keys and MCP grants.

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
```

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
`PlannedSliceDispatch` flow to create a WorkPackage, mint a worker grant, store
the worker secret through private handoff, link the planned slice, and refresh
the page with the WorkPackage id/status. The browser may show only non-secret
handoff metadata such as mode, target, path, and run command. It must not show a
raw worker secret. Dispatch does not spawn Codex agents and does not call Linear.
Board-grant WorkRequest detail remains scoped to planning controls and does not
show the local dispatch control.

The WorkPackage detail handoff panel reads durable handoff metadata only from
the dashboard's configured/default local secret store. If a CLI or MCP dispatch
uses a per-call custom secret store, that command output remains the handoff
source of truth unless the dashboard app is configured to the same store.
The panel uses the dashboard's configured ledger database identity and local
repo root when deriving non-secret bootstrap commands.
It shows handoff rows only for non-expired, non-revoked worker grants, and it
emits runnable commands only when the repo root is configured or discovered with
the worker-secret helper script present.

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
