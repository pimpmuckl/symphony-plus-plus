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
3. Store the one-time secret in a local private handoff store and return only
   non-secret handoff metadata in normal command output.
4. Worker MCP starts through the private-store bootstrap, which injects the
   secret only into the MCP child process environment and passes the stable
   `claimed_by` owner identity.
5. Server validates hash, expiry, revocation, claimed owner, and not already bound to a different owner.
6. Server binds grant to the worker session with the claimed_by owner identity.
7. Reconnects are accepted only for the same owner identity and secret proof.
8. Subsequent calls use bound session/grant identity.
```

This is the Symphony++ worker MCP API decision for the pre-production worker
surface: workers must claim with an explicit owner identity rather than relying
on ambiguous anonymous ownership.

`claim_work_key(secret, claimed_by)` remains the server-side recovery primitive,
but first-use Codex workers should not paste raw secrets into prompts or normal
tool calls. On Windows, the local bootstrap uses Windows Credential Manager. On
non-Windows systems, the fallback is a user-local private file store whose ACL
strength depends on the local profile and should be treated as a smaller
development fallback.

Private handoff metadata has its own naming contract. Local private-file paths
and Windows Credential Manager targets use the stable, non-secret
`worker_grant.id` as the uniqueness boundary. The four-character `display_key`
may appear as a readable operator label, but it is not the unique storage
identity. Normal command output must keep showing only non-secret handoff
metadata and bootstrap shape; raw worker secrets stay in the private store and
must remain redacted from stdout, prompts, PR text, review text, and logs.

Managed handoff metadata records are non-secret deletion-coordinate metadata.
They identify the work package, worker grant, mode, and managed private-store
path or credential target needed for later cleanup; they are not worker secrets
and must not contain work keys, bearer material, run commands, or claimed owner
identity. In the current pre-production v1 child minting contract,
`mint_child_worker_key` allows only one active child-worker grant/handoff per
child package and rejects remint attempts while one exists; it does not perform
implicit replacement or old-handoff cleanup.

Architect child worker minting follows the same private-handoff rule. The
`mint_child_worker_key` MCP response returns `worker_grant.secret_handoff` and
`worker_grant.secret_in_response: false`, never the child worker secret or a
`secret_returned_once` marker. Returned handoff metadata is redacted and omits
run commands and the resolved claimed owner identity. Optional handoff settings
are limited to `template.secret_handoff.mode`, `store_dir`, and `claimed_by`;
they do not change the child grant capability or expiry boundaries.

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
