# SYMPP-P0-002 — Repository map and extension seam analysis

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 0 — Baseline fork |
| Kind | analysis |
| Owner role | worker |
| Dependencies | SYMPP-P0-001 |

## Summary

Map the upstream repository structure and identify the lowest-risk seams for WorkPackage ledger, tracker adapter, MCP server, dashboard, and GitHub sync.

## Implementation tasks

- Map modules/processes responsible for tracker polling, issue normalization, workspaces, run state, dashboard/API, and config.
- Identify where to add `tracker.kind: Symphony_pp` without breaking Linear.
- Identify persistence layer and test conventions.
- Create docs/REPO_EXTENSION_MAP.md.
- Propose module names/namespaces for Symphony++ additions.

## Acceptance criteria

- [ ] REPO_EXTENSION_MAP.md exists and names concrete files/modules for each extension seam.
- [ ] The plan preserves existing Linear behavior.
- [ ] The analysis identifies risks and test strategy per seam.
- [ ] Architecture agent can use the map to assign Phase 1 work.

## Test plan

### Unit tests

- None unless helper introspection scripts are added.

### Integration / E2E tests

- Verify named modules/files exist in the current fork.
- Cross-check map against build/test output from P0-001.

### Negative / regression tests

- Do not implement the seams in this package.
- Do not rename upstream modules.


## Deliverables

- Implementation PR for `SYMPP-P0-002`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P0-002: Repository map and extension seam analysis.

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

Package dependencies: SYMPP-P0-001.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
