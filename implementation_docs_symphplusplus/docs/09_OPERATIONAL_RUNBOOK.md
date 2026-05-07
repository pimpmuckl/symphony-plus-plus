# Operational Runbook

## Starting a standalone hotfix

1. Create work package with kind `hotfix`.
2. Set repo and base branch.
3. Set acceptance criteria and review-suite requirement.
4. Mint worker grant.
5. Install or copy `.codex/skills/symphony-work-package/` into the worker repo.
6. Configure the Symphony++ MCP stdio dependency; see
   `.codex/skills/symphony-work-package/references/mcp_wiring.md`.
7. Hand worker the key and the verbatim `templates/worker_agent_prompt.md`.
8. Watch dashboard/API for progress.
9. Review PR and readiness evidence.
10. Human merges after branch protection passes.

## Starting a phase-based implementation

1. Create phase container.
2. Mint architect grant.
3. Give architect this package and `docs/00_ARCHITECT_AGENT_HANDOFF.md`.
4. Architect creates child packages from `work_packages/`.
5. Architect mints worker keys.
6. Workers implement child packages.
7. Architect merges accepted child PRs into phase branch.
8. Human reviews phase summary and promotes phase branch.

## Handling blocker

1. Read blocker reason and affected package.
2. Determine if blocker is scope, dependency, design, CI, or access.
3. For scope: approve/deny expansion.
4. For dependency: expose a context slice or adjust order.
5. For CI: require worker to attach failure analysis.
6. For design: request replan from architect.
7. Record resolution in progress events.

## Revoking a worker

1. Revoke grant.
2. Stop or pause active run if orchestrator supports it.
3. Mark AgentRun stopped/revoked.
4. Preserve workspace/logs.
5. Reassign package with a new grant if needed.

## Pilot migration with Kraken

Use the detailed operator playbook in
`../runbooks/KRAKEN_PILOT_MIGRATION_PLAYBOOK.md`.

Do not migrate the whole Kraken rewrite first.

Pilot sequence:

1. One standalone low-risk quick fix.
2. One hotfix-style package against `main`.
3. One mini-phase with two child packages and an architect agent.
4. Only then migrate the active Kraken rewrite phase.
