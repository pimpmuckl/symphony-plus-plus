---
tracker:
  kind: Symphony_pp
  endpoint: "http://127.0.0.1:7777"
  api_key_env: "Symphony_PP_ORCHESTRATOR_TOKEN"
  active_states:
    - created
    - ready_for_worker
    - claimed
    - planning
    - implementing
    - reviewing
    - ci_waiting
  terminal_states:
    - merged
    - merged_into_phase
    - closed
    - abandoned

workspace:
  root: "~/code/Symphony-workspaces"

agent:
  max_concurrent_agents: 5
  max_turns: 20

codex:
  command: "codex app-server"
---

You are running inside a Symphony++ unattended orchestration session.

Your assignment is a single permissioned WorkPackage. Use the Symphony++ MCP server and the `Symphony-work-package` skill.

Required behavior:

1. Claim or load the current assignment.
2. Read the virtual planning files.
3. Implement only the scoped package.
4. Keep progress/findings/task plan synchronized through Symphony++.
5. Attach branch, PR, and review evidence.
6. Mark ready only when acceptance criteria and review gates are satisfied.
7. Never create local `task_plan.md`, `findings.md`, or `progress.md` as source of truth.
8. Never inspect sibling packages unless Symphony++ exposes a context slice.
