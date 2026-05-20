defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestPlannedSlicesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.CreateWork
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SecretHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDispatch
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ScopeConstraints
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  defmodule RetryRepo do
    alias Ecto.Changeset

    def transaction(fun) do
      Process.put(:transaction_attempts, Process.get(:transaction_attempts, 0) + 1)

      if Process.get(:transient_error) == :database_busy and transient_failure?() do
        {:error, :database_busy}
      else
        {:ok, fun.()}
      end
    catch
      {:rollback, reason} -> {:error, reason}
    end

    def one(_query), do: 0

    def insert(%Changeset{} = changeset) do
      Process.put(:insert_attempts, Process.get(:insert_attempts, 0) + 1)

      if Process.get(:transient_error) == :sequence_conflict and transient_failure?() do
        raise %Ecto.ConstraintError{
          type: :unique,
          constraint: Process.get(:sequence_conflict_name),
          message: "sequence conflict"
        }
      else
        {:ok, Changeset.apply_changes(changeset)}
      end
    end

    def rollback(reason), do: throw({:rollback, reason})

    defp transient_failure? do
      failures_left = Process.get(:transient_failures_left, 0)

      if failures_left > 0 do
        Process.put(:transient_failures_left, failures_left - 1)
        true
      else
        false
      end
    end
  end

  setup_all do
    database_path = database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo, database_path: database_path}
  end

  setup %{repo: repo} do
    repo.delete_all(AgentRun)
    repo.delete_all(Artifact)
    repo.delete_all(ProgressEvent)
    repo.delete_all(Finding)
    repo.delete_all(PlanNode)
    repo.delete_all(AccessGrant)
    repo.delete_all(PlannedSlice)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "adds and lists planned slices deterministically", %{repo: repo} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             Service.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-002", title: "Implement persistence", review_lanes: ["normal"])
             )

    assert first.work_request_id == work_request.id
    assert first.sequence == 1
    assert first.title == "Implement persistence"
    assert first.status == "planned"
    assert first.review_lanes == ["normal"]

    assert {:ok, second} =
             Repository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-001", title: "Add validation", goal: "Reject malformed planned slices.")
             )

    assert second.sequence == 2
    assert {:ok, [^first, ^second]} = Service.list_planned_slices(repo, work_request.id)
  end

  test "gets planned slices by WorkRequest scope without leaking siblings", %{repo: repo} do
    work_request = create_work_request!(repo)
    sibling_request = create_work_request!(repo, id: "WR-SLICE-SIBLING")

    assert {:ok, planned} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-SCOPED-GET"))

    assert {:ok, ^planned} = Service.get_planned_slice(repo, work_request.id, planned.id)
    assert {:error, :not_found} = Repository.get_planned_slice(repo, sibling_request.id, planned.id)
    assert {:error, :not_found} = Service.get_planned_slice(repo, work_request.id, "WRS-MISSING")
  end

  test "validates planned-slice owned globs against persisted WorkRequest constraints", %{repo: repo} do
    work_request =
      create_work_request!(
        repo,
        constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => ["elixir/lib/test_support"]}
      )

    assert {:ok, valid} =
             Repository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-SCOPE-VALID", owned_file_globs: ["elixir/lib/*.ex"])
             )

    assert :ok = ScopeConstraints.validate_owned_file_globs(work_request, valid)

    assert {:ok, invalid} =
             Repository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-SCOPE-BLOCKED", owned_file_globs: ["elixir/lib/test_support/*.ex"])
             )

    assert {:error, [{:forbidden_path_overlap, "elixir/lib/test_support/*.ex", "elixir/lib/test_support"}]} =
             ScopeConstraints.validate_owned_file_globs(work_request, invalid)
  end

  test "approves and skips planned slices with stale status protection", %{repo: repo} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")
    assert {:ok, planned} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-STATUS"))

    assert {:ok, approved} = Service.approve_planned_slice(repo, work_request.id, planned.id, "planned")
    assert approved.status == "approved"

    assert {:error, :stale_status} = Repository.approve_planned_slice(repo, work_request.id, planned.id, "planned")

    assert {:ok, skipped} = Repository.skip_planned_slice(repo, work_request.id, approved.id, "approved")
    assert skipped.status == "skipped"

    assert {:error, :invalid_status} = Repository.skip_planned_slice(repo, work_request.id, skipped.id, "skipped")
  end

  test "does not mutate dispatched planned slices", %{repo: repo} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")
    assert {:ok, planned} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DISPATCHED"))
    dispatched = repo.update!(Ecto.Changeset.change(planned, status: "dispatched"))

    assert {:error, :invalid_status} = Repository.approve_planned_slice(repo, work_request.id, dispatched.id, "dispatched")
    assert {:error, :invalid_status} = Repository.skip_planned_slice(repo, work_request.id, dispatched.id, "dispatched")

    assert {:ok, [persisted]} = Repository.list_planned_slices(repo, work_request.id)
    assert persisted.status == "dispatched"
  end

  test "rejects planned-slice status updates outside planning WorkRequest states", %{repo: repo} do
    work_request = create_work_request!(repo, status: "clarifying")
    other = create_work_request!(repo, id: "WR-SLICE-OTHER", status: "ready_for_slicing")
    assert {:ok, planned} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-PARENT-STATUS"))

    assert {:error, :invalid_status} =
             Repository.approve_planned_slice(repo, work_request.id, planned.id, "planned")

    assert {:error, :not_found} =
             Repository.skip_planned_slice(repo, other.id, planned.id, "planned")

    assert {:ok, [persisted]} = Repository.list_planned_slices(repo, work_request.id)
    assert persisted.status == "planned"
  end

  test "marks WorkRequests sliced with approved or dispatched planned slices", %{repo: repo} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:error, :no_approved_slices} = Repository.mark_sliced(repo, work_request.id, "ready_for_slicing")

    assert {:ok, planned} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-SLICE-GUARD"))
    assert {:error, :no_approved_slices} = Repository.mark_sliced(repo, work_request.id, "ready_for_slicing")

    assert {:ok, _approved} = Repository.approve_planned_slice(repo, work_request.id, planned.id, "planned")
    assert {:ok, sliced} = Service.mark_sliced(repo, work_request.id, "ready_for_slicing")
    assert sliced.status == "sliced"

    assert {:error, :last_approved_slice} =
             Repository.skip_planned_slice(repo, work_request.id, planned.id, "approved")

    assert {:ok, [still_approved]} = Repository.list_planned_slices(repo, work_request.id)
    assert still_approved.status == "approved"

    assert {:error, :stale_status} = Repository.mark_sliced(repo, work_request.id, "ready_for_slicing")
    assert {:error, :invalid_status} = Repository.mark_sliced(repo, work_request.id, "sliced")

    dispatched_request = create_work_request!(repo, id: "WR-DISPATCHED-SLICE", status: "ready_for_slicing")

    assert {:ok, dispatched_planned} =
             Repository.add_planned_slice(repo, dispatched_request.id, planned_slice_attrs(id: "WRS-SLICE-DISPATCHED"))

    assert {:ok, dispatched_approved} =
             Repository.approve_planned_slice(repo, dispatched_request.id, dispatched_planned.id, "planned")

    dispatched_package =
      create_matching_work_package!(repo, dispatched_request, dispatched_approved, id: "SYMPP-DISPATCHED-SLICE")

    assert {:ok, dispatched} =
             Repository.dispatch_planned_slice(
               repo,
               dispatched_request.id,
               dispatched_approved.id,
               "approved",
               dispatched_package.id
             )

    assert dispatched.status == "dispatched"
    assert {:ok, sliced_from_dispatch} = Repository.mark_sliced(repo, dispatched_request.id, "ready_for_slicing")
    assert sliced_from_dispatch.status == "sliced"

    assert {:ok, extra_planned} =
             Repository.add_planned_slice(repo, dispatched_request.id, planned_slice_attrs(id: "WRS-SLICE-EXTRA"))

    assert {:ok, extra_approved} = Repository.approve_planned_slice(repo, dispatched_request.id, extra_planned.id, "planned")
    assert {:ok, skipped_extra} = Repository.skip_planned_slice(repo, dispatched_request.id, extra_approved.id, "approved")
    assert skipped_extra.status == "skipped"
  end

  test "defaults status and ignores caller-controlled sequence timestamps and linkage metadata", %{repo: repo} do
    work_request = create_work_request!(repo)
    forced_time = ~U[2000-01-01 00:00:00.000000Z]

    assert {:ok, planned_slice} =
             Repository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(
                 id: "WRS-FORCED",
                 sequence: 99,
                 inserted_at: forced_time,
                 updated_at: forced_time,
                 dispatched_at: forced_time,
                 work_package_id: "SYMPP-FORCED"
               )
             )

    assert planned_slice.sequence == 1
    assert planned_slice.status == "planned"
    assert planned_slice.work_package_id == nil
    assert planned_slice.dispatched_at == nil
    assert DateTime.compare(planned_slice.inserted_at, forced_time) == :gt
    assert DateTime.compare(planned_slice.updated_at, forced_time) == :gt
  end

  test "links approved planned slices as dispatched with WorkPackage metadata", %{repo: repo} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, planned} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DISPATCH-LINK"))
    assert {:ok, approved} = Service.approve_planned_slice(repo, work_request.id, planned.id, "planned")
    work_package = create_matching_work_package!(repo, work_request, approved, id: "SYMPP-DISPATCH-LINK")

    assert {:ok, dispatched} =
             Service.dispatch_planned_slice(repo, work_request.id, approved.id, "approved", work_package.id)

    assert dispatched.status == "dispatched"
    assert dispatched.work_package_id == work_package.id
    assert %DateTime{} = dispatched.dispatched_at

    assert {:ok, persisted} = Repository.get_planned_slice(repo, work_request.id, approved.id)
    assert persisted.status == "dispatched"
    assert persisted.work_package_id == work_package.id
    assert persisted.dispatched_at == dispatched.dispatched_at

    other_package = create_work_package!(repo, id: "SYMPP-DISPATCH-LINK-OTHER")

    assert {:error, :invalid_status} =
             Service.dispatch_planned_slice(repo, work_request.id, approved.id, "dispatched", other_package.id)
  end

  test "dispatch linkage rejects invalid WorkPackage ids and already linked WorkPackages", %{repo: repo} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first_planned} =
             Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DISPATCH-FIRST"))

    assert {:ok, first_approved} = Repository.approve_planned_slice(repo, work_request.id, first_planned.id, "planned")
    linked_package = create_matching_work_package!(repo, work_request, first_approved, id: "SYMPP-DISPATCH-USED")

    assert {:ok, _first_dispatched} =
             Repository.dispatch_planned_slice(repo, work_request.id, first_approved.id, "approved", linked_package.id)

    assert {:ok, second_planned} =
             Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DISPATCH-SECOND"))

    assert {:ok, second_approved} = Repository.approve_planned_slice(repo, work_request.id, second_planned.id, "planned")

    for invalid_work_package_id <- ["", "   ", nil] do
      assert {:error, :invalid_work_package_id} =
               Repository.dispatch_planned_slice(repo, work_request.id, second_approved.id, "approved", invalid_work_package_id)
    end

    assert {:error, :work_package_not_found} =
             Service.dispatch_planned_slice(repo, work_request.id, second_approved.id, "approved", "SYMPP-MISSING-DISPATCH")

    assert {:error, :work_package_already_linked} =
             Repository.dispatch_planned_slice(repo, work_request.id, second_approved.id, "approved", linked_package.id)

    assert {:ok, unchanged} = Repository.get_planned_slice(repo, work_request.id, second_approved.id)
    assert unchanged.status == "approved"
    assert unchanged.work_package_id == nil
    assert unchanged.dispatched_at == nil
  end

  test "dispatch linkage rejects WorkPackages outside the planned slice contract", %{repo: repo} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")
    other_request = create_work_request!(repo, id: "WR-DISPATCH-UNRELATED", repo: "nextide/other", status: "ready_for_slicing")

    assert {:ok, planned} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DISPATCH-MATCH"))
    assert {:ok, approved} = Repository.approve_planned_slice(repo, work_request.id, planned.id, "planned")

    assert {:ok, other_planned} =
             Repository.add_planned_slice(repo, other_request.id, planned_slice_attrs(id: "WRS-DISPATCH-OTHER-MATCH"))

    assert {:ok, other_approved} = Repository.approve_planned_slice(repo, other_request.id, other_planned.id, "planned")

    unrelated_package =
      create_matching_work_package!(repo, other_request, other_approved, id: "SYMPP-DISPATCH-UNRELATED")

    assert {:error, :work_package_mismatch} =
             Service.dispatch_planned_slice(repo, work_request.id, approved.id, "approved", unrelated_package.id)

    assert {:ok, unchanged} = Repository.get_planned_slice(repo, work_request.id, approved.id)
    assert unchanged.status == "approved"
    assert unchanged.work_package_id == nil
    assert unchanged.dispatched_at == nil
  end

  test "dispatch linkage rejects unsafe slice states wrong WorkRequest ids and stale updates", %{repo: repo} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")
    other_request = create_work_request!(repo, id: "WR-DISPATCH-OTHER", status: "ready_for_slicing")

    assert {:ok, planned} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DISPATCH-PLANNED"))
    work_package = create_matching_work_package!(repo, work_request, planned, id: "SYMPP-DISPATCH-REJECTIONS")

    assert {:error, :invalid_status} = Repository.dispatch_planned_slice(repo, work_request.id, planned.id, "planned", work_package.id)

    assert {:ok, skipped} = Repository.skip_planned_slice(repo, work_request.id, planned.id, "planned")
    assert {:error, :invalid_status} = Repository.dispatch_planned_slice(repo, work_request.id, skipped.id, "skipped", work_package.id)

    assert {:ok, stale_planned} =
             Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DISPATCH-STALE"))

    assert {:ok, stale_approved} = Repository.approve_planned_slice(repo, work_request.id, stale_planned.id, "planned")
    repo.update!(Ecto.Changeset.change(stale_approved, status: "skipped"))

    assert {:error, :stale_status} =
             Repository.dispatch_planned_slice(repo, work_request.id, stale_approved.id, "approved", work_package.id)

    assert {:ok, approved_planned} =
             Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DISPATCH-WRONG-WR"))

    assert {:ok, approved} = Repository.approve_planned_slice(repo, work_request.id, approved_planned.id, "planned")

    assert {:error, :not_found} =
             Repository.dispatch_planned_slice(repo, other_request.id, approved.id, "approved", work_package.id)

    assert {:ok, unchanged} = Repository.get_planned_slice(repo, work_request.id, approved.id)
    assert unchanged.status == "approved"
    assert unchanged.work_package_id == nil
  end

  test "dispatch linkage rejects every non-dispatchable parent WorkRequest status", %{repo: repo} do
    for status <- WorkRequest.statuses() -- ["ready_for_slicing", "sliced"] do
      work_request = create_work_request!(repo, id: "WR-DISPATCH-PARENT-#{status}", status: "ready_for_slicing")

      assert {:ok, planned} =
               Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DISPATCH-PARENT-#{status}"))

      assert {:ok, approved} = Repository.approve_planned_slice(repo, work_request.id, planned.id, "planned")
      work_package = create_matching_work_package!(repo, work_request, approved, id: "SYMPP-DISPATCH-PARENT-#{status}")

      repo.update!(Ecto.Changeset.change(work_request, status: status))

      assert {:error, :invalid_status} =
               Repository.dispatch_planned_slice(repo, work_request.id, approved.id, "approved", work_package.id)

      assert {:ok, unchanged} = Repository.get_planned_slice(repo, work_request.id, approved.id)
      assert unchanged.status == "approved"
      assert unchanged.work_package_id == nil
      assert unchanged.dispatched_at == nil
    end
  end

  test "dispatch linkage allows already sliced WorkRequests", %{repo: repo} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, planned} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DISPATCH-SLICED"))
    assert {:ok, approved} = Repository.approve_planned_slice(repo, work_request.id, planned.id, "planned")
    work_package = create_matching_work_package!(repo, work_request, approved, id: "SYMPP-DISPATCH-SLICED")

    assert {:ok, sliced} = Repository.mark_sliced(repo, work_request.id, "ready_for_slicing")

    assert {:ok, dispatched} = Repository.dispatch_planned_slice(repo, sliced.id, approved.id, "approved", work_package.id)
    assert dispatched.status == "dispatched"
    assert dispatched.work_package_id == work_package.id
  end

  test "dispatch orchestration creates and links one approved planned slice", %{repo: repo, database_path: database_path} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")
    assert {:ok, planned} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DISPATCH-ORCHESTRATE"))
    assert {:ok, approved} = Repository.approve_planned_slice(repo, work_request.id, planned.id, "planned")

    secret_store_dir = Path.join(System.tmp_dir!(), "sympp-dispatch-orchestrate-secrets-#{System.unique_integer([:positive])}")
    handoff_opts = dispatch_handoff_opts(database_path, secret_store_dir, "worker-dispatch-orchestrate")

    try do
      assert {:ok, dispatch} = PlannedSliceDispatch.dispatch(repo, work_request.id, approved.id, handoff_opts)
      Process.put(:dispatch_handoff, dispatch.worker_secret_handoff)

      payload = PlannedSliceDispatch.response_payload(dispatch)
      create_work = payload.create_work
      linkage = payload.planned_slice_linkage

      assert create_work.work_package.repo == work_request.repo
      assert create_work.work_package.base_branch == approved.target_base_branch
      assert create_work.work_package.title == approved.title
      assert create_work.work_package.kind == approved.work_package_kind
      assert create_work.work_package.branch_pattern == approved.branch_pattern
      assert create_work.work_package.product_description == work_request.human_description
      assert create_work.work_package.allowed_file_globs == approved.owned_file_globs
      assert create_work.work_package.acceptance_criteria == approved.acceptance_criteria
      assert create_work.work_package.engineering_scope =~ approved.goal
      assert create_work.work_package.engineering_scope =~ "Validation steps:"
      assert create_work.work_package.engineering_scope =~ "Review profiles:"
      assert create_work.work_package.engineering_scope =~ "Forbidden file globs:"
      assert create_work.work_package.engineering_scope =~ "Stop conditions:"

      refute Map.has_key?(create_work.worker_grant, :secret)
      assert create_work.secret_in_stdout == false
      assert create_work.worker_grant.secret_handoff.target == create_work.worker_secret_handoff.target

      assert linkage.work_request_id == work_request.id
      assert linkage.planned_slice_id == approved.id
      assert linkage.status == "dispatched"
      assert linkage.work_package_id == create_work.work_package.id
      assert is_binary(linkage.dispatched_at)

      assert {:ok, persisted} = Repository.get_planned_slice(repo, work_request.id, approved.id)
      assert persisted.status == "dispatched"
      assert persisted.work_package_id == create_work.work_package.id
    after
      cleanup_handoff(Process.get(:dispatch_handoff), handoff_opts)
      File.rm_rf(secret_store_dir)
      Process.delete(:dispatch_handoff)
    end
  end

  test "dispatch orchestration rejects preflight failures without mutation", %{repo: repo, database_path: database_path} do
    invalid_scope_request =
      create_work_request!(
        repo,
        id: "WR-DISPATCH-SCOPE-REJECT",
        status: "ready_for_slicing",
        constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests"]}
      )

    assert {:ok, invalid_scope_planned} =
             Repository.add_planned_slice(
               repo,
               invalid_scope_request.id,
               planned_slice_attrs(id: "WRS-DISPATCH-SCOPE-REJECT")
             )

    assert {:ok, invalid_scope_approved} =
             Repository.approve_planned_slice(repo, invalid_scope_request.id, invalid_scope_planned.id, "planned")

    invalid_create_request = create_work_request!(repo, id: "WR-DISPATCH-CREATE-REJECT", status: "ready_for_slicing")

    assert {:ok, invalid_create_planned} =
             Repository.add_planned_slice(
               repo,
               invalid_create_request.id,
               planned_slice_attrs(id: "WRS-DISPATCH-CREATE-REJECT", owned_file_globs: [], acceptance_criteria: [])
             )

    assert {:ok, invalid_create_approved} =
             Repository.approve_planned_slice(repo, invalid_create_request.id, invalid_create_planned.id, "planned")

    unsupported_request = create_work_request!(repo, id: "WR-DISPATCH-KIND-REJECT", status: "ready_for_slicing")

    assert {:ok, unsupported_planned} =
             Repository.add_planned_slice(
               repo,
               unsupported_request.id,
               planned_slice_attrs(id: "WRS-DISPATCH-KIND-REJECT", work_package_kind: "docs")
             )

    assert {:ok, unsupported_approved} =
             Repository.approve_planned_slice(repo, unsupported_request.id, unsupported_planned.id, "planned")

    planned_request = create_work_request!(repo, id: "WR-DISPATCH-PLANNED-REJECT", status: "ready_for_slicing")
    assert {:ok, planned_slice} = Repository.add_planned_slice(repo, planned_request.id, planned_slice_attrs(id: "WRS-DISPATCH-PLANNED-REJECT"))

    secret_store_dir = Path.join(System.tmp_dir!(), "sympp-dispatch-reject-secrets-#{System.unique_integer([:positive])}")
    handoff_opts = dispatch_handoff_opts(database_path, secret_store_dir, "worker-dispatch-reject")

    try do
      assert {:error, :not_found} = PlannedSliceDispatch.dispatch(repo, "WR-MISSING", "WRS-MISSING", handoff_opts)

      assert {:error, {:invalid_planned_slice_status, "planned"}} =
               PlannedSliceDispatch.dispatch(repo, planned_request.id, planned_slice.id, handoff_opts)

      assert {:error, {:planned_slice_scope_violation, [_ | _]}} =
               PlannedSliceDispatch.dispatch(repo, invalid_scope_request.id, invalid_scope_approved.id, handoff_opts)

      assert {:error, :missing_acceptance_criteria} =
               PlannedSliceDispatch.dispatch(repo, invalid_create_request.id, invalid_create_approved.id, handoff_opts)

      assert {:error, {:unsupported_standalone_kind, "docs"}} =
               PlannedSliceDispatch.dispatch(repo, unsupported_request.id, unsupported_approved.id, handoff_opts)

      assert repo.aggregate(WorkPackage, :count, :id) == 0
      assert repo.aggregate(AccessGrant, :count, :id) == 0
      refute File.exists?(secret_store_dir)
    after
      File.rm_rf(secret_store_dir)
    end
  end

  test "dispatch orchestration cleans up created work when linkage fails", %{repo: repo, database_path: database_path} do
    work_request = create_work_request!(repo, id: "WR-DISPATCH-LINK-ROLLBACK", status: "ready_for_slicing")
    assert {:ok, planned} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DISPATCH-LINK-ROLLBACK"))
    assert {:ok, approved} = Repository.approve_planned_slice(repo, work_request.id, planned.id, "planned")

    secret_store_dir = Path.join(System.tmp_dir!(), "sympp-dispatch-link-rollback-secrets-#{System.unique_integer([:positive])}")
    handoff_opts = dispatch_handoff_opts(database_path, secret_store_dir, "worker-dispatch-link-rollback")

    try do
      assert {:error, {:dispatch_link_failed, :forced_link_failure, recovery}} =
               PlannedSliceDispatch.dispatch(repo, work_request.id, approved.id, handoff_opts,
                 link_planned_slice: fn _repo, _work_request_id, _planned_slice_id, "approved", _work_package_id ->
                   {:error, :forced_link_failure}
                 end,
                 cleanup_created_work_package: fn cleanup_repo, work_package_id ->
                   assert :ok = CreateWork.cleanup_created_work_package(cleanup_repo, work_package_id)
                   {:ok, :deleted}
                 end
               )

      assert recovery.cleanup == %{ledger: :deleted, secret_handoff: :deleted}
      assert recovery.work_package_id
      assert recovery.worker_grant_id
      assert recovery.worker_secret_handoff.secret_in_stdout == false
      assert repo.aggregate(WorkPackage, :count, :id) == 0
      assert repo.aggregate(AccessGrant, :count, :id) == 0

      if recovery.worker_secret_handoff.mode == "local-private-file" do
        refute File.exists?(recovery.worker_secret_handoff.path)
      end

      assert Path.wildcard(Path.join([secret_store_dir, "metadata", "*.json"])) == []
    after
      File.rm_rf(secret_store_dir)
    end
  end

  test "dispatch orchestration cleans up created work when linkage raises", %{repo: repo, database_path: database_path} do
    work_request = create_work_request!(repo, id: "WR-DISPATCH-LINK-RAISE", status: "ready_for_slicing")
    assert {:ok, planned} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DISPATCH-LINK-RAISE"))
    assert {:ok, approved} = Repository.approve_planned_slice(repo, work_request.id, planned.id, "planned")

    secret_store_dir = Path.join(System.tmp_dir!(), "sympp-dispatch-link-raise-secrets-#{System.unique_integer([:positive])}")
    handoff_opts = dispatch_handoff_opts(database_path, secret_store_dir, "worker-dispatch-link-raise")

    try do
      assert {:error, {:dispatch_link_failed, {:link_failed, "forced link exception"}, recovery}} =
               PlannedSliceDispatch.dispatch(repo, work_request.id, approved.id, handoff_opts,
                 link_planned_slice: fn _repo, _work_request_id, _planned_slice_id, "approved", _work_package_id ->
                   raise "forced link exception"
                 end
               )

      assert recovery.cleanup == %{ledger: :deleted, secret_handoff: :deleted}
      assert repo.aggregate(WorkPackage, :count, :id) == 0
      assert repo.aggregate(AccessGrant, :count, :id) == 0

      if recovery.worker_secret_handoff.mode == "local-private-file" do
        refute File.exists?(recovery.worker_secret_handoff.path)
      end

      assert Path.wildcard(Path.join([secret_store_dir, "metadata", "*.json"])) == []
    after
      File.rm_rf(secret_store_dir)
    end
  end

  test "dispatch link cleanup keeps the legacy secret delete fallback injectable", %{
    repo: repo,
    database_path: database_path
  } do
    work_request = create_work_request!(repo, id: "WR-DISPATCH-LINK-FALLBACK", status: "ready_for_slicing")

    assert {:ok, planned} =
             Repository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-DISPATCH-LINK-FALLBACK")
             )

    assert {:ok, approved} = Repository.approve_planned_slice(repo, work_request.id, planned.id, "planned")

    secret_store_dir =
      Path.join(System.tmp_dir!(), "sympp-dispatch-link-fallback-secrets-#{System.unique_integer([:positive])}")

    handoff_opts = dispatch_handoff_opts(database_path, secret_store_dir, "worker-dispatch-link-fallback")
    parent = self()

    try do
      assert {:error, {:dispatch_link_failed, :forced_link_failure, recovery}} =
               PlannedSliceDispatch.dispatch(repo, work_request.id, approved.id, handoff_opts,
                 link_planned_slice: fn _repo, _work_request_id, _planned_slice_id, "approved", _work_package_id ->
                   {:error, :forced_link_failure}
                 end,
                 delete_worker_secret_by_grant: fn _work_package, _grant, _handoff_opts ->
                   {:error, :managed_cleanup_failed}
                 end,
                 delete_worker_secret: fn handoff, fallback_handoff_opts ->
                   send(parent, {:fallback_secret_delete, handoff.mode})
                   SecretHandoff.delete_worker_secret(handoff, fallback_handoff_opts)
                 end
               )

      assert_receive {:fallback_secret_delete, _mode}

      assert recovery.cleanup == %{
               ledger: :deleted,
               secret_handoff: {:cleanup_failed, :managed_cleanup_failed},
               fallback_secret_handoff: :deleted
             }

      assert repo.aggregate(WorkPackage, :count, :id) == 0
      assert repo.aggregate(AccessGrant, :count, :id) == 0
    after
      File.rm_rf(secret_store_dir)
    end
  end

  test "rejects invalid status work package kind and list fields", %{repo: repo} do
    work_request = create_work_request!(repo)

    assert {:error, %Ecto.Changeset{} = status_changeset} =
             Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(status: "open"))

    assert "is invalid" in errors_on(status_changeset).status

    assert {:error, %Ecto.Changeset{} = dispatched_changeset} =
             Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(status: "dispatched"))

    assert "must be planned on create" in errors_on(dispatched_changeset).status

    assert {:error, %Ecto.Changeset{} = kind_changeset} =
             Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(work_package_kind: "side_quest"))

    assert "is invalid" in errors_on(kind_changeset).work_package_kind

    assert {:error, %Ecto.Changeset{} = list_changeset} =
             Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(owned_file_globs: ["elixir/lib", :not_json]))

    assert "is invalid" in errors_on(list_changeset).owned_file_globs

    assert {:error, %Ecto.Changeset{} = non_list_changeset} =
             Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(review_lanes: "normal"))

    assert "is invalid" in errors_on(non_list_changeset).review_lanes
  end

  test "rejects duplicate ids and missing WorkRequest foreign keys", %{repo: repo} do
    work_request = create_work_request!(repo)

    assert {:ok, planned_slice} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DUPLICATE"))
    assert planned_slice.id == "WRS-DUPLICATE"

    assert {:error, :id_already_exists} =
             Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(id: "WRS-DUPLICATE"))

    assert {:error, {:constraint_failed, "foreign_key"}} =
             Repository.add_planned_slice(repo, "WR-MISSING", planned_slice_attrs(id: "WRS-MISSING-PARENT"))
  end

  test "retries planned slice sequence conflicts and database busy responses" do
    with_sequence_retry_attempts(5, fn ->
      assert {{:ok, %PlannedSlice{} = planned_slice}, transaction_attempts, insert_attempts} =
               with_transient_failures(
                 :sequence_conflict,
                 3,
                 [constraint: "sympp_work_request_planned_slices_work_request_sequence_unique_index"],
                 fn ->
                   Repository.add_planned_slice(RetryRepo, "WR-RETRY", planned_slice_attrs(id: "WRS-RETRY"))
                 end
               )

      assert planned_slice.id == "WRS-RETRY"
      assert planned_slice.sequence == 1
      assert transaction_attempts == 4
      assert insert_attempts == 4

      assert {{:ok, %PlannedSlice{} = busy_planned_slice}, transaction_attempts, insert_attempts} =
               with_transient_failures(:database_busy, 2, [], fn ->
                 Repository.add_planned_slice(RetryRepo, "WR-RETRY", planned_slice_attrs(id: "WRS-BUSY-RETRY"))
               end)

      assert busy_planned_slice.id == "WRS-BUSY-RETRY"
      assert busy_planned_slice.sequence == 1
      assert transaction_attempts == 3
      assert insert_attempts == 1
    end)
  end

  test "returns explicit terminal errors after exhausting planned slice sequence retries" do
    with_sequence_retry_attempts(2, fn ->
      assert {{:error, :sequence_conflict}, transaction_attempts, insert_attempts} =
               with_transient_failures(
                 :sequence_conflict,
                 3,
                 [constraint: "sympp_work_request_planned_slices_work_request_sequence_unique_index"],
                 fn ->
                   Repository.add_planned_slice(RetryRepo, "WR-EXHAUSTED", planned_slice_attrs(id: "WRS-EXHAUSTED"))
                 end
               )

      assert transaction_attempts == 3
      assert insert_attempts == 3

      assert {{:error, :database_busy}, transaction_attempts, insert_attempts} =
               with_transient_failures(:database_busy, 3, [], fn ->
                 Repository.add_planned_slice(RetryRepo, "WR-EXHAUSTED", planned_slice_attrs(id: "WRS-BUSY-EXHAUSTED"))
               end)

      assert transaction_attempts == 3
      assert insert_attempts == 0
    end)
  end

  test "deleting a WorkRequest deletes planned slices", %{repo: repo} do
    work_request = create_work_request!(repo)
    assert {:ok, _planned_slice} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs())

    repo.delete!(work_request)

    assert {:ok, []} = Repository.list_planned_slices(repo, work_request.id)
  end

  test "migration is idempotent and creates planned slice fields and indexes", %{repo: repo} do
    assert :ok = Repository.migrate(repo)

    assert_primary_key(repo, "sympp_work_request_planned_slices")

    columns = column_names(repo, "sympp_work_request_planned_slices")

    for column <- [
          "work_request_id",
          "sequence",
          "title",
          "goal",
          "work_package_kind",
          "target_base_branch",
          "branch_pattern",
          "owned_file_globs",
          "forbidden_file_globs",
          "acceptance_criteria",
          "validation_steps",
          "review_lanes",
          "stop_conditions",
          "status",
          "work_package_id",
          "dispatched_at",
          "inserted_at",
          "updated_at"
        ] do
      assert column in columns
    end

    assert Enum.any?(foreign_keys(repo, "sympp_work_request_planned_slices"), fn row ->
             Enum.at(row, 2) == "sympp_work_packages" and Enum.at(row, 3) == "work_package_id" and Enum.at(row, 4) == "id"
           end)

    indexes = index_names(repo, "sympp_work_request_planned_slices")

    assert "sympp_work_request_planned_slices_id_unique_index" in indexes
    assert "sympp_work_request_planned_slices_work_request_sequence_unique_index" in indexes
    assert "sympp_work_request_planned_slices_work_request_status_index" in indexes
    assert "sympp_work_request_planned_slices_work_package_id_unique_index" in indexes
    assert index_partial?(repo, "sympp_work_request_planned_slices", "sympp_work_request_planned_slices_work_package_id_unique_index")
  end

  defp create_work_request!(repo, overrides \\ []) do
    assert {:ok, work_request} = Repository.create(repo, work_request_attrs(overrides))
    work_request
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

  defp dispatch_handoff_opts(database_path, secret_store_dir, claimed_by) do
    [
      mode: "auto",
      store_dir: secret_store_dir,
      claimed_by: claimed_by,
      database: database_path,
      repo_root: repo_root()
    ]
  end

  defp cleanup_handoff(nil, _handoff_opts), do: :ok

  defp cleanup_handoff(handoff, handoff_opts) when is_map(handoff) and is_list(handoff_opts) do
    SecretHandoff.delete_worker_secret(handoff, handoff_opts)
  end

  defp repo_root do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.join("..")
    |> Path.expand()
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-#{System.unique_integer([:positive])}",
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

  defp planned_slice_attrs(overrides \\ []) do
    defaults = %{
      title: "Add WorkRequest planned-slice persistence",
      goal: "Persist the slice candidate before WorkPackage dispatch.",
      work_package_kind: "mcp",
      target_base_branch: "main",
      branch_pattern: "agent/SYMPP-V2-WR-003/planned-slices-core",
      owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/*.ex"],
      forbidden_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/**"],
      acceptance_criteria: ["Planned slices persist and list in sequence order."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/work_request_planned_slices_test.exs"],
      review_lanes: ["normal"],
      stop_conditions: ["Stop before dashboard or MCP tool wiring."]
    }

    Enum.into(overrides, defaults)
  end

  defp with_sequence_retry_attempts(attempts, fun) do
    key = :sympp_work_request_sequence_retry_attempts
    previous = Application.get_env(:symphony_elixir, key)
    Application.put_env(:symphony_elixir, key, attempts)

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, key)
      else
        Application.put_env(:symphony_elixir, key, previous)
      end
    end
  end

  defp with_transient_failures(kind, count, opts, fun) do
    Process.put(:transient_error, kind)
    Process.put(:transient_failures_left, count)
    Process.put(:sequence_conflict_name, Keyword.get(opts, :constraint))
    Process.put(:transaction_attempts, 0)
    Process.put(:insert_attempts, 0)

    try do
      {fun.(), Process.get(:transaction_attempts), Process.get(:insert_attempts)}
    after
      Process.delete(:transient_error)
      Process.delete(:transient_failures_left)
      Process.delete(:sequence_conflict_name)
      Process.delete(:transaction_attempts)
      Process.delete(:insert_attempts)
    end
  end

  defp assert_primary_key(repo, table) do
    %{rows: table_rows} = SQL.query!(repo, "PRAGMA table_info(#{table})")
    assert [_cid, "id", _type, _not_null, _default, 1] = Enum.find(table_rows, &(Enum.at(&1, 1) == "id"))
  end

  defp column_names(repo, table) do
    %{rows: table_rows} = SQL.query!(repo, "PRAGMA table_info(#{table})")
    Enum.map(table_rows, &Enum.at(&1, 1))
  end

  defp foreign_keys(repo, table) do
    %{rows: foreign_key_rows} = SQL.query!(repo, "PRAGMA foreign_key_list(#{table})")
    foreign_key_rows
  end

  defp index_names(repo, table) do
    %{rows: index_rows} = SQL.query!(repo, "PRAGMA index_list(#{table})")
    Enum.map(index_rows, &Enum.at(&1, 1))
  end

  defp index_partial?(repo, table, index_name) do
    %{rows: index_rows} = SQL.query!(repo, "PRAGMA index_list(#{table})")

    Enum.any?(index_rows, fn row ->
      Enum.at(row, 1) == index_name and Enum.at(row, 4) == 1
    end)
  end

  defp database_path do
    Path.join(
      System.tmp_dir!(),
      "sympp-work-request-planned-slices-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3"
    )
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
  end
end
