Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorktreeToolsLifecycleTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  @moduletag :ci_slow

  test "WorkPackage worktree MCP tools prepare, audit, and cleanup a linked package", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("symphony-plus-plus/beta", prefix: "sympp-mcp-worktree")
    other_fixture = TestSupport.git_repo_fixture!("symphony-plus-plus/beta", prefix: "sympp-mcp-other-worktree")
    same_origin_repo_root = TestSupport.git_repo_with_origin_fixture!(fixture.origin, prefix: "sympp-mcp-same-origin-worktree")
    codex_home = Path.join(fixture.root, "codex-home")
    config = Config.default(repo: repo, repo_root: test_repo_root())

    {anchor, session, _grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-ARCHITECT-WORKTREE-LIFECYCLE",
        [
          "dispatch:work_request"
        ],
        repo: fixture.origin
      )

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-LIFECYCLE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WORKTREE-LIFECYCLE",
                 title: "Prepare package worktree",
                 target_base_branch: anchor.base_branch,
                 branch_pattern: "feat/worktree-lifecycle",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_packages/**"],
                 acceptance_criteria: ["Prepare and clean worktrees."]
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORKTREE-LIFECYCLE",
                 kind: planned_slice.work_package_kind,
                 title: planned_slice.title,
                 repo: work_request.repo,
                 base_branch: planned_slice.target_base_branch,
                 branch_pattern: planned_slice.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: planned_slice.owned_file_globs,
                 acceptance_criteria: planned_slice.acceptance_criteria,
                 status: "ready_for_worker"
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    assert {:ok, _linked_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      already_clean_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: config
        )

      already_clean_payload = get_in(already_clean_response, ["result", "structuredContent"])
      assert already_clean_payload["worktree"]["status"] == "already_clean"
      assert already_clean_payload["work_package"]["worktree_path"] == nil

      scope_mismatch_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => other_fixture.repo_root
          },
          config: config
        )

      assert get_in(scope_mismatch_response, ["error", "data", "reason"]) == "target_repo_root_scope_mismatch"

      wrong_branch_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root,
            "branch" => "feat/wrong-base"
          },
          config: config
        )

      assert get_in(wrong_branch_response, ["error", "data", "reason"]) == "branch_scope_mismatch"

      prepare_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root
          },
          config: config
        )

      prepare_payload = get_in(prepare_response, ["result", "structuredContent"])
      assert prepare_payload["worktree"]["status"] == "prepared"
      assert prepare_payload["work_package"]["worktree_path"] == prepare_payload["worktree"]["path"]
      assert comparable_path(prepare_payload["worktree"]["target_repo_root"]) == comparable_path(fixture.repo_root)
      assert prepare_payload["worker_launch"]["workspace_path"] == prepare_payload["worktree"]["path"]
      assert prepare_payload["worker_launch"]["instruction"] =~ "Use this worktree only"
      assert prepare_payload["audit_event"]["payload"]["source_tool"] == "prepare_work_package_worktree"
      assert prepare_payload["audit_event"]["payload"]["worktree_path"] == "[REDACTED]"
      assert prepare_payload["audit_event"]["payload"]["target_repo_root"] == "[REDACTED]"
      assert File.dir?(prepare_payload["worktree"]["path"])

      same_origin_cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => same_origin_repo_root
          },
          config: config
        )

      assert get_in(same_origin_cleanup_response, ["error", "data", "reason"]) == "invalid_worktree_path"
      assert File.dir?(prepare_payload["worktree"]["path"])

      assert {:ok, _foreign_root_package} =
               WorkPackageRepository.update(repo, package.id, %{worktree_target_repo_root: other_fixture.repo_root})

      stored_scope_mismatch_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: config
        )

      assert get_in(stored_scope_mismatch_response, ["error", "data", "reason"]) == "target_repo_root_scope_mismatch"
      assert File.dir?(prepare_payload["worktree"]["path"])
      assert {:ok, _restored_root_package} = WorkPackageRepository.update(repo, package.id, %{worktree_target_repo_root: fixture.repo_root})

      cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: config
        )

      cleanup_payload = get_in(cleanup_response, ["result", "structuredContent"])
      assert cleanup_payload["worktree"]["status"] == "cleaned"
      assert cleanup_payload["audit_event"]["summary"] == "Success removing worktree. Subagent can be closed now."
      assert cleanup_payload["work_package"]["worktree_path"] == nil
      assert cleanup_payload["audit_event"]["payload"]["source_tool"] == "cleanup_work_package_worktree"
      assert cleanup_payload["audit_event"]["payload"]["worktree_path"] == "[REDACTED]"
      assert cleanup_payload["audit_event"]["payload"]["target_repo_root"] == "[REDACTED]"
      refute File.exists?(prepare_payload["worktree"]["path"])

      stale_prepare_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root
          },
          config: config
        )

      stale_prepare_payload = get_in(stale_prepare_response, ["result", "structuredContent"])
      assert stale_prepare_payload["worktree"]["status"] == "prepared"
      assert {:ok, _legacy_package} = WorkPackageRepository.update(repo, package.id, %{worktree_target_repo_root: nil})
      File.rm_rf!(stale_prepare_payload["worktree"]["path"])

      wrong_stale_cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id
          },
          config: Config.default(repo: repo, repo_root: same_origin_repo_root)
        )

      assert get_in(wrong_stale_cleanup_response, ["error", "data", "reason"]) == "target_repo_root_required"

      stale_cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root
          },
          config: config
        )

      stale_cleanup_payload = get_in(stale_cleanup_response, ["result", "structuredContent"])
      assert stale_cleanup_payload["worktree"]["status"] == "stale_record_cleared"
      assert stale_cleanup_payload["work_package"]["worktree_path"] == nil
      assert stale_cleanup_payload["audit_event"]["payload"]["source_tool"] == "cleanup_work_package_worktree"
      assert stale_cleanup_payload["audit_event"]["payload"]["status"] == "stale_record_cleared"
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end

    assert {:ok, cleaned_package} = WorkPackageRepository.get(repo, package.id)
    assert cleaned_package.worktree_path == nil

    events =
      repo.all(
        from(progress_event in ProgressEvent,
          where: progress_event.work_package_id == ^package.id,
          order_by: [asc: progress_event.sequence]
        )
      )

    assert Enum.map(events, & &1.payload["source_tool"]) == [
             "prepare_work_package_worktree",
             "cleanup_work_package_worktree",
             "cleanup_work_package_worktree"
           ]
  end
end
