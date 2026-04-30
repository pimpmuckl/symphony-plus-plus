# SYMPP-P4-001 — Standalone create-work CLI/API

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 4 — Quick work |
| Kind | product |
| Owner role | worker |
| Dependencies | SYMPP-P1-002, SYMPP-P1-003, SYMPP-P1-004 |

## Summary

Add human-facing CLI/API to create one standalone WorkPackage and mint a worker key without any phase or architect setup.

## Implementation tasks

- Implement create-work command or HTTP endpoint.
- Support kind, repo, base branch, title, product description, engineering scope, acceptance criteria, review-suite template.
- Mint worker grant and return secret once.
- Render initial virtual files.
- Document examples for quick fix and hotfix.

## Acceptance criteria

- [ ] Human can create standalone work in one command/request.
- [ ] Returned output includes WorkPackage ID and one-time worker key/secret.
- [ ] Created package has no required parent phase.
- [ ] Initial task_plan/context/acceptance render correctly.

## Test plan

### Unit tests

- Parse valid create-work request.
- Reject missing repo/base/title.
- Apply default policy by kind.
- Mint grant exactly once.

### Integration / E2E tests

- Create hotfix package then claim with worker MCP.
- Create quick_fix package then render virtual files.

### Negative / regression tests

- Do not require architect/phase for standalone work.
- Do not print raw secret again after creation.


## Deliverables

- Implementation PR for `SYMPP-P4-001`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P4-001: Standalone create-work CLI/API.

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

Package dependencies: SYMPP-P1-002, SYMPP-P1-003, SYMPP-P1-004.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
