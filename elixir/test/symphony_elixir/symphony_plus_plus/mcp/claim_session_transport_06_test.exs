Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport06Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "batch claim guard ignores earlier non-claim items on bound sessions", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-BATCH-BOUND-CLAIM")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    {responses, server} =
      Server.handle_state(
        [
          %{"jsonrpc" => "2.0", "id" => "context", "method" => "tools/call", "params" => %{"name" => "read_context"}},
          %{
            "jsonrpc" => "2.0",
            "id" => "claim",
            "method" => "tools/call",
            "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package, %{"claimed_by" => "worker-1"})}
          }
        ],
        %{local_mcp_server(local_mcp_config(repo), "local-bound-batch-claim-state") | session: session}
      )

    assert Enum.map(responses, & &1["id"]) == ["context", "claim"]
    assert get_in(Enum.at(responses, 1), ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert server.session.assignment.work_package_id == package.id
  end

  test "batch final state keeps refreshed local claim session after later non-claim items", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-BATCH-REFRESHED-CLAIM")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    stale_assignment = %{assignment | capabilities: []}
    stale_session = Session.new(stale_assignment, proof_hash: minted.grant.secret_hash)

    {responses, server} =
      Server.handle_state(
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "claim",
            "method" => "tools/call",
            "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package, %{"claimed_by" => "worker-1"})}
          },
          %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}}
        ],
        %{local_mcp_server(local_mcp_config(repo), "local-refreshed-batch-claim-state") | session: stale_session}
      )

    assert Enum.map(responses, & &1["id"]) == ["claim", "assignment"]
    assert get_in(Enum.at(responses, 0), ["result", "structuredContent", "assignment", "capabilities"]) == minted.grant.capabilities
    assert server.session.assignment.capabilities == minted.grant.capabilities
  end
end
