# MCP Tools Contract

This document mirrors `mcp_tools_contract.json` in readable form.

## Worker tools

| Tool | Purpose |
|---|---|
| claim_work_key | Claim a one-time work key/secret and bind it to the current agent run. |
| get_current_assignment | Return the scoped assignment for the bound grant. |
| read_context | Read context.md for the current work package. |
| read_task_plan | Read task_plan.md for the current work package. |
| update_task_plan | Patch the plan with optimistic concurrency. |
| append_finding | Append a finding to the current work package. |
| append_progress | Append a progress event to the current work package. |
| set_status | Request a valid state transition. |
| report_blocker | Record an active blocker. |
| request_scope_expansion | Request broader scope; does not approve it. |
| attach_branch | Attach branch metadata. |
| attach_pr | Attach PR metadata. |
| submit_review_package | Attach summary/tests/artifacts for review. |
| mark_ready | Move to ready state only if gates pass. |

## Resources

```text
sympp://assignment/current
sympp://work-packages/{id}/context.md
sympp://work-packages/{id}/task_plan.md
sympp://work-packages/{id}/findings.md
sympp://work-packages/{id}/progress.md
sympp://work-packages/{id}/acceptance.md
sympp://work-packages/{id}/review_suite.md
sympp://work-packages/{id}/handoff.md
```
