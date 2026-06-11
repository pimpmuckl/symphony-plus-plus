defmodule SymphonyElixir.SymphonyPlusPlus.WorktreeLifecycleCompatTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle
  alias SymphonyElixir.TestSupport
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

  test "stores nullable worktree metadata through SQLite", %{repo: repo} do
    assert {:ok, package} = Repository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-001"))
    assert package.worktree_path == nil
    assert package.worktree_target_repo_root == nil

    worktree_path = Path.join(System.tmp_dir!(), "sympp-worktree-path")
    target_repo_root = Path.join(System.tmp_dir!(), "sympp-target-repo-root")

    assert {:ok, updated} =
             Repository.update(repo, package.id, %{
               worktree_path: worktree_path,
               worktree_target_repo_root: target_repo_root
             })

    assert updated.worktree_path == worktree_path
    assert updated.worktree_target_repo_root == target_repo_root

    assert {:ok, cleared} = Repository.update(repo, package.id, %{worktree_path: nil, worktree_target_repo_root: nil})
    assert cleared.worktree_path == nil
    assert cleared.worktree_target_repo_root == nil
  end

  test "prepare replay and cleanup backfill target roots for pre-migration worktree records", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    attrs = %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/pre-migration-cleanup"}

    assert {:ok, package} =
             Repository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WT-PREMIGRATION",
                 kind: "mcp",
                 repo: fixture.repo_root,
                 base_branch: "main"
               )
             )

    assert {:ok, prepared} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)
    assert {:ok, _legacy_row} = Repository.update(repo, package.id, %{worktree_target_repo_root: nil})

    assert {:ok, replayed} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)
    assert replayed.status == "already_prepared"

    assert {:ok, replayed_package} = Repository.get(repo, package.id)
    assert replayed_package.worktree_target_repo_root == Path.expand(fixture.repo_root)

    assert {:ok, _legacy_row} = Repository.update(repo, package.id, %{worktree_target_repo_root: nil})
    assert {:ok, cleaned} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
    assert cleaned.status == "cleaned"
    refute File.exists?(prepared.worktree_path)

    assert {:ok, cleared} = Repository.get(repo, package.id)
    assert cleared.worktree_path == nil
    assert cleared.worktree_target_repo_root == nil
  end

  test "cleanup refuses unowned live pre-migration worktree records", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle-foreign")
    codex_home = Path.join(fixture.root, "codex-home")
    attrs = %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/unowned-live-cleanup"}

    assert {:ok, package} =
             Repository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WT-PREMIGRATION-FOREIGN",
                 kind: "mcp",
                 repo: "nextide/example",
                 base_branch: "main"
               )
             )

    assert {:ok, prepared} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)
    assert {:ok, _legacy_row} = Repository.update(repo, package.id, %{worktree_target_repo_root: nil})

    assert {:error, :invalid_target_repo_root} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
    assert File.dir?(prepared.worktree_path)
  end

  test "cleanup clears missing pre-migration worktree records from package repo path", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("main", prefix: "sympp-worktree-lifecycle")
    codex_home = Path.join(fixture.root, "codex-home")
    attrs = %{"repo_root" => fixture.repo_root, "base_branch" => "main", "branch" => "feat/pre-migration-missing"}

    assert {:ok, package} =
             Repository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WT-PREMIGRATION-MISSING",
                 kind: "mcp",
                 repo: fixture.repo_root,
                 base_branch: "main"
               )
             )

    assert {:ok, prepared} = WorktreeLifecycle.prepare(repo, package.id, attrs, codex_home: codex_home)
    assert {:ok, _legacy_row} = Repository.update(repo, package.id, %{worktree_target_repo_root: nil})

    File.rm_rf!(prepared.worktree_path)

    assert {:ok, recovered} = WorktreeLifecycle.cleanup(repo, package.id, codex_home: codex_home)
    assert recovered.status == "stale_record_cleared"

    assert {:ok, cleared} = Repository.get(repo, package.id)
    assert cleared.worktree_path == nil
    assert cleared.worktree_target_repo_root == nil
  end
end
