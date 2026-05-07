# Hotfix Runbook

Use this runbook for standalone hotfix packages. Use
`../docs/12_OPERATOR_TRAINING.md` first if you need the broader role and gate
context.

1. Create hotfix work package with one standalone command:
   `cd elixir && mise exec -- mix sympp.create_work --database <ledger.sqlite3> --file ../implementation_docs_symphplusplus/templates/create_work_package.hotfix.example.yaml`
2. Confirm base branch is correct.
3. Confirm acceptance criteria are narrow and testable.
4. Dispatch worker with the returned one-time `worker_grant.secret`; normal package reads and virtual file renders do not expose it again.
5. Have the worker claim with `claim_work_key(secret, claimed_by)`.
6. Watch progress timeline.
7. Require PR and hotfix review-suite artifact.
8. Review scope guard and changed files.
9. Human merges after branch protection passes.
10. Close package and archive evidence.

## Hotfix package checklist

- Copy `../templates/create_work_package.hotfix.example.yaml` before editing
  incident-specific values.
- Include the repository, base branch, owned paths, acceptance criteria, test
  plan, and review-suite requirement in the package.
- Keep the worker grant secret out of committed files, logs, PR bodies, and
  durable review text.
- Require the worker to attach the PR URL and current head SHA before readiness.
- Confirm review evidence applies to the current PR head, not an older commit.
- Record any skipped validation as blocked with the exact blocker and owner.

## Worker handoff

Send the worker only what they need:

- WorkPackage id, base branch, target branch, and PR title convention.
- The private one-time work key secret and stable `claimed_by` identity.
- The package scope, owned files, acceptance criteria, and stop conditions.
- The validation target and required review lanes.
- A reminder that raw secrets must not be printed, committed, or placed in PR
  and review text.

## Quick-Fix Example

Create a quick-fix package with:

```bash
cd elixir
mise exec -- mix sympp.create_work --database <ledger.sqlite3> --file ../implementation_docs_symphplusplus/templates/create_work_package.quick_fix.example.yaml
```

The command creates a parentless WorkPackage, applies the `quick_fix` policy, renders the initial virtual planning files, and returns the worker grant secret only in that creation response.

## Investigation Example

Create an investigation package with:

```bash
cd elixir
mise exec -- mix sympp.create_work --database <ledger.sqlite3> --file ../implementation_docs_symphplusplus/templates/create_work_package.investigation.example.yaml
```

The investigation policy does not require a PR. It requires findings plus the canonical `recommendation.md` artifact recorded through `request_scope_expansion`; stored legacy recommendation events do not satisfy readiness unless that canonical artifact already exists.
