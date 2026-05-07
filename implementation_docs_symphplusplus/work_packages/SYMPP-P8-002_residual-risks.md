# SYMPP-P8-002 Residual Risks

Date: 2026-05-07

## Covered In This Package

- MCP progress-event responses redact secret-shaped summary, status, idempotency, payload, artifact, and metadata text before serialization.
- Virtual planning markdown redacts secret-shaped source text before exposing MCP resource output.
- P7 architect mutating tools have regression coverage that direct calls fail without the specific grant capability.
- Scope expansion approval, child ready approval, and child merge operations retain audit progress events with actor and grant context.

## Residual Risks

1. `revoke_child_worker_key` remains a Phase 7 stub. It currently authorizes the architect capability and returns `phase7_not_implemented`; there is no product revocation operation to audit yet. A future revocation package must add actor, grant, rationale, and result audit events at the same time it implements the mutation.
2. Human override/readiness override is documented as a concept, but no MCP/API operation exists in the current product surface. A future override package must define the auth model and audit event before enabling the behavior.
3. `mint_child_worker_key` returns a child worker secret once in the MCP response so the child can claim the delegated grant. That value is intentionally not logged or persisted in API/dashboard surfaces, but operators must treat the one-time response as secret material and avoid pasting it into planning docs, PR bodies, logs, or reviews.
4. Internal `AccessGrantService.revoke/3` can revoke a grant without actor/rationale context because it is not exposed as the product revocation surface. If it becomes user-facing, it must be wrapped in an audited operation rather than called directly from an MCP/API tool.
