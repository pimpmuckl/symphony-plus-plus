# SYMPP-P2-002 — Symphony++ workflow config and dispatch filters

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 2 — Symphony adapter |
| Kind | adapter |
| Owner role | worker |
| Dependencies | SYMPP-P2-001 |

## Summary

Add workflow-frontmatter support and filters for Symphony++ work package dispatch.

## Implementation tasks

- Add example active/terminal state config.
- Add repo/base branch/work-kind filters if supported by current config model.
- Validate missing endpoint/token/config errors clearly.
- Document WORKFLOW.Symphony_pp.md usage.

## Acceptance criteria

- [ ] A custom WORKFLOW.Symphony_pp.md can select `Symphony_pp` tracker kind.
- [ ] Invalid config fails early with useful error.
- [ ] Dispatch filters prevent out-of-scope packages from running.
- [ ] Documentation explains how to run with custom workflow.

## Test plan

### Unit tests

- Parse valid config.
- Reject invalid tracker kind or missing required fields.
- Filter by state/kind/repo when configured.

### Integration / E2E tests

- Run dry/poll mode with sample config if supported.
- Existing default WORKFLOW.md still works.

### Negative / regression tests

- Do not silently fall back to Linear when Symphony_pp config is invalid.
- Do not dispatch all packages when filters are missing unless documented.


## Deliverables

- Implementation PR for `SYMPP-P2-002`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P2-002: Symphony++ workflow config and dispatch filters.

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

Package dependencies: SYMPP-P2-001.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
