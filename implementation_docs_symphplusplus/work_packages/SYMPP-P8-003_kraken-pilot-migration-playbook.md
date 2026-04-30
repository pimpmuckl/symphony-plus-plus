# SYMPP-P8-003 — Kraken pilot migration playbook

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 8 — Hardening and pilot |
| Kind | pilot |
| Owner role | architect |
| Dependencies | SYMPP-P8-001, SYMPP-P8-002 |

## Summary

Prepare a low-risk Kraken pilot plan using Symphony++ without migrating the entire active rewrite at once.

## Implementation tasks

- Select one low-risk standalone Kraken quick fix.
- Select one hotfix-like package against dev/main.
- Select one two-child mini-phase.
- Define success metrics and rollback plan.
- Create pilot runbook with exact prompts and expected dashboards.

## Acceptance criteria

- [ ] Pilot plan identifies concrete packages/branches.
- [ ] Rollback plan exists.
- [ ] Success metrics are measurable.
- [ ] Human can run pilot without reading system internals.

## Test plan

### Unit tests

- None.

### Integration / E2E tests

- Dry-run creation of pilot packages in test/staging if available.
- Validate prompts with architect agent in non-production branch.

### Negative / regression tests

- Do not migrate active Kraken rewrite phase before mini-pilot succeeds.
- Do not allow automated production merge in pilot.


## Deliverables

- Implementation PR for `SYMPP-P8-003`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P8-003: Kraken pilot migration playbook.

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

Package dependencies: SYMPP-P8-001, SYMPP-P8-002.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
