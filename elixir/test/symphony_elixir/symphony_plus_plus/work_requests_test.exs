defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  setup_all do
    database_path = database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
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
