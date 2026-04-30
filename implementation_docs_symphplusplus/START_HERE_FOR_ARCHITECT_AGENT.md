# Start Here: Symphony++ Architecture Agent

You are overseeing the Symphony++ implementation.

Read these in order:

1. `docs/00_ARCHITECT_AGENT_HANDOFF.md`
2. `docs/01_IMPLEMENTATION_GUIDE.md`
3. `work_packages/00_INDEX.md`
4. `work_packages/01_DEPENDENCY_GRAPH.md`
5. `templates/architect_agent_prompt.md`

Then dispatch the first worker on:

```text
work_packages/SYMPP-P0-001_upstream-fork-baseline-and-local-run.md
```

Do not skip Phase 0. Do not begin dashboard, GitHub sync, MCP tools, or architect delegation until the prerequisite phases are merged and tested.

Your standing objective:

```text
Build Symphony++ as a permissioned WorkPackage control plane on top of Symphony,
while preserving upstream Symphony behavior and proving the standalone hotfix flow
before expanding into phase/architect delegation.
```
