defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.MetadataProjectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.MetadataProjection
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent

  test "metadata prefers the current-head PR sync after PR attachment" do
    events = [
      progress_event("branch", 1, %{
        "type" => "branch",
        "source_tool" => "attach_branch",
        "branch" => "agent/wp-1",
        "head_sha" => "head-a"
      }),
      progress_event("attach-pr", 2, %{
        "type" => "pr",
        "source_tool" => "attach_pr",
        "repository" => "NextIDE/symphony-plus-plus",
        "number" => 17,
        "head_sha" => "head-a"
      }),
      progress_event("sync-pr", 3, %{
        "type" => "pr",
        "source_tool" => "sync_pr",
        "repository" => "nextide/symphony-plus-plus",
        "number" => 17,
        "head_sha" => "head-a",
        "check_summary" => %{"status" => "success"}
      })
    ]

    metadata = MetadataProjection.metadata(events, [], "wp-1")

    assert metadata.branch["head_sha"] == "head-a"
    assert metadata.pr["head_sha"] == "head-a"
    assert metadata.pr["current_head_sha"] == "head-a"
    refute metadata.pr["stale"]
  end

  defp progress_event(id, sequence, payload) do
    %ProgressEvent{
      id: id,
      sequence: sequence,
      payload: payload,
      created_at: DateTime.add(~U[2026-05-01 00:00:00Z], sequence, :second)
    }
  end
end
