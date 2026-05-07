# Symphony++ Implementation Package

Symphony++ is a permissioned work-package control plane built on top of OpenAI Symphony.

This package is meant to be handed to an architecture agent that will supervise a phased implementation. Each work package is sliced so that individual worker agents can implement one PR at a time while the architecture agent maintains ordering, testing, and merge discipline.

## What this package contains

- `docs/` — product, architecture, permission, testing, dashboard, and operations documents.
- `work_packages/` — PR-sized implementation packages with dependencies, acceptance criteria, and test plans.
- `templates/` — prompts, `WORKFLOW.md`, Skill, optional Codex hook nudges,
  AGENTS-style instructions, and status templates.
- `mcp/` — MCP tool/resource contracts for Symphony++.
- `schemas/` — initial JSON schema sketches for core records.
- `review/` — review-suite contract and readiness-gate definitions.
- `runbooks/` — launch, hotfix, incident, and migration runbooks.
- `imports/` — machine-readable work-package backlog seed files.

## How to use this package

1. Fork `openai/symphony` into your own repository.
2. Copy this package into a planning directory in the fork, for example `planning/Symphony-plus-plus/`.
3. Give `docs/00_ARCHITECT_AGENT_HANDOFF.md` to the architecture agent.
4. Instruct the architecture agent to open one PR per work package from `work_packages/`.
5. Require each worker PR to pass the package-specific acceptance criteria and test plan before merge.
6. Treat Phase 0 and Phase 1 as non-negotiable prerequisites before attempting MCP, dashboard, GitHub sync, or architect delegation.

For operator training, start with `docs/12_OPERATOR_TRAINING.md`. It explains
when to use a standalone package versus a phase-based flow, how to run a
standalone hotfix, and which release and review gates matter before merge.

## Recommended merge policy

- One work package = one PR unless the architecture agent explicitly splits it.
- Every PR must update implementation notes and tests for the functionality it changes.
- A worker can request scope expansion, but cannot silently expand its scope.
- The architecture agent owns merge ordering and dependency unblocking.
- The system is not considered useful until the standalone hotfix flow works end-to-end.

## Phase summary

| Phase | Theme | Outcome |
|---|---|---|
| 0 | Baseline fork | Upstream Symphony runs locally and repository boundaries are mapped. |
| 1 | Core ledger | WorkPackage, AccessGrant, virtual planning files, and state machine exist. |
| 2 | Symphony adapter | `tracker.kind: Symphony_pp` dispatches Symphony++ work packages through the existing runner. |
| 3 | Agent interface | MCP tools/resources and Codex Skill let workers operate through scoped state. |
| 4 | Quick work | Standalone quick-fix and hotfix workflows work without phases or architects. |
| 5 | Dashboard | Human operator can inspect board, work package detail, events, blockers, and runs. |
| 6 | GitHub/review integration | PR, CI, review-suite, and changed-file scope guard update readiness automatically. |
| 7 | Phase/architect delegation | Architect grants can create child packages and mint narrower worker keys. |
| 8 | Hardening/pilot | Integration tests, security audit, Kraken pilot migration, and release readiness. |

## First milestone

The first milestone is not the dashboard. It is this scenario:

```text
Human creates standalone hotfix work package.
Symphony++ mints a worker key.
Worker claims the key through MCP.
Worker reads virtual planning files.
Worker appends progress/findings.
Worker attaches a PR.
Review gates mark it ready for human merge.
```

If this scenario works, Symphony++ has its core value.

## Release and review references

- Operator training: `docs/12_OPERATOR_TRAINING.md`
- Hotfix package creation: `runbooks/HOTFIX_RUNBOOK.md`
- Release validation checklist: `docs/11_RELEASE_VALIDATION.md`
- WorkPackage readiness gates: `review/READINESS_GATES.md`
- Reviewer checklist: `review/REVIEWER_CHECKLIST.md`
