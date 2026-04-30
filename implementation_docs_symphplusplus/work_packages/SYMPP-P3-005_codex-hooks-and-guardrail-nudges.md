# SYMPP-P3-005 — Codex hooks and guardrail nudges

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 3 — Agent interface |
| Kind | hooks |
| Owner role | worker |
| Dependencies | SYMPP-P3-004 |

## Summary

Add optional Codex hook templates to remind agents of assignment scope, progress updates, and handoff requirements.

## Implementation tasks

- Add hook config examples for SessionStart/UserPromptSubmit/PreToolUse/PostToolUse/Stop where supported.
- Implement lightweight scripts only if safe and repo-appropriate.
- Document hooks as reliability aids, not permission boundary.
- Add tests/lints for scripts if executable.

## Acceptance criteria

- [ ] Hook templates are documented and optional.
- [ ] Hooks never contain grant secrets.
- [ ] Hooks do not block legitimate work unpredictably.
- [ ] Permission model still lives server-side.

## Test plan

### Unit tests

- Script lint/unit tests if scripts are added.
- Redaction tests for hook output if applicable.

### Integration / E2E tests

- Manual hook dry run if Codex hooks enabled.
- Verify no runtime dependency on hooks for server permission checks.

### Negative / regression tests

- Do not make hooks required for MCP authorization.
- Do not parse private chain-of-thought or transcripts for security decisions.


## Deliverables

- Implementation PR for `SYMPP-P3-005`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P3-005: Codex hooks and guardrail nudges.

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

Package dependencies: SYMPP-P3-004.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
