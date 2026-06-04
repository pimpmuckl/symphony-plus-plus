# Symphony++

Symphony++ is a product-tree cockpit and permissioned execution control plane
built on the OpenAI Symphony Elixir runtime. Operators and architects manage
WorkRequests as the product-facing unit, optionally organize them with nested
product plan nodes, dispatch planned slices to workers, and keep WorkPackages
as scoped execution/audit records with grants, evidence, reviews, and readiness
gates.

The upstream Symphony runtime remains in `elixir/`. Symphony++ extends it with
WorkRequest/product-tree projections, WorkPackage ledger records, access
grants, MCP, dashboard, GitHub/review, and release readiness surfaces without
replacing the base Linear-oriented runtime docs.

## Start Here

- Local operator golden path:
  `implementation_docs_symphplusplus/runbooks/LOCAL_OPERATOR_GOLDEN_PATH.md`
- Runtime setup and workflow configuration: `elixir/README.md`
- Operator/product guide:
  `implementation_docs_symphplusplus/docs/01_IMPLEMENTATION_GUIDE.md`
- V3 product-tree cockpit contract:
  `implementation_docs_symphplusplus/docs/V3_PRODUCT_TREE_REWORK.md`
- Current system and architecture contract:
  `implementation_docs_symphplusplus/docs/02_SYSTEM_SPEC.md`
- Solo Session local ledger contract:
  `implementation_docs_symphplusplus/docs/14_SOLO_SESSION_CONTRACT.md`
- Operator flow: `implementation_docs_symphplusplus/docs/12_OPERATOR_TRAINING.md`
- Short operational runbook:
  `implementation_docs_symphplusplus/docs/09_OPERATIONAL_RUNBOOK.md`
- Default Codex skill-only plugin reference:
  `plugins/symphony-plus-plus/README.md`
- Opt-in MCP plugin for WorkPackage/architect sessions:
  `plugins/symphony-plus-plus-mcp/README.md`
- Symphony++ operator documentation index:
  `implementation_docs_symphplusplus/README.md`
- Release validation:
  `implementation_docs_symphplusplus/docs/11_RELEASE_VALIDATION.md`
- Security and guardrails:
  `implementation_docs_symphplusplus/docs/06_SECURITY_AND_GUARDRAILS.md`
- MCP and worker skill contract:
  `implementation_docs_symphplusplus/docs/04_MCP_AND_SKILL_CONTRACT.md`
- Dashboard/operator cockpit:
  `implementation_docs_symphplusplus/docs/07_DASHBOARD_SPEC.md`
- V3 copied-ledger preview and cutover:
  `implementation_docs_symphplusplus/runbooks/V3_PRODUCT_TREE_CUTOVER.md`
- Execution Atlas brainstorm/design context:
  `implementation_docs_symphplusplus/docs/execution_atlas/README.md`

For new Symphony++ product work, start from a WorkRequest and use optional
product plan nodes only when they make progress clearer. For assigned worker
execution, start from the live WorkPackage claim. Do not treat historical
implementation phase notes or Execution Atlas brainstorms as current assignment
scope.

## Validation

Run the full local gate from the repository root when `make` and `mix` are
already on `PATH`:

```powershell
make -C elixir all
```

The aggregate gate is quiet by default and writes per-step logs under
`elixir/_build/make-logs/`. Use `VERBOSE=1` when you need the full Mix output
streamed to the console.

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
- `plugins/symphony-plus-plus/` contains the Codex-local skill-only plugin
  package; `plugins/symphony-plus-plus-mcp/` contains the opt-in MCP skill
  package for dedicated S++ sessions.
- Planned-slice worker dispatch uses ledger-backed `claim_local_assignment`. The
  worker-secret helper scripts remain explicit legacy/recovery bootstrap
  support after the ledger-claim cutover; they are not the normal worker path.
- Do not sync or refresh user-local plugin/cache installs during feature-branch
  work; local cache adoption happens at final feature-branch cutover.
- `implementation_docs_symphplusplus/docs/` contains the product-tree,
  permission, MCP, dashboard, GitHub, operator, release, and historical design
  context docs.
- `implementation_docs_symphplusplus/runbooks/` contains operator runbooks.
- `implementation_docs_symphplusplus/review/` contains readiness and reviewer
  checklists.
- `implementation_docs_symphplusplus/templates/`, `schemas/`, and `mcp/`
  contain live templates and contracts used by operators and workers.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
