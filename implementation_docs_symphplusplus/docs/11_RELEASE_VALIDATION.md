# Release Validation

This release uses a truthful validation gate: the branch is release-ready when
the full Elixir gate passes, the coverage ratchet passes, and any remaining
known gaps are documented with evidence.

## Current release gate

Run from the repository root when `make` and `mix` are on `PATH`:

```powershell
make -C elixir all
```

If Elixir is managed by `mise` instead of being on `PATH`, pass the Mix command
through the Makefile:

```powershell
make -C elixir all MIX="mise exec -- mix"
```

That gate runs dependency setup, build, format check, lint/static checks,
coverage, and Dialyzer through the Elixir `Makefile`.

The Elixir lint/static step includes `mix code_quality.guard`. The Mix guard
scans backend and frontend source paths, applies separate production and test
line/function-complexity defaults, and keeps measured legacy oversize files in
an explicit ratchet allowlist. Frontend ESLint applies the matching
line/complexity defaults and legacy ratchets for JavaScript/TypeScript/React
sources through the existing `npm run quality` / `make -C elixir assets-check`
path. Legacy entries may shrink without an update, but growth beyond the
recorded value must be an intentional ratchet edit in the same PR.

When diagnosing a coverage-only change, run the coverage gate directly from the
Elixir project:

```powershell
cd elixir
mix test --cover
```

With `mise`:

```powershell
cd elixir
mise exec -- mix test --cover
```

The current coverage ratchet is the `test_coverage.summary.threshold` value in
`elixir/mix.exs`. It is intentionally near the current measured total coverage
so normal work cannot regress coverage while the release remains unblocked.

## Future strict coverage lane

`100%` coverage is not a current Symphony++ release-readiness blocker. Treat it
as a future strict/integration campaign with its own ownership, test strategy,
and review budget.

Before raising the ratchet, first land the coverage improvement that proves the
new level on the full suite. Then raise the threshold in a follow-up or the same
PR so the gate remains evidence-backed.

## Release-readiness evidence

A release candidate is honest only when the PR records:

- The exact `make -C elixir all` result, including any environment blocker.
- The exact `mix test --cover` result and coverage percentage.
- Lint/static gate results.
- Known gaps that are not being fixed in the release candidate.

## Release gate checklist

- `make -C elixir all` is green for the release candidate, or the PR records
  the exact environment blocker. Refresh this gate when a package touches
  runtime code, tests, build files, or release-critical policy.
- Coverage passes the ratchet in `elixir/mix.exs`. The ratchet is near current
  measured coverage; do not describe it as a full-coverage requirement.
- Required review-suite lanes from the package policy or PR assignment are
  complete for the current PR head.
- The PR diff is scoped to the assigned WorkPackage and owned paths.
- No raw secrets or secret-bearing URLs appear in committed files, PR text,
  logs, or review artifacts.
- Known limitations and any blocked validation are documented before merge.

## Known limitations

- Symphony++ readiness gates control Symphony++ package state; they do not
  replace GitHub branch protection or a human merge decision.
- Local filesystem isolation depends on the runner/worktree setup. Pair package
  scope with changed-file review and branch protection.
- Secret-dependent validation must be reported as blocked when safe test
  credentials are unavailable.
- Historical P0-P8 implementation backlog artifacts are not release inputs.
  Use current operator docs, live WorkPackage state, and PR evidence instead.
- The Kraken pilot playbook remains a historical/conditional pilot migration
  guide, not proof that all later migrations are production-ready.
- `100%` coverage is a future strict-coverage campaign, not a current release
  blocker.
