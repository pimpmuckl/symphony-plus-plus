defmodule SymphonyElixir.SymphonyPlusPlus.DashboardApiTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule BusyRepo do
    @moduledoc false

    def all(_query), do: raise(%Exqlite.Error{message: "database is locked"})
    def one(_query), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule MissingCustomRepo do
    @moduledoc false

    def __adapter__, do: Ecto.Adapters.SQLite3
    def config, do: [database: SymphonyElixir.WorkPackageFactory.database_path()]
    def start_link(_opts), do: raise("custom repo should not start for invalid bearer probes")
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
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
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

    payload = json_response(get(auth_conn(architect_secret), "/api/v1/sympp/board"), 200)

    assert payload["total_count"] == 2
    assert [%{"id" => "SYMPP-DASH-1"}] = payload["groups"]["planning"]
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
    assert [%{"path" => "[REDACTED]", "title" => "[REDACTED]", "kind" => "review"}] = payload["artifacts"]
    assert [%{"id" => "blocker-a", "active" => true}] = payload["blockers"]
    assert [%{"id" => grant_id, "display_key" => display_key, "status" => "active"}] = payload["grants"]
    assert grant_id == grant.id
    assert display_key == grant.display_key
    assert [%{"status" => "completed", "session_id" => "session-1"}] = payload["agent_runs"]

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

  test "metadata suppresses PR and review payloads without a current branch head", %{repo: repo} do
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
    assert payload["metadata"]["pr"] == nil
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
    assert payload["metadata"]["pr"] == nil
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

    assert %{"artifacts" => [%{"path" => "[REDACTED]", "title" => "[REDACTED]"}]} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/artifacts"), 200)

    assert %{"blockers" => [%{"id" => "blocker-a", "active" => true}]} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/blockers"), 200)

    assert %{"grants" => [%{"grant_role" => "worker"}]} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/grants"), 200)

    assert %{"agent_runs" => [%{"worker_task_handle" => "task-1"}]} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/work-packages/#{work_package.id}/agent-runs"), 200)
  end

  test "worker-scoped API cannot fetch global board and cannot fetch sibling packages", %{repo: repo} do
    %{work_package: work_package, work_key_secret: secret} = create_dashboard_fixture(repo)
    assert {:ok, sibling} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-SIBLING"))

    assert %{"error" => %{"code" => "forbidden"}} =
             json_response(get(auth_conn(secret), "/api/v1/sympp/board"), 403)

    assert %{"work_package" => %{"id" => fetched_id}} =
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

  test "custom dashboard repo rejects invalid bearer probes before storage bootstrap" do
    with_endpoint_repo(MissingCustomRepo, fn ->
      unknown_work_key_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{WorkKey.generate().secret}")

      assert %{"error" => %{"code" => "unauthorized"}} =
               json_response(get(unknown_work_key_conn, "/api/v1/sympp/board"), 401)
    end)
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

  defp create_architect_grant_secret(repo, work_package_id) do
    work_key = WorkKey.generate()

    assert {:ok, grant} =
             AccessGrantRepository.create(repo, %{
               work_package_id: work_package_id,
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

  defp create_claimed_worker_grant(repo, work_package_id, claimed_by) do
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
    grant
  end

  defp auth_conn(secret) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{secret}")
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), sympp_repo: Repo)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
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
end
