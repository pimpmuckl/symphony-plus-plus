# SYMPP-P7-002 — Child work creation and worker-key minting

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 7 — Phase/architect delegation |
| Kind | delegation |
| Owner role | worker |
| Dependencies | SYMPP-P7-001, SYMPP-P3-003 |

## Summary

Allow a phase architect to create child WorkPackages and mint narrower worker grants for them.

## Implementation tasks

- Implement create_child_work_package.
- Implement mint_child_worker_key.
- Validate child scope within phase constraints.
- Set child base branch from phase policy unless explicitly allowed.
- Add context-slice support if feasible.

## Acceptance criteria

- [ ] Architect can create child package in own phase.
- [ ] Architect can mint worker key for child package.
- [ ] Child grant is narrower than architect grant.
- [ ] Out-of-phase child creation is rejected.
- [ ] Standalone flow remains unaffected.

## Test plan

### Unit tests

- Create valid child.
- Reject child outside phase.
- Mint child worker grant.
- Reject broader child grant.
- Worker cannot mint child grant.

### Integration / E2E tests

- Architect creates child, worker claims child, worker sees only child package.
- Architect sees child status.

### Negative / regression tests

- Architect cannot mint child against main if phase targets beta branch unless allowed.
- Worker cannot see sibling child packages.


## Deliverables

- Implementation PR for `SYMPP-P7-002`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P7-002: Child work creation and worker-key minting.

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

Package dependencies: SYMPP-P7-001, SYMPP-P3-003.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
