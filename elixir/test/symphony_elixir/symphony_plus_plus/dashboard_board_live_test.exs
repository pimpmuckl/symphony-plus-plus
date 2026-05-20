defmodule SymphonyElixir.SymphonyPlusPlus.DashboardBoardLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  alias Phoenix.HTML.Safe
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.Layouts
  alias SymphonyElixirWeb.SymppBoardLive
  alias SymphonyElixirWeb.SymppDashboardApiController

  @endpoint SymphonyElixirWeb.Endpoint
  @dashboard_phase_id "phase-dashboard-live-test"

  defmodule CustomBoardRepo do
    @moduledoc false

    use Ecto.Repo, otp_app: :symphony_elixir, adapter: Ecto.Adapters.SQLite3
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

    :ok
  end

  setup do
    Repo.delete_all(AgentRun)
    Repo.delete_all(Artifact)
    Repo.delete_all(ProgressEvent)
    Repo.delete_all(Finding)
    Repo.delete_all(PlanNode)
    Repo.delete_all(AccessGrant)
    Repo.delete_all(WorkPackage)
    Repo.delete_all(Phase)
    :ok
  end

  test "renders status columns and compact cards from the dashboard read model" do
    create_board_package(%{
      id: "SYMPP-P5-002",
      kind: "dashboard",
      status: "implementing",
      title: "Dashboard board UI",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta",
      blocker?: true,
      pr_url: "https://github.com/example/symphony-plus-plus/pull/22"
    })

    create_board_package(%{
      id: "SYMPP-P4-001",
      kind: "quick_fix",
      status: "ready_for_worker",
      title: "Standalone create work CLI",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    secret = create_architect_grant_secret(Repo, "SYMPP-P5-002")

    {:ok, _view, html} = live(auth_conn(secret), "/sympp/board")

    assert html =~ "Work package board"
    refute html =~ ~s(data-sympp-project-rail)
    refute html =~ ~s(data-sympp-stream-pin)
    assert html =~ "Implementing"
    assert html =~ "Ready for worker"
    assert html =~ "SYMPP-P5-002"
    assert html =~ "Dashboard board UI"
    assert html =~ ~s(href="work-packages/SYMPP-P5-002")
    assert html =~ "dashboard"
    assert html =~ "nextide/symphony-plus-plus / symphony-plus-plus/beta"
    assert html =~ "Blockers"
    assert html =~ ~s(href="https://github.com/example/symphony-plus-plus/pull/22")
    assert html =~ "Implementation"
    assert html =~ "Review attached"
    assert html =~ "Merge"
    assert html =~ "active run"
    assert html =~ "Blockers"
  end

  test "renders runtime alert indicators for stale runs and missing readiness evidence" do
    stale_package =
      create_board_package(%{
        id: "SYMPP-P5-004-STALE",
        kind: "dashboard",
        status: "implementing",
        title: "Stale runtime package",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta",
        blocker?: true
      })

    assert {:ok, [run]} = AgentRunRepository.list_for_work_package(Repo, stale_package.id)
    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -600, :second)

    assert {:ok, _stale_run} =
             run
             |> AgentRun.update_changeset(%{last_seen_at: stale_seen_at})
             |> Repo.update()

    assert {:ok, missing_package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P5-004-MISSING",
                 kind: "mcp",
                 status: "ready_for_human_merge",
                 title: "Missing evidence package",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 policy_template: "mcp"
               )
             )

    secret = create_architect_grant_secret(Repo, stale_package.id)
    create_architect_grant_secret(Repo, missing_package.id)

    {:ok, _view, html} = live(auth_conn(secret), "/sympp/board")

    assert html =~ "Stale runtime package"
    assert html =~ "stale run"
    assert html =~ "Stale heartbeat"
    assert html =~ "Blockers"
    assert html =~ "Missing evidence package"
    assert html =~ "Missing readiness evidence"
    refute html =~ ~r/<button[^>]*>\s*(Stop|Retry|Merge|Revoke|Claim|Notify)\s*<\/button>/
  end

  test "renders queued-only runs as queued on board cards" do
    queued_package =
      create_board_package(%{
        id: "SYMPP-P5-004-QUEUED",
        kind: "dashboard",
        status: "implementing",
        title: "Queued runtime package",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    assert {:ok, _queued_run} =
             AgentRunRepository.start_run(Repo, %{
               work_package_id: queued_package.id,
               access_grant_id: nil,
               actor_id: "worker-1",
               status: "starting",
               attempt: 1,
               worker_task_handle: "queued-task"
             })

    secret = create_architect_grant_secret(Repo, queued_package.id)
    {:ok, _view, html} = live(auth_conn(secret), "/sympp/board")

    assert html =~ "Queued runtime package"
    assert html =~ "queued run"
    refute html =~ "active run"
  end

  test "renders empty board state" do
    create_board_package(%{
      id: "SYMPP-P5-012",
      kind: "dashboard",
      status: "implementing",
      title: "Filtered auth package",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    secret = create_architect_grant_secret(Repo, "SYMPP-P5-012")

    {:ok, _view, html} = live(auth_conn(secret), "/sympp/board?kind=not-present")

    assert html =~ "No work packages match the current board filters."
    refute html =~ "Filtered auth package"
  end

  test "encodes package ids in board detail links" do
    raw_id = "SYMPP-P5-LINK/ONE?x=1"

    create_board_package(%{
      id: raw_id,
      kind: "dashboard",
      status: "implementing",
      title: "Encoded link package",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    secret = create_architect_grant_secret(Repo, raw_id)

    {:ok, _view, html} = live(auth_conn(secret), "/sympp/board")

    assert html =~ ~s(href="work-packages/#{path_segment(raw_id)}")
    refute html =~ ~s(href="work-packages/#{raw_id}")
  end

  test "encodes dot-only package ids in board detail links" do
    raw_id = ".."

    create_board_package(%{
      id: raw_id,
      kind: "dashboard",
      status: "implementing",
      title: "Dot link package",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    secret = create_architect_grant_secret(Repo, raw_id)

    {:ok, _view, html} = live(auth_conn(secret), "/sympp/board")

    assert html =~ ~s(href="work-packages/%2E%2E")
    refute html =~ ~s(href="work-packages/..")
  end

  test "filters packages by kind repo and phase without mutating state" do
    create_board_package(%{
      id: "SYMPP-P5-002",
      kind: "dashboard",
      status: "implementing",
      title: "Visible dashboard package",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    create_board_package(%{
      id: "SYMPP-P6-001",
      kind: "integration",
      status: "implementing",
      title: "Hidden integration package",
      repo: "nextide/other",
      base_branch: "main"
    })

    secret = create_architect_grant_secret(Repo, "SYMPP-P5-002")

    {:ok, _view, html} =
      live(board_session_conn(secret), "/sympp/board?kind=dashboard&repo=nextide/symphony-plus-plus&phase=P5")

    assert html =~ "Visible dashboard package"
    refute html =~ "Hidden integration package"
    assert html =~ ~s(method="get")
    refute html =~ ~s(method="post")
    refute html =~ ~r/<button[^>]*>\s*Merge\s*<\/button>/
    refute html =~ ~r/<button[^>]*>\s*Revoke\s*<\/button>/
  end

  test "phase progress summary stays stable across visible board filters" do
    anchor =
      create_board_package(%{
        id: "SYMPP-P7-003-ANCHOR",
        kind: "dashboard",
        status: "implementing",
        title: "Progress anchor",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    create_board_package(%{
      id: "SYMPP-P7-003-MERGED",
      kind: "phase_child",
      status: "merged_into_phase",
      title: "Merged visible child",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta",
      parent_id: anchor.id
    })

    create_board_package(%{
      id: "SYMPP-P8-003-READY",
      kind: "phase_child",
      status: "ready_for_architect_merge",
      title: "Ready filtered child",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta",
      parent_id: anchor.id
    })

    create_board_package(%{
      id: "SYMPP-P8-004-BLOCKED",
      kind: "phase_child",
      status: "blocked",
      title: "Blocked filtered child",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta",
      parent_id: anchor.id
    })

    secret = create_architect_grant_secret(Repo, anchor.id)

    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/board?kind=phase_child&phase=P7")

    assert html =~ "Merged visible child"
    refute html =~ "Progress anchor"
    refute html =~ "Ready filtered child"
    refute html =~ "Blocked filtered child"
    assert html =~ "1/3 children merged"
    refute html =~ "1/1 children merged"
  end

  test "redacted card fields do not display raw secrets and github sync is optional" do
    create_board_package(%{
      id: "SYMPP-P5-009",
      kind: "dashboard",
      status: "planning",
      title: "Leaked raw-secret-value",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta",
      pr_url: nil
    })

    secret = create_architect_grant_secret(Repo, "SYMPP-P5-009")

    {:ok, _view, html} = live(auth_conn(secret), "/sympp/board")

    assert html =~ "SYMPP-P5-009"
    assert html =~ "[REDACTED]"
    refute html =~ "raw-secret-value"
    refute html =~ "wk_"
  end

  test "does not render non-http PR metadata as a board link" do
    create_board_package(%{
      id: "SYMPP-P5-022",
      kind: "dashboard",
      status: "planning",
      title: "Unsafe PR metadata package",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta",
      pr_url: "javascript:alert(1)"
    })

    secret = create_architect_grant_secret(Repo, "SYMPP-P5-022")

    {:ok, _view, html} = live(auth_conn(secret), "/sympp/board")

    assert html =~ "Unsafe PR metadata package"
    refute html =~ "href=\"javascript:alert(1)\""
    refute html =~ ">PR</a>"
  end

  test "uses the configured ledger path instead of an unrelated named repo" do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

    on_exit(fn ->
      restore_database_env(original_database)
      File.rm(database_path)
    end)

    secret =
      with_transient_repo(database_path, fn ->
        create_board_package(%{
          id: "SYMPP-P5-010",
          kind: "dashboard",
          status: "implementing",
          title: "Selected ledger package",
          repo: "nextide/symphony-plus-plus",
          base_branch: "symphony-plus-plus/beta"
        })

        create_architect_grant_secret(Repo, "SYMPP-P5-010")
      end)

    {:ok, _view, html} = live(auth_conn(secret), "/sympp/board")

    assert html =~ "Selected ledger package"
    assert html =~ "SYMPP-P5-010"
  end

  test "migrates an existing configured ledger before rendering the browser board" do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_migrated_databases = Application.get_env(:symphony_elixir, :sympp_board_live_migrated_databases)

    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

    on_exit(fn ->
      restore_database_env(original_database)
      restore_board_live_migrated_databases(original_migrated_databases)
      File.rm(database_path)
    end)

    secret =
      seed_legacy_repo(database_path, fn ->
        insert_legacy_work_package(Repo, %{
          id: "SYMPP-P5-021",
          kind: "dashboard",
          status: "implementing",
          title: "Legacy configured package",
          repo: "nextide/symphony-plus-plus",
          base_branch: "symphony-plus-plus/beta"
        })

        create_architect_grant_secret(Repo, "SYMPP-P5-021")
      end)

    Application.put_env(
      :symphony_elixir,
      :sympp_board_live_migrated_databases,
      MapSet.new([{Repo, Repo.database_key(database_path)}])
    )

    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/board")

    assert html =~ "Legacy configured package"
    refute html =~ "The Symphony++ work package ledger could not be read."
  end

  test "uses the default repo when endpoint sympp_repo is unset" do
    create_board_package(%{
      id: "SYMPP-P5-023",
      kind: "dashboard",
      status: "implementing",
      title: "Unset endpoint repo package",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    secret = create_architect_grant_secret(Repo, "SYMPP-P5-023")

    with_endpoint_repo(nil, fn ->
      {:ok, _view, html} = live(board_session_conn(secret), "/sympp/board")

      assert html =~ "Unset endpoint repo package"
      refute html =~ "No Symphony++ work package ledger was found."
    end)
  end

  test "migrates a running custom repo before rendering the browser board" do
    stop_named_repo(CustomBoardRepo)

    database_path = WorkPackageFactory.database_path()
    original_custom_repo_config = Application.get_env(:symphony_elixir, CustomBoardRepo)

    Application.put_env(:symphony_elixir, CustomBoardRepo, database: database_path)

    on_exit(fn ->
      stop_named_repo(CustomBoardRepo)
      restore_custom_repo_env(original_custom_repo_config)
      File.rm(database_path)
    end)

    secret =
      seed_running_legacy_custom_repo(database_path, fn ->
        insert_legacy_work_package(CustomBoardRepo, %{
          id: "SYMPP-P5-024",
          kind: "dashboard",
          status: "implementing",
          title: "Running legacy custom package",
          repo: "nextide/symphony-plus-plus",
          base_branch: "symphony-plus-plus/beta"
        })

        create_architect_grant_secret(CustomBoardRepo, "SYMPP-P5-024")
      end)

    with_endpoint_repo(CustomBoardRepo, fn ->
      {:ok, _view, html} = live(board_session_conn(secret), "/sympp/board")

      assert html =~ "Running legacy custom package"
      refute html =~ "The Symphony++ work package ledger could not be read."
    end)
  end

  test "uses a running default repo when no configured ledger path exists" do
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    on_exit(fn -> restore_database_env(original_database) end)

    create_board_package(%{
      id: "SYMPP-P5-020",
      kind: "dashboard",
      status: "implementing",
      title: "Running repo package",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    secret = create_architect_grant_secret(Repo, "SYMPP-P5-020")

    with_endpoint_repo(nil, fn ->
      {:ok, _view, html} = live(board_session_conn(secret), "/sympp/board")

      assert html =~ "Running repo package"
      refute html =~ "No Symphony++ work package ledger was found."
    end)
  end

  test "prefers the running default repo over a stale default path" do
    create_board_package(%{
      id: "SYMPP-P5-027",
      kind: "dashboard",
      status: "implementing",
      title: "Running default beats stale path package",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    secret = create_architect_grant_secret(Repo, "SYMPP-P5-027")
    conn = board_session_conn(secret)

    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_default_database_root = Application.get_env(:symphony_elixir, :sympp_repo_default_database_root)
    original_workflow_path = Application.get_env(:symphony_elixir, :workflow_file_path)
    workflow_id = "sympp-dashboard-stale-db-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    workflow_path = Path.join([System.tmp_dir!(), workflow_id, "WORKFLOW.md"])
    default_database_root = Path.join([System.tmp_dir!(), workflow_id, ".symphony_plus_plus"])

    on_exit(fn ->
      restore_database_env(original_database)
      restore_default_database_root_env(original_default_database_root)
      restore_workflow_path(original_workflow_path)
    end)

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, :sympp_repo_default_database_root, default_database_root)
    Workflow.set_workflow_file_path(workflow_path)
    assert Repo.database_path_if_present() == nil
    stale_database_path = Repo.database_path()

    assert File.dir?(default_database_root)
    refute File.exists?(stale_database_path)

    on_exit(fn -> File.rm(stale_database_path) end)

    with_transient_repo(stale_database_path, fn -> :ok end)

    with_endpoint_repo(nil, fn ->
      {:ok, _view, html} = live(conn, "/sympp/board")

      assert html =~ "Running default beats stale path package"
    end)
  end

  test "does not create or migrate a missing ledger on board load" do
    missing_database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    File.rm(missing_database_path)
    Application.put_env(:symphony_elixir, :sympp_repo_database, missing_database_path)

    on_exit(fn ->
      restore_database_env(original_database)
      File.rm(missing_database_path)
    end)

    conn = get(build_conn(), "/sympp/board")

    assert response(conn, 401) =~ "Board access"
    refute File.exists?(missing_database_path)
  end

  test "starts a configured custom repo before reading the board" do
    stop_named_repo(CustomBoardRepo)

    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_custom_repo_config = Application.get_env(:symphony_elixir, CustomBoardRepo)

    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)
    Application.put_env(:symphony_elixir, CustomBoardRepo, database: database_path)

    on_exit(fn ->
      stop_named_repo(CustomBoardRepo)
      restore_database_env(original_database)
      restore_custom_repo_env(original_custom_repo_config)
      File.rm(database_path)
    end)

    secret =
      seed_custom_repo(database_path, fn ->
        assert {:ok, _work_package} =
                 WorkPackageRepository.create(
                   CustomBoardRepo,
                   WorkPackageFactory.attrs(
                     id: "SYMPP-P5-013",
                     kind: "dashboard",
                     status: "implementing",
                     title: "Custom repo board package",
                     repo: "nextide/symphony-plus-plus",
                     base_branch: "symphony-plus-plus/beta"
                   )
                 )

        create_architect_grant_secret(CustomBoardRepo, "SYMPP-P5-013")
      end)

    with_endpoint_repo(CustomBoardRepo, fn ->
      {:ok, _view, html} = live(auth_conn(secret), "/sympp/board")

      assert html =~ "Custom repo board package"
      assert html =~ "SYMPP-P5-013"
    end)
  end

  test "rejects an already-running custom repo for a different ledger" do
    stop_named_repo(CustomBoardRepo)

    wrong_database_path = WorkPackageFactory.database_path()
    selected_database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_custom_repo_config = Application.get_env(:symphony_elixir, CustomBoardRepo)

    Application.put_env(:symphony_elixir, :sympp_repo_database, selected_database_path)
    Application.put_env(:symphony_elixir, CustomBoardRepo, database: selected_database_path)

    on_exit(fn ->
      stop_named_repo(CustomBoardRepo)
      restore_database_env(original_database)
      restore_custom_repo_env(original_custom_repo_config)
      File.rm(wrong_database_path)
      File.rm(selected_database_path)
    end)

    secret =
      seed_custom_repo(selected_database_path, fn ->
        assert {:ok, _selected_package} =
                 WorkPackageRepository.create(
                   CustomBoardRepo,
                   WorkPackageFactory.attrs(
                     id: "SYMPP-P5-016",
                     kind: "dashboard",
                     status: "implementing",
                     title: "Selected custom repo package",
                     repo: "nextide/symphony-plus-plus",
                     base_branch: "symphony-plus-plus/beta"
                   )
                 )

        create_architect_grant_secret(CustomBoardRepo, "SYMPP-P5-016")
      end)

    {:ok, pid} = CustomBoardRepo.start_link(database: wrong_database_path, name: CustomBoardRepo)
    Process.unlink(pid)
    assert :ok = WorkPackageRepository.migrate(CustomBoardRepo)

    assert {:ok, _wrong_package} =
             WorkPackageRepository.create(
               CustomBoardRepo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P5-014",
                 kind: "dashboard",
                 status: "implementing",
                 title: "Wrong custom repo package",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    with_endpoint_repo(CustomBoardRepo, fn ->
      conn = get(auth_conn(secret), "/sympp/board")

      assert response(conn, 401) =~ "Board access"
      refute response(conn, 401) =~ "Wrong custom repo package"
    end)
  end

  test "renders DateTime timestamps and string-keyed metadata in board cards" do
    html =
      %{
        empty_filter: "all",
        filters: %{kind: "all", repo: "all", phase: "all"},
        board: %{
          error: nil,
          total_count: 1,
          visible_count: 1,
          column_count: 1,
          filter_options: %{kinds: [], repos: [], phases: []},
          columns: [
            %{
              status: "implementing",
              cards: [
                %{
                  id: "SYMPP-P5-011",
                  kind: "dashboard",
                  title: "String metadata package",
                  repo: "nextide/symphony-plus-plus",
                  base_branch: "symphony-plus-plus/beta",
                  status: "implementing",
                  latest_progress_at: ~U[2026-05-05 00:00:00Z],
                  updated_at: ~U[2026-05-04 00:00:00Z],
                  active_blocker_count: 0,
                  plan: %{total_count: 1, completed_count: 1, open_count: 0},
                  metadata: %{
                    "pr" => %{"url" => "https://github.com/example/symphony-plus-plus/pull/26"},
                    "review_package" => %{
                      "head_sha" => "abc123",
                      "reviews" => [
                        %{"lane" => "review_t1", "verdict" => "green"},
                        %{"lane" => "review_t2", "verdict" => "green"}
                      ]
                    }
                  },
                  active_agent_run: nil
                }
              ]
            }
          ]
        }
      }
      |> SymppBoardLive.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    pipeline_steps = pipeline_step_texts(html)

    assert html =~ "String metadata package"
    assert "Implementationactive" in pipeline_steps
    assert html =~ "Review-T2"
    assert "ReviewReview-T2" in pipeline_steps
    assert html =~ ~s(href="https://github.com/example/symphony-plus-plus/pull/26")
    refute "Implementationdone" in pipeline_steps
    refute html =~ "n/a"
  end

  test "pipeline surfaces failed or pending review lanes without marking them ready" do
    html =
      %{
        empty_filter: "all",
        filters: %{kind: "all", repo: "all", phase: "all"},
        board: %{
          error: nil,
          total_count: 5,
          visible_count: 5,
          column_count: 1,
          filter_options: %{kinds: [], repos: [], phases: []},
          columns: [
            %{
              status: "implementing",
              cards: [
                %{
                  id: "SYMPP-P5-012",
                  kind: "dashboard",
                  title: "Failed review package",
                  repo: "nextide/symphony-plus-plus",
                  base_branch: "main",
                  latest_progress_at: ~U[2026-05-05 00:00:00Z],
                  updated_at: ~U[2026-05-04 00:00:00Z],
                  active_blocker_count: 0,
                  plan: %{total_count: 1, completed_count: 1, open_count: 0},
                  metadata: %{
                    review_package: %{
                      reviews: [
                        %{lane: "review_t1", verdict: "green"},
                        %{lane: "review_t2", verdict: "red"}
                      ]
                    }
                  },
                  active_agent_run: nil
                },
                %{
                  id: "SYMPP-P5-016",
                  kind: "dashboard",
                  title: "Latest lower-lane package rerun",
                  repo: "nextide/symphony-plus-plus",
                  base_branch: "main",
                  latest_progress_at: ~U[2026-05-05 00:00:00Z],
                  updated_at: ~U[2026-05-04 00:00:00Z],
                  active_blocker_count: 0,
                  plan: %{total_count: 1, completed_count: 1, open_count: 0},
                  metadata: %{
                    review_package: %{
                      reviews: [
                        %{lane: "review_t2", verdict: "green"},
                        %{lane: "review_t1", verdict: "red"}
                      ]
                    }
                  },
                  active_agent_run: nil
                },
                %{
                  id: "SYMPP-P5-013",
                  kind: "dashboard",
                  title: "Pending review package",
                  repo: "nextide/symphony-plus-plus",
                  base_branch: "main",
                  latest_progress_at: ~U[2026-05-05 00:00:00Z],
                  updated_at: ~U[2026-05-04 00:00:00Z],
                  active_blocker_count: 0,
                  plan: %{total_count: 1, completed_count: 1, open_count: 0},
                  metadata: %{
                    review_suite_result: %{
                      suite: "review_t3",
                      status: "signoff_pending",
                      verdict: "pending"
                    }
                  },
                  active_agent_run: nil
                },
                %{
                  id: "SYMPP-P5-014",
                  kind: "dashboard",
                  title: "Combined review metadata",
                  repo: "nextide/symphony-plus-plus",
                  base_branch: "main",
                  latest_progress_at: ~U[2026-05-05 00:00:00Z],
                  updated_at: ~U[2026-05-04 00:00:00Z],
                  active_blocker_count: 0,
                  plan: %{total_count: 1, completed_count: 1, open_count: 0},
                  metadata: %{
                    review_suite_result: %{
                      lane: "review_t1",
                      verdict: "red"
                    },
                    review_package: %{
                      reviews: [
                        %{lane: "review_t1", verdict: "red"},
                        %{lane: "review_t2", verdict: "green"}
                      ]
                    }
                  },
                  active_agent_run: nil
                },
                %{
                  id: "SYMPP-P5-015",
                  kind: "dashboard",
                  title: "Suite result overrides package same lane",
                  repo: "nextide/symphony-plus-plus",
                  base_branch: "main",
                  latest_progress_at: ~U[2026-05-05 00:00:00Z],
                  updated_at: ~U[2026-05-04 00:00:00Z],
                  active_blocker_count: 0,
                  plan: %{total_count: 1, completed_count: 1, open_count: 0},
                  metadata: %{
                    review_suite_result: %{
                      suite: "review_t4",
                      verdict: "red"
                    },
                    review_package: %{
                      reviews: [
                        %{lane: "review_t4", verdict: "green"}
                      ]
                    }
                  },
                  active_agent_run: nil
                }
              ]
            }
          ]
        }
      }
      |> SymppBoardLive.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ "Review-T2 failed"
    assert html =~ "Review-T3 pending"
    assert html =~ "Combined review metadata"
    assert "ReviewReview-T1 failed" in pipeline_step_texts_for_card(html, "Latest lower-lane package rerun")
    assert html =~ "Review-T1 failed"
    assert html =~ "Suite result overrides package same lane"
    assert html =~ "Review-T4 failed"
    refute html =~ "Review-T2</strong>"
    refute html =~ "Review-T3</strong>"
    refute html =~ "Review-T4</strong>"
  end

  test "runtime pill labels the selected run instead of aggregate stale count" do
    html =
      %{
        empty_filter: "all",
        filters: %{kind: "all", repo: "all", phase: "all"},
        board: %{
          error: nil,
          total_count: 1,
          visible_count: 1,
          column_count: 1,
          filter_options: %{kinds: [], repos: [], phases: []},
          columns: [
            %{
              status: "implementing",
              cards: [
                %{
                  id: "SYMPP-P5-017",
                  kind: "dashboard",
                  title: "Queued selected run",
                  repo: "nextide/symphony-plus-plus",
                  base_branch: "symphony-plus-plus/beta",
                  latest_progress_at: ~U[2026-05-05 00:00:00Z],
                  updated_at: ~U[2026-05-04 00:00:00Z],
                  active_blocker_count: 0,
                  plan: %{total_count: 1, completed_count: 1, open_count: 0},
                  metadata: %{},
                  runtime: %{stale_count: 1},
                  active_agent_run: %{runtime_state: "queued", stale: false}
                }
              ]
            }
          ]
        }
      }
      |> SymppBoardLive.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ "queued run"
    refute html =~ "stale run"
  end

  test "pipeline keeps implementation done for review status with active run" do
    html =
      %{
        empty_filter: "all",
        filters: %{kind: "all", repo: "all", phase: "all"},
        board: %{
          error: nil,
          total_count: 1,
          visible_count: 1,
          column_count: 1,
          filter_options: %{kinds: [], repos: [], phases: []},
          columns: [
            %{
              status: "reviewing",
              cards: [
                %{
                  id: "SYMPP-P5-018",
                  kind: "dashboard",
                  title: "Reviewing selected run",
                  repo: "nextide/symphony-plus-plus",
                  base_branch: "symphony-plus-plus/beta",
                  status: "reviewing",
                  latest_progress_at: ~U[2026-05-05 00:00:00Z],
                  updated_at: ~U[2026-05-04 00:00:00Z],
                  active_blocker_count: 0,
                  plan: %{total_count: 1, completed_count: 1, open_count: 0},
                  metadata: %{review_suite_result: %{lane: "review_t2", verdict: "pending"}},
                  active_agent_run: %{runtime_state: "queued", stale: false}
                }
              ]
            }
          ]
        }
      }
      |> SymppBoardLive.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    pipeline_steps = pipeline_step_texts(html)

    assert "Implementationdone" in pipeline_steps
    assert "ReviewReview-T2 pending" in pipeline_steps
    refute "Implementationqueued run" in pipeline_steps
    assert html =~ "queued run"
  end

  test "pipeline keeps implementation done for review status with blocker count" do
    html =
      %{
        empty_filter: "all",
        filters: %{kind: "all", repo: "all", phase: "all"},
        board: %{
          error: nil,
          total_count: 1,
          visible_count: 1,
          column_count: 1,
          filter_options: %{kinds: [], repos: [], phases: []},
          columns: [
            %{
              status: "reviewing",
              cards: [
                %{
                  id: "SYMPP-P5-019",
                  kind: "dashboard",
                  title: "Reviewing blocked package",
                  repo: "nextide/symphony-plus-plus",
                  base_branch: "symphony-plus-plus/beta",
                  status: "reviewing",
                  latest_progress_at: ~U[2026-05-05 00:00:00Z],
                  updated_at: ~U[2026-05-04 00:00:00Z],
                  active_blocker_count: 1,
                  plan: %{total_count: 1, completed_count: 1, open_count: 0},
                  metadata: %{review_suite_result: %{lane: "review_t2", verdict: "red"}},
                  active_agent_run: nil
                }
              ]
            }
          ]
        }
      }
      |> SymppBoardLive.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    pipeline_steps = pipeline_step_texts(html)

    assert "Implementationdone" in pipeline_steps
    assert "ReviewReview-T2 failed" in pipeline_steps
    refute "Implementationblocked" in pipeline_steps
  end

  test "pipeline marks standalone merged packages complete" do
    html =
      %{
        empty_filter: "all",
        filters: %{kind: "all", repo: "all", phase: "all"},
        board: %{
          error: nil,
          total_count: 1,
          visible_count: 1,
          column_count: 1,
          filter_options: %{kinds: [], repos: [], phases: []},
          columns: [
            %{
              status: "merged",
              cards: [
                %{
                  id: "SYMPP-P5-020",
                  kind: "quick_fix",
                  title: "Standalone merged package",
                  repo: "nextide/symphony-plus-plus",
                  base_branch: "main",
                  status: "merged",
                  latest_progress_at: ~U[2026-05-05 00:00:00Z],
                  updated_at: ~U[2026-05-04 00:00:00Z],
                  active_blocker_count: 0,
                  plan: %{total_count: 1, completed_count: 1, open_count: 0},
                  metadata: %{review_suite_result: %{lane: "review_t2", verdict: "green"}},
                  active_agent_run: nil
                }
              ]
            }
          ]
        }
      }
      |> SymppBoardLive.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    pipeline_steps = pipeline_step_texts(html)

    assert "Implementationdone" in pipeline_steps
    assert "ReviewReview-T2" in pipeline_steps
    assert "Mergemerged" in pipeline_steps
    refute "Mergenot ready" in pipeline_steps
  end

  defp pipeline_step_texts(html) do
    html
    |> Floki.parse_document!()
    |> pipeline_step_texts_from_node()
  end

  defp pipeline_step_texts_for_card(html, title) do
    card =
      html
      |> Floki.parse_document!()
      |> Floki.find("article")
      |> Enum.find(fn card -> card |> Floki.find(".sympp-card-title") |> Floki.text() |> String.contains?(title) end)

    assert card

    pipeline_step_texts_from_node(card)
  end

  defp pipeline_step_texts_from_node(node) do
    node
    |> Floki.find(".sympp-progress-step")
    |> Enum.map(fn step ->
      step
      |> Floki.text()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    end)
  end

  defp create_board_package(attrs) do
    attrs = Map.new(attrs)

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(
                 id: attrs.id,
                 kind: attrs.kind,
                 status: attrs.status,
                 title: attrs.title,
                 repo: attrs.repo,
                 base_branch: attrs.base_branch,
                 parent_id: Map.get(attrs, :parent_id),
                 phase_id: Map.get(attrs, :phase_id)
               )
             )

    append_package_state(work_package, attrs)
    work_package
  end

  defp insert_legacy_work_package(repo, attrs) do
    now = DateTime.utc_now(:microsecond)

    repo.query!(
      """
      INSERT INTO sympp_work_packages
        (id, kind, title, repo, base_branch, acceptance_criteria, status, inserted_at, updated_at)
      VALUES
        (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
      """,
      [
        attrs.id,
        attrs.kind,
        attrs.title,
        attrs.repo,
        attrs.base_branch,
        "[]",
        attrs.status,
        now,
        now
      ]
    )

    :ok
  end

  defp append_package_state(work_package, attrs) do
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _done_plan} =
             PlanningRepository.append_plan_node(Repo, %{
               work_package_id: work_package.id,
               title: "Implement board",
               status: "done",
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _open_plan} =
             PlanningRepository.append_plan_node(Repo, %{
               work_package_id: work_package.id,
               title: "Validate board",
               status: "pending",
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(Repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{
                 type: "branch",
                 source_tool: "attach_branch",
                 branch: "agent/#{work_package.id}",
                 head_sha: "abc123"
               },
               created_at: DateTime.add(timestamp, 3, :second)
             })

    append_pr(work_package, attrs[:pr_url], timestamp)
    append_blocker(work_package, Map.get(attrs, :blocker?, false), timestamp)
    append_review_package(work_package, timestamp)
    append_agent_run(work_package, Map.get(attrs, :blocker?, false))
  end

  test "requires a claimed read phase grant for the browser board" do
    work_package =
      create_board_package(%{
        id: "SYMPP-P5-015",
        kind: "dashboard",
        status: "implementing",
        title: "Protected board package",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    worker_secret = create_worker_grant_secret(Repo, work_package.id)

    assert get(build_conn(), "/sympp/board") |> response(401)

    conn = get(auth_conn(worker_secret), "/sympp/board")

    assert response(conn, 403) =~ "Board access"
    assert response(conn, 403) =~ "not allowed"
    refute conn |> get_resp_header("content-type") |> Enum.join("") =~ "application/json"

    conn = post(build_conn(), "/sympp/board/session", %{"work_key" => worker_secret})

    assert response(conn, 403) =~ "Board access"
    assert response(conn, 403) =~ "not allowed"
    refute conn |> get_resp_header("content-type") |> Enum.join("") =~ "application/json"
  end

  test "board login shell uses prefixed browser paths" do
    conn =
      build_conn(:get, "/sympp/board")
      |> Plug.Test.init_test_session(%{})
      |> Map.put(:script_name, ["app"])
      |> SymppDashboardApiController.authorize_board_browser([])

    html = response(conn, 401)

    refute html =~ "dashboard.css"
    assert html =~ ~s(action="/app/sympp/board/session")
  end

  test "root layout uses prefixed browser asset and socket paths" do
    conn =
      build_conn(:get, "/sympp/board")
      |> Map.put(:script_name, ["app"])

    html =
      render_component(&Layouts.root/1,
        conn: conn,
        inner_content: ""
      )

    refute html =~ "/app/vendor/phoenix_html/phoenix_html.js"
    refute html =~ "/app/vendor/phoenix/phoenix.js"
    refute html =~ "/app/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/app/dashboard.css"
    refute html =~ "/app/live"
    refute html =~ "window.LiveView.LiveSocket"
  end

  test "authorized board HTTP response includes package content before websocket connect" do
    create_board_package(%{
      id: "SYMPP-P5-028",
      kind: "dashboard",
      status: "implementing",
      title: "Static board package",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    secret = create_architect_grant_secret(Repo, "SYMPP-P5-028")
    conn = get(board_session_conn(secret), "/sympp/board")

    html = response(conn, 200)

    assert html =~ "Static board package"
    refute html =~ "0 packages"
  end

  test "browser board renders legacy null phase grants from their current anchor phase" do
    assert {:ok, phase} = PhaseRepository.create(Repo, %{id: "phase-live-legacy", title: "Live legacy"})

    anchor =
      create_board_package(%{
        id: "SYMPP-LIVE-LEGACY-ANCHOR",
        kind: "dashboard",
        status: "implementing",
        title: "Legacy anchor board package",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    sibling =
      create_board_package(%{
        id: "SYMPP-LIVE-LEGACY-SIBLING",
        kind: "dashboard",
        status: "planning",
        title: "Legacy sibling board package",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    assert {:ok, _anchor} = WorkPackageRepository.update(Repo, anchor.id, %{phase_id: phase.id})
    assert {:ok, _sibling} = WorkPackageRepository.update(Repo, sibling.id, %{phase_id: phase.id})

    secret = create_legacy_phase_grant_secret(Repo, anchor.id, "grant-live-legacy-anchor")
    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/board")

    assert html =~ "Legacy anchor board package"
    assert html =~ "Legacy sibling board package"
    refute html =~ "Board access expired"
  end

  test "browser board legacy null grant follows the anchor current explicit phase" do
    assert {:ok, old_phase} = PhaseRepository.create(Repo, %{id: "phase-live-legacy-old", title: "Old legacy"})
    assert {:ok, current_phase} = PhaseRepository.create(Repo, %{id: "phase-live-legacy-current", title: "Current legacy"})

    anchor =
      create_board_package(%{
        id: "SYMPP-LIVE-LEGACY-MOVED",
        kind: "dashboard",
        status: "implementing",
        title: "Moved legacy anchor",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    old_sibling =
      create_board_package(%{
        id: "SYMPP-LIVE-LEGACY-OLD-SIBLING",
        kind: "dashboard",
        status: "planning",
        title: "Old phase sibling",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    current_sibling =
      create_board_package(%{
        id: "SYMPP-LIVE-LEGACY-CURRENT-SIBLING",
        kind: "dashboard",
        status: "blocked",
        title: "Current phase sibling",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    assert {:ok, _anchor} = WorkPackageRepository.update(Repo, anchor.id, %{phase_id: old_phase.id})
    assert {:ok, _old_sibling} = WorkPackageRepository.update(Repo, old_sibling.id, %{phase_id: old_phase.id})
    assert {:ok, _current_sibling} = WorkPackageRepository.update(Repo, current_sibling.id, %{phase_id: current_phase.id})

    secret = create_legacy_phase_grant_secret(Repo, anchor.id, "grant-live-legacy-current")
    conn = board_session_conn(secret)

    assert {:ok, _moved_anchor} = WorkPackageRepository.update(Repo, anchor.id, %{phase_id: current_phase.id})

    {:ok, _view, html} = live(conn, "/sympp/board")

    assert html =~ "Moved legacy anchor"
    assert html =~ "Current phase sibling"
    refute html =~ "Old phase sibling"
    refute html =~ "Board access expired"
  end

  test "browser board denies legacy null phase grants with unphased anchors" do
    anchor =
      create_board_package(%{
        id: "SYMPP-LIVE-LEGACY-UNPHASED",
        kind: "dashboard",
        status: "implementing",
        title: "Unphased legacy anchor",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    secret = create_legacy_phase_grant_secret(Repo, anchor.id, "grant-live-legacy-unphased")
    conn = post(build_conn(), "/sympp/board/session", %{"work_key" => secret})

    assert response(conn, 403) =~ "Board access"
    assert response(conn, 403) =~ "not allowed"
  end

  test "browser board denies explicit phase grants after their anchor leaves the phase" do
    assert {:ok, other_phase} = PhaseRepository.create(Repo, %{id: "phase-live-explicit-other", title: "Other explicit"})

    anchor =
      create_board_package(%{
        id: "SYMPP-LIVE-EXPLICIT-ANCHOR",
        kind: "dashboard",
        status: "implementing",
        title: "Explicit anchor board package",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    secret = create_architect_grant_secret(Repo, anchor.id)
    conn = board_session_conn(secret)

    assert {:ok, _moved_anchor} = WorkPackageRepository.update(Repo, anchor.id, %{phase_id: other_phase.id})

    conn = get(conn, "/sympp/board")

    assert response(conn, 403) =~ "Board access"
    refute response(conn, 403) =~ "Explicit anchor board package"
  end

  test "browser board filters scoped phase grants to frozen repo and base branch" do
    anchor =
      create_board_package(%{
        id: "SYMPP-LIVE-SCOPED-ANCHOR",
        kind: "dashboard",
        status: "implementing",
        title: "Scoped live anchor",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    create_board_package(%{
      id: "SYMPP-LIVE-SCOPED-SIBLING",
      kind: "dashboard",
      status: "planning",
      title: "Scoped live sibling",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    create_board_package(%{
      id: "SYMPP-LIVE-SCOPED-OTHER-REPO",
      kind: "dashboard",
      status: "planning",
      title: "Other repo live sibling",
      repo: "nextide/other-repo",
      base_branch: "symphony-plus-plus/beta"
    })

    create_board_package(%{
      id: "SYMPP-LIVE-SCOPED-OTHER-BASE",
      kind: "dashboard",
      status: "blocked",
      title: "Other base live sibling",
      repo: "nextide/symphony-plus-plus",
      base_branch: "main"
    })

    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/board")

    assert html =~ "Scoped live anchor"
    assert html =~ "Scoped live sibling"
    refute html =~ "Other repo live sibling"
    refute html =~ "Other base live sibling"
  end

  test "browser board session trims pasted work keys" do
    create_board_package(%{
      id: "SYMPP-P5-025",
      kind: "dashboard",
      status: "implementing",
      title: "Trimmed key package",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    secret = create_architect_grant_secret(Repo, "SYMPP-P5-025")
    conn = post(build_conn(), "/sympp/board/session", %{"work_key" => "  #{secret}\n"})

    assert redirected_to(conn) == "/sympp/board"
  end

  test "browser board session rejects unclaimed work keys without claiming them" do
    create_board_package(%{
      id: "SYMPP-P5-029",
      kind: "dashboard",
      status: "implementing",
      title: "Unclaimed key package",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    {secret, grant_id} = create_unclaimed_grant_secret(Repo, "SYMPP-P5-029", "architect", ["read:phase"])
    conn = post(build_conn(), "/sympp/board/session", %{"work_key" => secret})

    assert response(conn, 401) =~ "Board access"
    assert response(conn, 401) =~ "could not access"

    assert {:ok, grant} = AccessGrantRepository.get(Repo, grant_id)
    assert is_nil(grant.claimed_at)
    assert is_nil(grant.claimed_by)
  end

  test "failed board login clears an existing board session" do
    create_board_package(%{
      id: "SYMPP-P5-026",
      kind: "dashboard",
      status: "implementing",
      title: "Previous session package",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    secret = create_architect_grant_secret(Repo, "SYMPP-P5-026")
    conn = board_session_conn(secret)

    {:ok, _view, html} = live(conn, "/sympp/board")
    assert html =~ "Previous session package"

    conn = post(conn, "/sympp/board/session", %{"work_key" => "not-a-valid-work-key"})

    assert response(conn, 401) =~ "Board access"

    conn = get(recycle(conn), "/sympp/board")

    assert response(conn, 401) =~ "Board access"
    refute response(conn, 401) =~ "Previous session package"
  end

  test "browser session login preserves board access for filter navigation" do
    create_board_package(%{
      id: "SYMPP-P5-017",
      kind: "dashboard",
      status: "implementing",
      title: "Session board package",
      repo: "nextide/symphony-plus-plus",
      base_branch: "symphony-plus-plus/beta"
    })

    secret = create_architect_grant_secret(Repo, "SYMPP-P5-017")
    conn = board_session_conn(secret)

    {:ok, _view, html} = live(conn, "/sympp/board?kind=dashboard")

    assert html =~ "Session board package"
    refute html =~ secret
  end

  test "revoked board session grants are rejected before rendering the board" do
    work_package =
      create_board_package(%{
        id: "SYMPP-P5-018",
        kind: "dashboard",
        status: "implementing",
        title: "Revoked board package",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    secret = create_architect_grant_secret(Repo, work_package.id)
    conn = board_session_conn(secret)
    secret_hash = WorkKey.secret_hash(secret)
    assert {:ok, grant} = AccessGrantRepository.find_by_secret_hash(Repo, secret_hash)
    assert {:ok, _revoked} = AccessGrantRepository.revoke(Repo, grant.id, DateTime.utc_now(:microsecond))

    conn = get(conn, "/sympp/board")

    assert response(conn, 401) =~ "Board access"
    refute response(conn, 401) =~ "Revoked board package"
    refute response(conn, 401) =~ secret
  end

  test "live board navigation revalidates a revoked session grant before reading" do
    work_package =
      create_board_package(%{
        id: "SYMPP-P5-019",
        kind: "dashboard",
        status: "implementing",
        title: "Socket revalidation package",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    secret = create_architect_grant_secret(Repo, work_package.id)
    conn = board_session_conn(secret)
    {:ok, view, html} = live(conn, "/sympp/board")

    assert html =~ "Socket revalidation package"

    secret_hash = WorkKey.secret_hash(secret)
    assert {:ok, grant} = AccessGrantRepository.find_by_secret_hash(Repo, secret_hash)
    assert {:ok, _revoked} = AccessGrantRepository.revoke(Repo, grant.id, DateTime.utc_now(:microsecond))

    html = render_patch(view, "/sympp/board?kind=dashboard")

    assert html =~ "Board access expired"
    refute html =~ "Socket revalidation package"
  end

  test "live board navigation revalidates an explicit phase grant anchor before reading" do
    assert {:ok, other_phase} = PhaseRepository.create(Repo, %{id: "phase-live-socket-explicit-other", title: "Socket other"})

    work_package =
      create_board_package(%{
        id: "SYMPP-P5-030",
        kind: "dashboard",
        status: "implementing",
        title: "Socket explicit anchor package",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta"
      })

    secret = create_architect_grant_secret(Repo, work_package.id)
    conn = board_session_conn(secret)
    {:ok, view, html} = live(conn, "/sympp/board")

    assert html =~ "Socket explicit anchor package"

    assert {:ok, _moved_anchor} = WorkPackageRepository.update(Repo, work_package.id, %{phase_id: other_phase.id})

    html = render_patch(view, "/sympp/board?kind=dashboard")

    assert html =~ "Board access expired"
    refute html =~ "Socket explicit anchor package"
  end

  defp append_pr(_work_package, nil, _timestamp), do: :ok

  defp append_pr(work_package, pr_url, timestamp) do
    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(Repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: pr_url, head_sha: "abc123"},
               created_at: DateTime.add(timestamp, 4, :second)
             })

    :ok
  end

  defp append_blocker(_work_package, false, _timestamp), do: :ok

  defp append_blocker(work_package, true, timestamp) do
    assert {:ok, _blocker} =
             PlanningRepository.append_progress_event(Repo, %{
               work_package_id: work_package.id,
               summary: "Blocked on validation",
               status: "blocked",
               payload: %{
                 type: "blocker",
                 source_tool: "report_blocker",
                 blocker_id: "#{work_package.id}-blocker",
                 active: true
               },
               created_at: DateTime.add(timestamp, 5, :second)
             })

    :ok
  end

  defp append_review_package(work_package, timestamp) do
    assert {:ok, _review} =
             PlanningRepository.append_progress_event(Repo, %{
               work_package_id: work_package.id,
               summary: "Review package attached",
               status: "review_package_submitted",
               payload: %{type: "review_package", source_tool: "submit_review_package", head_sha: "abc123"},
               created_at: DateTime.add(timestamp, 6, :second)
             })

    :ok
  end

  defp append_agent_run(_work_package, false), do: :ok

  defp append_agent_run(work_package, true) do
    assert {:ok, _run} =
             AgentRunRepository.start_run(Repo, %{
               work_package_id: work_package.id,
               access_grant_id: nil,
               actor_id: "worker-1",
               status: "running",
               attempt: 1,
               worker_host: "local",
               worker_task_handle: "task-1",
               workspace_path: "C:/tmp/workspace",
               session_id: "session-1"
             })

    :ok
  end

  defp create_architect_grant_secret(repo, work_package_id) do
    create_claimed_grant_secret(repo, work_package_id, "architect", ["read:phase"], "architect-1")
  end

  defp create_worker_grant_secret(repo, work_package_id) do
    create_claimed_grant_secret(repo, work_package_id, "worker", ["read:package"], "worker-1")
  end

  defp create_unclaimed_grant_secret(repo, work_package_id, role, capabilities) do
    phase_id = if role == "architect" and "read:phase" in capabilities, do: ensure_dashboard_phase(repo)
    if phase_id, do: assign_existing_packages_to_phase(repo, phase_id)
    work_key = WorkKey.generate()

    attrs = %{
      work_package_id: work_package_id,
      display_key: work_key.display_key,
      secret_hash: WorkKey.secret_hash(work_key.secret),
      grant_role: role,
      capabilities: capabilities,
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
    }

    attrs = if phase_id, do: Map.put(attrs, :phase_id, phase_id), else: attrs

    assert {:ok, grant} = AccessGrantRepository.create(repo, attrs)

    {work_key.secret, grant.id}
  end

  defp create_claimed_grant_secret(repo, work_package_id, role, capabilities, claimed_by) do
    phase_id = if role == "architect" and "read:phase" in capabilities, do: ensure_dashboard_phase(repo)
    if phase_id, do: assign_existing_packages_to_phase(repo, phase_id)
    work_key = WorkKey.generate()

    attrs = %{
      work_package_id: work_package_id,
      display_key: work_key.display_key,
      secret_hash: WorkKey.secret_hash(work_key.secret),
      grant_role: role,
      capabilities: capabilities,
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
    }

    attrs = if phase_id, do: Map.put(attrs, :phase_id, phase_id), else: attrs

    assert {:ok, grant} = AccessGrantRepository.create(repo, attrs)

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: claimed_by}, DateTime.utc_now(:microsecond))

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
        assert {:ok, phase} = PhaseRepository.create(repo, %{id: @dashboard_phase_id, title: "Dashboard live test phase"})
        phase.id
    end
  end

  defp assign_existing_packages_to_phase(repo, phase_id) do
    assert {:ok, packages} = WorkPackageRepository.list(repo)

    Enum.each(packages, fn package ->
      assert {:ok, _updated} = WorkPackageRepository.update(repo, package.id, %{phase_id: phase_id})
    end)
  end

  defp auth_conn(secret) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{secret}")
  end

  defp board_session_conn(secret) do
    conn = post(build_conn(), "/sympp/board/session", %{"work_key" => secret})
    assert redirected_to(conn) == "/sympp/board"
    recycle(conn)
  end

  defp path_segment(value) do
    case value do
      "." -> "%2E"
      ".." -> "%2E%2E"
      value -> URI.encode(value, &URI.char_unreserved?/1)
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

  defp with_transient_repo(database_path, fun) do
    {:ok, pid} = Repo.start_link(Repo.child_options(database: database_path, name: nil))
    Process.unlink(pid)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      assert :ok = WorkPackageRepository.migrate(Repo)
      fun.()
    after
      Repo.put_dynamic_repo(original_repo)
      stop_transient_repo(pid)
    end
  end

  defp seed_legacy_repo(database_path, fun) do
    {:ok, pid} = Repo.start_link(Repo.child_options(database: database_path, name: nil))
    Process.unlink(pid)
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      Ecto.Migrator.run(Repo, WorkPackageRepository.migrations_path(), :up,
        dynamic_repo: pid,
        log: false,
        all: true
      )

      fun.()
    after
      Repo.put_dynamic_repo(original_repo)
      stop_transient_repo(pid)
    end
  end

  defp stop_transient_repo(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp stop_named_repo(repo) do
    cond do
      function_exported?(repo, :stop, 1) ->
        repo.stop(1_000)

      Process.whereis(repo) != nil ->
        repo |> Process.whereis() |> stop_transient_repo()

      true ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp restore_database_env(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_database)
  defp restore_database_env(database), do: Application.put_env(:symphony_elixir, :sympp_repo_database, database)

  defp restore_default_database_root_env(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_default_database_root)

  defp restore_default_database_root_env(database_root) do
    Application.put_env(:symphony_elixir, :sympp_repo_default_database_root, database_root)
  end

  defp restore_workflow_path(nil), do: Workflow.clear_workflow_file_path()
  defp restore_workflow_path(path), do: Workflow.set_workflow_file_path(path)

  defp restore_custom_repo_env(nil), do: Application.delete_env(:symphony_elixir, CustomBoardRepo)
  defp restore_custom_repo_env(config), do: Application.put_env(:symphony_elixir, CustomBoardRepo, config)

  defp restore_board_live_migrated_databases(nil) do
    Application.delete_env(:symphony_elixir, :sympp_board_live_migrated_databases)
  end

  defp restore_board_live_migrated_databases(databases) do
    Application.put_env(:symphony_elixir, :sympp_board_live_migrated_databases, databases)
  end

  defp seed_custom_repo(database_path, fun) do
    {:ok, pid} = CustomBoardRepo.start_link(database: database_path, name: CustomBoardRepo)
    Process.unlink(pid)

    try do
      assert :ok = WorkPackageRepository.migrate(CustomBoardRepo)
      fun.()
    after
      stop_transient_repo(pid)
    end
  end

  defp seed_running_legacy_custom_repo(database_path, fun) do
    {:ok, pid} = CustomBoardRepo.start_link(database: database_path, name: CustomBoardRepo)
    Process.unlink(pid)

    Ecto.Migrator.run(CustomBoardRepo, WorkPackageRepository.migrations_path(), :up,
      log: false,
      all: true
    )

    fun.()
  end

  defp with_endpoint_repo(repo, fun) do
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
end
