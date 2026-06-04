Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ProductTreeRevisionIdempotencyTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Revision
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery

  test "delivery replay does not record another product tree revision", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-DELIVERY-REVISION-REPLAY", status: "sliced")

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-DELIVERY-REVISION-REPLAY")
             )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, work_request, ArchitectHandoff.capabilities())

    args = %{
      "work_request_id" => work_request.id,
      "planned_slice_id" => planned_slice.id,
      "outcome" => "completed_no_pr",
      "no_pr_evidence" => "Operator confirmed the no-PR closeout.",
      "idempotency_key" => "delivery-revision-replay"
    }

    closeout = mcp_tool(repo, session, "record_planned_slice_delivery", args)
    assert get_in(closeout, ["result", "structuredContent", "planned_slice_delivery", "id"])
    assert revision_count(repo, work_request.id) == 1

    replay = mcp_tool(repo, session, "record_planned_slice_delivery", args)

    assert get_in(replay, ["result", "structuredContent", "planned_slice_delivery", "id"]) ==
             get_in(closeout, ["result", "structuredContent", "planned_slice_delivery", "id"])

    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 1
    assert revision_count(repo, work_request.id) == 1
  end

  defp revision_count(repo, work_request_id) do
    Revision
    |> repo.all()
    |> Enum.count(&(&1.work_request_id == work_request_id))
  end
end
