# Migration Runbook: Planning With Files to Symphony++

## Goal

Replace local planning files with virtual planning files backed by the Symphony++ ledger.

## Migration steps

1. Keep existing Planning With Files workflow during Phase 0-1.
2. After virtual renderers exist, import existing `task_plan.md`, `findings.md`, and `progress.md` into PlanNode/Finding/ProgressEvent records for one pilot package.
3. Run worker with Symphony++ Skill and MCP state tools.
4. Verify generated Markdown matches expected planning-file semantics.
5. Stop creating local planning files as source of truth.
6. Keep generated Git exports optional for audit only.

## Acceptance

- Agents can read planning state as Markdown.
- Writes go through Symphony++ tools.
- Dashboard/API sees the same state.
- No untracked local planning file is required.
