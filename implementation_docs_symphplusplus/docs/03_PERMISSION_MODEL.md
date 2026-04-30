# Permission Model

## Goal

Make it easy to send a normal worker agent to solve a small issue while still preventing the agent from gaining global project authority.

## Core policy

```text
No grant, no action.
Worker grant = one work package.
Architect grant = one container plus ability to mint narrower child grants.
Human/admin grant = repo/project/global authority depending on configuration.
```

## Display key versus secret

A four-character display key is acceptable for humans, but not as the security boundary.

Use:

```text
display_key: 91C2
secret: 32+ random bytes encoded as base64url or equivalent
secret_hash: hash(secret)
```

Store only `secret_hash`.

Never log:

- raw secret
- full claim URL containing secret
- bearer token
- grant verifier

## Claim flow

```text
1. Create WorkPackage.
2. Mint AccessGrant.
3. Return claim secret once.
4. Agent calls claim_work_key(secret).
5. Server validates hash, expiry, revocation, and not already bound.
6. Server binds grant to AgentRun.
7. Subsequent calls use bound session/grant identity.
```

## Worker capabilities

```text
read:own_work_package
read:own_context
read:own_virtual_planning_files
write:own_task_plan
append:own_findings
append:own_progress
set:own_status
report:own_blocker
request:scope_expansion
request:context
attach:own_branch
attach:own_pr
attach:own_artifact
submit:own_review_package
mark:ready
```

## Worker denials

```text
read:sibling_work_packages
write:phase_status
merge:pr
advance:phase
mint:worker_keys
reassign:work_package
read:grant_secrets
```

## Architect capabilities

```text
read:phase
write:phase_plan
create:child_work_package
update:child_work_package
mint:child_worker_key
revoke:child_worker_key
read:child_progress
read:child_findings
approve:child_ready_state
merge:child_into_phase
request:child_replan
split:child_work_package
publish:phase_update
```

## Scope expansion

Workers can request expansion, but cannot self-approve it.

Request shape:

```json
{
  "work_package_id": "SYMPP-P6-003",
  "reason": "Scope guard must inspect changed files from PR metadata, requiring GitHub client access.",
  "requested_capabilities": ["read:own_pr_changed_files"],
  "requested_file_globs": ["lib/Symphony_pp/github/**"],
  "risk": "medium",
  "proposed_verification": ["permission denial tests", "scope guard integration test"]
}
```

Approval updates the grant constraints. Denial records an event and the worker must stay in scope.

## Expiry defaults

| Grant kind | Default expiry |
|---|---:|
| quick fix worker | 24h |
| hotfix worker | 6h |
| investigation worker | 12h |
| phase child worker | 48h |
| architect phase grant | explicit phase duration |

## Enforcement location

The Symphony++ server enforces permissions. Prompts, skills, hooks, and dashboards are reliability aids, not authority.
