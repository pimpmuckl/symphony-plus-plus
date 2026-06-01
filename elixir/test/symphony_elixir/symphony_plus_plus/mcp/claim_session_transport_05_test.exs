Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport05Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "worker tool notifications execute without JSON-RPC responses", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-NOTIFY-WRITE", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    {responses, server} =
      Server.handle_state(
        [
          %{
            "jsonrpc" => "2.0",
            "method" => "tools/call",
            "params" => %{
              "name" => "append_progress",
              "arguments" => %{
                "summary" => "Notification progress",
                "body" => "Persisted through fire-and-forget call",
                "status" => "in_progress",
                "idempotency_key" => "notify-progress"
              }
            }
          },
          %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}}
        ],
        claimed_server
      )

    assert Enum.map(responses, & &1["id"]) == ["assignment"]
    assert server.session.assignment.work_package_id == "SYMPP-NOTIFY-WRITE"
    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.any?(progress_events, &(&1.summary == "Notification progress"))
  end

  test "claim_work_key rejects rebinding a server to another work key", %{repo: repo} do
    assert {:ok, first_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-FIRST-CLAIM", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, second_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-SECOND-CLAIM", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, first_minted} = AccessGrantService.mint_worker_grant(repo, first_package.id)
    assert {:ok, second_minted} = AccessGrantService.mint_worker_grant(repo, second_package.id)

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => first_minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-FIRST-CLAIM"

    {replay_response, replay_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-replay",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => first_minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        claimed_server
      )

    assert get_in(replay_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-FIRST-CLAIM"
    assert replay_server.session.assignment.work_package_id == "SYMPP-FIRST-CLAIM"

    {rebind_response, rebound_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-other",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => second_minted.work_key.secret, "claimed_by" => "worker-2"}}
        },
        claimed_server
      )

    assert get_in(rebind_response, ["error", "data", "reason"]) == "session_already_bound"
    assert rebound_server.session.assignment.work_package_id == "SYMPP-FIRST-CLAIM"
  end

  test "batch claim_work_key rejects rebinding after an earlier batch claim succeeds", %{repo: repo} do
    assert {:ok, first_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-FIRST-BATCH-CLAIM", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, second_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-SECOND-BATCH-CLAIM", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, first_minted} = AccessGrantService.mint_worker_grant(repo, first_package.id)
    assert {:ok, second_minted} = AccessGrantService.mint_worker_grant(repo, second_package.id)

    {responses, server} =
      Server.handle_state(
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "claim-first",
            "method" => "tools/call",
            "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => first_minted.work_key.secret, "claimed_by" => "worker-1"}}
          },
          %{
            "jsonrpc" => "2.0",
            "id" => "claim-second",
            "method" => "tools/call",
            "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => second_minted.work_key.secret, "claimed_by" => "worker-2"}}
          }
        ],
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(Enum.at(responses, 0), ["result", "structuredContent", "assignment", "work_package_id"]) == first_package.id
    assert get_in(Enum.at(responses, 1), ["error", "data", "reason"]) == "session_already_bound"
    assert server.session.assignment.work_package_id == first_package.id
    assert {:ok, second_grant} = AccessGrantRepository.get(repo, second_minted.grant.id)
    refute second_grant.claimed_by
    refute second_grant.claimed_at
  end

  test "batch claim_work_key only counts successful claims on bound connections", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BOUND-BATCH-CLAIM", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    {responses, server} =
      Server.handle_state(
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "claim-wrong-owner",
            "method" => "tools/call",
            "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-2"}}
          },
          %{
            "jsonrpc" => "2.0",
            "id" => "claim-replay",
            "method" => "tools/call",
            "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
          }
        ],
        claimed_server
      )

    assert get_in(Enum.at(responses, 0), ["error", "data", "reason"]) == "already_claimed"
    assert get_in(Enum.at(responses, 1), ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert server.session.assignment.work_package_id == package.id
  end

  test "batch claim_work_key counts notification refreshes on stale bound connections", %{repo: repo} do
    assert {:ok, original_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BATCH-STALE-ORIGINAL", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, replacement_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BATCH-STALE-REPLACEMENT", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, second_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BATCH-STALE-SECOND", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, original_minted} = AccessGrantService.mint_worker_grant(repo, original_package.id)
    assert {:ok, replacement_minted} = AccessGrantService.mint_worker_grant(repo, replacement_package.id)
    assert {:ok, second_minted} = AccessGrantService.mint_worker_grant(repo, second_package.id)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-original",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => original_minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, original_minted.grant.id)

    {responses, refreshed_server} =
      Server.handle_state(
        [
          %{
            "jsonrpc" => "2.0",
            "method" => "tools/call",
            "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => replacement_minted.work_key.secret, "claimed_by" => "worker-1"}}
          },
          %{
            "jsonrpc" => "2.0",
            "id" => "claim-second-after-notification-refresh",
            "method" => "tools/call",
            "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => second_minted.work_key.secret, "claimed_by" => "worker-2"}}
          }
        ],
        claimed_server
      )

    assert get_in(List.first(responses), ["error", "data", "reason"]) == "session_already_bound"
    assert refreshed_server.session.assignment.work_package_id == replacement_package.id
    assert {:ok, second_grant} = AccessGrantRepository.get(repo, second_minted.grant.id)
    refute second_grant.claimed_by
    refute second_grant.claimed_at
  end

  test "claim_work_key binds worker and architect grants and revalidates bound replays", %{repo: repo} do
    assert {:ok, worker_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WORKER-CLAIM", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, architect_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-CLAIM", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, worker_minted} = AccessGrantService.mint_worker_grant(repo, worker_package.id)
    assert {:ok, architect_work_key} = create_architect_work_key(repo, architect_package.id, ["read:child_progress", "read:child_findings"])

    {architect_response, architect_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "architect-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => architect_work_key.secret, "claimed_by" => "architect-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(architect_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-ARCHITECT-CLAIM"
    assert get_in(architect_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert architect_server.session.assignment.grant_role == "architect"

    architect_tools_response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "architect-tools-after-claim", "method" => "tools/list", "params" => %{}}, architect_server)

    architect_tools_by_name =
      architect_tools_response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(architect_tools_by_name, "read_child_status")
    refute Map.has_key?(architect_tools_by_name, "append_progress")

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => worker_minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-WORKER-CLAIM"

    reconnect_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-reconnect",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => worker_minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true, state_key: make_ref())
      )

    assert get_in(reconnect_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-WORKER-CLAIM"

    duplicate_owner_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-reconnect-other-owner",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => worker_minted.work_key.secret, "claimed_by" => "worker-2"}}
        },
        Server.new(Config.default(repo: repo), initialized: true, state_key: make_ref())
      )

    assert get_in(duplicate_owner_response, ["error", "data", "reason"]) == "already_claimed"

    assert {:ok, _grant} = AccessGrantService.revoke(repo, worker_minted.grant.id)

    {replay_response, replay_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-replay",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => worker_minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        claimed_server
      )

    assert get_in(replay_response, ["error", "data", "reason"]) == "revoked"
    assert replay_server.session.assignment.work_package_id == "SYMPP-WORKER-CLAIM"

    assert {:ok, replacement_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WORKER-CLAIM-REFRESH", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, replacement_minted} = AccessGrantService.mint_worker_grant(repo, replacement_package.id)

    {refresh_response, refreshed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-refresh-after-revocation",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => replacement_minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        replay_server
      )

    assert get_in(refresh_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-WORKER-CLAIM-REFRESH"
    assert refreshed_server.session.assignment.work_package_id == "SYMPP-WORKER-CLAIM-REFRESH"
  end

  test "bound MCP sessions fail closed after package authority reaches a terminal state", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WORKER-CLAIM-TERMINAL", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert {:ok, _terminal_package} = WorkPackageRepository.update(repo, package.id, %{status: "merged"})

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment-after-terminal", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        claimed_server
      )

    assert get_in(assignment_response, ["error", "code"]) == -32_001
    assert get_in(assignment_response, ["error", "data", "reason"]) == "work_package_terminal"

    reconnect_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-reconnect-after-terminal",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true, state_key: make_ref())
      )

    assert get_in(reconnect_response, ["error", "code"]) == -32_001
    assert get_in(reconnect_response, ["error", "data", "reason"]) == "work_package_terminal"
  end

  test "claim_work_key rejects non-worker non-architect grant roles", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-UNSUPPORTED-CLAIM-ROLE", kind: "mcp", status: "ready_for_worker"))

    work_key = WorkKey.generate()
    now = DateTime.utc_now(:microsecond)

    assert {1, nil} =
             repo.insert_all(AccessGrant, [
               %{
                 id: "ag_unsupported_claim_role",
                 work_package_id: package.id,
                 display_key: work_key.display_key,
                 secret_hash: WorkKey.secret_hash(work_key.secret),
                 grant_role: "auditor",
                 capabilities: [],
                 expires_at: DateTime.add(now, 86_400, :second),
                 inserted_at: now,
                 updated_at: now
               }
             ])

    response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "unsupported-role-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => work_key.secret, "claimed_by" => "auditor-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "unsupported_grant_role"

    assert {:ok, grant} = AccessGrantRepository.get(repo, "ag_unsupported_claim_role")
    assert grant.claimed_at == nil
    assert grant.claimed_by == nil
  end

  test "worker tools reject injected non-worker sessions", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INJECTED-ARCHITECT", kind: "mcp"))
    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id)

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "architect-write",
          "method" => "tools/call",
          "params" => %{"name" => "append_finding", "arguments" => %{"title" => "Architect", "body" => "Wrong role", "idempotency_key" => "architect"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "worker_grant_required"

    assignment_tool_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "architect-assignment-tool", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        repo: repo,
        session: session
      )

    assert get_in(assignment_tool_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert get_in(assignment_tool_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id

    read_tool_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "architect-read-tool", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        repo: repo,
        session: session
      )

    assert get_in(read_tool_response, ["error", "code"]) == -32_001
    assert get_in(read_tool_response, ["error", "data", "reason"]) == "worker_grant_required"

    resource_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "architect-resource",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/SYMPP-INJECTED-ARCHITECT/task_plan.md"}
        },
        repo: repo,
        session: session
      )

    assert get_in(resource_response, ["error", "data", "reason"]) == "insufficient_capability"

    assignment_resource_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "architect-assignment-resource", "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        repo: repo,
        session: session
      )

    assert get_in(assignment_resource_response, ["result", "contents", Access.at(0), "uri"]) == "sympp://assignment/current"

    assignment_resource_payload =
      assignment_resource_response
      |> get_in(["result", "contents", Access.at(0), "text"])
      |> Jason.decode!()

    assert assignment_resource_payload["grant_role"] == "architect"
    assert assignment_resource_payload["work_package_id"] == package.id
  end

  test "worker grants are denied architect tools", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WORKER-DENIED-ARCHITECT", kind: "mcp"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "worker-denied-architect",
          "method" => "tools/call",
          "params" => %{"name" => "read_child_status", "arguments" => %{"work_package_id" => package.id}}
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "architect_grant_required"

    schema_probe_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "worker-denied-architect-schema-probe",
          "method" => "tools/call",
          "params" => %{"name" => "read_phase_board", "arguments" => %{}}
        },
        repo: repo,
        session: session
      )

    assert get_in(schema_probe_response, ["error", "code"]) == -32_001
    assert get_in(schema_probe_response, ["error", "data", "reason"]) == "architect_grant_required"
  end

  test "architect tools reject missing and insufficient grants", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-AUTHZ", kind: "mcp"))

    missing_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "missing-architect",
          "method" => "tools/call",
          "params" => %{"name" => "read_child_status", "arguments" => %{"work_package_id" => package.id}}
        },
        repo: repo
      )

    assert get_in(missing_response, ["error", "code"]) == -32_001
    assert get_in(missing_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(missing_response, ["error", "data", "action"]) == "claim_work_key"

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:phase"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    insufficient_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "insufficient-architect",
          "method" => "tools/call",
          "params" => %{"name" => "read_child_status", "arguments" => %{"work_package_id" => package.id}}
        },
        repo: repo,
        session: session
      )

    assert get_in(insufficient_response, ["error", "code"]) == -32_001
    assert get_in(insufficient_response, ["error", "data", "reason"]) == "insufficient_capability"

    assert {:ok, progress_only_work_key} = create_architect_work_key(repo, package.id, ["read:child_progress"])

    assert {:ok, progress_only_assignment} =
             AccessGrantRepository.claim(repo, progress_only_work_key.secret, %{claimed_by: "architect-2"}, DateTime.utc_now(:microsecond))

    progress_only_session = MCPHarness.session(progress_only_assignment, proof_hash: WorkKey.secret_hash(progress_only_work_key.secret))

    progress_only_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "progress-only-architect",
          "method" => "tools/call",
          "params" => %{"name" => "read_child_status", "arguments" => %{"work_package_id" => package.id}}
        },
        repo: repo,
        session: progress_only_session
      )

    assert get_in(progress_only_response, ["error", "code"]) == -32_001
    assert get_in(progress_only_response, ["error", "data", "reason"]) == "insufficient_capability"
  end

  test "architect mutating tools require their specific grant capabilities", %{repo: repo} do
    {package, session} = create_architect_session(repo, "SYMPP-ARCHITECT-MUTATION-CAPABILITY", ["read:phase"])

    counts_before = {
      repo.aggregate(WorkPackage, :count),
      repo.aggregate(AccessGrant, :count),
      repo.aggregate(ProgressEvent, :count),
      repo.aggregate(Artifact, :count)
    }

    denied_calls = [
      {"create_child_work_package",
       %{
         "package" => %{
           "id" => "SYMPP-ARCHITECT-DENIED-CHILD",
           "title" => "Denied",
           "acceptance_criteria" => ["Denied"]
         }
       }},
      {"mint_child_worker_key", %{"work_package_id" => package.id, "template" => child_worker_template()}},
      {"revoke_child_worker_key", %{"grant_id" => "grant-denied", "reason" => "Denied"}},
      {"revoke_planned_slice_worker_key", %{"work_request_id" => "wr-denied", "planned_slice_id" => "slice-denied", "grant_id" => "grant-denied", "reason" => "Denied"}},
      {"approve_scope_expansion", %{"work_package_id" => package.id, "allowed_file_globs" => ["docs/**"], "rationale" => "Denied"}},
      {"request_child_replan", %{"work_package_id" => package.id, "rationale" => "Denied"}},
      {"approve_child_ready_state", %{"work_package_id" => package.id, "rationale" => "Denied"}},
      {"merge_child_into_phase", %{"work_package_id" => package.id, "merge_artifact" => %{"status" => "merged_into_phase", "uri" => "https://example.test/pr/1"}}},
      {"split_work_package", %{"work_package_id" => package.id, "package" => %{}}},
      {"publish_phase_update", %{"summary" => "Denied"}}
    ]

    Enum.each(denied_calls, fn {tool, arguments} ->
      response = mcp_tool(repo, session, tool, arguments)

      assert get_in(response, ["error", "code"]) == -32_001
      assert get_in(response, ["error", "data", "reason"]) == "insufficient_capability"
    end)

    assert {
             repo.aggregate(WorkPackage, :count),
             repo.aggregate(AccessGrant, :count),
             repo.aggregate(ProgressEvent, :count),
             repo.aggregate(Artifact, :count)
           } == counts_before
  end

  test "architect read_child_status reads only its scoped work package", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-READ-CHILD", kind: "mcp", status: "planning"))

    assert {:ok, sibling} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-SIBLING", kind: "mcp"))
    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:child_progress", "read:child_findings"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "read-child-status",
          "method" => "tools/call",
          "params" => %{"name" => "read_child_status", "arguments" => %{"work_package_id" => package.id}}
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) == package.id
    assert get_in(response, ["result", "structuredContent", "work_package", "status"]) == "planning"
    assert is_integer(get_in(response, ["result", "structuredContent", "plan_version"]))
    assert get_in(response, ["result", "structuredContent", "finding_count"]) == 0
    assert get_in(response, ["result", "structuredContent", "progress_event_count"]) == 0

    sibling_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "read-sibling-status",
          "method" => "tools/call",
          "params" => %{"name" => "read_child_status", "arguments" => %{"work_package_id" => sibling.id}}
        },
        repo: repo,
        session: session
      )

    assert get_in(sibling_response, ["error", "code"]) == -32_003
    assert get_in(sibling_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "single-item batch preserves claim_work_key session for later requests", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BATCH-SINGLE-CLAIM", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {responses, claimed_server} =
      Server.handle_state(
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "claim",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_work_key",
              "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}
            }
          }
        ],
        Server.new(Config.default(repo: repo), initialized: true)
      )

    {assignment_response, _server} =
      Server.handle_state(
        %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        claimed_server
      )

    assert Enum.map(responses, & &1["id"]) == ["claim"]
    assert claimed_server.session.assignment.work_package_id == package.id
    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  test "single-item batch preserves claim_private_handoff session for later requests", %{repo: repo} do
    store_dir = Path.join(test_handoff_store_dir(), "private-batch-claim")
    previous_store_dir = Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir)
    Application.put_env(:symphony_elixir, :sympp_worker_secret_store_dir, store_dir)

    on_exit(fn ->
      restore_app_env(:sympp_worker_secret_store_dir, previous_store_dir)
      File.rm_rf(store_dir)
    end)

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-PRIVATE-BATCH-CLAIM",
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

    {responses, claimed_server} =
      Server.handle_state(
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "claim-private",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_private_handoff",
              "arguments" => %{"claimed_by" => "kraken-beta-arch", "private_handoff" => private_handoff}
            }
          }
        ],
        Server.new(Config.default(repo: repo), initialized: true)
      )

    {read_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "read-private-batch-work-request",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => %{"work_request_id" => work_request.id}}
        },
        claimed_server
      )

    assert Enum.map(responses, & &1["id"]) == ["claim-private"]
    assert claimed_server.session.assignment.grant_role == "architect"
    assert claimed_server.session.assignment.work_package_id == handoff.anchor_package.id
    assert get_in(read_response, ["result", "structuredContent", "work_request", "id"]) == work_request.id
    assert handoff_secret_absent?(private_handoff, inspect(responses))
    assert handoff_secret_absent?(private_handoff, inspect(read_response))
  end

  test "batch calls do not thread claim_work_key session to later worker tools", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BATCH-CLAIM", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {responses, server} =
      Server.handle_state(
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "claim",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_work_key",
              "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}
            }
          },
          %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}}
        ],
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert Enum.map(responses, & &1["id"]) == ["claim", "assignment"]
    refute inspect(responses) =~ minted.work_key.secret
    assert get_in(Enum.at(responses, 0), ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-BATCH-CLAIM"
    assert get_in(Enum.at(responses, 1), ["error", "data", "reason"]) == "claim_required"
    assert server.session.assignment.work_package_id == "SYMPP-BATCH-CLAIM"
  end
end
