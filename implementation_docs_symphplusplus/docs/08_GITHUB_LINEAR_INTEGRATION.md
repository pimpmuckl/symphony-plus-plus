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

Webhook-driven sync may be added by a package that owns that behavior. Current
operator docs should treat fetched or recorded GitHub snapshots as the evidence
available to Symphony++.

```text
pull_request opened/synchronize/closed
pull_request_review submitted
pull_request_review_comment created
check_suite/check_run completed
push
```

Polling remains an acceptable synchronization mode when webhook delivery is not
configured.

For the local operator dashboard, periodic PR merge reconciliation first uses
the already-authenticated GitHub CLI (`gh pr view ... --json ...`). This keeps
local auto-sync aligned with the operator's existing `gh auth` session instead
of requiring `GITHUB_TOKEN` or `GH_TOKEN` in the Symphony++ server process.
Server or remote deployments can still configure the HTTP GitHub client and use
token-backed API access.

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
