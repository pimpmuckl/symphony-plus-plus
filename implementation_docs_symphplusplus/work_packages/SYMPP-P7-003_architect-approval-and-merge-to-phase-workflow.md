# SYMPP-P7-003 — Architect approval and merge-to-phase workflow

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 7 — Phase/architect delegation |
| Kind | delegation |
| Owner role | worker |
| Dependencies | SYMPP-P7-002, SYMPP-P6-003 |

## Summary

Implement the phase-child readiness path where workers mark ready for architect, architect approves and records merge into phase.

## Implementation tasks

- Add ready_for_architect_merge gate for phase children.
- Implement approve_child_ready_state.
- Implement merge_child_into_phase record/artifact.
- Do not directly merge protected branches unless branch protection and GitHub integration explicitly support it.
- Expose phase progress summary.

## Acceptance criteria

- [ ] Worker can mark child ready for architect when gates pass.
- [ ] Architect can approve child ready state.
- [ ] Architect can record merge artifact/status.
- [ ] Phase progress reflects merged child count.
- [ ] Human can inspect the phase summary.

## Test plan

### Unit tests

- Phase-child readiness state.
- Architect approval allowed.
- Worker approval denied.
- Merge record validation.
- Phase progress calculation.

### Integration / E2E tests

- Create phase child, attach PR/review, mark ready, approve, record merge.
- Verify dashboard/API phase board updates.

### Negative / regression tests

- Worker cannot mark merged_into_phase.
- Architect cannot approve child with failed gates unless explicit override with rationale.


## Deliverables

- Implementation PR for `SYMPP-P7-003`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P7-003: Architect approval and merge-to-phase workflow.

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

Package dependencies: SYMPP-P7-002, SYMPP-P6-003.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
