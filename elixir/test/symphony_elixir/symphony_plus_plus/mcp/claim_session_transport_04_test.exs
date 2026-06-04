Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport04Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{HTTPStateStore, HTTPTransport}

  test "response-only handle supports explicit state keys for recreated servers", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-STATELESS-HANDLE", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    state_key = make_ref()

    init_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    claim_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-STATELESS-HANDLE"
    assert get_in(assignment_response, ["error", "data", "reason"]) == "claim_required"

    reconnect_claim_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-again",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    assert get_in(reconnect_claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-STATELESS-HANDLE"
  end

  test "response-only handle supports explicit state keys across processes", %{repo: repo} do
    state_key = make_ref()

    init_response =
      Task.async(fn ->
        Server.handle(
          %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
          Server.new(Config.default(repo: repo), state_key: state_key)
        )
      end)
      |> Task.await()

    tools_response =
      Task.async(fn ->
        Server.handle(
          %{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}},
          Server.new(Config.default(repo: repo), state_key: state_key)
        )
      end)
      |> Task.await()

    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert is_list(get_in(tools_response, ["result", "tools"]))
  end

  test "response-only handle namespaces explicit state keys by config", %{repo: repo} do
    state_key = make_ref()

    init_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    other_repo_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}},
        Server.new(Config.default(repo: UnexpectedAuthRepo), state_key: state_key)
      )

    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert get_in(other_repo_response, ["error", "data", "reason"]) == "server_not_initialized"
  end

  test "response-only handle does not restore explicit state key session across reconnect initialize", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-STATE-RESET", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    state_key = make_ref()

    assert %{"result" => _result} =
             Server.handle(
               %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
               Server.new(Config.default(repo: repo), state_key: state_key)
             )

    assert %{"result" => _result} =
             Server.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => "claim",
                 "method" => "tools/call",
                 "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
               },
               Server.new(Config.default(repo: repo), state_key: state_key)
             )

    reinit_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "init-again", "method" => "initialize", "params" => initialize_params()},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    missing_assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment-missing", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    assert get_in(reinit_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert get_in(missing_assignment_response, ["error", "data", "reason"]) == "claim_required"

    assert %{"result" => _result} =
             Server.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => "claim-again",
                 "method" => "tools/call",
                 "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
               },
               Server.new(Config.default(repo: repo), state_key: state_key)
             )

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    assert get_in(assignment_response, ["error", "data", "reason"]) == "claim_required"
  end

  test "explicit state key stale live server remains claim-only until new session", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-STATE-STALE-LIVE", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    state_key = make_ref()

    {_init_response, initialized_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    {_claim_response, claimed_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        initialized_server
      )

    reinit_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "init-again", "method" => "initialize", "params" => initialize_params()},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    {tools_response, tools_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "tools-after-stale-reinit", "method" => "tools/list", "params" => %{}},
        claimed_server
      )

    tools_by_name = tools_response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    {repeat_tools_response, repeat_tools_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "tools-after-stale-reinit-repeat", "method" => "tools/list", "params" => %{}},
        tools_server
      )

    repeat_tools_by_name = repeat_tools_response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    {reused_init_response, reused_init_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "reused-init-after-stale", "method" => "initialize", "params" => initialize_params()},
        repeat_tools_server
      )

    # A duplicate initialize on the same reused explicit server is not a fresh
    # unbound session; keep the stale identity on the claim-only recovery
    # surface until re-claim or a new MCP process/session.
    {reused_tools_response, reused_tools_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "tools-after-reused-stale-init", "method" => "tools/list", "params" => %{}},
        reused_init_server
      )

    reused_tools_by_name = reused_tools_response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    {stale_solo_response, _stale_solo_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "solo-after-reused-stale-init", "method" => "tools/call", "params" => %{"name" => "solo_attach", "arguments" => %{}}},
        reused_tools_server
      )

    {stateless_tools_response, stateless_tools_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "tools-after-stateless-stale-recovery", "method" => "tools/list", "params" => %{}},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    stateless_tools_by_name = stateless_tools_response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    {stateless_solo_response, _stateless_solo_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "solo-after-stateless-stale-recovery", "method" => "tools/call", "params" => %{"name" => "solo_attach", "arguments" => %{}}},
        stateless_tools_server
      )

    {fresh_init_response, fresh_initialized_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "fresh-init-after-stale", "method" => "initialize", "params" => initialize_params()},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    {fresh_tools_response, _fresh_tools_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "tools-after-fresh-init", "method" => "tools/list", "params" => %{}},
        fresh_initialized_server
      )

    fresh_tools_by_name = fresh_tools_response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    {assignment_response, _server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "assignment-after-reinit", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        claimed_server
      )

    assert get_in(reinit_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert Map.keys(tools_by_name) |> Enum.sort() == ["claim_private_handoff", "claim_work_key", "sympp.health"]
    assert Map.keys(repeat_tools_by_name) |> Enum.sort() == ["claim_private_handoff", "claim_work_key", "sympp.health"]
    assert get_in(reused_init_response, ["error", "data", "reason"]) == "already_initialized"
    assert Map.keys(reused_tools_by_name) |> Enum.sort() == ["claim_private_handoff", "claim_work_key", "sympp.health"]
    assert get_in(stale_solo_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(stale_solo_response, ["error", "data", "action"]) == "claim_work_key"
    assert Map.keys(stateless_tools_by_name) |> Enum.sort() == ["claim_private_handoff", "claim_work_key", "sympp.health"]
    assert get_in(stateless_solo_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(stateless_solo_response, ["error", "data", "action"]) == "claim_work_key"
    assert get_in(fresh_init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    refute Map.has_key?(reused_tools_by_name, "get_current_assignment")
    assert Map.has_key?(fresh_tools_by_name, "read_work_request")
    assert Map.has_key?(fresh_tools_by_name, "solo_attach")
    assert Map.has_key?(fresh_tools_by_name, "get_current_assignment")
    assert get_in(assignment_response, ["error", "data", "reason"]) == "claim_required"
  end

  test "explicit state key duplicate initialize preserves active live session", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-STATE-LIVE-DUP", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    state_key = make_ref()

    {_init_response, initialized_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    {_claim_response, claimed_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        initialized_server
      )

    {duplicate_init_response, duplicate_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "init-again", "method" => "initialize", "params" => initialize_params()},
        claimed_server
      )

    {assignment_response, _server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "assignment-after-duplicate", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        duplicate_server
      )

    tools_after_reconnect =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "tools-after-duplicate-reconnect", "method" => "tools/list", "params" => %{}},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    assert get_in(duplicate_init_response, ["error", "data", "reason"]) == "already_initialized"
    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert is_list(get_in(tools_after_reconnect, ["result", "tools"]))

    assert %{"result" => _result} =
             Server.handle(
               %{"jsonrpc" => "2.0", "id" => "new-init", "method" => "initialize", "params" => initialize_params()},
               Server.new(Config.default(repo: repo), state_key: state_key)
             )

    {stale_duplicate_response, stale_duplicate_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "stale-init-again", "method" => "initialize", "params" => initialize_params()},
        claimed_server
      )

    {stale_assignment_response, _server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "assignment-after-stale-duplicate", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        stale_duplicate_server
      )

    assert get_in(stale_duplicate_response, ["error", "data", "reason"]) == "already_initialized"
    assert get_in(stale_assignment_response, ["error", "data", "reason"]) == "claim_required"
  end

  test "HTTP claim_work_key live session release clears the current claim lease", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-HTTP-WORK-KEY-RELEASE", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    config = local_mcp_config(repo)
    client_key = "client-http-work-key-release"

    {:ok, init_result} =
      HTTPTransport.handle(config, %{"jsonrpc" => "2.0", "id" => "init-work-key-release", "method" => "initialize", "params" => initialize_params()}, client_key: client_key)

    {:ok, claim_result} =
      HTTPTransport.handle(
        config,
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-work-key-release",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(claim_result.response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert {:ok, %ClaimLease{id: lease_id, actor_id: "work_key:" <> _hash}} = ClaimLeaseService.current_for_work_package(repo, package.id)

    {:ok, release_result} =
      HTTPTransport.handle(
        config,
        %{
          "jsonrpc" => "2.0",
          "id" => "release-live-work-key",
          "method" => "tools/call",
          "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "done"}}
        },
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(release_result.response, ["result", "structuredContent", "binding_cleared"]) == true
    assert get_in(release_result.response, ["result", "structuredContent", "claim_lease_release", "claim_lease_id"]) == lease_id
    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, package.id)
    refute inspect(release_result.response) =~ minted.work_key.secret
  end

  test "HTTP release_current_assignment notification persists unbound recovery state", %{repo: repo} do
    {package, work_request} = create_http_local_claim_package!(repo, "SYMPP-HTTP-RELEASE-NOTIFY")
    config = local_mcp_config(repo)
    client_key = "client-http-release-notify"

    {:ok, init_result} =
      HTTPTransport.handle(config, %{"jsonrpc" => "2.0", "id" => "init-release-notify", "method" => "initialize", "params" => initialize_params()}, client_key: client_key)

    {:ok, claim_result} =
      HTTPTransport.handle(
        config,
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-release-notify",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => local_assignment_claim_args(package, %{"work_request_id" => work_request.id})
          }
        },
        client_key: client_key,
        state_key: init_result.state_key
      )

    lease_id = get_in(claim_result.response, ["result", "structuredContent", "local_claim", "claim_lease_id"])
    assert get_in(claim_result.response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id

    {:ok, release_result} =
      HTTPTransport.handle(
        config,
        %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "done"}}
        },
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert release_result.response == nil
    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert %ClaimLease{id: ^lease_id, status: "released"} = repo.get(ClaimLease, lease_id)

    HTTPStateStore.reset!()

    {:ok, assignment_result} =
      HTTPTransport.handle(
        config,
        %{"jsonrpc" => "2.0", "id" => "assignment-after-notify-release", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(assignment_result.response, ["error", "data", "reason"]) == "claim_required"
  end

  test "HTTP batch release_current_assignment persists unbound recovery state", %{repo: repo} do
    {package, work_request} = create_http_local_claim_package!(repo, "SYMPP-HTTP-RELEASE-BATCH")
    config = local_mcp_config(repo)
    client_key = "client-http-release-batch"

    {:ok, init_result} =
      HTTPTransport.handle(config, %{"jsonrpc" => "2.0", "id" => "init-release-batch", "method" => "initialize", "params" => initialize_params()}, client_key: client_key)

    {:ok, claim_result} =
      HTTPTransport.handle(
        config,
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-release-batch",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => local_assignment_claim_args(package, %{"work_request_id" => work_request.id})
          }
        },
        client_key: client_key,
        state_key: init_result.state_key
      )

    lease_id = get_in(claim_result.response, ["result", "structuredContent", "local_claim", "claim_lease_id"])
    assert get_in(claim_result.response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id

    {:ok, release_result} =
      HTTPTransport.handle(
        config,
        [
          %{
            "jsonrpc" => "2.0",
            "id" => "release-batch",
            "method" => "tools/call",
            "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "done"}}
          }
        ],
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert [release_response] = release_result.response
    assert get_in(release_response, ["result", "structuredContent", "binding_cleared"]) == true
    assert get_in(release_response, ["result", "structuredContent", "claim_lease_release", "claim_lease_id"]) == lease_id

    HTTPStateStore.reset!()

    {:ok, assignment_result} =
      HTTPTransport.handle(
        config,
        %{"jsonrpc" => "2.0", "id" => "assignment-after-batch-release", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(assignment_result.response, ["error", "data", "reason"]) == "claim_required"
  end

  test "failed explicit state key reinitialize clears prior handshake state", %{repo: repo} do
    state_key = make_ref()

    assert %{"result" => _result} =
             Server.handle(
               %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
               Server.new(Config.default(repo: repo), state_key: state_key)
             )

    invalid_init_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "invalid-init", "method" => "initialize", "params" => %{"protocolVersion" => "2025-03-26"}},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    tools_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "tools-after-failed-init", "method" => "tools/list", "params" => %{}},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    assert get_in(invalid_init_response, ["error", "data", "reason"]) == "invalid_initialize_params"
    assert get_in(tools_response, ["error", "data", "reason"]) == "server_not_initialized"
  end

  test "failed explicit state key reconnect invalidates stale live server sessions", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-FAILED-RECONNECT-LIVE", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    state_key = make_ref()

    {_init_response, initialized_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    {_claim_response, claimed_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        initialized_server
      )

    invalid_reconnect_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "invalid-reconnect", "method" => "initialize", "params" => %{"protocolVersion" => "2025-03-26"}},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    {assignment_response, _server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "assignment-after-failed-reconnect", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        claimed_server
      )

    assert get_in(invalid_reconnect_response, ["error", "data", "reason"]) == "invalid_initialize_params"
    assert get_in(assignment_response, ["error", "data", "reason"]) == "claim_required"
  end

  test "failed duplicate explicit initialize preserves live server session", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-FAILED-REINIT-LIVE", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    state_key = make_ref()

    {_init_response, initialized_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        Server.new(Config.default(repo: repo), state_key: state_key)
      )

    {_claim_response, claimed_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        initialized_server
      )

    {invalid_init_response, live_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "invalid-init", "method" => "initialize", "params" => %{"protocolVersion" => "2025-03-26"}},
        claimed_server
      )

    {assignment_response, _server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "assignment-after-failed-init", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        live_server
      )

    assert get_in(invalid_init_response, ["error", "data", "reason"]) == "already_initialized"
    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  test "stdio response-only line helper retains initialized worker session", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-STDIO-STATE", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    server = Server.new(Config.default(repo: repo))

    init_response =
      %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}
      |> Jason.encode!()
      |> Stdio.line_response(server)

    claim_response =
      %{
        "jsonrpc" => "2.0",
        "id" => "claim",
        "method" => "tools/call",
        "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
      }
      |> Jason.encode!()
      |> Stdio.line_response(server)

    assignment_response =
      %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}}
      |> Jason.encode!()
      |> Stdio.line_response(server)

    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  test "stdio response-state preserves live session on duplicate initialize", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-STDIO-DUP-INIT", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    server = Server.new(Config.default(repo: repo))

    {init_response, initialized_server} =
      %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}
      |> Jason.encode!()
      |> Stdio.line_response_state(server)

    {claim_response, claimed_server} =
      %{
        "jsonrpc" => "2.0",
        "id" => "claim",
        "method" => "tools/call",
        "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
      }
      |> Jason.encode!()
      |> Stdio.line_response_state(initialized_server)

    {duplicate_init_response, duplicate_server} =
      %{"jsonrpc" => "2.0", "id" => "init-again", "method" => "initialize", "params" => initialize_params()}
      |> Jason.encode!()
      |> Stdio.line_response_state(claimed_server)

    {assignment_response, _server} =
      %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}}
      |> Jason.encode!()
      |> Stdio.line_response_state(duplicate_server)

    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(duplicate_init_response, ["error", "data", "reason"]) == "already_initialized"
    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  test "response-only handle does not share default state between recreated servers", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-STATE-ISOLATED", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    claim_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-STATE-ISOLATED"
    assert get_in(assignment_response, ["error", "data", "reason"]) == "claim_required"
  end

  test "response-only handle treats nil and blank state keys as absent", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-EMPTY-STATE-KEY", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    claim_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true, state_key: nil)
      )

    nil_key_assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment-nil", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        Server.new(Config.default(repo: repo), initialized: true, state_key: nil)
      )

    blank_key_assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment-blank", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        Server.new(Config.default(repo: repo), initialized: true, state_key: "  ")
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(nil_key_assignment_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(blank_key_assignment_response, ["error", "data", "reason"]) == "claim_required"
  end

  test "response-only state keys are isolated by the active ledger" do
    first_database = WorkPackageFactory.database_path()
    second_database = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()

    {:ok, first_pid} =
      Repo.start_link(database: first_database, name: Repo.process_name(first_database), pool_size: 1, log: false)

    {:ok, second_pid} =
      Repo.start_link(database: second_database, name: Repo.process_name(second_database), pool_size: 1, log: false)

    try do
      Repo.put_dynamic_repo(first_pid)
      assert :ok = WorkPackageRepository.migrate(Repo)

      assert {:ok, package} =
               WorkPackageRepository.create(
                 Repo,
                 WorkPackageFactory.attrs(id: "SYMPP-LEDGER-STATE", kind: "mcp", status: "ready_for_worker")
               )

      assert {:ok, minted} = AccessGrantService.mint_worker_grant(Repo, package.id)

      state_key = "shared-ledger-state"

      claim_response =
        Server.handle(
          %{
            "jsonrpc" => "2.0",
            "id" => "claim-ledger-one",
            "method" => "tools/call",
            "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
          },
          Server.new(Config.default(repo: Repo), initialized: true, state_key: state_key)
        )

      Repo.put_dynamic_repo(second_pid)
      assert :ok = WorkPackageRepository.migrate(Repo)

      assignment_response =
        Server.handle(
          %{"jsonrpc" => "2.0", "id" => "assignment-ledger-two", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
          Server.new(Config.default(repo: Repo), initialized: true, state_key: state_key)
        )

      assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
      assert get_in(assignment_response, ["error", "data", "reason"]) == "claim_required"
    after
      Repo.put_dynamic_repo(original_repo)
      if Process.alive?(first_pid), do: GenServer.stop(first_pid)
      if Process.alive?(second_pid), do: GenServer.stop(second_pid)
      File.rm(first_database)
      File.rm(second_database)
    end
  end

  test "explicit response state key follows the same dynamic ledger across repo processes" do
    database = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()

    {:ok, first_pid} =
      Repo.start_link(database: database, name: :"sympp_mcp_same_#{System.unique_integer([:positive])}", pool_size: 1, log: false)

    {:ok, second_pid} =
      Repo.start_link(database: database, name: :"sympp_mcp_same_#{System.unique_integer([:positive])}", pool_size: 1, log: false)

    try do
      state_key = "same-ledger-state"

      Repo.put_dynamic_repo(first_pid)

      {_initialize_response, _server} =
        Server.handle_response_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "init-first-ledger-process",
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => "2025-03-26",
              "clientInfo" => %{"name" => "sympp-test-client", "version" => "0.1.0"},
              "capabilities" => %{}
            }
          },
          Server.new(Config.default(repo: Repo), state_key: state_key)
        )

      Repo.put_dynamic_repo(second_pid)

      {tools_response, _server} =
        Server.handle_response_state(
          %{"jsonrpc" => "2.0", "id" => "tools-second-ledger-process", "method" => "tools/list", "params" => %{}},
          Server.new(Config.default(repo: Repo), state_key: state_key)
        )

      assert is_list(get_in(tools_response, ["result", "tools"]))
    after
      Repo.put_dynamic_repo(original_repo)
      if Process.alive?(first_pid), do: GenServer.stop(first_pid)
      if Process.alive?(second_pid), do: GenServer.stop(second_pid)
      File.rm(database)
    end
  end

  test "explicit response state key namespaces blank-path ledgers by configured database" do
    first_database = "file:sympp_mcp_blank_state_#{System.unique_integer([:positive])}?mode=memory&cache=shared"
    second_database = "file:sympp_mcp_blank_state_#{System.unique_integer([:positive])}?mode=memory&cache=shared"
    original_repo = Repo.get_dynamic_repo()

    {:ok, first_pid} =
      Repo.start_link(database: first_database, name: :"sympp_mcp_blank_first_#{System.unique_integer([:positive])}", pool_size: 1, log: false)

    {:ok, second_pid} =
      Repo.start_link(database: second_database, name: :"sympp_mcp_blank_second_#{System.unique_integer([:positive])}", pool_size: 1, log: false)

    try do
      state_key = "blank-ledger-state"

      assert {:ok, %{rows: first_rows}} = SQL.query(first_pid, "PRAGMA database_list", [], log: false)
      assert Enum.any?(first_rows, &match?([_seq, "main", ""], &1))

      {_initialize_response, _server} =
        Server.handle_response_state(
          %{"jsonrpc" => "2.0", "id" => "init-first-blank-ledger", "method" => "initialize", "params" => initialize_params()},
          Server.new(Config.default(repo: first_pid), state_key: state_key)
        )

      assert {:ok, %{rows: second_rows}} = SQL.query(second_pid, "PRAGMA database_list", [], log: false)
      assert Enum.any?(second_rows, &match?([_seq, "main", ""], &1))

      {tools_response, _server} =
        Server.handle_response_state(
          %{"jsonrpc" => "2.0", "id" => "tools-second-blank-ledger", "method" => "tools/list", "params" => %{}},
          Server.new(Config.default(repo: second_pid), state_key: state_key)
        )

      assert get_in(tools_response, ["error", "data", "reason"]) == "server_not_initialized"
    after
      Repo.put_dynamic_repo(original_repo)
      if Process.alive?(first_pid), do: GenServer.stop(first_pid)
      if Process.alive?(second_pid), do: GenServer.stop(second_pid)
    end
  end

  test "response-only handle does not retain unchanged one-shot server state", %{repo: repo} do
    server = Server.new(Config.default(repo: repo), initialized: true)
    delete_handle_state_entry(server)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}}, server)

    assert is_list(get_in(response, ["result", "tools"]))
    refute Map.has_key?(handle_state_store(), handle_state_store_key(server))
  end

  test "response-only handle cleans stale implicit entries while preserving explicit state keys", %{repo: repo} do
    stale_explicit_key = make_ref()
    expired_explicit_key = make_ref()
    stale_server = Server.new(Config.default(repo: repo), initialized: true)
    stale_explicit_server = Server.new(Config.default(repo: repo), initialized: true, state_key: stale_explicit_key)
    expired_explicit_server = Server.new(Config.default(repo: repo), initialized: true, state_key: expired_explicit_key)
    stale_timestamp = System.monotonic_time(:millisecond) - 90_000_000
    expired_explicit_timestamp = System.monotonic_time(:millisecond) - 700_000_000

    put_handle_state_entry(stale_server, {stale_server, stale_timestamp, false})
    put_handle_state_entry(stale_explicit_server, {stale_explicit_server, stale_timestamp, true})
    put_handle_state_entry(expired_explicit_server, {expired_explicit_server, expired_explicit_timestamp, true})

    response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "init-cleanup", "method" => "initialize", "params" => initialize_params()},
        Server.new(Config.default(repo: repo))
      )

    assert get_in(response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    refute Map.has_key?(handle_state_store(), handle_state_store_key(stale_server))
    assert Map.has_key?(handle_state_store(), handle_state_store_key(stale_explicit_server))
    refute Map.has_key?(handle_state_store(), handle_state_store_key(expired_explicit_server))

    explicit_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "tools-after-cleanup", "method" => "tools/list", "params" => %{}},
        Server.new(Config.default(repo: repo), state_key: stale_explicit_key)
      )

    assert is_list(get_in(explicit_response, ["result", "tools"]))
  end

  test "response-only handle refreshes active default state entries", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    init_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "init-refresh", "method" => "initialize", "params" => initialize_params()},
        server
      )

    {stored_server, _timestamp_ms, false} = Map.fetch!(handle_state_store(), handle_state_store_key(server))
    stale_but_active_timestamp = System.monotonic_time(:millisecond) - 59_000
    put_handle_state_entry(server, {stored_server, stale_but_active_timestamp, false})

    tools_response = Server.handle(%{"jsonrpc" => "2.0", "id" => "tools-refresh", "method" => "tools/list", "params" => %{}}, server)

    {_stored_server, refreshed_timestamp, false} = Map.fetch!(handle_state_store(), handle_state_store_key(server))
    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert is_list(get_in(tools_response, ["result", "tools"]))
    assert refreshed_timestamp > stale_but_active_timestamp
  end

  test "response-only handle keeps active default state per namespace", %{repo: repo} do
    timestamp = System.monotonic_time(:millisecond)
    kept_repo_server = Server.new(Config.default(repo: repo), initialized: true)
    other_namespace_server = Server.new(Config.default(repo: UnexpectedAuthRepo), initialized: true)

    Enum.each(1..130, fn offset ->
      server = Server.new(Config.default(repo: repo), initialized: true)
      put_handle_state_entry(server, {server, timestamp + offset, false})
    end)

    put_handle_state_entry(kept_repo_server, {kept_repo_server, timestamp + 1_000, false})
    put_handle_state_entry(other_namespace_server, {other_namespace_server, timestamp - 1_000, false})

    response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "init-trim-namespace", "method" => "initialize", "params" => initialize_params()},
        Server.new(Config.default(repo: repo))
      )

    store = handle_state_store()
    namespace = handle_state_namespace(Config.default(repo: repo))

    repo_default_count =
      Enum.count(store, fn
        {{^namespace, _state_key}, {%Server{}, _timestamp_ms, false}} -> true
        _entry -> false
      end)

    assert get_in(response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert repo_default_count == 132
    assert Map.has_key?(store, handle_state_store_key(kept_repo_server))
    assert Map.has_key?(store, handle_state_store_key(other_namespace_server))
  end

  test "batch items do not inherit session mutations from earlier notifications", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-NOTIFY-CLAIM", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {responses, server} =
      Server.handle_state(
        [
          %{
            "jsonrpc" => "2.0",
            "method" => "tools/call",
            "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
          },
          %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}}
        ],
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert Enum.map(responses, & &1["id"]) == ["assignment"]
    assert get_in(List.first(responses), ["error", "data", "reason"]) == "claim_required"
    assert server.session.assignment.work_package_id == "SYMPP-NOTIFY-CLAIM"
  end

  defp create_http_local_claim_package!(repo, id) do
    package = create_local_claim_package!(repo, id, base_branch: "main")

    work_request =
      create_work_request!(repo,
        id: "WR-#{id}",
        repo: package.repo,
        base_branch: package.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-#{id}",
                 target_base_branch: package.base_branch,
                 branch_pattern: package.branch_pattern
               )
             )

    repo.update!(Ecto.Changeset.change(planned_slice, status: "dispatched", work_package_id: package.id))
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    {package, work_request}
  end
end
