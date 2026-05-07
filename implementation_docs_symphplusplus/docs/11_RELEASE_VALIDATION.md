# Release Validation

This release uses a truthful validation gate: the branch is release-ready when
the full Elixir gate passes, the coverage ratchet passes, and any remaining
known gaps are documented with evidence.

## Current release gate

Run from the repository root:

```powershell
make -C elixir all
```

That gate runs dependency setup, build, format check, lint/static checks,
coverage, and Dialyzer through the Elixir `Makefile`.

When diagnosing a coverage-only change, run the coverage gate directly:

```powershell
cd elixir
mix test --cover
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
