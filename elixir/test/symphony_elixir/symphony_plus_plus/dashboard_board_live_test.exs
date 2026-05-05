defmodule SymphonyElixir.SymphonyPlusPlus.DashboardBoardLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Phoenix.HTML.Safe
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.SymppBoardLive

  @endpoint SymphonyElixirWeb.Endpoint

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
    assert html =~ "Implementing"
    assert html =~ "Ready for worker"
    assert html =~ "SYMPP-P5-002"
    assert html =~ "Dashboard board UI"
    assert html =~ "dashboard"
    assert html =~ "nextide/symphony-plus-plus / symphony-plus-plus/beta"
    assert html =~ "Blockers"
    assert html =~ ~s(href="https://github.com/example/symphony-plus-plus/pull/22")
    assert html =~ "Plan 1/2"
    assert html =~ "Review attached"
    assert html =~ "active run"
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
    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/board")

    assert html =~ "Running repo package"
    refute html =~ "No Symphony++ work package ledger was found."
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
                  latest_progress_at: ~U[2026-05-05 00:00:00Z],
                  updated_at: ~U[2026-05-04 00:00:00Z],
                  active_blocker_count: 0,
                  plan: %{total_count: 1, completed_count: 1, open_count: 0},
                  metadata: %{
                    "pr" => %{"url" => "https://github.com/example/symphony-plus-plus/pull/26"},
                    "review_package" => %{"head_sha" => "abc123"}
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

    assert html =~ "String metadata package"
    assert html =~ "Review attached"
    assert html =~ ~s(href="https://github.com/example/symphony-plus-plus/pull/26")
    refute html =~ "n/a"
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
                 base_branch: attrs.base_branch
               )
             )

    append_package_state(work_package, attrs)
    work_package
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
    assert get(auth_conn(worker_secret), "/sympp/board") |> response(403)
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

  defp create_claimed_grant_secret(repo, work_package_id, role, capabilities, claimed_by) do
    work_key = WorkKey.generate()

    assert {:ok, grant} =
             AccessGrantRepository.create(repo, %{
               work_package_id: work_package_id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: role,
               capabilities: capabilities,
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: claimed_by}, DateTime.utc_now(:microsecond))

    assert grant.display_key == work_key.display_key
    work_key.secret
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

  defp restore_custom_repo_env(nil), do: Application.delete_env(:symphony_elixir, CustomBoardRepo)
  defp restore_custom_repo_env(config), do: Application.put_env(:symphony_elixir, CustomBoardRepo, config)

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
