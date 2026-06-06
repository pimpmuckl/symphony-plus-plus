# Operational Runbook

## Local Daemon

From `elixir/`:

```bash
mix sympp.cockpit
```

The daemon serves MCP at `http://127.0.0.1:19998/mcp` by default and uses the
local Symphony++ ledger unless `--database <path>` is supplied.

## Worker Dispatch Check

1. Architect dispatches a planned slice with `dispatch_work_request_planned_slice`.
2. Confirm the response includes `work_package.id` and `worker_bootstrap`.
3. Prepare or select the worker's product-repo worktree. The normal architect
   tool is `prepare_work_package_worktree`; an equivalent operator-created
   worktree is acceptable when it is recorded or supplied in launch context.
4. Start a worker MCP-enabled session in that worktree.
5. Worker calls `claim_local_assignment` with the WorkPackage id.
6. Worker calls `get_current_assignment` and proceeds from ledger context.

Worktree path and branch are launch context for coding. They are not required
claim proof in the normal id-first claim path.

## Architect Check

1. Start an MCP-enabled architect session.
2. Call `claim_local_architect_assignment` with the WorkRequest id.
3. Read the WorkRequest, product tree, and delivery board before acting.

## Troubleshooting

- If a claim is rejected for another active owner, inspect/release the claim
  lease or wait for stale-lease recovery.
- If a claim is rejected for scope mismatch, verify the WorkRequest or
  WorkPackage belongs to the intended repo/base branch.
- If tools are missing, verify the opt-in MCP plugin/config was loaded before
  the session started.

## References

- `../../.codex/skills/symphony-work-package/`
- `../../plugins/symphony-plus-plus-mcp/`
- `../templates/references/mcp_wiring.md`
- `../templates/worker_agent_prompt.md`
