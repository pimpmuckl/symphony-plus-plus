# Final Cutover: Simplified Agent Claims

## Acceptance

- Runtime tool discovery does not expose legacy secret claim tools.
- Dispatch output contains `worker_bootstrap` for `claim_local_assignment`.
- Worker claim requires only `work_package_id`; `claimed_by` is optional.
- Architect claim requires only `work_request_id`; `claimed_by` is optional.
- Skills, templates, scripts, and MCP contracts teach the simplified claim
  surface.

## Verification

Call `tools/list` against the updated MCP daemon or plugin-backed MCP session
that agents will use. Fail cutover if any returned tool name is
`claim_work_key` or `claim_private_handoff`.

Also fail cutover unless:

- `claim_local_assignment.inputSchema.required` is exactly
  `["work_package_id"]`.
- `claim_local_architect_assignment.inputSchema.required` is exactly
  `["work_request_id"]`.
- Both claim schemas list `claimed_by` as optional and do not require repo,
  base branch, branch, worktree path, caller id, or anchor package fields.
- A focused local-ledger dispatch smoke returns
  `worker_bootstrap.tool == "claim_local_assignment"` with
  `args.work_package_id`, and that worker claim succeeds with only the
  WorkPackage id.
- A focused local-ledger architect smoke succeeds with
  `claim_local_architect_assignment` using only the WorkRequest id.
- Full-suite and CI/check status is recorded as passed, failed, pending, or
  intentionally waived, with evidence. Focused claim smokes alone do not mean
  the cutover is merge-ready.

Run a stale-surface grep for legacy secret claim names, helper scripts, and
private handoff fields. Expected result: no agent-facing runtime, script, skill,
or active docs hits that instruct agents to use those paths. Negative policy
text such as "do not ask for private handoff metadata" is allowed. Internal
access-grant implementation may still use verifier hashes as storage details;
those are not agent bootstrap inputs.
