# SYMPP-P3-003 — Architect MCP tools

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 3 — Agent interface |
| Kind | mcp |
| Owner role | worker |
| Dependencies | SYMPP-P3-001, SYMPP-P1-002 |

## Summary

Prepare architect-facing MCP tool surface, with implementation limited to safe stubs or Phase 7-ready foundations if phase entities are not yet available.

## Implementation tasks

- Define architect tool contracts.
- Implement permission checks for architect role.
- Implement safe read-only tools that do not require Phase entity if feasible.
- Return clear not-yet-implemented errors for Phase 7 tools if needed.
- Add tests that worker grants cannot call architect tools.

## Acceptance criteria

- [ ] Architect tool contract is documented and test-covered.
- [ ] Worker grants are denied architect tools.
- [ ] Unimplemented Phase 7 tools fail explicitly, not silently.
- [ ] No phase delegation behavior is prematurely wired.

## Test plan

### Unit tests

- Worker denied architect tool.
- Invalid/insufficient grant denied.
- Contract schema validates inputs.

### Integration / E2E tests

- Call read-only architect tool with architect grant if a container scope exists.
- Verify Phase 7 tools return explicit error if not implemented.

### Negative / regression tests

- Do not let architect mint child grants before Phase 7 rules exist.
- Do not grant architect tools through worker session.


## Deliverables

- Implementation PR for `SYMPP-P3-003`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P3-003: Architect MCP tools.

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

Package dependencies: SYMPP-P3-001, SYMPP-P1-002.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
