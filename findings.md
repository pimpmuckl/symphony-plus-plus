# Findings: SYMPP-P4-001

## Discovery

- `AGENTS.md` requires one package per PR, tight scope, concrete PR template evidence, no live Linear state, and no raw secrets in files/logs/PR/review text.
- Package spec requires a one-command/request standalone WorkPackage creation path with inputs for kind, repo, base branch, title, product description, engineering scope, acceptance criteria, and review-suite template.
- P1-002 is present as `AccessGrants.Service.mint_worker_grant/3` and stores only `secret_hash`; the raw `WorkKey.secret` is available only in the mint return.
- P1-003 is present as `Policies.Templates.expand/1`; current templates include `quick_fix`, `hotfix`, `standard_pr`, `phase_child`, `investigation`, plus P3 worker kinds.
- P1-004 is present as `Planning.Renderer.render_all/2` and virtual files include context, task plan, findings, progress, acceptance, review suite, and handoff.
- Existing operator-facing Symphony++ command pattern is `Mix.Tasks.Sympp.Mcp`; no product-specific HTTP API exists yet except observability routes.

## Decisions

- Implement service API plus Mix task instead of HTTP: the package allows command or endpoint, and a Mix task fits the existing Symphony++ command pattern without widening web/API scope.
- Treat `policy_template` / `review_suite_template` input as an explicit consistency check against the selected kind for now. The existing schema has no separate policy field, and P4-002 owns broader policy-template expansion.
- Create initial pending plan nodes from the requested engineering scope and acceptance/review expectation so `task_plan.md` is not empty on first render.

## Risks

- Real secret-dependent validation will be covered with generated test secrets only. No real worker secrets will be printed in planning, PR, or final text.
- `mix credo --strict` currently reports three pre-existing findings in `lib/symphony_elixir/symphony_plus_plus/mcp/server.ex` outside this package's touched files. The touched-file Credo lane passes with no issues.

## Review Findings

- T1 Alpha found two valid request-validation issues. Invariant: explicit template fields should match the selected policy, and acceptance criteria should be nonblank if provided. Owner/source of truth: `CreateWork.parse_request/1` backed by `Policies.Templates.expand/1`. Sibling paths checked: Mix task parsing delegates to `CreateWork.parse_file/1`, and worker MCP rendering consumes the created ledger state. Structural fix: accept either the kind or resolved template name for template fields, and reject blank/non-string criteria instead of dropping them. Regression coverage: `create_work_test.exs` covers `mcp` with `policy_template: worker_package` and blank criteria rejection.
- Follow-up review found a valid mixed-alias edge case where `policy_template` and `review_suite_template` could each use different valid aliases for the same resolved policy. Structural fix: validate each provided template field independently against `{kind, resolved_template}`. Regression coverage: the `mcp` request test now supplies both `review_suite_template: mcp` and `policy_template: worker_package`.
- T2 found four valid final-readiness issues: standalone packages were returned in non-dispatchable `created` status, `phase_child` could be created without a parent, the Mix task expanded SQLite special database names, and the task did not explicitly start Ecto SQL before starting the repo. Structural fix: create standalone packages directly as `ready_for_worker`, reject `phase_child`, preserve `:memory:`/`file:` SQLite names while preparing file URI parent dirs, and call `Application.ensure_all_started(:ecto_sql)` before repo startup. Regression coverage: service tests now assert ready status plus phase-child rejection, and Mix task tests cover SQLite special database preservation.
