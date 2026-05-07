# Security and Guardrails

## Threat model

Symphony++ assumes workers are useful but not fully trusted.

A worker may:

- Misunderstand instructions.
- Try to access state outside its assignment.
- Produce an overbroad diff.
- Claim work is ready without enough evidence.
- Accidentally expose secrets in logs or PR bodies.

Symphony++ must prevent or detect these cases.

## Non-negotiable guardrails

- Server-side permission checks on every action.
- No raw grant secrets stored.
- No raw grant secrets logged.
- Grant expiry and revocation.
- Worker grants scoped to one work package.
- Worker cannot mark merged.
- Worker cannot mint grants.
- Readiness gates are server-side.
- GitHub branch protection remains authoritative for protected branches.

## Local filesystem caveat

Symphony++ permissions control Symphony++ state. They do not automatically prevent an agent from editing arbitrary local files if the runner gives it broad filesystem access.

Therefore pair Symphony++ with:

- Per-issue workspaces.
- Branch protection.
- Required CI.
- Review-suite scope guard.
- Changed-file validation.
- Protected branch merge restrictions.

## Secret hygiene

The following strings are sensitive:

- Claim secrets.
- Bearer tokens.
- GitHub App private keys.
- Linear tokens.
- MCP server auth tokens.

Logs should contain only:

- WorkPackage IDs.
- display keys.
- grant IDs.
- hashed/verifier IDs.
- redacted token fingerprints.

## Scope guard

The scope guard should evaluate:

- Changed files.
- Base branch.
- Target branch.
- PR title/body work-package ID.
- Review-suite requirement.
- Required artifacts.

A worker can request scope expansion if the diff needs to exceed the package. The system must not silently accept scope drift.

## Human override

Human override is allowed only with explicit rationale and event logging.

Override record:

```json
{
  "override_type": "readiness_gate_override",
  "work_package_id": "SYMPP-P6-003",
  "actor": "human",
  "reason": "CI provider outage; local review suite and manual checks passed.",
  "created_at": "..."
}
```
