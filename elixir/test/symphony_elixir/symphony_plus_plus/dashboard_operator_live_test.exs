defmodule SymphonyElixir.SymphonyPlusPlus.DashboardOperatorLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
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
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

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
    Repo.delete_all(PlannedSlice)
    Repo.delete_all(DecisionLogEntry)
    Repo.delete_all(ClarificationQuestion)
    Repo.delete_all(WorkRequest)
    Repo.delete_all(AgentRun)
    Repo.delete_all(Artifact)
    Repo.delete_all(ProgressEvent)
    Repo.delete_all(Finding)
    Repo.delete_all(PlanNode)
    Repo.delete_all(AccessGrant)
    Repo.delete_all(WorkPackage)
    Repo.delete_all(Phase)
    disable_operator_mode()
    on_exit(fn -> disable_operator_mode() end)
    :ok
  end

  test "disabled local operator mode still requires a board work key" do
    create_package!(id: "SYMPP-V2-UX-DISABLED", title: "Hidden without operator mode")

    conn = get(build_conn(), "/sympp/board")

    assert response(conn, 401) =~ "Board access"
    refute response(conn, 401) =~ "Hidden without operator mode"
  end

  test "local operator opens the cockpit without a board work key" do
    enable_operator_mode()

    package =
      create_package!(
        id: "SYMPP-V2-UX-001",
        title: "Local operator cockpit",
        status: "implementing",
        blocker?: true,
        pr_url: "https://github.com/example/symphony-plus-plus/pull/101"
      )

    create_work_request!(
      id: "WR-OPERATOR-GUIDANCE",
      title: "Need product answer",
      status: "human_info_needed"
    )

    assert {:ok, _question} =
             WorkRequestRepository.ask_question(Repo, "WR-OPERATOR-GUIDANCE", %{
               category: "product",
               question: "Which workflow should lead?",
               why_needed: "The operator needs to choose the slice order."
             })

    {:ok, _view, html} = live(local_conn(), "/sympp/board")

    assert html =~ "Local operator cockpit"
    assert html =~ ~s(href="board?auth=work_key")
    assert html =~ "Product Guidance Needed"
    assert html =~ "Need product answer"
    assert html =~ "Blockers"
    assert html =~ "Local operator cockpit"
    assert html =~ package.id
    assert html =~ ~s(href="work-packages/#{package.id}")
    refute html =~ "Board access"
    refute html =~ ~s(name="work_key")
  end

  test "local operator keeps work-key login surfaces reachable" do
    enable_operator_mode()
    package = create_package!(id: "SYMPP-V2-UX-WORK-KEY", title: "Work key reachable package")

    board_conn = get(local_conn(), "/sympp/board?auth=work_key")

    assert response(board_conn, 401) =~ "Board access"
    assert response(board_conn, 401) =~ "work_key"
    refute Plug.Conn.get_session(board_conn, "sympp_local_operator")

    cached_board_conn =
      local_conn()
      |> Plug.Test.init_test_session(%{
        "sympp_board_grant_id" => create_architect_grant!(package.id).id,
        "sympp_package_grant_ids" => %{package.id => create_package_grant!(package.id).id}
      })
      |> get("/sympp/board?auth=work_key")

    assert response(cached_board_conn, 401) =~ "Board access"
    refute Plug.Conn.get_session(cached_board_conn, "sympp_board_grant_id")
    refute Plug.Conn.get_session(cached_board_conn, "sympp_package_grant_ids")

    package_conn =
      local_conn()
      |> Plug.Test.init_test_session(%{"sympp_local_operator" => true})
      |> get("/sympp/work-packages/#{package.id}?auth=work_key")

    assert response(package_conn, 401) =~ "Package access"
    assert response(package_conn, 401) =~ "work_key"
    refute response(package_conn, 401) =~ "Work key reachable package"
  end

  test "local operator drills into package detail with redaction and no package key" do
    enable_operator_mode()

    package =
      create_package!(
        id: "SYMPP-V2-UX-DETAIL",
        title: "Package raw-secret-value",
        product_description: "Product context with Bearer raw-secret-value",
        blocker?: true
      )

    {:ok, _finding} =
      PlanningRepository.append_finding(Repo, %{
        work_package_id: package.id,
        title: "Finding raw-secret-value",
        body: "Bearer raw-secret-value",
        severity: "high"
      })

    {:ok, _view, html} = live(local_conn(), "/sympp/work-packages/#{package.id}")

    assert html =~ "[REDACTED]"
    assert html =~ "Virtual Task Plan"
    assert html =~ "Findings"
    assert html =~ ~s(class="sympp-back-link")
    refute html =~ "raw-secret-value"
    refute html =~ "Package access"
    refute html =~ ~s(name="work_key")
  end

  test "local operator drills into WorkRequest detail without scoped board grant" do
    enable_operator_mode()

    request =
      create_work_request!(
        id: "WR-OPERATOR-DETAIL",
        title: "Operator WorkRequest detail",
        status: "human_info_needed",
        human_description: "Inspect the full request."
      )

    assert {:ok, _question} =
             WorkRequestRepository.ask_question(Repo, request.id, %{
               question: "Question needing operator guidance",
               category: "product",
               why_needed: "Operator needs to understand the pending product answer.",
               asked_by: "operator"
             })

    assert {:ok, _slice} =
             WorkRequestRepository.add_planned_slice(Repo, request.id, %{
               title: "First operator slice",
               goal: "Expose the cockpit.",
               work_package_kind: "dashboard",
               target_base_branch: "main",
               branch_pattern: "agent/SYMPP-V2-UX-001/local-operator-cockpit",
               acceptance_criteria: ["Operator can inspect the slice."],
               validation_steps: ["mix test"],
               review_lanes: ["review_t1"],
               stop_conditions: ["Stop before dispatch."]
             })

    {:ok, _view, html} = live(local_conn(), "/sympp/work-requests/#{request.id}")

    assert html =~ "Operator WorkRequest detail"
    assert html =~ "Question needing operator guidance"
    assert html =~ "Planned slices"
    assert html =~ "First operator slice"
    assert html =~ ~s(href="../board?auth=work_key")
    refute html =~ "Board access"
    refute html =~ ~s(name="work_key")
    refute html =~ "Answer</button>"
    refute html =~ "Close unanswered"
    refute html =~ "Approve</button>"
    refute html =~ "Add planned slice"
  end

  test "local operator mode clears stale scoped grants before rendering WorkRequest actions" do
    enable_operator_mode()

    package = create_package!(id: "SYMPP-V2-UX-STALE", title: "Stale grant package")
    grant = create_architect_grant!(package.id)

    request =
      create_work_request!(
        id: "WR-OPERATOR-STALE-GRANT",
        title: "Stale grant WorkRequest",
        status: "human_info_needed"
      )

    assert {:ok, _question} =
             WorkRequestRepository.ask_question(Repo, request.id, %{
               question: "Should stale grants unlock edits?",
               category: "product",
               why_needed: "Operator mode must stay read-only even after scoped sessions.",
               asked_by: "operator"
             })

    conn =
      local_conn()
      |> Plug.Test.init_test_session(%{"sympp_local_operator" => true, "sympp_board_grant_id" => grant.id})
      |> get("/sympp/board")

    assert Plug.Conn.get_session(conn, "sympp_local_operator") == true
    refute Plug.Conn.get_session(conn, "sympp_board_grant_id")

    {:ok, _view, html} = live(conn, "/sympp/work-requests/#{request.id}")

    assert html =~ "Stale grant WorkRequest"
    refute html =~ "Answer</button>"
    refute html =~ "Close unanswered"

    remote_conn =
      build_conn()
      |> Map.put(:remote_ip, {10, 0, 0, 8})
      |> Plug.Test.init_test_session(%{"sympp_local_operator" => true, "sympp_board_grant_id" => grant.id})
      |> get("/sympp/board")

    assert response(remote_conn, 200) =~ "Work package board"
    refute response(remote_conn, 200) =~ "Local operator cockpit"
    refute Plug.Conn.get_session(remote_conn, "sympp_local_operator")
    assert Plug.Conn.get_session(remote_conn, "sympp_board_grant_id") == grant.id
  end

  test "local operator priority watchlists follow active board filters" do
    enable_operator_mode()

    create_package!(id: "SYMPP-V2-UX-VISIBLE", title: "Visible repo package", repo: "nextide/symphony-plus-plus")
    create_package!(id: "SYMPP-V2-UX-HIDDEN", title: "Hidden repo blocker", repo: "nextide/other", blocker?: true)

    create_work_request!(
      id: "WR-OPERATOR-VISIBLE",
      title: "Visible guidance request",
      repo: "nextide/symphony-plus-plus",
      status: "human_info_needed"
    )

    create_work_request!(
      id: "WR-OPERATOR-HIDDEN",
      title: "Hidden guidance request",
      repo: "nextide/other",
      status: "human_info_needed"
    )

    {:ok, _view, html} = live(local_conn(), "/sympp/board?repo=nextide/symphony-plus-plus")

    assert html =~ "Visible repo package"
    assert html =~ "Visible guidance request"
    refute html =~ "Hidden repo blocker"
    refute html =~ "Hidden guidance request"
  end

  test "local operator guidance watchlist follows package kind filters by work stream" do
    enable_operator_mode()

    create_package!(
      id: "SYMPP-V2-UX-KIND-VISIBLE",
      title: "Visible dashboard package",
      kind: "dashboard",
      repo: "nextide/symphony-plus-plus"
    )

    create_package!(
      id: "SYMPP-V2-UX-KIND-HIDDEN",
      title: "Hidden docs package",
      kind: "docs",
      repo: "nextide/docs"
    )

    create_work_request!(
      id: "WR-OPERATOR-KIND-VISIBLE",
      title: "Visible kind guidance",
      repo: "nextide/symphony-plus-plus",
      status: "human_info_needed"
    )

    create_work_request!(
      id: "WR-OPERATOR-KIND-HIDDEN",
      title: "Hidden kind guidance",
      repo: "nextide/docs",
      status: "human_info_needed"
    )

    {:ok, _view, html} = live(local_conn(), "/sympp/board?kind=dashboard")

    assert html =~ "Visible dashboard package"
    assert html =~ "Visible kind guidance"
    refute html =~ "Hidden docs package"
    refute html =~ "Hidden kind guidance"
  end

  test "local operator direct access rejects forwarded proxy requests without a work key" do
    enable_operator_mode()
    create_package!(id: "SYMPP-V2-UX-PROXY", title: "Proxy-hidden package")

    conn =
      local_conn()
      |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.24")
      |> get("/sympp/board")

    assert response(conn, 401) =~ "Board access"
    refute response(conn, 401) =~ "Proxy-hidden package"
    refute Plug.Conn.get_session(conn, "sympp_local_operator")

    trusted_proxy_conn =
      local_conn()
      |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.24")
      |> then(fn conn ->
        put_endpoint_config(sympp_local_operator: true, sympp_local_operator_trust_proxy: true)
        conn
      end)
      |> get("/sympp/board")

    assert response(trusted_proxy_conn, 401) =~ "Board access"
    refute Plug.Conn.get_session(trusted_proxy_conn, "sympp_local_operator")
  end

  test "local operator mode requires browser provenance and accepts IPv6 loopback hosts" do
    enable_operator_mode()
    create_package!(id: "SYMPP-V2-UX-FETCH-SITE", title: "Fetch metadata package")

    headerless_conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> Map.put(:host, "127.0.0.1")
      |> get("/sympp/board")

    assert response(headerless_conn, 401) =~ "Board access"
    refute Plug.Conn.get_session(headerless_conn, "sympp_local_operator")

    cross_site_conn =
      local_conn()
      |> Plug.Conn.put_req_header("sec-fetch-site", "cross-site")
      |> get("/sympp/board")

    assert response(cross_site_conn, 401) =~ "Board access"
    refute Plug.Conn.get_session(cross_site_conn, "sympp_local_operator")

    ipv6_conn =
      build_conn()
      |> Map.put(:remote_ip, {0, 0, 0, 0, 0, 0, 0, 1})
      |> Map.put(:host, "[::1]")
      |> Plug.Conn.put_req_header("sec-fetch-site", "none")
      |> get("/sympp/board")

    assert response(ipv6_conn, 200) =~ "Local operator cockpit"
    assert Plug.Conn.get_session(ipv6_conn, "sympp_local_operator") == true
  end

  test "local operator package routes keep missing package ids as not found" do
    enable_operator_mode()

    conn = get(local_conn(), "/sympp/work-packages/SYMPP-DOES-NOT-EXIST")

    assert response(conn, 404) =~ "Package not found"
    refute Plug.Conn.get_session(conn, "sympp_local_operator")
  end

  test "explicit scoped board grants still win on localhost while operator mode is enabled" do
    enable_operator_mode()

    package = create_package!(id: "SYMPP-V2-UX-SCOPED", title: "Scoped localhost package")
    grant = create_architect_grant!(package.id)

    request =
      create_work_request!(
        id: "WR-OPERATOR-SCOPED-GRANT",
        title: "Scoped WorkRequest actions",
        status: "human_info_needed"
      )

    assert {:ok, _question} =
             WorkRequestRepository.ask_question(Repo, request.id, %{
               question: "Can scoped localhost grants still answer?",
               category: "product",
               why_needed: "Scoped work-key behavior must survive operator mode.",
               asked_by: "operator"
             })

    conn =
      local_conn()
      |> Plug.Test.init_test_session(%{"sympp_board_grant_id" => grant.id})
      |> get("/sympp/board")

    assert response(conn, 200) =~ "Work package board"
    refute response(conn, 200) =~ "Local operator cockpit"
    assert Plug.Conn.get_session(conn, "sympp_board_grant_id") == grant.id
    refute Plug.Conn.get_session(conn, "sympp_local_operator")

    {:ok, _view, html} = live(conn, "/sympp/work-requests/#{request.id}")

    assert html =~ "Scoped WorkRequest actions"
    assert html =~ "Answer</button>"
    assert html =~ "Close unanswered"
  end

  test "entering local operator mode preserves cached package grants" do
    enable_operator_mode()

    package = create_package!(id: "SYMPP-V2-UX-PACKAGE-CACHE", title: "Cached package grant")
    grant = create_package_grant!(package.id)

    conn =
      local_conn()
      |> Plug.Test.init_test_session(%{"sympp_package_grant_ids" => %{package.id => grant.id}})
      |> get("/sympp/board")

    assert response(conn, 200) =~ "Local operator cockpit"
    assert Plug.Conn.get_session(conn, "sympp_local_operator") == true
    assert Plug.Conn.get_session(conn, "sympp_package_grant_ids") == %{package.id => grant.id}

    scoped_conn =
      local_conn()
      |> Plug.Test.init_test_session(%{"sympp_local_operator" => true, "sympp_package_grant_ids" => %{package.id => grant.id}})
      |> get("/sympp/work-packages/#{package.id}?auth=work_key")

    assert response(scoped_conn, 401) =~ "Package access"
    refute Plug.Conn.get_session(scoped_conn, "sympp_local_operator")
    refute Map.has_key?(Plug.Conn.get_session(scoped_conn, "sympp_package_grant_ids", %{}), package.id)
  end

  defp create_package!(overrides) do
    blocker? = Keyword.get(overrides, :blocker?, false)
    pr_url = Keyword.get(overrides, :pr_url)

    assert {:ok, package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(
                 id: Keyword.fetch!(overrides, :id),
                 kind: Keyword.get(overrides, :kind, "dashboard"),
                 status: Keyword.get(overrides, :status, "planning"),
                 title: Keyword.get(overrides, :title, "Operator package"),
                 repo: Keyword.get(overrides, :repo, "nextide/symphony-plus-plus"),
                 base_branch: Keyword.get(overrides, :base_branch, "main"),
                 product_description: Keyword.get(overrides, :product_description, "Product context"),
                 engineering_scope: "Engineering scope",
                 acceptance_criteria: ["Visible in the operator cockpit."]
               )
             )

    assert {:ok, _plan} =
             PlanningRepository.append_plan_node(Repo, %{
               work_package_id: package.id,
               title: "Implement",
               status: "pending"
             })

    if blocker?, do: append_blocker!(package)
    if pr_url, do: append_pr!(package, pr_url)
    append_run!(package)
    package
  end

  defp append_blocker!(package) do
    assert {:ok, _blocker} =
             PlanningRepository.append_progress_event(Repo, %{
               work_package_id: package.id,
               summary: "Blocked on product direction",
               status: "blocked",
               payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "#{package.id}-blocker", active: true}
             })
  end

  defp append_pr!(package, pr_url) do
    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(Repo, %{
               work_package_id: package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: pr_url, head_sha: "abc123456"}
             })
  end

  defp append_run!(package) do
    assert {:ok, _run} =
             AgentRunRepository.start_run(Repo, %{
               work_package_id: package.id,
               status: "running",
               attempt: 1,
               worker_host: "local",
               worker_task_handle: "task-operator",
               session_id: "session-operator"
             })
  end

  defp create_work_request!(overrides) do
    defaults = %{
      id: "WR-OPERATOR",
      title: "Operator request",
      repo: "nextide/symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Operator-visible request.",
      constraints: %{"allowed_paths" => ["elixir/lib/symphony_elixir_web"]},
      desired_dispatch_shape: "single_package",
      status: "draft"
    }

    assert {:ok, work_request} = WorkRequestRepository.create(Repo, Enum.into(overrides, defaults))
    work_request
  end

  defp create_architect_grant!(work_package_id) do
    assert {:ok, phase} = PhaseRepository.create(Repo, %{id: "phase-operator-mode", title: "Operator mode test phase"})
    assert {:ok, _package} = WorkPackageRepository.update(Repo, work_package_id, %{phase_id: phase.id})
    work_key = WorkKey.generate()

    assert {:ok, grant} =
             AccessGrantRepository.create(Repo, %{
               work_package_id: work_package_id,
               phase_id: phase.id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "architect",
               capabilities: ["read:phase"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(Repo, work_key.secret, %{claimed_by: "architect-operator"}, DateTime.utc_now(:microsecond))

    grant
  end

  defp create_package_grant!(work_package_id) do
    work_key = WorkKey.generate()

    assert {:ok, grant} =
             AccessGrantRepository.create(Repo, %{
               work_package_id: work_package_id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "worker",
               capabilities: ["read:package"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
             })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(Repo, work_key.secret, %{claimed_by: "worker-operator"}, DateTime.utc_now(:microsecond))

    grant
  end

  defp enable_operator_mode do
    put_endpoint_config(sympp_local_operator: true)
  end

  defp disable_operator_mode do
    put_endpoint_config(sympp_local_operator: false)
  end

  defp local_conn do
    build_conn()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Map.put(:host, "127.0.0.1")
    |> Plug.Conn.put_req_header("sec-fetch-site", "none")
  end

  defp put_endpoint_config(opts) do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, Keyword.merge(endpoint_config, opts))
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), sympp_repo: Repo, sympp_local_operator: false)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp restore_database_env(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_database)
  defp restore_database_env(database), do: Application.put_env(:symphony_elixir, :sympp_repo_database, database)
end
