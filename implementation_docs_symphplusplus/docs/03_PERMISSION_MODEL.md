# Permission Model

The MCP server is the permission boundary. Prompts, skills, docs, and dashboard
UI are workflow aids only.

## Claim Coordinates

- Workers claim one WorkPackage with `claim_local_assignment`.
- Architects claim one WorkRequest with `claim_local_architect_assignment`.
- `claimed_by` is optional audit ownership, not a secret carrier.
- Repo, base branch, phase, anchor package, worktree, branch, and caller fields
  are derived from the ledger when omitted and are validation context when
  supplied.

## Role Boundaries

Workers can update task plan, findings, progress, blockers, comments, branch/PR
metadata, review evidence, and readiness for their assigned WorkPackage.
Workers cannot mint grants, dispatch planned slices, approve scope, merge PRs,
or close WorkRequest delivery.

Architects can slice WorkRequests, manage product-plan nodes, dispatch planned
slices, coordinate phase children, answer guidance, reconcile delivery, and
record closeout.
Architects may resolve blockers only for policy-scoped descendant WorkPackages
visible from their claimed WorkRequest or phase scope. They cannot report new
worker blockers, mutate sibling or unlinked packages, or use blocker resolution
as scope expansion.

## Safety

Agent-facing tools do not require private files, secret stores, or raw grant
secrets. Responses and durable notes redact bearer/API/GitHub/Linear/MCP tokens,
grant verifiers, secret hashes, and secret-like prose.
