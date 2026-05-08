# Symphony++

Symphony++ is a permissioned work-package control plane built on the OpenAI
Symphony Elixir runtime. Operators create bounded WorkPackages, mint scoped
worker or architect grants, expose package state as virtual planning files
through MCP, attach GitHub/review evidence, and gate readiness before human
merge.

The upstream Symphony runtime remains in `elixir/`. Symphony++ extends it with
WorkPackage ledger, access grant, MCP, dashboard, GitHub/review, and release
readiness surfaces without replacing the base Linear-oriented runtime docs.

## Start Here

- Runtime setup and workflow configuration: `elixir/README.md`
- Operator/product guide:
  `implementation_docs_symphplusplus/docs/01_IMPLEMENTATION_GUIDE.md`
- Current product and architecture contract:
  `implementation_docs_symphplusplus/docs/02_SYSTEM_SPEC.md`
- Operator flow: `implementation_docs_symphplusplus/docs/12_OPERATOR_TRAINING.md`
- Short operational runbook:
  `implementation_docs_symphplusplus/docs/09_OPERATIONAL_RUNBOOK.md`
- Codex plugin and private worker-secret handoff:
  `plugins/symphony-plus-plus/README.md`
- Release validation:
  `implementation_docs_symphplusplus/docs/11_RELEASE_VALIDATION.md`
- Security and guardrails:
  `implementation_docs_symphplusplus/docs/06_SECURITY_AND_GUARDRAILS.md`
- MCP and worker skill contract:
  `implementation_docs_symphplusplus/docs/04_MCP_AND_SKILL_CONTRACT.md`

For new Symphony++ work, start from a live WorkPackage or operator-approved
package request. Do not treat historical implementation phase notes as current
assignment scope.

## Validation

Run the full local gate from the repository root when `make` and `mix` are
already on `PATH`:

```powershell
make -C elixir all
```

If the Elixir toolchain is managed by `mise`, run the validated command from
the Elixir project:

```powershell
cd elixir
mise exec -- make all
```

See `implementation_docs_symphplusplus/docs/11_RELEASE_VALIDATION.md` for the
release checklist, coverage ratchet notes, and blocked-validation reporting
rules.

## Repository Map

- `elixir/` contains the runnable Symphony Elixir service and upstream runtime
  documentation.
- `.codex/skills/symphony-work-package/` contains the repo-local worker skill.
- `plugins/symphony-plus-plus/` contains the Codex-local plugin package for the
  same skill.
- `scripts/sympp-worker-secret.ps1` contains the Windows MCP bootstrap wrapper
  for worker secrets from Credential Manager or a local private file.
- `scripts/sympp-worker-secret.sh` contains the non-Windows local private-file
  MCP bootstrap wrapper for worker secrets.
- `implementation_docs_symphplusplus/docs/` contains the product, permission,
  MCP, dashboard, GitHub, operator, and release contracts.
- `implementation_docs_symphplusplus/runbooks/` contains operator runbooks.
- `implementation_docs_symphplusplus/review/` contains readiness and reviewer
  checklists.
- `implementation_docs_symphplusplus/templates/`, `schemas/`, and `mcp/`
  contain live templates and contracts used by operators and workers.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
