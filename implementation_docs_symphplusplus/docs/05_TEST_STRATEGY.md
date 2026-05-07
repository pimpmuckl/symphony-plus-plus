# Test Strategy

## Test goals

Symphony++ must prove three things:

1. It preserves upstream Symphony behavior.
2. It enforces scoped work-package permissions.
3. It supports both quick standalone work and phase/architect delegation.

## Test categories

### Unit tests

- WorkPackage validation.
- AccessGrant secret generation and hashing.
- Grant claim validation.
- State-transition validation.
- Capability checks.
- Markdown renderers.
- Policy template expansion.
- Readiness gate predicates.

### Integration tests

- `tracker.kind: Symphony_pp` returns eligible packages.
- Existing Linear tracker behavior remains unchanged.
- MCP tools enforce scope.
- Worker can update own package.
- Worker cannot read sibling package.
- Architect can mint narrower child grant.
- Architect cannot mint out-of-scope child grant.
- Dashboard API reflects ledger state.

### End-to-end tests

- Standalone hotfix lifecycle.
- Worker claim and virtual-file update lifecycle.
- PR attachment and readiness check.
- Scope guard rejects out-of-scope changed files.
- Phase architect creates child packages and supervises ready state.

### Security tests

- Invalid secret rejected.
- Expired grant rejected.
- Revoked grant rejected.
- Already-claimed grant cannot be rebound unless policy explicitly allows continuation.
- Raw secret never appears in logs.
- Worker cannot list grants.
- Worker cannot mark merged.
- Worker cannot self-approve scope expansion.

## Required package-level testing fields

Every work package must specify:

- Unit tests.
- Integration tests.
- E2E/manual tests if applicable.
- Negative tests.
- Acceptance criteria.
- Regression checks for existing Symphony behavior.

## E2E milestone scenario

```text
Create hotfix work package.
Mint worker key.
Claim through MCP.
Read virtual files.
Append plan/progress/finding.
Attach branch and PR.
Simulate CI/review-suite artifact.
Mark ready for human merge.
Verify dashboard/API state.
Verify worker cannot access another package.
```

This scenario should become the primary regression test before any Kraken pilot.

## Symphony++ integration harness

Run the deterministic core integration profile from the Elixir project:

```powershell
cd elixir
mise exec -- mix sympp.integration
```

The profile runs `test/symphony_elixir/symphony_plus_plus/integration_harness_test.exs`.
It uses local SQLite ledgers and in-process MCP calls only. GitHub metadata,
review-suite results, branch heads, PR URLs, and phase merge artifacts are
deterministic fixtures; the harness must not call GitHub, Linear, OpenAI, MCP
workers, or production services.

Covered scenarios:

- Standalone hotfix creation, MCP worker claim, virtual-file access, local
  progress evidence, fake GitHub metadata, fake review evidence, and readiness.
- MCP package readiness through changed-file scope, current PR metadata, and
  persisted review-suite artifacts.
- Two-package phase architect delegation, child worker readiness, architect
  approval, and phase merge records.
- Security denials for invalid work-key claims, revoked grants, sibling
  resource access, and architect phase-scope drift.

CI feasibility:

- The profile is intended to be CI-friendly because it uses no network and no
  credentials.
- On the current Windows host, the profile is the documented core harness while
  the repository-wide `mix test` can still encounter known environment blockers
  documented in `SETUP_NOTES.md`: Phoenix LiveView symlink permissions,
  path-canonicalization differences, and fake shell/SSH interception behavior.

## Coverage ratchet

The Elixir coverage threshold is a release ratchet, not an aspirational target.
Keep `test_coverage.summary.threshold` in `elixir/mix.exs` close to the current
measured total coverage so `mix test --cover` catches regressions without
blocking release readiness on future strict/integration coverage work.

`100%` coverage remains a future campaign lane. It is not a blocker for the
current Symphony++ release gate; see `11_RELEASE_VALIDATION.md`.
