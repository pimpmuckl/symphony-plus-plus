defmodule SymphonyElixir.SymphonyPlusPlus.MCPHTTPEndpointTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, HTTPStateStore, Session}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Server
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository, as: SoloSessionRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.Endpoint

  @endpoint Endpoint
  @client_key "__sympp_mcp_local_http_client__"

  defmodule LazyHTTPRepo do
    @moduledoc false

    use Ecto.Repo, otp_app: :symphony_elixir, adapter: Ecto.Adapters.SQLite3
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])
    sympp_repo_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

    Application.put_env(
      :symphony_elixir,
      Endpoint,
      endpoint_config
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64), sympp_repo: Repo)
    )

    start_supervised!({Repo, database: database_path, pool_size: 1})
    if Process.whereis(Endpoint) == nil, do: start_supervised!({Endpoint, []})

    assert :ok = WorkPackageRepository.migrate(Repo)
    assert :ok = SoloSessionRepository.migrate(Repo)
    assert :ok = PhaseRepository.migrate(Repo)
    assert :ok = WorkRequestRepository.migrate(Repo)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
      restore_sympp_repo_database(sympp_repo_database)
      File.rm(database_path)
    end)

    :ok
  end

  setup do
    reset_server_response_state()
    if Process.whereis(HTTPStateStore) == nil, do: start_supervised!(HTTPStateStore)
    HTTPStateStore.reset!()
    :ok
  end

  test "POST /mcp starts the HTTP state store when endpoint runtime omitted it" do
    restore_mode = remove_http_state_store_for_test()
    on_exit(fn -> restore_http_state_store_for_test(restore_mode) end)

    refute Process.whereis(HTTPStateStore)

    conn = post_json(initialize_request("init"))

    assert %{"jsonrpc" => "2.0", "id" => "init", "result" => %{"serverInfo" => %{"name" => "symphony-plus-plus"}}} =
             json_response(conn, 200)

    assert [_session_id] = get_resp_header(conn, "mcp-session-id")
  end

  test "POST /mcp restarts supervised HTTP state store through the application supervisor" do
    if application_supervises_http_state_store?() do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, HTTPStateStore)
      on_exit(fn -> restore_http_state_store_for_test(:application_supervisor) end)

      refute Process.whereis(HTTPStateStore)

      conn = post_json(initialize_request("restart"))

      assert %{"jsonrpc" => "2.0", "id" => "restart", "result" => %{"serverInfo" => %{"name" => "symphony-plus-plus"}}} =
               json_response(conn, 200)

      assert [_session_id] = get_resp_header(conn, "mcp-session-id")
      assert Process.whereis(HTTPStateStore) == supervised_http_state_store_pid()
    end
  end

  test "POST /mcp initialize returns JSON and Mcp-Session-Id" do
    conn = post_json(initialize_request("init"))

    assert %{"jsonrpc" => "2.0", "id" => "init", "result" => %{"serverInfo" => %{"name" => "symphony-plus-plus"}}} =
             json_response(conn, 200)

    assert [session_id] = get_resp_header(conn, "mcp-session-id")
    assert session_id =~ ~r/^[!-~]+$/
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "POST /mcp tools/list uses Mcp-Session-Id continuity" do
    init = post_json(initialize_request("init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    conn = post_json(tools_list_request("tools"), [{"mcp-session-id", session_id}])

    assert [^session_id] = get_resp_header(conn, "mcp-session-id")

    assert tool_names(json_response(conn, 200)) == [
             "claim_work_key",
             "solo_append",
             "solo_attach",
             "solo_list",
             "solo_show",
             "solo_update_status",
             "sympp.health"
           ]
  end

  test "POST /mcp persists claimed worker continuity over same Mcp-Session-Id" do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(id: "SYMPP-HTTP-ENDPOINT-WORKER", kind: "mcp", status: "ready_for_worker")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(Repo, work_package.id)

    init = post_json(initialize_request("init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    claim =
      post_json(
        tool_call_request("claim", "claim_work_key", %{"secret" => minted.work_key.secret, "claimed_by" => "worker-http"}),
        [{"mcp-session-id", session_id}]
      )

    assert [^session_id] = get_resp_header(claim, "mcp-session-id")
    assert get_in(json_response(claim, 200), ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id

    tools = post_json(tools_list_request("worker-tools"), [{"mcp-session-id", session_id}])
    tool_names = tool_names(json_response(tools, 200))

    assert "get_current_assignment" in tool_names
    assert "append_progress" in tool_names
    refute "solo_attach" in tool_names

    assignment_tool =
      post_json(tool_call_request("assignment-tool", "get_current_assignment", %{}), [{"mcp-session-id", session_id}])

    assert get_in(json_response(assignment_tool, 200), ["result", "structuredContent", "assignment", "work_package_id"]) ==
             work_package.id

    assignment_resource =
      post_json(resources_read_request("assignment-resource", "sympp://assignment/current"), [{"mcp-session-id", session_id}])

    assignment_payload =
      assignment_resource
      |> json_response(200)
      |> resource_payload()

    assert assignment_payload["work_package_id"] == work_package.id

    resources = post_json(resources_list_request("resources"), [{"mcp-session-id", session_id}])

    assert "sympp://work-packages/#{work_package.id}/task_plan.md" in resource_uris(json_response(resources, 200))
  end

  test "POST /mcp persists claimed architect continuity for scoped WorkRequest reads" do
    phase_id = "phase-http-endpoint-architect"

    assert {:ok, _phase} = PhaseRepository.create(Repo, %{id: phase_id, title: "HTTP endpoint architect phase"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-HTTP-ENDPOINT-ARCHITECT",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "main",
                 phase_id: phase_id,
                 status: "planning"
               )
             )

    assert {:ok, work_request} =
             WorkRequestRepository.create(
               Repo,
               work_request_attrs(%{
                 id: "WR-HTTP-ENDPOINT-ARCHITECT",
                 repo: anchor.repo,
                 base_branch: anchor.base_branch,
                 status: "ready_for_slicing"
               })
             )

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(Repo, phase_id,
               work_package_id: anchor.id,
               capabilities: ["read:work_request"]
             )

    init = post_json(initialize_request("init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    claim =
      post_json(
        tool_call_request("claim", "claim_work_key", %{"secret" => minted.work_key.secret, "claimed_by" => "architect-http"}),
        [{"mcp-session-id", session_id}]
      )

    assert get_in(json_response(claim, 200), ["result", "structuredContent", "assignment", "grant_role"]) == "architect"

    tools = post_json(tools_list_request("architect-tools"), [{"mcp-session-id", session_id}])
    tool_names = tool_names(json_response(tools, 200))

    assert "get_current_assignment" in tool_names
    assert "read_work_request" in tool_names
    refute "solo_attach" in tool_names

    read =
      post_json(
        tool_call_request("read-work-request", "read_work_request", %{"work_request_id" => work_request.id}),
        [{"mcp-session-id", session_id}]
      )

    assert get_in(json_response(read, 200), ["result", "structuredContent", "work_request", "id"]) == work_request.id
  end

  test "POST /mcp claimed worker follow-ups fail closed after grant revocation" do
    assert {:ok, work_package} =
             WorkPackageRepository.create(
               Repo,
               WorkPackageFactory.attrs(id: "SYMPP-HTTP-ENDPOINT-REVOKED", kind: "mcp", status: "ready_for_worker")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(Repo, work_package.id)

    init = post_json(initialize_request("init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    claim =
      post_json(
        tool_call_request("claim", "claim_work_key", %{"secret" => minted.work_key.secret, "claimed_by" => "worker-revoked"}),
        [{"mcp-session-id", session_id}]
      )

    assert get_in(json_response(claim, 200), ["result", "structuredContent", "assignment", "work_package_id"]) == work_package.id
    assert {:ok, _revoked} = AccessGrantService.revoke(Repo, minted.grant.id)

    tools = post_json(tools_list_request("revoked-tools"), [{"mcp-session-id", session_id}])
    tool_names = tool_names(json_response(tools, 200))

    assert "claim_work_key" in tool_names
    refute "get_current_assignment" in tool_names

    assignment_tool =
      post_json(tool_call_request("revoked-assignment", "get_current_assignment", %{}), [{"mcp-session-id", session_id}])

    assert get_in(json_response(assignment_tool, 200), ["error", "data", "reason"]) == "revoked"

    progress =
      post_json(
        tool_call_request("revoked-progress", "append_progress", %{"summary" => "Should not write", "idempotency_key" => "revoked-progress"}),
        [{"mcp-session-id", session_id}]
      )

    assert get_in(json_response(progress, 200), ["error", "data", "reason"]) == "revoked"

    assignment_resource =
      post_json(resources_read_request("revoked-resource", "sympp://assignment/current"), [{"mcp-session-id", session_id}])

    assert get_in(json_response(assignment_resource, 200), ["error", "data", "reason"]) == "revoked"
  end

  test "POST /mcp dispatches Solo tools through the dashboard lazy repo seam" do
    database_path = WorkPackageFactory.database_path()
    workspace_path = solo_workspace_path("lazy-repo")
    original_repo_config = Application.get_env(:symphony_elixir, LazyHTTPRepo)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.put_env(:symphony_elixir, LazyHTTPRepo, database: database_path)

    on_exit(fn ->
      restore_app_env(LazyHTTPRepo, original_repo_config)
      restore_sympp_repo_database(original_database)
      File.rm(database_path)
      File.rm_rf(workspace_path)
    end)

    with_endpoint_repo(LazyHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      tool_notification = post_json(tool_call_notification("solo_list", %{}), [{"mcp-session-id", session_id}])

      conn =
        post_json(
          tool_call_request("attach", "solo_attach", %{
            "repo" => "nextide/example",
            "base_branch" => "main",
            "workspace_path" => workspace_path,
            "caller_id" => "codex-local"
          }),
          [{"mcp-session-id", session_id}]
        )

      assert response(tool_notification, 202) == ""
      assert get_in(json_response(conn, 200), ["result", "structuredContent", "action"]) == "solo_attach"
      assert File.exists?(database_path)
    end)
  end

  test "POST /mcp preserves custom repo sessions through the dashboard fallback database" do
    fallback_database_path = WorkPackageFactory.database_path()
    original_repo_config = Application.get_env(:symphony_elixir, Repo)
    original_lazy_repo_config = Application.get_env(:symphony_elixir, LazyHTTPRepo)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, Repo, database: fallback_database_path)
    Application.delete_env(:symphony_elixir, LazyHTTPRepo)

    on_exit(fn ->
      restore_app_env(Repo, original_repo_config)
      restore_app_env(LazyHTTPRepo, original_lazy_repo_config)
      restore_sympp_repo_database(original_database)
      File.rm(fallback_database_path)
    end)

    with_endpoint_repo(LazyHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      tools = post_json(tools_list_request("tools"), [{"mcp-session-id", session_id}])

      assert "sympp.health" in tool_names(json_response(tools, 200))
      assert File.exists?(fallback_database_path)
    end)
  end

  test "POST /mcp keeps state-local follow-up traffic independent from lazy repo failures" do
    database_path = WorkPackageFactory.database_path()
    mismatch_database_path = WorkPackageFactory.database_path()
    original_repo_config = Application.get_env(:symphony_elixir, LazyHTTPRepo)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, LazyHTTPRepo, database: database_path)

    on_exit(fn ->
      if pid = Process.whereis(LazyHTTPRepo), do: GenServer.stop(pid, :normal, 5_000)
      restore_app_env(LazyHTTPRepo, original_repo_config)
      restore_sympp_repo_database(original_database)
      File.rm_rf(database_path)
      File.rm(mismatch_database_path)
    end)

    with_endpoint_repo(LazyHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")

      {:ok, mismatch_repo} = LazyHTTPRepo.start_link(database: mismatch_database_path, pool_size: 1)
      Process.unlink(mismatch_repo)

      tools = post_json(tools_list_request("tools"), [{"mcp-session-id", session_id}])
      notification = post_json(notification_request(), [{"mcp-session-id", session_id}])
      repo_backed = post_json(tool_call_request("repo-backed", "solo_list", %{}), [{"mcp-session-id", session_id}])
      repo_backed_notification = post_json(tool_call_notification("solo_list", %{}), [{"mcp-session-id", session_id}])
      repo_backed_resource = post_json(resources_list_request("resources"), [{"mcp-session-id", session_id}])
      health = post_json(tool_call_request("health", "sympp.health", %{}), [{"mcp-session-id", session_id}])

      version_resource =
        post_json(resources_read_request("version", "sympp://health/version"), [{"mcp-session-id", session_id}])

      protected_resource =
        post_json(
          resources_read_request("protected", "sympp://work-packages/SYMPP-MCP-HTTP/task_plan.md"),
          [{"mcp-session-id", session_id}]
        )

      unknown = post_json(tools_list_request("missing"), [{"mcp-session-id", "missing-session"}])

      assert "solo_attach" in tool_names(json_response(tools, 200))
      assert response(notification, 202) == ""
      assert json_response(repo_backed, 503) == json_rpc_error("repo-backed", -32_000, "Server error", "ledger_unavailable")
      assert json_response(repo_backed_notification, 503) == json_rpc_error(nil, -32_000, "Server error", "ledger_unavailable")
      assert json_response(repo_backed_resource, 503) == json_rpc_error("resources", -32_000, "Server error", "ledger_unavailable")
      assert get_in(json_response(health, 200), ["result", "structuredContent", "mode"]) == "http"
      assert get_in(json_response(version_resource, 200), ["result", "contents", Access.at(0), "uri"]) == "sympp://health/version"
      assert json_response(protected_resource, 503) == json_rpc_error("protected", -32_000, "Server error", "ledger_unavailable")
      assert get_in(json_response(unknown, 404), ["error", "data", "reason"]) == "unknown_state_key"
    end)
  end

  test "POST /mcp routes claimed tools/list through the dashboard lazy repo seam" do
    database_path = WorkPackageFactory.database_path()
    mismatch_database_path = WorkPackageFactory.database_path()
    original_repo_config = Application.get_env(:symphony_elixir, LazyHTTPRepo)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    Application.put_env(:symphony_elixir, LazyHTTPRepo, database: database_path)

    on_exit(fn ->
      if pid = Process.whereis(LazyHTTPRepo), do: GenServer.stop(pid, :normal, 5_000)
      restore_app_env(LazyHTTPRepo, original_repo_config)
      restore_sympp_repo_database(original_database)
      File.rm(database_path)
      File.rm(mismatch_database_path)
    end)

    with_endpoint_repo(LazyHTTPRepo, fn ->
      init = post_json(initialize_request("init"))
      [session_id] = get_resp_header(init, "mcp-session-id")
      config = Config.default(mode: :http, repo: LazyHTTPRepo, database: database_path)
      %Server{} = server = HTTPStateStore.get(config, @client_key, session_id)

      assert :ok = HTTPStateStore.put(config, @client_key, session_id, %{server | session: claimed_session()})

      {:ok, mismatch_repo} = LazyHTTPRepo.start_link(database: mismatch_database_path, pool_size: 1)
      Process.unlink(mismatch_repo)

      conn = post_json(tools_list_request("claimed-tools"), [{"mcp-session-id", session_id}])

      assert json_response(conn, 503) == json_rpc_error("claimed-tools", -32_000, "Server error", "ledger_unavailable")
    end)
  end

  test "POST /mcp fails closed when dashboard lazy repo startup fails" do
    database_path = WorkPackageFactory.database_path()
    original_repo_config = Application.get_env(:symphony_elixir, LazyHTTPRepo)

    File.mkdir_p!(database_path)
    Application.put_env(:symphony_elixir, LazyHTTPRepo, database: database_path)

    on_exit(fn ->
      restore_app_env(LazyHTTPRepo, original_repo_config)
      File.rm_rf(database_path)
    end)

    with_endpoint_repo(LazyHTTPRepo, fn ->
      conn = post_json(initialize_request("init"))

      assert json_response(conn, 503) == json_rpc_error("init", -32_000, "Server error", "ledger_unavailable")
      assert get_resp_header(conn, "mcp-session-id") == []
      assert :sys.get_state(HTTPStateStore).entries == %{}
    end)
  end

  test "POST /mcp notification returns 202 with no body and preserves state" do
    init = post_json(initialize_request("init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    notification = post_json(notification_request(), [{"mcp-session-id", session_id}])

    assert response(notification, 202) == ""
    assert [^session_id] = get_resp_header(notification, "mcp-session-id")

    conn = post_json(tools_list_request("after-notification"), [{"mcp-session-id", session_id}])

    assert "sympp.health" in tool_names(json_response(conn, 200))
  end

  test "POST /mcp requires Mcp-Session-Id for non-initialize requests" do
    conn = post_json(tools_list_request("tools"))

    assert json_response(conn, 400) == json_rpc_error("tools", -32_600, "Invalid Request", "missing_session_id")
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "POST /mcp rejects JSON-RPC batches before session handling" do
    init_batch = post_json([initialize_request("init")])
    mixed_batch = post_json([initialize_request("init"), tools_list_request("tools")])

    assert json_response(init_batch, 400) == json_rpc_error(nil, -32_600, "Invalid Request", "batch_not_supported")

    assert json_response(mixed_batch, 400) ==
             json_rpc_error(nil, -32_600, "Invalid Request", "batch_not_supported")

    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "POST /mcp rejects JSON-RPC batches before Mcp-Session-Id continuity" do
    init = post_json(initialize_request("init"))
    [session_id] = get_resp_header(init, "mcp-session-id")

    conn = post_json([initialize_request("init"), tools_list_request("tools")])

    conn_with_session = post_json([tools_list_request("tools")], [{"mcp-session-id", session_id}])

    assert json_response(conn, 400) == json_rpc_error(nil, -32_600, "Invalid Request", "batch_not_supported")

    assert json_response(conn_with_session, 400) ==
             json_rpc_error(nil, -32_600, "Invalid Request", "batch_not_supported")
  end

  test "POST /mcp rejects unknown Mcp-Session-Id without creating state" do
    conn = post_json(tools_list_request("tools"), [{"mcp-session-id", "missing-session"}])

    assert get_in(json_response(conn, 404), ["error", "data", "reason"]) == "unknown_state_key"
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "POST /mcp rejects unknown Mcp-Session-Id for notifications" do
    conn = post_json(notification_request(), [{"mcp-session-id", "missing-session"}])

    assert json_response(conn, 404) == json_rpc_error(nil, -32_600, "Invalid Request", "unknown_state_key")
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "POST /mcp rejects malformed Mcp-Session-Id bytes without crashing" do
    conn = post_json(tools_list_request("tools"), [{"mcp-session-id", <<255>>}])

    assert json_response(conn, 400) == json_rpc_error("tools", -32_600, "Invalid Request", "invalid_session_id")
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "POST /mcp rejects reserved Mcp-Session-Id values without dispatching" do
    conn = post_json(tools_list_request("tools"), [{"mcp-session-id", "__sympp_mcp_current_state__"}])

    assert json_response(conn, 400) == json_rpc_error("tools", -32_600, "Invalid Request", "invalid_session_id")
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "POST /mcp invalid JSON returns controlled JSON-RPC error" do
    conn = post_raw("{")

    assert json_response(conn, 400) == json_rpc_error(nil, -32_700, "Parse error", "invalid_json")
    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  test "GET /mcp returns 405 because this slice does not implement SSE" do
    conn =
      local_conn()
      |> get("/mcp")

    assert json_response(conn, 405) == json_rpc_error(nil, -32_601, "Method not found", "method_not_allowed")
    assert get_resp_header(conn, "allow") == ["POST"]
  end

  test "POST /mcp rejects non-loopback, forwarded, and cross-origin requests" do
    assert get_in(post_json(initialize_request("remote"), [], remote_ip: {10, 0, 0, 2}) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "local_only"

    assert get_in(post_json(initialize_request("forwarded"), [{"x-forwarded-for", "10.0.0.2"}]) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "local_only"

    assert get_in(post_json(initialize_request("origin"), [{"origin", "http://localhost:9999"}]) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "origin_not_allowed"

    assert get_in(post_json(initialize_request("malformed-host"), [], host: <<255>>) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "local_only"

    assert get_in(post_json(initialize_request("malformed-origin"), [{"origin", <<255>>}]) |> json_response(403), [
             "error",
             "data",
             "reason"
           ]) == "origin_not_allowed"

    assert :sys.get_state(HTTPStateStore).entries == %{}
  end

  defp post_json(payload, headers \\ [], opts \\ []) do
    payload
    |> Jason.encode!()
    |> post_raw(headers, opts)
  end

  defp post_raw(body, headers \\ [], opts \\ []) do
    headers = [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"} | headers]

    opts
    |> local_conn()
    |> put_headers(headers)
    |> post("/mcp", body)
  end

  defp local_conn(opts \\ []) do
    build_conn()
    |> Map.put(:host, Keyword.get(opts, :host, "localhost"))
    |> Map.put(:port, Keyword.get(opts, :port, 4000))
    |> Map.put(:remote_ip, Keyword.get(opts, :remote_ip, {127, 0, 0, 1}))
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
  end

  defp initialize_request(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "clientInfo" => %{"name" => "sympp-http-endpoint-test-client", "version" => "0.1.0"},
        "capabilities" => %{}
      }
    }
  end

  defp tools_list_request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list", "params" => %{}}
  defp resources_list_request(id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "resources/list", "params" => %{}}
  defp resources_read_request(id, uri), do: %{"jsonrpc" => "2.0", "id" => id, "method" => "resources/read", "params" => %{"uri" => uri}}
  defp notification_request, do: %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}

  defp tool_call_request(id, name, arguments) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}}
  end

  defp tool_call_notification(name, arguments) do
    %{"jsonrpc" => "2.0", "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}}
  end

  defp tool_names(payload) do
    payload
    |> get_in(["result", "tools"])
    |> Enum.map(& &1["name"])
    |> Enum.sort()
  end

  defp resource_uris(payload) do
    payload
    |> get_in(["result", "resources"])
    |> Enum.map(& &1["uri"])
    |> Enum.sort()
  end

  defp resource_payload(payload) do
    payload
    |> get_in(["result", "contents", Access.at(0), "text"])
    |> Jason.decode!()
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-HTTP-#{System.unique_integer([:positive])}",
      title: "HTTP MCP WorkRequest",
      repo: "nextide/symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Prove HTTP MCP architect continuity.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false},
      desired_dispatch_shape: "single_package",
      status: "draft"
    }

    Enum.into(overrides, defaults)
  end

  defp json_rpc_error(id, code, message, reason) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message, "data" => %{"reason" => reason}}}
  end

  defp reset_server_response_state do
    handle_state_agent = Module.concat(Server, HandleState)

    case Process.whereis(handle_state_agent) do
      nil -> :ok
      _pid -> reset_handle_state_agent(handle_state_agent)
    end
  end

  defp reset_handle_state_agent(handle_state_agent) do
    Agent.update(handle_state_agent, fn _store -> %{} end)
  catch
    :exit, _reason -> :ok
  end

  defp claimed_session do
    Session.new(%Assignment{
      grant_id: "grant-http-claimed",
      work_package_id: "SYMPP-MCP-HTTP",
      phase_id: nil,
      display_key: "SYMPP-MCP-HTTP",
      grant_role: "worker",
      capabilities: ["read:assignment"],
      claimed_at: DateTime.utc_now(:microsecond),
      claimed_by: "codex-local"
    })
  end

  defp restore_sympp_repo_database(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_database)
  defp restore_sympp_repo_database(database), do: Application.put_env(:symphony_elixir, :sympp_repo_database, database)

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp remove_http_state_store_for_test do
    if application_supervises_http_state_store?() do
      _result = Supervisor.terminate_child(SymphonyElixir.Supervisor, HTTPStateStore)
      _result = Supervisor.delete_child(SymphonyElixir.Supervisor, HTTPStateStore)
      :application_supervisor
    else
      stop_http_state_store()
      :standalone
    end
  end

  defp restore_http_state_store_for_test(:application_supervisor) do
    stop_http_state_store()

    case Supervisor.start_child(SymphonyElixir.Supervisor, HTTPStateStore) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp restore_http_state_store_for_test(:standalone), do: stop_http_state_store()

  defp application_supervises_http_state_store? do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        Enum.any?(Supervisor.which_children(SymphonyElixir.Supervisor), fn
          {HTTPStateStore, _pid, _type, _modules} -> true
          _child -> false
        end)

      nil ->
        false
    end
  end

  defp supervised_http_state_store_pid do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        Enum.find_value(Supervisor.which_children(SymphonyElixir.Supervisor), fn
          {HTTPStateStore, child_pid, _type, _modules} when is_pid(child_pid) -> child_pid
          _child -> nil
        end)

      nil ->
        nil
    end
  end

  defp stop_http_state_store do
    case Process.whereis(HTTPStateStore) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end
  catch
    :exit, _reason -> :ok
  end

  defp with_endpoint_repo(repo, fun) do
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    Application.put_env(:symphony_elixir, Endpoint, Keyword.put(endpoint_config, :sympp_repo, repo))

    try do
      fun.()
    after
      Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
    end
  end

  defp solo_workspace_path(name) do
    path = Path.join(System.tmp_dir!(), "sympp-mcp-http-solo-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
