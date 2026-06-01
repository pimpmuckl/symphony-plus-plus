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
