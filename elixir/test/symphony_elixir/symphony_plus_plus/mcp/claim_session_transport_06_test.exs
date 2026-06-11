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

  test "batch claim guard returns unauthorized after an earlier claim binds the batch", %{repo: repo} do
    first_package = create_local_claim_package!(repo, "SYMPP-BATCH-FIRST-CLAIM")
    second_package = create_local_claim_package!(repo, "SYMPP-BATCH-SECOND-CLAIM")
    assert {:ok, _first_minted} = AccessGrantService.mint_worker_grant(repo, first_package.id)
    assert {:ok, _second_minted} = AccessGrantService.mint_worker_grant(repo, second_package.id)

    {responses, server} =
      Server.handle_state(
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "claim-first",
            "method" => "tools/call",
            "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(first_package)}
          },
          %{
            "jsonrpc" => "2.0",
            "id" => "claim-second",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_local_assignment",
              "arguments" => local_assignment_claim_args(second_package, %{"claimed_by" => "worker-2"})
            }
          }
        ],
        local_mcp_server(local_mcp_config(repo), "local-batch-double-claim-state")
      )

    first_response = Enum.at(responses, 0)
    second_response = Enum.at(responses, 1)

    assert get_in(first_response, ["result", "structuredContent", "assignment", "work_package_id"]) == first_package.id
    assert get_in(second_response, ["error", "data", "reason"]) == "session_already_bound"
    assert get_in(second_response, ["error", "data", "action"]) == "use_fresh_mcp_session_or_release_current_assignment"

    assert get_in(second_response, ["error", "data", "current_assignment"]) == %{
             "grant_role" => "worker",
             "work_package_id" => first_package.id,
             "claimed_by" => "local-worker-1",
             "repo" => first_package.repo,
             "base_branch" => first_package.base_branch
           }

    assert server.session.assignment.work_package_id == first_package.id
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
