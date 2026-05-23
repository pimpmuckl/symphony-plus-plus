defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackagesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.StringList
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.WorkPackageFactory

  defmodule LockedWorkPackageRepo do
    def get(_schema, _id), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  defmodule BrokenWorkPackageRepo do
    def get(_schema, _id), do: raise(%Exqlite.Error{message: "disk I/O failed"})
  end

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
    assert {:ok, [^first, ^second]} = Service.list(repo)
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

    assert {:ok, service_updated} = Service.update(repo, created.id, %{status: "ready_for_worker"})
    assert service_updated.status == "ready_for_worker"
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

  test "rejects noncanonical policy templates", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(kind: "mcp", policy_template: "mcp"))
    assert package.policy_template == "mcp"

    assert {:ok, current_pr_state_package} =
             Repository.create(repo, WorkPackageFactory.attrs(kind: "mcp", policy_template: "mcp_current_pr_state"))

    assert current_pr_state_package.policy_template == "mcp_current_pr_state"

    assert {:error, %Ecto.Changeset{} = mismatch_changeset} =
             Repository.create(repo, WorkPackageFactory.attrs(kind: "quick_fix", policy_template: "hotfix"))

    assert "is invalid" in errors_on(mismatch_changeset).policy_template

    assert {:error, %Ecto.Changeset{} = alias_changeset} =
             Repository.create(repo, WorkPackageFactory.attrs(kind: "mcp", policy_template: "worker_package"))

    assert "is invalid" in errors_on(alias_changeset).policy_template

    assert {:error, %Ecto.Changeset{} = typo_changeset} =
             Repository.create(repo, WorkPackageFactory.attrs(kind: "mcp", policy_template: "mc"))

    assert "is invalid" in errors_on(typo_changeset).policy_template

    assert {:error, %Ecto.Changeset{} = missing_kind_changeset} =
             Repository.create(repo, WorkPackageFactory.attrs(policy_template: "mcp") |> Map.delete(:kind))

    assert "can't be blank" in errors_on(missing_kind_changeset).kind
    assert "is invalid" in errors_on(missing_kind_changeset).policy_template
  end

  test "returns not found for missing work packages", %{repo: repo} do
    assert {:error, :not_found} = Repository.get(repo, "missing")
    assert {:error, :not_found} = Repository.update(repo, "missing", %{title: "Nope"})
  end

  test "repository normalizes SQLite read failures" do
    assert {:error, :database_busy} = Repository.get(LockedWorkPackageRepo, "wp-1")
    assert {:error, {:storage_failed, "disk I/O failed"}} = Repository.get(BrokenWorkPackageRepo, "wp-1")
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

  test "stores allowed file globs through SQLite", %{repo: repo} do
    globs = ["src/kraken/**", "test/kraken/**"]

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-001", allowed_file_globs: globs))

    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.allowed_file_globs == globs
  end

  test "stores nullable worktree path through SQLite", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-001"))
    assert package.worktree_path == nil

    worktree_path = Path.join(System.tmp_dir!(), "sympp-worktree-path")
    assert {:ok, updated} = Repository.update(repo, package.id, %{worktree_path: worktree_path})
    assert updated.worktree_path == worktree_path

    assert {:ok, cleared} = Repository.update(repo, package.id, %{worktree_path: nil})
    assert cleared.worktree_path == nil
  end

  test "prepares a package worktree under CODEX_HOME and replays the recorded path", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-001", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{
                 "repo_root" => fixture.repo_root,
                 "base_branch" => "main",
                 "branch" => "feat/worktree-lifecycle"
               },
               codex_home: codex_home
             )

    expected_path =
      Path.expand(
        Path.join([
          codex_home,
          "worktrees",
          "spp_worktrees",
          Path.basename(fixture.repo_root),
          "feat-worktree-lifecycle"
        ])
      )

    assert prepared.status == "prepared"
    assert prepared.worktree_path == expected_path
    assert prepared.branch == "feat/worktree-lifecycle"
    assert prepared.base_branch == "main"
    assert File.dir?(expected_path)

    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.worktree_path == expected_path

    assert {:ok, replayed} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{
                 "repo_root" => fixture.repo_root,
                 "base_branch" => "main",
                 "branch" => "feat/worktree-lifecycle"
               },
               codex_home: codex_home
             )

    assert replayed.status == "already_prepared"
    assert replayed.worktree_path == expected_path
  end

  test "cleanup refuses dirty worktrees and clears clean recorded worktrees", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-002", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup"},
               codex_home: codex_home
             )

    dirty_path = Path.join(prepared.worktree_path, "dirty.txt")
    File.write!(dirty_path, "dirty")

    assert {:error, :dirty_worktree} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
    assert {:ok, dirty_package} = Repository.get(repo, package.id)
    assert dirty_package.worktree_path == prepared.worktree_path

    File.rm!(dirty_path)

    assert {:ok, cleaned} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
    assert cleaned.status == "cleaned"
    assert cleaned.worktree_path == prepared.worktree_path
    refute File.exists?(prepared.worktree_path)

    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.worktree_path == nil

    assert {:ok, replayed} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
    assert replayed.status == "already_clean"
  end

  test "cleanup rejects recorded worktree paths outside the managed root", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WT-003",
                 kind: "mcp",
                 base_branch: "main",
                 worktree_path: Path.join(fixture.root, "outside")
               )
             )

    assert {:error, :unsafe_worktree_path} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
  end

  test "prepare rejects existing unrecorded worktree target path", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    repo_name = Path.basename(fixture.repo_root)
    existing_path = Path.join([codex_home, "worktrees", "spp_worktrees", repo_name, "feat-collision"])
    File.mkdir_p!(existing_path)

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-004", kind: "mcp", base_branch: "main"))

    assert {:error, :worktree_path_exists} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/collision"},
               codex_home: codex_home
             )
  end

  test "string list type rejects malformed values" do
    assert StringList.type() == :string
    assert StringList.embed_as(:json) == :self
    assert StringList.equal?(["a"], ["a"])

    assert StringList.cast(["a", "b"]) == {:ok, ["a", "b"]}
    assert StringList.cast(["a", 1]) == :error
    assert StringList.cast("not-list") == :error

    assert StringList.load(~s(["a","b"])) == {:ok, ["a", "b"]}
    assert StringList.load(~s(["a",1])) == :error
    assert StringList.load(~s({"not":"list"})) == :error
    assert StringList.load("not-json") == :error
    assert StringList.load(123) == :error

    assert StringList.dump(["a", "b"]) == {:ok, ~s(["a","b"])}
    assert StringList.dump(["a", 1]) == :error
    assert StringList.dump("not-list") == :error
  end

  test "migration is idempotent", %{repo: repo} do
    assert :ok = Repository.migrate(repo)
  end

  test "migration marks id as primary key", %{repo: repo} do
    %{rows: rows} = SQL.query!(repo, "PRAGMA table_info(sympp_work_packages)")

    assert [_cid, "id", _type, _not_null, _default, 1] = Enum.find(rows, &(Enum.at(&1, 1) == "id"))
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
  end
end
