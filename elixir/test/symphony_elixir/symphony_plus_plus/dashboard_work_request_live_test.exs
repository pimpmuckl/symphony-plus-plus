defmodule SymphonyElixir.SymphonyPlusPlus.DashboardWorkRequestLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
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
  @dashboard_phase_id "phase-dashboard-work-request-live-test"

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
    Repo.delete_all(AccessGrant)
    Repo.delete_all(WorkPackage)
    Repo.delete_all(Phase)
    :ok
  end

  test "board provides a navigation path to WorkRequests" do
    anchor = create_anchor_package!()
    secret = create_architect_grant_secret(Repo, anchor.id)

    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/board")

    assert html =~ "WorkRequests"
    assert html =~ ~s(href="work-requests")
    refute html =~ ~s(href="/sympp/work-requests")
    refute html =~ ~r/<button[^>]*>\s*(Create|Dispatch|Approve|Plan)\s*<\/button>/
  end

  test "renders scoped WorkRequest list cards with counts and stable links" do
    anchor = create_anchor_package!()

    request =
      create_work_request!(
        id: "WR-LIVE-IN-SCOPE",
        title: "Read WorkRequests",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    create_work_request!(id: "WR-LIVE-OUT", repo: "nextide/other", base_branch: anchor.base_branch)

    assert {:ok, _open_question} = WorkRequestRepository.ask_question(Repo, request.id, question_attrs(id: "WRQ-LIVE-OPEN"))
    assert {:ok, _decision} = WorkRequestRepository.record_decision(Repo, request.id, decision_attrs(id: "WRD-LIVE-1"))
    assert {:ok, _slice} = WorkRequestRepository.add_planned_slice(Repo, request.id, planned_slice_attrs(id: "WRS-LIVE-1"))

    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/work-requests")

    assert html =~ "WorkRequests"
    assert html =~ "WR-LIVE-IN-SCOPE"
    assert html =~ "Read WorkRequests"
    assert html =~ "ready for slicing"
    assert html =~ "nextide/symphony-plus-plus / symphony-plus-plus/beta"
    assert html =~ ~s(href="work-requests/WR-LIVE-IN-SCOPE")
    assert html =~ ~s(href="work-requests/new")
    assert html =~ "New WorkRequest"
    assert html =~ "Open Q"
    assert html =~ "Decisions"
    assert html =~ "Slices"
    refute html =~ "WR-LIVE-OUT"
    refute html =~ ~s(method="post")
    refute html =~ ~r/<button[^>]*>/
  end

  test "encodes WorkRequest ids in list links" do
    anchor = create_anchor_package!()
    raw_id = "WR/LIVE LINK?x=1"
    create_work_request!(id: raw_id, repo: anchor.repo, base_branch: anchor.base_branch)

    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/work-requests")

    assert html =~ ~s(href="work-requests/#{path_segment(raw_id)}")
    refute html =~ ~s(href="work-requests/#{raw_id}")
    refute html =~ ~s(href="/sympp/work-requests/#{path_segment(raw_id)}")
  end

  test "renders WorkRequest detail in deterministic order" do
    anchor = create_anchor_package!()

    request =
      create_work_request!(
        id: "WR-LIVE-DETAIL",
        title: "Detail WorkRequest",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        human_description: "Review the existing read model.",
        constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false}
      )

    assert {:ok, second_question} =
             WorkRequestRepository.ask_question(Repo, request.id, question_attrs(id: "WRQ-LIVE-B", question: "Second?"))

    assert {:ok, first_question} =
             WorkRequestRepository.ask_question(Repo, request.id, question_attrs(id: "WRQ-LIVE-A", question: "First?"))

    assert {:ok, second_decision} =
             WorkRequestRepository.record_decision(Repo, request.id, decision_attrs(id: "WRD-LIVE-B", decision: "Second decision"))

    assert {:ok, first_decision} =
             WorkRequestRepository.record_decision(Repo, request.id, decision_attrs(id: "WRD-LIVE-A", decision: "First decision"))

    assert {:ok, second_slice} =
             WorkRequestRepository.add_planned_slice(Repo, request.id, planned_slice_attrs(id: "WRS-LIVE-B", title: "Second slice"))

    assert {:ok, first_slice} =
             WorkRequestRepository.add_planned_slice(
               Repo,
               request.id,
               planned_slice_attrs(
                 id: "WRS-LIVE-A",
                 title: "First slice",
                 target_base_branch: "release_candidate",
                 branch_pattern: "agent/foo_bar"
               )
             )

    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/work-requests/#{request.id}")

    assert html =~ "Detail WorkRequest"
    assert html =~ "Review the existing read model."
    assert html =~ "Constraints"
    assert html =~ "allowed_paths"
    assert html =~ "Clarification questions"
    assert html =~ "Decision log"
    assert html =~ "Planned slices"
    assert html =~ ~s(href="../board")
    assert html =~ ~s(href="../work-requests")
    assert html =~ "Mark ready for clarification"
    assert html =~ "release_candidate"
    assert html =~ "agent/foo_bar"
    refute html =~ "release candidate"
    refute html =~ "agent/foo bar"
    assert appears_before?(html, second_question.id, first_question.id)
    assert appears_before?(html, second_decision.id, first_decision.id)
    assert appears_before?(html, second_slice.id, first_slice.id)
  end

  test "renders planned-slice authoring form only for ready or sliced WorkRequests" do
    anchor = create_anchor_package!()
    draft = create_work_request!(id: "WR-LIVE-SLICE-DRAFT", repo: anchor.repo, base_branch: anchor.base_branch)
    assert {:ok, draft_slice} = WorkRequestRepository.add_planned_slice(Repo, draft.id, planned_slice_attrs(id: "WRS-LIVE-DRAFT-SLICE"))

    ready =
      create_work_request!(
        id: "WR-LIVE-SLICE-READY",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    sliced =
      create_work_request!(
        id: "WR-LIVE-SLICE-SLICED",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    secret = create_architect_grant_secret(Repo, anchor.id)

    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/work-requests/#{draft.id}")
    refute html =~ "Add planned slice"
    refute html =~ ~s(name="planned_slice[title]")
    refute html =~ ~s(name="slice[id]" value="#{draft_slice.id}")

    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/work-requests/#{ready.id}")
    assert html =~ "Add planned slice"
    assert html =~ ~s(name="planned_slice[title]")
    assert html =~ ~s(name="planned_slice[owned_file_globs]")

    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/work-requests/#{sliced.id}")
    assert html =~ "Add planned slice"
    assert html =~ ~s(name="planned_slice[title]")
  end

  test "submits planned slices through scoped detail form and refreshes counts" do
    anchor = create_anchor_package!()

    request =
      create_work_request!(
        id: "WR-LIVE-SLICE-CREATE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    package_count = Repo.aggregate(WorkPackage, :count, :id)
    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, view, html} = live(board_session_conn(secret), "/sympp/work-requests/#{request.id}")

    assert html =~ "0"
    assert html =~ "planned slices"

    html =
      render_submit(view, "add_planned_slice", %{
        "planned_slice" => %{
          "title" => " Author slice ",
          "goal" => " Let the architect persist a slice. ",
          "work_package_kind" => "dashboard",
          "target_base_branch" => anchor.base_branch,
          "branch_pattern" => " agent/SYMPP-V2-WR-008/slice-ui ",
          "owned_file_globs" => " elixir/lib/symphony_elixir_web/live/sympp_work_request_live.ex \n\n elixir/priv/static/dashboard.css ",
          "forbidden_file_globs" => "\n elixir/lib/symphony_elixir/symphony_plus_plus/mcp/** \n",
          "acceptance_criteria" => " Form creates a planned slice. \n\n Counts refresh. ",
          "validation_steps" => " mix test test/symphony_elixir/symphony_plus_plus/dashboard_work_request_live_test.exs \n",
          "review_lanes" => " review_t1 \n review_t2 \n",
          "stop_conditions" => " Stop before dispatch. \n\n"
        }
      })

    assert html =~ "Author slice"
    assert html =~ "1"
    assert html =~ "planned slices"
    assert html =~ "agent/SYMPP-V2-WR-008/slice-ui"
    assert html =~ "Stop before dispatch."
    assert Repo.aggregate(WorkPackage, :count, :id) == package_count

    assert {:ok, [planned_slice]} = WorkRequestRepository.list_planned_slices(Repo, request.id)
    assert planned_slice.sequence == 1
    assert planned_slice.status == "planned"
    assert planned_slice.title == "Author slice"
    assert planned_slice.goal == "Let the architect persist a slice."
    assert planned_slice.work_package_kind == "dashboard"
    assert planned_slice.target_base_branch == anchor.base_branch
    assert planned_slice.branch_pattern == "agent/SYMPP-V2-WR-008/slice-ui"

    assert planned_slice.owned_file_globs == [
             "elixir/lib/symphony_elixir_web/live/sympp_work_request_live.ex",
             "elixir/priv/static/dashboard.css"
           ]

    assert planned_slice.forbidden_file_globs == ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/**"]
    assert planned_slice.acceptance_criteria == ["Form creates a planned slice.", "Counts refresh."]

    assert planned_slice.validation_steps == [
             "mix test test/symphony_elixir/symphony_plus_plus/dashboard_work_request_live_test.exs"
           ]

    assert planned_slice.review_lanes == ["review_t1", "review_t2"]
    assert planned_slice.stop_conditions == ["Stop before dispatch."]
  end

  test "planned-slice approve skip and mark sliced actions are scoped and stale-safe" do
    anchor = create_anchor_package!()

    request =
      create_work_request!(
        id: "WR-LIVE-SLICE-ACTIONS",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, first} = WorkRequestRepository.add_planned_slice(Repo, request.id, planned_slice_attrs(id: "WRS-LIVE-ACTION-1"))
    assert {:ok, second} = WorkRequestRepository.add_planned_slice(Repo, request.id, planned_slice_attrs(id: "WRS-LIVE-ACTION-2", title: "Second action"))
    assert {:ok, dispatched} = WorkRequestRepository.add_planned_slice(Repo, request.id, planned_slice_attrs(id: "WRS-LIVE-ACTION-3", title: "Dispatched action"))
    dispatched = Repo.update!(Ecto.Changeset.change(dispatched, status: "dispatched"))

    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, view, html} = live(board_session_conn(secret), "/sympp/work-requests/#{request.id}")

    assert html =~ "Mark sliced"
    assert html =~ "Dispatched action"
    refute html =~ ~s(name="slice[id]" value="#{dispatched.id}")

    html =
      render_submit(view, "approve_planned_slice", %{
        "slice" => %{"id" => first.id, "current_status" => "planned"}
      })

    assert html =~ "approved"
    refute html =~ "Dispatch</button>"
    assert {:ok, [approved, ^second, ^dispatched]} = WorkRequestRepository.list_planned_slices(Repo, request.id)
    assert approved.status == "approved"

    html = render_click(view, "mark_sliced", %{})
    assert html =~ "sliced"
    assert {:ok, sliced} = WorkRequestRepository.get(Repo, request.id)
    assert sliced.status == "sliced"

    html =
      render_submit(view, "skip_planned_slice", %{
        "slice" => %{"id" => first.id, "current_status" => "approved"}
      })

    assert html =~ "A sliced WorkRequest must keep at least one approved planned slice."
    assert {:ok, [persisted_approved, ^second, ^dispatched]} = WorkRequestRepository.list_planned_slices(Repo, request.id)
    assert persisted_approved.status == "approved"

    html =
      render_submit(view, "skip_planned_slice", %{
        "slice" => %{"id" => second.id, "current_status" => "planned"}
      })

    assert html =~ "skipped"
    assert {:ok, [_approved, skipped, ^dispatched]} = WorkRequestRepository.list_planned_slices(Repo, request.id)
    assert skipped.status == "skipped"

    html =
      render_submit(view, "skip_planned_slice", %{
        "slice" => %{"id" => dispatched.id, "current_status" => "dispatched"}
      })

    assert html =~ "That action is not available from the current status."
    assert {:ok, [_approved, _skipped, persisted_dispatched]} = WorkRequestRepository.list_planned_slices(Repo, request.id)
    assert persisted_dispatched.status == "dispatched"
  end

  test "board grant hides dispatched WorkPackage linkage metadata" do
    anchor = create_anchor_package!()

    request =
      create_work_request!(
        id: "WR-LIVE-DISPATCH-LINKAGE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, slice} =
             WorkRequestRepository.add_planned_slice(
               Repo,
               request.id,
               planned_slice_attrs(id: "WRS-LIVE-DISPATCH-LINKAGE", title: "Linked dispatched action")
             )

    assert {:ok, linked_package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-LIVE-WR-DISPATCHED",
                 kind: "mcp",
                 status: "ready_for_worker",
                 repo: anchor.repo,
                 base_branch: anchor.base_branch
               )
             )

    Repo.update!(
      Ecto.Changeset.change(slice,
        status: "dispatched",
        work_package_id: linked_package.id,
        dispatched_at: DateTime.utc_now(:microsecond)
      )
    )

    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/work-requests/#{request.id}")

    assert html =~ "Linked dispatched action"
    assert html =~ "dispatched"
    refute html =~ linked_package.id
    refute html =~ "ready for worker"
  end

  test "mark sliced requires an approved planned slice" do
    anchor = create_anchor_package!()

    request =
      create_work_request!(
        id: "WR-LIVE-SLICE-GUARD",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, _planned} = WorkRequestRepository.add_planned_slice(Repo, request.id, planned_slice_attrs(id: "WRS-LIVE-SLICE-GUARD"))

    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, view, _html} = live(board_session_conn(secret), "/sympp/work-requests/#{request.id}")

    html = render_click(view, "mark_sliced", %{})
    assert html =~ "Approve at least one planned slice before marking sliced."

    assert {:ok, persisted} = WorkRequestRepository.get(Repo, request.id)
    assert persisted.status == "ready_for_slicing"
  end

  test "stale planned-slice actions render safe errors without overwriting newer state" do
    anchor = create_anchor_package!()

    request =
      create_work_request!(
        id: "WR-LIVE-SLICE-STALE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, planned} = WorkRequestRepository.add_planned_slice(Repo, request.id, planned_slice_attrs(id: "WRS-LIVE-STALE"))

    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, view, _html} = live(board_session_conn(secret), "/sympp/work-requests/#{request.id}")

    assert {:ok, _approved} = WorkRequestRepository.approve_planned_slice(Repo, request.id, planned.id, "planned")

    html =
      render_submit(view, "approve_planned_slice", %{
        "slice" => %{"id" => planned.id, "current_status" => "planned"}
      })

    assert html =~ "The WorkRequest status changed. Refresh and try again."
    assert {:ok, [persisted]} = WorkRequestRepository.list_planned_slices(Repo, request.id)
    assert persisted.status == "approved"
  end

  test "renders scoped WorkRequest intake form with locked repo and base branch" do
    anchor = create_anchor_package!()
    secret = create_architect_grant_secret(Repo, anchor.id)

    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/work-requests/new")

    assert html =~ "New WorkRequest"
    assert html =~ "Repo"
    assert html =~ "Base branch"
    assert html =~ anchor.repo
    assert html =~ anchor.base_branch
    assert html =~ "Constraints JSON"
    refute html =~ ~s(name="work_request[repo]")
    refute html =~ ~s(name="work_request[base_branch]")
  end

  test "submits valid scoped intake and ignores caller supplied repo and base branch" do
    anchor = create_anchor_package!()
    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, view, _html} = live(board_session_conn(secret), "/sympp/work-requests/new")

    render_submit(view, "create_work_request", %{
      "work_request" => %{
        "title" => "Scoped dashboard intake",
        "work_type" => "feature",
        "desired_dispatch_shape" => "single_package",
        "human_description" => "Create this from the board form.",
        "constraints_json" => ~s({"allowed_paths":["elixir/lib"],"requires_secret":false}),
        "repo" => "nextide/forged",
        "base_branch" => "forged"
      }
    })

    assert {redirected_path, _flash} = assert_redirect(view)
    assert redirected_path =~ "/sympp/work-requests/"
    created_id = redirected_path |> String.split("/") |> List.last()

    assert {:ok, created} = WorkRequestRepository.get(Repo, created_id)
    assert created.title == "Scoped dashboard intake"
    assert created.status == "draft"
    assert created.repo == anchor.repo
    assert created.base_branch == anchor.base_branch
    assert created.constraints == %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false}

    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/work-requests")
    assert html =~ "Scoped dashboard intake"
  end

  test "intake submit preserves script-name prefix in redirect" do
    assert SymphonyElixirWeb.SymppWorkRequestLive.__test_work_request_route(
             "http://www.example.com/app/sympp/work-requests/new",
             :new,
             %{},
             "WR/PREFIX"
           ) == "/app/sympp/work-requests/WR%2FPREFIX"
  end

  test "invalid intake data and invalid constraints JSON render safe errors" do
    anchor = create_anchor_package!()
    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, view, _html} = live(board_session_conn(secret), "/sympp/work-requests/new")

    html =
      render_submit(view, "create_work_request", %{
        "work_request" => %{
          "title" => "Broken constraints",
          "work_type" => "feature",
          "desired_dispatch_shape" => "single_package",
          "human_description" => "This should stay on the form.",
          "constraints_json" => "{not json"
        }
      })

    assert html =~ "Constraints must be valid JSON."
    assert html =~ "Broken constraints"

    html =
      render_submit(view, "create_work_request", %{
        "work_request" => %{
          "title" => "",
          "work_type" => "fix",
          "desired_dispatch_shape" => "single_package",
          "human_description" => "",
          "constraints_json" => "{}"
        }
      })

    assert html =~ "Check the required fields and selected values."
    refute html =~ "secret"
  end

  test "board grants without frozen scope cannot open create path" do
    anchor = create_anchor_package!()
    secret = create_legacy_phase_grant_secret(Repo, anchor.id, "grant-live-wr-legacy")

    conn = post(build_conn(), "/sympp/board/session", %{"work_key" => secret})

    assert response(conn, 403) =~ "not allowed to open the board"
  end

  test "marks draft WorkRequest ready for clarification with stale status protection" do
    anchor = create_anchor_package!()
    request = create_work_request!(id: "WR-LIVE-READY", repo: anchor.repo, base_branch: anchor.base_branch)
    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, view, html} = live(board_session_conn(secret), "/sympp/work-requests/#{request.id}")

    assert html =~ "draft"

    html = render_click(view, "mark_ready_for_clarification", %{"current-status" => "draft"})

    assert html =~ "ready for clarification"
    refute html =~ "Mark ready for clarification"
    assert {:ok, updated} = WorkRequestRepository.get(Repo, request.id)
    assert updated.status == "ready_for_clarification"
  end

  test "stale ready transition shows a safe error" do
    anchor = create_anchor_package!()
    request = create_work_request!(id: "WR-LIVE-STALE", repo: anchor.repo, base_branch: anchor.base_branch)
    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, view, html} = live(board_session_conn(secret), "/sympp/work-requests/#{request.id}")

    assert html =~ "draft"
    assert {:ok, _updated} = WorkRequestRepository.update_status(Repo, request.id, "draft", "clarifying")

    html = render_click(view, "mark_ready_for_clarification", %{"current-status" => "clarifying"})

    assert html =~ "The WorkRequest status changed. Refresh and try again."
    assert html =~ "clarifying"
    refute html =~ "raw-secret"
  end

  test "asks answers closes decisions and readiness through scoped detail actions" do
    anchor = create_anchor_package!()
    request = create_work_request!(id: "WR-LIVE-CLARIFY", repo: anchor.repo, base_branch: anchor.base_branch, status: "ready_for_clarification")
    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, view, html} = live(board_session_conn(secret), "/sympp/work-requests/#{request.id}")

    assert html =~ "Ask question"
    assert html =~ "Mark human info needed"
    assert html =~ "Mark ready for slicing"

    html =
      render_submit(view, "ask_question", %{
        "question" => %{
          "category" => "scope",
          "question" => "Which files are in scope?",
          "why_needed" => "The architect needs ownership before slicing.",
          "asked_by_agent_run_id" => "forged-run"
        }
      })

    assert html =~ "Which files are in scope?"
    assert html =~ "Answer"
    assert {:ok, clarified} = WorkRequestRepository.get(Repo, request.id)
    assert clarified.status == "clarifying"
    assert {:ok, [question]} = WorkRequestRepository.list_questions(Repo, request.id)
    assert question.status == "open"
    assert question.asked_by_agent_run_id == "architect-1"

    html = render_click(view, "mark_ready_for_slicing", %{})
    assert html =~ "Close or answer all open questions before marking ready for slicing."
    assert {:ok, still_clarifying} = WorkRequestRepository.get(Repo, request.id)
    assert still_clarifying.status == "clarifying"

    html =
      render_submit(view, "answer_question", %{
        "question" => %{
          "id" => question.id,
          "current_status" => "open",
          "answer" => "Only the assigned LiveView and docs.",
          "answered_by" => "operator-1"
        }
      })

    assert html =~ "Only the assigned LiveView and docs."
    assert {:ok, [answered]} = WorkRequestRepository.list_questions(Repo, request.id)
    assert answered.status == "answered"
    assert answered.answered_by == "operator-1"

    html =
      render_submit(view, "record_decision", %{
        "decision" => %{
          "source_type" => "human",
          "decision" => "Keep this package UI-only.",
          "rationale" => "Backend clarification APIs already exist.",
          "scope_impact" => "No MCP WorkRequest tools.",
          "created_by" => "operator-1"
        }
      })

    assert html =~ "Keep this package UI-only."
    assert {:ok, [decision]} = WorkRequestRepository.list_decisions(Repo, request.id)
    assert decision.source_type == "human"
    assert decision.created_by == "operator-1"

    html = render_click(view, "mark_human_info_needed", %{})
    assert html =~ "human info needed"
    assert {:ok, waiting} = WorkRequestRepository.get(Repo, request.id)
    assert waiting.status == "human_info_needed"

    html = render_click(view, "mark_ready_for_slicing", %{})
    assert html =~ "ready for slicing"
    assert {:ok, ready} = WorkRequestRepository.get(Repo, request.id)
    assert ready.status == "ready_for_slicing"
  end

  test "close and answer actions are stale-status-safe from the detail view" do
    anchor = create_anchor_package!()
    request = create_work_request!(id: "WR-LIVE-Q-STALE", repo: anchor.repo, base_branch: anchor.base_branch, status: "clarifying")
    assert {:ok, question} = WorkRequestRepository.ask_question(Repo, request.id, question_attrs(id: "WRQ-LIVE-Q-STALE"))
    assert {:ok, _closed} = WorkRequestRepository.close_question(Repo, question.id, "open")

    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, view, _html} = live(board_session_conn(secret), "/sympp/work-requests/#{request.id}")

    html =
      render_submit(view, "answer_question", %{
        "question" => %{
          "id" => question.id,
          "current_status" => "open",
          "answer" => "Too late.",
          "answered_by" => "operator-1"
        }
      })

    assert html =~ "That question is already closed."
    assert {:ok, [persisted]} = WorkRequestRepository.list_questions(Repo, request.id)
    assert persisted.status == "closed"
    assert persisted.answer == nil
  end

  test "first clarification question status transition rolls back when question insert fails" do
    anchor = create_anchor_package!()

    request =
      create_work_request!(
        id: "WR-LIVE-ASK-ROLLBACK",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_clarification"
      )

    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, view, _html} = live(board_session_conn(secret), "/sympp/work-requests/#{request.id}")

    html =
      render_submit(view, "ask_question", %{
        "question" => %{
          "category" => "",
          "question" => "",
          "why_needed" => ""
        }
      })

    assert html =~ "Check the required fields and selected values."
    assert {:ok, unchanged} = WorkRequestRepository.get(Repo, request.id)
    assert unchanged.status == "ready_for_clarification"
    assert {:ok, []} = WorkRequestRepository.list_questions(Repo, request.id)
  end

  test "detail actions cannot mutate out-of-scope WorkRequests" do
    anchor = create_anchor_package!()
    out_of_scope = create_work_request!(id: "WR-LIVE-HIDDEN-ACTION", repo: "nextide/other", base_branch: anchor.base_branch, status: "ready_for_clarification")

    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, view, html} = live(board_session_conn(secret), "/sympp/work-requests/#{out_of_scope.id}")
    assert html =~ "not found in this board scope"

    html =
      render_submit(view, "ask_question", %{
        "question" => %{
          "category" => "scope",
          "question" => "Should not persist?",
          "why_needed" => "Out of scope."
        }
      })

    assert html =~ "not found in this board scope"
    assert {:ok, []} = WorkRequestRepository.list_questions(Repo, out_of_scope.id)
    assert {:ok, unchanged} = WorkRequestRepository.get(Repo, out_of_scope.id)
    assert unchanged.status == "ready_for_clarification"

    html =
      render_submit(view, "add_planned_slice", %{
        "planned_slice" => %{
          "title" => "Hidden slice",
          "goal" => "Should not persist.",
          "work_package_kind" => "mcp",
          "target_base_branch" => anchor.base_branch,
          "branch_pattern" => "agent/hidden",
          "owned_file_globs" => "elixir/lib/**",
          "forbidden_file_globs" => "",
          "acceptance_criteria" => "Should not create.",
          "validation_steps" => "mix test",
          "review_lanes" => "review_t1",
          "stop_conditions" => "Stop."
        }
      })

    assert html =~ "not found in this board scope"
    assert {:ok, []} = WorkRequestRepository.list_planned_slices(Repo, out_of_scope.id)
  end

  test "detail hides out-of-scope WorkRequests as not found" do
    anchor = create_anchor_package!()
    other = create_work_request!(id: "WR-LIVE-HIDDEN", repo: "nextide/other", base_branch: anchor.base_branch)

    secret = create_architect_grant_secret(Repo, anchor.id)
    {:ok, _view, html} = live(board_session_conn(secret), "/sympp/work-requests/#{other.id}")

    assert html =~ "WorkRequest unavailable"
    assert html =~ "not found in this board scope"
    refute html =~ "WR-LIVE-HIDDEN"
  end

  test "requires board browser authorization" do
    conn = get(build_conn(), "/sympp/work-requests")

    assert response(conn, 401) =~ "Board access"
  end

  defp create_anchor_package! do
    assert {:ok, package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-LIVE-WR-ANCHOR",
                 kind: "phase_child",
                 status: "planning",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta"
               )
             )

    package
  end

  defp create_work_request!(overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(Repo, work_request_attrs(overrides))
    work_request
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-LIVE-#{System.unique_integer([:positive])}",
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
      title: "Add WorkRequest dashboard UI",
      goal: "Expose read-only browser views.",
      work_package_kind: "mcp",
      target_base_branch: "main",
      branch_pattern: "agent/SYMPP-V2-WR-005/workrequest-read-ui",
      owned_file_globs: ["elixir/lib/symphony_elixir_web/live/sympp_work_request_live.ex"],
      forbidden_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      acceptance_criteria: ["WorkRequest browser reads are scoped and redacted."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/dashboard_work_request_live_test.exs"],
      review_lanes: ["review_t1", "review_t2"],
      stop_conditions: ["Stop before authoring or dispatch wiring."]
    }

    Enum.into(overrides, defaults)
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
    work_key = WorkKey.generate()

    repo.insert!(%AccessGrant{
      id: grant_id,
      work_package_id: work_package_id,
      phase_id: nil,
      display_key: work_key.display_key,
      secret_hash: WorkKey.secret_hash(work_key.secret),
      grant_role: "architect",
      capabilities: ["read:phase"],
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600, :second)
    })

    assert {:ok, _assignment} =
             AccessGrantRepository.claim(repo, work_key.secret, %{claimed_by: "architect-legacy"}, DateTime.utc_now(:microsecond))

    work_key.secret
  end

  defp ensure_dashboard_phase(repo) do
    case PhaseRepository.get(repo, @dashboard_phase_id) do
      {:ok, phase} ->
        phase.id

      {:error, :not_found} ->
        assert {:ok, phase} = PhaseRepository.create(repo, %{id: @dashboard_phase_id, title: "Dashboard WorkRequest live test phase"})
        phase.id
    end
  end

  defp assign_existing_packages_to_phase(repo, phase_id) do
    assert {:ok, packages} = WorkPackageRepository.list(repo)

    Enum.each(packages, fn package ->
      assert {:ok, _updated} = WorkPackageRepository.update(repo, package.id, %{phase_id: phase_id})
    end)
  end

  defp board_session_conn(secret) do
    conn = post(build_conn(), "/sympp/board/session", %{"work_key" => secret})
    assert redirected_to(conn) == "/sympp/board"
    recycle(conn)
  end

  defp appears_before?(html, left, right), do: :binary.match(html, left) < :binary.match(html, right)

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

  defp restore_database_env(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_database)
  defp restore_database_env(database), do: Application.put_env(:symphony_elixir, :sympp_repo_database, database)
end
