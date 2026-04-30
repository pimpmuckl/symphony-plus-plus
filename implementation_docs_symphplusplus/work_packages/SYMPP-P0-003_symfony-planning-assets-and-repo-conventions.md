# SYMPP-P0-003 — Symphony++ planning assets and repo conventions

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 0 — Baseline fork |
| Kind | docs |
| Owner role | worker |
| Dependencies | SYMPP-P0-001 |

## Summary

Install this planning package into the fork and add non-invasive repo conventions for worker PRs, without changing runtime behavior.

## Implementation tasks

- Copy this package into planning/Symphony-plus-plus or equivalent.
- Add or update AGENTS.md with PR/package conventions if the repo supports it.
- Add a draft WORKFLOW.Symphony_pp.md template under planning/templates or equivalent.
- Do not wire the workflow into runtime yet.

## Acceptance criteria

- [ ] Planning assets are committed in a predictable location.
- [ ] AGENTS/conventions document describes work package PR expectations.
- [ ] No runtime behavior changes.
- [ ] Architecture agent has a stable source of package specs.

## Test plan

### Unit tests

- None.

### Integration / E2E tests

- Run existing build/tests to verify docs-only package did not affect runtime.

### Negative / regression tests

- Do not replace upstream WORKFLOW.md yet.
- Do not add unfinished runtime config as active default.


## Deliverables

- Implementation PR for `SYMPP-P0-003`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P0-003: Symphony++ planning assets and repo conventions.

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

Package dependencies: SYMPP-P0-001.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
