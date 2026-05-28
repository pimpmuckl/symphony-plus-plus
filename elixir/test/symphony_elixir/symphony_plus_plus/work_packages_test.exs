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

  defmodule UpdateFailsWorkPackageRepo do
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def get(schema, id), do: Repo.get(schema, id)
    def update(_changeset), do: raise(%Exqlite.Error{message: "database is locked"})
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

    expected_root =
      Path.expand(
        Path.join([
          codex_home,
          "worktrees",
          "spp_worktrees"
        ])
      )

    assert prepared.status == "prepared"
    assert String.starts_with?(prepared.worktree_path, expected_root)
    assert prepared.worktree_path =~ "SYMPP-WT-001"
    assert prepared.branch == "feat/worktree-lifecycle"
    assert prepared.base_branch == "main"
    assert File.dir?(prepared.worktree_path)

    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.worktree_path == prepared.worktree_path

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
    assert replayed.worktree_path == prepared.worktree_path
  end

  test "prepare keeps generated worktree paths compact for long ids and branches", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    long_id = "SYMPP-WT-LONG-" <> String.duplicate("PACKAGE-", 8)
    long_branch = "feat/" <> String.duplicate("very-long-worktree-branch-", 5) <> "tail"

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: long_id, kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => long_branch},
               codex_home: codex_home
             )

    assert {:ok, worktree_root} = WorktreeLifecycle.worktree_root(codex_home: codex_home)
    relative_path = Path.relative_to(prepared.worktree_path, worktree_root)

    assert String.length(relative_path) <= 80
    refute prepared.worktree_path =~ String.replace(long_branch, "/", "-")
    assert File.dir?(prepared.worktree_path)
  end

  test "prepare replays legacy recorded managed worktree paths", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    package_id = "SYMPP-WT-LEGACY-001"
    branch = "feat/legacy-prepare-replay"

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: package_id, kind: "mcp", base_branch: "main"))

    legacy_path = legacy_worktree_path(codex_home, fixture.repo_root, package.id, branch)
    File.mkdir_p!(Path.dirname(legacy_path))
    TestSupport.git_output!(fixture.repo_root, ["worktree", "add", "-b", branch, legacy_path, "origin/main"])

    assert {:ok, _updated} = Repository.update(repo, package.id, %{worktree_path: legacy_path})

    assert {:ok, replayed} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => branch},
               codex_home: codex_home
             )

    assert replayed.status == "already_prepared"
    assert replayed.worktree_path == Path.expand(legacy_path)
    assert File.dir?(legacy_path)
  end

  test "prepare rejects legacy recorded managed paths for a different branch", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    package_id = "SYMPP-WT-LEGACY-BRANCH"
    recorded_branch = "feat/legacy-recorded"
    requested_branch = "feat/legacy-requested"

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: package_id, kind: "mcp", base_branch: "main"))

    legacy_path = legacy_worktree_path(codex_home, fixture.repo_root, package.id, recorded_branch)
    File.mkdir_p!(Path.dirname(legacy_path))
    TestSupport.git_output!(fixture.repo_root, ["worktree", "add", "-b", recorded_branch, legacy_path, "origin/main"])

    assert {:ok, _updated} = Repository.update(repo, package.id, %{worktree_path: legacy_path})

    assert {:error, {:worktree_path_already_recorded, recorded_path}} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => requested_branch},
               codex_home: codex_home
             )

    assert recorded_path == Path.expand(legacy_path)
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

    assert {:ok, cleaned} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)
    assert cleaned.status == "cleaned"
    assert cleaned.worktree_path == prepared.worktree_path
    refute File.exists?(prepared.worktree_path)

    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.worktree_path == nil

    assert {:ok, replayed} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
    assert replayed.status == "already_clean"

    assert {:ok, prepared_again} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup"},
               codex_home: codex_home
             )

    assert prepared_again.status == "prepared"
    assert File.dir?(prepared_again.worktree_path)
  end

  test "cleanup recovers a stale recorded path after persistence failure", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-005", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup-persistence"},
               codex_home: codex_home
             )

    assert {:error, :database_busy} =
             WorktreeLifecycle.cleanup(UpdateFailsWorkPackageRepo, package.id,
               codex_home: codex_home,
               repo_root: fixture.repo_root
             )

    refute File.exists?(prepared.worktree_path)

    assert {:ok, fetched} = Repository.get(repo, package.id)
    assert fetched.worktree_path == prepared.worktree_path

    assert {:ok, recovered} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)
    assert recovered.status == "stale_record_cleared"

    assert {:ok, cleared} = Repository.get(repo, package.id)
    assert cleared.worktree_path == nil
  end

  test "prepare prunes stale git worktree metadata after missing-path cleanup", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-011", kind: "mcp", base_branch: "main"))

    attrs = %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/stale-prune"}

    assert {:ok, prepared} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)

    File.rm_rf!(prepared.worktree_path)

    assert normalized_path(TestSupport.git_output!(fixture.repo_root, ["worktree", "list", "--porcelain"])) =~
             normalized_path(prepared.worktree_path)

    assert {:ok, recovered} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)
    assert recovered.status == "stale_record_cleared"

    refute normalized_path(TestSupport.git_output!(fixture.repo_root, ["worktree", "list", "--porcelain"])) =~
             normalized_path(prepared.worktree_path)

    assert {:ok, prepared_again} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)
    assert prepared_again.status == "prepared"
    assert prepared_again.worktree_path == prepared.worktree_path
    assert File.dir?(prepared_again.worktree_path)
  end

  test "prepare returns sanitized git command failures", %{repo: repo} do
    non_repo_root =
      Path.join(System.tmp_dir!(), "sympp-worktree-secret-token-#{System.unique_integer([:positive])}")

    File.mkdir_p!(non_repo_root)
    on_exit(fn -> File.rm_rf(non_repo_root) end)

    sensitive_ref = "raw_secret_abcd1234"
    base_branch = "main-#{sensitive_ref}"
    branch = "feat/#{sensitive_ref}"

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-012", kind: "mcp", base_branch: base_branch))

    attrs = %{"target_repo_root" => non_repo_root, "base_branch" => base_branch, "branch" => branch}

    assert {:error, {:git_failed, status, details} = reason} =
             WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: Path.join(non_repo_root, "codex-home"))

    assert is_integer(status)
    assert details.status == status
    assert details.target_repo_root == "[REDACTED]"
    assert details.base_branch == "main-[REDACTED]"
    assert details.branch == "feat/[REDACTED]"
    assert is_binary(details.stderr)
    assert details.stderr =~ "fatal"
    refute inspect(details.git_args) =~ sensitive_ref
    refute inspect(reason) =~ "secret-token"
    refute inspect(reason) =~ sensitive_ref
  end

  test "cleanup rejects worktrees that belong to another repository", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    other_fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle-other")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-014", kind: "mcp", base_branch: "main"))

    assert {:ok, other_package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-015", kind: "mcp", base_branch: "main"))

    assert {:ok, other_prepared} =
             WorktreeLifecycle.prepare(
               repo,
               other_package.id,
               %{"repo_root" => other_fixture.repo_root, "base_branch" => "main", "branch" => "feat/other-repo"},
               codex_home: codex_home
             )

    assert {:ok, _corrupted} = Repository.update(repo, package.id, %{worktree_path: other_prepared.worktree_path})

    assert {:error, :invalid_worktree_path} =
             WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)

    assert File.dir?(other_prepared.worktree_path)
    assert {:ok, recorded} = Repository.get(repo, package.id)
    assert recorded.worktree_path == other_prepared.worktree_path
  end

  test "cleanup rejects same-origin clones that do not own the recorded worktree", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    second_clone_root = TestSupport.git_repo_with_origin_fixture!(fixture.origin, prefix: "sympp-worktree-second-clone")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-016", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/clone-owner"},
               codex_home: codex_home
             )

    assert {:error, :invalid_worktree_path} =
             WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: second_clone_root)

    assert File.dir?(prepared.worktree_path)
    assert {:ok, recorded} = Repository.get(repo, package.id)
    assert recorded.worktree_path == prepared.worktree_path
  end

  test "cleanup rejects missing recorded paths from same-origin non-owning clones", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    second_clone_parent = Path.join(fixture.root, "same-name-second-clone")
    second_clone_root = Path.join(second_clone_parent, Path.basename(fixture.repo_root))
    File.mkdir_p!(second_clone_parent)
    TestSupport.git_output!(fixture.root, ["clone", fixture.origin, second_clone_root])

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-018", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/stale-clone-owner"},
               codex_home: codex_home
             )

    File.rm_rf!(prepared.worktree_path)

    assert {:error, :invalid_worktree_path} =
             WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: second_clone_root)

    assert normalized_path(TestSupport.git_output!(fixture.repo_root, ["worktree", "list", "--porcelain"])) =~
             normalized_path(prepared.worktree_path)

    assert {:ok, recovered} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)
    assert recovered.status == "stale_record_cleared"
  end

  test "cleanup returns sanitized git command failures with target and worktree paths", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-017", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup-git-failure"},
               codex_home: codex_home
             )

    File.rm_rf!(prepared.worktree_path)
    File.mkdir_p!(prepared.worktree_path)

    assert {:error, {:git_failed, status, details}} =
             WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)

    assert is_integer(status)
    assert details.status == status
    assert normalized_path(details.target_repo_root) == normalized_path(fixture.repo_root)
    assert normalized_path(details.worktree_path) == normalized_path(prepared.worktree_path)
    assert details.git_args == ["status", "--porcelain"]
    assert details.stderr =~ "fatal"
  end

  test "prepare updates the remote-tracking base before creating new branches", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    updater_root = Path.join(fixture.root, "updater")

    TestSupport.git_output!(fixture.repo_root, ["config", "--unset-all", "remote.origin.fetch"])
    TestSupport.git_output!(fixture.root, ["clone", fixture.origin, updater_root])
    TestSupport.git_output!(updater_root, ["checkout", "main"])
    TestSupport.git_output!(updater_root, ["config", "user.email", "sympp@example.com"])
    TestSupport.git_output!(updater_root, ["config", "user.name", "Symphony Test"])
    File.write!(Path.join(updater_root, "remote-update.txt"), "remote update\n")
    TestSupport.git_output!(updater_root, ["add", "remote-update.txt"])
    TestSupport.git_output!(updater_root, ["commit", "-m", "Remote update"])
    TestSupport.git_output!(updater_root, ["push", "origin", "main"])

    stale_origin_revision = fixture.repo_root |> TestSupport.git_output!(["rev-parse", "origin/main"]) |> String.trim()
    remote_revision = updater_root |> TestSupport.git_output!(["rev-parse", "HEAD"]) |> String.trim()
    refute stale_origin_revision == remote_revision

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-013", kind: "mcp", base_branch: "main"))

    assert {:ok, _prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/fresh-base"},
               codex_home: codex_home
             )

    assert fixture.repo_root |> TestSupport.git_output!(["rev-parse", "origin/main"]) |> String.trim() == remote_revision
    assert fixture.repo_root |> TestSupport.git_output!(["rev-parse", "feat/fresh-base"]) |> String.trim() == remote_revision
  end

  test "prepare replay rejects recorded paths that are no longer git worktrees", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-009", kind: "mcp", base_branch: "main"))

    attrs = %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/replay-invalid"}

    assert {:ok, prepared} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)

    File.rm_rf!(prepared.worktree_path)
    File.mkdir_p!(prepared.worktree_path)

    assert {:error, :invalid_worktree_path} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)

    assert {:ok, recorded} = Repository.get(repo, package.id)
    assert recorded.worktree_path == prepared.worktree_path
  end

  test "cleanup rejects recorded paths that exist as non-directories", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-010", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/cleanup-invalid"},
               codex_home: codex_home
             )

    File.rm_rf!(prepared.worktree_path)
    File.write!(prepared.worktree_path, "not a directory")

    assert {:error, :invalid_worktree_path} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)

    assert {:ok, recorded} = Repository.get(repo, package.id)
    assert recorded.worktree_path == prepared.worktree_path
  end

  test "prepare rejects stale existing local branches", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-008", kind: "mcp", base_branch: "main"))

    attrs = %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/stale"}

    assert {:ok, prepared} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)
    assert {:ok, _cleaned} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home, repo_root: fixture.repo_root)

    TestSupport.git_output!(fixture.repo_root, ["checkout", "feat/stale"])
    File.write!(Path.join(fixture.repo_root, "stale.txt"), "stale\n")
    TestSupport.git_output!(fixture.repo_root, ["add", "stale.txt"])
    TestSupport.git_output!(fixture.repo_root, ["commit", "-m", "Stale branch commit"])

    assert {:error, :stale_existing_branch} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)
    refute File.exists?(prepared.worktree_path)
  end

  test "prepare uses collision-resistant paths for distinct branch names", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, first_package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-006-A", kind: "mcp", base_branch: "main"))

    assert {:ok, second_package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-006-B", kind: "mcp", base_branch: "main"))

    assert {:ok, first} =
             WorktreeLifecycle.prepare(
               repo,
               first_package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/a-b"},
               codex_home: codex_home
             )

    assert {:ok, second} =
             WorktreeLifecycle.prepare(
               repo,
               second_package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat-a/b"},
               codex_home: codex_home
             )

    refute first.worktree_path == second.worktree_path
    assert File.dir?(first.worktree_path)
    assert File.dir?(second.worktree_path)
  end

  test "prepare rollback deletes the local branch it created when persistence fails", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-007", kind: "mcp", base_branch: "main"))

    assert {:error, {:worktree_record_failed, :database_busy}} =
             WorktreeLifecycle.prepare(
               UpdateFailsWorkPackageRepo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/rollback"},
               codex_home: codex_home
             )

    assert TestSupport.git_output!(fixture.repo_root, ["branch", "--list", "feat/rollback"]) == ""
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

    assert {:ok, package} =
             Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WT-004", kind: "mcp", base_branch: "main"))

    assert {:ok, prepared} =
             WorktreeLifecycle.prepare(
               repo,
               package.id,
               %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/collision"},
               codex_home: codex_home
             )

    assert File.dir?(prepared.worktree_path)
    assert {:ok, _cleared} = Repository.update(repo, package.id, %{worktree_path: nil})

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

  defp normalized_path(path) do
    path
    |> String.replace("\\", "/")
    |> String.downcase()
  end

  defp legacy_worktree_path(codex_home, repo_root, package_id, branch) do
    {:ok, worktree_root} = WorktreeLifecycle.worktree_root(codex_home: codex_home)
    {:ok, repo_root} = SymphonyElixir.PathSafety.canonicalize(repo_root)

    Path.join([
      worktree_root,
      legacy_unique_segment(Path.basename(repo_root), repo_root),
      "#{safe_segment(package_id)}-#{legacy_unique_segment(branch, branch)}"
    ])
  end

  defp legacy_unique_segment(display_value, fingerprint_value) do
    "#{safe_segment(display_value)}-#{test_short_hash(fingerprint_value)}"
  end

  defp safe_segment(value) do
    value
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.trim("-")
  end

  defp test_short_hash(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 10)
  end
end
