# SYMPP-P3-002 — Worker MCP tools and resources

## Package metadata

| Field | Value |
|---|---|
| Phase | Phase 3 — Agent interface |
| Kind | mcp |
| Owner role | worker |
| Dependencies | SYMPP-P3-001, SYMPP-P1-004, SYMPP-P1-005 |

## Summary

Implement scoped worker MCP tools/resources for claim, virtual planning files, progress, findings, PR attachment, blockers, and readiness.

## Implementation tasks

- Implement claim_work_key with required secret plus claimed_by owner identity.
- Implement get_current_assignment.
- Implement virtual planning file resources.
- Implement update_task_plan, append_finding, append_progress.
- Implement set_status/report_blocker/request_scope_expansion.
- Implement attach_branch(branch, head_sha)/attach_pr/mark_ready with readiness checks.
- Implement submit_review_package so `head_sha` is required on every submission and the latest current-head review package is authoritative for readiness.
- Add permission-denial tests.

## Acceptance criteria

- [ ] Worker can complete basic state lifecycle for own package.
- [ ] Worker cannot read or mutate sibling package.
- [ ] mark_ready enforces gates.
- [ ] All writes are actor/grant scoped and idempotent where appropriate.

## Test plan

### Unit tests

- Each tool success path.
- Each tool denial path.
- mark_ready fails without required artifacts.
- request_scope_expansion records request but does not approve.

### Integration / E2E tests

- Claim key then read resources and append updates.
- Create two packages; verify worker A cannot access worker B.
- Attach PR and attempt readiness.

### Negative / regression tests

- Worker cannot mark merged.
- Worker cannot mint grants.
- Worker cannot list all packages.

### Claim contract

Workers must call `claim_work_key(secret, claimed_by)`. The `claimed_by`
identity is required so reconnect ownership is explicit; reconnects are accepted
only for the same owner identity and secret proof.

### Review package contract

Workers must include `submit_review_package.head_sha` on every submission. The
latest review package for that current head is authoritative for readiness;
older same-head packages are superseded.

For non-merge-gated package policies such as `quick_fix`, workers can satisfy
focused-test and review-lane gates with generic `append_progress.status` values
`tests_passed` and `<review_lane>_green`. Tool-owned metadata, blocker, status,
and scope events do not satisfy those fallback gates. Merge-gated package
policies still use current-head review package evidence and review artifacts.

After `mark_ready` succeeds, worker evidence writes for the package are frozen;
new progress, findings, blockers, branch/PR metadata, scope requests, and review
packages return `already_ready`. Investigation packages use
`request_scope_expansion` as the worker's recorded scope recommendation evidence;
the request itself does not approve any expanded scope.

## Deliverables

- Implementation PR for `SYMPP-P3-002`.
- Tests described above.
- Updated implementation notes if the worker discovers constraints.
- Clear PR summary mapping code changes to acceptance criteria.

## Suggested worker prompt

```text
You are assigned Symphony++ work package SYMPP-P3-002: Worker MCP tools and resources.

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

Package dependencies: SYMPP-P3-001, SYMPP-P1-004, SYMPP-P1-005.
```

## Review checklist

- [ ] Scope matches package and dependencies.
- [ ] Acceptance criteria are satisfied.
- [ ] Required tests were added/updated and run.
- [ ] Existing Symphony behavior was preserved where applicable.
- [ ] No raw secrets or sensitive credentials are logged or exposed.
- [ ] PR summary includes implementation notes, test results, and risks.
