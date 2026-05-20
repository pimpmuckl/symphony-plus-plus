defmodule SymphonyElixir.SymphonyPlusPlus.GitHubMergeReconcilerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.FakeGitHubClient
  alias SymphonyElixir.GitHubPullRequestFixtures
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{HttpClient, MergeReconciler}
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(Artifact)
    repo.delete_all(ProgressEvent)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)
    FakeGitHubClient.clear()
    :ok
  end

  test "merged PR fetch transitions ready standalone package to merged", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-MERGED", status: "ready_for_human_merge")
    append_pr_evidence(repo, package, 1, "head-a")
    FakeGitHubClient.put_response("nextide/repo", 1, GitHubPullRequestFixtures.metadata(1, "head-a", merged?: true))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.merged_count == 1
    assert [%{status: "merged", reason: "github_pr_merged", work_package_id: "SYMPP-GH-MERGED"}] = result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "merged"

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.any?(events, &match?(%ProgressEvent{status: "pr_synced", payload: %{"source_tool" => "sync_pr"}}, &1))

    assert Enum.any?(
             events,
             &match?(%ProgressEvent{status: "github_pr_merged", payload: %{"source_tool" => "operator_sync_prs", "after_status" => "merged"}}, &1)
           )
  end

  test "non-merged PR syncs metadata without transitioning", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-OPEN", status: "ready_for_human_merge")
    append_pr_evidence(repo, package, 2, "head-a")
    FakeGitHubClient.put_response("nextide/repo", 2, GitHubPullRequestFixtures.metadata(2, "head-a", merged?: false))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.merged_count == 0
    assert [%{status: "synced", reason: "pr_not_merged"}] = result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "ready_for_human_merge"
  end

  test "merged PR with mismatched head syncs but does not transition", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-STALE", status: "ready_for_human_merge")
    append_pr_evidence(repo, package, 3, "expected-head")
    FakeGitHubClient.put_response("nextide/repo", 3, GitHubPullRequestFixtures.metadata(3, "other-head", merged?: true))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.merged_count == 0
    assert [%{status: "skipped", reason: "head_mismatch", expected_head_sha: "expected-head"}] = result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "ready_for_human_merge"
  end

  test "attached PR head wins over older branch head evidence", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-REATTACHED", status: "ready_for_human_merge")
    append_branch_evidence(repo, package, "old-head")
    append_attached_pr_evidence(repo, package, 5, "new-head")
    FakeGitHubClient.put_response("nextide/repo", 5, GitHubPullRequestFixtures.metadata(5, "new-head", merged?: true))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.merged_count == 1
    assert [%{status: "merged", reason: "github_pr_merged"}] = result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "merged"
  end

  test "newer branch head evidence wins over older attached PR head", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-BRANCH-NEWER", status: "ready_for_human_merge")
    append_attached_pr_evidence(repo, package, 6, "old-head")
    append_branch_evidence(repo, package, "new-head")
    FakeGitHubClient.put_response("nextide/repo", 6, GitHubPullRequestFixtures.metadata(6, "new-head", merged?: true))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.merged_count == 1
    assert [%{status: "merged", reason: "github_pr_merged"}] = result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "merged"
  end

  test "synced PR head evidence does not satisfy stale head guard", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-SYNC-NEWER", status: "ready_for_human_merge")
    append_attached_pr_evidence(repo, package, 7, "old-head")
    FakeGitHubClient.put_response("nextide/repo", 7, GitHubPullRequestFixtures.metadata(7, "new-head", merged?: true))

    assert {:ok, first_result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert first_result.merged_count == 0
    assert [%{status: "skipped", reason: "head_mismatch", expected_head_sha: "old-head"}] = first_result.results
    assert {:ok, ready_package} = WorkPackageRepository.get(repo, package.id)
    assert ready_package.status == "ready_for_human_merge"

    assert {:ok, second_result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert second_result.merged_count == 0
    assert [%{status: "skipped", reason: "head_mismatch", expected_head_sha: "old-head"}] = second_result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "ready_for_human_merge"
  end

  test "merged PR targeting a different base branch syncs but does not transition", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-WRONG-BASE", status: "ready_for_human_merge")
    append_pr_evidence(repo, package, 8, "head-a")
    FakeGitHubClient.put_response("nextide/repo", 8, GitHubPullRequestFixtures.metadata(8, "head-a", merged?: true, base_branch: "release"))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.merged_count == 0

    assert [
             %{
               status: "skipped",
               reason: "base_branch_mismatch",
               expected_base_branch: "main",
               actual_base_branch: "release"
             }
           ] = result.results

    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "ready_for_human_merge"
  end

  test "merge transition rolls back when merge evidence cannot be recorded", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-EVIDENCE-FAIL", status: "ready_for_human_merge")
    append_pr_evidence(repo, package, 9, "head-a")

    assert {:ok, _existing_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Pre-existing merge reconciliation key",
               status: "test_merge_evidence_collision",
               idempotency_key: "operator_github_merge:#{package.id}:head-a",
               payload: %{type: "test_collision"}
             })

    FakeGitHubClient.put_response("nextide/repo", 9, GitHubPullRequestFixtures.metadata(9, "head-a", merged?: true))

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.error_count == 1
    assert [%{status: "error", reason: "merge_evidence_conflict"}] = result.results
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "ready_for_human_merge"

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)
    refute Enum.any?(events, &match?(%ProgressEvent{status: "github_pr_merged"}, &1))
  end

  test "phase child merge-ready package is not polled by v1 auto reconciliation", %{repo: repo} do
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: "phase-1", title: "Phase 1"})

    assert {:ok, package} =
             create_package(repo,
               id: "SYMPP-GH-PHASE-CHILD",
               kind: "phase_child",
               status: "ready_for_architect_merge",
               parent_id: "phase-parent",
               phase_id: "phase-1"
             )

    append_pr_evidence(repo, package, 4, "head-a")

    assert {:ok, result} = MergeReconciler.reconcile(repo, client: FakeGitHubClient)

    assert result.total_count == 0
    assert result.merged_count == 0
    assert result.results == []
    assert {:ok, updated} = WorkPackageRepository.get(repo, package.id)
    assert updated.status == "ready_for_architect_merge"
  end

  test "periodic default HTTP sync skips when no GitHub token is configured", %{repo: repo} do
    with_github_token_env(nil, fn ->
      assert {:ok, result} = MergeReconciler.reconcile(repo, client: HttpClient, require_authenticated_client?: true)

      assert result.reason == "github_token_required_for_periodic_sync"
      assert result.results == []
      assert result.total_count == 0
    end)
  end

  test "worker grant still cannot mark a package merged", %{repo: repo} do
    assert {:ok, package} = create_package(repo, id: "SYMPP-GH-WORKER-DENIED", status: "ready_for_human_merge")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    assert {:error, :worker_cannot_mark_merged} =
             LifecycleService.transition(repo, package.id, "merged", Map.from_struct(assignment))
  end

  defp create_package(repo, overrides) do
    attrs =
      overrides
      |> Keyword.put_new(:kind, "hotfix")
      |> Keyword.put_new(:repo, "nextide/repo")
      |> Keyword.put_new(:base_branch, "main")
      |> WorkPackageFactory.attrs()

    WorkPackageRepository.create(repo, attrs)
  end

  defp append_pr_evidence(repo, package, number, head_sha) do
    append_branch_evidence(repo, package, head_sha)
    append_attached_pr_evidence(repo, package, number, head_sha)
  end

  defp append_branch_evidence(repo, package, head_sha) do
    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{package.id}", head_sha: head_sha}
             })
  end

  defp append_attached_pr_evidence(repo, package, number, head_sha) do
    assert {:ok, _pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/repo/pull/#{number}", head_sha: head_sha}
             })
  end

  defp with_github_token_env(value, fun) do
    original_github_token = System.get_env("GITHUB_TOKEN")
    original_gh_token = System.get_env("GH_TOKEN")

    try do
      set_env("GITHUB_TOKEN", value)
      set_env("GH_TOKEN", value)
      fun.()
    after
      set_env("GITHUB_TOKEN", original_github_token)
      set_env("GH_TOKEN", original_gh_token)
    end
  end

  defp set_env(key, nil), do: System.delete_env(key)
  defp set_env(key, value), do: System.put_env(key, value)
end
