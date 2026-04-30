# SYMPP-P4-003 — End-to-end standalone hotfix scenario

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 4 — Quick work |
| Kind | e2e |
| Owner role | worker |
| Dependencies | SYMPP-P3-002, SYMPP-P4-001, SYMPP-P4-002 |

## Summary

Implement the primary MVP regression scenario from hotfix creation through worker claim, virtual-file updates, PR attachment, and readiness.

## Implementation tasks

- Build automated E2E test or scripted integration test.
- Create hotfix package.
- Mint/claim worker key.
- Read virtual files.
- Append plan/finding/progress.
- Attach branch and fake or real PR artifact.
- Attach review-suite artifact if needed.
- Mark ready_for_human_merge.
- Verify sibling access denial.

## Acceptance criteria

- [ ] E2E test passes in CI or documented local test profile.
- [ ] The scenario proves no phase is needed.
- [ ] mark_ready fails before required evidence and passes after evidence.
- [ ] Sibling access denial is included.

## Test plan

### Unit tests

- Covered by component tests from dependencies.

### Integration / E2E tests

- Full scenario script/test.
- Run against test database and MCP server/test client.

### Negative / regression tests

- Attempt mark_ready before PR/evidence.
- Attempt read sibling package.
- Attempt reuse claimed secret if policy forbids.


## Deliverables

- Implementation PR for `SYMPP-P4-003`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P4-003: End-to-end standalone hotfix scenario.

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

Package dependencies: SYMPP-P3-002, SYMPP-P4-001, SYMPP-P4-002.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
