# SYMPP-P1-005 — Audit event ledger and idempotency keys

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 1 — Core ledger |
| Kind | core |
| Owner role | worker |
| Dependencies | SYMPP-P1-001, SYMPP-P1-002 |

## Summary

Add append-only audit/progress events and idempotency handling for agent writes.

## Implementation tasks

- Add event/audit ledger if progress_events is not sufficient.
- Add idempotency key handling to append operations.
- Record actor/grant/agent_run when available.
- Add helper to fetch package timeline.
- Ensure sensitive values are redacted.

## Acceptance criteria

- [ ] Repeated append with same idempotency key does not duplicate events.
- [ ] Events include actor identity where available.
- [ ] Timeline can be rendered for dashboard/API.
- [ ] Secrets are redacted in event payloads.

## Test plan

### Unit tests

- Idempotent append same key.
- Different keys append separate events.
- Actor/grant recorded.
- Redaction helper removes known secret fields.

### Integration / E2E tests

- Claim grant, append progress with idempotency, verify one event.
- Render progress.md from event ledger.

### Negative / regression tests

- No raw claim secret in event payload.
- No unauthenticated event append.


## Deliverables

- Implementation PR for `SYMPP-P1-005`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P1-005: Audit event ledger and idempotency keys.

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

Package dependencies: SYMPP-P1-001, SYMPP-P1-002.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
