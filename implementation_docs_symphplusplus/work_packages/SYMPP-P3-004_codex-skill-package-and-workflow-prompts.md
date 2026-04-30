# SYMPP-P3-004 — Codex Skill package and workflow prompts

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 3 — Agent interface |
| Kind | skill |
| Owner role | worker |
| Dependencies | SYMPP-P3-002 |

## Summary

Add the Symphony++ Codex Skill and repo workflow templates that teach workers to use MCP-backed virtual planning files.

## Implementation tasks

- Create Skill directory with SKILL.md.
- Add instructions to claim assignment, read virtual files, update progress/findings, attach PR, and mark ready.
- Add references/templates for worker prompts.
- Add docs for installing/wiring MCP dependency.
- Ensure skill does not instruct workers to create local planning files as source of truth.

## Acceptance criteria

- [ ] Skill metadata contains name and description.
- [ ] Skill instructions match MCP tool names.
- [ ] Worker prompt template is ready to paste.
- [ ] No contradiction with permission model.

## Test plan

### Unit tests

- If repository supports linting skill files, run it.
- Check file existence and required metadata.

### Integration / E2E tests

- Manual dry run: agent prompt can identify skill and intended MCP tools.
- Run existing tests to verify docs/skill do not break runtime.

### Negative / regression tests

- Do not include raw secrets in examples.
- Do not tell workers to use broad Linear/GitHub state directly for Symphony++ permissions.


## Deliverables

- Implementation PR for `SYMPP-P3-004`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P3-004: Codex Skill package and workflow prompts.

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

Package dependencies: SYMPP-P3-002.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
