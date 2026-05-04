# Hotfix Runbook

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

The investigation policy does not require a PR. It requires findings plus protected recommendation evidence recorded through `request_scope_expansion`; new recommendation events persist the canonical `recommendation.md` artifact, and prior protected recommendation events remain valid readiness evidence.
