# SYMPP-P3-003 Findings

## Package Scope

- Source of truth: `implementation_docs_symphplusplus/work_packages/SYMPP-P3-003_architect-mcp-tools.md`.
- Acceptance requires documented/tested architect tool contracts, denial for worker grants, denial for invalid or insufficient grants, safe read-only tools where feasible, explicit not-yet-implemented errors for Phase 7 tools, and no premature delegation behavior.

## Current MCP Foundation

- `elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex` owns MCP tool/resource registration and dispatch.
- Existing worker tools are listed in `@worker_tools`, advertised through `tools/list`, validated against input schemas, and dispatched through `worker_tool/3`.
- Worker resources and tools revalidate live sessions through `Auth.require_session/2` and reject non-worker grants with `require_worker_assignment/1`.
- `AccessGrant` already supports `grant_role` values `worker` and `architect`, while `AccessGrantService.mint_worker_grant/3` only mints worker grants.
- Tests already include a helper that manually creates claimed architect grants for current pre-Phase-7 coverage.

## Implementation Boundary

- Phase entity support is not present in this package. Architect tools that need phase scopes, delegation, key minting, replan requests, approvals, merges, splitting, or phase publication must remain explicit stubs.
- A scoped read-only `read_child_status(work_package_id)` is feasible against the existing work-package ledger if the requested work package matches the architect grant's current scope.

## Validation Notes

- `mise exec -- mix format --check-formatted` passed.
- `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/mcp_test.exs` passed with 108 tests and 0 failures.
- `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/access_grants_test.exs test/symphony_elixir/symphony_plus_plus/mcp_test.exs` passed with 125 tests and 0 failures.
- `mise exec -- mix test` was attempted and failed with 57 unrelated Windows-environment failures across specs-check, SSH/fake-binary, workspace/temp-path, symlink, and app-server harness tests. The failure signatures do not involve the changed MCP architect-tool tests.
- The focused test run emits existing Windows/Phoenix symlink and migration module redefinition warnings; no test failures are associated with those warnings.

## Review Findings

- T1 Alpha found valid issues in the initial PR head: `read_child_status` classified backend read failures as invalid params, and its summary returned finding/artifact counts with only `read:child_progress`.
- Fix invariant: backend/storage failures must remain retryable service errors, and summary fields that reveal findings/artifacts need the corresponding architect finding capability.
- Owner/source of truth: MCP server authorization/error mapping in `server.ex`; permission split in `docs/03_PERMISSION_MODEL.md`.
- Structural fix: architect errors now map database/storage/migration failures to service errors, and `read_child_status` requires both `read:child_progress` and `read:child_findings`.
- Regression coverage: added progress-only architect denial and retained stub/runtime argument validation coverage in `mcp_test.exs`.
