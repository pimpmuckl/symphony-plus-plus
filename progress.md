# Progress: SYMPP-P4-001

## 2026-05-03

- Read `planning-with-files`, `review-suite`, and `symphony-work-package` skill instructions. Assignment explicitly requires local planning files in this worktree, so local planning files are being used for this package.
- Read package spec and repo instructions.
- Confirmed branch is `agent/SYMPP-P4-001/standalone-create-work-cli-api` tracking `symphony-plus-plus/beta`.
- Confirmed dependency surfaces exist: WorkPackage ledger, AccessGrant worker minting, policy templates, and virtual planning renderer.
- Chose the smallest existing-pattern surface: reusable create-work service API plus `mix sympp.create_work` command.
- Implemented `SymphonyElixir.SymphonyPlusPlus.CreateWork` and `mix sympp.create_work`.
- Added focused create-work service and Mix task tests.
- Added quick-fix YAML example and updated the hotfix runbook with create-work command examples and one-time secret semantics.

## Validation

| Command | Result | Notes |
|---|---|---|
| `mise trust` | pass | Trusted this worktree's `elixir/mise.toml`. |
| `mise exec -- mix deps.get` | pass | Fetched dependencies for this worktree. |
| `mise exec -- mix format` | pass | Ran after implementation and final test cleanup. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | 8 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | 329 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | All public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | No formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex lib/mix/tasks/sympp.create_work.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | 4 touched source/test files, no issues. |
| `mise exec -- mix credo --strict` | blocked | Reports three existing `mcp/server.ex` refactoring findings outside this package scope. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | T2 fix validation: 11 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | T2 fix validation: 331 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | T2 fix validation: all public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | T2 fix validation: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex lib/mix/tasks/sympp.create_work.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | T2 fix validation: 4 touched source/test files, no issues. |
| `mise exec -- mix credo --strict` | blocked | T2 fix validation: same three existing `mcp/server.ex` refactoring findings outside package scope. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Cached T2 rerun fix validation: 12 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | Cached T2 rerun fix validation: 331 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | Cached T2 rerun fix validation: all public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | Cached T2 rerun fix validation: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex lib/mix/tasks/sympp.create_work.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Cached T2 rerun fix validation: 4 touched source/test files, no issues. |
| `mise exec -- mix credo --strict` | blocked | Cached T2 rerun fix validation: same three existing `mcp/server.ex` refactoring findings outside package scope. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Latest cached T2 fix validation: 13 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | Latest cached T2 fix validation: 332 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | Latest cached T2 fix validation: all public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | Latest cached T2 fix validation: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex lib/mix/tasks/sympp.create_work.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Latest cached T2 fix validation: 4 touched source/test files, no issues. |
| `mise exec -- mix credo --strict` | blocked | Latest cached T2 fix validation: same three existing `mcp/server.ex` refactoring findings outside package scope. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Template-selection/workflow-restore fix validation: 14 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | Template-selection/workflow-restore fix validation: 333 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | Template-selection/workflow-restore fix validation: all public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | Template-selection/workflow-restore fix validation: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex lib/mix/tasks/sympp.create_work.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Template-selection/workflow-restore fix validation: 4 touched source/test files, no issues. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Template-consistency fix validation: 14 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | Template-consistency fix validation: 333 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | Template-consistency fix validation: all public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | Template-consistency fix validation: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex lib/mix/tasks/sympp.create_work.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Template-consistency fix validation: 4 touched source/test files, no issues. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Planning-content fix validation: 15 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | Planning-content fix validation: 334 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | Planning-content fix validation: all public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | Planning-content fix validation: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex lib/mix/tasks/sympp.create_work.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Planning-content fix validation: 4 touched source/test files, no issues. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | CLI/input edge validation: 16 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | CLI/input edge validation: 334 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | CLI/input edge validation: all public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | CLI/input edge validation: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex lib/mix/tasks/sympp.create_work.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | CLI/input edge validation: 4 touched source/test files, no issues. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/symphony_elixir/symphony_plus_plus/work_packages_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Allowed-file-globs fix validation: 28 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | Allowed-file-globs fix validation: 336 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | Allowed-file-globs fix validation: all public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | Allowed-file-globs fix validation: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex lib/mix/tasks/sympp.create_work.ex lib/symphony_elixir/symphony_plus_plus/work_packages/work_package.ex lib/symphony_elixir/symphony_plus_plus/planning/renderer.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/symphony_elixir/symphony_plus_plus/work_packages_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Allowed-file-globs fix validation: 7 touched source/test files, no issues. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/symphony_elixir/symphony_plus_plus/work_packages_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Invalid-request/no-ledger and inert-glob rendering fix validation: 29 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | Invalid-request/no-ledger and inert-glob rendering fix validation: 336 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | Invalid-request/no-ledger and inert-glob rendering fix validation: all public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | Invalid-request/no-ledger and inert-glob rendering fix validation: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex lib/mix/tasks/sympp.create_work.ex lib/symphony_elixir/symphony_plus_plus/work_packages/work_package.ex lib/symphony_elixir/symphony_plus_plus/planning/renderer.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/symphony_elixir/symphony_plus_plus/work_packages_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Invalid-request/no-ledger and inert-glob rendering fix validation: 7 touched source/test files, no issues. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Acceptance-less quick-fix regression: 12 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/symphony_elixir/symphony_plus_plus/work_packages_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Acceptance-less quick-fix regression: 30 tests, 0 failures. |
| `mise exec -- mix format --check-formatted` | pass | Acceptance-less quick-fix regression: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Acceptance-less quick-fix regression: touched files, no issues. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Acceptance-less quick-fix persistence/render strengthening: 12 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/symphony_elixir/symphony_plus_plus/work_packages_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Acceptance-less quick-fix persistence/render strengthening: 30 tests, 0 failures. |
| `mise exec -- mix format --check-formatted` | pass | Acceptance-less quick-fix persistence/render strengthening: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Acceptance-less quick-fix persistence/render strengthening: touched files, no issues. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Kind/template parser fix validation: 12 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/symphony_elixir/symphony_plus_plus/work_packages_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Kind/template parser fix validation: 30 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | Kind/template parser fix validation: 337 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | Kind/template parser fix validation: all public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | Kind/template parser fix validation: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Kind/template parser fix validation: touched files, no issues. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Initial task-plan wording fix validation: 12 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/symphony_elixir/symphony_plus_plus/work_packages_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Initial task-plan wording fix validation: 30 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | Initial task-plan wording fix validation: 337 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | Initial task-plan wording fix validation: all public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | Initial task-plan wording fix validation: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Initial task-plan wording fix validation: touched files, no issues. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Policy-template persistence fix validation: 13 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/symphony_elixir/symphony_plus_plus/work_packages_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Policy-template persistence fix validation: 31 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/lifecycle_test.exs test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Policy-template persistence fix validation: 40 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | Policy-template persistence fix validation: 338 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | Policy-template persistence fix validation: all public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | Policy-template persistence fix validation: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex lib/symphony_elixir/symphony_plus_plus/policies/templates.ex lib/symphony_elixir/symphony_plus_plus/work_packages/work_package.ex lib/symphony_elixir/symphony_plus_plus/lifecycle/service.ex lib/symphony_elixir/symphony_plus_plus/planning/renderer.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Policy-template persistence fix validation: touched files, no issues. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Lifecycle-kind/template consistency fix validation: 13 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/create_work_test.exs test/symphony_elixir/symphony_plus_plus/work_packages_test.exs test/mix/tasks/sympp_create_work_test.exs` | pass | Lifecycle-kind/template consistency fix validation: 31 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus/lifecycle_test.exs test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Lifecycle-kind/template consistency fix validation: 40 tests, 0 failures. |
| `mise exec -- mix test test/symphony_elixir/symphony_plus_plus` | pass | Lifecycle-kind/template consistency fix validation: 338 tests, 0 failures. |
| `mise exec -- mix specs.check` | pass | Lifecycle-kind/template consistency fix validation: all public functions have specs or exemption. |
| `mise exec -- mix format --check-formatted` | pass | Lifecycle-kind/template consistency fix validation: no formatting drift. |
| `mise exec -- mix credo --strict lib/symphony_elixir/symphony_plus_plus/create_work.ex lib/symphony_elixir/symphony_plus_plus/policies/templates.ex lib/symphony_elixir/symphony_plus_plus/work_packages/work_package.ex lib/symphony_elixir/symphony_plus_plus/lifecycle/service.ex lib/symphony_elixir/symphony_plus_plus/planning/renderer.ex test/symphony_elixir/symphony_plus_plus/create_work_test.exs` | pass | Lifecycle-kind/template consistency fix validation: touched files, no issues. |

## Review

- T1 round `phase_review-symphony-plus-plus-sympp-p4-001-1de35c-20260503T164350Z-62704a67`: Bravo clean; Alpha found valid template-name and blank-acceptance validation issues. Graded Alpha as winner for better bug coverage.
- Applied narrow validation fixes and added regression coverage.
- Post-fix validation: focused create-work tests now run 9 tests, 0 failures; `test/symphony_elixir/symphony_plus_plus` now runs 330 tests, 0 failures; touched-file strict Credo remains clean.
- Follow-up review session `019deec0-2e7f-77a1-809e-cdbf253f2985` found one valid mixed-template-alias edge case. Applied a per-field alias validation fix and extended the regression test.
- T2 round `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T165448Z-9ac9450c` found valid readiness issues around dispatchable status, `phase_child` rejection, SQLite special database handling, and Mix task repo dependency startup. Applied narrow fixes in the create-work service and Mix task and added regression coverage.
- Cached follow-up session `019deecd-c77a-7e53-900d-e437463df05b` returned no findings for the dispatchable-status/SQLite/dependency-startup fix.
- Cached T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T170715Z-bee435ee` found valid workflow issues for omitted-`--database` default ledger selection and missing criteria on `package_acceptance` kinds. Closed the gate as findings and applied narrow fixes with regression coverage.
- Cached T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T171824Z-1a29e29e` found valid edge cases for preconfigured workflow leakage and blank explicit IDs. Closed the gate as findings and applied narrow fixes with regression coverage.
- Cached T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T172442Z-28f54e48` found valid issues for policy-template fields being no-ops and workflow path mutation leaking after default database resolution. Closed the gate as findings and applied narrow fixes with regression coverage.
- Cached T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T173315Z-d2489c30` found a valid downstream inconsistency if explicit templates select a policy that does not match persisted `kind`. Closed the gate as findings and changed template fields back to strict consistency assertions for `kind`.
- Cached T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T173958Z-e94af471` found valid initial planning content issues for investigation packages and whitespace-only engineering scope. Closed the gate as findings and applied narrow rendering-input fixes with regression coverage.
- Cached T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T174643Z-49be956f` found valid CLI/input edge cases for global database override leakage, blank explicit `--database`, and nil YAML `acceptance_criteria`. Closed the gate as findings and applied narrow parsing/default fixes with regression coverage.
- Cached full-diff T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T180145Z-4258864b` found a valid scope-preservation issue for documented `allowed_file_globs`. Closed the gate as findings and applied a persisted WorkPackage field plus rendering/regression coverage.
- Cached full-diff T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T181222Z-31be8eaf` found valid request-side-effect and inert-rendering issues. Closed the gate as findings and applied narrow fixes with regression coverage.
- Cached full-diff T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T182047Z-024f3c39` returned clean and was anchored on head `dff32133351ac6336223967a97fa74fda30a516e`.
- Cached GitHub review returned clean on PR #19 at `https://github.com/Pimpmuckl/symphony-plus-plus/pull/19#issuecomment-4366867995`.
- Final cached `review_state` after GitHub review: `recommendation: none` for head `dff32133351ac6336223967a97fa74fda30a516e`.
- Cached full-diff T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T183448Z-82b38779` flagged acceptance-less quick-fix persistence; added explicit regression coverage for the accepted/persisted quick-fix path.
- Cached follow-up `019def24-cfe9-7d53-83c3-27c1c0042e2d` found the acceptance-less quick-fix regression needed to prove ledger reload/rendering. Updated the test to reload the persisted WorkPackage and render `acceptance.md` from repository state.
- Cached follow-up `019def26-9112-74c1-befe-0054773bbc7e` returned no findings for the strengthened acceptance-less quick-fix regression.
- Cached full-diff T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T184341Z-c43a17cd` found explicit invalid-kind defaulting and limited explicit-template selection. Closed the gate as findings and applied a narrow parser fix: absent kind can select a known explicit template, explicit malformed kind is rejected, and cross-kind overrides remain rejected.
- Cached follow-up `019def2f-f6c7-7971-bb17-7629b41144ad` returned no findings for the kind/template parser fix.
- Cached full-diff T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T185347Z-f66046c4` found initial task plan wording issues for investigation packages and policy gate labels. Closed the gate as findings and patched the seeded plan title/label with regression assertions.
- Cached full-diff T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T190239Z-cd4a85a0` found policy/template split issues for valid non-policy `kind` values plus malformed template fields. Closed the gate as findings and patched WorkPackage policy-template persistence, renderer/lifecycle policy lookup, typed template resolution, and regression coverage.
- Cached full-diff T2 rerun `phase_gate-symphony-plus-plus-sympp-p4-001-1de35c-20260503T191407Z-19ceeba8` found valid runtime consistency issues for lifecycle-unsupported kinds, cross-kind policy overrides, and single-field `worker_package` aliases. Closed the gate as findings and patched create-work to require lifecycle-supported standalone kinds, same-kind policy resolution, and kind-assisted alias disambiguation.

## Outstanding

- Commit/push lifecycle-kind/template consistency fix, then rerun cached review-state/T2/GitHub lanes on the final pushed head.
