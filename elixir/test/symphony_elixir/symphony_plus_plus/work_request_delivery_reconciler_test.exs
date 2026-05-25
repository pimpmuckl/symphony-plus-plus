Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestDeliveryReconcilerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Config
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryReconciler
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkRequestRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    for schema <- [
          ProgressEvent,
          PlannedSliceDelivery,
          PlannedSlice,
          DecisionLogEntry,
          AccessGrant,
          WorkPackage,
          WorkRequest,
          Phase
        ] do
      repo.delete_all(schema)
    end

    :ok
  end

  test "dry-run proposes and apply records merged PR closeout through delivery service", %{repo: repo} do
    {work_request, planned_slice, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-PR-MERGED",
        work_package_id: "WP-RECONCILE-PR-MERGED",
        status: "ready_for_human_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 902, "head-902")

    assert {:ok, dry_run} = DeliveryReconciler.reconcile(repo, work_request.id, recorded_by: "reconciler-test")

    assert dry_run.mode == "dry_run"
    assert dry_run.proposed_count == 1
    assert dry_run.applied_count == 0

    assert [
             %{
               status: "proposed",
               reason: "github_pr_merged",
               planned_slice_id: planned_slice_id,
               work_package_id: work_package_id,
               action: %{outcome: "pr_merged", pr_number: 902, merge_commit_sha: "merge-sha-902"}
             }
           ] = dry_run.results

    assert planned_slice_id == planned_slice.id
    assert work_package_id == linked_package.id
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_human_merge"

    assert {:ok, applied} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply, recorded_by: "reconciler-test")

    assert applied.applied_count == 1
    assert [%{status: "applied", reason: "github_pr_merged", delivery_id: delivery_id}] = applied.results
    assert is_binary(delivery_id)

    assert [delivery] = repo.all(PlannedSliceDelivery)
    assert delivery.outcome == "pr_merged"
    assert delivery.planned_slice_id == planned_slice.id
    assert delivery.recorded_by == "reconciler-test"
    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
  end

  test "MCP reconcile_work_request dry-run reports proposed closeout without write capability", %{repo: repo} do
    {work_request, planned_slice, linked_package} =
      linked_slice!(
        repo,
        work_request_id: "WR-RECONCILE-MCP-DRY-RUN",
        work_package_id: "WP-RECONCILE-MCP-DRY-RUN",
        status: "ready_for_human_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 903, "head-903")
    session = create_work_request_architect_session(repo, work_request, ["read:work_request"])

    response = mcp_tool(repo, session, "reconcile_work_request", %{"work_request_id" => work_request.id})
    payload = get_in(response, ["result", "structuredContent", "reconciliation"])

    assert payload["mode"] == "dry_run"
    assert payload["proposed_count"] == 1
    assert [result] = payload["results"]
    assert result["status"] == "proposed"
    assert result["reason"] == "github_pr_merged"
    assert result["planned_slice_id"] == planned_slice.id
    assert get_in(response, ["result", "structuredContent", "delivery_board", "counts", "needs_closeout"]) == 1
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_human_merge"
  end

  test "repository base and head mismatches are skipped with reason codes", %{repo: repo} do
    cases = [
      {"repository_mismatch", [repository: "other/repo"]},
      {"base_branch_mismatch", [base_branch: "release"]},
      {"head_mismatch", [synced_head_sha: "other-head"]}
    ]

    for {reason, evidence_opts} <- cases do
      {work_request, _planned_slice, linked_package} =
        linked_slice!(repo,
          work_request_id: "WR-RECONCILE-#{String.upcase(reason)}",
          work_package_id: "WP-RECONCILE-#{String.upcase(reason)}",
          status: "ready_for_human_merge"
        )

      append_merged_pr_evidence!(repo, linked_package, System.unique_integer([:positive]), "expected-head", evidence_opts)

      assert {:ok, result} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

      assert result.applied_count == 0
      assert [%{status: "skipped", reason: ^reason}] = result.results
      assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
      assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_human_merge"
    end
  end

  test "decision-log prose and terminal package status do not infer no-PR completion", %{repo: repo} do
    {work_request, _planned_slice, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-NO-PR-PROSE",
        work_package_id: "WP-RECONCILE-NO-PR-PROSE",
        status: "closed"
      )

    assert {:ok, _decision} =
             WorkRequestRepository.record_decision(repo, work_request.id, %{
               source_type: "architect",
               created_by: "architect-1",
               decision: "Slice completed without PR.",
               rationale: "Operator prose only.",
               scope_impact: "Advisory note."
             })

    assert {:ok, result} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

    assert result.applied_count == 0
    assert [%{status: "skipped", reason: "no_structured_pr_merge_evidence"}] = result.results
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "closed"
  end

  test "already closed-out slices are skipped without duplicate deliveries", %{repo: repo} do
    {work_request, _planned_slice, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-ALREADY-CLOSED",
        work_package_id: "WP-RECONCILE-ALREADY-CLOSED",
        status: "ready_for_human_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 911, "head-911")

    assert {:ok, first} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)
    assert [%{status: "applied"}] = first.results
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 1

    assert {:ok, second} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

    assert second.applied_count == 0
    assert [%{status: "skipped", reason: "already_closeout", delivery_outcome: "pr_merged"}] = second.results
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 1
  end

  test "merged PR evidence without strong merge fields is skipped before apply", %{repo: repo} do
    {work_request, _planned_slice, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-RECONCILE-WEAK-PR",
        work_package_id: "WP-RECONCILE-WEAK-PR",
        status: "ready_for_human_merge"
      )

    append_merged_pr_evidence!(repo, linked_package, 912, "head-912", merge_commit_sha: nil)

    assert {:ok, result} = DeliveryReconciler.reconcile(repo, work_request.id, mode: :apply)

    assert result.applied_count == 0
    assert [%{status: "skipped", reason: "missing_strong_pr_evidence", missing: "merge_commit_sha"}] = result.results
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_human_merge"
  end

  defp linked_slice!(repo, overrides) do
    request_id = Keyword.fetch!(overrides, :work_request_id)
    work_package_id = Keyword.fetch!(overrides, :work_package_id)
    status = Keyword.get(overrides, :status, "reviewing")

    work_request = create_work_request!(repo, id: request_id, status: "ready_for_slicing")
    planned_slice = create_planned_slice!(repo, work_request, id: "WRS-#{request_id}")

    assert {:ok, approved_slice} =
             WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    work_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: work_package_id,
        status: status
      )

    assert {:ok, dispatched_slice} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               approved_slice.id,
               "approved",
               work_package.id
             )

    {work_request, dispatched_slice, work_package}
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_planned_slice!(repo, work_request, overrides) do
    assert {:ok, planned_slice} = WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(overrides))
    planned_slice
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

  defp create_work_request_architect_session(repo, %WorkRequest{} = work_request, capabilities) do
    phase_id = ArchitectHandoff.phase_id_for_work_request(work_request)

    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Architect handoff for #{work_request.id}"})

    anchor_attrs =
      [
        id: ArchitectHandoff.anchor_id_for_work_request(work_request),
        kind: "delegation",
        title: "Architect handoff: #{work_request.title}",
        repo: work_request.repo,
        base_branch: work_request.base_branch,
        phase_id: phase_id,
        status: "planning",
        allowed_file_globs: ["elixir/lib", "elixir/lib/**"],
        acceptance_criteria: ["Own the WorkRequest architecture."]
      ]
      |> WorkPackageFactory.attrs()

    assert {:ok, anchor} = WorkPackageRepository.create(repo, anchor_attrs)

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, phase_id,
               work_package_id: anchor.id,
               capabilities: capabilities
             )

    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "architect-1")

    MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
  end

  defp append_merged_pr_evidence!(repo, work_package, number, attached_head_sha, opts \\ []) do
    synced_head_sha = Keyword.get(opts, :synced_head_sha, attached_head_sha)
    repository = Keyword.get(opts, :repository, "nextide/repo")
    url = Keyword.get(opts, :url, "https://github.com/#{repository}/pull/#{number}")
    base_branch = Keyword.get(opts, :base_branch, "main")
    merge_commit_sha = Keyword.get(opts, :merge_commit_sha, "merge-sha-#{number}")

    assert {:ok, _branch} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "Branch attached",
               status: "branch_attached",
               payload: %{type: "branch", source_tool: "attach_branch", branch: "agent/#{work_package.id}", head_sha: attached_head_sha}
             })

    assert {:ok, _attached} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: url,
                 repository: repository,
                 number: number,
                 head_sha: attached_head_sha,
                 base_branch: base_branch
               }
             })

    assert {:ok, _synced} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: work_package.id,
               summary: "PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: url,
                 repository: repository,
                 number: number,
                 head_sha: synced_head_sha,
                 base_branch: base_branch,
                 merged_at: "2026-05-24T12:00:00Z",
                 merge_commit_sha: merge_commit_sha,
                 merge_state: %{merged: true}
               }
             })
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-RECONCILE-#{System.unique_integer([:positive])}",
      title: "Reconcile delivered WorkRequest slices",
      repo: "nextide/repo",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record closeout truth for delivered slices.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "architect_led_feature_branch"
    }

    Enum.into(overrides, defaults)
  end

  defp planned_slice_attrs(overrides) do
    defaults = %{
      title: "Reconcile delivered slice",
      goal: "Record terminal delivery state.",
      work_package_kind: "mcp",
      target_base_branch: "main",
      branch_pattern: "feat/delivery-reconciler",
      owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery reconciler is deterministic."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/work_request_delivery_reconciler_test.exs"],
      review_lanes: ["normal"],
      stop_conditions: ["Do not infer no-PR completion from prose."]
    }

    Enum.into(overrides, defaults)
  end

  defp mcp_tool(repo, %Session{} = session, name, arguments) do
    MCPHarness.request(
      %{
        "jsonrpc" => "2.0",
        "id" => name,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      },
      config: Config.default(repo: repo, repo_root: test_repo_root()),
      session: session
    )
  end

  defp test_repo_root do
    Path.expand("../../../..", __DIR__)
  end
end
