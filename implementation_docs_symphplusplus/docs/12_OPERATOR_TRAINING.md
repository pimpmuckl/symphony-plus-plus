# Operator Training

## Mental Model

Agents need one id to enter their lane:

- Worker lane: WorkPackage id.
- Architect lane: WorkRequest id.

Everything else is ledger context, validation context, or audit metadata.

## Worker Launch

Give the worker the package goal, acceptance criteria, constraints, validation
steps, review expectations, and the WorkPackage id. The worker claims with
`claim_local_assignment`, then reads context from MCP.

## Architect Launch

Give the architect the WorkRequest goal, constraints, product decisions, and the
WorkRequest id. The architect claims with `claim_local_architect_assignment`.

## Common Mistakes

- Do not paste raw secrets into prompts or comments.
- Do not ask workers to infer sibling scope.
- Do not use Solo Session as authority for assigned WorkPackages.
- Do not treat `tools/list` visibility as authorization.
