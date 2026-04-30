# SYMPP-P6-002 — Review-suite artifact contract

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 6 — GitHub/review integration |
| Kind | integration |
| Owner role | worker |
| Dependencies | SYMPP-P4-003 |

## Summary

Define and enforce review-suite artifacts keyed to work package and PR head SHA.

## Implementation tasks

- Add review-suite artifact schema/validation.
- Implement attach_review_suite_result or integrate via existing artifact API.
- Require artifact for packages/templates that demand it.
- Display review result in API/dashboard.
- Document expected JSON format.

## Acceptance criteria

- [ ] Review-suite result can be attached and validated.
- [ ] Artifact includes work_package_id and head_sha.
- [ ] mark_ready fails if required artifact missing or stale.
- [ ] Dashboard/API shows review-suite status.

## Test plan

### Unit tests

- Validate passing artifact.
- Reject missing head_sha.
- Reject wrong work_package_id.
- Reject stale artifact for current PR head.

### Integration / E2E tests

- Attach PR, attach review result for matching SHA, mark ready.
- Attach review result for old SHA, mark_ready fails.

### Negative / regression tests

- Do not accept arbitrary unvalidated JSON as passing evidence.
- Do not let worker bypass required review suite.


## Deliverables

- Implementation PR for `SYMPP-P6-002`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P6-002: Review-suite artifact contract.

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

Package dependencies: SYMPP-P4-003.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
