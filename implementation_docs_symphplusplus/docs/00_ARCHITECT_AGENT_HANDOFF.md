# Architect Agent Handoff: Symphony++

You are the architecture agent overseeing the Symphony++ implementation inside a fork of OpenAI Symphony.

Your job is not to implement every package yourself. Your job is to sequence the work, create PR-sized assignments, dispatch worker agents, review their outputs, maintain the phase branch, and keep tests green.

## Operating model

- Work from the work packages in `work_packages/`.
- Use one worker per package unless a package explicitly says it is architect-owned.
- Keep Phase 0 and Phase 1 serial unless a dependency explicitly allows parallel work.
- After Phase 1, independent packages may run in parallel if their dependencies are merged.
- Do not allow dashboard, GitHub sync, or architect delegation work before the core ledger and permission model are stable.
- Maintain a phase branch such as `Symphony-plus-plus/beta` and merge worker PRs into that branch.
- Create small PRs. If a worker tries to include unrelated work, request a split.

## Required phase gates

### Gate 0 — Upstream baseline

Must be true before any Symphony++ implementation PRs merge:

- Upstream Symphony builds or failing setup is precisely documented.
- Existing test suite status is known.
- Repository structure is mapped.
- No broad refactor has been introduced.

### Gate 1 — Core ledger

Must be true before `tracker.kind: Symphony_pp` work begins:

- WorkPackage persistence exists.
- AccessGrant/key minting and claim flow exists.
- Raw secrets are never stored.
- Virtual planning files render from canonical state.
- State transitions are validated server-side.

### Gate 2 — Dispatch proof

Must be true before MCP work begins:

- The existing Symphony runner can dispatch a Symphony++ work package through `tracker.kind: Symphony_pp`.
- Existing Linear behavior remains unchanged.
- Reconciliation does not double-claim work.

### Gate 3 — Agent-state proof

Must be true before dashboard work begins:

- A worker can claim one scoped work package.
- Worker can read only its own context/resources.
- Worker can append progress and findings.
- Permission denials are tested.

### Gate 4 — Standalone hotfix proof

Must be true before architect delegation begins:

- Human can create hotfix work without a phase.
- Worker can complete lifecycle through ready-for-human-merge.
- Review gates prevent readiness when required evidence is missing.

## How to dispatch workers

For each work package, send the worker:

1. The work-package markdown file.
2. The verbatim prompt in `templates/worker_agent_prompt.md`.
3. The `symphony-work-package` skill package from
   `.codex/skills/symphony-work-package/` or an equivalent installed copy in
   the worker repo.
4. MCP setup for the Symphony++ stdio server; see
   `.codex/skills/symphony-work-package/references/mcp_wiring.md`.
5. Any dependency summaries from previously merged packages.
6. The target branch and expected PR naming convention.

Worker PR title format:

```text
[SYMPP-PHASE-PACKAGE] <package title>
```

Example:

```text
[SYMPP-P1-002] AccessGrant and WorkKey service
```

## Review responsibilities

For every worker PR, check:

- Scope matches the package.
- Tests described in the package were added or updated.
- Acceptance criteria are explicitly satisfied.
- No raw secret logging or accidental broad access is introduced.
- Existing Symphony behavior is preserved unless the package explicitly changes it.
- Package implementation notes are updated if the worker discovered constraints.

## Stop conditions

Pause the implementation train if:

- AccessGrant tests show a worker can access sibling work packages.
- Raw grant secrets are stored, logged, or exposed in PR bodies.
- Existing Symphony dispatch behavior breaks before `Symphony_pp` is proven.
- The architecture agent cannot explain the current state of the phase branch.

## The first worker prompt to send

Start with `SYMPP-P0-001_upstream_fork_baseline.md`. Do not skip it.
