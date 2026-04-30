# GitHub and Linear Integration

## GitHub role

GitHub is the source of truth for:

- Branches.
- PRs.
- Commits.
- Changed files.
- CI/check results.
- Reviews.
- Merge state.

Symphony++ should store synchronized snapshots and artifacts, but not pretend GitHub state is true unless it has been fetched or received via webhook.

## PR linking convention

PR title:

```text
[SYMPP-P6-001] GitHub PR attachment and sync
```

PR body:

```markdown
Symphony-WorkPackage: SYMPP-P6-001
Symphony-Kind: standard_pr
```

Never put the raw grant secret in the PR.

## GitHub sync events

Eventually webhook-driven:

```text
pull_request opened/synchronize/closed
pull_request_review submitted
pull_request_review_comment created
check_suite/check_run completed
push
```

MVP can start with polling.

## Review suite integration

Review-suite artifacts should be attached to the work package and keyed by PR head SHA.

Readiness should fail if the attached artifact is for an old head SHA.

## Linear role

Linear is optional and should be a mirror, not the source of truth for agent permissions.

Mapping:

```text
Program -> Linear Initiative
Phase -> Linear Project
WorkPackage -> Linear Issue
Progress checkpoint -> Linear comment or project update
Blocker -> Linear label/comment
```

Workers should not receive broad Linear access. They should go through Symphony++.
