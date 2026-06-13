Code.require_file("api_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.WorkRequestDeliveryProjectionTest do
  use SymphonyElixir.SymphonyPlusPlus.Dashboard.ApiCase, async: false

  test "WorkRequest detail preserves delivery-board closeout and delivery slice payloads", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-DASH-DELIVERY-BOARD")

    closeout_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-NEEDS-CLOSEOUT")
    closeout_package = create_matching_work_package!(repo, work_request, closeout_slice, id: "SYMPP-DASH-NEEDS-CLOSEOUT", status: "ready_for_human_merge")

    assert {:ok, _dispatched_closeout} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, closeout_slice.id, "approved", closeout_package.id)

    assert {:ok, _attached_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: closeout_package.id,
               summary: "PR attached",
               status: "pr_attached",
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/903",
                 head_sha: "head-903"
               }
             })

    assert {:ok, _merged_pr} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: closeout_package.id,
               summary: "PR merged",
               status: "pr_synced",
               payload: %{
                 type: "pr",
                 source_tool: "sync_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/903",
                 head_sha: "head-903",
                 merge_state: %{merged: true}
               }
             })

    no_pr_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-NO-PR")
    no_pr_package = create_matching_work_package!(repo, work_request, no_pr_slice, id: "SYMPP-DASH-NO-PR", status: "closed")

    assert {:ok, _dispatched_no_pr} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, no_pr_slice.id, "approved", no_pr_package.id)

    assert {:ok, _no_pr_delivery} =
             WorkRequestRepository.record_planned_slice_delivery(
               repo,
               work_request.id,
               no_pr_slice.id,
               delivery_attrs(%{
                 outcome: "completed_no_pr",
                 idempotency_key: "dashboard-delivery-board-no-pr",
                 no_pr_evidence: "Operator confirmed direct completion."
               })
             )

    superseded_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-SUPERSEDED")
    superseded_package = create_matching_work_package!(repo, work_request, superseded_slice, id: "SYMPP-DASH-SUPERSEDED", status: "closed")

    assert {:ok, _dispatched_superseded} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, superseded_slice.id, "approved", superseded_package.id)

    successor_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-SUCCESSOR")
    successor_package = create_matching_work_package!(repo, work_request, successor_slice, id: "SYMPP-DASH-SUCCESSOR", status: "ready_for_worker")

    assert {:ok, _successor_dispatch} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, successor_slice.id, "approved", successor_package.id)

    assert {:ok, _superseded_delivery} =
             WorkRequestRepository.record_planned_slice_delivery(
               repo,
               work_request.id,
               superseded_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "dashboard-delivery-board-superseded",
                 successor_planned_slice_id: successor_slice.id,
                 successor_work_package_id: successor_package.id,
                 superseded_reason: "Replaced by successor package."
               })
             )

    merged_delivery_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-RECORDED-MERGED")

    merged_delivery_package =
      create_matching_work_package!(repo, work_request, merged_delivery_slice,
        id: "SYMPP-DASH-RECORDED-MERGED",
        status: "ready_for_worker"
      )

    assert {:ok, _merged_delivery_progress} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: merged_delivery_package.id,
               summary: "Worker progress exists",
               status: "progress",
               payload: %{type: "progress"}
             })

    assert {:ok, _dispatched_merged_delivery} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               merged_delivery_slice.id,
               "approved",
               merged_delivery_package.id
             )

    assert {:ok, _merged_delivery} =
             WorkRequestRepository.record_planned_slice_delivery(
               repo,
               work_request.id,
               merged_delivery_slice.id,
               delivery_attrs(%{
                 outcome: "pr_merged",
                 idempotency_key: "dashboard-delivery-board-pr-merged",
                 pr_url: "https://github.com/nextide/symphony-plus-plus/pull/904",
                 pr_merged_at: ~U[2026-05-24 12:00:00.000000Z],
                 merge_commit_sha: "merge-904"
               })
             )

    filtered_successor_slice = add_approved_slice!(repo, work_request, id: "WRS-DASH-FILTERED-SUCCESSOR")

    filtered_successor_package =
      create_matching_work_package!(repo, work_request, filtered_successor_slice,
        id: "SYMPP-DASH-FILTERED-SUCCESSOR",
        status: "closed"
      )

    assert {:ok, _filtered_successor_dispatch} =
             WorkRequestRepository.dispatch_planned_slice(
               repo,
               work_request.id,
               filtered_successor_slice.id,
               "approved",
               filtered_successor_package.id
             )

    out_of_scope_successor_package =
      create_work_package!(repo,
        id: "SYMPP-DASH-OUT-OF-SCOPE-SUCCESSOR",
        status: "ready_for_worker",
        repo: work_request.repo,
        base_branch: "other-base"
      )

    assert {:error, :not_found} =
             WorkRequestRepository.record_planned_slice_delivery(
               repo,
               work_request.id,
               filtered_successor_slice.id,
               delivery_attrs(%{
                 outcome: "superseded",
                 idempotency_key: "dashboard-delivery-board-filtered-successor",
                 successor_planned_slice_id: successor_slice.id,
                 successor_work_package_id: out_of_scope_successor_package.id,
                 superseded_reason: "Out-of-scope successor should remain hidden."
               })
             )

    assert {:ok, payload} = Dashboard.work_request_detail(repo, work_request.id)

    assert payload.delivery_board["slice_count"] == 6
    slices_by_id = Map.new(payload.delivery_board["slices"], &{&1["id"], &1})

    assert get_in(slices_by_id, ["WRS-DASH-NEEDS-CLOSEOUT", "operational_state", "key"]) == "needs_closeout"
    assert get_in(slices_by_id, ["WRS-DASH-NEEDS-CLOSEOUT", "attention_reason_codes"]) == ["pr_merged_without_delivery_outcome"]
    assert get_in(slices_by_id, ["WRS-DASH-NO-PR", "delivery", "outcome"]) == "completed_no_pr"
    assert get_in(slices_by_id, ["WRS-DASH-NO-PR", "operational_state", "key"]) == "completed_no_pr"
    assert get_in(slices_by_id, ["WRS-DASH-RECORDED-MERGED", "delivery", "outcome"]) == "pr_merged"
    assert get_in(slices_by_id, ["WRS-DASH-RECORDED-MERGED", "operational_state", "key"]) == "delivered"
    assert get_in(slices_by_id, ["WRS-DASH-SUPERSEDED", "successor", "work_package", "id"]) == successor_package.id
    assert get_in(slices_by_id, ["WRS-DASH-FILTERED-SUCCESSOR", "successor", "work_package"]) == nil
    assert get_in(slices_by_id, ["WRS-DASH-FILTERED-SUCCESSOR", "successor", "work_package_id"]) == nil

    planned_slices_by_id = Map.new(payload.planned_slices, &{&1.id, &1})

    assert Map.fetch!(planned_slices_by_id, "WRS-DASH-NEEDS-CLOSEOUT").operational_state.key == "needs_closeout"
    assert get_in(Map.fetch!(planned_slices_by_id, "WRS-DASH-NO-PR"), [:delivery, "outcome"]) == "completed_no_pr"
    assert Map.fetch!(planned_slices_by_id, "WRS-DASH-NO-PR").operational_state.label == "Completed Without PR"
    assert get_in(Map.fetch!(planned_slices_by_id, "WRS-DASH-RECORDED-MERGED"), [:delivery, "outcome"]) == "pr_merged"

    merged_slice = Map.fetch!(planned_slices_by_id, "WRS-DASH-RECORDED-MERGED")
    assert merged_slice.operational_state.key == "delivered"
    assert merged_slice.operational_state.label == "Delivered"
    assert merged_slice.operational_state.raw_status == "dispatched"
    assert merged_slice.operational_state.work_package_status == "ready_for_worker"
    assert merged_slice.operational_state.has_started == true
    assert merged_slice.operational_state.is_stale == true
    assert Enum.any?(merged_slice.operational_state.attention_items, &(&1.key == "ready_for_worker_with_activity"))
    assert "linked_package_status_stale_after_delivery" in merged_slice.attention_reason_codes

    assert Map.fetch!(planned_slices_by_id, "WRS-DASH-SUPERSEDED").operational_state.key == "superseded"
    assert get_in(Map.fetch!(planned_slices_by_id, "WRS-DASH-SUPERSEDED"), [:successor, "work_package", "id"]) == successor_package.id
    assert payload.work_request.completed_at == nil
  end

  defp add_approved_slice!(repo, work_request, overrides) do
    assert {:ok, planned_slice} = WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(overrides))
    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    approved_slice
  end
end
