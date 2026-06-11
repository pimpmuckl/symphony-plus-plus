Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport03Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "claim_local_architect_assignment claims and reconnects a WorkRequest architect session with only the WorkRequest id", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-CLAIM",
        status: "ready_for_clarification"
      )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, handoff.grant.id)
    assert is_nil(unclaimed_grant.claimed_at)
    repo.delete_all(from(scope in GrantScope, where: scope.access_grant_id == ^handoff.grant.id))
    assert {:ok, []} = AccessGrantRepository.list_scopes(repo, handoff.grant.id)

    arguments = %{"work_request_id" => work_request.id}

    state_key = "local-architect-claim-state"
    config = %{local_mcp_config(repo) | claimed_by: "generic-config-owner"}

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => arguments}
        },
        local_mcp_server(config, state_key)
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == handoff.anchor_package.id
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "claimed_by"]) == ArchitectHandoff.claimed_by()
    assert get_in(claim_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "created"
    assert claimed_server.session.assignment.grant_role == "architect"
    assert Scope.work_request(work_request.id) in claimed_server.session.assignment.scopes
    assert claimed_server.session.proof_hash == unclaimed_grant.secret_hash
    refute inspect(claim_response) =~ unclaimed_grant.secret_hash
    refute inspect(claim_response) =~ "private_handoff"

    assert {:ok, claimed_grant} = AccessGrantRepository.get(repo, handoff.grant.id)
    assert claimed_grant.claimed_by == ArchitectHandoff.claimed_by()
    assert {:ok, scope_rows} = AccessGrantRepository.list_scopes(repo, handoff.grant.id)
    assert Enum.any?(scope_rows, &(&1.scope_type == "work_request" and &1.scope_id == work_request.id))

    read_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-read-work-request",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => %{"work_request_id" => work_request.id}}
        },
        claimed_server
      )

    assert get_in(read_response, ["result", "structuredContent", "work_request", "id"]) == work_request.id

    {reconnect_response, reconnected_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-reconnect",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => arguments}
        },
        local_mcp_server(config, state_key)
      )

    assert get_in(reconnect_response, ["result", "structuredContent", "assignment", "grant_id"]) == handoff.grant.id
    assert get_in(reconnect_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "heartbeat"
    assert reconnected_server.session.assignment.grant_role == "architect"
    assert Scope.work_request(work_request.id) in reconnected_server.session.assignment.scopes

    {reboot_response, rebooted_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-reboot-reclaim",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => Map.put(arguments, "caller_id", "codex-local-architect-reboot")
          }
        },
        local_mcp_server(config, "local-architect-reboot-state")
      )

    assert get_in(reboot_response, ["result", "structuredContent", "assignment", "grant_id"]) == handoff.grant.id
    assert get_in(reboot_response, ["result", "structuredContent", "local_claim", "caller_id"]) == "codex-local-architect-reboot"
    assert get_in(reboot_response, ["result", "structuredContent", "local_claim", "claimed_by"]) == ArchitectHandoff.claimed_by()
    assert get_in(reboot_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "heartbeat"
    assert rebooted_server.session.assignment.grant_role == "architect"
    assert Scope.work_request(work_request.id) in rebooted_server.session.assignment.scopes
  end

  test "claim_local_architect_assignment reports missing prepared handoff for existing WorkRequests", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-MISSING-HANDOFF",
        status: "ready_for_clarification"
      )

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-missing-handoff",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{"work_request_id" => work_request.id, "claimed_by" => "local-architect-1"}
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-missing-handoff-state")
      )

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "architect_handoff_not_prepared"
    assert get_in(response, ["error", "data", "action"]) == "prepare_architect_handoff"
    assert get_in(response, ["error", "data", "work_request_id"]) == work_request.id

    assert get_in(response, ["error", "data", "expected_architect_anchor_work_package_id"]) ==
             ArchitectHandoff.anchor_id_for_work_request(work_request)

    assert get_in(response, ["error", "data", "expected_phase_id"]) == ArchitectHandoff.phase_id_for_work_request(work_request)
    assert get_in(response, ["error", "data", "hint"]) =~ "prepare the architect handoff"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, ArchitectHandoff.anchor_id_for_work_request(work_request))

    {phase_mismatch_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-missing-handoff-phase-mismatch",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{"work_request_id" => work_request.id, "phase_id" => "phase-stale"}
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-missing-handoff-phase-mismatch-state")
      )

    assert get_in(phase_mismatch_response, ["error", "data", "reason"]) == "phase_scope_mismatch"

    {repo_mismatch_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-missing-handoff-repo-mismatch",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{"work_request_id" => work_request.id, "repo" => "nextide/other"}
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-missing-handoff-repo-mismatch-state")
      )

    assert get_in(repo_mismatch_response, ["error", "data", "reason"]) == "repo_scope_mismatch"
  end

  test "claim_local_architect_assignment reports the current binding before rebinding", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-ARCHITECT-CLAIM-BOUND-WORKER", base_branch: "main")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-BOUND-SESSION",
        status: "ready_for_clarification"
      )

    assert {:ok, _handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    {worker_response, worker_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-worker-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-bound-worker-state")
      )

    assert get_in(worker_response, ["result", "structuredContent", "assignment", "grant_role"]) == "worker"

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-rebind",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => %{"work_request_id" => work_request.id}}
        },
        worker_server
      )

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "session_already_bound"
    assert get_in(response, ["error", "data", "action"]) == "use_fresh_mcp_session_or_release_current_assignment"
    assert get_in(response, ["error", "data", "hint"]) =~ "fresh MCP session"

    assert get_in(response, ["error", "data", "current_assignment"]) == %{
             "grant_role" => "worker",
             "work_package_id" => package.id,
             "claimed_by" => "local-worker-1",
             "repo" => package.repo,
             "base_branch" => package.base_branch
           }
  end

  test "claim_local_architect_assignment can read trusted same-repo WorkRequests without widening writes", %{repo: repo} do
    previous_trusted_remotes = Application.get_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)
    Application.put_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes, ["https://github.com/Pimpmuckl/symphony-plus-plus.git"])

    on_exit(fn -> restore_app_env(:sympp_repo_identity_trusted_remotes, previous_trusted_remotes) end)

    owner =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-OWNER",
        status: "ready_for_slicing"
      )

    same_repo =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-SAME-REPO",
        repo: owner.repo,
        base_branch: owner.base_branch,
        status: "ready_for_slicing"
      )

    other_repo =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-OTHER-REPO",
        repo: "nextide/other",
        base_branch: owner.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, _handoff} =
             ArchitectHandoff.create_or_replay(repo, owner.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-claim",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{"work_request_id" => owner.id, "claimed_by" => "local-architect-1"}
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-same-repo-state")
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"

    same_repo_read =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "same-repo-read",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => %{"work_request_id" => same_repo.id}}
        },
        claimed_server
      )

    other_repo_read =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "other-repo-read",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => %{"work_request_id" => other_repo.id}}
        },
        claimed_server
      )

    same_repo_write =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "same-repo-write",
          "method" => "tools/call",
          "params" => %{
            "name" => "record_work_request_decision",
            "arguments" => %{
              "work_request_id" => same_repo.id,
              "source_type" => "architect",
              "decision" => "Attempt write outside owner WorkRequest.",
              "rationale" => "This should stay scoped.",
              "scope_impact" => "No change.",
              "created_by" => "local-architect-1"
            }
          }
        },
        claimed_server
      )

    assert get_in(same_repo_read, ["result", "structuredContent", "work_request", "id"]) == same_repo.id
    assert get_in(other_repo_read, ["error", "data", "reason"]) == "not_found"
    assert get_in(same_repo_write, ["error", "data", "reason"]) == "not_found"
  end

  test "claim_local_architect_assignment rejects mismatched optional scope hints", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-MISMATCH",
        status: "ready_for_clarification"
      )

    assert {:ok, _handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-mismatch",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "repo" => "nextide/other",
              "claimed_by" => "local-architect-1"
            }
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-mismatch-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "repo_scope_mismatch"
  end

  test "claim_local_architect_assignment rejects stale explicit anchor hints as scope mismatches", %{repo: repo} do
    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-STALE-ANCHOR",
        status: "ready_for_clarification"
      )

    assert {:ok, _handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               handoff_opts: handoff_opts(repo)
             )

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-stale-anchor",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "architect_anchor_work_package_id" => "SYMPP-WR-ARCH-stale"
            }
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-stale-anchor-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "architect_anchor_scope_mismatch"
  end

  defp handoff_opts(repo) do
    [claimed_by: ArchitectHandoff.claimed_by(), database: repo.database_path(), local_architect_claim?: true]
  end
end
