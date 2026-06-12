Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport05Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "claim_local_assignment rejects rebinding a server to another package", %{repo: repo} do
    first_package = create_local_claim_package!(repo, "SYMPP-LOCAL-REBIND-ONE")
    second_package = create_local_claim_package!(repo, "SYMPP-LOCAL-REBIND-TWO")
    assert {:ok, _first_minted} = AccessGrantService.mint_worker_grant(repo, first_package.id)
    assert {:ok, _second_minted} = AccessGrantService.mint_worker_grant(repo, second_package.id)

    {first_response, claimed_server} =
      Server.handle_response_state(
        tool_call("claim-one", "claim_local_assignment", local_assignment_claim_args(first_package)),
        local_mcp_server(local_mcp_config(repo), "local-rebind-state")
      )

    {same_response, same_server} =
      Server.handle_response_state(
        tool_call("claim-one-again", "claim_local_assignment", local_assignment_claim_args(first_package)),
        claimed_server
      )

    {rebind_response, _server} =
      Server.handle_response_state(
        tool_call("claim-two", "claim_local_assignment", local_assignment_claim_args(second_package, %{"claimed_by" => "local-worker-2"})),
        same_server
      )

    assert get_in(first_response, ["result", "structuredContent", "assignment", "work_package_id"]) == first_package.id
    assert get_in(same_response, ["result", "structuredContent", "assignment", "work_package_id"]) == first_package.id
    assert get_in(rebind_response, ["error", "data", "reason"]) == "session_already_bound"
    assert get_in(rebind_response, ["error", "data", "recovery", "category"]) == "session_binding"
    assert get_in(rebind_response, ["error", "data", "recovery", "next_action"]) == "use_fresh_mcp_session_or_release_current_assignment"
    assert get_in(rebind_response, ["error", "data", "recovery", "retry", "tool"]) == "release_current_assignment"
  end

  test "stdio local claim binds by WorkPackage id only", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STDIO-ID-ONLY-CLAIM")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, claimed_server} =
      Server.handle_response_state(
        tool_call("stdio-id-only-claim", "claim_local_assignment", %{"work_package_id" => package.id}),
        Server.new(test_mcp_config(repo), initialized: true)
      )

    assert get_in(response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(response, ["result", "structuredContent", "local_claim", "mode"]) == "stdio"
    assert claimed_server.session.assignment.work_package_id == package.id

    {reconnect_response, _server} =
      Server.handle_response_state(
        tool_call("stdio-id-only-reconnect", "claim_local_assignment", %{"work_package_id" => package.id}),
        Server.new(test_mcp_config(repo), initialized: true)
      )

    assert get_in(reconnect_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(reconnect_response, ["result", "structuredContent", "local_claim", "mode"]) == "stdio"
    assert get_in(reconnect_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "heartbeat"
  end

  test "batch local claim does not bind sibling batch items", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-BATCH-THREAD")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {responses, _server} =
      Server.handle_response_state(
        [
          tool_call("invalid-local-claim", "claim_local_assignment", Map.put(local_assignment_claim_args(package), "unexpected", "value")),
          tool_call("progress-before-claim", "append_progress", %{
            "summary" => "should not append",
            "idempotency_key" => "progress-before-local-claim"
          }),
          tool_call("valid-local-claim", "claim_local_assignment", local_assignment_claim_args(package)),
          tool_call("progress-after-claim", "append_progress", %{
            "summary" => "should append",
            "idempotency_key" => "progress-after-local-claim"
          })
        ],
        local_mcp_server(local_mcp_config(repo), "local-batch-thread-state")
      )

    assert get_in(Enum.at(responses, 0), ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(Enum.at(responses, 1), ["error", "data", "reason"]) == "claim_required"
    assert get_in(Enum.at(responses, 2), ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(Enum.at(responses, 3), ["error", "data", "reason"]) == "claim_required"
  end

  test "single-item batch preserves local claim session for later requests", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-SINGLE-BATCH")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    state_key = make_ref()
    server = local_mcp_server(local_mcp_config(repo), state_key)

    {responses, claimed_server} =
      Server.handle_response_state(
        [
          tool_call("single-batch-claim", "claim_local_assignment", local_assignment_claim_args(package))
        ],
        server
      )

    {read_response, _server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "assignment-after-single-batch", "method" => "tools/call", "params" => %{"name" => "get_current_assignment", "arguments" => %{}}},
        claimed_server
      )

    assert [claim_response] = responses
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(read_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  test "batch calls persist local claim session only after the batch completes", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-BATCH-NO-LEAK")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    server = local_mcp_server(local_mcp_config(repo), make_ref())

    {responses, claimed_server} =
      Server.handle_response_state(
        [
          tool_call("batch-claim", "claim_local_assignment", local_assignment_claim_args(package)),
          tool_call("batch-progress", "append_progress", %{
            "summary" => "in-batch progress",
            "idempotency_key" => "local-batch-progress"
          })
        ],
        server
      )

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment-outside-batch", "method" => "tools/call", "params" => %{"name" => "get_current_assignment", "arguments" => %{}}},
        server
      )

    assert get_in(Enum.at(responses, 0), ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(Enum.at(responses, 1), ["error", "data", "reason"]) == "claim_required"
    assert claimed_server.session.assignment.work_package_id == package.id
    assert get_in(assignment_response, ["error", "data", "reason"]) == "claim_required"
  end

  defp tool_call(id, name, arguments) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}}
  end
end
