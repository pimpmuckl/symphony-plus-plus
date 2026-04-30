# AGENTS.md — Symphony++ Implementation Conventions

## PR conventions

- One WorkPackage per PR.
- PR title format: `[SYMPP-...] <title>`.
- PR body must list acceptance criteria and tests run.
- Do not implement dependent packages unless explicitly assigned.
- Preserve upstream Symphony behavior unless the package says otherwise.

## Security conventions

- Never log raw grant secrets, bearer tokens, GitHub tokens, Linear tokens, or MCP auth tokens.
- Store only hashed/verifier forms of secrets.
- Server-side permission checks are mandatory for every Symphony++ API/MCP action.
- Worker grants are scoped to exactly one WorkPackage.

## Testing conventions

- Every implementation package must add or update tests matching the package's test plan.
- Existing tests must continue to pass.
- If a test cannot be run locally, document the exact reason in the PR summary.

## Documentation conventions

- Update implementation notes when discovering constraints.
- Keep `planning/Symphony-plus-plus/work_packages/00_INDEX.md` current if packages are split or merged.
