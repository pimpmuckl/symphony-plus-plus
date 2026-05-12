defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestPlannedSlicesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ScopeConstraints
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

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

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(PlannedSlice)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "adds and lists planned slices deterministically", %{repo: repo} do
    work_request = create_work_request!(repo)

    assert {:ok, first} =
             Service.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-002", title: "Implement persistence", review_lanes: ["review_t1", "review_t2"])
             )

    assert first.work_request_id == work_request.id
    assert first.sequence == 1
    assert first.title == "Implement persistence"
    assert first.status == "planned"
    assert first.review_lanes == ["review_t1", "review_t2"]

    assert {:ok, second} =
             Repository.add_planned_slice(
               repo,
               work_request.id,
               planned_slice_attrs(id: "WRS-001", title: "Add validation", goal: "Reject malformed planned slices.")
             )

    assert second.sequence == 2
    assert {:ok, [^first, ^second]} = Service.list_planned_slices(repo, work_request.id)
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

  test "marks WorkRequests sliced only with an approved planned slice", %{repo: repo} do
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
    assert DateTime.compare(planned_slice.inserted_at, forced_time) == :gt
    assert DateTime.compare(planned_slice.updated_at, forced_time) == :gt
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
             Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(review_lanes: "review_t1"))

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
          "inserted_at",
          "updated_at"
        ] do
      assert column in columns
    end

    indexes = index_names(repo, "sympp_work_request_planned_slices")

    assert "sympp_work_request_planned_slices_id_unique_index" in indexes
    assert "sympp_work_request_planned_slices_work_request_sequence_unique_index" in indexes
    assert "sympp_work_request_planned_slices_work_request_status_index" in indexes
  end

  defp create_work_request!(repo, overrides \\ []) do
    assert {:ok, work_request} = Repository.create(repo, work_request_attrs(overrides))
    work_request
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
      review_lanes: ["review_t1", "review_t2"],
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

  defp index_names(repo, table) do
    %{rows: index_rows} = SQL.query!(repo, "PRAGMA index_list(#{table})")
    Enum.map(index_rows, &Enum.at(&1, 1))
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
