defmodule SymphonyElixir.SymphonyPlusPlus.DashboardDetailLiveTest do
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
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.SymppDetailLive

  @endpoint SymphonyElixirWeb.Endpoint

  setup_all do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = WorkPackageRepository.migrate(Repo)
    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)
    start_test_endpoint()

    on_exit(fn ->
      restore_database_env(original_database)
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

  test "renders package detail, virtual plan, findings, timeline, artifacts, grants, and agent runs" do
    %{work_package: work_package, architect_secret: secret} = create_detail_package()

    {:ok, _view, html} = live(auth_conn(secret), "/sympp/work-packages/#{work_package.id}")

    assert html =~ "Detail UI package"
    assert html =~ ~s(id="sympp-package-id")
    assert html =~ ~s(value="SYMPP-P5-003")
    assert html =~ "Product context"
    assert html =~ "Engineering scope"
    assert html =~ "Render detail"
    assert html =~ "Acceptance"
    assert html =~ "Virtual Task Plan"
    assert html =~ "Implement detail"
    assert html =~ "Validate detail"
    assert html =~ "Findings"
    assert html =~ "Finding one"
    assert html =~ "Artifacts"
    assert html =~ "Implementation note"
    assert html =~ "Grants"
    assert html =~ "architect"
    assert html =~ "Agent Runs"
    assert html =~ "task-1"
    assert html =~ ~s(href="https://github.com/example/symphony-plus-plus/pull/33")
    assert html =~ "Open PR"
  end

  test "renders empty states for missing detail collections" do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(id: "SYMPP-P5-EMPTY", kind: "dashboard", title: "Empty detail package")
             )

    secret = create_architect_grant_secret(Repo, work_package.id)

    {:ok, _view, html} = live(auth_conn(secret), "/sympp/work-packages/#{work_package.id}")

    assert html =~ "Empty detail package"
    assert html =~ "No virtual plan nodes recorded."
    assert html =~ "No findings recorded."
    assert html =~ "No progress or finding timeline events recorded."
    assert html =~ "No artifacts recorded."
    assert html =~ "No agent runs recorded."
  end

  test "timeline is chronological across progress and findings" do
    %{work_package: work_package, architect_secret: secret} = create_detail_package()

    {:ok, _view, html} = live(auth_conn(secret), "/sympp/work-packages/#{work_package.id}")

    timeline_html = timeline_section(html)

    assert before?(timeline_html, "Backfilled older progress", "Branch attached")
    assert before?(timeline_html, "Branch attached", "PR attached")
    assert before?(timeline_html, "PR attached", "Finding one")
    assert before?(timeline_html, "Finding one", "Review package attached")
  end

  test "redacts sensitive fields and does not render mutating controls" do
    %{work_package: work_package, architect_secret: secret} =
      create_detail_package(title: "Leaked raw-secret-value", secret_finding?: true)

    {:ok, _view, html} = live(auth_conn(secret), "/sympp/work-packages/#{work_package.id}")

    assert html =~ "[REDACTED]"
    refute html =~ "raw-secret-value"
    refute html =~ "Bearer "
    refute html =~ ~r/<button[^>]*>\s*Merge\s*<\/button>/
    refute html =~ ~r/<button[^>]*>\s*Revoke\s*<\/button>/
    refute html =~ ~r/<button[^>]*>\s*Claim\s*<\/button>/
  end

  test "worker-scoped browser viewer can see own package but not sibling package" do
    %{work_package: work_package, worker_secret: worker_secret} = create_detail_package()

    assert {:ok, sibling} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(id: "SYMPP-P5-SIBLING", kind: "dashboard", title: "Sibling detail package")
             )

    {:ok, _view, own_html} = live(auth_conn(worker_secret), "/sympp/work-packages/#{work_package.id}")

    assert own_html =~ "Detail UI package"

    conn = get(auth_conn(worker_secret), "/sympp/work-packages/#{sibling.id}")

    assert response(conn, 403) =~ "Board access"
    refute response(conn, 403) =~ "Sibling detail package"
  end

  test "valid package bearer auth overrides a stale different-package browser session" do
    %{work_package: first, worker_secret: first_secret} = create_detail_package(id: "SYMPP-P5-FIRST", title: "First package")
    %{work_package: second, worker_secret: second_secret} = create_detail_package(id: "SYMPP-P5-SECOND", title: "Second package")

    first_conn = get(auth_conn(first_secret), "/sympp/work-packages/#{first.id}")

    assert response(first_conn, 200) =~ "First package"

    second_conn =
      first_conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{second_secret}")
      |> get("/sympp/work-packages/#{second.id}")

    assert response(second_conn, 200) =~ "Second package"
    refute response(second_conn, 200) =~ "Package unavailable"
  end

  test "renders DateTime timestamps and string-keyed payloads in render helpers" do
    html =
      %{
        work_package_id: "SYMPP-P5-HELPER",
        error: nil,
        detail: %{
          work_package: %{
            id: "SYMPP-P5-HELPER",
            title: "Helper detail",
            kind: "dashboard",
            status: "planning",
            repo: "nextide/symphony-plus-plus",
            base_branch: "symphony-plus-plus/beta",
            product_description: "Product",
            engineering_scope: "Engineering",
            allowed_file_globs: [],
            acceptance_criteria: []
          },
          summary: %{
            artifact_count: 0,
            finding_count: 0,
            progress_event_count: 0,
            active_blocker_count: 0,
            grant_count: 0,
            active_grant_count: 0,
            agent_run_count: 0,
            active_agent_run_count: 0,
            latest_progress_at: ~U[2026-05-05 00:00:00Z],
            plan: %{total_count: 1, completed_count: 1, open_count: 0}
          },
          metadata: %{
            "branch" => %{"branch" => "agent/SYMPP-P5-HELPER", "head_sha" => "abcdef123456"},
            "pr" => %{"url" => "https://github.com/example/repo/pull/55"}
          },
          plan: [],
          findings: [],
          artifacts: [],
          grants: [],
          agent_runs: []
        },
        timeline: %{events: []}
      }
      |> SymppDetailLive.render()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()

    assert html =~ "Helper detail"
    assert html =~ "1/1"
    assert html =~ "agent/SYMPP-P5-HELPER @ abcdef1"
    assert html =~ ~s(href="https://github.com/example/repo/pull/55")
  end

  defp create_detail_package(opts \\ []) do
    id = Keyword.get(opts, :id, "SYMPP-P5-003")
    title = Keyword.get(opts, :title, "Detail UI package")

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(
                 id: id,
                 kind: "dashboard",
                 status: "implementing",
                 title: title,
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 branch_pattern: "agent/#{id}",
                 product_description: "Product context",
                 engineering_scope: "Engineering scope",
                 allowed_file_globs: ["elixir/lib/symphony_elixir_web/**"],
                 acceptance_criteria: ["Render detail", "Redact secrets"]
               )
             )

    worker_secret = create_worker_grant_secret(Repo, work_package.id)
    architect_secret = create_architect_grant_secret(Repo, work_package.id)
    append_detail_state(work_package, Keyword.get(opts, :secret_finding?, false))

    %{work_package: work_package, worker_secret: worker_secret, architect_secret: architect_secret}
  end

  defp append_detail_state(work_package, secret_finding?) do
    timestamp = ~U[2026-05-05 00:00:00Z]

    assert {:ok, _old_progress} =
             PlanningRepository.append_progress_event(Repo, %{
               work_package_id: work_package.id,
               summary: "Backfilled older progress",
               status: "planning",
               created_at: DateTime.add(timestamp, -5, :second),
               payload: %{type: "status", source_tool: "test"}
             })

    assert {:ok, _done_plan} =
             PlanningRepository.append_plan_node(Repo, %{
               work_package_id: work_package.id,
               title: "Implement detail",
               body: "Build page",
               status: "done",
               created_at: DateTime.add(timestamp, 1, :second)
             })

    assert {:ok, _open_plan} =
             PlanningRepository.append_plan_node(Repo, %{
               work_package_id: work_package.id,
               title: "Validate detail",
               body: "Run tests",
               status: "pending",
               created_at: DateTime.add(timestamp, 2, :second)
             })

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(Repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               created_at: DateTime.add(timestamp, 3, :second),
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: "abc123456"}
             })

    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(Repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               created_at: DateTime.add(timestamp, 4, :second),
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/example/symphony-plus-plus/pull/33",
                 head_sha: "abc123456"
               }
             })

    append_finding(work_package, secret_finding?, timestamp)

    assert {:ok, _review} =
             PlanningRepository.append_progress_event(Repo, %{
               work_package_id: work_package.id,
               summary: "Review package attached",
               status: "review_package_submitted",
               created_at: DateTime.add(timestamp, 6, :second),
               payload: %{
                 type: "review_package",
                 source_tool: "submit_review_package",
                 head_sha: "abc123456",
                 url: "https://example.test/review?sig=raw-secret-value",
                 secret_hash: "raw-secret-value"
               }
             })

    assert {:ok, _artifact} =
             PlanningService.append_artifact(Repo, %{
               work_package_id: work_package.id,
               path: "implementation-note.md",
               title: "Implementation note",
               kind: "note",
               uri: "https://example.test/artifact.md",
               created_at: DateTime.add(timestamp, 7, :second)
             })

    assert {:ok, _run} =
             AgentRunRepository.start_run(Repo, %{
               work_package_id: work_package.id,
               status: "running",
               attempt: 1,
               worker_host: "local",
               worker_task_handle: "task-1",
               workspace_path: "C:/tmp/workspace",
               session_id: "session-1",
               codex_total_tokens: 42,
               turn_count: 3
             })
  end

  defp append_finding(work_package, true, timestamp) do
    assert {:ok, _finding} =
             PlanningRepository.append_finding(Repo, %{
               work_package_id: work_package.id,
               title: "Finding raw-secret-value",
               body: "Bearer raw-secret-value",
               severity: "high",
               created_at: DateTime.add(timestamp, 5, :second)
             })
  end

  defp append_finding(work_package, false, timestamp) do
    assert {:ok, _finding} =
             PlanningRepository.append_finding(Repo, %{
               work_package_id: work_package.id,
               title: "Finding one",
               body: "Needs attention",
               severity: "medium",
               created_at: DateTime.add(timestamp, 5, :second)
             })
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

  defp before?(html, first, second) do
    :binary.match(html, first) != :nomatch and :binary.match(html, second) != :nomatch and
      elem(:binary.match(html, first), 0) < elem(:binary.match(html, second), 0)
  end

  defp timeline_section(html) do
    [_before, timeline] = String.split(html, "<h2>Timeline</h2>", parts: 2)
    timeline
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), sympp_repo: Repo)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp restore_database_env(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_database)
  defp restore_database_env(database), do: Application.put_env(:symphony_elixir, :sympp_repo_database, database)
end
