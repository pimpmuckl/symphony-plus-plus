defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackagesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(WorkPackage)
    :ok
  end

  test "creates and fetches a standalone parentless work package", %{repo: repo} do
    assert {:ok, %WorkPackage{} = created} = Service.create(repo, WorkPackageFactory.attrs(parent_id: nil))

    assert created.id =~ "wp_"
    assert created.status == "created"
    assert created.parent_id == nil
    assert %DateTime{} = created.inserted_at
    assert %DateTime{} = created.updated_at

    assert {:ok, fetched} = Service.get(repo, created.id)
    assert fetched == created
  end

  test "lists created work packages deterministically", %{repo: repo} do
    assert {:ok, first} = Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-001-A", title: "First"))
    assert {:ok, second} = Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-001-B", title: "Second"))

    assert {:ok, [^first, ^second]} = Repository.list(repo)
  end

  test "updates fields while preserving stable id and inserted timestamp", %{repo: repo} do
    assert {:ok, created} = Repository.create(repo, WorkPackageFactory.attrs(status: "planning"))

    assert {:ok, updated} =
             Repository.update(repo, created.id, %{
               "updated_at" => ~U[2000-01-01 00:00:00Z],
               id: "ignored",
               status: "implementing",
               title: "Updated title",
               inserted_at: ~U[2000-01-01 00:00:00Z]
             })

    assert updated.id == created.id
    assert updated.inserted_at == created.inserted_at
    assert DateTime.compare(updated.updated_at, created.updated_at) != :lt
    assert updated.updated_at != ~U[2000-01-01 00:00:00Z]
    assert updated.status == "implementing"
    assert updated.title == "Updated title"
  end

  test "rejects invalid kind and status", %{repo: repo} do
    assert {:error, %Ecto.Changeset{} = kind_changeset} =
             Repository.create(repo, WorkPackageFactory.attrs(kind: "legacy_kind"))

    assert "is invalid" in errors_on(kind_changeset).kind

    assert {:ok, created} = Repository.create(repo, WorkPackageFactory.attrs())

    assert {:error, %Ecto.Changeset{} = status_changeset} =
             Repository.update(repo, created.id, %{status: "done_for_real"})

    assert "is invalid" in errors_on(status_changeset).status
  end

  test "returns not found for missing work packages", %{repo: repo} do
    assert {:error, :not_found} = Repository.get(repo, "missing")
    assert {:error, :not_found} = Repository.update(repo, "missing", %{title: "Nope"})
  end

  test "rejects duplicate caller-provided ids", %{repo: repo} do
    attrs = WorkPackageFactory.attrs(id: "SYMPP-P1-001")

    assert {:ok, package} = Repository.create(repo, attrs)
    assert package.id == "SYMPP-P1-001"
    assert {:error, :id_already_exists} = Repository.create(repo, attrs)
  end

  test "rejects nil acceptance criteria without crashing", %{repo: repo} do
    assert {:error, %Ecto.Changeset{} = changeset} =
             Repository.create(repo, WorkPackageFactory.attrs(acceptance_criteria: nil))

    assert "can't be blank" in errors_on(changeset).acceptance_criteria
  end

  test "stores acceptance criteria through SQLite", %{repo: repo} do
    criteria = ["Create package", "Fetch package"]

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-001", acceptance_criteria: criteria))

    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.acceptance_criteria == criteria
  end

  test "migration is idempotent", %{repo: repo} do
    assert :ok = Repository.migrate(repo)
  end

  test "migration marks id as not null", %{repo: repo} do
    %{rows: rows} = SQL.query!(repo, "PRAGMA table_info(sympp_work_packages)")

    assert [_cid, "id", _type, 1, _default, _primary_key] = Enum.find(rows, &(Enum.at(&1, 1) == "id"))
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
  end
end
