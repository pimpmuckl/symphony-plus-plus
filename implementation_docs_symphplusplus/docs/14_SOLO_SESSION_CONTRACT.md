# Solo Session Contract

Solo Sessions provide lightweight local planning memory for ordinary single
agent work. They are not authority for assigned WorkPackages, WorkRequests,
architect orchestration, bound MCP planning resources, or merge gates.

## Scope

Solo Session entries may record task plans, progress, findings, blockers,
decisions, and validation notes. They should stay small, redacted, and tied to
one repo/base branch/workspace path.

## Not For

- WorkPackage execution.
- WorkRequest orchestration.
- Grant minting or claim authority.
- Delivery closeout.

## Safety

Do not store raw API keys, bearer/GitHub/Linear/MCP tokens, worker secrets, raw
WorkKeys, access grants, private handoff payloads, access-grant verifiers,
secret hashes, secret-bearing commands, or claim lease internals.
