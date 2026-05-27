defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestDeliveryCloseoutTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AgentRun)
    repo.delete_all(ClaimLease)
    repo.delete_all(AccessGrant)
    repo.delete_all(ProgressEvent)
    repo.delete_all(PlannedSliceDelivery)
    repo.delete_all(PlannedSlice)
    repo.delete_all(WorkPackage)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "PR merged closeout records delivery, merges the linked package, appends progress, and refreshes completion", %{repo: repo} do
    {work_request, planned_slice, linked_package} = linked_slice!(repo, status: "ready_for_human_merge")

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-pr-merged",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/123",
        pr_number: 123,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 12:00:00.000000Z],
        merge_commit_sha: "abc123"
      })

    assert {:ok, delivery} = Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert delivery.outcome == "pr_merged"

    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
    assert %WorkRequest{completed_at: %DateTime{}} = repo.get!(WorkRequest, work_request.id)

    assert [event] = repo.all(ProgressEvent)
    assert event.work_package_id == linked_package.id
    assert event.status == "merged"
    assert event.payload["source_tool"] == "record_planned_slice_delivery"
    assert event.payload["outcome"] == "pr_merged"
    assert event.payload["previous_status"] == "ready_for_human_merge"
    assert event.payload["next_status"] == "merged"

    assert {:ok, _drifted_after_closeout} = WorkPackageRepository.update(repo, linked_package.id, %{title: "Drifted after closeout"})
    assert {:ok, replay} = Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert replay.id == delivery.id
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 1
    assert repo.aggregate(ProgressEvent, :count, :id) == 1
    assert repo.get!(WorkPackage, linked_package.id).status == "merged"
  end

  test "completed_no_pr superseded and abandoned close compatible linked packages to terminal states", %{repo: repo} do
    {no_pr_request, no_pr_slice, no_pr_package} = linked_slice!(repo, status: "reviewing")

    assert {:ok, no_pr_delivery} =
             Service.record_planned_slice_delivery(
               repo,
               no_pr_request.id,
               no_pr_slice.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "delivery-no-pr",
                 no_pr_evidence: "Operator confirmed the docs-only package landed directly."
               })
             )

    assert no_pr_delivery.outcome == "completed_no_pr"
    assert repo.get!(WorkPackage, no_pr_package.id).status == "closed"
    assert %WorkRequest{completed_at: %DateTime{}} = repo.get!(WorkRequest, no_pr_request.id)

    {superseded_request, superseded_slice, superseded_package} = linked_slice!(repo, status: "implementing")
    successor_slice = create_planned_slice!(repo, superseded_request, id: "WRS-DELIVERY-SUCCESSOR")
    assert {:ok, _skipped_successor} = Repository.skip_planned_slice(repo, superseded_request.id, successor_slice.id, "planned")

    assert {:ok, superseded_delivery} =
             Service.record_planned_slice_delivery(
               repo,
               superseded_request.id,
               superseded_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "delivery-superseded",
                 successor_planned_slice_id: successor_slice.id,
                 superseded_reason: "Recut with narrower owned files."
               })
             )

    assert superseded_delivery.outcome == "superseded"
    assert repo.get!(WorkPackage, superseded_package.id).status == "closed"
    assert %WorkRequest{completed_at: %DateTime{}} = repo.get!(WorkRequest, superseded_request.id)

    {abandoned_request, abandoned_slice, abandoned_package} = linked_slice!(repo, status: "planning")

    assert {:ok, abandoned_delivery} =
             Service.record_planned_slice_delivery(
               repo,
               abandoned_request.id,
               abandoned_slice.id,
               delivery_attrs(%{
                 outcome: "abandoned",
                 idempotency_key: "delivery-abandoned",
                 abandoned_rationale: "Architecture decision made the package unnecessary."
               })
             )

    assert abandoned_delivery.outcome == "abandoned"
    assert repo.get!(WorkPackage, abandoned_package.id).status == "abandoned"
    assert %WorkRequest{completed_at: %DateTime{}} = repo.get!(WorkRequest, abandoned_request.id)
  end

  test "phase-child PR merged closeout must use merge_child_into_phase", %{repo: repo} do
    {work_request, planned_slice, linked_package} =
      linked_slice!(repo,
        work_package_kind: "phase_child",
        status: "ready_for_architect_merge"
      )

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-phase-child",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/456",
        pr_number: 456,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 13:00:00.000000Z],
        merge_commit_sha: "def456"
      })

    assert {:error, :phase_child_pr_merged_requires_merge_child_into_phase} =
             Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)

    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_architect_merge"

    assert {:ok, _merged_into_phase} = WorkPackageRepository.update_status(repo, linked_package.id, "ready_for_architect_merge", "merged_into_phase")
    assert {:ok, delivery} = Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)

    assert delivery.outcome == "pr_merged"
    assert repo.get!(WorkPackage, linked_package.id).status == "merged_into_phase"
    assert [event] = repo.all(ProgressEvent)
    assert event.status == "merged_into_phase"
  end

  test "linked PR merged closeout rejects weak PR evidence and rolls back", %{repo: repo} do
    {work_request, planned_slice, linked_package} = linked_slice!(repo, status: "ready_for_human_merge")

    assert {:error, :missing_strong_pr_evidence} =
             Service.record_planned_slice_delivery(
               repo,
               work_request.id,
               planned_slice.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "delivery-weak-pr",
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/789",
                 pr_number: 789,
                 pr_repository: "nextide/symphony-plus-plus",
                 pr_merged_at: ~U[2026-05-24 14:00:00.000000Z]
               })
             )

    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_human_merge"
  end

  test "replayed closeout skips weak PR evidence only with matching audit and terminal state", %{repo: repo} do
    {work_request, planned_slice, linked_package} = linked_slice!(repo, status: "ready_for_human_merge")

    attrs =
      delivery_attrs(%{
        outcome: "pr_merged",
        idempotency_key: "delivery-legacy-pr-merged",
        pr_url: "https://github.com/nextide/symphony-plus-plus/pull/790",
        pr_number: 790,
        pr_repository: "nextide/symphony-plus-plus",
        pr_merged_at: ~U[2026-05-24 14:30:00.000000Z]
      })

    assert {:ok, delivery} = Repository.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert {:ok, _merged} = WorkPackageRepository.update_status(repo, linked_package.id, "ready_for_human_merge", "merged")

    assert {:ok, _event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Recorded WorkRequest delivery closeout: pr_merged",
               status: "merged",
               idempotency_key: "work_request_delivery_closeout:#{work_request.id}:#{planned_slice.id}:#{attrs.idempotency_key}",
               payload: %{
                 type: "work_request_delivery_closeout",
                 source_tool: "record_planned_slice_delivery",
                 work_request_id: work_request.id,
                 planned_slice_id: planned_slice.id,
                 delivery_id: delivery.id,
                 outcome: "pr_merged",
                 previous_status: "ready_for_human_merge",
                 next_status: "merged",
                 status_changed: true
               }
             })

    assert {:ok, replay} = Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert replay.id == delivery.id
    assert %WorkRequest{completed_at: %DateTime{}} = repo.get!(WorkRequest, work_request.id)
  end

  test "colliding closeout progress does not bypass validation or terminal mutation", %{repo: repo} do
    {work_request, planned_slice, linked_package} = linked_slice!(repo, status: "ready_for_human_merge")
    delivery_idempotency_key = "delivery-progress-collision"

    assert {:ok, _colliding_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Manual event with a colliding closeout key",
               status: "merged",
               idempotency_key: "work_request_delivery_closeout:#{work_request.id}:#{planned_slice.id}:#{delivery_idempotency_key}",
               payload: %{
                 type: "manual",
                 source_tool: "operator_note",
                 work_request_id: work_request.id,
                 planned_slice_id: planned_slice.id,
                 delivery_id: "not-this-delivery",
                 outcome: "pr_merged",
                 next_status: "merged"
               }
             })

    assert {:error, :idempotency_key_conflict} =
             Service.record_planned_slice_delivery(
               repo,
               work_request.id,
               planned_slice.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: delivery_idempotency_key,
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/999",
                 pr_number: 999,
                 pr_repository: "nextide/symphony-plus-plus",
                 pr_merged_at: ~U[2026-05-24 15:00:00.000000Z],
                 merge_commit_sha: "fed999"
               })
             )

    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
    assert repo.aggregate(ProgressEvent, :count, :id) == 1
    assert repo.get!(WorkPackage, linked_package.id).status == "ready_for_human_merge"
  end

  test "delivery on a non-terminal unlinked planned slice does not complete the request", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DELIVERY-UNLINKED", status: "ready_for_slicing")
    planned_slice = create_planned_slice!(repo, work_request, id: "WRS-DELIVERY-UNLINKED")

    assert {:ok, delivery} =
             Service.record_planned_slice_delivery(
               repo,
               work_request.id,
               planned_slice.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "delivery-unlinked-planned",
                 no_pr_evidence: "Operator noted the slice was not dispatched."
               })
             )

    assert delivery.outcome == "completed_no_pr"
    assert %WorkRequest{completed_at: nil} = repo.get!(WorkRequest, work_request.id)
  end

  test "delivery on an approved unlinked planned slice skips linked worker grant checks", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DELIVERY-APPROVED-UNLINKED", status: "ready_for_slicing")
    planned_slice = create_planned_slice!(repo, work_request, id: "WRS-DELIVERY-APPROVED-UNLINKED")
    assert {:ok, approved_slice} = Repository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    assert {:ok, delivery} =
             Service.record_planned_slice_delivery(
               repo,
               work_request.id,
               approved_slice.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "delivery-approved-unlinked",
                 no_pr_evidence: "Operator noted the slice was approved but never dispatched."
               })
             )

    assert delivery.outcome == "completed_no_pr"
    assert %WorkRequest{completed_at: nil} = repo.get!(WorkRequest, work_request.id)
  end

  test "terminal linked package does not complete an approved slice before dispatch", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DELIVERY-APPROVED", status: "ready_for_slicing")
    planned_slice = create_planned_slice!(repo, work_request, id: "WRS-DELIVERY-APPROVED")
    assert {:ok, approved_slice} = Repository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    work_package = create_matching_work_package!(repo, work_request, approved_slice, id: "WP-DELIVERY-APPROVED", status: "merged")

    approved_slice
    |> Ecto.Changeset.change(work_package_id: work_package.id)
    |> repo.update!()

    assert {:ok, refreshed} = Service.refresh_completion(repo, work_request.id)
    assert refreshed.completed_at == nil
  end

  test "raced delivery closeout preserves the observed previous status", %{repo: repo} do
    {work_request, planned_slice, linked_package} = linked_slice!(repo, status: "reviewing")
    __MODULE__.RaceRepo.seed(linked_package, "closed")

    assert {:ok, closeout} =
             WorkPackageRepository.close_compatible_linked_delivery_package(
               __MODULE__.RaceRepo,
               work_request,
               planned_slice,
               "closed"
             )

    assert closeout.changed? == false
    assert closeout.previous_status == "reviewing"
    assert closeout.next_status == "closed"
    assert closeout.work_package.status == "closed"
  end

  test "linked package compatibility is validated before delivery is recorded", %{repo: repo} do
    {work_request, planned_slice, linked_package} = linked_slice!(repo, status: "reviewing")
    assert {:ok, _drifted} = WorkPackageRepository.update(repo, linked_package.id, %{title: "Drifted title"})

    assert {:error, :work_package_mismatch} =
             Service.record_planned_slice_delivery(
               repo,
               work_request.id,
               planned_slice.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "delivery-mismatched-package",
                 no_pr_evidence: "Operator confirmed the work landed elsewhere."
               })
             )

    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "reviewing"
  end

  test "active blockers prevent terminal package mutation", %{repo: repo} do
    {work_request, planned_slice, linked_package} = linked_slice!(repo, status: "reviewing")

    assert {:ok, _blocker} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: linked_package.id,
               summary: "Blocked",
               status: "blocked",
               idempotency_key: "closeout-active-blocker",
               payload: %{type: "blocker", source_tool: "report_blocker", blocker_id: "closeout", active: true}
             })

    assert {:error, :active_blocker} =
             Service.record_planned_slice_delivery(
               repo,
               work_request.id,
               planned_slice.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "delivery-active-blocker",
                 no_pr_evidence: "Operator confirmed the work landed elsewhere."
               })
             )

    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
    assert repo.get!(WorkPackage, linked_package.id).status == "reviewing"
  end

  test "active worker grants prevent closeout until explicitly revoked", %{repo: repo} do
    {work_request, planned_slice, linked_package} = linked_slice!(repo, status: "ready_for_human_merge")

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    assert {:ok, _closed} = WorkPackageRepository.update_status(repo, linked_package.id, "ready_for_human_merge", "closed")

    attrs =
      delivery_attrs(%{
        outcome: "completed_no_pr",
        idempotency_key: "delivery-active-worker-grant",
        no_pr_evidence: "Worker is complete, but the runtime grant still needs explicit closeout."
      })

    assert {:error, :active_runtime} = Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0

    assert {:ok, _revoked_grant} = AccessGrantService.revoke(repo, minted.grant.id)
    assert {:ok, delivery} = Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert delivery.outcome == "completed_no_pr"
    assert repo.get!(WorkPackage, linked_package.id).status == "closed"
  end

  test "unclaimed worker grants prevent closeout until explicitly revoked", %{repo: repo} do
    {work_request, planned_slice, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-DELIVERY-UNCLAIMED-WORKER-GRANT",
        status: "ready_for_human_merge"
      )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _closed} = WorkPackageRepository.update_status(repo, linked_package.id, "ready_for_human_merge", "closed")

    attrs =
      delivery_attrs(%{
        outcome: "completed_no_pr",
        idempotency_key: "delivery-unclaimed-worker-grant",
        no_pr_evidence: "A live worker grant still needs explicit revocation."
      })

    assert {:error, :active_runtime} = Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0

    assert {:ok, _revoked_grant} = AccessGrantService.revoke(repo, minted.grant.id)
    assert {:ok, delivery} = Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert delivery.outcome == "completed_no_pr"
    assert repo.get!(WorkPackage, linked_package.id).status == "closed"
  end

  test "active claim leases prevent closeout until explicitly released", %{repo: repo} do
    {work_request, planned_slice, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-DELIVERY-ACTIVE-CLAIM-LEASE",
        status: "ready_for_human_merge"
      )

    assert {:ok, claim_lease} =
             ClaimLeaseService.claim(
               repo,
               linked_package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:closeout-claim", "actor_display_name" => "worker-claim"},
               stale_after_ms: 60_000
             )

    assert {:ok, _closed} = WorkPackageRepository.update_status(repo, linked_package.id, "ready_for_human_merge", "closed")

    attrs =
      delivery_attrs(%{
        outcome: "completed_no_pr",
        idempotency_key: "delivery-active-claim-lease",
        no_pr_evidence: "The package status is terminal, but the live claim lease still needs release."
      })

    assert {:error, :active_runtime} = Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0

    assert {:ok, _released_lease} = ClaimLeaseService.release(repo, claim_lease.id, reason: "worker finished")
    assert {:ok, delivery} = Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert delivery.outcome == "completed_no_pr"
  end

  test "stale agent runs prevent closeout until explicitly stopped", %{repo: repo} do
    {work_request, planned_slice, linked_package} =
      linked_slice!(repo,
        work_request_id: "WR-DELIVERY-STALE-AGENT-RUN",
        status: "ready_for_human_merge"
      )

    assert {:ok, agent_run} =
             AgentRunRepository.start_run(repo, %{
               work_package_id: linked_package.id,
               status: "running",
               last_seen_at: DateTime.add(DateTime.utc_now(:microsecond), -301, :second)
             })

    assert {:ok, _closed} = WorkPackageRepository.update_status(repo, linked_package.id, "ready_for_human_merge", "closed")

    attrs =
      delivery_attrs(%{
        outcome: "completed_no_pr",
        idempotency_key: "delivery-stale-agent-run",
        no_pr_evidence: "The package status is terminal, but the stale AgentRun still needs explicit closeout."
      })

    assert {:error, :active_runtime} = Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0

    assert {:ok, _stopped_run} = AgentRunRepository.mark_stopped(repo, agent_run.id, "worker stopped")
    assert {:ok, delivery} = Service.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    assert delivery.outcome == "completed_no_pr"
  end

  defp linked_slice!(repo, overrides) do
    work_package_kind = Keyword.get(overrides, :work_package_kind, "mcp")
    status = Keyword.get(overrides, :status, "reviewing")
    request_id = Keyword.get_lazy(overrides, :work_request_id, fn -> "WR-DELIVERY-#{System.unique_integer([:positive])}" end)

    work_request = create_work_request!(repo, id: request_id, status: "ready_for_slicing")
    planned_slice = create_planned_slice!(repo, work_request, id: "WRS-#{request_id}", work_package_kind: work_package_kind)
    assert {:ok, approved_slice} = Repository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    work_package = create_matching_work_package!(repo, work_request, approved_slice, id: "WP-#{request_id}", status: status)
    assert {:ok, dispatched_slice} = Repository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", work_package.id)

    {work_request, dispatched_slice, work_package}
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = Repository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp create_planned_slice!(repo, work_request, overrides) do
    assert {:ok, planned_slice} = Repository.add_planned_slice(repo, work_request.id, planned_slice_attrs(overrides))
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

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-DELIVERY-#{System.unique_integer([:positive])}",
      title: "Close delivered WorkRequest slices",
      repo: "nextide/example",
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
      title: "Close delivered slice",
      goal: "Record terminal delivery state.",
      work_package_kind: "mcp",
      target_base_branch: "main",
      branch_pattern: "feat/delivery-closeout",
      owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery closeout is transactional."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/work_request_delivery_closeout_test.exs"],
      review_lanes: ["normal"],
      stop_conditions: ["Do not bypass phase-child merge semantics."]
    }

    Enum.into(overrides, defaults)
  end

  defp delivery_attrs(overrides) do
    defaults = %{
      idempotency_key: "delivery-#{System.unique_integer([:positive])}",
      recorded_by: "delivery-closeout-test"
    }

    Enum.into(overrides, defaults)
  end

  defp database_path do
    Path.join(System.tmp_dir!(), "sympp-work-request-delivery-closeout-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3")
  end

  defmodule RaceRepo do
    @moduledoc false

    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    def seed(%WorkPackage{} = package, next_status) when is_binary(next_status) do
      Process.put(__MODULE__, %{get_count: 0, next_status: next_status, package: package})
    end

    def get(WorkPackage, id) when is_binary(id) do
      %{get_count: get_count, next_status: next_status, package: %WorkPackage{id: ^id} = package} = Process.get(__MODULE__)
      Process.put(__MODULE__, %{get_count: get_count + 1, next_status: next_status, package: package})

      if get_count == 0 do
        package
      else
        %WorkPackage{package | status: next_status}
      end
    end

    def all(_query), do: []

    def update_all(_query, _updates), do: {0, []}
  end
end
