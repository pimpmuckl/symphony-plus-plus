# Task Plan: SYMPP-P3-001 MCP Server Scaffold

## Goal

Implement SYMPP-P3-001 only: a minimal Symphony++ MCP server scaffold with STDIO JSON-RPC, health/version, ledger reachability, session/auth gates, and focused tests.

## Current Phase

Phase 4

## Phases

### Phase 1: Requirements & Discovery
- [x] Read the package spec.
- [x] Confirm P1/P2 dependency packages are present on the base branch.
- [x] Inspect MCP contract, permission model, ledger services, and existing protocol conventions.
- [x] Select STDIO MCP mode based on repo and MCP transport conventions.
- **Status:** complete

### Phase 2: Implementation
- [x] Add MCP config, session/auth, JSON-RPC handler, and STDIO runner.
- [x] Add a local start command.
- [x] Keep worker/package tool/resource implementation out of scope except for auth denial scaffolding.
- **Status:** complete

### Phase 3: Testing & Verification
- [x] Add focused config, health/version, auth denial, and harness tests.
- [x] Run targeted tests and relevant baseline checks.
- [x] Document test results and any blocked validation.
- **Status:** complete

### Phase 4: PR & Reviews
- [x] Push branch and open PR `[SYMPP-P3-001] MCP server scaffold`.
- [x] Run review-t1 until valid findings are fixed.
- [x] Run review-t2 until green.
- [x] Run review-github until green and address inline comments.
- **Status:** complete

## Decisions Made

| Decision | Rationale |
|----------|-----------|
| Use STDIO MCP mode for P3-001. | Existing agent-facing protocol code uses stdio JSON-RPC, and MCP stdio is the local subprocess mode expected by clients. |
| Expose health/version and auth-gated resource stubs only. | P3-002/P3-003 own concrete worker and architect MCP tools; this package owns scaffold and safety gates. |

## Errors Encountered

| Error | Resolution |
|-------|------------|
| None | N/A |
