Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport03Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "claim_private_handoff binds an architect session from redacted local-private-file metadata", %{repo: repo} do
    store_dir = Path.join(test_handoff_store_dir(), "private-architect-claim")
    previous_store_dir = Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir)
    Application.put_env(:symphony_elixir, :sympp_worker_secret_store_dir, store_dir)

    on_exit(fn ->
      restore_app_env(:sympp_worker_secret_store_dir, previous_store_dir)
      File.rm_rf(store_dir)
    end)

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-PRIVATE-HANDOFF-CLAIM",
        status: "ready_for_clarification"
      )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: [
                 mode: "local-private-file",
                 repo_root: test_repo_root(),
                 store_dir: store_dir,
                 claimed_by: ArchitectHandoff.claimed_by()
               ]
             )

    private_handoff = json_payload(handoff.secret_handoff)
    assert private_handoff["mode"] == "local-private-file"
    refute Map.has_key?(private_handoff, "secret")
    refute Map.has_key?(private_handoff, "secret_hash")
    refute Map.has_key?(private_handoff, "run_mcp_command")

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-private-handoff",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_private_handoff",
            "arguments" => %{"claimed_by" => "kraken-beta-arch", "private_handoff" => private_handoff}
          }
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == handoff.anchor_package.id
    assert claimed_server.session.assignment.grant_role == "architect"
    assert handoff_secret_absent?(private_handoff, inspect(claim_response))

    read_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "read-claimed-work-request",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => %{"work_request_id" => work_request.id}}
        },
        claimed_server
      )

    assert get_in(read_response, ["result", "structuredContent", "work_request", "id"]) == work_request.id
    assert handoff_secret_absent?(private_handoff, inspect(read_response))
  end

  test "claim_local_architect_assignment claims and reconnects a WorkRequest architect session", %{repo: repo} do
    store_dir = Path.join(test_handoff_store_dir(), "local-architect-claim")
    previous_store_dir = Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir)
    Application.put_env(:symphony_elixir, :sympp_worker_secret_store_dir, store_dir)

    on_exit(fn ->
      restore_app_env(:sympp_worker_secret_store_dir, previous_store_dir)
      File.rm_rf(store_dir)
    end)

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-CLAIM",
        status: "ready_for_clarification"
      )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: [
                 mode: "local-private-file",
                 repo_root: test_repo_root(),
                 store_dir: store_dir,
                 claimed_by: ArchitectHandoff.claimed_by()
               ]
             )

    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, handoff.grant.id)
    assert is_nil(unclaimed_grant.claimed_at)
    repo.delete_all(from(scope in GrantScope, where: scope.access_grant_id == ^handoff.grant.id))
    assert {:ok, []} = AccessGrantRepository.list_scopes(repo, handoff.grant.id)

    arguments = %{
      "work_request_id" => work_request.id,
      "architect_anchor_work_package_id" => handoff.anchor_package.id,
      "repo" => work_request.repo,
      "base_branch" => work_request.base_branch,
      "caller_id" => "codex-local-architect-test",
      "claimed_by" => "local-architect-1"
    }

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-claim-state")
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == handoff.anchor_package.id
    assert get_in(claim_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "created"
    assert claimed_server.session.assignment.grant_role == "architect"
    assert Scope.work_request(work_request.id) in claimed_server.session.assignment.scopes
    assert claimed_server.session.proof_hash == unclaimed_grant.secret_hash
    refute inspect(claim_response) =~ unclaimed_grant.secret_hash

    assert {:ok, claimed_grant} = AccessGrantRepository.get(repo, handoff.grant.id)
    assert claimed_grant.claimed_by == "local-architect-1"
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

    guidance_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-list-guidance",
          "method" => "tools/call",
          "params" => %{"name" => "list_guidance_requests", "arguments" => %{}}
        },
        claimed_server
      )

    assert get_in(guidance_response, ["result", "structuredContent", "guidance_requests"]) == []

    decision_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-record-decision",
          "method" => "tools/call",
          "params" => %{
            "name" => "record_work_request_decision",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "source_type" => "architect",
              "decision" => "Use the local architect claim flow.",
              "rationale" => "The local session has non-secret ledger metadata.",
              "scope_impact" => "No private handoff is needed for normal reconnect.",
              "created_by" => "local-architect-1"
            }
          }
        },
        claimed_server
      )

    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "created_by"]) == "local-architect-1"

    assert {:ok, comment} =
             CommentService.create(repo, %{
               target_kind: "work_request",
               target_id: work_request.id,
               body: "Architect visible note",
               source_type: "operator",
               author_name: "operator"
             })

    list_comments_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-list-comments",
          "method" => "tools/call",
          "params" => %{
            "name" => "list_comments",
            "arguments" => %{"target_kind" => "work_request", "target_id" => work_request.id}
          }
        },
        claimed_server
      )

    assert [%{"id" => comment_id}] = get_in(list_comments_response, ["result", "structuredContent", "comments"])
    assert comment_id == comment.id

    {other_runtime_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-other-runtime",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_architect_assignment",
            "arguments" => Map.put(arguments, "caller_id", "codex-local-architect-other-runtime")
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-other-runtime-state")
      )

    assert get_in(other_runtime_response, ["error", "data", "reason"]) == "claim_lease_active_for_other_actor"
    assert get_in(other_runtime_response, ["error", "data", "action"]) == "reuse_claim_identity_or_recycle_stale_claim"
    assert get_in(other_runtime_response, ["error", "data", "hint"]) =~ "claimed_by unchanged"

    {reconnect_response, reconnected_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-reconnect",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => Map.put(arguments, "phase_id", handoff.phase.id)}
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-reconnect-state")
      )

    assert get_in(reconnect_response, ["result", "structuredContent", "assignment", "grant_id"]) == handoff.grant.id
    assert get_in(reconnect_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "heartbeat"
    assert reconnected_server.session.assignment.grant_role == "architect"
    assert Scope.work_request(work_request.id) in reconnected_server.session.assignment.scopes
  end

  test "claim_local_architect_assignment can read trusted same-repo WorkRequests without widening writes", %{repo: repo} do
    store_dir = Path.join(test_handoff_store_dir(), "local-architect-cross-wr-read")
    previous_store_dir = Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir)
    previous_trusted_remotes = Application.get_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)

    Application.put_env(:symphony_elixir, :sympp_worker_secret_store_dir, store_dir)
    Application.put_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes, ["https://github.com/Pimpmuckl/symphony-plus-plus.git"])

    on_exit(fn ->
      restore_app_env(:sympp_worker_secret_store_dir, previous_store_dir)
      restore_app_env(:sympp_repo_identity_trusted_remotes, previous_trusted_remotes)
      File.rm_rf(store_dir)
    end)

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-ALIAS",
        repo: "symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-ALIAS-SIBLING",
        repo: "Pimpmuckl/symphony-plus-plus",
        base_branch: work_request.base_branch,
        status: "ready_for_slicing"
      )

    other_owner =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-ALIAS-OTHER-OWNER",
        repo: "Elsewhere/symphony-plus-plus",
        base_branch: work_request.base_branch,
        status: "ready_for_slicing"
      )

    other_base =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-ALIAS-OTHER-BASE",
        repo: sibling.repo,
        base_branch: "release/local-architect-alias",
        status: "ready_for_slicing"
      )

    assert {:ok, board_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               sibling.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-LOCAL-ARCHITECT-ALIAS-BOARD", target_base_branch: sibling.base_branch)
             )

    assert {:ok, board_slice} = WorkRequestRepository.approve_planned_slice(repo, sibling.id, board_slice.id, "planned")

    assert {:ok, sibling_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-MCP-LOCAL-ARCHITECT-ALIAS-PKG",
                 kind: "mcp",
                 repo: sibling.repo,
                 base_branch: sibling.base_branch,
                 branch_pattern: board_slice.branch_pattern,
                 title: board_slice.title,
                 product_description: sibling.human_description,
                 engineering_scope: board_slice.goal,
                 allowed_file_globs: board_slice.owned_file_globs,
                 acceptance_criteria: board_slice.acceptance_criteria,
                 status: "planning"
               )
             )

    assert {:ok, _dispatched_board_slice} =
             WorkRequestRepository.dispatch_planned_slice(repo, sibling.id, board_slice.id, "approved", sibling_package.id)

    assert {:ok, mutation_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               sibling.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-LOCAL-ARCHITECT-ALIAS-MUTATION", target_base_branch: sibling.base_branch)
             )

    assert {:ok, mutation_slice} = WorkRequestRepository.approve_planned_slice(repo, sibling.id, mutation_slice.id, "planned")

    assert {:ok, cross_base_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               sibling.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-LOCAL-ARCHITECT-ALIAS-CROSS-BASE", target_base_branch: other_base.base_branch)
             )

    assert {:ok, cross_base_slice} = WorkRequestRepository.approve_planned_slice(repo, sibling.id, cross_base_slice.id, "planned")

    assert {:ok, cross_base_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-MCP-LOCAL-ARCHITECT-ALIAS-CROSS-BASE-PKG",
                 kind: "mcp",
                 repo: sibling.repo,
                 base_branch: cross_base_slice.target_base_branch,
                 branch_pattern: cross_base_slice.branch_pattern,
                 title: cross_base_slice.title,
                 product_description: sibling.human_description,
                 engineering_scope: cross_base_slice.goal,
                 allowed_file_globs: cross_base_slice.owned_file_globs,
                 acceptance_criteria: cross_base_slice.acceptance_criteria,
                 status: "planning"
               )
             )

    assert {:ok, _dispatched_cross_base_slice} =
             WorkRequestRepository.dispatch_planned_slice(repo, sibling.id, cross_base_slice.id, "approved", cross_base_package.id)

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: [
                 mode: "local-private-file",
                 repo_root: test_repo_root(),
                 store_dir: store_dir,
                 claimed_by: ArchitectHandoff.claimed_by()
               ]
             )

    arguments = %{
      "work_request_id" => work_request.id,
      "architect_anchor_work_package_id" => handoff.anchor_package.id,
      "repo" => work_request.repo,
      "base_branch" => work_request.base_branch,
      "caller_id" => "codex-local-architect-alias-test",
      "claimed_by" => "local-architect-alias"
    }

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-alias-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-alias-state")
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert Scope.work_request(work_request.id) in claimed_server.session.assignment.scopes

    call = fn name, args ->
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => name,
          "method" => "tools/call",
          "params" => %{"name" => name, "arguments" => args}
        },
        claimed_server
      )
    end

    list_response = call.("list_work_requests", %{"status" => "ready_for_slicing"})
    listed_ids = list_response |> get_in(["result", "structuredContent", "work_requests"]) |> Enum.map(& &1["id"])

    assert work_request.id in listed_ids
    assert sibling.id in listed_ids
    refute other_owner.id in listed_ids
    refute other_base.id in listed_ids

    read_response = call.("read_work_request", %{"work_request_id" => sibling.id})
    read_payload = get_in(read_response, ["result", "structuredContent"])
    read_slice_ids = Enum.map(read_payload["planned_slices"], & &1["id"])

    assert read_payload["work_request"]["id"] == sibling.id
    assert board_slice.id in read_slice_ids
    assert mutation_slice.id in read_slice_ids
    assert cross_base_slice.id in read_slice_ids

    board_response = call.("read_work_request_delivery_board", %{"work_request_id" => sibling.id})
    board_slices = get_in(board_response, ["result", "structuredContent", "delivery_board", "slices"])

    assert get_in(board_response, ["result", "structuredContent", "work_request", "id"]) == sibling.id
    assert Enum.any?(board_slices, &(get_in(&1, ["work_package", "id"]) == sibling_package.id))
    refute Enum.any?(board_slices, &(get_in(&1, ["work_package", "id"]) == cross_base_package.id))

    for out_of_scope <- [other_owner, other_base] do
      out_of_scope_response = call.("read_work_request", %{"work_request_id" => out_of_scope.id})
      assert get_in(out_of_scope_response, ["error", "code"]) == -32_004
      assert get_in(out_of_scope_response, ["error", "data", "reason"]) == "not_found"
      refute inspect(out_of_scope_response) =~ out_of_scope.id
    end

    sibling_status_response =
      call.("set_work_request_status", %{
        "work_request_id" => sibling.id,
        "current_status" => "ready_for_slicing",
        "next_status" => "sliced"
      })

    sibling_add_slice_response =
      call.("add_work_request_planned_slice", %{
        "work_request_id" => sibling.id,
        "title" => "Sibling mutation",
        "goal" => "This should be denied.",
        "work_package_kind" => "mcp",
        "target_base_branch" => sibling.base_branch,
        "owned_file_globs" => ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
        "forbidden_file_globs" => [],
        "acceptance_criteria" => ["Sibling mutation remains denied."],
        "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
        "review_lanes" => ["normal"],
        "stop_conditions" => ["Stop before mutating siblings."]
      })

    sibling_dispatch_response =
      call.("dispatch_work_request_planned_slice", %{
        "work_request_id" => sibling.id,
        "planned_slice_id" => mutation_slice.id,
        "claimed_by" => "sibling-worker"
      })

    sibling_delivery_response =
      call.("record_planned_slice_delivery", %{
        "work_request_id" => sibling.id,
        "planned_slice_id" => board_slice.id,
        "outcome" => "completed_no_pr",
        "no_pr_evidence" => "Sibling delivery mutation should be denied.",
        "idempotency_key" => "local-architect-alias-delivery-denied"
      })

    for response <- [sibling_status_response, sibling_add_slice_response, sibling_dispatch_response, sibling_delivery_response] do
      assert get_in(response, ["error", "code"]) == -32_004
      assert get_in(response, ["error", "data", "reason"]) == "not_found"
      refute inspect(response) =~ sibling.id
    end

    assert {:ok, persisted_sibling} = WorkRequestRepository.get(repo, sibling.id)
    assert persisted_sibling.status == "ready_for_slicing"
    assert {:ok, persisted_slices} = WorkRequestRepository.list_planned_slices(repo, sibling.id)

    persisted_slices_by_id = Map.new(persisted_slices, &{&1.id, &1})
    assert Map.keys(persisted_slices_by_id) |> Enum.sort() == [board_slice.id, cross_base_slice.id, mutation_slice.id] |> Enum.sort()
    assert persisted_slices_by_id[board_slice.id].status == "dispatched"
    assert persisted_slices_by_id[board_slice.id].work_package_id == sibling_package.id
    assert persisted_slices_by_id[cross_base_slice.id].status == "dispatched"
    assert persisted_slices_by_id[cross_base_slice.id].work_package_id == cross_base_package.id
    assert persisted_slices_by_id[mutation_slice.id].status == "approved"
    assert is_nil(persisted_slices_by_id[mutation_slice.id].work_package_id)
  end

  test "claim_local_architect_assignment releases heartbeat leases when grant owner changes", %{repo: repo} do
    store_dir = Path.join(test_handoff_store_dir(), "local-architect-claim-owner-changed")
    previous_store_dir = Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir)
    Application.put_env(:symphony_elixir, :sympp_worker_secret_store_dir, store_dir)

    on_exit(fn ->
      restore_app_env(:sympp_worker_secret_store_dir, previous_store_dir)
      File.rm_rf(store_dir)
    end)

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-ARCHITECT-OWNER-CHANGED",
        status: "ready_for_clarification"
      )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: [
                 mode: "local-private-file",
                 repo_root: test_repo_root(),
                 store_dir: store_dir,
                 claimed_by: ArchitectHandoff.claimed_by()
               ]
             )

    arguments = %{
      "work_request_id" => work_request.id,
      "architect_anchor_work_package_id" => handoff.anchor_package.id,
      "repo" => work_request.repo,
      "base_branch" => work_request.base_branch,
      "caller_id" => "codex-local-architect-owner-original",
      "claimed_by" => "original-architect"
    }

    {_claim_response, _claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-owner-original",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-owner-original-state")
      )

    assert {:ok, %ClaimLease{id: lease_id, status: "active"}} =
             ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)

    now = DateTime.utc_now(:microsecond)

    assert {1, nil} =
             repo.update_all(
               from(grant in AccessGrant, where: grant.id == ^handoff.grant.id),
               set: [claimed_at: now, claimed_by: "replacement-architect", updated_at: now]
             )

    {stale_owner_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-owner-stale",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-owner-stale-state")
      )

    assert get_in(stale_owner_response, ["error", "data", "reason"]) == "already_claimed"
    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, handoff.anchor_package.id)

    statuses =
      repo.all(
        from(claim_lease in ClaimLease,
          where: claim_lease.work_package_id == ^handoff.anchor_package.id,
          select: {claim_lease.id, claim_lease.status, claim_lease.release_reason}
        )
      )

    assert {lease_id, "released", "local_architect_assignment_claim_failed"} in statuses

    replacement_arguments =
      arguments
      |> Map.put("caller_id", "codex-local-architect-owner-replacement")
      |> Map.put("claimed_by", "replacement-architect")

    {replacement_response, _replacement_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-owner-replacement",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => replacement_arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-architect-owner-replacement-state")
      )

    assert get_in(replacement_response, ["result", "structuredContent", "assignment", "grant_id"]) == handoff.grant.id
    assert get_in(replacement_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "created"
  end

  test "claim_local_architect_assignment requires trusted file-backed local HTTP state", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-ARCHITECT-DENIED", status: "ready_for_clarification")

    arguments = %{
      "work_request_id" => work_request.id,
      "architect_anchor_work_package_id" => ArchitectHandoff.anchor_id_for_work_request(work_request),
      "repo" => work_request.repo,
      "base_branch" => work_request.base_branch,
      "caller_id" => "codex-local-architect-denied",
      "claimed_by" => "local-architect-denied"
    }

    stdio_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-stdio-denied",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => arguments}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(stdio_response, ["error", "data", "reason"]) == "local_mcp_required"

    stateless_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-stateless-denied",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => arguments}
        },
        Server.new(local_mcp_config(repo), initialized: true, local_daemon_trusted: true)
      )

    assert get_in(stateless_response, ["error", "data", "reason"]) == "local_mcp_session_required"

    untrusted_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-untrusted-denied",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => arguments}
        },
        Server.new(local_mcp_config(repo), initialized: true, state_key: "local-architect-untrusted-state")
      )

    assert get_in(untrusted_response, ["error", "data", "reason"]) == "local_daemon_trust_required"

    remote_config = %{local_mcp_config(repo) | database: "https://ledger.example.test/mcp?token=ghp_localarchitectsecret"}

    remote_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-architect-remote-denied",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_architect_assignment", "arguments" => arguments}
        },
        local_mcp_server(remote_config, "local-architect-remote-denied-state")
      )

    assert get_in(remote_response, ["error", "data", "reason"]) == "local_database_required"
    refute inspect(remote_response) =~ "ghp_localarchitectsecret"
  end

  test "claim_private_handoff resolves metadata when dispatch and worker namespaces differ", %{repo: repo} do
    store_dir = Path.join(test_handoff_store_dir(), "private-architect-namespace-mismatch")
    dispatch_repo_root = temporary_worker_repo_root("claim-namespace-mismatch")
    database = Path.join(store_dir, "matching-ledger.sqlite3")
    previous_store_dir = Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir)
    Application.put_env(:symphony_elixir, :sympp_worker_secret_store_dir, store_dir)

    on_exit(fn ->
      restore_app_env(:sympp_worker_secret_store_dir, previous_store_dir)
      File.rm_rf(store_dir)
      File.rm_rf(dispatch_repo_root)
    end)

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-PRIVATE-HANDOFF-NAMESPACE-MISMATCH",
        status: "ready_for_clarification"
      )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: [
                 mode: "local-private-file",
                 repo_root: dispatch_repo_root,
                 database: database,
                 store_dir: store_dir,
                 claimed_by: ArchitectHandoff.claimed_by()
               ]
             )

    private_handoff = json_payload(handoff.secret_handoff)
    assert private_handoff["namespace_repo_root"] == Path.expand(dispatch_repo_root)
    assert private_handoff["database"] == database

    legacy_private_handoff = Map.delete(private_handoff, "namespace_repo_root")

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-private-handoff-namespace-mismatch",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_private_handoff",
            "arguments" => %{"claimed_by" => "kraken-beta-arch", "private_handoff" => legacy_private_handoff}
          }
        },
        Server.new(Config.default(repo: repo, repo_root: test_repo_root(), database: database), initialized: true)
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == handoff.anchor_package.id
    assert claimed_server.session.assignment.grant_role == "architect"
    assert handoff_secret_absent?(legacy_private_handoff, inspect(claim_response))
  end

  test "claim_private_handoff rejects arbitrary paths and mismatched metadata without leaking secrets", %{repo: repo} do
    store_dir = Path.join(test_handoff_store_dir(), "private-architect-reject")
    previous_store_dir = Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir)
    Application.put_env(:symphony_elixir, :sympp_worker_secret_store_dir, store_dir)

    on_exit(fn ->
      restore_app_env(:sympp_worker_secret_store_dir, previous_store_dir)
      File.rm_rf(store_dir)
    end)

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-PRIVATE-HANDOFF-REJECT",
        status: "ready_for_clarification"
      )

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: [
                 mode: "local-private-file",
                 repo_root: test_repo_root(),
                 store_dir: store_dir,
                 claimed_by: ArchitectHandoff.claimed_by()
               ]
             )

    private_handoff = json_payload(handoff.secret_handoff)
    arbitrary_path = Path.join(System.tmp_dir!(), "sympp-unmanaged-private-handoff-#{System.unique_integer([:positive])}.secret")
    File.write!(arbitrary_path, "not-a-work-key")

    on_exit(fn -> File.rm(arbitrary_path) end)

    arbitrary_response =
      mcp_tool(repo, nil, "claim_private_handoff", %{
        "claimed_by" => "kraken-beta-arch",
        "private_handoff" => Map.put(private_handoff, "path", arbitrary_path)
      })

    assert get_in(arbitrary_response, ["error", "code"]) == -32_001
    assert get_in(arbitrary_response, ["error", "data", "reason"]) == "private_handoff_path_mismatch"
    assert handoff_secret_absent?(private_handoff, inspect(arbitrary_response))

    mismatch_response =
      mcp_tool(repo, nil, "claim_private_handoff", %{
        "claimed_by" => "kraken-beta-arch",
        "private_handoff" => Map.put(private_handoff, "display_key", "FFFF")
      })

    assert get_in(mismatch_response, ["error", "code"]) == -32_001
    assert get_in(mismatch_response, ["error", "data", "reason"]) == "private_handoff_metadata_mismatch"
    assert handoff_secret_absent?(private_handoff, inspect(mismatch_response))

    namespace_response =
      mcp_tool(repo, nil, "claim_private_handoff", %{
        "claimed_by" => "kraken-beta-arch",
        "private_handoff" => Map.put(private_handoff, "namespace_repo_root", Path.join(System.tmp_dir!(), "wrong-repo"))
      })

    assert get_in(namespace_response, ["error", "code"]) == -32_001
    assert get_in(namespace_response, ["error", "data", "reason"]) == "{:handoff_metadata_read_failed, :enoent}"
    assert handoff_secret_absent?(private_handoff, inspect(namespace_response))

    database_response =
      mcp_tool(repo, nil, "claim_private_handoff", %{
        "claimed_by" => "kraken-beta-arch",
        "private_handoff" => Map.put(private_handoff, "database", "wrong-ledger.sqlite3")
      })

    assert get_in(database_response, ["error", "code"]) == -32_001
    assert get_in(database_response, ["error", "data", "reason"]) == "{:handoff_metadata_read_failed, :enoent}"
    assert handoff_secret_absent?(private_handoff, inspect(database_response))
  end

  test "architect handoff TOON preserves runtime identifiers losslessly" do
    long_path = "C:/sympp/" <> String.duplicate("deep-directory/", 25) <> "architect-handoff.secret"
    long_database = "sqlite:///" <> String.duplicate("ledger-segment-", 25) <> "sympp.sqlite3"
    long_claimed_by = String.duplicate("architect-claim-owner-", 20)

    toon =
      ArchitectContext.encode_handoff_reference(%{
        "work_request_id" => "WR-MCP-LONG-HANDOFF",
        "repo" => "nextide/symphony-plus-plus",
        "base_branch" => "main",
        "phase_id" => "phase-long-handoff",
        "architect_anchor_work_package_id" => "SYMPP-LONG-HANDOFF",
        "ledger_database" => long_database,
        "local_architect_claim" => %{
          "tool" => "claim_local_architect_assignment",
          "required_runtime_arguments" => ["caller_id", "claimed_by"],
          "arguments" => %{
            "caller_id" => "codex-local-architect-long-handoff",
            "claimed_by" => long_claimed_by,
            "worktree_path" => long_path
          }
        },
        "private_handoff" => %{
          "mode" => "local-private-file",
          "target" => "SymphonyPlusPlus:architect:SYMPP-LONG-HANDOFF:ABCD:grant-long",
          "path" => long_path,
          "grant_id" => "grant-long",
          "display_key" => "ABCD",
          "work_package_id" => "SYMPP-LONG-HANDOFF"
        }
      })

    assert toon =~ "agent_context: architect_handoff_reference"
    assert toon =~ long_path
    assert toon =~ long_database
    assert toon =~ long_claimed_by
    refute toon =~ "..."
  end

  test "architect TOON redacts sensitive text before shortening display fields" do
    secret_near_limit = String.duplicate("a", 276) <> "sk-1234567890"

    toon =
      ArchitectContext.encode_tool_payload(
        %{
          "work_request" => %{
            "id" => "WR-MCP-TOON-REDACT",
            "title" => "Redact before compacting",
            "repo" => "symphony-plus-plus",
            "base_branch" => "main",
            "status" => "sliced"
          },
          "decision_log_entries" => [
            %{
              "id" => "decision-redact",
              "decision" => secret_near_limit,
              "rationale" => "Display text stays compact after redaction."
            }
          ]
        },
        :work_request_read
      )

    assert toon =~ "agent_context: work_request_read"
    assert toon =~ "RED"
    refute toon =~ "sk-"
    refute toon =~ "sk-1234567890"
  end

  test "claim_work_key tool migrates legacy access grant expiry before unbound claim" do
    database_path = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()

    {:ok, pid} =
      Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

    try do
      Repo.put_dynamic_repo(pid)
      assert :ok = WorkPackageRepository.migrate(Repo)
      assert {:ok, package} = WorkPackageRepository.create(Repo, WorkPackageFactory.attrs(id: "SYMPP-MCP-LEGACY-TOOL"))

      assert {:ok, minted} =
               AccessGrantService.mint_worker_grant(Repo, package.id, expires_at: ~U[2030-01-01 00:00:00Z])

      rebuild_access_grants_with_not_null_expiry!(pid)
      remove_null_expiry_migration_version!(pid)
      assert access_grant_expiry_not_null?(pid)

      response =
        mcp_tool(
          Repo,
          nil,
          "claim_work_key",
          %{"secret" => minted.work_key.secret, "claimed_by" => "worker-legacy-tool"},
          config: Config.default(repo: Repo, repo_root: test_repo_root(), database: database_path)
        )

      refute inspect(response) =~ minted.work_key.secret
      assert get_in(response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-MCP-LEGACY-TOOL"
      assert get_in(response, ["result", "structuredContent", "assignment", "claimed_by"]) == "worker-legacy-tool"
      refute access_grant_expiry_not_null?(pid)
      assert schema_migration_recorded?(pid, 20_260_519_120_000)
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  test "claim_work_key rejects terminal package grants without mutating them", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-TERMINAL-CLAIM", kind: "mcp", status: "merged"))

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-terminal-package",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "work_package_terminal"

    assert {:ok, grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert grant.claimed_at == nil
    assert grant.claimed_by == nil
  end

  test "response-only handle preserves claimed session for sequential calls", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-HANDLE-CLAIM", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    server = Server.new(Config.default(repo: repo), initialized: true)

    claim_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        server
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-HANDLE-CLAIM"

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        server
      )

    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "claimed_by"]) == "worker-1"
  end

  test "set_status records repeated matching reason audit events", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-STATUS-REASON-REPEAT", kind: "mcp", status: "planning"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    block_args = %{"status" => "blocked", "expected_status" => "planning", "reason" => "Waiting on dependency"}

    first_block_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "blocked-1", "method" => "tools/call", "params" => %{"name" => "set_status", "arguments" => block_args}},
        repo: repo,
        session: session
      )

    planning_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "planning",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"status" => "planning", "expected_status" => "blocked"}}
        },
        repo: repo,
        session: session
      )

    second_block_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "blocked-2", "method" => "tools/call", "params" => %{"name" => "set_status", "arguments" => block_args}},
        repo: repo,
        session: session
      )

    assert get_in(first_block_response, ["result", "structuredContent", "work_package", "status"]) == "blocked"
    assert get_in(planning_response, ["result", "structuredContent", "work_package", "status"]) == "planning"
    assert get_in(second_block_response, ["result", "structuredContent", "work_package", "status"]) == "blocked"
    assert {:ok, status_events} = PlanningRepository.list_progress_events(repo, package.id)

    assert status_events
           |> Enum.filter(&(&1.body == "Waiting on dependency" and &1.payload["type"] == "status_transition"))
           |> length() == 2
  end

  test "response-only handle preserves initialized state for sequential calls", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    init_response = Server.handle(%{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}, server)

    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"

    tools_response = Server.handle(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}}, server)

    assert is_list(get_in(tools_response, ["result", "tools"]))
  end

  test "response-only handle resets implicit session for fresh initialize", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REINIT-HANDLE", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    server = Server.new(Config.default(repo: repo))

    init_response = Server.handle(%{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}, server)

    claim_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        server
      )

    reinit_response = Server.handle(%{"jsonrpc" => "2.0", "id" => "init-again", "method" => "initialize", "params" => initialize_params()}, server)

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        server
      )

    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-REINIT-HANDLE"
    assert get_in(reinit_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert get_in(assignment_response, ["error", "data", "reason"]) == "claim_required"
  end
end
