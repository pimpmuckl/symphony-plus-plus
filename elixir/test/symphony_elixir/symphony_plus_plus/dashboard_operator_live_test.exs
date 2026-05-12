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

    {:ok, _view, html} = live(build_conn(), "/sympp/board")

    assert html =~ "Local operator cockpit"
    assert html =~ "Product Guidance Needed"
    assert html =~ "Need product answer"
    assert html =~ "Blockers"
    assert html =~ "Local operator cockpit"
    assert html =~ package.id
    assert html =~ ~s(href="work-packages/#{package.id}")
    refute html =~ "Board access"
    refute html =~ "work_key"
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

    {:ok, _view, html} = live(build_conn(), "/sympp/work-packages/#{package.id}")

    assert html =~ "[REDACTED]"
    assert html =~ "Virtual Task Plan"
    assert html =~ "Findings"
    assert html =~ ~s(class="sympp-back-link")
    refute html =~ "raw-secret-value"
    refute html =~ "Package access"
    refute html =~ "work_key"
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

    {:ok, _view, html} = live(build_conn(), "/sympp/work-requests/#{request.id}")

    assert html =~ "Operator WorkRequest detail"
    assert html =~ "Question needing operator guidance"
    assert html =~ "Planned slices"
    assert html =~ "First operator slice"
    refute html =~ "Board access"
    refute html =~ "work_key"
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
      build_conn()
      |> Plug.Test.init_test_session(%{"sympp_board_grant_id" => grant.id})
      |> get("/sympp/board")

    assert Plug.Conn.get_session(conn, "sympp_local_operator") == true
    refute Plug.Conn.get_session(conn, "sympp_board_grant_id")

    {:ok, _view, html} = live(conn, "/sympp/work-requests/#{request.id}")

    assert html =~ "Stale grant WorkRequest"
    refute html =~ "Answer</button>"
    refute html =~ "Close unanswered"
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

    {:ok, _view, html} = live(build_conn(), "/sympp/board?repo=nextide/symphony-plus-plus")

    assert html =~ "Visible repo package"
    assert html =~ "Visible guidance request"
    refute html =~ "Hidden repo blocker"
    refute html =~ "Hidden guidance request"
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

  defp enable_operator_mode do
    put_endpoint_config(sympp_local_operator: true)
  end

  defp disable_operator_mode do
    put_endpoint_config(sympp_local_operator: false)
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
