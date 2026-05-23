defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AgentRun)
    repo.delete_all(ProgressEvent)
    repo.delete_all(AccessGrant)
    repo.delete_all(PlannedSlice)
    repo.delete_all(WorkPackage)
    repo.delete_all(ClarificationQuestion)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "creates and fetches a draft work request", %{repo: repo} do
    assert {:ok, %WorkRequest{} = created} = Service.create(repo, attrs(constraints: nil))

    assert created.id =~ "wr_"
    assert created.status == "draft"
    assert created.constraints == %{}
    assert %DateTime{} = created.inserted_at
    assert %DateTime{} = created.updated_at
    assert created.completed_at == nil
    assert created.archived_at == nil

    assert {:ok, fetched} = Service.get(repo, created.id)
    assert fetched == created
  end

  test "lists work requests deterministically with status repo and base branch filters", %{repo: repo} do
    assert {:ok, first} =
             Repository.create(
               repo,
               attrs(
                 id: "WR-001",
                 title: "First",
                 status: "ready_for_slicing",
                 repo: "nextide/example",
                 base_branch: "main"
               )
             )

    assert {:ok, second} =
             Repository.create(
               repo,
               attrs(
                 id: "WR-002",
                 title: "Second",
                 status: "ready_for_slicing",
                 repo: "nextide/example",
                 base_branch: "main"
               )
             )

    assert {:ok, _third} =
             Repository.create(
               repo,
               attrs(
                 id: "WR-003",
                 title: "Third",
                 status: "draft",
                 repo: "nextide/example",
                 base_branch: "feature/v2"
               )
             )

    filters = %{status: "ready_for_slicing", repo: "nextide/example", base_branch: "main"}

    assert {:ok, [^first, ^second]} = Repository.list(repo, filters)
    assert {:ok, [^first, ^second]} = Service.list(repo, filters)
  end

  test "updates fields while preserving stable id and inserted timestamp", %{repo: repo} do
    assert {:ok, created} = Repository.create(repo, attrs(status: "clarifying"))

    constraints = %{
      "allowed_paths" => ["elixir/lib/symphony_elixir"],
      "stop_conditions" => %{"needs_human" => true},
      "max_review_rounds" => 2
    }

    assert {:ok, updated} =
             Repository.update(repo, created.id, %{
               "updated_at" => ~U[2000-01-01 00:00:00Z],
               id: "ignored",
               title: "Updated title",
               work_type: "investigation",
               desired_dispatch_shape: "investigation_first",
               constraints: constraints,
               completed_at: ~U[2001-01-01 00:00:00Z],
               archived_at: ~U[2001-01-02 00:00:00Z],
               inserted_at: ~U[2000-01-01 00:00:00Z]
             })

    assert updated.id == created.id
    assert updated.inserted_at == created.inserted_at
    assert DateTime.compare(updated.updated_at, created.updated_at) != :lt
    assert updated.updated_at != ~U[2000-01-01 00:00:00Z]
    assert updated.title == "Updated title"
    assert updated.work_type == "investigation"
    assert updated.desired_dispatch_shape == "investigation_first"
    assert updated.constraints == constraints
    assert updated.completed_at == nil
    assert updated.archived_at == nil

    assert {:error, %Ecto.Changeset{} = status_changeset} =
             Service.update(repo, created.id, %{status: "ready_for_slicing"})

    assert "use update_status/4 for status transitions" in errors_on(status_changeset).status

    assert {:ok, service_updated} = Service.update_status(repo, created.id, "clarifying", "ready_for_slicing")
    assert service_updated.status == "ready_for_slicing"
  end

  test "rejects invalid status work type dispatch shape and non JSON-safe constraints", %{repo: repo} do
    assert {:error, %Ecto.Changeset{} = status_changeset} = Repository.create(repo, attrs(status: "created"))
    assert "is invalid" in errors_on(status_changeset).status

    assert {:error, %Ecto.Changeset{} = work_type_changeset} = Repository.create(repo, attrs(work_type: "fix"))
    assert "is invalid" in errors_on(work_type_changeset).work_type

    assert {:error, %Ecto.Changeset{} = dispatch_shape_changeset} =
             Repository.create(repo, attrs(desired_dispatch_shape: "single package"))

    assert "is invalid" in errors_on(dispatch_shape_changeset).desired_dispatch_shape

    assert {:error, %Ecto.Changeset{} = constraints_changeset} =
             Repository.create(repo, attrs(constraints: %{secret_name: :not_json_safe}))

    assert "must be a JSON-safe map" in errors_on(constraints_changeset).constraints
  end

  test "normalizes JSON-safe constraint atom keys recursively", %{repo: repo} do
    constraints = %{
      allowed_paths: ["elixir/lib/symphony_elixir"],
      stop_conditions: %{needs_human: true},
      review: [%{lane: "normal"}]
    }

    assert {:ok, request} = Repository.create(repo, attrs(constraints: constraints))

    assert request.constraints == %{
             "allowed_paths" => ["elixir/lib/symphony_elixir"],
             "stop_conditions" => %{"needs_human" => true},
             "review" => [%{"lane" => "normal"}]
           }
  end

  test "rejects duplicate caller-provided ids", %{repo: repo} do
    attrs = attrs(id: "WR-DUPLICATE")

    assert {:ok, request} = Repository.create(repo, attrs)
    assert request.id == "WR-DUPLICATE"
    assert {:error, :id_already_exists} = Repository.create(repo, attrs)
  end

  test "updates status optimistically and distinguishes stale from missing records", %{repo: repo} do
    assert {:ok, request} = Repository.create(repo, attrs(id: "WR-STATUS"))

    assert {:ok, ready} = Service.update_status(repo, request.id, "draft", "ready_for_clarification")
    assert ready.status == "ready_for_clarification"

    assert {:error, :stale_status} =
             Repository.update_status(repo, request.id, "draft", "clarifying")

    assert {:error, :not_found} =
             Repository.update_status(repo, "WR-MISSING", "draft", "clarifying")

    assert {:error, :invalid_status} =
             Repository.update_status(repo, request.id, "draft", "ready")
  end

  test "refreshes conservative completion and archive state without changing raw status", %{repo: repo} do
    assert {:ok, request} = Repository.create(repo, attrs(id: "WR-COMPLETE", status: "ready_for_slicing"))
    assert {:ok, slice} = Repository.add_planned_slice(repo, request.id, planned_slice_attrs(id: "WRS-COMPLETE"))
    assert {:ok, _skipped} = Repository.skip_planned_slice(repo, request.id, slice.id, "planned")

    assert {:ok, completed} = Service.refresh_completion(repo, request.id)
    assert completed.status == "ready_for_slicing"
    assert %DateTime{} = completed.completed_at
    assert completed.archived_at == nil

    assert {:ok, archived} = Service.archive(repo, request.id)
    assert archived.status == "ready_for_slicing"
    assert archived.completed_at == completed.completed_at
    assert %DateTime{} = archived.archived_at
  end

  test "completion waits for questions blockers linked packages and active runtime", %{repo: repo} do
    assert {:ok, question_request} = Repository.create(repo, attrs(id: "WR-COMPLETE-QUESTION", status: "ready_for_slicing"))
    assert {:ok, question_slice} = Repository.add_planned_slice(repo, question_request.id, planned_slice_attrs(id: "WRS-COMPLETE-QUESTION"))
    assert {:ok, _skipped} = Repository.skip_planned_slice(repo, question_request.id, question_slice.id, "planned")
    assert {:ok, open_question} = Repository.ask_question(repo, question_request.id, question_attrs(id: "WRQ-COMPLETE-OPEN"))

    assert {:ok, with_question} = Service.refresh_completion(repo, question_request.id)
    assert with_question.completed_at == nil

    assert {:ok, _closed} = Repository.close_question(repo, open_question.id, "open")
    assert {:ok, without_question} = Service.refresh_completion(repo, question_request.id)
    assert %DateTime{} = without_question.completed_at

    assert {:ok, linked_request} = Repository.create(repo, attrs(id: "WR-COMPLETE-LINKED", status: "ready_for_slicing"))
    assert {:ok, planned_slice} = Repository.add_planned_slice(repo, linked_request.id, planned_slice_attrs(id: "WRS-COMPLETE-LINKED"))
    assert {:ok, approved_slice} = Repository.approve_planned_slice(repo, linked_request.id, planned_slice.id, "planned")
    linked_package = create_matching_work_package!(repo, linked_request, approved_slice, id: "WP-COMPLETE-LINKED", status: "merged")

    assert {:ok, _dispatched} = Repository.dispatch_planned_slice(repo, linked_request.id, approved_slice.id, "approved", linked_package.id)

    append_blocker_event!(repo, linked_package.id, "blocker-completion", true)
    assert {:ok, blocked} = Service.refresh_completion(repo, linked_request.id)
    assert blocked.completed_at == nil

    resolved_blocker = append_blocker_event!(repo, linked_package.id, "blocker-completion", false)
    assert {:ok, unblocked} = Service.refresh_completion(repo, linked_request.id)
    assert %DateTime{} = unblocked.completed_at
    assert DateTime.compare(unblocked.completed_at, resolved_blocker.created_at) in [:eq, :gt]

    assert {:ok, runtime_request} = Repository.create(repo, attrs(id: "WR-COMPLETE-RUNTIME", status: "ready_for_slicing"))
    assert {:ok, runtime_slice} = Repository.add_planned_slice(repo, runtime_request.id, planned_slice_attrs(id: "WRS-COMPLETE-RUNTIME"))
    assert {:ok, runtime_slice} = Repository.approve_planned_slice(repo, runtime_request.id, runtime_slice.id, "planned")
    runtime_package = create_matching_work_package!(repo, runtime_request, runtime_slice, id: "WP-COMPLETE-RUNTIME", status: "merged")

    assert {:ok, _runtime_dispatched} = Repository.dispatch_planned_slice(repo, runtime_request.id, runtime_slice.id, "approved", runtime_package.id)

    assert {:ok, run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: runtime_package.id,
               status: "running",
               attempt: 1,
               worker_task_handle: "completion-runtime"
             })

    assert {:ok, with_runtime} = Service.refresh_completion(repo, runtime_request.id)
    assert with_runtime.completed_at == nil

    assert {:ok, _completed_run} = AgentRunRepository.mark_completed(repo, run.id, "done")
    assert {:ok, without_runtime} = Service.refresh_completion(repo, runtime_request.id)
    assert %DateTime{} = without_runtime.completed_at
  end

  test "returns not found for missing work requests", %{repo: repo} do
    assert {:error, :not_found} = Repository.get(repo, "missing")
    assert {:error, :not_found} = Repository.update(repo, "missing", %{title: "Nope"})
  end

  test "migration is idempotent", %{repo: repo} do
    assert :ok = Repository.migrate(repo)
  end

  test "migration marks id as primary key and creates listing indexes", %{repo: repo} do
    %{rows: table_rows} = SQL.query!(repo, "PRAGMA table_info(sympp_work_requests)")

    assert [_cid, "id", _type, _not_null, _default, 1] = Enum.find(table_rows, &(Enum.at(&1, 1) == "id"))

    %{rows: index_rows} = SQL.query!(repo, "PRAGMA index_list(sympp_work_requests)")
    index_names = Enum.map(index_rows, &Enum.at(&1, 1))

    assert "sympp_work_requests_status_index" in index_names
    assert "sympp_work_requests_repo_base_branch_index" in index_names
    assert "sympp_work_requests_status_repo_base_branch_index" in index_names
  end

  defp attrs(overrides) do
    defaults = %{
      title: "Improve intake flow",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record the human's desired outcome before slicing.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "single_package"
    }

    Enum.into(overrides, defaults)
  end

  defp planned_slice_attrs(overrides) do
    defaults = %{
      title: "Complete WorkRequest state",
      goal: "Track completed WorkRequests.",
      work_package_kind: "mcp",
      target_base_branch: "main",
      owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: [],
      acceptance_criteria: ["Completion state is explicit."],
      validation_steps: ["mix test"],
      review_lanes: ["normal"],
      stop_conditions: []
    }

    Enum.into(overrides, defaults)
  end

  defp question_attrs(overrides) do
    defaults = %{
      category: "product",
      question: "Is the WorkRequest done?",
      why_needed: "Open human questions keep the WorkRequest visible."
    }

    Enum.into(overrides, defaults)
  end

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
      |> WorkPackageFactory.attrs()

    assert {:ok, work_package} = WorkPackageRepository.create(repo, attrs)
    work_package
  end

  defp append_blocker_event!(repo, work_package_id, blocker_id, active) do
    assert {:ok, event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package_id,
               summary: "Blocked",
               status: if(active, do: "blocked", else: "unblocked"),
               idempotency_key: "#{blocker_id}-#{active}-#{System.unique_integer([:positive])}",
               payload: %{type: "blocker", source_tool: blocker_source_tool(active), blocker_id: blocker_id, active: active}
             })

    event
  end

  defp blocker_source_tool(true), do: "report_blocker"
  defp blocker_source_tool(false), do: "resolve_blocker"

  defp database_path do
    Path.join(System.tmp_dir!(), "sympp-work-requests-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
  end
end
