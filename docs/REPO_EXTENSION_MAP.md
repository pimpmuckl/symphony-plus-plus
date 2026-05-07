# Repository Extension Map

This map records the current upstream Symphony Elixir implementation seams for
Symphony++ planning. It is analysis only: do not treat any proposed module name
below as implemented by this package.

## Baseline Status

- Reference implementation: `elixir/`.
- Upstream behavior to preserve: Linear polling, normalized Linear issues,
  workspace creation, Codex app-server runs, retry/reconciliation semantics,
  dashboard/API observability, and the existing `linear_graphql` dynamic tool.
- Runtime setup lives in `elixir/README.md`; current release validation lives
  in `implementation_docs_symphplusplus/docs/11_RELEASE_VALIDATION.md`.
- Secret rule: do not print, log, commit, or mirror raw Linear/API token values.

## Current Runtime Map

| Area | Current files/modules | Notes |
|---|---|---|
| OTP app startup | `elixir/lib/symphony_elixir.ex` | Starts PubSub, task supervisor, `WorkflowStore`, `Orchestrator`, `HttpServer`, and `StatusDashboard`. |
| CLI | `elixir/lib/symphony_elixir/cli.ex` | Selects `WORKFLOW.md`, `--logs-root`, `--port`, and guardrail acknowledgement before app startup. |
| Workflow loading | `elixir/lib/symphony_elixir/workflow.ex`, `elixir/lib/symphony_elixir/workflow_store.ex` | Parses YAML front matter and prompt body; store keeps last known good workflow on reload failures. |
| Config schema | `elixir/lib/symphony_elixir/config.ex`, `elixir/lib/symphony_elixir/config/schema.ex` | Ecto embedded schemas only; validates tracker kind, Linear credentials, concurrency, hooks, server, worker, and Codex settings. |
| Tracker boundary | `elixir/lib/symphony_elixir/tracker.ex` | Behaviour/facade for candidate fetch, state refresh, comment create, and state update. |
| Linear adapter | `elixir/lib/symphony_elixir/linear/adapter.ex`, `elixir/lib/symphony_elixir/linear/client.ex`, `elixir/lib/symphony_elixir/linear/issue.ex` | GraphQL polling, pagination, issue normalization, labels/blockers, comments, state updates. |
| Test tracker | `elixir/lib/symphony_elixir/tracker/memory.ex` | In-memory adapter for tests/local development. |
| Orchestrator state | `elixir/lib/symphony_elixir/orchestrator.ex` | Owns poll ticks, active/retry/claimed state, reconciliation, dispatch, stalls, token/rate-limit aggregation, and snapshots. |
| Agent execution | `elixir/lib/symphony_elixir/agent_runner.ex` | Creates workspace, runs hooks, starts Codex session, loops turns, refreshes issue state. |
| Workspaces | `elixir/lib/symphony_elixir/workspace.ex`, `elixir/lib/symphony_elixir/path_safety.ex`, `elixir/lib/symphony_elixir/ssh.ex` | Creates/removes per-issue local or SSH workspaces with root containment and lifecycle hooks. |
| Codex app-server client | `elixir/lib/symphony_elixir/codex/app_server.ex` | Starts thread/turn, handles approvals, tool calls, timeouts, and stream events; launches locally via `bash -lc` or remotely through `SSH.start_port/2` for worker-host runs. |
| Dynamic tools | `elixir/lib/symphony_elixir/codex/dynamic_tool.ex` | Exposes the existing app-server client-side `linear_graphql` tool. This is not an MCP server. |
| Dashboard/API | `elixir/lib/symphony_elixir/http_server.ex`, `elixir/lib/symphony_elixir_web/router.ex`, `elixir/lib/symphony_elixir_web/controllers/observability_api_controller.ex`, `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`, `elixir/lib/symphony_elixir_web/presenter.ex` | Configurable Phoenix LiveView/API surface for runtime snapshots and refresh requests; the app starts `HttpServer`/`StatusDashboard`, with the HTTP endpoint enabled by server port config. |
| Terminal status | `elixir/lib/symphony_elixir/status_dashboard.ex` | Human-readable terminal status projection. |
| Logging | `elixir/lib/symphony_elixir/log_file.ex`, `elixir/docs/logging.md` | Rotating OTP disk log handler; no ledger persistence. |

## Persistence And Test Conventions

- There is no `Ecto.Repo`, migration directory, or database-backed table in the
  current fork. `Ecto.Schema` is used for config embedded schemas in
  `Config.Schema`.
- Durable runtime artifacts today are `WORKFLOW.md`, per-issue workspaces, disk
  logs, and test fixtures/snapshots.
- Main quality gate is `make -C elixir all` or `make all` from `elixir/`.
- Public `def` functions under `elixir/lib/` require adjacent `@spec`
  entries unless covered by the existing `@impl` or explicit exemption paths in
  `Mix.Tasks.Specs.Check` / `SymphonyElixir.SpecsCheck`.
- Key test files for future seam work:
  - Tracker/config/normalization: `elixir/test/symphony_elixir/core_test.exs`,
    `extensions_test.exs`, `workspace_and_config_test.exs`.
  - Orchestrator/runtime state: `core_test.exs`,
    `orchestrator_status_test.exs`, `live_e2e_test.exs`.
  - Workspace/SSH/config: `workspace_and_config_test.exs`, `ssh_test.exs`,
    `cli_test.exs`.
  - Codex/dynamic tools: `app_server_test.exs`, `dynamic_tool_test.exs`.
  - Dashboard/API: `orchestrator_status_test.exs`,
    `status_dashboard_snapshot_test.exs`, `observability_pubsub_test.exs`.

## Extension Seams

### WorkPackage Ledger

Recommended namespace:

- `SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage`
- `SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository`
- `SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service`
- `SymphonyElixir.SymphonyPlusPlus.AccessGrants.*`
- `SymphonyElixir.SymphonyPlusPlus.AuditEvents.*`

Current seam:

- Add new persistence infrastructure beside, not inside, the Linear adapter.
- Keep `SymphonyElixir.Linear.Issue` as the current normalized dispatch shape
  until the tracker adapter package introduces a shared issue abstraction.
- Do not store raw grant secrets; store hashes and expose display keys only.

Risks:

- Introducing a database changes app startup and tests; this must not make
  existing Linear-only startup unusable.
- Ledger state is the Symphony++ source of truth, but GitHub remains the source
  of truth for branches/PRs/CI/reviews.

Test strategy:

- Repository unit tests for create/get/list/update and invalid status/kind.
- Migration or storage setup test if a database is selected.
- Existing `make -C elixir all` must keep Linear/config/orchestrator behavior
  green.

### `tracker.kind: Symphony_pp`

Recommended namespace:

- `SymphonyElixir.SymphonyPlusPlus.Tracker.Adapter`
- `SymphonyElixir.SymphonyPlusPlus.Tracker.IssueMapper`

Current seam:

- `Config.validate!/0` currently accepts only `linear` and `memory`.
- `Tracker.adapter/0` currently routes `memory` explicitly and all other kinds
  to `SymphonyElixir.Linear.Adapter`.
- Add `Symphony_pp` validation and adapter routing in the same change so an
  unsupported kind cannot silently fall through to Linear.
- Preserve existing `linear` and `memory` behavior and tests.

Risks:

- Tracker kind naming is compatibility-sensitive. Do not normalize or rename
  the requested `Symphony_pp` value without explicit architectural approval.
- The live orchestrator and agent runner currently pattern-match on
  `%SymphonyElixir.Linear.Issue{}` in dispatch, reconciliation, and
  continuation paths; tests and helpers also depend on that struct. Changing
  the normalized issue model is broader than the adapter package unless
  deliberately approved.

Test strategy:

- Config tests for `linear`, `memory`, `Symphony_pp`, missing kind, and invalid
  kind.
- Adapter routing tests proving `linear` still resolves to Linear and
  `Symphony_pp` resolves to the new adapter.
- Mapper tests from WorkPackage ledger records to normalized dispatch issues.
- Orchestrator polling test with test Symphony++ packages.

### MCP Server

Recommended namespace:

- `SymphonyElixir.SymphonyPlusPlus.MCP.Server`
- `SymphonyElixir.SymphonyPlusPlus.MCP.Auth`
- `SymphonyElixir.SymphonyPlusPlus.MCP.Resources`
- `SymphonyElixir.SymphonyPlusPlus.MCP.Tools`

Current seam:

- There is no standalone MCP server in this fork.
- The closest existing agent-tool seam is `Codex.DynamicTool`, which advertises
  app-server dynamic tools during `thread/start`.
- MCP should call ledger/access-grant services directly instead of depending on
  Linear or the dashboard presenter.

Risks:

- Confusing app-server dynamic tools with MCP would blur authentication and
  permission boundaries.
- MCP resources must enforce grant scope server-side; hooks and skills are only
  reminders, not authorization.

Test strategy:

- Server starts in test mode.
- Missing/invalid grant denies access without listing packages.
- Resource/tool tests for current assignment and virtual planning files.
- Secret redaction tests for grant/work-key input paths.

### Dashboard/API

Recommended namespace:

- `SymphonyElixir.SymphonyPlusPlusWeb.WorkPackageController`
- `SymphonyElixir.SymphonyPlusPlusWeb.BoardLive`
- `SymphonyElixir.SymphonyPlusPlusWeb.WorkPackageLive`
- `SymphonyElixir.SymphonyPlusPlusWeb.Presenter`

Current seam:

- Existing dashboard/API is runtime-observability-only and is backed by
  `Orchestrator.snapshot/2`.
- `Router` already owns `/`, `/api/v1/state`, `/api/v1/refresh`, and
  `/api/v1/:issue_identifier`.
- Symphony++ board/detail views should use ledger read models, while runtime
  panels can continue to consume orchestrator snapshots.

Risks:

- Do not collapse readiness signals into one boolean; implementation docs split
  agent, review-suite, GitHub, architect, and human readiness.
- Avoid changing current `/api/v1/state` semantics while adding ledger routes.

Test strategy:

- Presenter tests for ledger board/detail payloads.
- Controller/LiveView tests for no unauthenticated package disclosure.
- Existing observability API and snapshot tests must keep passing.

### GitHub Sync

Recommended namespace:

- `SymphonyElixir.SymphonyPlusPlus.GitHub.Client`
- `SymphonyElixir.SymphonyPlusPlus.GitHub.Sync`
- `SymphonyElixir.SymphonyPlusPlus.GitHub.Webhook`
- `SymphonyElixir.SymphonyPlusPlus.ReviewSuite.Artifacts`

Current seam:

- No GitHub client/sync implementation exists in the Elixir runtime.
- PR/review state should attach to WorkPackage ledger records and be keyed by
  PR/head SHA.
- GitHub is the source of truth for branches, PRs, commits, changed files, CI,
  reviews, and merge state.

Risks:

- Cached GitHub data must be marked as fetched/webhook-derived snapshots, not
  treated as intrinsically current.
- PR bodies and review artifacts must never include raw grant secrets.

Test strategy:

- Client tests with canned GitHub payloads.
- Sync idempotency tests keyed by delivery/event IDs.
- Readiness tests proving stale review/CI artifacts for an old head SHA do not
  satisfy gates.

## Phase Assignment Guidance

1. Build the WorkPackage ledger first as a new persistence boundary.
2. Add AccessGrant/work-key services before worker-facing MCP tools.
3. Add virtual planning file renderers on top of ledger state.
4. Add `tracker.kind: Symphony_pp` only after ledger and lifecycle state exist.
5. Add MCP server tools/resources after grant enforcement exists.
6. Extend dashboard/API after ledger read models exist.
7. Add GitHub sync after PR attachment conventions and review artifacts exist.

This sequencing preserves the current Linear runtime while creating explicit
Symphony++ seams for later packages.
