defmodule SymphonyElixir.SymphonyPlusPlus.DashboardApiTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.FakeAuthenticatedGitHubClient
  alias SymphonyElixir.FakeGhCli
  alias SymphonyElixir.FakeGitHubClient
  alias SymphonyElixir.GitHubPullRequestFixtures
  alias SymphonyElixir.GitHubTestSupport
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Repository, as: GuidanceRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Service, as: OperatorSettingsService
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SecretHandoff
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service, as: SoloSessionsService
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.ReactDashboardController
  alias SymphonyElixirWeb.SymppDashboardApiController

  @endpoint SymphonyElixirWeb.Endpoint
  @dashboard_phase_id "phase-dashboard-test"
  @repo_root Path.expand("../../../../", __DIR__)

  defmodule BusyRepo do
    @moduledoc false

    def all(_query), do: raise(%Exqlite.Error{message: "database is locked"})
    def one(_query), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule LockedPhaseAnchorRepo do
    @moduledoc false

    @grant_key {__MODULE__, :grant}

    def put_grant(%AccessGrant{} = grant), do: :persistent_term.put(@grant_key, grant)
    def clear_grant, do: :persistent_term.erase(@grant_key)

    def one(_query), do: :persistent_term.get(@grant_key)
    def get(AccessGrant, _id), do: :persistent_term.get(@grant_key)
    def get(WorkPackage, _id), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule MissingCustomRepo do
    @moduledoc false

    def __adapter__, do: Ecto.Adapters.SQLite3
    def config, do: [database: SymphonyElixir.WorkPackageFactory.database_path()]
    def start_link(_opts), do: raise("custom repo should not start for invalid bearer probes")
  end

  defmodule CountingRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def all(query) do
      count_artifact_list_query(query)
      Repo.all(query)
    end

    def one(query), do: Repo.one(query)
    def get(queryable, id), do: Repo.get(queryable, id)
    def transaction(fun), do: Repo.transaction(fun)

    def counter(counter), do: :persistent_term.put({__MODULE__, :counter}, counter)
    def clear_counter, do: :persistent_term.erase({__MODULE__, :counter})

    defp count_artifact_list_query(%Ecto.Query{from: %{source: {"sympp_artifacts", _schema}}, order_bys: [_ | _]}) do
      case :persistent_term.get({__MODULE__, :counter}, nil) do
        nil -> :ok
        counter -> Agent.update(counter, &(&1 + 1))
      end
    end

    defp count_artifact_list_query(_query), do: :ok
  end

  defmodule WorkRequestCardCountingRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.Repo

    @counted_tables [
      "sympp_work_requests",
      "sympp_work_request_clarification_questions",
      "sympp_work_request_decision_logs",
      "sympp_work_request_planned_slices",
      "sympp_work_request_planned_slice_deliveries",
      "sympp_comments"
    ]

    def all(query) do
      count_query(query)
      Repo.all(query)
    end

    def one(query), do: Repo.one(query)
    def get(queryable, id), do: Repo.get(queryable, id)
    def transaction(fun), do: Repo.transaction(fun)

    def counter(counter), do: :persistent_term.put({__MODULE__, :counter}, counter)
    def clear_counter, do: :persistent_term.erase({__MODULE__, :counter})

    defp count_query(%Ecto.Query{from: %{source: {table, _schema}}}) when table in @counted_tables do
      case :persistent_term.get({__MODULE__, :counter}, nil) do
        nil -> :ok
        counter -> Agent.update(counter, &Map.update(&1, table, 1, fn count -> count + 1 end))
      end
    end

    defp count_query(_query), do: :ok
  end

  defmodule PhaseBoardMaterializationRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    @blocked_key :sympp_api_phase_board_blocked_card_id

    def block_materialization(work_package_id), do: Process.put(@blocked_key, work_package_id)
    def clear_materialization_block, do: Process.delete(@blocked_key)

    def all(query), do: Repo.all(query)
    def one(query), do: Repo.one(query)
    def transaction(fun), do: Repo.transaction(fun)

    def get(WorkPackage, id) do
      if Process.get(@blocked_key) == id do
        raise "out-of-scope API phase board card materialized: #{id}"
      else
        Repo.get(WorkPackage, id)
      end
    end

    def get(schema, id), do: Repo.get(schema, id)
  end

  defmodule MalformedPhaseGrantRepo do
    @moduledoc false

    def one(_query), do: :persistent_term.get({__MODULE__, :grant})
    def get(_schema, _id), do: raise("non-null malformed phase scope must not derive from anchor")
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = WorkPackageRepository.migrate(Repo)
    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)
    start_test_endpoint()

    on_exit(fn ->
      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end

      File.rm(database_path)
    end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AgentRun)
    repo.delete_all(Artifact)
    repo.delete_all(ProgressEvent)
    repo.delete_all(Finding)
    repo.delete_all(PlanNode)
    repo.delete_all(SoloSessionEntry)
    repo.delete_all(SoloSession)
    repo.delete_all(GuidanceRequest)
    repo.delete_all(Comment)
    repo.delete_all(AccessGrant)
    repo.delete_all(PlannedSliceDelivery)
    repo.delete_all(PlannedSlice)
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)
    repo.delete_all(DecisionLogEntry)
    repo.delete_all(ClarificationQuestion)
    repo.delete_all(WorkRequest)
    repo.delete_all(OperatorSettings)
    :ok
  end

  test "serializes package cards and groups the board by status", %{repo: repo} do
    %{work_package: first} = create_dashboard_fixture(repo, id: "SYMPP-DASH-1", status: "planning")
    assert {:ok, _second} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-DASH-2", status: "blocked"))
    architect_secret = create_architect_grant_secret(repo, first.id)

    assert {:ok, card} = Dashboard.card(repo, first)
    assert card.id == "SYMPP-DASH-1"
    assert card.status == "planning"
    assert card.active_blocker_count == 1
    assert card.artifact_count == 1
    assert card.finding_count == 1
    assert card.metadata.pr["url"] == "https://github.com/example/repo/pull/1"
    assert card.operational_state.key == "blocked"
    assert card.operational_state.raw_status == "planning"
    assert [%{key: "active_blocker", blocker_ids: ["blocker-a"]}] = card.operational_state.attention_items

    payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/board"), 200)

    assert payload["total_count"] == 2
    assert [%{"id" => "SYMPP-DASH-1", "operational_state" => %{"key" => "blocked", "raw_status" => "planning"}}] = payload["groups"]["planning"]
    assert [%{"id" => "SYMPP-DASH-2"}] = payload["groups"]["blocked"]
    assert payload["groups"]["created"] == []

    assert %{
             "work_package" => %{"id" => "SYMPP-DASH-1"},
             "summary" => %{"artifact_count" => 1, "progress_event_count" => 4}
           } = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/SYMPP-DASH-1"), 200)

    assert %{
             "work_package" => %{"id" => "SYMPP-DASH-2"},
             "summary" => %{"artifact_count" => 0, "progress_event_count" => 0}
           } = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/SYMPP-DASH-2"), 200)
  end

  test "package operational state splits active work from historical activity", %{repo: repo} do
    assert {:ok, ready} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-READY", status: "ready_for_worker"))

    assert {:ok, card} = Dashboard.card(repo, ready)
    assert card.operational_state.key == "ready_for_worker"
    assert card.operational_state.attention_items == []
    assert card.operational_state.has_started == false
    assert card.operational_state.has_active_worker == false

    assert {:ok, started} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-READY-STARTED", status: "ready_for_worker"))

    create_claimed_worker_grant(repo, started.id, "worker-started")

    assert {:ok, started_card} = Dashboard.card(repo, started)
    assert started_card.operational_state.key == "needs_attention"
    assert started_card.operational_state.raw_status == "ready_for_worker"
    assert started_card.operational_state.has_started == true
    assert started_card.operational_state.has_active_worker == true
    assert [%{key: "ready_for_worker_with_activity"}] = started_card.operational_state.attention_items

    assert {:ok, ready_with_history} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-READY-HISTORY", status: "ready_for_worker"))

    assert {:ok, _old_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: ready_with_history.id,
               summary: "Worker made progress earlier",
               status: "progress",
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, ready_history_card} = Dashboard.card(repo, ready_with_history)
    assert ready_history_card.operational_state.key == "needs_attention"
    assert ready_history_card.operational_state.has_started == true
    assert ready_history_card.operational_state.has_active_worker == false
    assert ready_history_card.operational_state.is_stale == true

    assert {:ok, ready_with_run_history} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-READY-RUN-HISTORY", status: "ready_for_worker"))

    assert {:ok, ready_history_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: ready_with_run_history.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "ready-history-run"
             })

    assert {:ok, _completed_ready_history_run} = AgentRunRepository.mark_completed(repo, ready_history_run.id, "done earlier")

    assert {:ok, ready_run_history_card} = Dashboard.card(repo, ready_with_run_history)
    assert ready_run_history_card.operational_state.key == "needs_attention"
    assert ready_run_history_card.operational_state.has_started == true
    assert ready_run_history_card.operational_state.has_active_worker == false
    assert ready_run_history_card.operational_state.is_stale == true

    assert {:ok, historical} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-HISTORICAL", status: "implementing"))

    assert {:ok, run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: historical.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "historical-run"
             })

    assert {:ok, _completed_run} = AgentRunRepository.mark_completed(repo, run.id, "done earlier")

    assert {:ok, historical_card} = Dashboard.card(repo, historical)
    assert historical_card.operational_state.key == "started_paused"
    assert historical_card.operational_state.raw_status == "implementing"
    assert historical_card.operational_state.has_started == true
    assert historical_card.operational_state.has_active_worker == false
    assert historical_card.operational_state.is_stale == true
    assert is_binary(historical_card.operational_state.last_activity_at)

    assert {:ok, active} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-ACTIVE", status: "implementing"))

    assert {:ok, _active_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: active.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "active-run"
             })

    assert {:ok, active_card} = Dashboard.card(repo, active)
    assert active_card.operational_state.key == "active"
    assert active_card.operational_state.label == "Active"
    assert active_card.operational_state.has_started == true
    assert active_card.operational_state.has_active_worker == true

    assert {:ok, stale_active} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-STALE-ACTIVE", status: "implementing"))

    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -600, :second)

    assert {:ok, _stale_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: stale_active.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "stale-active-run",
               last_seen_at: stale_seen_at
             })

    assert {:ok, stale_active_card} = Dashboard.card(repo, stale_active)
    assert stale_active_card.active_agent_run == nil
    assert stale_active_card.operational_state.key == "started_paused"
    assert stale_active_card.operational_state.has_started == true
    assert stale_active_card.operational_state.has_active_worker == false
    assert stale_active_card.operational_state.is_stale == true

    assert {:ok, ci_waiting} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-OP-CI-WAITING", status: "ci_waiting"))

    assert {:ok, _review_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: ci_waiting.id,
               summary: "Review started",
               status: "review_started",
               payload: %{type: "review_progress", source_tool: "submit_review_package"},
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, ci_card} = Dashboard.card(repo, ci_waiting)
    assert ci_card.operational_state.key == "ci_waiting"
  end

  test "package operational state projects merged PRs while surfacing missing readiness contradictions", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-OP-MERGED-PR",
                 kind: "mcp",
                 status: "ready_for_human_merge",
                 policy_template: "mcp"
               )
             )

    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/77", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _pr_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/77",
                 repository: "example/repo",
                 number: 77,
                 head_sha: "head-a",
                 merge_state: %{merged: true}
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    assert {:ok, card} = Dashboard.card(repo, work_package)
    assert card.operational_state.key == "merged"
    assert card.operational_state.raw_status == "ready_for_human_merge"

    attention_by_key = Map.new(card.operational_state.attention_items, &{&1.key, &1})
    refute Map.has_key?(attention_by_key, "pr_merged_raw_status_open")
    assert "review_package_submitted" in attention_by_key["missing_readiness_evidence"].missing

    assert {:ok, _new_branch_head} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch advanced",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-b"},
               created_at: DateTime.add(timestamp, 4, :second)
             })

    assert {:ok, stale_card} = Dashboard.card(repo, work_package)
    assert stale_card.operational_state.key == "merge_ready"
    refute Enum.any?(stale_card.operational_state.attention_items, &(&1.key == "pr_merged_raw_status_open"))
  end

  test "phase board authorization preserves exact persisted phase ids", %{repo: repo} do
    phase_id = "phase-dashboard-exact "
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Exact phase"})

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-EXACT-PHASE", kind: "phase_child", phase_id: phase_id, status: "planning")
             )

    work_key = WorkKey.generate()

    assert {:ok, grant} =
             AccessGrantRepository.create(repo, %{
               work_package_id: work_package.id,
               phase_id: phase_id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:phase"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    assert grant.phase_id == phase_id

    payload = json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/board"), 200)

    assert payload["phase"]["id"] == phase_id
    assert payload["total_count"] == 1
    assert [%{"id" => "SYMPP-DASH-EXACT-PHASE"}] = payload["groups"]["planning"]
  end

  test "phase board exposes scoped child merge progress summary", %{repo: repo} do
    phase_id = "phase-dashboard-progress"
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Progress phase"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-PROGRESS-ANCHOR",
                 kind: "mcp",
                 phase_id: phase_id,
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 status: "planning"
               )
             )

    for {id, status} <- [
          {"SYMPP-DASH-PROGRESS-MERGED", "merged_into_phase"},
          {"SYMPP-DASH-PROGRESS-READY", "ready_for_architect_merge"},
          {"SYMPP-DASH-PROGRESS-CLOSED", "closed"},
          {"SYMPP-DASH-PROGRESS-ABANDONED", "abandoned"}
        ] do
      assert {:ok, _child} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(
                   id: id,
                   kind: "phase_child",
                   policy_template: "phase_child",
                   phase_id: phase_id,
                   parent_id: anchor.id,
                   repo: anchor.repo,
                   base_branch: anchor.base_branch,
                   status: status
                 )
               )
    end

    assert {:ok, _out_of_scope_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-PROGRESS-OUT-OF-SCOPE",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: phase_id,
                 parent_id: anchor.id,
                 repo: "nextide/other",
                 base_branch: anchor.base_branch,
                 status: "merged_into_phase"
               )
             )

    assert {:ok, _out_of_scope_base_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-PROGRESS-OUT-OF-BASE",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: phase_id,
                 parent_id: anchor.id,
                 repo: anchor.repo,
                 base_branch: "main",
                 status: "merged_into_phase"
               )
             )

    work_key = WorkKey.generate()

    assert {:ok, _grant} =
             AccessGrantRepository.create(repo, %{
               work_package_id: anchor.id,
               phase_id: phase_id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:phase"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    payload = json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/board"), 200)

    assert payload["total_count"] == 5

    assert payload["summary"] == %{
             "child_count" => 3,
             "merged_child_count" => 1,
             "ready_child_count" => 1,
             "merging_child_count" => 0,
             "open_child_count" => 1
           }

    assert {:ok, filtered_board} =
             Dashboard.phase_board(repo, phase_id,
               repo: anchor.repo,
               base_branch: anchor.base_branch,
               status: "merged_into_phase"
             )

    assert filtered_board.summary == %{
             child_count: 3,
             merged_child_count: 1,
             ready_child_count: 1,
             merging_child_count: 0,
             open_child_count: 1
           }
  end

  test "phase board status filters keep repo identity from the phase scope", %{repo: repo} do
    with_trusted_repo_remotes(["Pimpmuckl/symphony-plus-plus"], fn ->
      assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-repo-identity", title: "Repo identity phase"})

      assert {:ok, bare} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(
                   id: "SYMPP-DASH-PHASE-REPO-BARE",
                   kind: "phase_child",
                   phase_id: phase.id,
                   status: "planning",
                   repo: "symphony-plus-plus",
                   base_branch: "main"
                 )
               )

      assert {:ok, _owner} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(
                   id: "SYMPP-DASH-PHASE-REPO-OWNER",
                   kind: "phase_child",
                   phase_id: phase.id,
                   status: "blocked",
                   repo: "Pimpmuckl/symphony-plus-plus",
                   base_branch: "main"
                 )
               )

      assert {:ok, board} = Dashboard.phase_board(repo, phase.id, status: "planning")
      assert [%{id: bare_id} = card] = board.groups["planning"]
      assert bare_id == bare.id
      assert card.repo == "symphony-plus-plus"
      assert card.repo_key == "symphony-plus-plus"
      assert card.repo_display == "symphony-plus-plus"
      assert card.repo_remote == "Pimpmuckl/symphony-plus-plus"
      assert card.repo_aliases == ["Pimpmuckl/symphony-plus-plus", "symphony-plus-plus"]
    end)
  end

  test "legacy null phase grants derive dashboard scope from their phased anchor", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-legacy", title: "Legacy phase"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-LEGACY-ANCHOR", kind: "phase_child", phase_id: phase.id, status: "planning")
             )

    assert {:ok, sibling} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-LEGACY-SIBLING", kind: "phase_child", phase_id: phase.id, status: "blocked")
             )

    secret = create_legacy_phase_grant_secret(repo, anchor.id, "grant-dashboard-legacy-derived")

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 200)

    assert payload["phase"]["id"] == phase.id
    assert payload["total_count"] == 2
    assert [%{"id" => "SYMPP-DASH-LEGACY-ANCHOR"}] = payload["groups"]["planning"]
    assert [%{"id" => "SYMPP-DASH-LEGACY-SIBLING"}] = payload["groups"]["blocked"]
    assert payload["summary"]["child_count"] == 0
    assert payload["summary"]["merged_child_count"] == 0

    phase_id = phase.id
    sibling_id = sibling.id

    assert %{"work_package" => %{"id" => ^sibling_id, "phase_id" => ^phase_id}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{sibling.id}"), 200)
  end

  test "legacy null phase grants with unphased anchors are denied dashboard phase reads", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-LEGACY-UNPHASED", kind: "hotfix", parent_id: nil, phase_id: nil)
             )

    secret = create_legacy_phase_grant_secret(repo, anchor.id, "grant-dashboard-legacy-unphased")

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 403)
  end

  test "legacy null phase grants cannot read packages outside anchor phase", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-legacy-own", title: "Legacy own"})
    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-legacy-other", title: "Legacy other"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-LEGACY-OWN", kind: "phase_child", phase_id: phase.id, status: "planning")
             )

    assert {:ok, other_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-LEGACY-OTHER", kind: "phase_child", phase_id: other_phase.id, status: "planning")
             )

    secret = create_legacy_phase_grant_secret(repo, anchor.id, "grant-dashboard-legacy-other")
    phase_id = phase.id

    assert %{"phase" => %{"id" => ^phase_id}} = json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 200)

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{other_package.id}"), 403)
  end

  test "dashboard anchor fallback applies only to null phase grant scopes" do
    now = DateTime.utc_now(:microsecond)
    work_key = WorkKey.generate()

    :persistent_term.put(
      {MalformedPhaseGrantRepo, :grant},
      %AccessGrant{
        id: "grant-dashboard-malformed-phase",
        work_package_id: "SYMPP-DASH-MALFORMED-PHASE",
        phase_id: :malformed,
        display_key: work_key.display_key,
        secret_hash: WorkKey.secret_hash(work_key.secret),
        grant_role: "architect",
        capabilities: ["read:phase"],
        expires_at: DateTime.add(now, 3600, :second),
        claimed_at: now,
        claimed_by: "architect-malformed"
      }
    )

    on_exit(fn -> :persistent_term.erase({MalformedPhaseGrantRepo, :grant}) end)

    with_endpoint_repo(MalformedPhaseGrantRepo, fn ->
      assert %{"error" => %{"code" => "forbidden"}} =
               json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/board"), 403)
    end)
  end

  test "phase board grants are denied after their architect anchor leaves the phase", %{repo: repo} do
    assert {:ok, phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-anchor", title: "Anchor phase"})
    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-dashboard-anchor-other", title: "Other phase"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-ANCHOR", kind: "phase_child", phase_id: phase.id, status: "planning")
             )

    assert {:ok, sibling} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-ANCHOR-SIBLING", kind: "phase_child", phase_id: phase.id, status: "planning")
             )

    assert {:ok, other_sibling} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-ANCHOR-OTHER-SIBLING", kind: "phase_child", phase_id: other_phase.id, status: "planning")
             )

    work_key = WorkKey.generate()

    assert {:ok, _grant} =
             AccessGrantRepository.create(repo, %{
               work_package_id: anchor.id,
               phase_id: phase.id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:phase"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    assert %{"phase" => %{"id" => "phase-dashboard-anchor"}} =
             json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/board"), 200)

    assert {:ok, _updated_anchor} = WorkPackageRepository.update(repo, anchor.id, %{phase_id: other_phase.id})

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/board"), 403)

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/work-packages/#{sibling.id}"), 403)

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(work_key.secret), "/api/v1/sympp/work-packages/#{other_sibling.id}"), 403)
  end

  test "dashboard API phase board filters scoped grants before card materialization", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-SCOPED-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    assert {:ok, in_scope_sibling} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-SCOPED-SIBLING",
                 kind: "phase_child",
                 status: "blocked",
                 repo: "symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    assert {:ok, other_repo} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-SCOPED-OTHER-REPO",
                 kind: "phase_child",
                 status: "planning",
                 repo: "Pimpmuckl/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    assert {:ok, other_base} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-SCOPED-OTHER-BASE",
                 kind: "phase_child",
                 status: "planning",
                 repo: "symphony-plus-plus",
                 base_branch: "main"
               )
             )

    secret = create_architect_grant_secret(repo, anchor.id)
    PhaseBoardMaterializationRepo.block_materialization(other_repo.id)

    payload =
      try do
        with_endpoint_repo(PhaseBoardMaterializationRepo, fn ->
          json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 200)
        end)
      after
        PhaseBoardMaterializationRepo.clear_materialization_block()
      end

    encoded = Jason.encode!(payload)

    assert payload["total_count"] == 2

    visible_cards =
      payload["groups"]
      |> Map.values()
      |> List.flatten()

    assert Enum.map(visible_cards, & &1["id"]) |> Enum.sort() == Enum.sort([anchor.id, in_scope_sibling.id])
    assert Enum.all?(visible_cards, &(&1["repo"] == "symphony-plus-plus"))
    assert Enum.all?(visible_cards, &(&1["repo_key"] == "symphony-plus-plus"))
    assert Enum.all?(visible_cards, &(&1["repo_remote"] == nil))
    assert Enum.all?(visible_cards, &(&1["repo_aliases"] == ["symphony-plus-plus"]))

    assert encoded =~ anchor.id
    assert encoded =~ in_scope_sibling.id
    refute encoded =~ other_repo.id
    refute encoded =~ other_base.id
  end

  test "dashboard API package detail rejects scoped phase siblings outside frozen repo and base", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-DETAIL-SCOPED-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    assert {:ok, in_scope_sibling} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-DETAIL-SCOPED-SIBLING",
                 kind: "phase_child",
                 status: "blocked",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    assert {:ok, other_repo} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-DETAIL-SCOPED-OTHER-REPO",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/other-repo",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    assert {:ok, other_base} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-DETAIL-SCOPED-OTHER-BASE",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main"
               )
             )

    secret = create_architect_grant_secret(repo, anchor.id)

    assert %{"work_package" => %{"id" => "SYMPP-DASH-DETAIL-SCOPED-SIBLING"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{in_scope_sibling.id}"), 200)

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{other_repo.id}"), 403)

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{other_base.id}"), 403)
  end

  test "dashboard API lists scoped WorkRequest cards with counts", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-WR-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    in_scope =
      create_work_request!(
        repo,
        id: "WR-DASH-IN-SCOPE",
        title: "Read WorkRequests",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    _out_of_scope =
      create_work_request!(
        repo,
        id: "WR-DASH-OUT-OF-SCOPE",
        repo: "nextide/other",
        base_branch: anchor.base_branch
      )

    assert {:ok, _open_question} = WorkRequestRepository.ask_question(repo, in_scope.id, question_attrs(id: "WRQ-DASH-OPEN"))

    assert {:ok, answered_question} =
             WorkRequestRepository.ask_question(repo, in_scope.id, question_attrs(id: "WRQ-DASH-ANSWERED"))

    assert {:ok, _answered} =
             WorkRequestRepository.answer_question(repo, answered_question.id, "open", %{
               answer: "Use the backend API only.",
               answered_by: "operator-1"
             })

    assert {:ok, closed_question} = WorkRequestRepository.ask_question(repo, in_scope.id, question_attrs(id: "WRQ-DASH-CLOSED"))
    assert {:ok, _closed} = WorkRequestRepository.close_question(repo, closed_question.id, "open")

    assert {:ok, _decision} = WorkRequestRepository.record_decision(repo, in_scope.id, decision_attrs(id: "WRD-DASH-1"))
    assert {:ok, planned} = WorkRequestRepository.add_planned_slice(repo, in_scope.id, planned_slice_attrs(id: "WRS-DASH-PLANNED"))
    assert {:ok, approved} = WorkRequestRepository.add_planned_slice(repo, in_scope.id, planned_slice_attrs(id: "WRS-DASH-APPROVED"))
    assert {:ok, dispatched} = WorkRequestRepository.add_planned_slice(repo, in_scope.id, planned_slice_attrs(id: "WRS-DASH-DISPATCHED"))
    assert {:ok, skipped} = WorkRequestRepository.add_planned_slice(repo, in_scope.id, planned_slice_attrs(id: "WRS-DASH-SKIPPED"))

    assert planned.status == "planned"
    repo.update!(Ecto.Changeset.change(approved, status: "approved"))
    repo.update!(Ecto.Changeset.change(dispatched, status: "dispatched"))
    repo.update!(Ecto.Changeset.change(skipped, status: "skipped"))

    secret = create_architect_grant_secret(repo, anchor.id)
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests"), 200)

    assert payload["total_count"] == 1

    assert [
             %{
               "id" => "WR-DASH-IN-SCOPE",
               "title" => "Read WorkRequests",
               "repo" => "nextide/symphony-plus-plus",
               "base_branch" => "symphony-plus-plus/beta",
               "work_type" => "feature",
               "desired_dispatch_shape" => "single_package",
               "status" => "ready_for_slicing",
               "open_question_count" => 1,
               "answered_question_count" => 1,
               "closed_question_count" => 1,
               "decision_count" => 1,
               "planned_slice_count" => 1,
               "approved_slice_count" => 1,
               "dispatched_slice_count" => 1,
               "skipped_slice_count" => 1
             }
           ] = payload["work_requests"]
  end

  test "dashboard WorkRequest list batches related card count reads", %{repo: repo} do
    first = create_work_request!(repo, id: "WR-DASH-BATCH-1")
    second = create_work_request!(repo, id: "WR-DASH-BATCH-2")

    assert {:ok, _question} = WorkRequestRepository.ask_question(repo, first.id, question_attrs(id: "WRQ-DASH-BATCH-1"))
    assert {:ok, _decision} = WorkRequestRepository.record_decision(repo, second.id, decision_attrs(id: "WRD-DASH-BATCH-1"))
    assert {:ok, _slice} = WorkRequestRepository.add_planned_slice(repo, second.id, planned_slice_attrs(id: "WRS-DASH-BATCH-1"))

    {:ok, counter} = Agent.start_link(fn -> %{} end)
    WorkRequestCardCountingRepo.counter(counter)

    try do
      grant = %AccessGrant{
        grant_role: "architect",
        capabilities: ["read:phase"],
        phase_id: "phase-batch",
        scope_repo: "nextide/symphony-plus-plus",
        scope_base_branch: "main"
      }

      assert {:ok, payload} = Dashboard.work_requests_for_grant(WorkRequestCardCountingRepo, grant)
      assert payload.total_count == 2
      assert Enum.map(payload.work_requests, & &1.id) == [first.id, second.id]

      assert Agent.get(counter, & &1) == %{
               "sympp_work_requests" => 1,
               "sympp_work_request_clarification_questions" => 1,
               "sympp_work_request_decision_logs" => 1,
               "sympp_work_request_planned_slices" => 1,
               "sympp_work_request_planned_slice_deliveries" => 1,
               "sympp_comments" => 1
             }
    after
      WorkRequestCardCountingRepo.clear_counter()
      Agent.stop(counter)
    end
  end

  test "dashboard WorkRequest list has deterministic card order", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-WR-ORDER-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    newer = create_work_request!(repo, id: "WR-DASH-ORDER-B", repo: anchor.repo, base_branch: anchor.base_branch)
    older = create_work_request!(repo, id: "WR-DASH-ORDER-A", repo: anchor.repo, base_branch: anchor.base_branch)

    older_inserted_at = DateTime.add(newer.inserted_at, -60, :second)
    repo.update!(Ecto.Changeset.change(older, inserted_at: older_inserted_at))

    secret = create_architect_grant_secret(repo, anchor.id)
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests"), 200)

    assert Enum.map(payload["work_requests"], & &1["id"]) == [older.id, newer.id]
  end

  test "dashboard API returns redacted deterministic WorkRequest detail", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-WR-DETAIL-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    work_request =
      create_work_request!(
        repo,
        id: "WR-DASH-DETAIL",
        title: "Detail WorkRequest",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        human_description: "Use Bearer raw-secret-value for validation",
        constraints: %{"token" => "raw-secret-value", "safe" => "visible"}
      )

    assert {:ok, second_question} =
             WorkRequestRepository.ask_question(repo, work_request.id, question_attrs(id: "WRQ-DETAIL-B", question: "Second?"))

    assert {:ok, first_question} =
             WorkRequestRepository.ask_question(repo, work_request.id, question_attrs(id: "WRQ-DETAIL-A", question: "First sk-secret123?"))

    assert {:ok, _answered} =
             WorkRequestRepository.answer_question(repo, first_question.id, "open", %{
               answer: "Bearer raw-secret-value",
               answered_by: "operator-1"
             })

    assert {:ok, second_decision} =
             WorkRequestRepository.record_decision(
               repo,
               work_request.id,
               decision_attrs(id: "WRD-DETAIL-B", decision: "Second decision")
             )

    assert {:ok, first_decision} =
             WorkRequestRepository.record_decision(
               repo,
               work_request.id,
               decision_attrs(id: "WRD-DETAIL-A", decision: "Use https://example.test/path?sig=raw-secret-value")
             )

    assert {:ok, second_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-DETAIL-B", title: "Second slice")
             )

    assert {:ok, first_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-DETAIL-A", title: "Slice with ghp_secret123")
             )

    secret = create_architect_grant_secret(repo, anchor.id)
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{work_request.id}"), 200)

    assert payload["work_request"]["title"] == "Detail WorkRequest"
    assert payload["work_request"]["human_description"] == "[REDACTED]"
    assert payload["work_request"]["constraints"]["token"] == "[REDACTED]"
    assert payload["work_request"]["constraints"]["safe"] == "visible"
    assert Enum.map(payload["clarification_questions"], & &1["id"]) == [second_question.id, first_question.id]
    assert Enum.at(payload["clarification_questions"], 1)["question"] == "[REDACTED]"
    assert Enum.at(payload["clarification_questions"], 1)["answer"] == "[REDACTED]"
    assert Enum.map(payload["decision_logs"], & &1["id"]) == [second_decision.id, first_decision.id]
    assert Enum.at(payload["decision_logs"], 1)["decision"] == "[REDACTED]"
    assert Enum.map(payload["planned_slices"], & &1["id"]) == [second_slice.id, first_slice.id]
    assert Enum.at(payload["planned_slices"], 1)["title"] == "[REDACTED]"

    assert payload["summary"] == %{
             "open_question_count" => 1,
             "answered_question_count" => 1,
             "closed_question_count" => 0,
             "decision_count" => 2,
             "comment_count" => 0,
             "open_comment_count" => 0,
             "planned_slice_count" => 2,
             "approved_slice_count" => 0,
             "dispatched_slice_count" => 0,
             "skipped_slice_count" => 0
           }
  end

  test "dashboard WorkRequest detail includes redacted comments and aggregate counts", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-COMMENT-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    work_request =
      create_work_request!(
        repo,
        id: "WR-DASH-COMMENTS",
        repo: anchor.repo,
        base_branch: anchor.base_branch
      )

    assert {:ok, slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-DASH-COMMENTS")
             )

    assert {:ok, request_comment} =
             CommentService.create(repo, %{
               target_kind: "work_request",
               target_id: work_request.id,
               body: "Request note includes sk-secret123",
               source_type: "operator",
               author_name: "operator"
             })

    assert {:ok, slice_comment} =
             CommentService.create(repo, %{
               target_kind: "planned_slice",
               target_id: slice.id,
               body: "Slice note",
               source_type: "architect",
               author_name: "architect"
             })

    request_comment_id = request_comment.id
    slice_comment_id = slice_comment.id

    assert {:ok, _resolved} =
             CommentService.resolve(repo, slice_comment.id, %{
               resolved_by: "operator",
               resolved_source_type: "operator",
               resolution_note: "Closed"
             })

    secret = create_architect_grant_secret(repo, anchor.id)
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{work_request.id}"), 200)

    assert payload["work_request"]["comment_count"] == 2
    assert payload["work_request"]["open_comment_count"] == 1
    assert payload["summary"]["comment_count"] == 2
    assert payload["summary"]["open_comment_count"] == 1

    assert [%{"id" => ^request_comment_id, "body" => "Request note includes [REDACTED]", "status" => "open"}] = payload["comments"]

    assert [slice_payload] = payload["planned_slices"]
    assert slice_payload["comment_count"] == 1
    assert slice_payload["open_comment_count"] == 0
    assert [%{"id" => ^slice_comment_id, "status" => "resolved", "resolution_note" => "Closed"}] = slice_payload["comments"]
  end

  test "dashboard WorkRequest detail caps comments per target to newest entries", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-COMMENT-CAP-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    work_request =
      create_work_request!(
        repo,
        id: "WR-DASH-COMMENT-CAP",
        repo: anchor.repo,
        base_branch: anchor.base_branch
      )

    assert {:ok, slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-DASH-COMMENT-CAP")
             )

    Enum.each(1..105, fn index ->
      create_comment_at!(repo, index, %{
        id: numbered_comment_id("comment-wr", index),
        target_kind: "work_request",
        target_id: work_request.id,
        body: "Request comment #{index}",
        source_type: "operator",
        author_name: "operator"
      })

      create_comment_at!(repo, index, %{
        id: numbered_comment_id("comment-slice", index),
        target_kind: "planned_slice",
        target_id: slice.id,
        body: "Slice comment #{index}",
        source_type: "operator",
        author_name: "operator"
      })
    end)

    expected_request_ids = Enum.map(6..105, &numbered_comment_id("comment-wr", &1))
    expected_slice_ids = Enum.map(6..105, &numbered_comment_id("comment-slice", &1))

    assert {:ok, listed_comments} = CommentService.list_for_target(repo, "work_request", work_request.id)
    assert Enum.map(listed_comments, & &1.id) == expected_request_ids

    secret = create_architect_grant_secret(repo, anchor.id)
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{work_request.id}"), 200)

    assert payload["work_request"]["comment_count"] == 210
    assert payload["summary"]["comment_count"] == 210
    assert Enum.map(payload["comments"], & &1["id"]) == expected_request_ids

    assert [slice_payload] = payload["planned_slices"]
    assert Enum.map(slice_payload["comments"], & &1["id"]) == expected_slice_ids
  end

  test "local WorkRequest detail includes planned-slice operational state from linked package activity", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-OP-SLICES", status: "ready_for_slicing")

    assert {:ok, approved_ready} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-OP-READY"))

    assert {:ok, _approved_ready} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, approved_ready.id, "planned")

    assert {:ok, approved_idle_linked} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-OP-IDLE-LINKED"))

    assert {:ok, approved_idle_linked} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, approved_idle_linked.id, "planned")

    idle_package =
      create_matching_work_package!(repo, work_request, approved_idle_linked,
        id: "SYMPP-OP-IDLE-LINKED",
        status: "ready_for_worker"
      )

    assert {:ok, dispatched_idle} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_idle_linked.id, "approved", idle_package.id)

    repo.update!(Ecto.Changeset.change(dispatched_idle, status: "approved"))

    assert {:ok, approved_linked} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-OP-LINKED"))

    assert {:ok, approved_linked} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, approved_linked.id, "planned")

    linked_package =
      create_matching_work_package!(repo, work_request, approved_linked,
        id: "SYMPP-OP-LINKED",
        status: "implementing"
      )

    assert {:ok, dispatched} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_linked.id, "approved", linked_package.id)

    repo.update!(Ecto.Changeset.change(dispatched, status: "approved"))

    assert {:ok, approved_terminal} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-OP-TERMINAL"))

    assert {:ok, approved_terminal} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, approved_terminal.id, "planned")

    terminal_package =
      create_matching_work_package!(repo, work_request, approved_terminal,
        id: "SYMPP-OP-TERMINAL",
        status: "abandoned"
      )

    assert {:ok, dispatched_terminal} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_terminal.id, "approved", terminal_package.id)

    repo.update!(Ecto.Changeset.change(dispatched_terminal, status: "approved"))

    assert {:ok, payload} = Dashboard.work_request_detail(repo, work_request.id)
    slices_by_id = Map.new(payload.planned_slices, &{&1.id, &1})

    assert get_in(slices_by_id, ["WRS-OP-READY", :operational_state, :key]) == "ready_for_worker"
    assert get_in(slices_by_id, ["WRS-OP-READY", :operational_state, :raw_status]) == "approved"
    assert get_in(slices_by_id, ["WRS-OP-IDLE-LINKED", :operational_state, :key]) == "ready_for_worker"

    linked_slice = Map.fetch!(slices_by_id, "WRS-OP-LINKED")
    assert linked_slice.work_package_id == linked_package.id
    assert linked_slice.work_package_status == "implementing"
    assert linked_slice.operational_state.key == "started_paused"
    assert linked_slice.operational_state.raw_status == "approved"

    assert Enum.any?(
             linked_slice.operational_state.attention_items,
             &(&1.key == "linked_package_started_while_slice_idle")
           )

    terminal_slice = Map.fetch!(slices_by_id, "WRS-OP-TERMINAL")
    assert terminal_slice.work_package_status == "abandoned"
    assert terminal_slice.operational_state.key == "needs_closeout"
    assert terminal_slice.attention_reason_codes == ["terminal_package_without_delivery_outcome"]
  end

  test "WorkRequest cards promote linked package operational state over raw ready-for-slicing", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-OP-REQUEST", status: "ready_for_slicing")

    assert {:ok, active_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-OP-REQUEST-ACTIVE"))

    assert {:ok, active_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, active_slice.id, "planned")

    active_package =
      create_matching_work_package!(repo, work_request, active_slice,
        id: "SYMPP-OP-REQUEST-ACTIVE",
        status: "implementing"
      )

    assert {:ok, _active_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: active_package.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "request-active-run"
             })

    assert {:ok, _dispatched_active} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, active_slice.id, "approved", active_package.id)

    assert {:ok, merged_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-OP-REQUEST-MERGED"))

    assert {:ok, merged_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, merged_slice.id, "planned")

    merged_package =
      create_matching_work_package!(repo, work_request, merged_slice,
        id: "SYMPP-OP-REQUEST-MERGED",
        status: "merged"
      )

    assert {:ok, _dispatched_merged} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, merged_slice.id, "approved", merged_package.id)

    assert {:ok, payload} = Dashboard.work_requests(repo)
    request_card = Enum.find(payload.work_requests, &(&1.id == work_request.id))

    assert request_card.status == "ready_for_slicing"
    assert request_card.dispatched_slice_count == 2
    assert request_card.operational_state.key == "active"
    assert request_card.operational_state.label == "Active"
    assert request_card.operational_state.raw_status == "ready_for_slicing"
    assert request_card.operational_state.has_started == true
    assert request_card.operational_state.has_active_worker == true
  end

  test "WorkRequest completion shows needs closeout while dispatched slice preserves merged package truth", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-OP-MERGED", status: "ready_for_slicing")

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-OP-MERGED"))

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    merged_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "SYMPP-OP-MERGED",
        status: "merged"
      )

    assert {:ok, dispatched_slice} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", merged_package.id)

    assert dispatched_slice.status == "dispatched"

    assert {:ok, payload} = Dashboard.work_request_detail(repo, work_request.id)
    assert payload.work_request.status == "ready_for_slicing"
    assert payload.work_request.completed_at != nil
    assert payload.work_request.archived_at == nil
    assert payload.work_request.operational_state.key == "needs_closeout"
    assert payload.work_request.operational_state.label == "Needs Closeout"
    assert payload.work_request.operational_state.raw_status == "ready_for_slicing"

    assert {:ok, read_request} = WorkRequestRepository.get(repo, work_request.id)
    assert read_request.completed_at == nil

    [slice] = payload.planned_slices
    assert slice.status == "dispatched"
    assert slice.work_package_status == "merged"
    assert slice.operational_state.key == "needs_closeout"
    assert slice.operational_state.raw_status == "dispatched"
    assert slice.attention_reason_codes == ["terminal_package_without_delivery_outcome"]
  end

  test "WorkRequest delivery truth stays primary over lifecycle gates", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-OP-GATED-DELIVERY", status: "ready_for_slicing")

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-OP-GATED-DELIVERY"))

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    work_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "SYMPP-OP-GATED-DELIVERY",
        status: "ready_for_worker"
      )

    assert {:ok, _dispatched_slice} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", work_package.id)

    assert {:ok, _delivery} =
             WorkRequestRepository.record_planned_slice_delivery(
               repo,
               work_request.id,
               approved_slice.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "dashboard-gated-delivery",
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/904",
                 pr_merged_at: ~U[2026-05-24 11:30:00.000000Z],
                 merge_commit_sha: "merge-904"
               })
             )

    work_request
    |> Ecto.Changeset.change(status: "human_info_needed")
    |> repo.update!()

    assert {:ok, payload} = Dashboard.work_requests(repo)
    card = Enum.find(payload.work_requests, &(&1.id == work_request.id))

    assert card.operational_state.key == "delivered"
    assert card.operational_state.raw_status == "human_info_needed"

    assert {:ok, detail} = Dashboard.work_request_detail(repo, work_request.id)
    assert detail.work_request.operational_state.key == "delivered"
    assert detail.work_request.operational_state.raw_status == "human_info_needed"

    [slice] = detail.planned_slices
    assert slice.operational_state.key == "delivered"
  end

  test "operator-completed WorkRequest stays completed over lifecycle gates", %{repo: repo} do
    completed_at = ~U[2026-05-25 10:00:00.000000Z]

    work_request =
      create_work_request!(repo, id: "WR-DASH-OPERATOR-COMPLETED-GATED", status: "human_info_needed")
      |> Ecto.Changeset.change(completed_at: completed_at, completion_source: "operator")
      |> repo.update!()

    assert {:ok, payload} = Dashboard.work_requests(repo)
    card = Enum.find(payload.work_requests, &(&1.id == work_request.id))

    assert card.operational_state.key == "completed"
    assert card.operational_state.raw_status == "human_info_needed"

    assert {:ok, detail} = Dashboard.work_request_detail(repo, work_request.id)
    assert detail.work_request.operational_state.key == "completed"
    assert detail.work_request.operational_state.raw_status == "human_info_needed"
  end

  test "derived completed WorkRequest stays completed over clarification gates", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-DERIVED-COMPLETED-GATED", status: "ready_for_slicing")

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DERIVED-COMPLETED-GATED"))

    assert {:ok, _skipped_slice} = WorkRequestRepository.skip_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    work_request
    |> Ecto.Changeset.change(status: "clarifying")
    |> repo.update!()

    assert {:ok, payload} = Dashboard.work_requests(repo)
    card = Enum.find(payload.work_requests, &(&1.id == work_request.id))

    assert card.operational_state.key == "completed"
    assert card.operational_state.raw_status == "clarifying"

    assert {:ok, detail} = Dashboard.work_request_detail(repo, work_request.id)
    assert detail.work_request.operational_state.key == "completed"
    assert detail.work_request.operational_state.raw_status == "clarifying"
  end

  test "archived WorkRequest lifecycle stays primary over delivery promotion", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-OP-ARCHIVED-DELIVERY", status: "ready_for_slicing")

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-OP-ARCHIVED-DELIVERY"))

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    work_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "SYMPP-OP-ARCHIVED-DELIVERY",
        status: "ready_for_worker"
      )

    assert {:ok, _dispatched_slice} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", work_package.id)

    assert {:ok, _delivery} =
             WorkRequestRepository.record_planned_slice_delivery(
               repo,
               work_request.id,
               approved_slice.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "dashboard-archived-delivery",
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/906",
                 pr_merged_at: ~U[2026-05-24 12:00:00.000000Z],
                 merge_commit_sha: "merge-906"
               })
             )

    archived_at = ~U[2026-05-25 09:00:00.000000Z]

    work_request
    |> Ecto.Changeset.change(completed_at: archived_at, completion_source: "operator", archived_at: archived_at)
    |> repo.update!()

    assert {:ok, detail} = Dashboard.work_request_detail(repo, work_request.id)
    assert detail.work_request.operational_state.key == "completed"

    [slice] = detail.planned_slices
    assert slice.operational_state.key == "delivered"
  end

  test "grant WorkRequest list and detail promote scoped linked packages consistently", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-OP-GRANT-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    work_request =
      create_work_request!(
        repo,
        id: "WR-DASH-OP-GRANT-MERGED",
        status: "ready_for_slicing",
        repo: anchor.repo,
        base_branch: anchor.base_branch
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-OP-GRANT-MERGED", target_base_branch: anchor.base_branch)
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    merged_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "SYMPP-OP-GRANT-MERGED",
        status: "merged"
      )

    assert {:ok, _dispatched_slice} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", merged_package.id)

    assert {:ok, _delivery} =
             WorkRequestRepository.record_planned_slice_delivery(
               repo,
               work_request.id,
               approved_slice.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "grant-dashboard-delivery-merged",
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/903",
                 pr_merged_at: ~U[2026-05-24 11:00:00.000000Z],
                 merge_commit_sha: "merge-903"
               })
             )

    assert {:ok, terminal_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-OP-GRANT-TERMINAL", target_base_branch: anchor.base_branch)
             )

    assert {:ok, terminal_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, terminal_slice.id, "planned")

    terminal_package =
      create_matching_work_package!(repo, work_request, terminal_slice,
        id: "SYMPP-OP-GRANT-TERMINAL",
        status: "merged"
      )

    assert {:ok, _terminal_dispatched_slice} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, terminal_slice.id, "approved", terminal_package.id)

    secret = create_architect_grant_secret(repo, anchor.id)
    list_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests"), 200)
    detail_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{work_request.id}"), 200)

    [card] = Enum.filter(list_payload["work_requests"], &(&1["id"] == work_request.id))

    assert card["status"] == "ready_for_slicing"
    assert card["completed_at"] != nil
    assert card["archived_at"] == nil
    assert card["operational_state"]["key"] == "needs_closeout"
    assert card["operational_state"]["label"] == "Needs Closeout"
    assert card["operational_state"]["raw_status"] == "ready_for_slicing"
    refute Map.has_key?(card["operational_state"], "reason")
    refute Map.has_key?(card["operational_state"], "work_package_status")
    refute Enum.any?(card["operational_state"]["attention_items"] || [], &Map.has_key?(&1, "reason"))
    refute Map.has_key?(card["operational_state"], "has_started")
    refute Map.has_key?(card["operational_state"], "has_active_worker")
    refute Map.has_key?(card["operational_state"], "last_activity_at")
    refute Map.has_key?(card["operational_state"], "is_stale")

    assert detail_payload["work_request"]["operational_state"]["key"] == card["operational_state"]["key"]
    assert detail_payload["work_request"]["completed_at"] == card["completed_at"]
    refute Map.has_key?(detail_payload["work_request"]["operational_state"], "reason")
    refute Map.has_key?(detail_payload["work_request"]["operational_state"], "work_package_status")
    refute Enum.any?(detail_payload["work_request"]["operational_state"]["attention_items"] || [], &Map.has_key?(&1, "reason"))
    refute Map.has_key?(detail_payload["work_request"]["operational_state"], "has_started")
    refute Map.has_key?(detail_payload["work_request"]["operational_state"], "has_active_worker")
    refute Map.has_key?(detail_payload["work_request"]["operational_state"], "last_activity_at")
    refute Map.has_key?(detail_payload["work_request"]["operational_state"], "is_stale")

    grant_slices = Map.new(detail_payload["planned_slices"], &{&1["id"], &1})

    assert %{"status" => "dispatched"} = grant_slice = Map.fetch!(grant_slices, approved_slice.id)
    assert get_in(grant_slice, ["operational_state", "key"]) == "delivered"
    refute Map.has_key?(grant_slice, "delivery")
    refute Map.has_key?(grant_slice, "successor")
    refute Map.has_key?(grant_slice, "work_package_status")
    refute Map.has_key?(grant_slice["operational_state"], "reason")
    refute Map.has_key?(grant_slice["operational_state"], "work_package_status")
    refute Enum.any?(grant_slice["operational_state"]["attention_items"] || [], &Map.has_key?(&1, "reason"))

    assert %{"status" => "dispatched"} = terminal_grant_slice = Map.fetch!(grant_slices, terminal_slice.id)
    assert get_in(terminal_grant_slice, ["operational_state", "key"]) == "needs_closeout"
    assert terminal_grant_slice["attention_reason_codes"] == ["terminal_package_without_delivery_outcome"]
    refute Map.has_key?(terminal_grant_slice, "delivery")
    refute Map.has_key?(terminal_grant_slice, "successor")
    refute Map.has_key?(terminal_grant_slice, "work_package_status")
    refute Map.has_key?(terminal_grant_slice["operational_state"], "reason")
    refute Map.has_key?(terminal_grant_slice["operational_state"], "work_package_status")
    refute Enum.any?(terminal_grant_slice["operational_state"]["attention_items"] || [], &Map.has_key?(&1, "reason"))
    refute Map.has_key?(detail_payload, "delivery_board")
  end

  test "dashboard WorkRequest detail exposes delivery-board closeout truth", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-DELIVERY-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main"
               )
             )

    work_request =
      create_work_request!(
        repo,
        id: "WR-DASH-DELIVERY-BOARD",
        status: "ready_for_slicing",
        repo: anchor.repo,
        base_branch: anchor.base_branch
      )

    assert {:ok, closeout_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-DASH-NEEDS-CLOSEOUT", target_base_branch: anchor.base_branch)
             )

    assert {:ok, closeout_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, closeout_slice.id, "planned")

    closeout_package =
      create_matching_work_package!(repo, work_request, closeout_slice,
        id: "SYMPP-DASH-NEEDS-CLOSEOUT",
        status: "ready_for_human_merge"
      )

    assert {:ok, _dispatched_closeout} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, closeout_slice.id, "approved", closeout_package.id)

    assert {:ok, _attached_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: closeout_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/symphony-plus-plus/pull/903", head_sha: "head-903"}
             })

    assert {:ok, _merged_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: closeout_package.id,
               summary: "PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/903",
                 head_sha: "head-903",
                 merge_state: %{merged: true}
               }
             })

    assert {:ok, no_pr_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-DASH-NO-PR", target_base_branch: anchor.base_branch)
             )

    assert {:ok, no_pr_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, no_pr_slice.id, "planned")

    no_pr_package =
      create_matching_work_package!(repo, work_request, no_pr_slice,
        id: "SYMPP-DASH-NO-PR",
        status: "closed"
      )

    assert {:ok, _dispatched_no_pr} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, no_pr_slice.id, "approved", no_pr_package.id)

    assert {:ok, _no_pr_delivery} =
             WorkRequestRepository.record_planned_slice_delivery(
               repo,
               work_request.id,
               no_pr_slice.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "dashboard-delivery-board-no-pr",
                 no_pr_evidence: "Operator confirmed direct completion."
               })
             )

    assert {:ok, superseded_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-DASH-SUPERSEDED", target_base_branch: anchor.base_branch)
             )

    assert {:ok, superseded_slice} =
             WorkRequestRepository.approve_planned_slice(repo, work_request.id, superseded_slice.id, "planned")

    superseded_package =
      create_matching_work_package!(repo, work_request, superseded_slice,
        id: "SYMPP-DASH-SUPERSEDED",
        status: "closed"
      )

    assert {:ok, _dispatched_superseded} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, superseded_slice.id, "approved", superseded_package.id)

    assert {:ok, successor_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-DASH-SUCCESSOR", target_base_branch: anchor.base_branch)
             )

    successor_package =
      create_work_package!(repo,
        id: "SYMPP-DASH-SUCCESSOR",
        status: "ready_for_worker",
        repo: work_request.repo,
        base_branch: anchor.base_branch
      )

    assert {:ok, _superseded_delivery} =
             WorkRequestRepository.record_planned_slice_delivery(
               repo,
               work_request.id,
               superseded_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "dashboard-delivery-board-superseded",
                 successor_planned_slice_id: successor_slice.id,
                 successor_work_package_id: successor_package.id,
                 superseded_reason: "Replaced by successor package."
               })
             )

    assert {:ok, merged_delivery_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-DASH-RECORDED-MERGED", target_base_branch: anchor.base_branch)
             )

    assert {:ok, merged_delivery_slice} =
             WorkRequestRepository.approve_planned_slice(repo, work_request.id, merged_delivery_slice.id, "planned")

    merged_delivery_package =
      create_matching_work_package!(repo, work_request, merged_delivery_slice,
        id: "SYMPP-DASH-RECORDED-MERGED",
        status: "ready_for_worker"
      )

    assert {:ok, _merged_delivery_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: merged_delivery_package.id,
               summary: "Worker progress exists",
               status: "progress",
               payload: %{type: "progress"}
             })

    assert {:ok, _dispatched_merged_delivery} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               merged_delivery_slice.id,
               "approved",
               merged_delivery_package.id
             )

    assert {:ok, _merged_delivery} =
             WorkRequestRepository.record_planned_slice_delivery(
               repo,
               work_request.id,
               merged_delivery_slice.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "dashboard-delivery-board-pr-merged",
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/904",
                 pr_merged_at: ~U[2026-05-24 12:00:00.000000Z],
                 merge_commit_sha: "merge-904"
               })
             )

    assert {:ok, filtered_successor_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-DASH-FILTERED-SUCCESSOR", target_base_branch: anchor.base_branch)
             )

    assert {:ok, filtered_successor_slice} =
             WorkRequestRepository.approve_planned_slice(repo, work_request.id, filtered_successor_slice.id, "planned")

    filtered_successor_package =
      create_matching_work_package!(repo, work_request, filtered_successor_slice,
        id: "SYMPP-DASH-FILTERED-SUCCESSOR",
        status: "closed"
      )

    assert {:ok, _filtered_successor_dispatch} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               filtered_successor_slice.id,
               "approved",
               filtered_successor_package.id
             )

    out_of_scope_successor_package =
      create_work_package!(repo,
        id: "SYMPP-DASH-OUT-OF-SCOPE-SUCCESSOR",
        status: "ready_for_worker",
        repo: work_request.repo,
        base_branch: "other-base"
      )

    assert {:ok, _filtered_successor_delivery} =
             WorkRequestRepository.record_planned_slice_delivery(
               repo,
               work_request.id,
               filtered_successor_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "dashboard-delivery-board-filtered-successor",
                 successor_planned_slice_id: successor_slice.id,
                 successor_work_package_id: out_of_scope_successor_package.id,
                 superseded_reason: "Out-of-scope successor should remain hidden."
               })
             )

    assert {:ok, payload} = Dashboard.work_request_detail(repo, work_request.id)

    assert payload.delivery_board["slice_count"] == 6
    slices_by_id = Map.new(payload.delivery_board["slices"], &{&1["id"], &1})

    assert get_in(slices_by_id, ["WRS-DASH-NEEDS-CLOSEOUT", "operational_state", "key"]) == "needs_closeout"
    assert get_in(slices_by_id, ["WRS-DASH-NEEDS-CLOSEOUT", "attention_reason_codes"]) == ["pr_merged_without_delivery_outcome"]
    assert get_in(slices_by_id, ["WRS-DASH-NO-PR", "delivery", "outcome"]) == "completed_no_pr"
    assert get_in(slices_by_id, ["WRS-DASH-NO-PR", "operational_state", "key"]) == "completed_no_pr"
    assert get_in(slices_by_id, ["WRS-DASH-RECORDED-MERGED", "delivery", "outcome"]) == "pr_merged"
    assert get_in(slices_by_id, ["WRS-DASH-RECORDED-MERGED", "operational_state", "key"]) == "delivered"
    assert get_in(slices_by_id, ["WRS-DASH-SUPERSEDED", "successor", "work_package", "id"]) == successor_package.id
    assert get_in(slices_by_id, ["WRS-DASH-SUPERSEDED", "successor", "work_package_id"]) == successor_package.id
    assert get_in(slices_by_id, ["WRS-DASH-FILTERED-SUCCESSOR", "successor", "work_package"]) == nil
    assert get_in(slices_by_id, ["WRS-DASH-FILTERED-SUCCESSOR", "successor", "work_package_id"]) == nil

    planned_slices_by_id = Map.new(payload.planned_slices, &{&1.id, &1})

    needs_closeout_slice = Map.fetch!(planned_slices_by_id, "WRS-DASH-NEEDS-CLOSEOUT")
    assert needs_closeout_slice.operational_state.key == "needs_closeout"
    assert needs_closeout_slice.attention_reason_codes == ["pr_merged_without_delivery_outcome"]
    assert needs_closeout_slice.operational_state.raw_status == "dispatched"

    no_pr_slice = Map.fetch!(planned_slices_by_id, "WRS-DASH-NO-PR")
    assert get_in(no_pr_slice, [:delivery, "outcome"]) == "completed_no_pr"
    assert no_pr_slice.operational_state.key == "completed_no_pr"
    assert no_pr_slice.operational_state.label == "Completed Without PR"
    assert no_pr_slice.operational_state.raw_status == "dispatched"

    merged_slice = Map.fetch!(planned_slices_by_id, "WRS-DASH-RECORDED-MERGED")
    assert get_in(merged_slice, [:delivery, "outcome"]) == "pr_merged"
    assert merged_slice.operational_state.key == "delivered"
    assert merged_slice.operational_state.label == "Delivered"
    assert merged_slice.operational_state.raw_status == "dispatched"
    assert merged_slice.operational_state.work_package_status == "ready_for_worker"
    assert merged_slice.operational_state.has_started == true
    assert merged_slice.operational_state.is_stale == true
    assert Enum.any?(merged_slice.operational_state.attention_items, &(&1.key == "ready_for_worker_with_activity"))
    assert "linked_package_status_stale_after_delivery" in merged_slice.attention_reason_codes

    superseded_payload = Map.fetch!(planned_slices_by_id, "WRS-DASH-SUPERSEDED")
    assert get_in(superseded_payload, [:delivery, "outcome"]) == "superseded"
    assert superseded_payload.operational_state.key == "superseded"
    assert get_in(superseded_payload, [:successor, "work_package", "id"]) == successor_package.id
    assert payload.work_request.completed_at == nil
  end

  test "dashboard API WorkRequest endpoints enforce board reader authorization and scope", %{repo: repo} do
    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-WR-AUTH-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    in_scope = create_work_request!(repo, id: "WR-DASH-AUTH-IN", repo: anchor.repo, base_branch: anchor.base_branch)
    other_repo = create_work_request!(repo, id: "WR-DASH-AUTH-OTHER", repo: "nextide/other", base_branch: anchor.base_branch)
    other_branch = create_work_request!(repo, id: "WR-DASH-AUTH-BRANCH", repo: anchor.repo, base_branch: "main")
    secret = create_architect_grant_secret(repo, anchor.id)
    legacy_secret = create_legacy_phase_grant_secret(repo, anchor.id, "grant-dashboard-wr-legacy")

    assert %{"work_requests" => [%{"id" => "WR-DASH-AUTH-IN"}]} =
             json_response(get(auth_conn(legacy_secret), "/api/v1/sympp/work-requests"), 200)

    assert %{"work_request" => %{"id" => "WR-DASH-AUTH-IN"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{in_scope.id}"), 200)

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{other_repo.id}"), 404)

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/#{other_branch.id}"), 404)

    assert %{"work_request" => %{"id" => "WR-DASH-AUTH-IN"}} =
             json_response(get(auth_conn(legacy_secret), "/api/v1/sympp/work-requests/#{in_scope.id}"), 200)

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(get(auth_conn(legacy_secret), "/api/v1/sympp/work-requests/#{other_repo.id}"), 404)

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(get(auth_conn(legacy_secret), "/api/v1/sympp/work-requests/#{other_branch.id}"), 404)

    assert {:error, :forbidden} =
             Dashboard.work_requests_for_grant(repo, %AccessGrant{grant_role: "operator", capabilities: ["read:phase"]})

    assert %{"error" => %{"code" => "not_found"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-requests/WR-DASH-MISSING"), 404)

    assert %{"error" => %{"code" => "unauthorized"}} =
             json_response(get(build_conn(), "/api/v1/sympp/work-requests"), 401)

    %{work_key_secret: package_secret} = create_dashboard_fixture(repo, id: "SYMPP-DASH-WR-PACKAGE-ONLY")

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(package_secret), "/api/v1/sympp/work-requests"), 403)
  end

  test "dashboard WorkRequest reads normalize database busy errors" do
    grant = %AccessGrant{
      grant_role: "architect",
      capabilities: ["read:phase"],
      phase_id: "phase-busy",
      scope_repo: "nextide/symphony-plus-plus",
      scope_base_branch: "main"
    }

    assert {:error, :database_busy} = Dashboard.work_requests_for_grant(BusyRepo, grant)
  end

  test "board artifact reads are limited to packages that need artifact-backed readiness", %{repo: repo} do
    assert {:ok, plain_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-DASH-PLAIN-ARTIFACTS", kind: "mcp", status: "planning", policy_template: "mcp")
             )

    assert {:ok, review_suite_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-REVIEW-SUITE-ARTIFACTS",
                 kind: "mcp",
                 status: "planning",
                 policy_template: "mcp_review_suite_artifact"
               )
             )

    assert {:ok, _plain_artifact} =
             PlanningService.append_artifact(repo, %{
               work_package_id: plain_package.id,
               path: "plain.txt",
               title: "Plain artifact",
               kind: "note"
             })

    assert {:ok, _review_suite_artifact} =
             PlanningService.append_artifact(repo, %{
               work_package_id: review_suite_package.id,
               path: "review-suite-result.json",
               title: "Review-suite result",
               kind: "review_suite"
             })

    assert {:ok, counter} = Agent.start_link(fn -> 0 end)
    CountingRepo.counter(counter)

    try do
      assert {:ok, board} = Dashboard.board(CountingRepo)
      assert board.total_count == 2
      assert Agent.get(counter, & &1) == 1
    after
      CountingRepo.clear_counter()
      Agent.stop(counter)
    end
  end

  test "detail endpoint returns package state with redacted events, artifacts, grants, blockers, and runs", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret, grant: grant} = create_dashboard_fixture(repo)
    sibling_grant = create_claimed_worker_grant(repo, work_package.id, "worker-2")
    assert {:ok, [own_run]} = AgentRunRepository.list_for_work_package(repo, work_package.id)
    assert {:ok, _completed_run} = AgentRunRepository.mark_completed(repo, own_run.id)

    assert {:ok, sibling_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               access_grant_id: sibling_grant.id,
               actor_id: "worker-2",
               status: "running",
               attempt: 1,
               worker_host: "other-host",
               worker_task_handle: "task-2",
               workspace_path: "C:/tmp/other-workspace",
               session_id: "session-2"
             })

    assert {:ok, _sibling_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Sibling package progress",
               status: "working",
               actor_id: "worker-2",
               actor_type: "worker",
               access_grant_id: sibling_grant.id,
               agent_run_id: sibling_run.id,
               payload: %{type: "status", source_tool: "test"}
             })

    assert {:ok, _sibling_finding} =
             PlanningRepository.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "Sibling package finding",
               body: "Shared package context",
               severity: "low",
               access_grant_id: sibling_grant.id
             })

    assert {:ok, _sibling_metadata} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Sibling metadata",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/example/repo/pull/2",
                 head_sha: "abc123",
                 access_grant_id: sibling_grant.id,
                 agent_run_id: sibling_run.id,
                 actor: %{id: "worker-2", type: "worker"}
               }
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["work_package"]["id"] == work_package.id
    assert payload["summary"]["artifact_count"] == 1
    assert payload["summary"]["grant_count"] == 1
    assert payload["summary"]["agent_run_count"] == 1
    assert payload["summary"]["active_agent_run_count"] == 0
    assert payload["summary"]["runtime"]["active_count"] == 0
    assert payload["summary"]["runtime"]["failed_count"] == 0
    assert payload["summary"]["runtime"]["stale_count"] == 0
    assert [%{"path" => "[REDACTED]", "title" => "[REDACTED]", "kind" => "review"}] = payload["artifacts"]
    assert [%{"id" => "blocker-a", "active" => true}] = payload["blockers"]
    assert [%{"id" => grant_id, "display_key" => display_key, "status" => "active"}] = payload["grants"]
    assert grant_id == grant.id
    assert display_key == grant.display_key
    assert [%{"status" => "completed", "session_id" => "session-1"}] = payload["agent_runs"]
    assert [%{"runtime_state" => "terminal", "stale" => false}] = payload["agent_runs"]
    assert [%{"access_grant_id" => ^grant_id, "actor_id" => "worker-1"}] = payload["agent_runs"]
    assert is_nil(payload["active_agent_run"])
    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})
    refute alerts["stale_heartbeat"]["active"]
    refute alerts["failed_run"]["active"]

    encoded = Jason.encode!(payload)
    assert encoded =~ "Sibling package progress"
    assert encoded =~ "Sibling package finding"
    refute encoded =~ secret
    refute encoded =~ grant.secret_hash
    refute encoded =~ sibling_grant.id
    refute encoded =~ sibling_run.id
    refute encoded =~ "worker-2"
    refute encoded =~ "other-workspace"
    refute encoded =~ "raw-secret-value"
    assert encoded =~ "[REDACTED]"
  end

  test "worker scoping classifies status-only run payloads", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUNTIME-STATUS-ONLY", status: "implementing"))

    grant = create_claimed_worker_grant(repo, work_package.id, "worker-1")
    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -600, :second)

    payload =
      SymppDashboardApiController.scope_package_payload_for_grant(grant, %{
        active_agent_run: %{id: "run-other", access_grant_id: "grant-other", status: "running"},
        agent_runs: [
          %{id: "run-owned", access_grant_id: grant.id, status: "running", last_seen_at: stale_seen_at},
          %{id: "run-other", access_grant_id: "grant-other", status: "running"}
        ],
        runtime: %{
          stale_heartbeat_after_seconds: 300,
          active_count: 2,
          queued_count: 0,
          stopped_count: 0,
          failed_count: 0,
          completed_count: 0,
          terminal_count: 0,
          stale_count: 1
        },
        summary: %{runtime: %{stale_heartbeat_after_seconds: 300}},
        alert_indicators: [
          %{type: "stale_heartbeat", active: false, detail: "0 run(s) past 300s"},
          %{type: "failed_run", active: false, detail: "0 failed run(s)"}
        ]
      })

    alerts = Map.new(payload.alert_indicators, &{&1.type, &1})

    assert [%{id: "run-owned"}] = payload.agent_runs
    assert payload.active_agent_run.id == "run-owned"
    assert payload.summary.active_agent_run_count == 1
    assert payload.summary.stale_agent_run_count == 1
    assert payload.summary.runtime.active_count == 1
    assert payload.summary.runtime.stale_count == 1
    assert payload.runtime.active_count == 1
    assert payload.runtime.stale_count == 1
    assert alerts["stale_heartbeat"].active == true
    assert alerts["stale_heartbeat"].detail == "1 run(s) past 300s"
  end

  test "worker-scoped stale alerts keep the configured threshold", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret, grant: grant} =
      create_dashboard_fixture(repo, id: "SYMPP-RUNTIME-SCOPED-STALE")

    assert {:ok, [run]} = AgentRunRepository.list_for_work_package(repo, work_package.id)
    assert {:ok, _completed_run} = AgentRunRepository.mark_completed(repo, run.id)

    assert {:ok, stale_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               access_grant_id: grant.id,
               actor_id: "worker-1",
               status: "starting",
               attempt: 2,
               worker_task_handle: "queued-task"
             })

    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -600, :second)

    assert {:ok, _stale_run} =
             stale_run
             |> AgentRun.update_changeset(%{last_seen_at: stale_seen_at})
             |> repo.update()

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})

    assert payload["summary"]["runtime"]["stale_heartbeat_after_seconds"] == 300
    assert payload["summary"]["active_agent_run_count"] == 1
    assert payload["summary"]["queued_agent_run_count"] == 1
    assert payload["summary"]["runtime"]["stale_count"] == 1
    assert payload["active_agent_run"]["runtime_state"] == "queued"
    assert alerts["stale_heartbeat"]["active"] == true
    assert alerts["stale_heartbeat"]["detail"] == "1 run(s) past 300s"
  end

  test "stale calculation only flags active or queued runs past the threshold", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUNTIME-STALE", status: "ready_for_worker"))

    now = DateTime.utc_now(:microsecond)

    fresh_run =
      %AgentRun{
        work_package_id: work_package.id,
        status: "running",
        last_seen_at: DateTime.add(now, -299, :second)
      }

    stale_run =
      %AgentRun{
        work_package_id: work_package.id,
        status: "starting",
        last_seen_at: DateTime.add(now, -300, :second)
      }

    stopped_run =
      %AgentRun{
        work_package_id: work_package.id,
        status: "stopped",
        last_seen_at: DateTime.add(now, -900, :second)
      }

    refute Dashboard.stale_agent_run?(fresh_run, now, 300)
    assert Dashboard.stale_agent_run?(stale_run, now, 300)
    refute Dashboard.stale_agent_run?(stopped_run, now, 300)
  end

  test "runtime alert indicators expose stale, blocker, failed, stopped, and queued states without secrets", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret, grant: grant} =
      create_dashboard_fixture(repo, id: "SYMPP-RUNTIME-API", status: "blocked")

    assert {:ok, [run]} = AgentRunRepository.list_for_work_package(repo, work_package.id)
    assert {:ok, failed_run} = AgentRunRepository.mark_failed(repo, run.id, "failed with Bearer raw-secret-value")

    assert {:ok, stopped_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               access_grant_id: grant.id,
               actor_id: "worker-1",
               status: "running",
               attempt: 2,
               worker_task_handle: "stopped-task"
             })

    assert {:ok, _stopped_run} = AgentRunRepository.mark_stopped(repo, stopped_run.id, "operator stopped raw-secret-value")

    assert {:ok, queued_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               access_grant_id: grant.id,
               actor_id: "worker-1",
               status: "starting",
               attempt: 3,
               worker_task_handle: "queued-task",
               session_id: "session-queued"
             })

    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -600, :second)

    assert {:ok, _stale_queued_run} =
             queued_run
             |> AgentRun.update_changeset(%{last_seen_at: stale_seen_at})
             |> repo.update()

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["summary"]["active_agent_run_count"] == 1
    assert payload["summary"]["queued_agent_run_count"] == 1
    assert payload["summary"]["stopped_agent_run_count"] == 1
    assert payload["summary"]["failed_agent_run_count"] == 1
    assert payload["summary"]["stale_agent_run_count"] == 1
    assert payload["summary"]["runtime"]["stale_heartbeat_after_seconds"] == 300

    assert Enum.any?(payload["agent_runs"], &(&1["id"] == failed_run.id and &1["runtime_state"] == "terminal"))
    assert Enum.any?(payload["agent_runs"], &(&1["runtime_state"] == "stopped"))
    assert Enum.any?(payload["agent_runs"], &(&1["runtime_state"] == "queued" and &1["stale"] == true))

    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})
    assert alerts["blocker"]["active"] == true
    assert alerts["stale_heartbeat"]["active"] == true
    assert alerts["failed_run"]["active"] == true
    assert alerts["scope_drift"]["placeholder"] == false
    assert alerts["scope_drift"]["reasons"] == []
    refute alerts["scope_drift"]["active"]

    encoded = Jason.encode!(payload)
    refute encoded =~ "raw-secret-value"
    refute encoded =~ "Bearer "
  end

  test "blocked packages do not show an active blocker alert after blockers are resolved", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUNTIME-RESOLVED-BLOCKER", status: "blocked"))

    secret = create_architect_grant_secret(repo, work_package.id)
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _reported} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Blocked",
               status: "blocked",
               payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "blocker-a", active: true},
               created_at: timestamp
             })

    assert {:ok, _resolved} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Unblocked",
               status: "unblocked",
               payload: %{type: "blocker", source_tool: "resolve_blocker", blocker_id: "blocker-a", active: false},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})

    assert payload["summary"]["active_blocker_count"] == 0
    refute alerts["blocker"]["active"]
    assert alerts["blocker"]["detail"] == "0 active blockers"
  end

  test "stale alert uses the latest active run heartbeat", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUNTIME-CURRENT", status: "implementing"))

    secret = create_architect_grant_secret(repo, work_package.id)
    now = DateTime.utc_now(:microsecond)

    assert {:ok, _older_stale_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "older-stale",
               last_seen_at: DateTime.add(now, -600, :second)
             })

    assert {:ok, [older_stale_run]} = AgentRunRepository.list_for_work_package(repo, work_package.id)
    assert {:ok, _stopped_run} = AgentRunRepository.mark_stopped(repo, older_stale_run.id, "superseded")

    assert {:ok, _fresh_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               status: "running",
               attempt: 2,
               worker_task_handle: "fresh-active",
               last_seen_at: now
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})

    assert payload["summary"]["active_agent_run_count"] == 1
    assert payload["summary"]["stale_agent_run_count"] == 0
    refute alerts["stale_heartbeat"]["active"]
  end

  test "ready packages missing readiness evidence are flagged in API", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-MISSING",
                 kind: "mcp",
                 status: "ready_for_human_merge",
                 policy_template: "mcp"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert missing["active"] == true
    assert "plan_complete" in missing["missing"]
    assert "acceptance_criteria_met" in missing["missing"]
    assert "tests_passed" in missing["missing"]
    assert "branch_attached" in missing["missing"]
    assert "pr_attached" in missing["missing"]
    assert "review_package_submitted" in missing["missing"]
  end

  test "ready packages with in-progress plan nodes flag missing plan evidence", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-IN-PROGRESS-PLAN",
                 kind: "mcp",
                 status: "ready_for_human_merge",
                 policy_template: "mcp"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    append_ready_evidence_with_review_artifacts(repo, work_package, ["review-log.txt"])

    timestamp = DateTime.utc_now(:microsecond)

    repo.query!(
      """
      INSERT INTO sympp_plan_nodes
        (id, work_package_id, title, body, status, position, created_at, inserted_at, updated_at)
      VALUES
        (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
      """,
      [
        "plan_in_progress",
        work_package.id,
        "Still running",
        "Not done",
        "in_progress",
        2,
        timestamp,
        timestamp,
        timestamp
      ]
    )

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert missing["active"] == true
    assert "plan_complete" in missing["missing"]
    refute "review_artifacts_attached" in missing["missing"]
    refute "review_package_submitted" in missing["missing"]
    refute "tests_passed" in missing["missing"]
    refute "acceptance_criteria_met" in missing["missing"]
    refute "review_lanes_complete" in missing["missing"]
  end

  test "ready packages with review package but no artifacts flag artifact evidence", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-NO-ARTIFACTS",
                 kind: "mcp",
                 status: "ready_for_human_merge",
                 policy_template: "mcp"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    append_ready_evidence_without_artifacts(repo, work_package)

    assert {:ok, _unrelated_artifact} =
             PlanningService.append_artifact(repo, %{
               work_package_id: work_package.id,
               path: "notes.txt",
               title: "Unrelated notes",
               kind: "note",
               uri: "file://notes.txt"
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert missing["active"] == true
    assert "review_artifacts_attached" in missing["missing"]
    refute "review_package_submitted" in missing["missing"]
    refute "branch_attached" in missing["missing"]
    refute "pr_attached" in missing["missing"]
    refute "tests_passed" in missing["missing"]
    refute "acceptance_criteria_met" in missing["missing"]
    refute "review_lanes_complete" in missing["missing"]
  end

  test "package detail exposes sanitized review-suite result evidence", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-DASH-REVIEW-SUITE",
                 kind: "mcp",
                 status: "ready_for_human_merge",
                 policy_template: "mcp_review_suite_artifact"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    append_ready_evidence_with_review_artifacts(repo, work_package, ["review-log.txt"])

    assert {:ok, _review_suite_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Review suite passed",
               idempotency_key: "attach_review_suite_result:#{work_package.id}:dashboard-review-suite",
               status: "review_suite_passed",
               created_at: ~U[2026-05-05 00:00:10Z],
               payload: %{
                 type: "review_suite_result",
                 source_tool: "attach_review_suite_result",
                 work_package_id: work_package.id,
                 head_sha: "abc123",
                 suite: "review-suite",
                 anchor: "phase_gate-abc123",
                 status: "passed",
                 verdict: "green",
                 summary: "brief and normal green",
                 lane: "normal",
                 reviewer: "Bearer raw-review-token"
               }
             })

    assert {:ok, _older_review_suite_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Older review suite failed",
               idempotency_key: "attach_review_suite_result:#{work_package.id}:dashboard-review-suite-failed",
               status: "review_suite_failed",
               created_at: ~U[2026-05-05 00:00:00Z],
               payload: %{
                 type: "review_suite_result",
                 source_tool: "attach_review_suite_result",
                 work_package_id: work_package.id,
                 head_sha: "abc123",
                 suite: "review-suite",
                 anchor: "phase_gate-abc123-failed",
                 status: "failed",
                 verdict: "red",
                 summary: "Older failed result"
               }
             })

    assert {:ok, _review_suite_artifact} =
             PlanningRepository.append_artifact(repo, %{
               id: review_suite_artifact_id(work_package.id, "abc123"),
               work_package_id: work_package.id,
               path: "review-suite-result.json",
               title: "Review-suite result",
               kind: "review_suite"
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert payload["metadata"]["review_suite_result"]["status"] == "passed"
    assert payload["metadata"]["review_suite_result"]["verdict"] == "green"
    assert payload["metadata"]["review_suite_result"]["anchor"] == "phase_gate-abc123"
    assert Enum.any?(payload["artifacts"], &(&1["kind"] == "review_suite" and &1["path"] == "review-suite-result.json"))
    refute "review_suite_result" in missing["missing"]
    refute inspect(payload) =~ "raw prompt"
    refute inspect(payload) =~ "Bearer "
  end

  test "latest no-artifact review package does not reuse older artifact evidence", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-STALE-ARTIFACT",
                 kind: "mcp",
                 status: "ready_for_human_merge",
                 policy_template: "mcp"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    append_ready_evidence_with_review_artifacts(repo, work_package, ["review-log.txt"])
    append_review_package(repo, work_package, [], DateTime.add(~U[2026-05-05 00:00:00Z], 5, :second))

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert missing["active"] == true
    assert "review_artifacts_attached" in missing["missing"]
    refute "review_package_submitted" in missing["missing"]
    refute "tests_passed" in missing["missing"]
    refute "acceptance_criteria_met" in missing["missing"]
    refute "review_lanes_complete" in missing["missing"]
  end

  test "malformed review package tests payload is treated as missing evidence", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-MALFORMED-TESTS",
                 kind: "mcp",
                 status: "ready_for_human_merge",
                 policy_template: "mcp"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    append_ready_evidence_with_review_artifacts(repo, work_package, ["review-log.txt"])

    assert {:ok, _malformed_review_package} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Malformed review package submitted",
               status: "review_package_submitted",
               payload: %{
                 type: "review_package",
                 source_tool: "submit_review_package",
                 acceptance_criteria_met: true,
                 tests: "mix test",
                 artifacts: ["review-log.txt"],
                 reviews: [
                   %{lane: "brief", verdict: "green"},
                   %{lane: "normal", verdict: "green"}
                 ],
                 head_sha: "abc123"
               },
               created_at: DateTime.add(~U[2026-05-05 00:00:00Z], 5, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert missing["active"] == true
    assert "tests_passed" in missing["missing"]
    refute "review_package_submitted" in missing["missing"]
    refute "review_artifacts_attached" in missing["missing"]
    refute "acceptance_criteria_met" in missing["missing"]
    refute "review_lanes_complete" in missing["missing"]
  end

  test "generic readiness statuses before latest branch do not clear missing evidence", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-BRANCH-BOUND",
                 kind: "quick_fix",
                 status: "ready_for_human_merge",
                 policy_template: "quick_fix"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _old_tests} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Old tests passed",
               status: "tests_passed",
               payload: %{},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _old_review} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Old review green",
               status: "review_brief_green",
               payload: %{},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _new_branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "New branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "new-head"},
               created_at: DateTime.add(timestamp, 3, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert "tests_passed" in missing["missing"]
    assert "review_lanes_complete" in missing["missing"]
    refute "branch_attached" in missing["missing"]
  end

  test "readiness remains anchored to the latest branch head after PR attach", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-PR-HEAD",
                 kind: "mcp",
                 status: "ready_for_human_merge",
                 policy_template: "mcp"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _plan_node} =
             PlanningRepository.append_plan_node(repo, %{
               work_package_id: work_package.id,
               title: "Implement package",
               status: "done",
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "old-head"},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/7", head_sha: "new-head"},
               created_at: DateTime.add(timestamp, 3, :second)
             })

    append_review_package(repo, work_package, ["review-log.txt"], DateTime.add(timestamp, 4, :second), "new-head")

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               id: review_artifact_id(work_package.id, "new-head", "review-log.txt"),
               work_package_id: work_package.id,
               path: "review-log.txt",
               title: "review-log.txt",
               kind: "review",
               uri: "file://review-log.txt"
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert missing["active"] == true
    refute "branch_attached" in missing["missing"]
    assert "pr_attached" in missing["missing"]
    assert "review_package_submitted" in missing["missing"]
    assert "tests_passed" in missing["missing"]
    assert "review_lanes_complete" in missing["missing"]
  end

  test "dashboard readiness does not accept PR sync without attached PR identity", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-SYNC-WITHOUT-ATTACH",
                 kind: "mcp",
                 status: "ready_for_human_merge",
                 policy_template: "mcp"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _pr_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced without attach",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/7",
                 head_sha: "head-a",
                 check_summary: %{conclusion: "success"}
               },
               created_at: DateTime.add(timestamp, 2, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert "pr_attached" in missing["missing"]
    assert payload["metadata"]["pr"] == nil
  end

  test "dashboard current PR state gate validates synced state separately from attachment", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-CURRENT-PR-STATE",
                 kind: "mcp",
                 status: "ready_for_human_merge",
                 policy_template: "mcp_current_pr_state"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/8", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    refute "pr_attached" in missing["missing"]
    assert "current_pr_state" in missing["missing"]

    assert {:ok, _invalid_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/8",
                 head_sha: "head-a",
                 check_summary: %{token: "x"}
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    invalid_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    invalid_missing = Enum.find(invalid_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert "current_pr_state" in invalid_missing["missing"]

    assert {:ok, _raw_state_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/8",
                 head_sha: "head-a",
                 review_state: %{draft: false},
                 merge_state: %{state: "open"}
               },
               created_at: DateTime.add(timestamp, 4, :second)
             })

    raw_state_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    raw_state_missing = Enum.find(raw_state_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert "current_pr_state" in raw_state_missing["missing"]

    assert {:ok, _boolean_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/8",
                 head_sha: "head-a",
                 merge_state: %{mergeable: true, merged: false}
               },
               created_at: DateTime.add(timestamp, 5, :second)
             })

    boolean_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    boolean_missing = Enum.find(boolean_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    refute "current_pr_state" in boolean_missing["missing"]

    assert {:ok, _valid_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/8",
                 head_sha: "head-a",
                 check_summary: %{conclusion: "success"}
               },
               created_at: DateTime.add(timestamp, 6, :second)
             })

    valid_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    valid_missing = Enum.find(valid_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    refute "current_pr_state" in valid_missing["missing"]

    assert {:ok, _same_pr_reattach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR reattached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/8", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 7, :second)
             })

    reattach_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    reattach_missing = Enum.find(reattach_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert "current_pr_state" in reattach_missing["missing"]
    assert reattach_payload["metadata"]["pr"]["source_tool"] == "attach_pr"
    refute Map.has_key?(reattach_payload["metadata"]["pr"], "check_summary")

    assert {:ok, _resync_after_reattach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/8",
                 head_sha: "head-a",
                 check_summary: %{conclusion: "success"}
               },
               created_at: DateTime.add(timestamp, 8, :second)
             })

    assert {:ok, _new_pr_attach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Different PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/9", head_sha: "head-a"},
               created_at: DateTime.add(timestamp, 9, :second)
             })

    different_pr_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    different_pr_missing = Enum.find(different_pr_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert "current_pr_state" in different_pr_missing["missing"]
    assert different_pr_payload["metadata"]["pr"]["url"] == "https://github.com/example/repo/pull/9"
    refute Map.has_key?(different_pr_payload["metadata"]["pr"], "check_summary")

    assert {:ok, _new_branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch advanced",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-b"},
               created_at: DateTime.add(timestamp, 10, :second)
             })

    stale_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    stale_missing = Enum.find(stale_payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert "current_pr_state" in stale_missing["missing"]
  end

  test "dashboard exposes structured scope guard readiness reasons without synced secrets", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-SCOPE-GUARD",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 status: "ready_for_human_merge",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: ["elixir/lib/**"]
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    timestamp = ~U[2026-05-05 00:00:00Z]
    head_sha = "scope-dashboard-head"

    assert {:ok, _plan_node} =
             PlanningRepository.append_plan_node(repo, %{
               work_package_id: work_package.id,
               title: "Complete implementation",
               status: "done"
             })

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/#{work_package.id}", "head_sha" => head_sha},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/12", "head_sha" => head_sha},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 "type" => "pr",
                 "source_tool" => "sync_pr",
                 "url" => "https://github.com/nextide/symphony-plus-plus/pull/12",
                 "head_sha" => head_sha,
                 "base_branch" => "symphony-plus-plus/beta",
                 "changed_files" => [
                   %{"path" => "elixir/lib/symphony_elixir/symphony_plus_plus/dashboard.ex"},
                   %{"path" => "docs/scope-dashboard.md", "token" => "ghp_dashboard_secret"}
                 ],
                 "changed_files_count" => 2,
                 "check_summary" => %{"conclusion" => "success", "token" => "ghp_dashboard_secret"},
                 "review_state" => %{"state" => "approved"},
                 "merge_state" => %{"state" => "clean"}
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    assert {:ok, _review_package} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Review package",
               status: "review_package_submitted",
               payload: %{
                 "type" => "review_package",
                 "source_tool" => "submit_review_package",
                 "head_sha" => head_sha,
                 "summary" => "Ready review package",
                 "tests" => ["mix test"],
                 "artifacts" => ["review.txt"],
                 "acceptance_criteria_met" => true,
                 "reviews" => [%{"lane" => "brief", "verdict" => "green"}, %{"lane" => "normal", "verdict" => "green"}]
               },
               created_at: DateTime.add(timestamp, 4, :second)
             })

    assert {:ok, _review_artifact} =
             PlanningRepository.append_artifact(repo, %{
               id: review_artifact_id(work_package.id, head_sha, "review.txt"),
               work_package_id: work_package.id,
               path: "review.txt",
               title: "Review artifact",
               kind: "review"
             })

    assert {:ok, _review_suite_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "attach_review_suite_result:#{work_package.id}:dashboard-scope-suite",
               summary: "Review-suite result",
               status: "review_suite_passed",
               payload: %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => work_package.id,
                 "head_sha" => head_sha,
                 "suite" => "review-suite",
                 "anchor" => "phase_gate-dashboard-scope",
                 "summary" => "Review suite passed",
                 "status" => "passed",
                 "verdict" => "green"
               },
               created_at: DateTime.add(timestamp, 5, :second)
             })

    assert {:ok, _review_suite_artifact} =
             PlanningRepository.append_artifact(repo, %{
               id: review_suite_artifact_id(work_package.id, head_sha),
               work_package_id: work_package.id,
               path: "review-suite-result.json",
               title: "Review-suite result",
               kind: "review_suite"
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})
    missing = alerts["missing_readiness_evidence"]
    scope = alerts["scope_drift"]

    assert "scope_guard" in missing["missing"]
    assert [%{"code" => "out_of_scope_files", "files" => ["docs/scope-dashboard.md"]}] = missing["reasons"]
    assert scope["active"] == true
    assert scope["reasons"] == missing["reasons"]
    refute Jason.encode!(payload) =~ "ghp_dashboard_secret"
  end

  test "dashboard does not treat missing scope preconditions as critical drift", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-SCOPE-PRECONDITION",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 status: "ready_for_human_merge",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: ["elixir/lib/**"]
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    alerts = Map.new(payload["alert_indicators"], &{&1["type"], &1})
    scope = alerts["scope_drift"]

    assert scope["active"] == false
    assert scope["severity"] == "info"
    assert [%{"code" => "missing_current_head"}] = scope["reasons"]

    timestamp = ~U[2026-05-05 00:00:00Z]
    head_sha = "scope-precondition-head"

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{"type" => "branch", "source_tool" => "attach_branch", "branch" => "agent/#{work_package.id}", "head_sha" => head_sha},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{"type" => "pr", "source_tool" => "attach_pr", "url" => "https://github.com/nextide/symphony-plus-plus/pull/13", "head_sha" => head_sha},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 "type" => "pr",
                 "source_tool" => "sync_pr",
                 "url" => "https://github.com/nextide/symphony-plus-plus/pull/13",
                 "head_sha" => head_sha,
                 "base_branch" => "symphony-plus-plus/beta",
                 "changed_files" => [],
                 "changed_files_count" => 0,
                 "changed_files_available" => false
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    blocked_payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    blocked_alerts = Map.new(blocked_payload["alert_indicators"], &{&1["type"], &1})
    blocked_scope = blocked_alerts["scope_drift"]

    assert blocked_scope["active"] == true
    assert blocked_scope["severity"] == "warning"
    assert blocked_scope["detail"] == "Scope guard evidence unavailable: changed_files_unavailable"
    assert [%{"code" => "changed_files_unavailable"}] = blocked_scope["reasons"]
  end

  test "detail API exposes stale synced PR metadata without secrets", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-STALE-PR",
                 kind: "mcp",
                 status: "ready_for_human_merge",
                 policy_template: "mcp"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "branch-head"},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _attached_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/44", head_sha: "old-pr-head"},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/44",
                 repository: "example/repo",
                 number: 44,
                 head_sha: "old-pr-head",
                 changed_files: [%{path: "elixir/lib/example.ex"}],
                 check_summary: %{token: "ghp_should_be_redacted"}
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["pr"]["url"] == "https://github.com/example/repo/pull/44"
    assert payload["metadata"]["pr"]["stale"] == true
    assert payload["metadata"]["pr"]["current_head_sha"] == "branch-head"
    assert payload["metadata"]["pr"]["check_summary"]["token"] == "[REDACTED]"
    refute inspect(payload) =~ "ghp_should_be_redacted"
  end

  test "metadata prefers current-head PR over newer stale PR", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-CURRENT-PREFERRED", status: "planning"))

    architect_secret = create_architect_grant_secret(repo, work_package.id)

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{
                 type: "branch",
                 source_tool: "attach_branch",
                 branch: "agent/#{work_package.id}",
                 head_sha: "abcdef1234567890abcdef1234567890abcdef12"
               },
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, _current_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Current PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "abcdef1234567890abcdef1234567890abcdef12"
               },
               created_at: ~U[2026-05-05 00:00:01Z]
             })

    assert {:ok, _current_pr_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Current PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "abcdef1234567890abcdef1234567890abcdef12"
               },
               created_at: ~U[2026-05-05 00:00:02Z]
             })

    assert {:ok, _stale_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Older PR sync arrived late",
               status: "pr_synced",
               payload: %{type: "pr", source_tool: "sync_pr", url: "https://github.com/example/repo/pull/10", head_sha: "old-head"},
               created_at: ~U[2026-05-05 00:00:03Z]
             })

    payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["pr"]["head_sha"] == "abcdef1234567890abcdef1234567890abcdef12"
    assert payload["metadata"]["pr"]["stale"] == false
    assert payload["metadata"]["pr"]["current_head_sha"] == "abcdef1234567890abcdef1234567890abcdef12"
  end

  test "metadata treats abbreviated branch head as current against full PR head", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-SHORT-HEAD-STALE", status: "planning"))

    architect_secret = create_architect_grant_secret(repo, work_package.id)

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "abcdef1"},
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "abcdef1234567890abcdef1234567890abcdef12"
               },
               created_at: ~U[2026-05-05 00:00:01Z]
             })

    assert {:ok, _sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "abcdef1234567890abcdef1234567890abcdef12"
               },
               created_at: ~U[2026-05-05 00:00:02Z]
             })

    payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["pr"]["stale"] == false
    assert payload["metadata"]["pr"]["current_head_sha"] == "abcdef1"
  end

  test "metadata stays scoped to latest attached PR after reattach", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-REATTACHED", status: "planning"))

    architect_secret = create_architect_grant_secret(repo, work_package.id)

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "current-head"},
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, _first_pr_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "First PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 repository: "example/repo",
                 number: 10,
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "current-head"
               },
               created_at: ~U[2026-05-05 00:00:01Z]
             })

    assert {:ok, _reattached_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR reattached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 repository: "example/repo",
                 number: 11,
                 url: "https://github.com/example/repo/pull/11",
                 head_sha: "old-head"
               },
               created_at: ~U[2026-05-05 00:00:02Z]
             })

    payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["pr"]["url"] == "https://github.com/example/repo/pull/11"
    assert payload["metadata"]["pr"]["stale"] == true
    assert payload["metadata"]["pr"]["current_head_sha"] == "current-head"
  end

  test "metadata does not display stale synced PR state after later reattach", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-SYNC-DISPLAY-PREFERRED", status: "planning"))

    architect_secret = create_architect_grant_secret(repo, work_package.id)

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{
                 type: "branch",
                 source_tool: "attach_branch",
                 branch: "agent/#{work_package.id}",
                 head_sha: "current-head"
               },
               created_at: ~U[2026-05-05 00:00:00Z]
             })

    assert {:ok, _first_attach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 repository: "example/repo",
                 number: 10,
                 url: "https://github.com/example/repo/pull/10"
               },
               created_at: ~U[2026-05-05 00:00:01Z]
             })

    assert {:ok, _sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 repository: "example/repo",
                 number: 10,
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "current-head",
                 check_summary: %{conclusion: "success"},
                 review_state: %{state: "approved"},
                 merge_state: %{state: "clean"}
               },
               created_at: ~U[2026-05-05 00:00:02Z]
             })

    assert {:ok, _reattach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR reattached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 repository: "example/repo",
                 number: 10,
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "current-head"
               },
               created_at: ~U[2026-05-05 00:00:03Z]
             })

    payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["pr"]["source_tool"] == "attach_pr"
    refute Map.has_key?(payload["metadata"]["pr"], "check_summary")
    refute Map.has_key?(payload["metadata"]["pr"], "review_state")
    refute Map.has_key?(payload["metadata"]["pr"], "merge_state")

    assert {:ok, _rich_reattach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR reattached with richer metadata",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 repository: "example/repo",
                 number: 10,
                 url: "https://github.com/example/repo/pull/10",
                 head_sha: "current-head",
                 check_summary: %{conclusion: "success", total_count: 7},
                 review_state: %{state: "approved"},
                 merge_state: %{state: "clean"}
               },
               created_at: ~U[2026-05-05 00:00:04Z]
             })

    rich_payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert rich_payload["metadata"]["pr"]["source_tool"] == "attach_pr"
    assert rich_payload["metadata"]["pr"]["check_summary"]["total_count"] == 7
  end

  test "unknown policy lookup does not invent merge or review evidence requirements", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-RUNTIME-UNKNOWN-POLICY",
                 kind: "dashboard",
                 status: "ready_for_human_merge"
               )
             )

    secret = create_architect_grant_secret(repo, work_package.id)

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    missing = Enum.find(payload["alert_indicators"], &(&1["type"] == "missing_readiness_evidence"))

    assert missing["active"] == true
    assert "plan_complete" in missing["missing"]
    refute "acceptance_criteria_met" in missing["missing"]
    refute "tests_passed" in missing["missing"]
    refute "branch_attached" in missing["missing"]
    refute "pr_attached" in missing["missing"]
    refute "review_package_submitted" in missing["missing"]
    refute "review_lanes_complete" in missing["missing"]
  end

  test "card summaries use total counts and full progress metadata", %{repo: repo} do
    %{work_package: work_package} = create_dashboard_fixture(repo)
    timestamp = ~U[2026-05-05 00:02:00Z]

    for index <- 1..105 do
      assert {:ok, _event} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: work_package.id,
                 summary: "Heartbeat #{index}",
                 status: "working",
                 payload: %{type: "status", source_tool: "test"},
                 created_at: DateTime.add(timestamp, index, :second)
               })
    end

    assert {:ok, _backfilled_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Backfilled older event",
               status: "working",
               payload: %{type: "status", source_tool: "test"},
               created_at: DateTime.add(timestamp, -1, :second)
             })

    for index <- 1..101 do
      assert {:ok, _finding} =
               PlanningRepository.append_finding(repo, %{
                 work_package_id: work_package.id,
                 title: "Finding #{index}",
                 body: "Finding body #{index}",
                 severity: "low",
                 created_at: DateTime.add(timestamp, 200 + index, :second)
               })

      assert {:ok, _artifact} =
               PlanningService.append_artifact(repo, %{
                 work_package_id: work_package.id,
                 path: "artifact-#{index}.txt",
                 title: "Artifact #{index}",
                 kind: "log",
                 created_at: DateTime.add(timestamp, 400 + index, :second)
               })
    end

    assert {:ok, card} = Dashboard.card(repo, work_package)
    assert card.finding_count == 102
    assert card.artifact_count == 102
    assert card.active_blocker_count == 1
    assert {:ok, latest_progress_at, _offset} = DateTime.from_iso8601(card.latest_progress_at)
    assert DateTime.compare(latest_progress_at, DateTime.add(timestamp, 105, :second)) == :eq
    assert card.metadata.pr["url"] == "https://github.com/example/repo/pull/1"
  end

  test "metadata preserves PR and suppresses review payloads without a current branch head", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BRANCHLESS", status: "planning"))

    architect_secret = create_architect_grant_secret(repo, work_package.id)

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached without branch",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/99", head_sha: "stale"}
             })

    assert {:ok, _review_package} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Review submitted without branch",
               status: "review_package_submitted",
               payload: %{type: "review_package", source_tool: "submit_review_package", head_sha: "stale", artifacts: ["review.txt"]}
             })

    payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["branch"] == nil
    assert payload["metadata"]["pr"]["url"] == "https://github.com/example/repo/pull/99"
    assert payload["metadata"]["pr"]["head_sha"] == "stale"
    refute Map.has_key?(payload["metadata"]["pr"], "stale")
    refute Map.has_key?(payload["metadata"]["pr"], "current_head_sha")
    assert payload["metadata"]["review_package"] == nil
  end

  test "timeline endpoint includes progress, finding, and status events in useful order", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret, grant: grant} = create_dashboard_fixture(repo)
    assert {:ok, [run]} = AgentRunRepository.list_for_work_package(repo, work_package.id)

    assert {:ok, _run_bound_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Run-bound package progress",
               status: "working",
               actor_id: "worker-1",
               actor_type: "worker",
               access_grant_id: grant.id,
               agent_run_id: run.id,
               payload: %{type: "status", source_tool: "test"}
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/timeline"), 200)

    assert [
             %{"type" => "progress", "status" => "branch_attached"},
             %{"type" => "progress", "status" => "pr_attached"},
             %{"type" => "progress", "status" => "blocked"},
             %{"type" => "finding", "severity" => "medium"}
           ] = Enum.take(payload["events"], 4)

    assert Enum.any?(payload["events"], &(&1["status"] == "review_package_submitted"))
    assert Enum.any?(payload["events"], &(&1["summary"] == "Run-bound package progress"))

    encoded = Jason.encode!(payload)
    refute encoded =~ grant.id
    refute encoded =~ run.id
    refute encoded =~ "worker-1"
    assert encoded =~ "[REDACTED]"
  end

  test "dashboard detail redacts text and reports current-head summaries", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(repo)
    timestamp = ~U[2026-05-05 00:01:00Z]
    unclaimed_key = WorkKey.generate()

    assert {:ok, _skipped} =
             PlanningRepository.append_plan_node(repo, %{
               work_package_id: work_package.id,
               title: "Skipped follow-up",
               body: "No longer needed",
               status: "skipped",
               created_at: timestamp
             })

    assert {:ok, _secret_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Leaked signed URL https://example.test/file.txt?sig=raw-secret-value",
               body: "Bearer raw-secret-value",
               status: "blocked",
               payload: %{type: "status", source_tool: "test"},
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _secret_finding} =
             PlanningRepository.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "Token raw-secret-value",
               body: "secret raw-secret-value",
               severity: "high",
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _normal_finding} =
             PlanningRepository.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "Token bucket note",
               body: "Secretary review is not a credential",
               severity: "low",
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _new_branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "New branch head attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "def456"},
               created_at: DateTime.add(timestamp, 3, :second)
             })

    assert {:ok, _blank_changed_branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Changed branch without head",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}-new", head_sha: ""},
               created_at: DateTime.add(timestamp, 3, :second)
             })

    assert {:ok, _backfilled_old_branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Backfilled old branch",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}-old", head_sha: "old123"},
               created_at: DateTime.add(timestamp, -30, :second)
             })

    assert {:ok, _backfilled_old_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Backfilled old PR",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/old", head_sha: "old123"},
               created_at: DateTime.add(timestamp, -29, :second)
             })

    assert {:ok, _spoofed_blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Spoofed blocker",
               status: "blocked",
               payload: %{type: "blocker", source_tool: "append_progress", blocker_id: "spoofed", active: true},
               created_at: DateTime.add(timestamp, 4, :second)
             })

    assert {:ok, _backfilled_old_blocker_resolution} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Backfilled old blocker resolution",
               status: "unblocked",
               payload: %{
                 type: "blocker",
                 source_tool: "resolve_blocker",
                 blocker_id: "blocker-a",
                 active: false,
                 resolution: "historical"
               },
               created_at: DateTime.add(timestamp, -120, :second)
             })

    assert {:ok, _unclaimed} =
             AccessGrantRepository.create(repo, %{
               work_package_id: work_package.id,
               display_key: unclaimed_key.display_key,
               secret_hash: WorkKey.secret_hash(unclaimed_key.secret),
               grant_role: "worker",
               capabilities: ["read:work_package"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)
    encoded = inspect(payload)

    refute encoded =~ "raw-secret-value"
    refute encoded =~ "wk_"
    assert Enum.any?(payload["progress"], &(&1["summary"] == "[REDACTED]"))
    assert Enum.any?(payload["progress"], &(&1["body"] == "[REDACTED]"))
    assert Enum.any?(payload["findings"], &(&1["title"] == "[REDACTED]"))
    assert Enum.any?(payload["findings"], &(&1["title"] == "Token bucket note"))
    assert payload["summary"]["plan"] == %{"completed_count" => 2, "open_count" => 0, "total_count" => 2}
    assert payload["summary"]["active_blocker_count"] == 1
    assert Enum.any?(payload["blockers"], &(&1["id"] == "blocker-a" and &1["active"] == true))
    refute Enum.any?(payload["blockers"], &(&1["id"] == "spoofed"))
    assert payload["summary"]["grant_count"] == 1
    assert payload["summary"]["active_grant_count"] == 1
    assert Enum.any?(payload["grants"], &(&1["status"] == "active"))
    refute Enum.any?(payload["grants"], &(&1["status"] == "unclaimed"))
    assert payload["metadata"]["branch"]["branch"] == "agent/#{work_package.id}-new"
    assert payload["metadata"]["branch"]["head_sha"] == ""
    assert payload["metadata"]["pr"]["url"] == "https://github.com/example/repo/pull/1"
    assert payload["metadata"]["pr"]["head_sha"] == "abc123"
    refute Map.has_key?(payload["metadata"]["pr"], "stale")
    assert payload["metadata"]["review_package"] == nil
  end

  test "blank branch head sha reuses latest head for the same branch", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(repo)

    assert {:ok, _blank_branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached without head",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: ""},
               created_at: ~U[2026-05-05 00:03:00Z]
             })

    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["metadata"]["branch"]["head_sha"] == ""
    assert payload["metadata"]["pr"]["url"] == "https://github.com/example/repo/pull/1"
  end

  test "dedicated collection endpoints fetch artifacts, blockers, grants, and agent runs", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(repo)

    assert %{"artifacts" => [%{"path" => "[REDACTED]", "title" => "[REDACTED]"} = artifact]} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/artifacts"), 200)

    refute Map.has_key?(artifact, "metadata")

    assert %{"blockers" => [%{"id" => "blocker-a", "active" => true}]} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/blockers"), 200)

    assert %{"grants" => [%{"grant_role" => "worker"}]} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/grants"), 200)

    assert %{"agent_runs" => [%{"worker_task_handle" => "task-1"}]} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/agent-runs"), 200)
  end

  test "worker-scoped API cannot fetch global board and cannot fetch sibling packages", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret, grant: grant} = create_dashboard_fixture(repo)
    assert {:ok, sibling} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-SIBLING"))
    store_dir = Path.join(System.tmp_dir!(), "sympp-api-worker-handoff-#{System.unique_integer([:positive])}")
    previous_store_dir = Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir)

    Application.put_env(:symphony_elixir, :sympp_worker_secret_store_dir, store_dir)

    on_exit(fn ->
      restore_store_dir_env(previous_store_dir)
      File.rm_rf(store_dir)
    end)

    handoff_opts = [
      mode: "windows-credential-manager",
      store_dir: store_dir,
      database: Application.fetch_env!(:symphony_elixir, :sympp_repo_database),
      repo_root: @repo_root,
      claimed_by: "local-operator-worker"
    ]

    handoff = %{mode: "windows-credential-manager", target: credential_target(work_package, grant)}
    assert :ok = SecretHandoff.store_worker_secret_metadata(work_package, grant, handoff, handoff_opts)

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 403)

    assert %{"work_package" => %{"id" => fetched_id}, "worker_secret_handoffs" => []} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert fetched_id == work_package.id

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{sibling.id}"), 403)
  end

  test "dashboard API rejects unauthenticated reads", %{repo: repo} do
    %{work_package: work_package} = create_dashboard_fixture(repo)

    assert %{"error" => %{"code" => "unauthorized"}} =
             json_response(get(build_conn(), "/api/v1/sympp/board"), 401)

    assert %{"error" => %{"code" => "unauthorized"}} =
             json_response(get(build_conn(), "/api/v1/sympp/work-packages/#{work_package.id}"), 401)

    unknown_work_key_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{WorkKey.generate().secret}")

    assert %{"error" => %{"code" => "unauthorized"}} =
             json_response(get(unknown_work_key_conn, "/api/v1/sympp/board"), 401)
  end

  test "local operator dashboard returns aggregate workflow state", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, work_request} =
               WorkRequestRepository.create(repo, %{
                 title: "Operator intake",
                 repo: "symphony-plus-plus",
                 base_branch: "main",
                 work_type: "feature",
                 human_description: "Build the dashboard.",
                 constraints: %{},
                 desired_dispatch_shape: "architect_led_feature_branch",
                 status: "ready_for_clarification"
               })

      assert {:ok, archived_request} =
               WorkRequestRepository.create(repo, %{
                 title: "Archived operator intake",
                 repo: "symphony-plus-plus",
                 base_branch: "main",
                 work_type: "feature",
                 human_description: "Completed earlier.",
                 constraints: %{},
                 desired_dispatch_shape: "single_package",
                 status: "ready_for_slicing"
               })

      assert {:ok, slice} = WorkRequestRepository.add_planned_slice(repo, archived_request.id, planned_slice_attrs(id: "WRS-OPERATOR-ARCHIVE"))
      assert {:ok, _skipped} = WorkRequestRepository.skip_planned_slice(repo, archived_request.id, slice.id, "planned")

      archived_request
      |> Ecto.Changeset.change(completed_at: %{~U[2026-05-01 00:00:00Z] | microsecond: {0, 6}})
      |> Ecto.Changeset.change(archived_at: %{~U[2026-05-16 00:00:00Z] | microsecond: {0, 6}})
      |> repo.update!()

      payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard"), 200)

      assert payload["work_requests"]["total_count"] == 1
      assert [%{"work_request" => %{"id" => work_request_id}}] = payload["work_request_details"]
      assert work_request_id == work_request.id
      refute Enum.any?(payload["work_requests"]["work_requests"], &(&1["id"] == archived_request.id))

      assert {:ok, archived} = WorkRequestRepository.get(repo, archived_request.id)
      assert %DateTime{} = archived.archived_at
    end)
  end

  test "local operator dashboard projects delivery closeout states into slice cards", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-DELIVERY", status: "ready_for_slicing")

      assert {:ok, planned_slice} =
               WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-LOCAL-DELIVERY-MERGED"))

      assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved_slice,
          id: "SYMPP-LOCAL-DELIVERY-MERGED",
          status: "ready_for_worker"
        )

      assert {:ok, _progress} =
               PlanningRepository.append_progress_event(repo, %{
                 work_package_id: work_package.id,
                 summary: "Worker progress exists",
                 status: "progress",
                 payload: %{type: "progress"}
               })

      assert {:ok, _dispatched_slice} =
               WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", work_package.id)

      assert {:ok, _delivery} =
               WorkRequestRepository.record_planned_slice_delivery(
                 repo,
                 work_request.id,
                 approved_slice.id,
                 delivery_attrs(%{
                   outcome: "pr_merged",
                   idempotency_key: "local-operator-dashboard-delivery-merged",
                   pr_url: "https://github.com/Pimpmuckl/symphony-plus-plus/pull/905",
                   pr_merged_at: ~U[2026-05-24 12:30:00.000000Z],
                   merge_commit_sha: "merge-905"
                 })
               )

      payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard"), 200)
      detail = work_request_detail(payload, work_request.id)
      [slice] = detail["planned_slices"]
      [card] = Enum.filter(payload["work_requests"]["work_requests"], &(&1["id"] == work_request.id))

      assert card["operational_state"]["key"] == "delivered"
      assert card["operational_state"]["has_started"] == true
      assert card["operational_state"]["has_active_worker"] == false
      assert card["operational_state"]["is_stale"] == true
      assert get_in(detail, ["work_request", "operational_state", "key"]) == "delivered"
      assert get_in(detail, ["work_request", "operational_state", "has_started"]) == true
      assert get_in(detail, ["work_request", "operational_state", "has_active_worker"]) == false
      assert get_in(detail, ["work_request", "operational_state", "is_stale"]) == true
      assert get_in(slice, ["operational_state", "key"]) == "delivered"
      assert get_in(slice, ["operational_state", "label"]) == "Delivered"
      assert get_in(slice, ["operational_state", "raw_status"]) == "dispatched"
      assert get_in(slice, ["operational_state", "work_package_status"]) == "ready_for_worker"
      assert get_in(slice, ["delivery", "outcome"]) == "pr_merged"
      assert "linked_package_status_stale_after_delivery" in slice["attention_reason_codes"]
      assert get_in(detail, ["delivery_board", "slices", Access.at(0), "operational_state", "key"]) == "delivered"
    end)
  end

  test "local operator dashboard infers canonical repo identity from local origin", %{repo: repo} do
    with_local_repo_origin("https://github.com/Pimpmuckl/symphony-plus-plus.git", fn ->
      with_local_operator_endpoint(fn ->
        assert {:ok, work_package} =
                 WorkPackageRepository.create(
                   repo,
                   WorkPackageFactory.attrs(
                     id: "SYMPP-REPO-IDENTITY",
                     repo: "symphony-plus-plus",
                     base_branch: "main"
                   )
                 )

        assert {:ok, _work_request} =
                 WorkRequestRepository.create(repo, %{
                   title: "Operator intake",
                   repo: "symphony-plus-plus",
                   base_branch: "main",
                   work_type: "feature",
                   human_description: "Build the dashboard.",
                   constraints: %{},
                   desired_dispatch_shape: "architect_led_feature_branch",
                   status: "ready_for_clarification"
                 })

        assert {:ok, owner_session} =
                 SoloSessionsService.create_or_attach_current(repo, %{
                   repo: "Pimpmuckl/symphony-plus-plus",
                   base_branch: "main",
                   workspace_path: Path.join(@repo_root, "repo-identity-owner"),
                   caller_id: "repo-identity-owner",
                   title: "Owner scoped solo"
                 })

        assert {:ok, bare_session} =
                 SoloSessionsService.create_or_attach_current(repo, %{
                   repo: "symphony-plus-plus",
                   base_branch: "main",
                   workspace_path: Path.join(@repo_root, "repo-identity-bare"),
                   caller_id: "repo-identity-bare",
                   title: "Bare scoped solo"
                 })

        guidance_grant = create_claimed_worker_grant(repo, work_package.id, "repo-identity-worker")

        assert {:ok, _guidance_request} =
                 GuidanceRequestRepository.create(repo, %{
                   work_package_id: work_package.id,
                   requester_grant_id: guidance_grant.id,
                   requested_by: "repo-identity-worker",
                   idempotency_key: "repo-identity-guidance",
                   summary: "Needs repo identity decision",
                   question: "Which repo identity should the dashboard show?",
                   context: "Operator dashboard canonical repo identity coverage.",
                   status: "human_info_needed"
                 })

        payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard"), 200)

        package_card =
          payload["board"]["groups"]["created"]
          |> Enum.find(&(&1["id"] == work_package.id))

        assert package_card["repo"] == "symphony-plus-plus"
        assert package_card["repo_key"] == "symphony-plus-plus"
        assert package_card["repo_display"] == "symphony-plus-plus"
        assert package_card["repo_remote"] == "Pimpmuckl/symphony-plus-plus"
        assert package_card["repo_aliases"] == ["Pimpmuckl/symphony-plus-plus", "symphony-plus-plus"]

        assert [%{"repo_key" => "symphony-plus-plus", "repo_remote" => "Pimpmuckl/symphony-plus-plus"}] =
                 payload["work_requests"]["work_requests"]

        assert [%{"work_request" => %{"repo_key" => "symphony-plus-plus", "repo_remote" => "Pimpmuckl/symphony-plus-plus"}}] =
                 payload["work_request_details"]

        assert [
                 %{
                   "repo" => "symphony-plus-plus",
                   "repo_key" => "symphony-plus-plus",
                   "repo_display" => "symphony-plus-plus",
                   "repo_remote" => "Pimpmuckl/symphony-plus-plus",
                   "repo_aliases" => ["Pimpmuckl/symphony-plus-plus", "symphony-plus-plus"]
                 }
               ] = payload["guidance_requests"]["guidance_requests"]

        solo_sessions = payload["solo_sessions"]["solo_sessions"]
        assert Enum.map(solo_sessions, & &1["id"]) |> Enum.sort() == Enum.sort([owner_session.id, bare_session.id])
        assert Enum.all?(solo_sessions, &(&1["repo_key"] == "symphony-plus-plus"))
        assert Enum.all?(solo_sessions, &(&1["repo_display"] == "symphony-plus-plus"))
        assert Enum.all?(solo_sessions, &(&1["repo_remote"] == "Pimpmuckl/symphony-plus-plus"))

        assert {:ok, repo_identity_catalog} = Dashboard.local_operator_repo_identity_catalog(repo)
        assert {:ok, streams} = Dashboard.solo_session_streams(repo, repo_identity_catalog: repo_identity_catalog)

        assert [
                 %{
                   repo_key: "symphony-plus-plus",
                   repo_display: "symphony-plus-plus",
                   repo_remote: "Pimpmuckl/symphony-plus-plus",
                   repo_aliases: ["Pimpmuckl/symphony-plus-plus", "symphony-plus-plus"],
                   base_branch: "main",
                   solo_session_count: 2
                 } = stream
               ] = streams

        assert stream.repo == "symphony-plus-plus"
      end)
    end)
  end

  test "local operator dashboard projects persisted local path repos through their git origin", %{repo: repo} do
    repo_path =
      TestSupport.git_repo_with_origin_fixture!(
        "https://github.com/Pimpmuckl/nextide-saas-live-chat.git",
        prefix: "sympp-dashboard-repo-path"
      )

    try do
      with_local_operator_endpoint(fn ->
        assert {:ok, work_package} =
                 WorkPackageRepository.create(
                   repo,
                   WorkPackageFactory.attrs(
                     id: "SYMPP-REPO-PATH-IDENTITY",
                     repo: repo_path,
                     base_branch: "main"
                   )
                 )

        assert {:ok, work_request} =
                 WorkRequestRepository.create(repo, %{
                   title: "Path repo projection",
                   repo: repo_path,
                   base_branch: "main",
                   work_type: "feature",
                   human_description: "Project the path repo through local git origin.",
                   constraints: %{},
                   desired_dispatch_shape: "architect_led_feature_branch",
                   status: "ready_for_clarification"
                 })

        assert {:ok, solo_session} =
                 SoloSessionsService.create_or_attach_current(repo, %{
                   repo: repo_path,
                   base_branch: "main",
                   workspace_path: Path.join(@repo_root, "repo-path-identity-solo"),
                   caller_id: "repo-path-identity-solo",
                   title: "Path scoped solo"
                 })

        payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard"), 200)
        expected_aliases = Enum.sort_by([repo_path, "nextide-saas-live-chat", "Pimpmuckl/nextide-saas-live-chat"], &String.downcase/1)

        package_card =
          payload["board"]["groups"]["created"]
          |> Enum.find(&(&1["id"] == work_package.id))

        assert package_card["repo"] == repo_path
        assert package_card["repo_key"] == "nextide-saas-live-chat"
        assert package_card["repo_display"] == "nextide-saas-live-chat"
        assert package_card["repo_remote"] == "Pimpmuckl/nextide-saas-live-chat"
        assert package_card["repo_aliases"] == expected_aliases

        assert [%{"repo" => ^repo_path, "repo_key" => "nextide-saas-live-chat", "repo_remote" => "Pimpmuckl/nextide-saas-live-chat"}] =
                 payload["work_requests"]["work_requests"]

        solo_session_id = solo_session.id

        assert [%{"id" => ^solo_session_id, "repo" => ^repo_path, "repo_key" => "nextide-saas-live-chat", "repo_remote" => "Pimpmuckl/nextide-saas-live-chat"}] =
                 payload["solo_sessions"]["solo_sessions"]

        assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
        assert {:ok, persisted_request} = WorkRequestRepository.get(repo, work_request.id)
        assert {:ok, persisted_session} = SoloSessionsService.get(repo, solo_session.id)

        assert persisted_package.repo == repo_path
        assert persisted_request.repo == repo_path
        assert persisted_session.repo == repo_path
      end)
    after
      File.rm_rf(repo_path)
    end
  end

  test "package detail repo identity stays scoped to the authorized package", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-REPO-DETAIL-SCOPED",
                 repo: "symphony-plus-plus",
                 base_branch: "main"
               )
             )

    assert {:ok, _unrelated} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-REPO-DETAIL-UNRELATED",
                 repo: "Pimpmuckl/symphony-plus-plus",
                 base_branch: "main"
               )
             )

    secret = create_worker_grant_secret(repo, work_package.id, "repo-detail-worker")
    payload = json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert payload["work_package"]["repo"] == "symphony-plus-plus"
    assert payload["work_package"]["repo_key"] == "symphony-plus-plus"
    assert payload["work_package"]["repo_display"] == "symphony-plus-plus"
    assert payload["work_package"]["repo_remote"] == nil
    assert payload["work_package"]["repo_aliases"] == ["symphony-plus-plus"]
  end

  test "record detail repo identity stays scoped unless a catalog is passed", %{repo: repo} do
    with_trusted_repo_remotes(["Pimpmuckl/symphony-plus-plus"], fn ->
      assert {:ok, _unrelated} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(
                   id: "SYMPP-REPO-DETAIL-CATALOG-SOURCE",
                   repo: "Pimpmuckl/symphony-plus-plus",
                   base_branch: "main"
                 )
               )

      assert {:ok, work_request} =
               WorkRequestRepository.create(repo, %{
                 title: "Scoped detail request",
                 repo: "symphony-plus-plus",
                 base_branch: "main",
                 work_type: "feature",
                 human_description: "Keep detail identity scoped.",
                 constraints: %{},
                 desired_dispatch_shape: "architect_led_feature_branch",
                 status: "ready_for_clarification"
               })

      assert {:ok, solo_session} =
               SoloSessionsService.create_or_attach_current(repo, %{
                 repo: "symphony-plus-plus",
                 base_branch: "main",
                 workspace_path: Path.join(@repo_root, "repo-detail-scoped-solo"),
                 caller_id: "repo-detail-scoped-solo",
                 title: "Scoped solo detail"
               })

      assert {:ok, request_detail} = Dashboard.work_request_detail(repo, work_request.id)
      assert request_detail.work_request.repo_remote == nil
      assert request_detail.work_request.repo_aliases == ["symphony-plus-plus"]

      assert {:ok, solo_detail} = Dashboard.solo_session_detail(repo, solo_session.id)
      assert solo_detail.solo_session.repo_remote == nil
      assert solo_detail.solo_session.repo_aliases == ["symphony-plus-plus"]
    end)
  end

  test "dashboard repo identity keeps conflicting owner-qualified repos separate", %{repo: repo} do
    with_local_repo_origin("https://github.com/alpha/shared.git", fn ->
      repo_cases = [
        {:bare, "SYMPP-REPO-CONFLICT-BARE", "shared"},
        {:alpha, "SYMPP-REPO-CONFLICT-A", "alpha/shared"},
        {:beta, "SYMPP-REPO-CONFLICT-B", "beta/shared"}
      ]

      packages = Map.new(repo_cases, &create_repo_identity_package!(repo, &1))
      requests = Map.new(repo_cases, &create_repo_identity_request!(repo, &1))
      expectations = Map.new(repo_cases, fn {key, _id, raw_repo} -> {key, repo_identity_expectation(raw_repo)} end)

      assert {:ok, repo_identity_catalog} = Dashboard.local_operator_repo_identity_catalog(repo)
      opts = [repo_identity_catalog: repo_identity_catalog]

      assert {:ok, board} = Dashboard.operator_board(repo, opts)

      cards_by_id =
        board.groups["created"]
        |> Map.new(&{&1.id, &1})

      Enum.each(repo_cases, fn {key, _id, _raw_repo} ->
        package_card = Map.fetch!(cards_by_id, Map.fetch!(packages, key).id)
        assert_repo_identity(package_card, Map.fetch!(expectations, key))
      end)

      assert {:ok, work_requests} = Dashboard.work_requests(repo, opts)

      request_cards_by_id =
        work_requests.work_requests
        |> Map.new(&{&1.id, &1})

      Enum.each(repo_cases, fn {key, _id, _raw_repo} ->
        request = Map.fetch!(requests, key)

        request_card = Map.fetch!(request_cards_by_id, request.id)
        assert_repo_identity(request_card, Map.fetch!(expectations, key))

        assert {:ok, detail} = Dashboard.work_request_detail(repo, request.id, opts)
        assert_repo_identity(detail.work_request, Map.fetch!(expectations, key))
      end)
    end)
  end

  test "local operator dashboard exposes active blocking edges", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request =
        create_work_request!(
          repo,
          id: "WR-ACTIVE-BLOCKING-EDGES",
          status: "ready_for_slicing",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )

      assert {:ok, planned_slice} =
               WorkRequestRepository.add_planned_slice(
                 repo,
                 work_request.id,
                 planned_slice_attrs(id: "WRS-ACTIVE-BLOCKING-EDGES")
               )

      assert {:ok, approved_slice} =
               WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

      linked_package =
        create_matching_work_package!(
          repo,
          work_request,
          approved_slice,
          id: "SYMPP-ACTIVE-BLOCKING-LINKED",
          status: "planning"
        )

      assert {:ok, _dispatched_slice} =
               WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", linked_package.id)

      unlinked_package =
        create_work_package!(
          repo,
          id: "SYMPP-ACTIVE-BLOCKING-UNLINKED",
          status: "planning"
        )

      timestamp = ~U[2026-05-20 10:00:00Z]

      append_blocker_event!(repo, linked_package.id, "blocker-linked", true,
        summary: "Blocked by sk-secret123",
        body: "Bearer raw-secret-value",
        created_at: DateTime.add(timestamp, 1, :second)
      )

      append_blocker_event!(repo, linked_package.id, "blocker-resolved", true,
        summary: "Temporary blocker",
        created_at: DateTime.add(timestamp, 2, :second)
      )

      append_blocker_event!(repo, linked_package.id, "blocker-resolved", false,
        summary: "Resolved blocker",
        created_at: DateTime.add(timestamp, 3, :second)
      )

      append_blocker_event!(repo, unlinked_package.id, "blocker-unlinked", true,
        summary: "Blocked on review",
        created_at: DateTime.add(timestamp, 4, :second)
      )

      payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard"), 200)
      edges = payload["active_blocking_edges"]

      assert Enum.map(edges, & &1["blocker_id"]) == ["blocker-linked", "blocker-unlinked"]
      refute Enum.any?(edges, &(&1["blocker_id"] == "blocker-resolved"))

      assert [linked_edge, unlinked_edge] = edges
      assert linked_edge["from"] == %{"kind" => "slice", "id" => approved_slice.id}
      assert linked_edge["to"] == %{"kind" => "work_package", "id" => linked_package.id}
      assert linked_edge["work_request_id"] == work_request.id
      assert linked_edge["planned_slice_id"] == approved_slice.id
      assert linked_edge["work_package_id"] == linked_package.id
      assert linked_edge["summary"] == "[REDACTED]"
      assert linked_edge["body"] == "[REDACTED]"

      assert unlinked_edge["from"] == %{"kind" => "work_package", "id" => unlinked_package.id}
      assert unlinked_edge["to"] == %{"kind" => "work_package", "id" => unlinked_package.id}
      assert unlinked_edge["work_package_id"] == unlinked_package.id
      refute Map.has_key?(unlinked_edge, "planned_slice_id")

      linked_card =
        payload["board"]["groups"]["planning"]
        |> Enum.find(&(&1["id"] == linked_package.id))

      assert linked_card["active_blocker_count"] == 1

      repeated_payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/dashboard"), 200)
      assert Enum.map(repeated_payload["active_blocking_edges"], & &1["id"]) == Enum.map(edges, & &1["id"])
    end)
  end

  test "local operator config returns runtime csrf and asset paths" do
    with_local_operator_endpoint(fn ->
      payload = json_response(get(local_operator_conn(), "/api/v1/sympp/operator/config"), 200)

      assert payload["apiBase"] == "/api/v1/sympp/operator"
      assert payload["basePath"] == ""
      assert payload["logoUrl"] == "/splusplus-logo.png"
      assert is_binary(payload["csrfToken"])
      assert byte_size(payload["csrfToken"]) > 20
    end)
  end

  test "local operator can fetch package detail through the dashboard API", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      %{work_package: work_package} = create_dashboard_fixture(repo, id: "SYMPP-LOCAL-OPERATOR-DETAIL")

      payload =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/work-packages/#{work_package.id}")
        |> json_response(200)

      assert payload["work_package"]["id"] == work_package.id
      assert is_list(payload["progress"])
      assert is_map(payload["summary"])
    end)
  end

  test "local operator can sync GitHub PR merge state and receive refreshed dashboard", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      with_operator_github_client(fn ->
        work_package =
          create_work_package!(repo,
            id: "SYMPP-LOCAL-OPERATOR-GH-SYNC",
            kind: "hotfix",
            repo: "nextide/repo",
            status: "ready_for_human_merge"
          )

        assert {:ok, _branch} =
                 PlanningRepository.append_progress_event(repo, %{
                   work_package_id: work_package.id,
                   summary: "Branch attached",
                   status: "branch_attached",
                   payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-a"}
                 })

        assert {:ok, _pr} =
                 PlanningRepository.append_progress_event(repo, %{
                   work_package_id: work_package.id,
                   summary: "PR attached",
                   status: "pr_attached",
                   payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/repo/pull/22", head_sha: "head-a"}
                 })

        FakeGitHubClient.put_response("nextide/repo", 22, GitHubPullRequestFixtures.metadata(22, "head-a", merged?: true))

        payload =
          local_operator_csrf_conn()
          |> post("/api/v1/sympp/operator/github/sync-prs", %{})
          |> json_response(200)

        assert payload["sync"]["merged_count"] == 1
        assert [%{"work_package_id" => "SYMPP-LOCAL-OPERATOR-GH-SYNC", "status" => "merged"}] = payload["sync"]["results"]
        assert payload["dashboard"]["generated_at"]

        assert {:ok, updated} = WorkPackageRepository.get(repo, work_package.id)
        assert updated.status == "merged"
      end)
    end)
  end

  test "local operator auto GitHub sync uses gh CLI without token env", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      with_operator_gh_cli_runner(fn ->
        GitHubTestSupport.with_github_token_env(nil, fn ->
          work_package =
            create_work_package!(repo,
              id: "SYMPP-LOCAL-OPERATOR-GH-CLI-AUTO",
              kind: "hotfix",
              repo: "nextide/repo",
              status: "ready_for_human_merge"
            )

          assert {:ok, _branch} =
                   PlanningRepository.append_progress_event(repo, %{
                     work_package_id: work_package.id,
                     summary: "Branch attached",
                     status: "branch_attached",
                     payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-a"}
                   })

          assert {:ok, _pr} =
                   PlanningRepository.append_progress_event(repo, %{
                     work_package_id: work_package.id,
                     summary: "PR attached",
                     status: "pr_attached",
                     payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/repo/pull/23", head_sha: "head-a"}
                   })

          FakeGhCli.authenticate(:ok)
          FakeGhCli.put_response("nextide/repo", 23, GitHubPullRequestFixtures.gh_view(23, "head-a", merged?: true))

          payload =
            local_operator_csrf_conn()
            |> post("/api/v1/sympp/operator/github/sync-prs", %{mode: "auto"})
            |> json_response(200)

          assert payload["sync"]["merged_count"] == 1
          assert [%{"work_package_id" => "SYMPP-LOCAL-OPERATOR-GH-CLI-AUTO", "status" => "merged"}] = payload["sync"]["results"]
          assert payload["dashboard"]["generated_at"]

          assert {:ok, updated} = WorkPackageRepository.get(repo, work_package.id)
          assert updated.status == "merged"

          assert [
                   %{args: ["auth", "status", "--hostname", "github.com"]},
                   %{args: ["pr", "view", "23", "--repo", "nextide/repo", "--json", _fields]}
                 ] = FakeGhCli.commands()
        end)
      end)
    end)
  end

  test "local operator auto GitHub sync respects configured GitHub client", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      with_operator_authenticated_github_client(fn ->
        GitHubTestSupport.with_github_token_env(nil, fn ->
          work_package =
            create_work_package!(repo,
              id: "SYMPP-LOCAL-OPERATOR-GH-CONFIGURED-AUTO",
              kind: "hotfix",
              repo: "nextide/repo",
              status: "ready_for_human_merge"
            )

          assert {:ok, _branch} =
                   PlanningRepository.append_progress_event(repo, %{
                     work_package_id: work_package.id,
                     summary: "Branch attached",
                     status: "branch_attached",
                     payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "head-a"}
                   })

          assert {:ok, _pr} =
                   PlanningRepository.append_progress_event(repo, %{
                     work_package_id: work_package.id,
                     summary: "PR attached",
                     status: "pr_attached",
                     payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/repo/pull/25", head_sha: "head-a"}
                   })

          FakeGitHubClient.put_response("nextide/repo", 25, GitHubPullRequestFixtures.metadata(25, "head-a", merged?: true))

          payload =
            local_operator_csrf_conn()
            |> post("/api/v1/sympp/operator/github/sync-prs", %{mode: "auto"})
            |> json_response(200)

          assert payload["sync"]["merged_count"] == 1
          assert [%{"work_package_id" => "SYMPP-LOCAL-OPERATOR-GH-CONFIGURED-AUTO", "status" => "merged"}] = payload["sync"]["results"]
          assert FakeGhCli.commands() == []
        end)
      end)
    end)
  end

  test "local operator can fetch Solo Session detail through the dashboard API", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, session} =
               SoloSessionsService.create_or_attach_current(repo, %{
                 repo: "nextide/demo-operator",
                 base_branch: "main",
                 workspace_path: @repo_root,
                 caller_id: "local-dashboard-test",
                 title: "Inspect solo modal"
               })

      assert {:ok, _entry} =
               SoloSessionsService.append_entry(repo, session.id, %{
                 entry_kind: "task_plan",
                 title: "Plan the solo session card",
                 body: "## Plan\n- Keep the card quiet.\n- Put the detail in the modal.",
                 status: "in_progress",
                 idempotency_key: "solo-dashboard-detail-test:plan"
               })

      payload =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/solo-sessions/#{session.id}")
        |> json_response(200)

      assert payload["solo_session"]["id"] == session.id
      assert payload["entry_count"] == 1
      assert [%{"kind" => "task_plan", "body" => body}] = payload["entries"]
      assert body =~ "Keep the card quiet"
    end)
  end

  test "local operator can create a WorkRequest through the dashboard API", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-requests", %{
          "title" => "Fresh dashboard request",
          "repo" => "symphony-plus-plus",
          "base_branch" => "main",
          "work_type" => "feature",
          "human_description" => "Create a first-class operator cockpit.",
          "desired_dispatch_shape" => "architect_led_feature_branch",
          "constraints" => %{"allowed_paths" => ["elixir"]}
        })
        |> json_response(201)

      assert payload["work_request"]["work_request"]["status"] == "ready_for_clarification"
      assert payload["dashboard"]["work_requests"]["total_count"] == 1

      assert {:ok, [stored]} = WorkRequestRepository.list(repo)
      assert stored.title == "Fresh dashboard request"
    end)
  end

  test "local operator can tune archive cutoff and restore archived WorkRequests", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      completed_at = DateTime.add(DateTime.utc_now(:microsecond), -2 * 24 * 60 * 60, :second)
      request = create_completed_skipped_work_request!(repo, "WR-LOCAL-ARCHIVE-SETTINGS", completed_at)

      dashboard_payload =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/dashboard")
        |> json_response(200)

      assert dashboard_payload["settings"]["work_request_archive_after_days"] == 14
      assert Enum.any?(dashboard_payload["work_requests"]["work_requests"], &(&1["id"] == request.id))
      assert dashboard_payload["archived_work_requests"]["work_requests"] == []

      archive_payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/settings", %{"work_request_archive_after_days" => 1})
        |> json_response(200)

      assert archive_payload["settings"]["work_request_archive_after_days"] == 1
      refute Enum.any?(archive_payload["dashboard"]["work_requests"]["work_requests"], &(&1["id"] == request.id))
      assert [%{"id" => "WR-LOCAL-ARCHIVE-SETTINGS", "archived_at" => archived_at}] = archive_payload["dashboard"]["archived_work_requests"]["work_requests"]
      assert is_binary(archived_at)

      restore_payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{request.id}/restore", %{})
        |> json_response(200)

      assert Enum.any?(restore_payload["dashboard"]["work_requests"]["work_requests"], &(&1["id"] == request.id))
      refute Enum.any?(restore_payload["dashboard"]["archived_work_requests"]["work_requests"], &(&1["id"] == request.id))
      assert get_in(restore_payload, ["work_request", "work_request", "archived_at"]) == nil
    end)
  end

  test "local operator dashboard refresh applies archive retention", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, _settings} = OperatorSettingsService.update(repo, %{"work_request_archive_after_days" => 1})

      completed_at = DateTime.add(DateTime.utc_now(:microsecond), -2 * 24 * 60 * 60, :second)
      request = create_completed_skipped_work_request!(repo, "WR-LOCAL-REFRESH-RETENTION", completed_at)

      payload =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/dashboard")
        |> json_response(200)

      refute Enum.any?(payload["work_requests"]["work_requests"], &(&1["id"] == request.id))
      assert [%{"id" => "WR-LOCAL-REFRESH-RETENTION", "archived_at" => archived_at}] = payload["archived_work_requests"]["work_requests"]
      assert is_binary(archived_at)
    end)
  end

  test "local operator can manually archive completed WorkRequests only", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      completed_at = DateTime.add(DateTime.utc_now(:microsecond), -24 * 60 * 60, :second)
      completed = create_completed_skipped_work_request!(repo, "WR-LOCAL-MANUAL-ARCHIVE", completed_at)

      archive_payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{completed.id}/archive", %{})
        |> json_response(200)

      refute Enum.any?(archive_payload["dashboard"]["work_requests"]["work_requests"], &(&1["id"] == completed.id))
      assert [%{"id" => "WR-LOCAL-MANUAL-ARCHIVE"}] = archive_payload["dashboard"]["archived_work_requests"]["work_requests"]

      incomplete = create_work_request!(repo, id: "WR-LOCAL-MANUAL-NOT-COMPLETE", status: "ready_for_slicing")

      error_payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{incomplete.id}/archive", %{})
        |> json_response(422)

      assert error_payload["error"]["code"] == "not_completed"
    end)
  end

  test "local operator can mark WorkPackages merged and refresh WorkRequest completion", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-MARK-PACKAGE-MERGED", status: "ready_for_slicing")

      assert {:ok, slice} =
               WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-LOCAL-MARK-PACKAGE-MERGED"))

      assert {:ok, approved} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, slice.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-MARK-PACKAGE-MERGED",
          status: "implementing"
        )

      assert {:ok, _dispatched} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved.id, "approved", work_package.id)

      payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/state", %{"status" => "merged"})
        |> json_response(200)

      assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
      assert persisted_package.status == "merged"

      assert get_in(work_request_detail(payload["dashboard"], work_request.id), ["work_request", "operational_state", "key"]) ==
               "needs_closeout"
    end)
  end

  test "local operator can close linked WorkPackages with no-PR evidence", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-NO-PR", status: "ready_for_slicing")

      assert {:ok, slice} =
               WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-LOCAL-NO-PR"))

      assert {:ok, approved} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, slice.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-NO-PR",
          status: "reviewing"
        )

      assert {:ok, _dispatched} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved.id, "approved", work_package.id)

      payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/state", %{
          "status" => "completed_no_pr",
          "no_pr_evidence" => "Operator confirmed the exploratory work landed without a PR."
        })
        |> json_response(200)

      assert [%PlannedSliceDelivery{} = delivery] = repo.all(PlannedSliceDelivery)
      assert delivery.outcome == "completed_no_pr"
      assert delivery.idempotency_key == "local-operator-completed-no-pr:#{approved.id}"
      assert delivery.no_pr_evidence == "Operator confirmed the exploratory work landed without a PR."

      assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
      assert persisted_package.status == "closed"

      detail = work_request_detail(payload["dashboard"], work_request.id)
      assert get_in(detail, ["planned_slices", Access.at(0), "delivery", "outcome"]) == "completed_no_pr"
    end)
  end

  test "local operator cannot close terminal linked WorkPackages with no-PR evidence", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-NO-PR-TERMINAL", status: "ready_for_slicing")

      assert {:ok, slice} =
               WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-LOCAL-NO-PR-TERMINAL"))

      assert {:ok, approved} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, slice.id, "planned")

      work_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-NO-PR-TERMINAL",
          status: "merged"
        )

      assert {:ok, _dispatched} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved.id, "approved", work_package.id)

      error =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/state", %{
          "status" => "completed_no_pr",
          "no_pr_evidence" => "Operator tried to close an already merged package without PR."
        })
        |> json_response(422)

      assert error["error"]["code"] == "invalid_status"
      assert [] = repo.all(PlannedSliceDelivery)
    end)
  end

  test "local operator can change and archive unlinked WorkPackages in one action", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      merge_package =
        create_work_package!(repo,
          id: "WP-LOCAL-MERGE-ARCHIVE",
          status: "implementing",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )

      close_package =
        create_work_package!(repo,
          id: "WP-LOCAL-CLOSE-ARCHIVE",
          status: "planning",
          repo: merge_package.repo,
          base_branch: merge_package.base_branch
        )

      merge_payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{merge_package.id}/state", %{"status" => "merged_and_archive"})
        |> json_response(200)

      close_payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{close_package.id}/state", %{"status" => "closed_and_archive"})
        |> json_response(200)

      assert get_in(close_payload, ["dashboard", "settings", "hidden_work_package_ids"]) == [merge_package.id, close_package.id]
      refute merge_package.id in board_work_package_ids(merge_payload["dashboard"])
      refute merge_package.id in board_work_package_ids(close_payload["dashboard"])
      refute close_package.id in board_work_package_ids(close_payload["dashboard"])

      assert {:ok, persisted_merge_package} = WorkPackageRepository.get(repo, merge_package.id)
      assert persisted_merge_package.status == "merged"

      assert {:ok, persisted_close_package} = WorkPackageRepository.get(repo, close_package.id)
      assert persisted_close_package.status == "closed"
    end)
  end

  test "local operator can archive delivered unlinked WorkPackages without deleting them", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      delivered_package =
        create_work_package!(repo,
          id: "WP-LOCAL-ARCHIVE-UNLINKED",
          status: "merged",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )

      active_package =
        create_work_package!(repo,
          id: "WP-LOCAL-ARCHIVE-ACTIVE",
          status: "implementing",
          repo: delivered_package.repo,
          base_branch: delivered_package.base_branch
        )

      archive_payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{delivered_package.id}/archive", %{})
        |> json_response(200)

      assert get_in(archive_payload, ["dashboard", "settings", "hidden_work_package_ids"]) == [delivered_package.id]
      assert active_package.id in board_work_package_ids(archive_payload["dashboard"])
      refute delivered_package.id in board_work_package_ids(archive_payload["dashboard"])

      assert {:ok, persisted_package} = WorkPackageRepository.get(repo, delivered_package.id)
      assert persisted_package.status == "merged"
    end)
  end

  test "local operator dashboard does not hide packages linked from archived WorkRequests", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request =
        create_work_request!(repo,
          id: "WR-LOCAL-HIDDEN-LINKED-ARCHIVED",
          status: "ready_for_slicing",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )

      assert {:ok, slice} =
               WorkRequestRepository.add_planned_slice(
                 repo,
                 work_request.id,
                 planned_slice_attrs(
                   id: "WRS-LOCAL-HIDDEN-LINKED-ARCHIVED",
                   target_base_branch: "main"
                 )
               )

      assert {:ok, approved} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, slice.id, "planned")

      hidden_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-HIDDEN-LINKED-ARCHIVED",
          status: "merged"
        )

      assert {:ok, _settings} =
               OperatorSettingsService.update(repo, %{"hidden_work_package_ids" => [hidden_package.id]})

      assert {:ok, _dispatched} =
               WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved.id, "approved", hidden_package.id)

      archived_at = ~U[2026-05-25 10:00:00.000000Z]

      work_request
      |> Ecto.Changeset.change(completed_at: archived_at, completion_source: "operator", archived_at: archived_at)
      |> repo.update!()

      payload =
        local_operator_conn()
        |> get("/api/v1/sympp/operator/dashboard")
        |> json_response(200)

      assert hidden_package.id in payload["linked_work_package_ids"]
      assert hidden_package.id in board_work_package_ids(payload)
      assert payload["work_request_details"] == []
    end)
  end

  test "local operator cannot archive active or linked WorkPackages", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      active_package =
        create_work_package!(repo,
          id: "WP-LOCAL-ARCHIVE-ACTIVE-REJECTED",
          status: "implementing",
          repo: "nextide/symphony-plus-plus",
          base_branch: "main"
        )

      active_error =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{active_package.id}/archive", %{})
        |> json_response(422)

      assert active_error["error"]["code"] == "not_delivered"

      work_request = create_work_request!(repo, id: "WR-LOCAL-ARCHIVE-LINKED", status: "ready_for_slicing")

      assert {:ok, slice} =
               WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-LOCAL-ARCHIVE-LINKED"))

      assert {:ok, approved} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, slice.id, "planned")

      linked_package =
        create_matching_work_package!(repo, work_request, approved,
          id: "WP-LOCAL-ARCHIVE-LINKED",
          status: "merged"
        )

      assert {:ok, _dispatched} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved.id, "approved", linked_package.id)

      linked_error =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-packages/#{linked_package.id}/archive", %{})
        |> json_response(422)

      assert linked_error["error"]["code"] == "linked_work_package"
    end)
  end

  test "local operator cannot mark non-merged terminal WorkPackages merged", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      assert {:ok, work_package} =
               WorkPackageRepository.create(
                 repo,
                 WorkPackageFactory.attrs(id: "WP-LOCAL-MARK-CLOSED", status: "closed")
               )

      local_operator_csrf_conn()
      |> post("/api/v1/sympp/operator/work-packages/#{work_package.id}/state", %{"status" => "merged"})
      |> json_response(422)

      assert {:ok, persisted_package} = WorkPackageRepository.get(repo, work_package.id)
      assert persisted_package.status == "closed"
    end)
  end

  test "local operator can force complete an unfinished WorkRequest", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-COMPLETE-STATE", status: "ready_for_slicing")

      assert {:ok, planned_slice} =
               WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-LOCAL-COMPLETE-STATE"))

      assert {:ok, open_question} =
               WorkRequestRepository.ask_question(repo, work_request.id, question_attrs(id: "WRQ-LOCAL-COMPLETE-STATE"))

      payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/work-requests/#{work_request.id}/state", %{"state" => "completed"})
        |> json_response(200)

      assert get_in(payload, ["work_request", "work_request", "operational_state", "key"]) == "completed"
      assert get_in(payload, ["work_request", "work_request", "completion_source"]) == "operator"

      assert {:ok, persisted_request} = WorkRequestRepository.get(repo, work_request.id)
      assert %DateTime{} = persisted_request.completed_at
      assert persisted_request.completion_source == "operator"

      assert {:ok, [persisted_slice]} = WorkRequestRepository.list_planned_slices(repo, work_request.id)
      assert persisted_slice.id == planned_slice.id
      assert persisted_slice.status == "planned"

      assert {:ok, [persisted_question]} = WorkRequestRepository.list_questions(repo, work_request.id)
      assert persisted_question.id == open_question.id
      assert persisted_question.status == "open"

      assert {:ok, refreshed_request} = WorkRequestService.refresh_completion(repo, work_request.id)
      assert refreshed_request.completed_at == persisted_request.completed_at
      assert refreshed_request.completion_source == "operator"
    end)
  end

  test "local operator can create and resolve comments through the dashboard API", %{repo: repo} do
    with_local_operator_endpoint(fn ->
      work_request = create_work_request!(repo, id: "WR-LOCAL-COMMENTS", status: "ready_for_slicing")

      create_payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/comments", %{
          "target_kind" => "work_request",
          "target_id" => work_request.id,
          "body" => "Operator note sk-secret123",
          "source_type" => "worker",
          "author_name" => "github_pat_12345678"
        })
        |> json_response(201)

      assert %{"comment" => %{"id" => comment_id, "status" => "open"}} = create_payload
      assert get_in(create_payload, ["comment", "body"]) == "Operator note [REDACTED]"
      assert get_in(create_payload, ["comment", "source_type"]) == "operator"
      assert get_in(create_payload, ["comment", "author_name"]) == "local-operator"
      assert get_in(work_request_detail(create_payload["dashboard"], work_request.id), ["summary", "open_comment_count"]) == 1

      assert {:ok, %Comment{source_type: "operator", author_name: "local-operator", body: "Operator note [REDACTED]"}} = CommentService.get(repo, comment_id)

      resolve_payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/comments/#{comment_id}/resolve", %{
          "resolved_by" => "spoofed-worker",
          "resolved_source_type" => "worker",
          "resolution_note" => "Handled bearer abcdefgh"
        })
        |> json_response(200)

      assert get_in(resolve_payload, ["comment", "status"]) == "resolved"
      assert get_in(resolve_payload, ["comment", "resolved_by"]) == "local-operator"
      assert get_in(resolve_payload, ["comment", "resolved_source_type"]) == "operator"
      assert get_in(resolve_payload, ["comment", "resolution_note"]) == "Handled [REDACTED]"
      assert get_in(work_request_detail(resolve_payload["dashboard"], work_request.id), ["summary", "comment_count"]) == 1
      assert get_in(work_request_detail(resolve_payload["dashboard"], work_request.id), ["summary", "open_comment_count"]) == 0
      assert {:ok, %Comment{resolution_note: "Handled [REDACTED]"}} = CommentService.get(repo, comment_id)

      overlong_payload =
        local_operator_csrf_conn()
        |> post("/api/v1/sympp/operator/comments", %{
          "target_kind" => "work_request",
          "target_id" => work_request.id,
          "body" => String.duplicate("x", Comment.max_body_length() + 1)
        })
        |> json_response(422)

      assert get_in(overlong_payload, ["error", "code"]) == "invalid_request"
      assert get_in(overlong_payload, ["error", "message"]) =~ "body"
    end)
  end

  test "local operator mutations require CSRF protection" do
    with_local_operator_endpoint(fn ->
      index = "<!doctype html><html><head></head><body><div id=\"root\"></div></body></html>"

      with_static_dashboard_file("index.html", index, fn ->
        shell_conn =
          local_operator_conn()
          |> Plug.Test.init_test_session(%{})
          |> ReactDashboardController.index(%{})

        assert html_response(shell_conn, 200) =~ "csrfToken"

        assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
          shell_conn
          |> recycle_local_operator_conn("http://evil.example")
          |> post("/api/v1/sympp/operator/work-requests", %{
            "title" => "Cross-site dashboard request",
            "repo" => "symphony-plus-plus",
            "base_branch" => "main",
            "work_type" => "feature",
            "human_description" => "This should not reach the local ledger.",
            "desired_dispatch_shape" => "architect_led_feature_branch"
          })
        end
      end)
    end)
  end

  test "react dashboard shell injects prefix-aware runtime config" do
    index = """
    <!doctype html>
    <html>
      <head>
        <link rel="icon" href="/splusplus-logo.png">
        <script type="module" src="/assets/index.js"></script>
      </head>
      <body><div id="root"></div></body>
    </html>
    """

    with_static_dashboard_file("index.html", index, fn ->
      html =
        build_conn(:get, "/sympp/board")
        |> Plug.Test.init_test_session(%{})
        |> Map.put(:script_name, ["app"])
        |> ReactDashboardController.index(%{})
        |> html_response(200)

      assert html =~ ~s(href="/app/splusplus-logo.png")
      assert html =~ ~s(src="/app/assets/index.js")
      assert html =~ "window.SYMPP_DASHBOARD_CONFIG"
      assert html =~ ~s("apiBase":"/app/api/v1/sympp/operator")
      assert html =~ ~s("logoUrl":"/app/splusplus-logo.png")
      assert html =~ ~s("csrfToken":)
    end)
  end

  test "endpoint serves the built dashboard logo asset" do
    with_static_dashboard_file("splusplus-logo.png", "logo-bytes", fn ->
      assert response(get(build_conn(), "/splusplus-logo.png"), 200) == "logo-bytes"
    end)
  end

  test "dashboard API rejects grants after package authority reaches terminal state", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(repo, status: "planning")

    assert %{"work_package" => %{"id" => fetched_id}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert fetched_id == work_package.id
    assert {:ok, _terminal_package} = WorkPackageRepository.update(repo, work_package.id, %{status: "merged"})

    assert %{"error" => %{"code" => "unauthorized"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}"), 401)
  end

  test "dashboard browser sessions reject unknown work keys with login responses", %{repo: repo} do
    %{work_package: work_package} = create_dashboard_fixture(repo)
    unknown_secret = WorkKey.generate().secret

    board_conn = post(build_conn(), "/sympp/board/session", %{"work_key" => unknown_secret})

    assert response(board_conn, 401) =~ "The work key could not access the board."

    package_conn =
      post(build_conn(), "/sympp/work-packages/#{work_package.id}/session", %{"work_key" => unknown_secret})

    assert response(package_conn, 401) =~ "The work key could not access this package."
  end

  test "Phoenix request logger filters dashboard session secret parameters" do
    sentinel = "sympp-dashboard-log-secret-sentinel"

    params = %{
      "work_key" => sentinel,
      "work_key_secret" => "#{sentinel}-work-key-secret",
      "grant_secret" => "#{sentinel}-grant-secret",
      "secret" => "#{sentinel}-generic-secret",
      "work_package_id" => "SYMPP-P10-LOG-FILTER"
    }

    filtered = Phoenix.Logger.filter_values(params)
    filtered_text = inspect(filtered)

    refute filtered_text =~ sentinel
    assert filtered["work_key"] == "[FILTERED]"
    assert filtered["work_key_secret"] == "[FILTERED]"
    assert filtered["grant_secret"] == "[FILTERED]"
    assert filtered["secret"] == "[FILTERED]"
    assert filtered["work_package_id"] == "SYMPP-P10-LOG-FILTER"
  end

  test "dashboard API rejects missing bearer auth before dynamic repo bootstrap" do
    database_path = WorkPackageFactory.database_path()
    File.rm(database_path)

    with_dynamic_endpoint_database(database_path, fn ->
      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(build_conn(), "/api/v1/sympp/board"), 401)

      invalid_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer garbage")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(invalid_conn, "/api/v1/sympp/board"), 401)

      unknown_work_key_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{WorkKey.generate().secret}")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(unknown_work_key_conn, "/api/v1/sympp/board"), 401)
    end)

    refute File.exists?(database_path)
  end

  test "dashboard API rejects unknown bearer before missing file URI repo bootstrap" do
    database_path = WorkPackageFactory.database_path()
    File.rm(database_path)
    database_uri = "file:#{String.replace(database_path, "\\", "/")}?mode=rwc"

    with_dynamic_endpoint_database(database_uri, fn ->
      unknown_work_key_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{WorkKey.generate().secret}")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(unknown_work_key_conn, "/api/v1/sympp/board"), 401)
    end)

    refute File.exists?(database_path)
  end

  test "dashboard API rejects invalid bearer against an unmigrated existing database without migration" do
    database_path = WorkPackageFactory.database_path()

    try do
      File.write!(database_path, "")

      unknown_work_key_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{WorkKey.generate().secret}")

      with_configured_endpoint_database(database_path, fn ->
        assert %{"error" => %{"code" => "unauthorized"}} =
                 json_response(get(unknown_work_key_conn, "/api/v1/sympp/board"), 401)
      end)
    after
      File.rm(database_path)
    end
  end

  test "dashboard API migrates existing ledgers before auth reads new phase columns" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, secret} = seed_pre_phase_dashboard_database(database_path)

      refute "phase_id" in table_columns(database_path, "sympp_access_grants")
      refute "phase_id" in table_columns(database_path, "sympp_work_packages")

      with_configured_endpoint_database(database_path, fn ->
        assert %{"work_package" => %{"id" => ^work_package_id}} =
                 json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package_id}"), 200)
      end)

      assert "phase_id" in table_columns(database_path, "sympp_access_grants")
      assert "phase_id" in table_columns(database_path, "sympp_work_packages")
    after
      File.rm(database_path)
    end
  end

  test "dashboard board grant auth migrates pre-phase ledgers before phase auth reads phase columns" do
    database_path = WorkPackageFactory.database_path()

    try do
      {_work_package_id, _secret} =
        seed_pre_phase_dashboard_database(database_path,
          work_package_id: "SYMPP-PRE-PHASE-BOARD-AUTH",
          grant_id: "grant-pre-phase-board-auth",
          grant_role: "architect",
          capabilities: ["read:phase"],
          claimed_by: "architect-pre-phase"
        )

      refute "phase_id" in table_columns(database_path, "sympp_access_grants")
      refute "phase_id" in table_columns(database_path, "sympp_work_packages")

      with_configured_endpoint_database(database_path, fn ->
        assert {:error, :forbidden} = SymppDashboardApiController.authorize_board_grant_id("grant-pre-phase-board-auth")
      end)

      assert "phase_id" in table_columns(database_path, "sympp_access_grants")
      assert "phase_id" in table_columns(database_path, "sympp_work_packages")
    after
      File.rm(database_path)
    end
  end

  test "dashboard API board endpoint migrates pristine pre-phase ledgers before phase auth reads" do
    database_path = WorkPackageFactory.database_path()

    try do
      {_work_package_id, secret} =
        seed_pre_phase_dashboard_database(database_path,
          work_package_id: "SYMPP-PRE-PHASE-BOARD-ENDPOINT",
          grant_id: "grant-pre-phase-board-endpoint",
          grant_role: "architect",
          capabilities: ["read:phase"],
          claimed_by: "architect-pre-phase"
        )

      refute "phase_id" in table_columns(database_path, "sympp_access_grants")
      refute "phase_id" in table_columns(database_path, "sympp_work_packages")

      with_configured_endpoint_database(database_path, fn ->
        assert %{"error" => %{"code" => "forbidden"}} =
                 json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 403)
      end)

      assert "phase_id" in table_columns(database_path, "sympp_access_grants")
      assert "phase_id" in table_columns(database_path, "sympp_work_packages")
    after
      File.rm(database_path)
    end
  end

  test "dashboard package grant auth migrates pre-phase ledgers before phase package auth reads" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, _secret} =
        seed_pre_phase_dashboard_database(database_path,
          work_package_id: "SYMPP-PRE-PHASE-PACKAGE-AUTH",
          grant_id: "grant-pre-phase-package-auth",
          grant_role: "architect",
          capabilities: ["read:phase"],
          claimed_by: "architect-pre-phase"
        )

      refute "phase_id" in table_columns(database_path, "sympp_access_grants")
      refute "phase_id" in table_columns(database_path, "sympp_work_packages")

      with_configured_endpoint_database(database_path, fn ->
        assert {:error, :forbidden} =
                 SymppDashboardApiController.authorize_package_grant_id("grant-pre-phase-package-auth", work_package_id)
      end)

      assert "phase_id" in table_columns(database_path, "sympp_access_grants")
      assert "phase_id" in table_columns(database_path, "sympp_work_packages")
    after
      File.rm(database_path)
    end
  end

  test "dashboard package session migrates pristine pre-phase ledgers before phase package auth reads" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, secret} =
        seed_pre_phase_dashboard_database(database_path,
          work_package_id: "SYMPP-PRE-PHASE-PACKAGE-SESSION",
          grant_id: "grant-pre-phase-package-session",
          grant_role: "architect",
          capabilities: ["read:phase"],
          claimed_by: "architect-pre-phase"
        )

      refute "phase_id" in table_columns(database_path, "sympp_access_grants")
      refute "phase_id" in table_columns(database_path, "sympp_work_packages")

      with_configured_endpoint_database(database_path, fn ->
        conn = post(build_conn(), "/sympp/work-packages/#{work_package_id}/session", %{"work_key" => secret})

        assert response(conn, 403) =~ "The work key is not allowed to open this package."
      end)

      assert "phase_id" in table_columns(database_path, "sympp_access_grants")
      assert "phase_id" in table_columns(database_path, "sympp_work_packages")
    after
      File.rm(database_path)
    end
  end

  test "dashboard API migrates existing ledgers before auth reads scope grant columns" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, secret} =
        seed_dashboard_database_at_migration(database_path, 20_260_506_120_000,
          work_package_id: "SYMPP-PRE-SCOPE-AUTH",
          grant_id: "grant-pre-scope-auth"
        )

      assert "phase_id" in table_columns(database_path, "sympp_access_grants")
      refute "scope_repo" in table_columns(database_path, "sympp_access_grants")
      refute "scope_base_branch" in table_columns(database_path, "sympp_access_grants")
      refute "provenance" in table_columns(database_path, "sympp_access_grants")

      with_configured_endpoint_database(database_path, fn ->
        assert %{"work_package" => %{"id" => ^work_package_id}} =
                 json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package_id}"), 200)
      end)

      assert "scope_repo" in table_columns(database_path, "sympp_access_grants")
      assert "scope_base_branch" in table_columns(database_path, "sympp_access_grants")
      assert "provenance" in table_columns(database_path, "sympp_access_grants")
    after
      File.rm(database_path)
    end
  end

  test "dashboard package session migrates existing ledgers before auth reads provenance" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, secret} =
        seed_dashboard_database_at_migration(database_path, 20_260_506_143_000,
          work_package_id: "SYMPP-PRE-PROVENANCE-SESSION",
          grant_id: "grant-pre-provenance-session"
        )

      assert "scope_repo" in table_columns(database_path, "sympp_access_grants")
      assert "scope_base_branch" in table_columns(database_path, "sympp_access_grants")
      refute "provenance" in table_columns(database_path, "sympp_access_grants")

      with_configured_endpoint_database(database_path, fn ->
        conn = post(build_conn(), "/sympp/work-packages/#{work_package_id}/session", %{"work_key" => secret})

        assert redirected_to(conn) == "/sympp/work-packages/#{work_package_id}"
      end)

      assert "provenance" in table_columns(database_path, "sympp_access_grants")
    after
      File.rm(database_path)
    end
  end

  test "dashboard auth preflight treats in-memory SQLite ledgers as absent" do
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    try do
      for database_path <- [":memory:", "file::memory:?cache=shared", "file:?mode=rwc"] do
        Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)
        assert Repo.database_path() == database_path
        assert Repo.database_path_if_present() == nil
      end
    after
      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end
    end
  end

  test "dashboard API rejects invalid non-string database config before auth storage access" do
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    try do
      Application.put_env(:symphony_elixir, :sympp_repo_database, :invalid_database_path)

      unknown_work_key_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{WorkKey.generate().secret}")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(unknown_work_key_conn, "/api/v1/sympp/board"), 401)
    after
      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end
    end
  end

  test "dashboard browser sessions use the default database when endpoint sympp_repo is unset" do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    try do
      {work_package_id, board_secret, package_secret} = seed_dashboard_session_database(database_path)
      Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

      with_runtime_endpoint_repo(nil, fn ->
        board_conn = post(build_conn(), "/sympp/board/session", %{"work_key" => board_secret})
        assert redirected_to(board_conn) == "/sympp/board"

        package_conn =
          post(build_conn(), "/sympp/work-packages/#{work_package_id}/session", %{"work_key" => package_secret})

        assert redirected_to(package_conn) == "/sympp/work-packages/#{work_package_id}"
      end)
    after
      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end

      File.rm(database_path)
    end
  end

  test "dashboard API authenticates an existing explicit database while local Repo uses another ledger" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, secret} = seed_dashboard_database(database_path)

      with_configured_endpoint_database(database_path, fn ->
        assert %{"work_package" => %{"id" => ^work_package_id}} =
                 json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package_id}"), 200)
      end)
    after
      File.rm(database_path)
    end
  end

  test "dashboard API honors repo-configured database while local Repo uses another ledger" do
    database_path = WorkPackageFactory.database_path()

    try do
      {work_package_id, secret} = seed_dashboard_database(database_path)

      with_repo_configured_endpoint_database(database_path, fn ->
        assert %{"work_package" => %{"id" => ^work_package_id}} =
                 json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package_id}"), 200)
      end)
    after
      File.rm(database_path)
    end
  end

  test "dashboard API accepts case-insensitive bearer auth", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(repo)

    conn =
      build_conn()
      |> put_req_header("authorization", "bearer #{secret}")

    assert %{"work_package" => %{"id" => fetched_id}} =
             json_response(get(conn, "/api/v1/sympp/work-packages/#{work_package.id}"), 200)

    assert fetched_id == work_package.id
  end

  test "dashboard reads normalize SQLite busy errors" do
    assert {:error, :database_busy} = Dashboard.board(BusyRepo)
  end

  test "dashboard API normalizes SQLite busy errors during bearer auth" do
    secret = WorkKey.generate().secret

    with_endpoint_repo(BusyRepo, fn ->
      assert %{"error" => %{"code" => "database_busy"}} =
               json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 503)
    end)
  end

  test "dashboard API preserves SQLite busy errors during phase anchor authorization" do
    secret = WorkKey.generate().secret
    now = DateTime.utc_now(:microsecond)

    grant = %AccessGrant{
      id: "grant-locked-phase-anchor",
      work_package_id: "SYMPP-ANCHOR",
      phase_id: @dashboard_phase_id,
      display_key: "ABCD",
      secret_hash: WorkKey.secret_hash(secret),
      grant_role: "architect",
      capabilities: ["read:phase"],
      claimed_at: now,
      claimed_by: "reviewer",
      expires_at: DateTime.add(now, 3600, :second),
      inserted_at: now,
      updated_at: now
    }

    LockedPhaseAnchorRepo.put_grant(grant)
    on_exit(fn -> LockedPhaseAnchorRepo.clear_grant() end)

    with_endpoint_repo(LockedPhaseAnchorRepo, fn ->
      assert {:error, :database_busy} = SymppDashboardApiController.authorize_board_grant_id(grant.id)

      assert %{"error" => %{"code" => "database_busy"}} =
               json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 503)
    end)
  end

  test "custom dashboard repo rejects invalid bearer probes before storage bootstrap" do
    with_endpoint_repo(MissingCustomRepo, fn ->
      unknown_work_key_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{WorkKey.generate().secret}")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(unknown_work_key_conn, "/api/v1/sympp/board"), 401)
    end)
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_completed_skipped_work_request!(repo, id, completed_at) do
    work_request = create_work_request!(repo, id: id, status: "ready_for_slicing")

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-#{id}"))

    assert {:ok, _skipped} = WorkRequestRepository.skip_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    assert {:ok, completed} = WorkRequestService.refresh_completion(repo, work_request.id)

    completed
    |> Ecto.Changeset.change(completed_at: completed_at, archived_at: nil)
    |> repo.update!()
  end

  defp create_work_package!(repo, overrides) do
    overrides
    |> WorkPackageFactory.attrs()
    |> then(&WorkPackageRepository.create(repo, &1))
    |> case do
      {:ok, work_package} -> work_package
      {:error, reason} -> flunk("failed to create WorkPackage: #{inspect(reason)}")
    end
  end

  defp create_comment_at!(repo, offset_seconds, attrs) do
    timestamp = DateTime.add(~U[2026-05-23 12:00:00.000000Z], offset_seconds, :second)

    assert {:ok, comment} = CommentService.create(repo, attrs)
    repo.update!(Ecto.Changeset.change(comment, inserted_at: timestamp, updated_at: timestamp))
  end

  defp numbered_comment_id(prefix, index), do: "#{prefix}-#{String.pad_leading(Integer.to_string(index), 3, "0")}"

  defp create_matching_work_package!(repo, work_request, planned_slice, overrides) do
    attrs =
      [
        kind: planned_slice.work_package_kind,
        title: planned_slice.title,
        repo: work_request.repo,
        base_branch: planned_slice.target_base_branch,
        branch_pattern: planned_slice.branch_pattern,
        product_description: work_request.human_description,
        allowed_file_globs: planned_slice.owned_file_globs,
        acceptance_criteria: planned_slice.acceptance_criteria
      ]
      |> Keyword.merge(overrides)

    create_work_package!(repo, attrs)
  end

  defp append_blocker_event!(repo, work_package_id, blocker_id, active, overrides) do
    attrs =
      [
        work_package_id: work_package_id,
        summary: "Blocked",
        status: if(active, do: "blocked", else: "unblocked"),
        idempotency_key: "#{blocker_id}-#{active}-#{System.unique_integer([:positive])}",
        payload: %{type: "blocker", source_tool: blocker_source_tool(active), blocker_id: blocker_id, active: active}
      ]
      |> Keyword.merge(overrides)
      |> Map.new()

    assert {:ok, event} = PlanningRepository.append_progress_event(repo, attrs)
    event
  end

  defp blocker_source_tool(true), do: "report_blocker"
  defp blocker_source_tool(false), do: "resolve_blocker"

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-DASH-#{System.unique_integer([:positive])}",
      title: "Improve intake flow",
      repo: "nextide/symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record the human's desired outcome before slicing.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false},
      desired_dispatch_shape: "single_package",
      status: "draft"
    }

    Enum.into(overrides, defaults)
  end

  defp question_attrs(overrides) do
    defaults = %{
      category: "scope",
      question: "Which branch should this target?",
      why_needed: "The architect needs the target before slicing."
    }

    Enum.into(overrides, defaults)
  end

  defp decision_attrs(overrides) do
    defaults = %{
      source_type: "architect",
      decision: "Keep this WorkRequest narrow.",
      rationale: "The next slice owns broader orchestration.",
      scope_impact: "No new runtime tools.",
      created_by: "architect-1"
    }

    Enum.into(overrides, defaults)
  end

  defp planned_slice_attrs(overrides) do
    defaults = %{
      title: "Add WorkRequest dashboard API",
      goal: "Expose read-only dashboard view models.",
      work_package_kind: "mcp",
      target_base_branch: "main",
      branch_pattern: "agent/SYMPP-V2-WR-004/workrequest-read-api",
      owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/dashboard.ex"],
      forbidden_file_globs: ["elixir/lib/symphony_elixir_web/live/**"],
      acceptance_criteria: ["WorkRequest dashboard API reads are scoped and redacted."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/dashboard_api_test.exs"],
      review_lanes: ["brief", "normal"],
      stop_conditions: ["Stop before UI or dispatch wiring."]
    }

    Enum.into(overrides, defaults)
  end

  defp delivery_attrs(overrides) do
    defaults = %{
      idempotency_key: "dashboard-delivery-#{System.unique_integer([:positive])}",
      recorded_by: "dashboard-api-test"
    }

    Enum.into(overrides, defaults)
  end

  defp create_dashboard_fixture(repo, opts \\ []) do
    id = Keyword.get(opts, :id, "SYMPP-DASH-API")
    status = Keyword.get(opts, :status, "planning")

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: id,
                 kind: "dashboard",
                 status: status,
                 title: "Dashboard API raw-secret-value",
                 branch_pattern: "agent/#{id}",
                 product_description: "Build dashboard with raw-secret-value",
                 engineering_scope: "No credential handling",
                 acceptance_criteria: ["Expose read API", "Redact raw-secret-value"]
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    assert {:ok, grant} = AccessGrantRepository.get(repo, minted.grant.id)

    append_state(repo, work_package, grant)

    %{work_package: work_package, grant: grant, work_key_secret: minted.work_key.secret}
  end

  defp append_state(repo, work_package, grant) do
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _plan_node} =
             PlanningRepository.append_plan_node(repo, %{
               work_package_id: work_package.id,
               title: "Implement API",
               body: "Add read endpoints",
               status: "done",
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "abc123"},
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/example/repo/pull/1", head_sha: "abc123"},
               created_at: DateTime.add(timestamp, 3, :second)
             })

    assert {:ok, _blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Blocked on validation",
               status: "blocked",
               idempotency_key: "blocker-a",
               payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "blocker-a", active: true},
               created_at: DateTime.add(timestamp, 4, :second)
             })

    assert {:ok, _finding} =
             PlanningRepository.append_finding(repo, %{
               work_package_id: work_package.id,
               title: "Finding one",
               body: "Needs attention",
               severity: "medium",
               access_grant_id: grant.id,
               created_at: DateTime.add(timestamp, 5, :second)
             })

    assert {:ok, _review_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Review submitted #{WorkKey.generate().secret}",
               status: "review_package_submitted",
               payload: %{
                 type: "review_package",
                 source_tool: "submit_review_package",
                 artifacts: ["review-log.txt"],
                 head_sha: "abc123",
                 url: "https://example.test/review?sig=raw-secret-value",
                 urls: ["https://example.test/one?sig=raw-secret-value"],
                 note: "Bearer raw-secret-value",
                 raw_secret: "raw-secret-value",
                 secret_hash: grant.secret_hash
               },
               created_at: DateTime.add(timestamp, 6, :second)
             })

    assert {:ok, _artifact} =
             PlanningService.append_artifact(repo, %{
               work_package_id: work_package.id,
               path: "review-log-raw-secret-value.txt",
               title: "Review log raw-secret-value",
               kind: "review",
               uri: "https://example.test/review-log.txt?X-Amz-Signature=raw-secret-value",
               metadata: %{"access_grant_id" => "grant-other-worker", "agent_run_id" => "run-other-worker"},
               created_at: DateTime.add(timestamp, 7, :second)
             })

    assert {:ok, _run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: work_package.id,
               access_grant_id: grant.id,
               actor_id: "worker-1",
               status: "running",
               attempt: 1,
               worker_host: "local",
               worker_task_handle: "task-1",
               workspace_path: "C:/tmp/workspace",
               session_id: "session-1"
             })
  end

  defp append_ready_evidence_with_review_artifacts(repo, work_package, artifacts) do
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _plan_node} =
             PlanningRepository.append_plan_node(repo, %{
               work_package_id: work_package.id,
               title: "Implement package",
               body: "Done",
               status: "done",
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{
                 type: "branch",
                 source_tool: "attach_branch",
                 branch: "agent/#{work_package.id}",
                 head_sha: "abc123"
               },
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/example/repo/pull/7",
                 head_sha: "abc123"
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    assert {:ok, _pr_sync} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR synced",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/example/repo/pull/7",
                 repository: "example/repo",
                 number: 7,
                 head_sha: "abc123",
                 check_summary: %{conclusion: "success"},
                 review_state: %{state: "approved"},
                 merge_state: %{state: "clean"}
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    append_review_package(repo, work_package, artifacts, DateTime.add(timestamp, 4, :second))

    Enum.each(artifacts, fn artifact ->
      assert {:ok, _artifact} =
               PlanningRepository.append_artifact(repo, %{
                 id: review_artifact_id(work_package.id, "abc123", artifact),
                 work_package_id: work_package.id,
                 path: artifact,
                 title: artifact,
                 kind: "review",
                 uri: "file://#{artifact}"
               })
    end)
  end

  defp append_ready_evidence_without_artifacts(repo, work_package) do
    append_ready_evidence_with_review_artifacts(repo, work_package, [])
  end

  defp append_review_package(repo, work_package, artifacts, created_at) do
    append_review_package(repo, work_package, artifacts, created_at, "abc123")
  end

  defp append_review_package(repo, work_package, artifacts, created_at, head_sha) do
    assert {:ok, _review_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Review package submitted",
               status: "review_package_submitted",
               payload: %{
                 type: "review_package",
                 source_tool: "submit_review_package",
                 acceptance_criteria_met: true,
                 tests: ["mix test test/symphony_elixir/symphony_plus_plus"],
                 artifacts: artifacts,
                 reviews: [
                   %{lane: "brief", verdict: "green"},
                   %{lane: "normal", verdict: "green"}
                 ],
                 head_sha: head_sha
               },
               created_at: created_at
             })
  end

  defp review_artifact_id(work_package_id, head_sha, artifact) do
    material = [work_package_id, head_sha || "no-head", artifact] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp review_suite_artifact_id(work_package_id, head_sha) do
    material = [work_package_id, head_sha, "review-suite-result.json"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp create_architect_grant_secret(repo, work_package_id) do
    phase_id = ensure_dashboard_phase(repo)
    assign_existing_packages_to_phase(repo, phase_id)
    work_key = WorkKey.generate()

    assert {:ok, grant} =
             AccessGrantRepository.create(repo, %{
               work_package_id: work_package_id,
               phase_id: phase_id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:phase"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    assert grant.display_key == work_key.display_key
    work_key.secret
  end

  defp create_legacy_phase_grant_secret(repo, work_package_id, grant_id) do
    now = DateTime.utc_now(:microsecond)
    work_key = WorkKey.generate()

    repo.insert!(%AccessGrant{
      id: grant_id,
      work_package_id: work_package_id,
      phase_id: nil,
      display_key: work_key.display_key,
      secret_hash: WorkKey.secret_hash(work_key.secret),
      grant_role: "architect",
      capabilities: ["read:phase"],
      expires_at: DateTime.add(now, 3600, :second)
    })

    assert {:ok, assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: "architect-legacy"}, DateTime.utc_now(:microsecond))

    assert assignment.phase_id == nil
    work_key.secret
  end

  defp ensure_dashboard_phase(repo) do
    case PhaseRepository.get(repo, @dashboard_phase_id) do
      {:ok, phase} ->
        phase.id

      {:error, :not_found} ->
        assert {:ok, phase} = PhaseRepository.create(repo, %{id: @dashboard_phase_id, title: "Dashboard test phase"})
        phase.id
    end
  end

  defp assign_existing_packages_to_phase(repo, phase_id) do
    assert {:ok, packages} = WorkPackageRepository.list(repo)

    Enum.each(packages, fn package ->
      assert {:ok, _updated} = WorkPackageRepository.update(repo, package.id, %{phase_id: phase_id})
    end)
  end

  defp create_claimed_worker_grant(repo, work_package_id, claimed_by) do
    {grant, _work_key} = create_claimed_worker_key(repo, work_package_id, claimed_by)
    grant
  end

  defp create_worker_grant_secret(repo, work_package_id, claimed_by) do
    {_grant, work_key} = create_claimed_worker_key(repo, work_package_id, claimed_by)
    work_key.secret
  end

  defp create_claimed_worker_key(repo, work_package_id, claimed_by) do
    work_key = WorkKey.generate()

    assert {:ok, grant} =
             AccessGrantRepository.create(repo, %{
               work_package_id: work_package_id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "worker",
               capabilities: ["read:package"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: claimed_by}, DateTime.utc_now(:microsecond))

    assert {:ok, grant} = AccessGrantRepository.get(repo, grant.id)
    {grant, work_key}
  end

  defp credential_target(%WorkPackage{id: work_package_id}, %AccessGrant{} = worker_grant) do
    "SymphonyPlusPlus:worker:#{work_package_id}:#{worker_grant.display_key}:#{String.trim(worker_grant.id)}"
  end

  defp restore_store_dir_env(nil), do: Application.delete_env(:symphony_elixir, :sympp_worker_secret_store_dir)
  defp restore_store_dir_env(store_dir), do: Application.put_env(:symphony_elixir, :sympp_worker_secret_store_dir, store_dir)

  defp with_trusted_repo_remotes(remotes, fun) when is_list(remotes) and is_function(fun, 0) do
    original = Application.fetch_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)
    Application.put_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes, remotes)

    try do
      fun.()
    after
      restore_fetched_app_env(:sympp_repo_identity_trusted_remotes, original)
    end
  end

  defp create_repo_identity_package!(repo, {key, id, raw_repo}) do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: id, repo: raw_repo, base_branch: "main")
             )

    {key, package}
  end

  defp create_repo_identity_request!(repo, {key, id, raw_repo}) do
    assert {:ok, request} =
             WorkRequestRepository.create(repo, %{
               title: "#{id} request",
               repo: raw_repo,
               base_branch: "main",
               work_type: "feature",
               human_description: "#{raw_repo} repo identity coverage.",
               constraints: %{},
               desired_dispatch_shape: "architect_led_feature_branch",
               status: "ready_for_clarification"
             })

    {key, request}
  end

  defp repo_identity_expectation(raw_repo) do
    %{
      repo: raw_repo,
      repo_key: String.downcase(raw_repo),
      repo_display: raw_repo,
      repo_remote: if(String.contains?(raw_repo, "/"), do: raw_repo),
      repo_aliases: [raw_repo]
    }
  end

  defp assert_repo_identity(record, expected) do
    Enum.each(expected, fn {field, value} ->
      assert Map.fetch!(record, field) == value
    end)
  end

  defp with_local_repo_origin(origin, fun) when is_binary(origin) and is_function(fun, 0) do
    original_repo_root = Application.fetch_env(:symphony_elixir, :sympp_repo_root)
    original_trusted_remotes = Application.fetch_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)
    repo_root = TestSupport.git_repo_with_origin_fixture!(origin, prefix: "sympp-dashboard-repo-root")
    script_path = Path.join([repo_root, "scripts", "sympp-worker-secret.ps1"])

    File.mkdir_p!(Path.dirname(script_path))
    File.write!(script_path, "# test fixture\n")

    Application.put_env(:symphony_elixir, :sympp_repo_root, repo_root)
    Application.delete_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)

    try do
      fun.()
    after
      restore_fetched_app_env(:sympp_repo_root, original_repo_root)
      restore_fetched_app_env(:sympp_repo_identity_trusted_remotes, original_trusted_remotes)
    end
  end

  defp restore_fetched_app_env(key, {:ok, value}), do: Application.put_env(:symphony_elixir, key, value)
  defp restore_fetched_app_env(key, :error), do: Application.delete_env(:symphony_elixir, key)

  defp work_request_detail(dashboard, work_request_id) do
    dashboard
    |> get_in(["work_request_details"])
    |> Kernel.||([])
    |> Enum.find(&(get_in(&1, ["work_request", "id"]) == work_request_id))
  end

  defp board_work_package_ids(dashboard) do
    dashboard
    |> get_in(["board", "groups"])
    |> Kernel.||(%{})
    |> Map.values()
    |> List.flatten()
    |> Enum.map(& &1["id"])
  end

  defp auth_conn(secret) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{secret}")
  end

  defp local_operator_conn do
    build_conn()
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("origin", "http://localhost")
  end

  defp local_operator_csrf_conn do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    local_operator_conn()
    |> Plug.Test.init_test_session(%{})
    |> put_req_header("x-csrf-token", csrf_token)
  end

  defp recycle_local_operator_conn(conn, origin) do
    conn
    |> recycle()
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("origin", origin)
  end

  defp with_operator_github_client(fun) when is_function(fun, 0) do
    original = Application.get_env(:symphony_elixir, :sympp_github_client)
    Application.put_env(:symphony_elixir, :sympp_github_client, FakeGitHubClient)

    try do
      fun.()
    after
      FakeGitHubClient.clear()

      case original do
        nil -> Application.delete_env(:symphony_elixir, :sympp_github_client)
        value -> Application.put_env(:symphony_elixir, :sympp_github_client, value)
      end
    end
  end

  defp with_operator_authenticated_github_client(fun) when is_function(fun, 0) do
    original = Application.get_env(:symphony_elixir, :sympp_github_client)
    Application.put_env(:symphony_elixir, :sympp_github_client, FakeAuthenticatedGitHubClient)
    FakeGhCli.clear()

    try do
      fun.()
    after
      FakeGitHubClient.clear()
      FakeGhCli.clear()

      case original do
        nil -> Application.delete_env(:symphony_elixir, :sympp_github_client)
        value -> Application.put_env(:symphony_elixir, :sympp_github_client, value)
      end
    end
  end

  defp with_operator_gh_cli_runner(fun) when is_function(fun, 0) do
    original_client = Application.get_env(:symphony_elixir, :sympp_github_client)
    original_runner = Application.get_env(:symphony_elixir, :sympp_gh_command_runner)

    Application.delete_env(:symphony_elixir, :sympp_github_client)
    Application.put_env(:symphony_elixir, :sympp_gh_command_runner, &FakeGhCli.run/3)

    try do
      fun.()
    after
      FakeGhCli.clear()

      case original_client do
        nil -> Application.delete_env(:symphony_elixir, :sympp_github_client)
        value -> Application.put_env(:symphony_elixir, :sympp_github_client, value)
      end

      case original_runner do
        nil -> Application.delete_env(:symphony_elixir, :sympp_gh_command_runner)
        value -> Application.put_env(:symphony_elixir, :sympp_gh_command_runner, value)
      end
    end
  end

  defp with_static_dashboard_file(file_name, contents, fun) when is_function(fun, 0) do
    static_dir =
      :symphony_elixir
      |> :code.priv_dir()
      |> Path.join("static")

    path = Path.join(static_dir, file_name)
    original = File.read(path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)

    try do
      fun.()
    after
      case original do
        {:ok, previous} -> File.write!(path, previous)
        {:error, _reason} -> File.rm(path)
      end
    end
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), sympp_repo: Repo)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp with_local_operator_endpoint(fun) when is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :sympp_local_operator, true)
    )

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end
  end

  defp with_endpoint_repo(repo, fun) when is_atom(repo) and is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :sympp_repo, repo)
    )

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end
  end

  defp with_runtime_endpoint_repo(repo, fun) when is_atom(repo) and is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    original_runtime_repo = SymphonyElixirWeb.Endpoint.config(:sympp_repo)

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :sympp_repo, repo)
    )

    SymphonyElixirWeb.Endpoint.config_change([{SymphonyElixirWeb.Endpoint, [sympp_repo: repo]}], [])

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
      SymphonyElixirWeb.Endpoint.config_change([{SymphonyElixirWeb.Endpoint, [sympp_repo: original_runtime_repo]}], [])
    end
  end

  defp with_dynamic_endpoint_database(database_path, fun) when is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.delete(endpoint_config, :sympp_repo)
    )

    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)

      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end
    end
  end

  defp with_configured_endpoint_database(database_path, fun) when is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :sympp_repo, Repo)
    )

    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)

      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end
    end
  end

  defp with_repo_configured_endpoint_database(database_path, fun) when is_function(fun, 0) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_repo_config = Application.get_env(:symphony_elixir, Repo, [])

    Application.put_env(
      :symphony_elixir,
      SymphonyElixirWeb.Endpoint,
      Keyword.put(endpoint_config, :sympp_repo, Repo)
    )

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, Repo, Keyword.put(original_repo_config, :database, database_path))

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
      Application.put_env(:symphony_elixir, Repo, original_repo_config)

      case original_database do
        nil -> Application.delete_env(:symphony_elixir, :sympp_repo_database)
        value -> Application.put_env(:symphony_elixir, :sympp_repo_database, value)
      end
    end
  end

  defp seed_dashboard_database(database_path) do
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      assert :ok = WorkPackageRepository.migrate(Repo)
      %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(Repo, id: "SYMPP-ALT-DB")
      {work_package.id, secret}
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
    end
  end

  defp seed_dashboard_session_database(database_path) do
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      assert :ok = WorkPackageRepository.migrate(Repo)

      %{work_package: work_package, work_key_secret: package_secret} =
        create_dashboard_fixture(Repo, id: "SYMPP-DEFAULT-SESSION")

      board_secret = create_architect_grant_secret(Repo, work_package.id)

      {work_package.id, board_secret, package_secret}
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
    end
  end

  defp seed_pre_phase_dashboard_database(database_path, opts \\ []) do
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      pre_phase_migration = 20_260_503_192_500

      migrated_versions =
        Ecto.Migrator.run(Repo, WorkPackageRepository.migrations_path(), :up,
          to: pre_phase_migration,
          log: false
        )

      assert pre_phase_migration in migrated_versions

      now = DateTime.utc_now(:microsecond)
      expires_at = DateTime.add(now, 86_400, :second)
      work_key = WorkKey.generate()
      work_package_id = Keyword.get(opts, :work_package_id, "SYMPP-PRE-PHASE-AUTH")
      grant_id = Keyword.get(opts, :grant_id, "grant-pre-phase-auth")
      grant_role = Keyword.get(opts, :grant_role, "worker")
      capabilities = opts |> Keyword.get(:capabilities, ["read:package"]) |> Jason.encode!()
      claimed_by = Keyword.get(opts, :claimed_by, "worker-1")

      Repo.query!(
        """
        INSERT INTO sympp_work_packages
          (id, kind, title, repo, base_branch, branch_pattern, product_description,
           engineering_scope, acceptance_criteria, status, parent_id, owner_id,
           allowed_file_globs, policy_template, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          work_package_id,
          "mcp",
          "Pre-phase auth package",
          "Pimpmuckl/symphony-plus-plus",
          "symphony-plus-plus/beta",
          nil,
          nil,
          nil,
          "[]",
          "created",
          nil,
          nil,
          "[]",
          nil,
          now,
          now
        ]
      )

      Repo.query!(
        """
        INSERT INTO sympp_access_grants
          (id, work_package_id, display_key, secret_hash, grant_role, capabilities,
           expires_at, revoked_at, claimed_at, claimed_by, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          grant_id,
          work_package_id,
          work_key.display_key,
          WorkKey.secret_hash(work_key.secret),
          grant_role,
          capabilities,
          expires_at,
          nil,
          now,
          claimed_by,
          now,
          now
        ]
      )

      {work_package_id, work_key.secret}
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
    end
  end

  defp seed_dashboard_database_at_migration(database_path, migration_version, opts) do
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      migrated_versions =
        Ecto.Migrator.run(Repo, WorkPackageRepository.migrations_path(), :up,
          to: migration_version,
          log: false
        )

      assert migration_version in migrated_versions

      now = DateTime.utc_now(:microsecond)
      expires_at = DateTime.add(now, 86_400, :second)
      work_key = WorkKey.generate()
      work_package_id = Keyword.fetch!(opts, :work_package_id)
      grant_id = Keyword.fetch!(opts, :grant_id)
      capabilities = opts |> Keyword.get(:capabilities, ["read:package"]) |> Jason.encode!()

      insert_legacy_dashboard_row("sympp_work_packages", [
        {"id", work_package_id},
        {"kind", "mcp"},
        {"title", "Legacy auth package"},
        {"repo", "Pimpmuckl/symphony-plus-plus"},
        {"base_branch", "symphony-plus-plus/beta"},
        {"branch_pattern", nil},
        {"product_description", nil},
        {"engineering_scope", nil},
        {"acceptance_criteria", "[]"},
        {"status", "created"},
        {"parent_id", nil},
        {"owner_id", nil},
        {"allowed_file_globs", "[]"},
        {"policy_template", nil},
        {"phase_id", Keyword.get(opts, :work_package_phase_id, nil)},
        {"inserted_at", now},
        {"updated_at", now}
      ])

      insert_legacy_dashboard_row("sympp_access_grants", [
        {"id", grant_id},
        {"work_package_id", work_package_id},
        {"phase_id", Keyword.get(opts, :grant_phase_id, nil)},
        {"scope_repo", Keyword.get(opts, :scope_repo, nil)},
        {"scope_base_branch", Keyword.get(opts, :scope_base_branch, nil)},
        {"display_key", work_key.display_key},
        {"secret_hash", WorkKey.secret_hash(work_key.secret)},
        {"grant_role", Keyword.get(opts, :grant_role, "worker")},
        {"provenance", Keyword.get(opts, :provenance, nil)},
        {"capabilities", capabilities},
        {"expires_at", expires_at},
        {"revoked_at", nil},
        {"claimed_at", now},
        {"claimed_by", Keyword.get(opts, :claimed_by, "worker-1")},
        {"inserted_at", now},
        {"updated_at", now}
      ])

      {work_package_id, work_key.secret}
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
    end
  end

  defp insert_legacy_dashboard_row(table, attrs)
       when table in ["sympp_access_grants", "sympp_work_packages"] and is_list(attrs) do
    columns = table_columns_for_repo(table)
    row = Enum.filter(attrs, fn {column, _value} -> column in columns end)
    column_sql = Enum.map_join(row, ", ", &elem(&1, 0))
    placeholders = Enum.map_join(row, ", ", fn _field -> "?" end)
    values = Enum.map(row, &elem(&1, 1))

    Repo.query!("INSERT INTO #{table} (#{column_sql}) VALUES (#{placeholders})", values)
  end

  defp table_columns_for_repo(table) when table in ["sympp_access_grants", "sympp_work_packages"] do
    "PRAGMA table_info(#{table})"
    |> Repo.query!([])
    |> Map.fetch!(:rows)
    |> Enum.map(fn [_index, name | _rest] -> name end)
  end

  defp table_columns(database_path, table) when table in ["sympp_access_grants", "sympp_work_packages"] do
    {:ok, pid} = Repo.start_link(database: database_path, name: nil, pool_size: 1, log: false)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      "PRAGMA table_info(#{table})"
      |> Repo.query!([])
      |> Map.fetch!(:rows)
      |> Enum.map(fn [_index, name | _rest] -> name end)
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
    end
  end
end
