# SYMPP-P3-001 — MCP server scaffold

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 3 — Agent interface |
| Kind | mcp |
| Owner role | worker |
| Dependencies | SYMPP-P1-002, SYMPP-P1-004 |

## Summary

Create the Symphony++ MCP server process and expose basic health, resource, and auth wiring.

## Implementation tasks

- Select STDIO or HTTP MCP mode based on project conventions.
- Implement server scaffold and config.
- Expose a health/version tool or resource if appropriate.
- Wire server to Symphony++ ledger services.
- Add test harness for MCP calls.

## Acceptance criteria

- [ ] MCP server starts locally.
- [ ] Server can reach test ledger.
- [ ] Auth/session injection path is designed.
- [ ] No package data is exposed without grant/session.

## Test plan

### Unit tests

- Server config parsing.
- Health/version response.
- Auth missing -> denial.

### Integration / E2E tests

- Start MCP server in test mode and call basic tool/resource.
- Verify no unauthenticated work package listing.

### Negative / regression tests

- Do not expose admin APIs to worker MCP by default.
- Do not log bearer tokens/secrets.


## Deliverables

- Implementation PR for `SYMPP-P3-001`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P3-001: MCP server scaffold.

Read this package spec fully. Implement only this package's scope. Do not implement dependent packages. If you discover that the package requires broader scope, stop and request scope expansion with a concrete reason.

Before coding:
1. Inspect the current repository state.
2. Confirm the dependency packages are merged or available.
3. Create a brief implementation plan.

During coding:
1. Keep changes limited to this package.
2. Add or update tests from the package test plan.
3. Preserve existing Symphony behavior unless this package explicitly changes it.

Before PR:
1. Run the relevant tests.
2. Verify every acceptance criterion is satisfied or explain any exception.
3. Write a PR summary with test results and risk notes.

Package dependencies: SYMPP-P1-002, SYMPP-P1-004.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
