# Symphony++ Repository Conventions

## Work Package PRs

- Use one Symphony++ work package per PR unless the overseeing architecture agent explicitly splits or combines scope.
- Keep each worker branch scoped to its assigned package and ignore sibling worktrees or branches.
- Use PR titles in the form `[SYMPP-...] <title>`.
- Fill `.github/pull_request_template.md` concretely, including acceptance evidence, tests run, and any blocked validation.
- Do not implement dependent packages or adjacent cleanup unless the architecture agent explicitly expands scope.

## Planning Assets

- Treat `implementation_docs_symphplusplus/` as the stable planning package location.
- Use `implementation_docs_symphplusplus/work_packages/00_INDEX.md` as the architecture queue.
- Use the matching file in `implementation_docs_symphplusplus/work_packages/` as the source of truth for package scope, acceptance criteria, and test plan.
- Keep `implementation_docs_symphplusplus/templates/WORKFLOW.symfony_pp.md` as a draft template until a later package wires Symphony++ runtime behavior.

## Runtime Boundary

- Preserve upstream Symphony and Linear behavior unless the assigned package explicitly changes it.
- Do not replace `elixir/WORKFLOW.md` with the Symphony++ draft workflow template.
- Do not wire unfinished Symphony++ config into runtime defaults.
- Do not create live Linear state unless the assigned package and operator explicitly require it.

## Security

- Never commit, print, or place raw API keys, bearer tokens, GitHub tokens, Linear tokens, MCP auth tokens, or worker secrets in files, prompts, logs, PR bodies, or review text.
- Document missing secret-dependent validation as blocked rather than substituting real token values.
