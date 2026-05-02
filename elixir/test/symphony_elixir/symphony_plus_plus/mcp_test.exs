Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import ExUnit.CaptureIO

  alias Mix.Tasks.Sympp.Mcp, as: McpTask
  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Server, Session, Stdio}
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

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        claimed_server
      )

    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "claimed_by"]) == "worker-1"

    status_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "status",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"status" => "claimed"}}
        },
        claimed_server
      )

    assert get_in(status_response, ["result", "structuredContent", "work_package", "status"]) == "claimed"
  end

  test "worker tools update only the scoped planning state and deny sibling mutations", %{repo: repo} do
    assert {:ok, own_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WORKER-OWN", kind: "adapter"))
    assert {:ok, sibling_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WORKER-SIBLING", kind: "adapter"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, own_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    plan_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "plan",
          "method" => "tools/call",
          "params" => %{"name" => "update_task_plan", "arguments" => %{"title" => "Implement MCP worker tools", "status" => "done"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(plan_response, ["result", "structuredContent", "plan_node", "status"]) == "done"

    finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "finding",
          "method" => "tools/call",
          "params" => %{"name" => "append_finding", "arguments" => %{"title" => "Scoped", "body" => "Own package only"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(finding_response, ["result", "structuredContent", "finding", "title"]) == "Scoped"

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

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-GATES/worker"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/123", "head_sha" => "abc123"})
    attach_tool(repo, session, "submit_review_package", %{"summary" => "Ready", "tests" => ["mix test"], "artifacts" => []})

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_human_merge"
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
    assert get_in(ready_response, ["error", "data", "missing"]) == ["branch_attached", "pr_attached", "review_package_submitted"]
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
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id, capabilities: ["worker:claim"])
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-CAP/worker"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/124", "head_sha" => "abc124"})
    attach_tool(repo, session, "submit_review_package", %{"summary" => "Ready", "tests" => ["mix test"], "artifacts" => []})

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
          "params" => %{"name" => "set_status", "arguments" => %{"status" => "merged"}}
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

  defp decode_json_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
