# SYMPP-P1-001 — WorkPackage ledger schema and repository API

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 1 — Core ledger |
| Kind | core |
| Owner role | worker |
| Dependencies | SYMPP-P0-002 |

## Summary

Add persistent WorkPackage storage and a small repository/service API for creating, reading, updating, and listing work packages.

## Implementation tasks

- Add WorkPackage schema/table/entity with fields from docs/02_SYSTEM_SPEC.md.
- Implement repository/service functions for create/get/list/update.
- Add status and kind validation.
- Add timestamps and stable IDs.
- Add seed/test factory helpers.

## Acceptance criteria

- [ ] Standalone WorkPackage can be created and fetched.
- [ ] Invalid kind/status is rejected.
- [ ] Parentless standalone work packages are supported.
- [ ] Existing Symphony behavior still passes tests.

## Test plan

### Unit tests

- Create/get/update/list WorkPackage.
- Validation rejects invalid kind/status.
- Parent ID optional for standalone work.
- Timestamps set on create/update.

### Integration / E2E tests

- Run existing Symphony tests.
- Add persistence migration test or equivalent.
- If using Ecto, migration rolls forward cleanly in test database.

### Negative / regression tests

- Do not add grants yet.
- Do not dispatch WorkPackages through Symphony yet.


## Deliverables

- Implementation PR for `SYMPP-P1-001`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P1-001: WorkPackage ledger schema and repository API.

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

Package dependencies: SYMPP-P0-002.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
