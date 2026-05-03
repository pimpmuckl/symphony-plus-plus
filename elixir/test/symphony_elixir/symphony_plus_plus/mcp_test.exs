Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import ExUnit.CaptureIO

  alias Mix.Tasks.Sympp.Mcp, as: McpTask
  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Server, Session, Stdio}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  defmodule FailingAuthRepo do
    def get(_schema, _id), do: raise(RuntimeError, "ledger unavailable")
  end

  defmodule UnexpectedAuthRepo do
    def get(_schema, _id), do: {:error, :ledger_down}
  end

  defmodule FailingHealthRepo do
    def query(_sql, _params, _opts), do: {:error, %RuntimeError{message: "C:/secret/path.sqlite"}}
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "config parser defaults to stdio and rejects unsupported modes" do
    assert {:ok, %Config{mode: :stdio, database: nil}} = Config.parse([])
    assert {:ok, %Config{mode: :stdio, database: "tmp/sympp.sqlite3"}} = Config.parse(["--database", "tmp/sympp.sqlite3"])
    assert {:ok, %Config{work_key_secret_env: "SYMPP_MCP_SECRET"}} = Config.parse(["--work-key-secret-env", "SYMPP_MCP_SECRET"])
    assert {:error, message} = Config.parse(["--mode", "http"])
    assert message =~ "Only STDIO MCP mode is supported"
  end

  test "database-scoped repo binding reaches the requested ledger while the default repo is running" do
    database_path = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()

    {:ok, pid} =
      Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

    try do
      Repo.put_dynamic_repo(pid)

      assert {:ok, %{rows: rows}} = Repo.query("PRAGMA database_list", [], log: false)
      assert Enum.any?(rows, &main_database_row_matches?(&1, database_path))
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  test "mix task database option reaches the requested ledger while the default repo is running" do
    database_path = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()
    original_logger_config = Application.fetch_env(:logger, :console)

    input =
      [
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => initialize_params()}),
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/call", "params" => %{"name" => "sympp.health", "arguments" => %{}}})
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    output =
      capture_io(input, fn ->
        McpTask.run(["--database", database_path])
      end)

    responses = decode_json_lines(output)

    assert Enum.any?(responses, fn response ->
             get_in(response, ["result", "structuredContent", "ledger", "reachable"]) == true
           end)

    assert Repo.get_dynamic_repo() == original_repo
    assert :global.whereis_name(Repo.process_key(database_path)) == :undefined
    assert Application.fetch_env(:logger, :console) == original_logger_config
    File.rm(database_path)
  end

  test "mix task without database option reuses the current dynamic repo" do
    database_path = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()
    env_var = "SYMPP_MCP_TEST_SECRET_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

    try do
      Repo.put_dynamic_repo(pid)
      assert :ok = WorkPackageRepository.migrate(Repo)
      assert {:ok, package} = WorkPackageRepository.create(Repo, WorkPackageFactory.attrs(id: "SYMPP-P3-001"))
      assert {:ok, minted} = AccessGrantService.mint_worker_grant(Repo, package.id)
      assert {:ok, _assignment} = AccessGrantService.claim(Repo, minted.work_key.secret, claimed_by: "worker-1")
      System.put_env(env_var, minted.work_key.secret)

      input =
        [
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}),
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "resources/read",
            "params" => %{"uri" => "sympp://assignment/current"}
          })
        ]
        |> Enum.join("\n")
        |> Kernel.<>("\n")

      output =
        capture_io(input, fn ->
          McpTask.run(["--work-key-secret-env", env_var])
        end)

      [_init_response, response] = decode_json_lines(output)
      text = get_in(response, ["result", "contents", Access.at(0), "text"])

      assert Jason.decode!(text)["work_package_id"] == "SYMPP-P3-001"
      assert Repo.get_dynamic_repo() == pid
    after
      System.delete_env(env_var)
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  test "mix task reuses an already-started repo for the exact SQLite URI" do
    database = "file:sympp_mcp_#{System.unique_integer([:positive])}?mode=memory&cache=shared"
    original_repo = Repo.get_dynamic_repo()
    original_logger_config = Application.fetch_env(:logger, :console)
    {:ok, pid} = Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 1, log: false)

    input =
      [
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}),
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        })
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    try do
      output =
        capture_io(input, fn ->
          McpTask.run(["--database", database])
        end)

      responses = decode_json_lines(output)

      assert Enum.any?(responses, fn response ->
               get_in(response, ["result", "structuredContent", "ledger", "reachable"]) == true
             end)

      assert Process.alive?(pid)
      assert Repo.get_dynamic_repo() == original_repo
      assert Application.fetch_env(:logger, :console) == original_logger_config
    after
      GenServer.stop(pid)
    end
  end

  test "harness config override does not require a repo option" do
    config = Config.default(repo: Repo, version: "test-version")

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/read", "params" => %{"uri" => "sympp://health/version"}},
        config: config
      )

    text = get_in(response, ["result", "contents", Access.at(0), "text"])
    assert Jason.decode!(text)["version"] == "test-version"
  end

  test "initialize returns server version and MCP capabilities", %{repo: repo} do
    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => initialize_params()},
        repo: repo
      )

    assert response["jsonrpc"] == "2.0"
    assert response["id"] == 1
    assert get_in(response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert get_in(response, ["result", "serverInfo", "version"])
    assert get_in(response, ["result", "capabilities", "tools"]) == %{}
    assert get_in(response, ["result", "capabilities", "resources"]) == %{}
  end

  test "server requires initialize before MCP operations", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    pre_init_response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}}, server)

    assert get_in(pre_init_response, ["error", "code"]) == -32_000
    assert get_in(pre_init_response, ["error", "data", "reason"]) == "server_not_initialized"

    {init_response, initialized_server} =
      Server.handle_state(%{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}, server)

    assert init_response["result"]["protocolVersion"] == "2025-03-26"
    assert initialized_server.initialized == true

    post_init_response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}}, initialized_server)

    assert is_list(get_in(post_init_response, ["result", "tools"]))
  end

  test "tools list advertises worker argument schemas", %{repo: repo} do
    server = Server.new(Config.default(repo: repo), initialized: true)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}}, server)
    tools = get_in(response, ["result", "tools"])
    tools_by_name = Map.new(tools, &{&1["name"], &1})

    assert get_in(tools_by_name, ["claim_work_key", "inputSchema", "required"]) == ["secret", "claimed_by"]
    assert get_in(tools_by_name, ["claim_work_key", "inputSchema", "properties", "secret", "type"]) == "string"
    assert get_in(tools_by_name, ["append_progress", "inputSchema", "required"]) == ["summary", "idempotency_key"]
    assert get_in(tools_by_name, ["append_finding", "inputSchema", "required"]) == ["title", "body", "idempotency_key"]
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "required"]) == ["expected_version"]
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties", "expected_version", "type"]) == "integer"
    assert get_in(tools_by_name, ["set_status", "inputSchema", "required"]) == ["status", "expected_status"]
    assert get_in(tools_by_name, ["report_blocker", "inputSchema", "properties", "blocker_id", "type"]) == "string"
    assert get_in(tools_by_name, ["resolve_blocker", "inputSchema", "required"]) == ["blocker_id", "resolution", "summary", "idempotency_key"]
    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "required"]) == ["url", "head_sha"]
    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "properties", "head_sha", "type"]) == "string"
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "required"]) == ["summary", "tests", "artifacts"]
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "reviews", "type"]) == "array"
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "head_sha", "type"]) == ["string", "null"]
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "acceptance_criteria_met", "type"]) == "boolean"
  end

  test "server rejects re-initialize after handshake", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))
    initialize_request = %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}

    {_init_response, initialized_server} = Server.handle_state(initialize_request, server)
    {second_response, second_server} = Server.handle_state(%{initialize_request | "id" => "init-again"}, initialized_server)

    assert get_in(second_response, ["error", "code"]) == -32_600
    assert get_in(second_response, ["error", "data", "reason"]) == "already_initialized"
    assert second_server.initialized == true
  end

  test "initialize rejects missing protocol versions and negotiates supported version", %{repo: repo} do
    missing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}},
        repo: repo
      )

    negotiated_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "initialize",
          "params" => %{initialize_params() | "protocolVersion" => "2024-11-05"}
        },
        repo: repo
      )

    assert get_in(missing_response, ["error", "code"]) == -32_602
    assert get_in(missing_response, ["error", "data", "reason"]) == "missing_protocol_version"
    assert get_in(negotiated_response, ["result", "protocolVersion"]) == "2025-03-26"
  end

  test "initialize rejects partial handshake params", %{repo: repo} do
    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{"protocolVersion" => "2025-03-26"}},
        repo: repo
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "invalid_initialize_params"
  end

  test "health tool reaches the test ledger without exposing package rows", %{repo: repo} do
    assert {:ok, _work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-001"))

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        repo: repo
      )

    result = get_in(response, ["result", "structuredContent"])
    text = get_in(response, ["result", "content", Access.at(0), "text"])

    assert result["status"] == "ok"
    assert result["ledger"] == %{"reachable" => true}
    assert result["mode"] == "stdio"
    refute text =~ "SYMPP-P3-001"
  end

  test "health tool rejects arguments outside its empty schema", %{repo: repo} do
    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{"unexpected" => "value"}}
        },
        repo: repo
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "invalid_tool_arguments"
  end

  test "health tool accepts omitted arguments for its empty schema", %{repo: repo} do
    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health"}
        },
        repo: repo
      )

    assert get_in(response, ["result", "structuredContent", "ledger", "reachable"]) == true
  end

  test "health tool hides raw ledger failure details" do
    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: FailingHealthRepo)
      )

    result = get_in(response, ["result", "structuredContent"])
    text = get_in(response, ["result", "content", Access.at(0), "text"])

    assert result["status"] == "degraded"
    assert result["ledger"] == %{"reachable" => false, "error" => "ledger_unavailable"}
    refute text =~ "C:/secret/path.sqlite"
    refute text =~ "RuntimeError"
  end

  test "resources do not expose package or assignment data without a session", %{repo: repo} do
    assert {:ok, _work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-001"))

    list_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "resources/list", "params" => %{}},
        repo: repo
      )

    assert get_in(list_response, ["result", "resources"]) == [
             %{
               "uri" => "sympp://health/version",
               "name" => "Symphony++ version",
               "mimeType" => "application/json"
             }
           ]

    assignment_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 3, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        repo: repo
      )

    assert get_in(assignment_response, ["error", "code"]) == -32_001
    assert get_in(assignment_response, ["error", "data", "reason"]) == "missing_session"

    package_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/SYMPP-P3-001/task_plan.md"}
        },
        repo: repo
      )

    assert get_in(package_response, ["error", "code"]) == -32_001
    assert get_in(package_response, ["error", "data", "reason"]) == "missing_session"
  end

  test "notifications produce no JSON-RPC response", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    assert nil == Server.handle(%{"jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => %{}}, server)
    assert nil == Server.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, server)
  end

  test "initialize cannot be sent as a notification", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    response = Server.handle(%{"jsonrpc" => "2.0", "method" => "initialize", "params" => initialize_params()}, server)

    assert response["id"] == nil
    assert get_in(response, ["error", "code"]) == -32_600
    assert get_in(response, ["error", "data", "reason"]) == "initialize_requires_id"
  end

  test "malformed method-only payloads are not suppressed as notifications", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    missing_jsonrpc = Server.handle(%{"id" => nil, "method" => "initialize", "params" => %{}}, server)
    missing_method = Server.handle(%{"jsonrpc" => "2.0", "id" => 12}, server)
    method_only = Server.handle(%{"method" => "initialize", "params" => %{}}, server)

    assert get_in(missing_jsonrpc, ["error", "code"]) == -32_600
    assert get_in(missing_jsonrpc, ["error", "data", "reason"]) == "invalid_jsonrpc_version"
    assert get_in(missing_method, ["error", "data", "reason"]) == "missing_method"
    assert get_in(method_only, ["error", "code"]) == -32_600
    assert get_in(method_only, ["error", "data", "reason"]) == "request_must_be_object"
  end

  test "JSON-RPC requests reject invalid versions before shape fallthrough", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    missing_method = Server.handle(%{"jsonrpc" => "1.0", "id" => 1}, server)
    missing_id = Server.handle(%{"jsonrpc" => "1.0", "method" => "initialize"}, server)

    assert missing_method["id"] == 1
    assert get_in(missing_method, ["error", "code"]) == -32_600
    assert get_in(missing_method, ["error", "data", "reason"]) == "invalid_jsonrpc_version"

    assert missing_id["id"] == nil
    assert get_in(missing_id, ["error", "code"]) == -32_600
    assert get_in(missing_id, ["error", "data", "reason"]) == "invalid_jsonrpc_version"
  end

  test "JSON-RPC requests reject non-scalar ids", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    Enum.each(
      [
        %{"jsonrpc" => "2.0", "id" => %{}, "method" => "initialize", "params" => %{}},
        %{"jsonrpc" => "2.0", "id" => []},
        %{"id" => %{}, "method" => "initialize", "params" => %{}}
      ],
      fn request ->
        response = Server.handle(request, server)

        assert response["id"] == nil
        assert get_in(response, ["error", "code"]) == -32_600
        assert get_in(response, ["error", "data", "reason"]) == "invalid_request_id"
      end
    )
  end

  test "JSON-RPC batches are handled consistently through direct server calls", %{repo: repo} do
    response =
      MCPHarness.request(
        [
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          %{"jsonrpc" => "2.0", "id" => "version", "method" => "resources/read", "params" => %{"uri" => "sympp://health/version"}}
        ],
        repo: repo
      )

    assert [%{"id" => "version", "result" => %{"contents" => [%{"text" => text}]}}] = response
    assert Jason.decode!(text)["mode"] == "stdio"
  end

  test "JSON-RPC batch elements reject nested arrays", %{repo: repo} do
    response =
      MCPHarness.request(
        [
          [
            %{"jsonrpc" => "2.0", "id" => "version", "method" => "resources/read", "params" => %{"uri" => "sympp://health/version"}}
          ]
        ],
        repo: repo
      )

    assert [%{"id" => nil, "error" => %{"code" => -32_600, "data" => %{"reason" => "request_must_be_object"}}}] = response
  end

  test "JSON-RPC batches reject initialize requests", %{repo: repo} do
    response =
      MCPHarness.request(
        [
          %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
          %{"jsonrpc" => "2.0", "id" => "version", "method" => "resources/read", "params" => %{"uri" => "sympp://health/version"}}
        ],
        repo: repo
      )

    assert response["id"] == nil
    assert get_in(response, ["error", "code"]) == -32_600
    assert get_in(response, ["error", "data", "reason"]) == "initialize_must_be_standalone"
  end

  test "JSON-RPC notification-only batches return no response", %{repo: repo} do
    response =
      MCPHarness.request(
        [
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          %{"jsonrpc" => "2.0", "method" => "notifications/cancelled"}
        ],
        repo: repo
      )

    assert response == nil
  end

  test "JSON-RPC request params reject unsupported scalar values", %{repo: repo} do
    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => "bad"},
        repo: repo
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "params_must_be_object_or_array"
  end

  test "object-only MCP methods reject positional params", %{repo: repo} do
    Enum.each(
      [
        {"init", "initialize"},
        {"tools", "tools/list"},
        {"tool", "tools/call"},
        {"resources", "resources/list"},
        {"resource", "resources/read"}
      ],
      fn {id, method} ->
        response =
          MCPHarness.request(
            %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => []},
            repo: repo
          )

        assert get_in(response, ["error", "code"]) == -32_602
        assert get_in(response, ["error", "data", "reason"]) == "params_must_be_object"
      end
    )
  end

  test "JSON-RPC requests reject non-string methods", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => 12, "method" => 123, "params" => %{}}, server)

    assert response["id"] == 12
    assert get_in(response, ["error", "code"]) == -32_600
    assert get_in(response, ["error", "data", "reason"]) == "invalid_method"
  end

  test "JSON-RPC requests without versions reject non-string methods", %{repo: repo} do
    response = MCPHarness.request(%{"id" => "method", "method" => 123}, repo: repo)

    assert get_in(response, ["error", "code"]) == -32_600
    assert get_in(response, ["error", "data", "reason"]) == "invalid_method"
  end

  test "stdio handler rejects empty batches", %{repo: repo} do
    response = Stdio.handle_payload([], Server.new(Config.default(repo: repo)))

    assert response["id"] == nil
    assert get_in(response, ["error", "code"]) == -32_600
    assert get_in(response, ["error", "data", "reason"]) == "empty_batch"
  end

  test "stdio handler ignores blank lines and accepts CRLF lines", %{repo: repo} do
    server = Server.new(Config.default(repo: repo), initialized: true)

    assert nil == Stdio.line_response("\r\n", server)
    assert nil == Stdio.line_response("\n", server)

    response =
      Stdio.line_response(
        ~s({"jsonrpc":"2.0","id":10,"method":"resources/read","params":{"uri":"sympp://health/version"}}\r\n),
        server
      )

    assert response["id"] == 10
    assert get_in(response, ["result", "contents", Access.at(0), "uri"]) == "sympp://health/version"
  end

  test "injected session exposes only current assignment and denies sibling package scope", %{repo: repo} do
    assert {:ok, own_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-001"))
    assert {:ok, _sibling_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-002"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, own_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    assignment_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 5, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        repo: repo,
        session: session
      )

    assignment_payload =
      assignment_response
      |> get_in(["result", "contents", Access.at(0), "text"])
      |> Jason.decode!()

    assert assignment_payload["work_package_id"] == "SYMPP-P3-001"
    assert assignment_payload["claimed_by"] == "worker-1"
    refute inspect(assignment_payload) =~ minted.work_key.secret

    own_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => 6,
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/SYMPP-P3-001/task_plan.md"}
        },
        repo: repo,
        session: session
      )

    own_text = get_in(own_response, ["result", "contents", Access.at(0), "text"])
    assert own_text =~ "Task Plan"
    assert own_text =~ "SYMPP-P3-001"

    sibling_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => 7,
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/SYMPP-P3-002/task_plan.md"}
        },
        repo: repo,
        session: session
      )

    assert get_in(sibling_response, ["error", "code"]) == -32_003
    assert get_in(sibling_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "claim_work_key binds the server session for worker lifecycle tools", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-002", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    server = Server.new(Config.default(repo: repo), initialized: true)

    missing_owner_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-missing-owner",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret}}
        },
        server
      )

    assert get_in(missing_owner_response, ["error", "data", "reason"]) == "missing_claimed_by"

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_work_key",
            "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}
          }
        },
        server
      )

    refute inspect(claim_response) =~ minted.work_key.secret
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-P3-002"

    {retry_claim_response, retry_claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-retry",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_work_key",
            "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}
          }
        },
        server
      )

    assert get_in(retry_claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-P3-002"
    assert retry_claimed_server.session.assignment.work_package_id == "SYMPP-P3-002"

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        claimed_server
      )

    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "claimed_by"]) == "worker-1"

    invalid_reason_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-status-reason",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"status" => "claimed", "expected_status" => "ready_for_worker", "reason" => 123}}
        },
        claimed_server
      )

    assert get_in(invalid_reason_response, ["error", "data", "reason"]) == "invalid_reason"
    assert {:ok, unchanged_package} = WorkPackageRepository.get(repo, package.id)
    assert unchanged_package.status == "ready_for_worker"

    status_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "status",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"status" => "claimed", "expected_status" => "ready_for_worker", "reason" => "Starting work"}}
        },
        claimed_server
      )

    assert get_in(status_response, ["result", "structuredContent", "work_package", "status"]) == "claimed"
    assert {:ok, status_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.any?(status_events, &(&1.body == "Starting work" and &1.payload["type"] == "status_transition"))

    stale_status_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-status",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"status" => "implementing", "expected_status" => "ready_for_worker"}}
        },
        claimed_server
      )

    assert get_in(stale_status_response, ["error", "data", "reason"]) == "stale_status"
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
    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-STATELESS-HANDLE"
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
    assert get_in(assignment_response, ["error", "data", "reason"]) == "missing_session"
  end

  test "response-only handle does not retain unchanged one-shot server state", %{repo: repo} do
    server = Server.new(Config.default(repo: repo), initialized: true)
    Process.delete({Server, server.state_key})

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}}, server)

    assert is_list(get_in(response, ["result", "tools"]))
    assert Process.get({Server, server.state_key}) == nil
  end

  test "claim_work_key notification binds session inside a batch", %{repo: repo} do
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
    assert get_in(List.first(responses), ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-NOTIFY-CLAIM"
    assert server.session.assignment.work_package_id == "SYMPP-NOTIFY-CLAIM"
  end

  test "worker tool notifications execute without JSON-RPC responses", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-NOTIFY-WRITE", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {responses, server} =
      Server.handle_state(
        [
          %{
            "jsonrpc" => "2.0",
            "method" => "tools/call",
            "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
          },
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
        Server.new(Config.default(repo: repo), initialized: true)
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

  test "claim_work_key rejects non-worker grants and revalidates bound replays", %{repo: repo} do
    assert {:ok, worker_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WORKER-CLAIM", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, architect_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-CLAIM", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, worker_minted} = AccessGrantService.mint_worker_grant(repo, worker_package.id)
    assert {:ok, architect_work_key} = create_architect_work_key(repo, architect_package.id)

    architect_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "architect-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => architect_work_key.secret, "claimed_by" => "architect-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(architect_response, ["error", "data", "reason"]) == "worker_grant_required"
    assert {:ok, architect_assignment} = AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))
    assert architect_assignment.grant_role == "architect"

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

    assert get_in(response, ["error", "data", "reason"]) == "worker_grant_required"

    assignment_tool_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "architect-assignment-tool", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        repo: repo,
        session: session
      )

    assert get_in(assignment_tool_response, ["error", "data", "reason"]) == "worker_grant_required"

    read_tool_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "architect-read-tool", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        repo: repo,
        session: session
      )

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

    assert get_in(resource_response, ["error", "data", "reason"]) == "worker_grant_required"

    assignment_resource_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "architect-assignment-resource", "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        repo: repo,
        session: session
      )

    assert get_in(assignment_resource_response, ["error", "data", "reason"]) == "worker_grant_required"
  end

  test "batch calls thread claim_work_key session to later worker tools", %{repo: repo} do
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
    assert get_in(Enum.at(responses, 1), ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-BATCH-CLAIM"
    assert server.session.assignment.work_package_id == "SYMPP-BATCH-CLAIM"
  end

  test "worker tools update only the scoped planning state and deny sibling mutations", %{repo: repo} do
    assert {:ok, own_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WORKER-OWN", kind: "adapter"))
    assert {:ok, sibling_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WORKER-SIBLING", kind: "adapter"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, own_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    read_plan_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "read-plan", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        repo: repo,
        session: session
      )

    plan_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{
              "expected_version" => get_in(read_plan_response, ["result", "structuredContent", "version"]),
              "title" => "Implement MCP worker tools",
              "status" => "done"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(plan_response, ["result", "structuredContent", "plan_nodes", Access.at(0), "status"]) == "done"

    finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Scoped", "body" => "Own package only", "idempotency_key" => "finding-scoped"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(finding_response, ["result", "structuredContent", "finding", "title"]) == "Scoped"

    explicit_finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding-explicit-id",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"id" => "custom-finding-id", "title" => "Explicit", "body" => "Caller supplied id", "idempotency_key" => "finding-explicit"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(explicit_finding_response, ["result", "structuredContent", "finding", "id"]) == "custom-finding-id"

    explicit_finding_replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding-explicit-id-replay",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"id" => "custom-finding-id-retry", "title" => "Explicit", "body" => "Caller supplied id", "idempotency_key" => "finding-explicit"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(explicit_finding_replay_response, ["error", "data", "reason"]) == "idempotency_conflict"

    matching_explicit_finding_replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding-explicit-id-matching-replay",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"id" => "custom-finding-id", "title" => "Explicit", "body" => "Caller supplied id", "idempotency_key" => "finding-explicit"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(matching_explicit_finding_replay_response, ["result", "structuredContent", "finding", "id"]) == "custom-finding-id"

    explicit_finding_id_conflict_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding-explicit-id-conflict",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"id" => "custom-finding-id", "title" => "Explicit", "body" => "Caller supplied id", "idempotency_key" => "finding-other"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(explicit_finding_id_conflict_response, ["error", "data", "reason"]) == "idempotency_conflict"

    finding_replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding-replay",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Scoped", "body" => "Own package only", "idempotency_key" => "finding-scoped"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(finding_replay_response, ["result", "structuredContent", "finding", "id"]) ==
             get_in(finding_response, ["result", "structuredContent", "finding", "id"])

    whitespace_finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding-whitespace",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Whitespace", "body" => "Trim idempotency", "idempotency_key" => " finding-space "}
          }
        },
        repo: repo,
        session: session
      )

    whitespace_replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding-whitespace-replay",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Whitespace", "body" => "Trim idempotency", "idempotency_key" => "finding-space"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(whitespace_replay_response, ["result", "structuredContent", "finding", "id"]) ==
             get_in(whitespace_finding_response, ["result", "structuredContent", "finding", "id"])

    assert {:ok, second_minted} = AccessGrantService.mint_worker_grant(repo, own_package.id)
    assert {:ok, second_assignment} = AccessGrantService.claim(repo, second_minted.work_key.secret, claimed_by: "worker-2")
    second_session = MCPHarness.session(second_assignment, proof_hash: second_minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-WORKER-OWN/worker"})
    attach_tool(repo, second_session, "attach_branch", %{"branch" => "agent/SYMPP-WORKER-OWN/worker"})

    finding_regrant_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding-regrant",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Scoped", "body" => "Own package only", "idempotency_key" => "finding-scoped"}
          }
        },
        repo: repo,
        session: second_session
      )

    refute get_in(finding_regrant_response, ["result", "structuredContent", "finding", "id"]) ==
             get_in(finding_response, ["result", "structuredContent", "finding", "id"])

    conflicting_finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding-conflict",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Scoped", "body" => "Different body", "idempotency_key" => "finding-scoped"}
          }
        },
        repo: repo,
        session: second_session
      )

    assert get_in(conflicting_finding_response, ["error", "data", "reason"]) == "idempotency_conflict"

    progress_args = %{"summary" => "Progress", "idempotency_key" => "worker-progress-1", "body" => "Done"}

    progress_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "progress", "method" => "tools/call", "params" => %{"name" => "append_progress", "arguments" => progress_args}},
        repo: repo,
        session: session
      )

    replay_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "progress-replay", "method" => "tools/call", "params" => %{"name" => "append_progress", "arguments" => progress_args}},
        repo: repo,
        session: session
      )

    assert get_in(progress_response, ["result", "structuredContent", "progress_event", "id"]) ==
             get_in(replay_response, ["result", "structuredContent", "progress_event", "id"])

    whitespace_progress_replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "progress-whitespace-replay",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{progress_args | "idempotency_key" => " worker-progress-1 "}}
        },
        repo: repo,
        session: session
      )

    assert get_in(whitespace_progress_replay_response, ["result", "structuredContent", "progress_event", "id"]) ==
             get_in(progress_response, ["result", "structuredContent", "progress_event", "id"])

    redacted_progress_args = %{
      "summary" => "Redacted progress",
      "idempotency_key" => "worker-progress-redacted",
      "payload" => %{"token" => "sk-secret"}
    }

    redacted_progress_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "progress-redacted",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => redacted_progress_args}
        },
        repo: repo,
        session: session
      )

    assert get_in(redacted_progress_response, ["result", "structuredContent", "progress_event", "payload", "token"]) == "[REDACTED]"

    redacted_replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "progress-redacted-replay",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => redacted_progress_args}
        },
        repo: repo,
        session: session
      )

    assert get_in(redacted_replay_response, ["result", "structuredContent", "progress_event", "id"]) ==
             get_in(redacted_progress_response, ["result", "structuredContent", "progress_event", "id"])

    conflicting_progress_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "progress-conflict",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => Map.put(progress_args, "summary", "Different progress")}
        },
        repo: repo,
        session: session
      )

    assert get_in(conflicting_progress_response, ["error", "data", "reason"]) == "idempotency_conflict"

    scope_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "scope",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_scope_expansion",
            "arguments" => %{
              "summary" => "Need broader files",
              "idempotency_key" => "scope-request-1",
              "payload" => %{"requested_file_globs" => ["lib/other/**"]}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(scope_response, ["result", "structuredContent", "progress_event", "status"]) == "recorded"

    denied_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "denied",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"work_package_id" => sibling_package.id, "title" => "Mutate sibling"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(denied_response, ["error", "code"]) == -32_003

    assert {:ok, own_nodes} = PlanningRepository.list_plan_nodes(repo, own_package.id)
    assert {:ok, sibling_nodes} = PlanningRepository.list_plan_nodes(repo, sibling_package.id)
    assert {:ok, events} = PlanningRepository.list_progress_events(repo, own_package.id)
    assert length(own_nodes) == 1
    assert sibling_nodes == []
    assert Enum.any?(events, &(get_in(&1.payload, ["type"]) == "scope_expansion_request" and get_in(&1.payload, ["approved"]) == false))
  end

  test "update_task_plan patches existing nodes with expected version", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PLAN-PATCH", kind: "mcp"))
    assert {:ok, plan_node} = PlanningRepository.append_plan_node(repo, %{"work_package_id" => package.id, "title" => "Original", "status" => "pending"})
    assert {:ok, second_node} = PlanningRepository.append_plan_node(repo, %{"work_package_id" => package.id, "title" => "Second", "status" => "pending"})
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    read_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "read-plan", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        repo: repo,
        session: session
      )

    version = get_in(read_response, ["result", "structuredContent", "version"])

    invalid_patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{
              "expected_version" => version,
              "patch" => %{"nodes" => [%{"id" => plan_node.id, "status" => "done"}, %{"id" => second_node.id, "status" => "invalid"}]}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_patch_response, ["error", "code"]) == -32_602
    assert {:ok, unchanged_nodes} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert Enum.find(unchanged_nodes, &(&1.id == plan_node.id)).status == "pending"

    malformed_patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "malformed-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => ["bad"]}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(malformed_patch_response, ["error", "data", "reason"]) == "invalid_patch_node"

    malformed_patch_shape_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "malformed-patch-shape-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => "bad", "title" => "Do not append"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(malformed_patch_shape_response, ["error", "data", "reason"]) == "invalid_patch"
    assert {:ok, unchanged_after_bad_patch} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert length(unchanged_after_bad_patch) == 2

    malformed_id_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "malformed-id-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => [%{"id" => 123, "title" => "Duplicate"}]}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(malformed_id_response, ["error", "data", "reason"]) == "invalid_patch_node"
    assert {:ok, unchanged_after_bad_id} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert length(unchanged_after_bad_id) == 2

    no_op_patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "no-op-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => [%{"id" => plan_node.id}]}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(no_op_patch_response, ["error", "data", "reason"]) == "invalid_patch_node"

    patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => [%{"id" => plan_node.id, "status" => "done", "body" => "Complete"}]}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(patch_response, ["result", "structuredContent", "plan_nodes", Access.at(0), "status"]) == "done"
    assert {:ok, nodes} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert length(nodes) == 2
    assert Enum.find(nodes, &(&1.id == plan_node.id)).body == "Complete"

    stale_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => [%{"id" => plan_node.id, "status" => "pending"}]}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_response, ["error", "data", "reason"]) == "stale_plan_version"
  end

  test "mark_ready enforces worker readiness gates", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-GATES", kind: "mcp", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(missing_response, ["error", "data", "reason"]) == "readiness_failed"
    assert "pr_attached" in get_in(missing_response, ["error", "data", "missing"])

    bypass_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "ready-bypass",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"status" => "ready_for_human_merge", "expected_status" => "ci_waiting"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(bypass_response, ["error", "data", "reason"]) == "use_mark_ready"
    assert {:ok, unchanged_package} = WorkPackageRepository.get(repo, package.id)
    assert unchanged_package.status == "ci_waiting"

    attach_tool(repo, session, "append_progress", %{"summary" => "Shared key baseline", "idempotency_key" => "shared-metadata-key"})

    missing_head_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "missing-pr-head",
          "method" => "tools/call",
          "params" => %{"name" => "attach_pr", "arguments" => %{"url" => "https://github.com/example/repo/pull/123"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_head_response, ["error", "data", "reason"]) == "missing_head_sha"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-GATES/worker", "idempotency_key" => "shared-metadata-key"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/123", "head_sha" => "abc123"})

    headless_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "headless-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Headless review",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(headless_review_response, ["result", "structuredContent", "progress_event", "payload", "head_sha"]) == "abc123"
    assert get_in(headless_review_response, ["result", "structuredContent", "progress_event", "payload", "reviews"]) == []

    missing_acceptance_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-acceptance", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "acceptance_criteria_met" in get_in(missing_acceptance_response, ["error", "data", "missing"])

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test", "review_t1 green", "review_t2 green"],
      "artifacts" => ["review-t1-log.txt"],
      "head_sha" => "abc123",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}]
    })

    repo.delete_all(Artifact)

    missing_review_lanes_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-review-lanes", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(missing_review_lanes_response, ["error", "data", "missing"])

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready after T2",
      "tests" => ["mix test", "review_t2 green"],
      "artifacts" => ["review-t2-log.txt"],
      "head_sha" => "abc123",
      "reviews" => [%{"lane" => "review_t2", "verdict" => "green"}]
    })

    incremental_review_lanes_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-incremental-review-lanes", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    incremental_missing = get_in(incremental_review_lanes_response, ["error", "data", "missing"])
    refute "review_lanes_complete" in incremental_missing
    refute "acceptance_criteria_met" in incremental_missing
    assert "review_artifacts_attached" in incremental_missing
    assert "plan_complete" in incremental_missing

    malformed_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "malformed-review-entries",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Malformed review",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [%{"lane" => 1, "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => nil}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(malformed_review_response, ["error", "data", "reason"]) == "invalid_reviews"

    missing_artifacts_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "ready-missing-artifacts",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Ready without artifacts",
              "tests" => ["mix test"],
              "artifacts" => [],
              "head_sha" => "abc123",
              "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_artifacts_response, ["error", "data", "reason"]) == "missing_artifacts"

    blank_artifact_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "blank-artifact",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Blank artifact",
              "tests" => ["mix test"],
              "artifacts" => [" "],
              "head_sha" => "abc123",
              "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(blank_artifact_response, ["error", "data", "reason"]) == "invalid_artifacts"

    malformed_reviews_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "malformed-reviews",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Malformed reviews",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => %{"lane" => "review_t1", "verdict" => "green"}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(malformed_reviews_response, ["error", "data", "reason"]) == "invalid_reviews"

    invalid_acceptance_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-acceptance",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Invalid acceptance",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => "true",
              "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_acceptance_response, ["error", "data", "reason"]) == "invalid_acceptance_criteria_met"

    invalid_tests_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-tests",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Invalid tests",
              "tests" => [" "],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_tests_response, ["error", "data", "reason"]) == "invalid_tests"

    invalid_head_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-head-sha",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Invalid head",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => 123,
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_head_response, ["error", "data", "reason"]) == "invalid_head_sha"

    sibling_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sibling-review-package",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "work_package_id" => "SYMPP-OTHER",
              "summary" => "Wrong package",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(sibling_review_response, ["error", "data", "reason"]) == "outside_session_scope"

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc123",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    handoff_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "handoff-with-review-artifact",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/SYMPP-READY-GATES/handoff.md"}
        },
        repo: repo,
        session: session
      )

    assert get_in(handoff_response, ["result", "contents", Access.at(0), "text"]) =~ "review-log.txt"

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Latest review has findings",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc123",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}]
    })

    latest_missing_lane_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-latest-missing-lane", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    latest_missing_lane_missing = get_in(latest_missing_lane_response, ["error", "data", "missing"])
    refute "review_lanes_complete" in latest_missing_lane_missing
    assert "plan_complete" in latest_missing_lane_missing

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Latest review has findings",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc123",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "findings"}]
    })

    latest_findings_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-latest-findings", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(latest_findings_response, ["error", "data", "missing"])

    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/123", "head_sha" => "def456"})

    stale_submit_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-review-submit",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Stale review",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_submit_response, ["error", "data", "reason"]) == "stale_head_sha"

    stale_review_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-stale-review", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(stale_review_response, ["error", "data", "missing"])

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "def456",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => " review_t1 ", "verdict" => " green "}, %{"lane" => " review_t2 ", "verdict" => " green "}]
    })

    empty_plan_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-empty-plan", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "plan_complete" in get_in(empty_plan_response, ["error", "data", "missing"])
    append_done_plan(repo, package.id)

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_human_merge"
  end

  test "review package submitted before PR attach remains readiness evidence", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PRE-PR-REVIEW", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PRE-PR-REVIEW/worker"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Pre-PR review",
      "tests" => ["mix test"],
      "artifacts" => ["pre-pr-review.txt"],
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/456", "head_sha" => "later-head"})

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-pr-attach", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "mark_ready rejects empty review packages and allows resolved blockers", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-BLOCKER", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    empty_review_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "empty-review", "method" => "tools/call", "params" => %{"name" => "submit_review_package", "arguments" => %{}}},
        repo: repo,
        session: session
      )

    assert get_in(empty_review_response, ["error", "data", "reason"]) == "missing_summary"

    invalid_blocker_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "report_blocker",
            "arguments" => %{"summary" => "Invalid blocker", "idempotency_key" => "invalid-blocker", "blocker_id" => 1}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_blocker_response, ["error", "data", "reason"]) == "invalid_blocker_id"

    attach_tool(repo, session, "append_progress", %{"summary" => "Progress with shared retry key", "idempotency_key" => "blocker-1"})

    blocker_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "report_blocker",
            "arguments" => %{"summary" => "Temporarily blocked", "idempotency_key" => "blocker-1", "blocker_id" => "blocker-1 "}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(blocker_response, ["result", "structuredContent", "progress_event", "payload", "active"]) == true
    assert get_in(blocker_response, ["result", "structuredContent", "progress_event", "payload", "blocker_id"]) == "blocker-1"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-BLOCKER/worker"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/125", "head_sha" => "abc125"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc125",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    blocked_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-blocked", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "no_active_blockers" in get_in(blocked_response, ["error", "data", "missing"])

    resolved_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "resolve",
          "method" => "tools/call",
          "params" => %{
            "name" => "resolve_blocker",
            "arguments" => %{"blocker_id" => "blocker-1", "resolution" => "Unblocked", "summary" => "Resolved", "idempotency_key" => "resolve-1"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(resolved_response, ["result", "structuredContent", "progress_event", "payload", "active"]) == false

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-resolved", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "mark_ready does not require review-package metadata for non-merge-gated policies", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-QUICK-FIX", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(response, ["error", "data", "missing"])
    assert get_in(response, ["error", "data", "reason"]) == "readiness_failed"
    refute "review_package_submitted" in missing
  end

  test "investigation readiness does not require branch or review package", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-READY", kind: "investigation", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Recommendation", "body" => "No code change needed.", "idempotency_key" => "investigation-finding"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(finding_response, ["result", "structuredContent", "finding", "title"]) == "Recommendation"

    missing_recommendation_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-recommendation", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_recorded" in get_in(missing_recommendation_response, ["error", "data", "missing"])

    attach_tool(repo, session, "append_progress", %{
      "summary" => "No scope expansion needed",
      "body" => "Recommendation recorded for the investigation package.",
      "idempotency_key" => "investigation-recommendation",
      "payload" => %{"type" => "recommendation", "recommendation" => "no_scope_expansion_needed"}
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "mark_ready rejects spoofed metadata and accepts skipped plan nodes", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-SPOOF", kind: "mcp", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    assert {:ok, _skipped} =
             PlanningRepository.append_plan_node(repo, %{
               "work_package_id" => package.id,
               "title" => "Skipped with rationale",
               "body" => "No longer needed",
               "status" => "skipped"
             })

    Enum.each(["branch", "pr", "review_package"], fn type ->
      response =
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "spoof-#{type}",
            "method" => "tools/call",
            "params" => %{
              "name" => "append_progress",
              "arguments" => %{
                "summary" => "Spoof #{type}",
                "idempotency_key" => "spoof-#{type}",
                "payload" => %{"type" => type, "source_tool" => "attach_#{type}"}
              }
            }
          },
          repo: repo,
          session: session
        )

      assert get_in(response, ["result", "structuredContent", "progress_event", "id"])
    end)

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["error", "data", "reason"]) == "readiness_failed"

    assert get_in(ready_response, ["error", "data", "missing"]) == [
             "acceptance_criteria_met",
             "tests_passed",
             "branch_attached",
             "pr_attached",
             "review_package_submitted",
             "review_artifacts_attached",
             "review_lanes_complete"
           ]
  end

  test "worker metadata tools preserve protected fields and reject non-map payloads", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PAYLOAD", kind: "mcp"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    blocker_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "report_blocker",
            "arguments" => %{
              "summary" => "Blocked",
              "idempotency_key" => "blocker-protected",
              "payload" => %{"type" => "pr", "active" => false, "source_tool" => "attach_pr"}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert event_id = get_in(blocker_response, ["result", "structuredContent", "progress_event", "id"])
    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)
    event = Enum.find(events, &(&1.id == event_id))
    assert event.payload["type"] == "blocker"
    assert event.payload["source_tool"] == "report_blocker"
    assert event.payload["active"] == true

    invalid_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "bad-payload",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_progress",
            "arguments" => %{"summary" => "Bad", "idempotency_key" => "bad-payload", "payload" => false}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_response, ["error", "code"]) == -32_602
    assert get_in(invalid_response, ["error", "data", "reason"]) == "invalid_payload"
  end

  test "mark_ready uses lifecycle capability checks", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-CAP", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id, capabilities: ["worker:claim"])
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-CAP/worker"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/124", "head_sha" => "abc124"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc124",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "data", "reason"]) == "missing_lifecycle_capability"
  end

  test "worker cannot mark merged mint grants or list all packages through MCP", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-DENIALS", kind: "adapter", status: "ready_for_human_merge"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    merged_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "merged",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"status" => "merged", "expected_status" => "ready_for_human_merge"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(merged_response, ["error", "data", "reason"]) == "worker_cannot_mark_merged"

    Enum.each(["mint_worker_grant", "list_work_packages"], fn tool ->
      response =
        MCPHarness.request(
          %{"jsonrpc" => "2.0", "id" => tool, "method" => "tools/call", "params" => %{"name" => tool, "arguments" => %{}}},
          repo: repo,
          session: session
        )

      assert get_in(response, ["error", "code"]) == -32_601
    end)
  end

  test "protected resources revalidate injected sessions against live grants", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-001"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 8, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        repo: repo,
        session: MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
      )

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "revoked"

    list_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 9, "method" => "resources/list", "params" => %{}},
        repo: repo,
        session: MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
      )

    resource_uris = list_response |> get_in(["result", "resources"]) |> Enum.map(& &1["uri"])
    refute "sympp://assignment/current" in resource_uris

    progress_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "revoked-progress",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_progress",
            "arguments" => %{"summary" => "Should not write", "idempotency_key" => "revoked-progress"}
          }
        },
        repo: repo,
        session: MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
      )

    assert get_in(progress_response, ["error", "data", "reason"]) == "revoked"

    assert {:ok, status_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REVOKED-STATUS", kind: "mcp", status: "planning"))

    assert {:ok, status_minted} = AccessGrantService.mint_worker_grant(repo, status_package.id)
    assert {:ok, status_assignment} = AccessGrantService.claim(repo, status_minted.work_key.secret, claimed_by: "worker-1")
    assert {:ok, _revoked_status} = AccessGrantService.revoke(repo, status_minted.grant.id)

    status_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "revoked-status",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"status" => "blocked", "expected_status" => "planning"}}
        },
        repo: repo,
        session: MCPHarness.session(status_assignment, proof_hash: status_minted.grant.secret_hash)
      )

    assert get_in(status_response, ["error", "data", "reason"]) == "revoked"

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "revoked-ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: MCPHarness.session(status_assignment, proof_hash: status_minted.grant.secret_hash)
      )

    assert get_in(ready_response, ["error", "data", "reason"]) == "revoked"
  end

  test "protected resources require injected session proof of possession", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P3-001"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 8, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        repo: repo,
        session: MCPHarness.session(assignment)
      )

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "missing_session_proof"

    list_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 9, "method" => "resources/list", "params" => %{}},
        repo: repo,
        session: MCPHarness.session(assignment)
      )

    resource_uris = list_response |> get_in(["result", "resources"]) |> Enum.map(& &1["uri"])
    refute "sympp://assignment/current" in resource_uris
  end

  test "protected resource reads surface structured ledger failures" do
    session =
      Session.new(%Assignment{
        grant_id: "grant-1",
        work_package_id: "SYMPP-P3-001",
        display_key: "ABCD",
        grant_role: "worker",
        capabilities: [],
        claimed_at: DateTime.utc_now(:microsecond),
        claimed_by: "worker-1"
      })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 10, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        config: Config.default(repo: FailingAuthRepo),
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_000
    assert get_in(response, ["error", "data", "reason"]) == "ledger_unavailable"
    refute Map.has_key?(get_in(response, ["error", "data"]), "detail")
  end

  test "malformed injected sessions fail closed without protected resources", %{repo: repo} do
    read_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 10, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        repo: repo,
        session: %{"grant_id" => "grant-1"}
      )

    assert get_in(read_response, ["error", "code"]) == -32_001
    assert get_in(read_response, ["error", "data", "reason"]) == "invalid_session"

    list_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 11, "method" => "resources/list", "params" => %{}},
        repo: repo,
        session: %{"grant_id" => "grant-1"}
      )

    resource_uris = list_response |> get_in(["result", "resources"]) |> Enum.map(& &1["uri"])
    refute "sympp://assignment/current" in resource_uris
  end

  test "protected resources surface unexpected grant lookup results as ledger failures" do
    session =
      Session.new(%Assignment{
        grant_id: "grant-1",
        work_package_id: "SYMPP-P3-001",
        display_key: "ABCD",
        grant_role: "worker",
        capabilities: [],
        claimed_at: DateTime.utc_now(:microsecond),
        claimed_by: "worker-1"
      })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 10, "method" => "resources/read", "params" => %{"uri" => "sympp://assignment/current"}},
        config: Config.default(repo: UnexpectedAuthRepo),
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_000
    assert get_in(response, ["error", "data", "reason"]) == "ledger_unavailable"
    refute Map.has_key?(get_in(response, ["error", "data"]), "detail")
  end

  test "resource listing surfaces ledger failures for injected sessions" do
    session =
      Session.new(%Assignment{
        grant_id: "grant-1",
        work_package_id: "SYMPP-P3-001",
        display_key: "ABCD",
        grant_role: "worker",
        capabilities: [],
        claimed_at: DateTime.utc_now(:microsecond),
        claimed_by: "worker-1"
      })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => 11, "method" => "resources/list", "params" => %{}},
        config: Config.default(repo: FailingAuthRepo),
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_000
    assert get_in(response, ["error", "data", "reason"]) == "ledger_unavailable"
    refute Map.has_key?(get_in(response, ["error", "data"]), "detail")
  end

  test "malformed work package resource URIs fail before auth", %{repo: repo} do
    Enum.each(
      [
        "sympp://work-packages/",
        "sympp://work-packages//task_plan.md",
        "sympp://work-packages/SYMPP-P3-001/",
        "sympp://work-packages/SYMPP-P3-001//task_plan.md",
        "sympp://work-packages/SYMPP-P3-001/path/to/file.md"
      ],
      fn uri ->
        response =
          MCPHarness.request(
            %{"jsonrpc" => "2.0", "id" => uri, "method" => "resources/read", "params" => %{"uri" => uri}},
            repo: repo
          )

        assert get_in(response, ["error", "code"]) == -32_602
        assert get_in(response, ["error", "data", "reason"]) == "invalid_work_package_resource_uri"
      end
    )
  end

  test "invalid health arguments do not log bearer tokens or grant secrets", %{repo: repo} do
    secret = "wk_secret_that_must_not_be_logged"

    log =
      capture_log(fn ->
        response =
          MCPHarness.request(
            %{
              "jsonrpc" => "2.0",
              "id" => "health",
              "method" => "tools/call",
              "params" => %{"name" => "sympp.health", "arguments" => %{"bearer" => "Bearer #{secret}"}}
            },
            repo: repo
          )

        assert get_in(response, ["error", "data", "reason"]) == "invalid_tool_arguments"
      end)

    refute log =~ secret
    refute log =~ "Bearer"
  end

  defp main_database_row_matches?([_seq, "main", path], database_path) do
    Repo.same_database_path?(path, database_path)
  end

  defp main_database_row_matches?(_row, _database_path), do: false

  defp initialize_params do
    %{
      "protocolVersion" => "2025-03-26",
      "clientInfo" => %{"name" => "sympp-test-client", "version" => "0.1.0"},
      "capabilities" => %{}
    }
  end

  defp attach_tool(repo, session, name, arguments) do
    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => name, "method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}},
        repo: repo,
        session: session
      )

    assert get_in(response, ["result", "structuredContent", "progress_event", "id"])
    response
  end

  defp append_done_plan(repo, work_package_id) do
    assert {:ok, _plan_node} =
             PlanningRepository.append_plan_node(repo, %{
               "work_package_id" => work_package_id,
               "title" => "Complete implementation",
               "status" => "done"
             })
  end

  defp create_architect_work_key(repo, work_package_id) do
    now = DateTime.utc_now(:microsecond)
    work_key = WorkKey.generate()

    with {:ok, _grant} <-
           AccessGrantRepository.create(repo, %{
             work_package_id: work_package_id,
             display_key: work_key.display_key,
             secret_hash: WorkKey.secret_hash(work_key.secret),
             grant_role: "architect",
             capabilities: ["architect:lifecycle.transition"],
             expires_at: DateTime.add(now, 86_400, :second)
           }) do
      {:ok, work_key}
    end
  end

  defp decode_json_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
