# SYMPP-P4-002 — Quick-fix, hotfix, and investigation policy templates

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 4 — Quick work |
| Kind | product |
| Owner role | worker |
| Dependencies | SYMPP-P1-003, SYMPP-P4-001 |

## Summary

Finalize lightweight policy templates so small work stays agile while still gated.

## Implementation tasks

- Implement quick_fix, hotfix, investigation templates.
- Configure planning depth, grant expiry, required PR/artifacts, and readiness state.
- Add review-suite requirement defaults.
- Add template documentation.

## Acceptance criteria

- [ ] quick_fix can complete with light planning.
- [ ] hotfix has stricter expiry/review requirements.
- [ ] investigation does not require PR but requires recommendation artifact.
- [ ] Templates are covered by lifecycle tests.

## Test plan

### Unit tests

- Template defaults match docs.
- Hotfix expires sooner than quick_fix.
- Investigation readiness does not require PR.
- Hotfix readiness requires PR/review evidence.

### Integration / E2E tests

- Create package of each template and drive valid lifecycle.
- Attempt invalid lifecycle for each template.

### Negative / regression tests

- Do not force phase-child planning depth on hotfixes.
- Do not allow hotfix to mark merged by worker.


## Deliverables

- Implementation PR for `SYMPP-P4-002`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P4-002: Quick-fix, hotfix, and investigation policy templates.

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

Package dependencies: SYMPP-P1-003, SYMPP-P4-001.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
