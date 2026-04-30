# SYMPP-P0-001 — Upstream fork baseline and local run

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 0 — Baseline fork |
| Kind | setup |
| Owner role | worker |
| Dependencies | none |

## Summary

Fork or clone upstream Symphony, run the reference implementation setup/build, and document the exact baseline without adding Symphony++ features.

## Implementation tasks

- Read upstream README, SPEC, and Elixir README.
- Run the documented setup/build commands from the reference implementation.
- Capture current test/build status, including failures.
- Create SETUP_NOTES.md with commands, environment variables, and troubleshooting notes.
- Do not change orchestration behavior.

## Acceptance criteria

- [ ] Existing upstream build/test status is known and documented.
- [ ] A human can reproduce the local setup from SETUP_NOTES.md.
- [ ] No Symphony++ implementation code is added in this package.
- [ ] Repository has a clean baseline branch/commit for later comparison.

## Test plan

### Unit tests

- No new unit tests required unless setup scripts are changed.

### Integration / E2E tests

- Run the existing upstream test/build command and record exact result.
- Run the upstream orchestrator command if credentials/config permit, or document missing credentials.

### Negative / regression tests

- Do not hide or patch upstream failures without explaining them.
- Do not introduce broad refactors.


## Deliverables

- Implementation PR for `SYMPP-P0-001`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P0-001: Upstream fork baseline and local run.

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

Package dependencies: none.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
