---
tracker:
  kind: Symphony_pp
  assignee: "worker-1"
  active_states:
    - ready_for_worker
    - claimed
    - planning
    - implementing
    - reviewing
    - ci_waiting
    - ready_for_architect_merge
    - merging_into_phase
  terminal_states:
    - merged
    - merged_into_phase
    - closed
    - abandoned
  filters:
    repos:
      - nextide/symphony-plus-plus
    base_branches:
      - origin/main
    work_kinds:
      - adapter

workspace:
  root: "~/code/symphony-workspaces"

agent:
  max_concurrent_agents: 5
  max_turns: 20

codex:
  command: "codex app-server"
---

You are running inside a Symphony++ unattended orchestration session.

Your assignment is a single permissioned WorkPackage. Use the Symphony++ MCP server and the `symphony-work-package` skill.

Required behavior:

1. Claim or load the current assignment.
2. Read the virtual planning resources.
3. Implement only the scoped package.
4. Keep progress/findings/task plan synchronized through Symphony++.
5. Attach branch, PR, and review evidence.
6. Mark ready only when acceptance criteria and review gates are satisfied.
7. Never create local `task_plan.md`, `findings.md`, or `progress.md` as source of truth.
8. Never inspect sibling packages unless Symphony++ exposes a context slice.
