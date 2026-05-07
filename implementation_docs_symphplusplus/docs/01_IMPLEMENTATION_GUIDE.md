# Symphony++ Implementation Guide

## Product definition

Symphony++ is a Symphony fork where `issue` becomes a permissioned `WorkPackage`, the work package owns virtual planning files, and agents interact through scoped keys rather than broad tracker access.

## Design principles

1. Preserve upstream Symphony behavior first.
2. Add Symphony++ as a layer, not as an immediate rewrite.
3. Treat the Symphony++ ledger as the source of truth for agent state.
4. Treat GitHub as the source of truth for code, PR, CI, and review facts.
5. Treat Linear as an optional mirror, not the core authority.
6. Keep small work small: standalone quick-fix and hotfix packages must not require phase setup.
7. Make permissions server-enforced, not prompt-enforced.
8. Keep the agent-facing workflow simple: receive key, claim assignment, read virtual planning files, implement, attach PR, mark ready.

## Build order

```text
0. Run upstream Symphony and document baseline.
1. Add core Symphony++ ledger and permission objects.
2. Render virtual planning files from ledger state.
3. Add `tracker.kind: Symphony_pp` so the existing runner can dispatch Symphony++ packages.
4. Add MCP tools/resources and the Codex skill.
5. Add standalone quick-fix/hotfix creation and lifecycle.
6. Add dashboard.
7. Add GitHub PR/CI/review integration.
8. Add phase and architect delegation.
9. Harden, run E2E tests, and pilot with Kraken.
```

## Branching model

Recommended branches:

```text
main
  upstream-compatible fork baseline

Symphony-plus-plus/beta
  integration branch for all Symphony++ worker PRs

worker branches
  agent/SYMPP-P1-002-access-grants
```

For package PRs, prefer:

```text
agent/<work_package_id>/<short-slug>
```

## Merge model

- Worker PRs merge into the Symphony++ beta branch.
- Architecture agent owns merge ordering.
- Human owns final merge from beta to main until the system is trusted.
- Phase 7 may add architect merge automation, but it must not bypass branch protection.

## Testing pyramid

```text
Unit tests
  schema validation, state transitions, token hashing, renderer output

Integration tests
  tracker adapter, MCP tools, grant claim, permission denials, dashboard API

End-to-end tests
  standalone hotfix lifecycle, dispatched worker run, PR attachment, readiness gates

Security tests
  invalid/expired/revoked grants, sibling access denial, scope expansion enforcement
```

## Minimum useful product

The MVP is complete when:

- A standalone hotfix can be created without a phase.
- A worker receives a key and can claim exactly one assignment.
- Virtual `task_plan.md`, `findings.md`, and `progress.md` are rendered from canonical state.
- The worker can update plan/progress/findings through MCP tools.
- The worker can attach a PR and mark ready only when required evidence exists.
- A human can inspect the state in either a simple API response or early dashboard.

## What not to build first

Do not build these first:

- A beautiful dashboard.
- Linear mirroring.
- Full Kraken phase migration.
- Automated merge to protected branches.
- Complex multi-agent phase delegation.

Build the work-package/key/virtual-file core first.
