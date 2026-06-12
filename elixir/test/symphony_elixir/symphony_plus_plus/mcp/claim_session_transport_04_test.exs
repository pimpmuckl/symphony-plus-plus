Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimSessionTransport04Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{HTTPStateStore, HTTPTransport, Session}

  test "unbound claim schemas advertise durable ids and mark optional hints advanced", %{repo: repo} do
    response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "claim-schema-tools", "method" => "tools/list", "params" => %{}},
        Server.new(Config.default(repo: repo), initialized: true)
      )

    tools_by_name =
      response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    worker_claim = Map.fetch!(tools_by_name, "claim_local_assignment")
    architect_claim = Map.fetch!(tools_by_name, "claim_local_architect_assignment")

    assert worker_claim["description"] =~ "Normal calls pass only work_package_id"
    assert get_in(worker_claim, ["inputSchema", "required"]) == ["work_package_id"]
    assert get_in(worker_claim, ["inputSchema", "properties", "work_package_id", "description"]) =~ "normal worker claim coordinate"
    assert get_in(worker_claim, ["inputSchema", "properties", "claimed_by", "description"]) =~ "Optional stable audit owner"

    for hint <- ["repo", "base_branch", "work_request_id", "branch", "worktree_path", "caller_id"] do
      description = get_in(worker_claim, ["inputSchema", "properties", hint, "description"])
      assert description =~ "Advanced/debug hint"
      assert description =~ "ignored-hint recovery metadata"
      assert description =~ "Server-recorded authority boundaries still fail closed"
    end

    assert architect_claim["description"] =~ "Normal calls pass only work_request_id"
    assert get_in(architect_claim, ["inputSchema", "required"]) == ["work_request_id"]
    assert get_in(architect_claim, ["inputSchema", "properties", "work_request_id", "description"]) =~ "normal architect claim coordinate"

    for hint <- ["repo", "base_branch", "architect_anchor_work_package_id", "phase_id", "caller_id"] do
      description = get_in(architect_claim, ["inputSchema", "properties", hint, "description"])
      assert description =~ "Advanced/debug hint"
      assert description =~ "ignored-hint recovery metadata"
      assert description =~ "Server-recorded authority boundaries still fail closed"
    end
  end

  test "response-only handle supports explicit state keys for recreated servers through local claim replay", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATELESS-HANDLE")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)
    state_key = make_ref()

    init_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    claim_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    reconnect_claim_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-again",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    refute inspect(claim_response) =~ minted.work_key.secret
    assert get_in(assignment_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(reconnect_claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
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

  test "explicit state key stale live server remains local-claim-only until new session", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-STALE-LIVE")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)
    state_key = make_ref()

    {_init_response, initialized_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    {_claim_response, claimed_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        initialized_server
      )

    reinit_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "init-again", "method" => "initialize", "params" => initialize_params()},
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    {tools_response, tools_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "tools-after-stale-reinit", "method" => "tools/list", "params" => %{}},
        claimed_server
      )

    tools_by_name = tools_response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    {stale_solo_response, _stale_solo_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "solo-after-stale-init", "method" => "tools/call", "params" => %{"name" => "solo_attach", "arguments" => %{}}},
        tools_server
      )

    {fresh_init_response, fresh_initialized_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "fresh-init-after-stale", "method" => "initialize", "params" => initialize_params()},
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    {fresh_tools_response, _fresh_tools_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "tools-after-fresh-init", "method" => "tools/list", "params" => %{}},
        fresh_initialized_server
      )

    fresh_tools_by_name = fresh_tools_response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    assert get_in(reinit_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert Map.keys(tools_by_name) |> Enum.sort() == ["claim_local_architect_assignment", "claim_local_assignment", "sympp.health"]
    assert get_in(stale_solo_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(stale_solo_response, ["error", "data", "action"]) == "claim_local_assignment"
    assert get_in(fresh_init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    refute Map.has_key?(tools_by_name, "get_current_assignment")
    assert Map.has_key?(fresh_tools_by_name, "read_work_request")
    assert Map.has_key?(fresh_tools_by_name, "solo_attach")
    assert Map.has_key?(fresh_tools_by_name, "get_current_assignment")
  end

  test "explicit state key duplicate initialize preserves active live session", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-STATE-LIVE-DUP")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    state_key = make_ref()

    {_init_response, initialized_server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        Server.new(local_mcp_config(repo), state_key: state_key)
      )

    {_claim_response, claimed_server} =
      Server.handle_response_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
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

    assert get_in(duplicate_init_response, ["error", "data", "reason"]) == "already_initialized"
    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  test "HTTP local assignment release clears the current claim lease", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-HTTP-LOCAL-RELEASE")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    config = local_mcp_config(repo)
    client_key = "client-http-local-release"

    {:ok, init_result} =
      HTTPTransport.handle(config, %{"jsonrpc" => "2.0", "id" => "init-local-release", "method" => "initialize", "params" => initialize_params()}, client_key: client_key)

    {:ok, claim_result} =
      HTTPTransport.handle(
        config,
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-local-release",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(claim_result.response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert {:ok, %ClaimLease{id: lease_id, actor_id: "local:" <> _hash}} = ClaimLeaseService.current_for_work_package(repo, package.id)

    {:ok, release_result} =
      HTTPTransport.handle(
        config,
        %{
          "jsonrpc" => "2.0",
          "id" => "release-live-local",
          "method" => "tools/call",
          "params" => %{"name" => "release_current_assignment", "arguments" => %{"reason" => "done"}}
        },
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(release_result.response, ["result", "structuredContent", "binding_cleared"]) == true
    assert get_in(release_result.response, ["result", "structuredContent", "claim_lease_release", "claim_lease_id"]) == lease_id
    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, package.id)
  end

  test "HTTP local assignment recovery rehydrates a worker session", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-HTTP-LOCAL-RECOVERY")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    config = local_mcp_config(repo)
    client_key = "client-http-local-recovery"

    {:ok, init_result} =
      HTTPTransport.handle(config, %{"jsonrpc" => "2.0", "id" => "init-local-recovery", "method" => "initialize", "params" => initialize_params()}, client_key: client_key)

    {:ok, claim_result} =
      HTTPTransport.handle(
        config,
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-local-recovery",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(claim_result.response, ["result", "structuredContent", "assignment", "grant_id"]) == minted.grant.id

    HTTPStateStore.reset!()

    {:ok, assignment_result} =
      HTTPTransport.handle(
        config,
        %{"jsonrpc" => "2.0", "id" => "assignment-after-reset", "method" => "tools/call", "params" => %{"name" => "get_current_assignment", "arguments" => %{}}},
        client_key: client_key,
        state_key: init_result.state_key
      )

    assert get_in(assignment_result.response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert %Server{session: %Session{assignment: %{work_package_id: package_id}}} = HTTPStateStore.get(config, client_key, init_result.state_key)
    assert package_id == package.id
  end
end
