defmodule SymphonyElixir.SymphonyPlusPlus.DashboardOperatorLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Repository, as: GuidanceRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SecretHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.SymppDashboardApiController

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule CustomOperatorRepo do
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
    Repo.delete_all(GuidanceRequest)
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
        title: "Package raw-secret-value",
        status: "implementing",
        blocker?: true,
        pr_url: "https://github.com/example/symphony-plus-plus/pull/101"
      )

    create_work_request!(
      id: "WR-OPERATOR-GUIDANCE",
      title: "Need product answer ghp_raw_secret_value",
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
    assert html =~ "Blockers"
    assert html =~ package.id
    assert html =~ ~s(href="work-packages/#{package.id}")
    assert Regex.scan(~r/\[REDACTED\]/, html) |> length() >= 2
    refute html =~ "raw-secret-value"
    refute html =~ "ghp_raw_secret_value"
    refute html =~ "Board access"
    refute html =~ ~s(name="work_key")
  end

  test "local operator board shows human-info guidance requests from packages" do
    enable_operator_mode()

    package =
      create_package!(
        id: "SYMPP-V2-GUIDANCE-BOARD",
        title: "Guidance board package",
        status: "blocked",
        blocker?: true
      )

    guidance = create_human_guidance_request!(package, id: "guidance-board-visible", summary: "Choose product behavior")

    {:ok, _view, html} = live(local_conn(), "/sympp/board")

    assert html =~ "Local operator cockpit"
    assert html =~ "Product Guidance Needed"
    assert html =~ "Choose product behavior"
    assert html =~ "worker-operator"
    assert html =~ ~s(href="work-packages/#{package.id}#guidance-requests")
    assert html =~ "Human info needed"
    refute html =~ "raw-secret-value"
    assert guidance.status == "human_info_needed"
  end

  test "local operator answers human-info guidance from package detail and resolves readiness blocker" do
    enable_operator_mode()

    package =
      create_package!(
        id: "SYMPP-V2-GUIDANCE-ANSWER",
        title: "Guidance answer package",
        status: "ci_waiting"
      )

    guidance =
      create_human_guidance_request!(
        package,
        id: "guidance-answer-visible",
        summary: "Need package behavior",
        question: "Which behavior should this package implement?",
        context: "Two product behaviors fit the package scope."
      )

    {:ok, detail} = Dashboard.detail(Repo, package.id)
    assert detail.summary.active_blocker_count == 1

    {:ok, view, html} = live(local_conn(), "/sympp/work-packages/#{package.id}")

    assert html =~ "Guidance Requests"
    assert html =~ "Need package behavior"
    assert html =~ "Which behavior should this package implement?"
    assert html =~ "worker-operator"
    assert html =~ "guidance_request:#{guidance.id}"
    assert html =~ "Answer guidance"

    html =
      render_submit(view, "answer_guidance_request", %{
        "guidance_request" => %{
          "id" => guidance.id,
          "work_package_id" => "forged-package",
          "answer" => "Implement the explicit product behavior."
        }
      })

    assert html =~ "Implement the explicit product behavior."
    assert html =~ "local-operator"
    refute html =~ "Answer guidance"

    answered = Repo.get!(GuidanceRequest, guidance.id)
    assert answered.status == "answered"
    assert answered.answered_by == "local-operator"
    assert answered.answer == "Implement the explicit product behavior."

    assert {:ok, events} = PlanningRepository.list_progress_events(Repo, package.id)
    resolve_event = Enum.find(events, &(&1.payload["source_tool"] == "resolve_blocker"))
    assert resolve_event.status == "resolved"
    assert resolve_event.payload["blocker_id"] == "guidance_request:#{guidance.id}"
    assert resolve_event.payload["active"] == false

    {:ok, updated_detail} = Dashboard.detail(Repo, package.id)
    assert updated_detail.summary.active_blocker_count == 0
  end

  test "package-grant sessions cannot answer human-info guidance from package detail" do
    enable_operator_mode()

    package =
      create_package!(
        id: "SYMPP-V2-GUIDANCE-DENIED",
        title: "Guidance denied package",
        status: "blocked"
      )

    guidance = create_human_guidance_request!(package, id: "guidance-answer-denied")
    grant = create_package_grant!(package.id)

    {:ok, view, html} =
      build_conn()
      |> Plug.Test.init_test_session(%{"sympp_package_grant_ids" => %{package.id => grant.id}})
      |> live("/sympp/work-packages/#{package.id}")

    assert html =~ "Guidance Requests"
    assert html =~ guidance.summary
    refute html =~ "Answer guidance"

    html =
      render_submit(view, "answer_guidance_request", %{
        "guidance_request" => %{"id" => guidance.id, "answer" => "Bypass architect responsibility."}
      })

    assert html =~ "Only the local operator cockpit can answer human info guidance."
    assert Repo.get!(GuidanceRequest, guidance.id).status == "human_info_needed"
  end

  test "local operator creates a WorkRequest with explicit repo and base branch" do
    enable_operator_mode()

    {:ok, view, html} = live(local_conn(), "/sympp/work-requests/new")

    assert html =~ "New WorkRequest"
    assert html =~ ~s(name="work_request[repo]")
    assert html =~ ~s(name="work_request[base_branch]")

    render_submit(view, "create_work_request", %{
      "work_request" => %{
        "title" => "Local operator intake",
        "repo" => "nextide/local-dogfood",
        "base_branch" => "dogfood/base",
        "work_type" => "feature",
        "desired_dispatch_shape" => "single_package",
        "human_description" => "Create from local operator mode.",
        "constraints_json" => ~s({"allowed_paths":["elixir/lib"],"requires_secret":false})
      }
    })

    assert {redirected_path, _flash} = assert_redirect(view)
    assert redirected_path =~ "/sympp/work-requests/"
    created_id = redirected_path |> String.split("/") |> List.last()

    assert {:ok, created} = WorkRequestRepository.get(Repo, created_id)
    assert created.title == "Local operator intake"
    assert created.status == "draft"
    assert created.repo == "nextide/local-dogfood"
    assert created.base_branch == "dogfood/base"
    assert created.constraints == %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false}
  end

  test "local operator initializes a missing configured ledger as an empty cockpit" do
    enable_operator_mode()

    missing_database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_migrated_databases = Application.get_env(:symphony_elixir, :sympp_board_live_migrated_databases)

    File.rm(missing_database_path)
    Application.put_env(:symphony_elixir, :sympp_repo_database, missing_database_path)

    on_exit(fn ->
      restore_database_env(original_database)
      restore_board_live_migrated_databases(original_migrated_databases)
      File.rm(missing_database_path)
    end)

    {:ok, _view, html} = live(local_conn(), "/sympp/board")

    assert File.exists?(missing_database_path)
    assert html =~ "Local operator cockpit"
    assert html =~ "No work packages match the current board filters."
    assert html =~ ~r/<span class="sympp-board-count numeric">\s*0\s*<\/span>\s*<span class="muted">total<\/span>/
    assert html =~ ~r/<span class="sympp-board-count numeric">\s*0\s*<\/span>\s*<span class="muted">shown<\/span>/
    assert html =~ ~r/<span class="muted">Guidance needed<\/span>\s*<strong class="numeric">\s*0\s*<\/strong>/
    assert html =~ ~r/<span class="muted">Active blockers<\/span>\s*<strong class="numeric">\s*0\s*<\/strong>/
    assert html =~ ~r/<span class="muted">Review or ready<\/span>\s*<strong class="numeric">\s*0\s*<\/strong>/
    refute html =~ "Board unavailable"
    refute html =~ "No Symphony++ work package ledger was found."
    refute html =~ "Board access"
    refute html =~ ~s(name="work_key")
  end

  test "local operator initializes a missing sqlite URI ledger as an empty cockpit" do
    enable_operator_mode()

    missing_database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_migrated_databases = Application.get_env(:symphony_elixir, :sympp_board_live_migrated_databases)
    uri_database = "file:#{missing_database_path}?mode=rwc&cache=shared"

    File.rm(missing_database_path)
    Application.put_env(:symphony_elixir, :sympp_repo_database, uri_database)

    on_exit(fn ->
      restore_database_env(original_database)
      restore_board_live_migrated_databases(original_migrated_databases)
      File.rm(missing_database_path)
    end)

    {:ok, _view, html} = live(local_conn(), "/sympp/board")

    assert File.exists?(missing_database_path)
    assert html =~ "Local operator cockpit"
    assert html =~ "No work packages match the current board filters."
    refute html =~ "Board unavailable"
    refute html =~ "No Symphony++ work package ledger was found."
  end

  test "local operator rejects empty-path sqlite URI ledgers" do
    enable_operator_mode()

    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_migrated_databases = Application.get_env(:symphony_elixir, :sympp_board_live_migrated_databases)

    Application.put_env(:symphony_elixir, :sympp_repo_database, "file:?mode=rwc")

    on_exit(fn ->
      restore_database_env(original_database)
      restore_board_live_migrated_databases(original_migrated_databases)
    end)

    {:ok, _view, html} = live(local_conn(), "/sympp/board")

    assert html =~ "Board unavailable"
    assert html =~ "No Symphony++ work package ledger was found."
    refute html =~ "No work packages match the current board filters."
  end

  test "local operator rejects missing read-only sqlite URI ledgers" do
    enable_operator_mode()

    missing_database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_migrated_databases = Application.get_env(:symphony_elixir, :sympp_board_live_migrated_databases)

    File.rm(missing_database_path)
    Application.put_env(:symphony_elixir, :sympp_repo_database, "file:#{missing_database_path}?mode=ro")

    on_exit(fn ->
      restore_database_env(original_database)
      restore_board_live_migrated_databases(original_migrated_databases)
      File.rm(missing_database_path)
    end)

    {:ok, _view, html} = live(local_conn(), "/sympp/board")

    refute File.exists?(missing_database_path)
    assert html =~ "Board unavailable"
    assert html =~ "No Symphony++ work package ledger was found."
    refute html =~ "No work packages match the current board filters."
  end

  test "local operator rejects missing existing-file-only sqlite URI ledgers" do
    enable_operator_mode()

    missing_database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_migrated_databases = Application.get_env(:symphony_elixir, :sympp_board_live_migrated_databases)

    File.rm(missing_database_path)
    Application.put_env(:symphony_elixir, :sympp_repo_database, "file:#{missing_database_path}?mode=rw")

    on_exit(fn ->
      restore_database_env(original_database)
      restore_board_live_migrated_databases(original_migrated_databases)
      File.rm(missing_database_path)
    end)

    {:ok, _view, html} = live(local_conn(), "/sympp/board")

    refute File.exists?(missing_database_path)
    assert html =~ "Board unavailable"
    assert html =~ "No Symphony++ work package ledger was found."
    refute html =~ "No work packages match the current board filters."
  end

  test "local operator preserves existing sqlite URI ledgers" do
    enable_operator_mode()

    package = create_package!(id: "SYMPP-V2-UX-URI", title: "URI-backed cockpit package")
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_migrated_databases = Application.get_env(:symphony_elixir, :sympp_board_live_migrated_databases)
    uri_database = "file:#{Repo.database_path()}"

    Application.put_env(:symphony_elixir, :sympp_repo_database, uri_database)

    on_exit(fn ->
      restore_database_env(original_database)
      restore_board_live_migrated_databases(original_migrated_databases)
    end)

    {:ok, _view, html} = live(local_conn(), "/sympp/board")

    assert html =~ "Local operator cockpit"
    assert html =~ package.id
    refute html =~ "Board unavailable"
    refute html =~ "No Symphony++ work package ledger was found."
  end

  test "local operator initializes a missing custom repo ledger as an empty cockpit" do
    enable_operator_mode()

    missing_database_path = WorkPackageFactory.database_path()
    original_custom_repo_config = Application.get_env(:symphony_elixir, CustomOperatorRepo)
    original_migrated_databases = Application.get_env(:symphony_elixir, :sympp_board_live_migrated_databases)

    File.rm(missing_database_path)
    Application.put_env(:symphony_elixir, CustomOperatorRepo, database: missing_database_path)
    put_endpoint_config(sympp_repo: CustomOperatorRepo)

    on_exit(fn ->
      restore_custom_operator_repo_env(original_custom_repo_config)
      restore_board_live_migrated_databases(original_migrated_databases)
      put_endpoint_config(sympp_repo: Repo)
      File.rm(missing_database_path)
    end)

    {:ok, _view, html} = live(local_conn(), "/sympp/board")

    assert File.exists?(missing_database_path)
    assert html =~ "Local operator cockpit"
    assert html =~ "No work packages match the current board filters."
    refute html =~ "Board unavailable"
    refute html =~ "No Symphony++ work package ledger was found."
  end

  test "local operator treats blank custom repo database config as unset" do
    enable_operator_mode()

    package = create_package!(id: "SYMPP-V2-UX-BLANK-CUSTOM", title: "Blank custom repo package")
    original_custom_repo_config = Application.get_env(:symphony_elixir, CustomOperatorRepo)
    original_migrated_databases = Application.get_env(:symphony_elixir, :sympp_board_live_migrated_databases)

    Application.put_env(:symphony_elixir, CustomOperatorRepo, database: " ")
    put_endpoint_config(sympp_repo: CustomOperatorRepo)

    on_exit(fn ->
      restore_custom_operator_repo_env(original_custom_repo_config)
      restore_board_live_migrated_databases(original_migrated_databases)
      put_endpoint_config(sympp_repo: Repo)
    end)

    {:ok, _view, html} = live(local_conn(), "/sympp/board")

    assert html =~ "Local operator cockpit"
    assert html =~ package.id
    refute html =~ "Board unavailable"
    refute html =~ "No Symphony++ work package ledger was found."
  end

  test "local operator keeps work-key login surfaces reachable" do
    enable_operator_mode()
    package = create_package!(id: "SYMPP-V2-UX-WORK-KEY", title: "Work key reachable package")

    board_conn = get(local_conn(), "/sympp/board?auth=work_key")

    assert response(board_conn, 401) =~ "Board access"
    assert response(board_conn, 401) =~ "work_key"
    refute Plug.Conn.get_session(board_conn, "sympp_local_operator")

    board_grant = create_architect_grant!(package.id)
    package_grant = create_package_grant!(package.id)

    cached_board_conn =
      local_conn()
      |> Plug.Test.init_test_session(%{
        "sympp_board_grant_id" => board_grant.id,
        "sympp_package_grant_ids" => %{package.id => package_grant.id}
      })
      |> get("/sympp/board?auth=work_key")

    assert response(cached_board_conn, 401) =~ "Board access"
    assert Plug.Conn.get_session(cached_board_conn, "sympp_board_grant_id") == board_grant.id
    assert Plug.Conn.get_session(cached_board_conn, "sympp_package_grant_ids") == %{package.id => package_grant.id}

    package_conn =
      local_conn()
      |> Plug.Test.init_test_session(%{"sympp_local_operator" => true})
      |> get("/sympp/work-packages/#{package.id}?auth=work_key")

    assert response(package_conn, 401) =~ "Package access"
    assert response(package_conn, 401) =~ "work_key"
    refute response(package_conn, 401) =~ "Work key reachable package"
    assert Plug.Conn.get_session(package_conn, "sympp_local_operator") == true
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
        human_description: "Inspect the full request with Bearer raw-secret-value."
      )

    assert {:ok, question} =
             WorkRequestRepository.ask_question(Repo, request.id, %{
               question: "Question needing operator guidance raw-secret-value",
               category: "product",
               why_needed: "Operator needs to understand the pending product answer.",
               asked_by: "operator"
             })

    assert {:ok, decision} =
             WorkRequestRepository.record_decision(Repo, request.id, %{
               decision: "Proceed without ghp_raw_secret_value",
               rationale: "The token raw-secret-value is not needed.",
               source_type: "operator",
               scope_impact: "No scope change.",
               created_by: "operator"
             })

    assert {:ok, slice} =
             WorkRequestRepository.add_planned_slice(Repo, request.id, %{
               title: "First operator slice",
               goal: "Expose the cockpit without sk-rawsecretvalue.",
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
    assert html =~ "Clarification questions"
    assert html =~ question.id
    assert html =~ "Decision log"
    assert html =~ decision.id
    assert html =~ "Planned slices"
    assert html =~ slice.id
    assert html =~ "First operator slice"
    assert Regex.scan(~r/\[REDACTED\]/, html) |> length() >= 5
    assert html =~ ~s(href="../board?auth=work_key")
    refute html =~ "Board access"
    refute html =~ "raw-secret-value"
    refute html =~ "ghp_raw_secret_value"
    refute html =~ "sk-rawsecretvalue"
    refute html =~ ~s(name="work_key")
    assert html =~ "Answer</button>"
    assert html =~ "Close unanswered"
  end

  test "local operator can manage the safe WorkRequest lifecycle without a scoped board grant" do
    enable_operator_mode()

    request =
      create_work_request!(
        id: "WR-OPERATOR-MANAGE",
        title: "Operator managed request"
      )

    {:ok, view, html} = live(local_conn(), "/sympp/work-requests/#{request.id}")

    assert html =~ "Mark ready for clarification"

    html = render_click(view, "mark_ready_for_clarification", %{})
    assert html =~ "ready for clarification"

    html =
      render_submit(view, "ask_question", %{
        "question" => %{
          "category" => "product",
          "question" => "What should the first slice own?",
          "why_needed" => "The operator needs to decide the slice boundary.",
          "asked_by_agent_run_id" => "forged"
        }
      })

    assert html =~ "What should the first slice own?"
    assert {:ok, clarified} = WorkRequestRepository.get(Repo, request.id)
    assert clarified.status == "clarifying"
    assert {:ok, [first_question]} = WorkRequestRepository.list_questions(Repo, request.id)
    assert first_question.asked_by_agent_run_id == "local-operator"

    html =
      render_submit(view, "close_question", %{
        "question" => %{"id" => first_question.id, "current_status" => "open"}
      })

    assert html =~ "closed"
    assert {:ok, [closed_question]} = WorkRequestRepository.list_questions(Repo, request.id)
    assert closed_question.status == "closed"

    html =
      render_submit(view, "ask_question", %{
        "question" => %{
          "category" => "product",
          "question" => "Which repo docs should be updated?",
          "why_needed" => "The runbook needs to match the UI."
        }
      })

    assert html =~ "Which repo docs should be updated?"
    assert {:ok, [_closed_question, second_question]} = WorkRequestRepository.list_questions(Repo, request.id)

    html =
      render_submit(view, "answer_question", %{
        "question" => %{
          "id" => second_question.id,
          "current_status" => "open",
          "answer" => "Update the dashboard spec and operational runbook.",
          "answered_by" => "forged-answer"
        }
      })

    assert html =~ "Update the dashboard spec and operational runbook."
    assert {:ok, [_closed_question, answered_question]} = WorkRequestRepository.list_questions(Repo, request.id)
    assert answered_question.status == "answered"
    assert answered_question.answered_by == "local-operator"

    render_submit(view, "answer_question", %{
      "question" => %{
        "id" => second_question.id,
        "current_status" => "open",
        "answer" => "Too late.",
        "answered_by" => "local-operator"
      }
    })

    assert {:ok, [_closed_question, still_answered]} = WorkRequestRepository.list_questions(Repo, request.id)
    assert still_answered.answer == "Update the dashboard spec and operational runbook."

    html =
      render_submit(view, "record_decision", %{
        "decision" => %{
          "source_type" => "operator",
          "decision" => "Keep the local operator intake browser-only.",
          "rationale" => "Worker grants stay unchanged.",
          "scope_impact" => "No MCP or Linear change.",
          "created_by" => "forged-decision"
        }
      })

    assert html =~ "Keep the local operator intake browser-only."
    assert {:ok, [decision]} = WorkRequestRepository.list_decisions(Repo, request.id)
    assert decision.created_by == "local-operator"

    html = render_click(view, "mark_human_info_needed", %{})
    assert html =~ "human info needed"

    html = render_click(view, "mark_ready_for_slicing", %{})
    assert html =~ "ready for slicing"

    html =
      render_submit(view, "add_planned_slice", %{
        "planned_slice" => %{
          "title" => "Add local operator WorkRequest controls",
          "goal" => "Let local operators continue clarification and slicing.",
          "work_package_kind" => "dashboard",
          "target_base_branch" => "main",
          "branch_pattern" => "agent/SYMPP-V2-UX-004/local-operator-workrequest-intake",
          "owned_file_globs" => "elixir/lib/symphony_elixir_web/live/sympp_work_request_live.ex",
          "forbidden_file_globs" => "elixir/lib/symphony_elixir/symphony_plus_plus/secret_handoff.ex",
          "acceptance_criteria" => "Local operator can approve a slice.",
          "validation_steps" => "mix test",
          "review_lanes" => "review_t1\nreview_t2",
          "stop_conditions" => "Stop before dispatch."
        }
      })

    assert html =~ "Add local operator WorkRequest controls"
    assert {:ok, [first_slice]} = WorkRequestRepository.list_planned_slices(Repo, request.id)

    html =
      render_submit(view, "approve_planned_slice", %{
        "slice" => %{"id" => first_slice.id, "current_status" => "planned"}
      })

    assert html =~ "approved"

    html =
      render_submit(view, "add_planned_slice", %{
        "planned_slice" => %{
          "title" => "Optional follow-up",
          "goal" => "Capture a deferrable follow-up.",
          "work_package_kind" => "docs",
          "target_base_branch" => "main",
          "branch_pattern" => "agent/SYMPP-V2-UX-004/docs-followup",
          "owned_file_globs" => "implementation_docs_symphplusplus/docs/**",
          "forbidden_file_globs" => "elixir/lib/symphony_elixir/symphony_plus_plus/secret_handoff.ex",
          "acceptance_criteria" => "Follow-up can be skipped.",
          "validation_steps" => "mix test",
          "review_lanes" => "review_t1",
          "stop_conditions" => "Stop before dispatch."
        }
      })

    assert html =~ "Optional follow-up"
    assert {:ok, [_approved_slice, second_slice]} = WorkRequestRepository.list_planned_slices(Repo, request.id)

    html =
      render_submit(view, "skip_planned_slice", %{
        "slice" => %{"id" => second_slice.id, "current_status" => "planned"}
      })

    assert html =~ "skipped"

    html = render_click(view, "mark_sliced", %{})
    assert html =~ "sliced"
    assert {:ok, sliced} = WorkRequestRepository.get(Repo, request.id)
    assert sliced.status == "sliced"
  end

  test "local operator dispatches approved planned slices through private handoff" do
    enable_operator_mode()
    store_dir = Path.join(System.tmp_dir!(), "sympp-operator-dispatch-store-#{System.unique_integer([:positive])}")
    previous_store_dir = Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir)
    Application.put_env(:symphony_elixir, :sympp_worker_secret_store_dir, store_dir)

    on_exit(fn ->
      restore_store_dir_env(previous_store_dir)
      File.rm_rf(store_dir)
    end)

    request =
      create_work_request!(
        id: "WR-OPERATOR-DISPATCH",
        title: "Dispatch local slice",
        status: "ready_for_slicing",
        constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false}
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(Repo, request.id, %{
               title: "Dispatch from WorkRequest detail",
               goal: "Create a worker-ready WorkPackage without spawning Codex.",
               work_package_kind: "mcp",
               target_base_branch: "main",
               branch_pattern: "agent/SYMPP-V2-UX-005/local-operator-slice-dispatch",
               owned_file_globs: ["elixir/lib/symphony_elixir_web/live/sympp_work_request_live.ex"],
               forbidden_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/secret_handoff.ex"],
               acceptance_criteria: ["Dispatch links the planned slice to a WorkPackage."],
               validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/dashboard_operator_live_test.exs"],
               review_lanes: ["review_t1", "review_t2"],
               stop_conditions: ["Stop before spawning Codex."]
             })

    assert {:ok, approved_slice} =
             WorkRequestRepository.approve_planned_slice(Repo, request.id, planned_slice.id, "planned")

    {:ok, view, html} = live(local_conn(), "/sympp/work-requests/#{request.id}")

    assert html =~ "Dispatch from WorkRequest detail"
    assert html =~ "Dispatch</button>"

    html =
      render_submit(view, "dispatch_planned_slice", %{
        "slice" => %{"id" => approved_slice.id}
      })

    handoff = dispatch_handoff_from_html(html)

    on_exit(fn ->
      cleanup_handoff(handoff)
    end)

    assert html =~ "Private worker handoff stored"
    assert html =~ "local-operator-worker"
    assert html =~ "Secret in stdout"
    assert html =~ "false"
    assert_handoff_store_dir!(handoff, store_dir)
    metadata_dir = Path.join(store_dir, "metadata")
    assert File.dir?(metadata_dir)
    assert metadata_dir |> File.ls!() |> Enum.any?(&String.ends_with?(&1, ".json"))

    expected_database =
      :symphony_elixir
      |> Application.fetch_env!(:sympp_repo_database)

    assert html =~ "-Database"
    assert html =~ Path.basename(expected_database)
    refute html =~ "secret_returned_once"
    refute html =~ "secret_not_persisted"

    assert {:ok, [dispatched_slice]} = WorkRequestRepository.list_planned_slices(Repo, request.id)
    assert dispatched_slice.status == "dispatched"
    assert is_binary(dispatched_slice.work_package_id)
    assert %DateTime{} = dispatched_slice.dispatched_at

    assert {:ok, work_package} = WorkPackageRepository.get(Repo, dispatched_slice.work_package_id)
    assert work_package.status == "ready_for_worker"
    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(Repo, work_package.id)
    worker_grant = Enum.find(grants, &(&1.grant_role == "worker"))

    on_exit(fn ->
      cleanup_handoff_by_grant(work_package, worker_grant)
    end)

    assert html =~ dispatched_slice.work_package_id
    assert html =~ ~s(href="/sympp/work-packages/#{dispatched_slice.work_package_id}")
    assert html =~ "ready for worker"
    refute html =~ ~s(name="slice[id]" value="#{approved_slice.id}")

    {:ok, _detail_view, detail_html} = live(local_conn(), "/sympp/work-packages/#{dispatched_slice.work_package_id}")

    assert detail_html =~ "Worker Handoff"
    assert detail_html =~ "local-operator-worker"
    assert detail_html =~ "Secret in stdout"
    assert detail_html =~ "false"
    assert detail_html =~ handoff["target"]
    assert detail_html =~ "Run MCP"
    refute detail_html =~ "secret_returned_once"
    refute detail_html =~ "secret_not_persisted"
  end

  test "local operator prepares and replays a WorkRequest architect handoff" do
    enable_operator_mode()
    store_dir = Path.join(System.tmp_dir!(), "sympp-operator-architect-store-#{System.unique_integer([:positive])}")
    previous_store_dir = Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir)
    Application.put_env(:symphony_elixir, :sympp_worker_secret_store_dir, store_dir)

    on_exit(fn ->
      restore_store_dir_env(previous_store_dir)
      File.rm_rf(store_dir)
    end)

    request =
      create_work_request!(
        id: "WR-OPERATOR-ARCHITECT-HANDOFF",
        title: "Prepare architect handoff",
        status: "ready_for_clarification",
        constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false}
      )

    {:ok, view, html} = live(local_conn(), "/sympp/work-requests/#{request.id}")

    assert html =~ "Prepare architect handoff"
    refute html =~ "Private architect handoff stored"

    html = render_click(view, "create_architect_handoff", %{})

    assert html =~ "Private architect handoff stored"
    assert html =~ "created"
    assert html =~ request.id
    assert html =~ "phase-wr-architect-"
    assert html =~ "SYMPP-WR-ARCH-"
    assert html =~ "symphony-plus-plus:symphony-architect"
    assert html =~ "nextide/symphony-plus-plus / main"
    assert html =~ "Secret in stdout"
    assert html =~ "false"
    assert html =~ "Ledger database"
    assert html =~ Path.basename(Application.fetch_env!(:symphony_elixir, :sympp_repo_database))

    Enum.each(ArchitectHandoff.capabilities(), fn capability ->
      assert html =~ capability
    end)

    refute html =~ "wk_"
    refute html =~ "secret_hash"
    refute html =~ "secret_returned_once"
    refute html =~ "run_mcp_command"
    refute html =~ "Run MCP"

    anchor_id = regex_capture(html, ~r/SYMPP-WR-ARCH-[A-Za-z0-9_-]+/)
    assert {:ok, anchor} = WorkPackageRepository.get(Repo, anchor_id)
    assert anchor.repo == request.repo
    assert anchor.base_branch == request.base_branch
    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(Repo, anchor.id)

    on_exit(fn ->
      cleanup_architect_handoff_by_grant(anchor, grant)
    end)

    assert grant.grant_role == "architect"
    assert grant.phase_id == anchor.phase_id
    assert grant.capabilities == ArchitectHandoff.capabilities()
    assert grant.scope_repo == request.repo
    assert grant.scope_base_branch == request.base_branch
    assert is_nil(grant.claimed_at)

    metadata_dir = Path.join(store_dir, "metadata")
    assert File.dir?(metadata_dir)
    assert metadata_dir |> File.ls!() |> Enum.any?(&String.ends_with?(&1, ".json"))

    replay_html = render_click(view, "create_architect_handoff", %{})

    assert replay_html =~ "replayed"
    assert replay_html =~ grant.id
    refute replay_html =~ "wk_"
    refute replay_html =~ "secret_hash"
    refute replay_html =~ "Run MCP"

    assert {:ok, replayed_grants} = AccessGrantRepository.list_for_work_package(Repo, anchor.id)
    assert Enum.map(replayed_grants, & &1.id) == [grant.id]
  end

  test "local operator hides architect handoff action for WorkRequests without frozen scope" do
    enable_operator_mode()

    request =
      Repo.insert!(%WorkRequest{
        id: "WR-OPERATOR-ARCHITECT-BLANK-SCOPE",
        title: "Blank scope architect handoff",
        repo: "",
        base_branch: "main",
        work_type: "feature",
        human_description: "Stored rows without frozen scope must not show handoff controls.",
        constraints: %{},
        desired_dispatch_shape: "architect_led_feature_branch",
        status: "ready_for_slicing"
      })

    {:ok, _view, html} = live(local_conn(), "/sympp/work-requests/#{request.id}")

    assert html =~ "Blank scope architect handoff"
    refute html =~ "Prepare architect handoff"
    refute html =~ "Private architect handoff stored"
  end

  test "local operator hides architect handoff action for WorkRequests with invalid file scope" do
    enable_operator_mode()

    request =
      Repo.insert!(%WorkRequest{
        id: "WR-OPERATOR-ARCHITECT-BAD-FILE-SCOPE",
        title: "Bad file scope architect handoff",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        work_type: "feature",
        human_description: "Stored rows with malformed file scope must not show handoff controls.",
        constraints: %{"allowed_paths" => "elixir/lib"},
        desired_dispatch_shape: "architect_led_feature_branch",
        status: "ready_for_slicing"
      })

    {:ok, _view, html} = live(local_conn(), "/sympp/work-requests/#{request.id}")

    assert html =~ "Bad file scope architect handoff"
    refute html =~ "Prepare architect handoff"
    refute html =~ "Private architect handoff stored"
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

    {:ok, _view, html} =
      conn
      |> recycle_local_browser_conn()
      |> live("/sympp/work-requests/#{request.id}")

    assert html =~ "Stale grant WorkRequest"
    assert html =~ "Answer</button>"
    assert html =~ "Close unanswered"
    assert html =~ ~s(value="local-operator")
    refute html =~ ~s(value="architect-operator")

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

  test "active local operator board route honors explicit board bearer grants" do
    enable_operator_mode()

    package = create_package!(id: "SYMPP-V2-UX-BEARER", title: "Bearer grant package")
    {grant, secret} = create_architect_grant_with_secret!(package.id)

    conn =
      local_conn()
      |> Plug.Test.init_test_session(%{"sympp_local_operator" => true})
      |> Plug.Conn.put_req_header("authorization", "Bearer #{secret}")
      |> get("/sympp/board")

    assert response(conn, 200) =~ "Work package board"
    refute response(conn, 200) =~ "Local operator cockpit"
    refute Plug.Conn.get_session(conn, "sympp_local_operator")
    assert Plug.Conn.get_session(conn, "sympp_board_grant_id") == grant.id
  end

  test "active local operator routes reject invalid explicit bearer grants" do
    enable_operator_mode()

    package = create_package!(id: "SYMPP-V2-UX-BAD-BEARER", title: "Invalid bearer package")
    invalid_secret = WorkKey.generate().secret

    board_conn =
      local_conn()
      |> Plug.Test.init_test_session(%{"sympp_local_operator" => true})
      |> Plug.Conn.put_req_header("authorization", "Bearer #{invalid_secret}")
      |> get("/sympp/board")

    assert response(board_conn, 401) =~ "The work key could not access the board."
    refute response(board_conn, 401) =~ "Local operator cockpit"

    package_conn =
      local_conn()
      |> Plug.Test.init_test_session(%{"sympp_local_operator" => true})
      |> Plug.Conn.put_req_header("authorization", "Bearer #{invalid_secret}")
      |> get("/sympp/work-packages/#{package.id}")

    assert response(package_conn, 401) =~ "The work key could not access this package."
    refute response(package_conn, 401) =~ "Invalid bearer package"
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

    create_work_request!(
      id: "WR-OPERATOR-EMPTY-STREAM",
      title: "Hidden empty stream guidance",
      repo: "nextide/symphony-plus-plus",
      base_branch: "feature/no-visible-package",
      status: "human_info_needed"
    )

    {:ok, _view, html} = live(local_conn(), "/sympp/board?repo=nextide/symphony-plus-plus")

    assert html =~ "Visible repo package"
    assert html =~ "Visible guidance request"
    refute html =~ "Hidden repo blocker"
    refute html =~ "Hidden guidance request"
    refute html =~ "Hidden empty stream guidance"
  end

  test "local operator guidance watchlist hides unsupported package kind filters" do
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
    refute html =~ "Visible kind guidance"
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

  test "local operator LiveView connection info must still be direct local" do
    enable_operator_mode()

    assert {"/live", Phoenix.LiveView.Socket, socket_opts} =
             Enum.find(SymphonyElixirWeb.Endpoint.__sockets__(), &match?({"/live", Phoenix.LiveView.Socket, _opts}, &1))

    assert get_in(socket_opts, [:websocket, :check_origin]) == :conn
    assert get_in(socket_opts, [:websocket, :check_csrf]) == true

    assert SymppDashboardApiController.local_operator_live_connect_info?(%{
             peer_data: %{address: {127, 0, 0, 1}},
             uri: URI.parse("http://127.0.0.1/sympp/board"),
             x_headers: []
           })

    refute SymppDashboardApiController.local_operator_live_connect_info?(%{
             peer_data: %{address: {10, 0, 0, 8}},
             uri: URI.parse("http://127.0.0.1/sympp/board"),
             x_headers: []
           })

    refute SymppDashboardApiController.local_operator_live_connect_info?(%{
             peer_data: %{address: {127, 0, 0, 1}},
             uri: URI.parse("http://example.com/sympp/board"),
             x_headers: []
           })

    refute SymppDashboardApiController.local_operator_live_connect_info?(%{
             peer_data: %{address: {127, 0, 0, 1}},
             uri: URI.parse("http://127.0.0.1/sympp/board"),
             x_headers: [{"x-forwarded-for", "10.0.0.8"}]
           })
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

  test "explicit work key keeps WorkRequest intake scoped after local operator entry" do
    enable_operator_mode()

    package =
      create_package!(
        id: "SYMPP-V2-UX-MIXED-SCOPE",
        title: "Mixed session package",
        repo: "nextide/scoped-package",
        base_branch: "feature/scoped-base"
      )

    {_grant, secret} = create_architect_grant_with_secret!(package.id)

    conn =
      local_conn()
      |> get("/sympp/board")

    assert response(conn, 200) =~ "Local operator cockpit"
    assert Plug.Conn.get_session(conn, "sympp_local_operator") == true

    scoped_conn =
      conn
      |> recycle()
      |> post("/sympp/board/session", %{"work_key" => secret})

    assert redirected_to(scoped_conn) == "/sympp/board"
    assert Plug.Conn.get_session(scoped_conn, "sympp_board_grant_id")
    refute Plug.Conn.get_session(scoped_conn, "sympp_local_operator")

    {:ok, view, html} = live(recycle(scoped_conn), "/sympp/work-requests/new")

    assert html =~ "New WorkRequest"
    assert html =~ "nextide/scoped-package"
    assert html =~ "feature/scoped-base"
    refute html =~ ~s(name="work_request[repo]")
    refute html =~ ~s(name="work_request[base_branch]")

    render_submit(view, "create_work_request", %{
      "work_request" => %{
        "title" => "Mixed session scoped intake",
        "work_type" => "feature",
        "desired_dispatch_shape" => "single_package",
        "human_description" => "Create through the valid grant scope.",
        "constraints_json" => ~s({"allowed_paths":["elixir/lib"]}),
        "repo" => "nextide/forged",
        "base_branch" => "forged"
      }
    })

    assert {redirected_path, _flash} = assert_redirect(view)
    created_id = redirected_path |> String.split("/") |> List.last()

    assert {:ok, created} = WorkRequestRepository.get(Repo, created_id)
    assert created.repo == "nextide/scoped-package"
    assert created.base_branch == "feature/scoped-base"
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
    assert Plug.Conn.get_session(scoped_conn, "sympp_local_operator") == true
    assert Plug.Conn.get_session(scoped_conn, "sympp_package_grant_ids") == %{package.id => grant.id}

    {:ok, _view, html} =
      local_conn()
      |> Plug.Test.init_test_session(%{"sympp_local_operator" => true, "sympp_package_grant_ids" => %{package.id => grant.id}})
      |> live("/sympp/work-packages/#{package.id}")

    assert html =~ "Cached package grant"
    refute html =~ ~s(href="?auth=work_key")
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

  defp create_human_guidance_request!(package, overrides) do
    worker_grant = create_package_grant!(package.id)
    id = Keyword.get(overrides, :id, "guidance-operator")
    blocker_id = "guidance_request:#{id}"

    assert {:ok, guidance_request} =
             GuidanceRequestRepository.create(Repo, %{
               id: id,
               work_package_id: package.id,
               requester_grant_id: worker_grant.id,
               requested_by: Keyword.get(overrides, :requested_by, "worker-operator"),
               idempotency_key: Keyword.get(overrides, :idempotency_key, "guidance-key-#{id}"),
               summary: Keyword.get(overrides, :summary, "Need product guidance"),
               question: Keyword.get(overrides, :question, "Which product behavior should this package implement?"),
               context: Keyword.get(overrides, :context, "The worker needs local human input before continuing."),
               status: "human_info_needed",
               human_info_reason: Keyword.get(overrides, :human_info_reason, "Product input is required before work can continue."),
               recommended_language: Keyword.get(overrides, :recommended_language, "Choose the package behavior before implementation continues."),
               blocker_id: blocker_id
             })

    assert {:ok, _blocker} =
             PlanningRepository.append_progress_event(Repo, %{
               work_package_id: package.id,
               summary: "Human info needed for guidance request",
               status: "blocked",
               payload: %{
                 type: "blocker",
                 source_tool: "report_blocker",
                 blocker_id: blocker_id,
                 active: true,
                 guidance_request_id: id,
                 human_info_needed: true
               }
             })

    guidance_request
  end

  defp create_architect_grant!(work_package_id) do
    {grant, _secret} = create_architect_grant_with_secret!(work_package_id)
    grant
  end

  defp create_architect_grant_with_secret!(work_package_id) do
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

    {grant, work_key.secret}
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

  defp dispatch_handoff_from_html(html) do
    %{}
    |> maybe_put("mode", dispatch_handoff_mode(html))
    |> maybe_put("target", regex_capture(html, ~r/SymphonyPlusPlus:worker:[^\s<]+/))
    |> maybe_put("path", regex_capture(html, ~r/<dt>Path<\/dt>\s*<dd class="mono">([^<]+)<\/dd>/))
  end

  defp dispatch_handoff_mode(html) do
    cond do
      html =~ "windows-credential-manager" -> "windows-credential-manager"
      html =~ "local-private-file" -> "local-private-file"
      true -> nil
    end
  end

  defp regex_capture(html, regex) do
    case Regex.run(regex, html) do
      [match] -> match
      [_match, capture] -> capture
      nil -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp cleanup_handoff(%{"mode" => _mode} = handoff) do
    SecretHandoff.delete_worker_secret(handoff, repo_root: repo_root())
  end

  defp cleanup_handoff(_handoff), do: :ok

  defp cleanup_handoff_by_grant(work_package, worker_grant) do
    SecretHandoff.delete_worker_secret_by_grant(work_package, worker_grant, local_operator_handoff_opts())
  end

  defp cleanup_architect_handoff_by_grant(work_package, architect_grant) do
    SecretHandoff.delete_worker_secret_by_grant(work_package, architect_grant, local_operator_architect_handoff_opts())
  end

  defp local_operator_handoff_opts do
    [
      repo_root: repo_root(),
      claimed_by: "local-operator-worker",
      database: Application.fetch_env!(:symphony_elixir, :sympp_repo_database)
    ]
    |> put_optional_handoff_opt(:store_dir, Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir))
  end

  defp local_operator_architect_handoff_opts do
    [
      repo_root: repo_root(),
      claimed_by: ArchitectHandoff.claimed_by(),
      database: Application.fetch_env!(:symphony_elixir, :sympp_repo_database)
    ]
    |> put_optional_handoff_opt(:store_dir, Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir))
  end

  defp assert_handoff_store_dir!(%{"path" => path}, store_dir) when is_binary(path) do
    assert String.starts_with?(path, store_dir)
  end

  defp assert_handoff_store_dir!(%{"target" => target}, _store_dir) when is_binary(target), do: :ok

  defp put_optional_handoff_opt(opts, _key, nil), do: opts
  defp put_optional_handoff_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp restore_store_dir_env(nil), do: Application.delete_env(:symphony_elixir, :sympp_worker_secret_store_dir)
  defp restore_store_dir_env(store_dir), do: Application.put_env(:symphony_elixir, :sympp_worker_secret_store_dir, store_dir)

  defp repo_root do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.join("..")
    |> Path.expand()
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

  defp recycle_local_browser_conn(conn) do
    conn
    |> recycle()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Map.put(:host, "127.0.0.1")
    |> Plug.Conn.put_req_header("sec-fetch-site", "same-origin")
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

  defp restore_custom_operator_repo_env(nil), do: Application.delete_env(:symphony_elixir, CustomOperatorRepo)

  defp restore_custom_operator_repo_env(config), do: Application.put_env(:symphony_elixir, CustomOperatorRepo, config)

  defp restore_board_live_migrated_databases(nil), do: Application.delete_env(:symphony_elixir, :sympp_board_live_migrated_databases)

  defp restore_board_live_migrated_databases(databases) do
    Application.put_env(:symphony_elixir, :sympp_board_live_migrated_databases, databases)
  end
end
