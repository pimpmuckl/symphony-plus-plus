Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import ExUnit.CaptureIO

  alias Ecto.Adapters.SQL
  alias Mix.Tasks.Sympp.Mcp, as: McpTask
  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Auth, Config, Server, Session, Stdio}
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

  defmodule BusyPrSyncRepo do
    def get(AccessGrant, "grant-pr-sync-service") do
      %AccessGrant{
        id: "grant-pr-sync-service",
        work_package_id: "SYMPP-PR-SERVICE-ERROR",
        display_key: "ABCD",
        grant_role: "worker",
        capabilities: ["read:own", "write:own"],
        claimed_at: ~U[2026-05-05 00:00:00Z],
        claimed_by: "worker-1",
        expires_at: ~U[2030-01-01 00:00:00Z],
        secret_hash: "proof"
      }
    end

    def get(WorkPackage, "SYMPP-PR-SERVICE-ERROR") do
      %WorkPackage{
        id: "SYMPP-PR-SERVICE-ERROR",
        kind: "standard_pr",
        repo: "nextide/symphony-plus-plus",
        status: "ci_waiting"
      }
    end

    def one(_query), do: raise(%Exqlite.Error{message: "database is locked"})
    def all(_query), do: raise(%Exqlite.Error{message: "database is locked"})
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    reset_handle_state_store()
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "session parsing reports malformed assignment fields" do
    attrs = %{
      "grant_id" => "grant-1",
      "work_package_id" => "SYMPP-SESSION",
      "display_key" => "ABCD",
      "grant_role" => "worker",
      "capabilities" => ["read:own"],
      "claimed_by" => "worker-1",
      "claimed_at" => "2026-05-04T12:00:00Z",
      "proof_hash" => "proof"
    }

    assert {:ok, session} = Session.from_map(attrs)
    assert session.proof_hash == "proof"
    assert session.assignment.claimed_at == ~U[2026-05-04 12:00:00Z]

    assert {:ok, nil_session} = Session.from_map(%{attrs | "claimed_at" => nil})
    assert nil_session.assignment.claimed_at == nil

    assert Session.from_map(%{attrs | "grant_id" => " "}) == {:error, {:blank, "grant_id"}}
    assert Session.from_map(Map.delete(attrs, "work_package_id")) == {:error, {:missing, "work_package_id"}}
    assert Session.from_map(%{attrs | "capabilities" => ["read:own", :bad]}) == {:error, {:invalid, "capabilities"}}
    assert Session.from_map(%{attrs | "capabilities" => "read:own"}) == {:error, {:missing, "capabilities"}}
    assert Session.from_map(%{attrs | "claimed_at" => "not-a-date"}) == {:error, {:invalid, "claimed_at", :invalid_format}}
    assert Session.from_map(%{attrs | "claimed_at" => 123}) == {:error, {:invalid, "claimed_at"}}
  end

  test "session grant validation rejects inactive or unclaimed grants" do
    now = ~U[2026-05-04 12:00:00Z]

    grant = %AccessGrant{
      id: "grant-1",
      work_package_id: "SYMPP-SESSION-GRANT",
      display_key: "ABCD",
      grant_role: "worker",
      capabilities: ["read:own"],
      expires_at: DateTime.add(now, 60, :second),
      claimed_at: now,
      claimed_by: "worker-1"
    }

    assert {:ok, session} = Session.from_grant(grant, now, proof_hash: "proof")
    assert session.assignment.work_package_id == "SYMPP-SESSION-GRANT"

    assert Session.from_grant(%{grant | revoked_at: now}, now) == {:error, :revoked}
    assert Session.from_grant(%{grant | expires_at: now}, now) == {:error, :expired}
    assert Session.from_grant(%{grant | expires_at: nil}, now) == {:error, :missing_expiry}
    assert Session.from_grant(%{grant | claimed_at: nil}, now) == {:error, :unclaimed}
    assert Session.from_grant(%{grant | claimed_by: " "}, now) == {:error, :missing_claim_identity}
  end

  test "auth helpers reject missing invalid and mismatched sessions" do
    session =
      Session.new(%Assignment{
        grant_id: "grant-1",
        work_package_id: "SYMPP-AUTH",
        display_key: "ABCD",
        grant_role: "worker",
        capabilities: [],
        claimed_at: ~U[2026-05-04 12:00:00Z],
        claimed_by: "worker-1"
      })

    assert Auth.require_session(session) == {:ok, session}
    assert Auth.require_session(nil) == {:error, :unauthorized}
    assert Auth.require_session(:bad) == {:error, {:unauthorized, :invalid_session}}

    assert Auth.require_work_package(session, "SYMPP-OTHER", UnexpectedAuthRepo) ==
             {:error, {:service_unavailable, {:unexpected_grant_lookup_result, :tuple}}}
  end

  test "config parser defaults to stdio and rejects unsupported modes" do
    assert {:ok, %Config{mode: :stdio, database: nil}} = Config.parse([])
    assert %Config{mode: :stdio, repo: Repo, version: version} = Config.default()
    assert is_binary(version)
    assert {:ok, %Config{mode: :stdio, database: "tmp/sympp.sqlite3"}} = Config.parse(["--database", "tmp/sympp.sqlite3"])
    assert {:ok, %Config{work_key_secret_env: "SYMPP_MCP_SECRET"}} = Config.parse(["--work-key-secret-env", "SYMPP_MCP_SECRET"])
    assert {:error, message} = Config.parse(["--mode", "http"])
    assert message =~ "Only STDIO MCP mode is supported"
    assert {:error, invalid_message} = Config.parse(["--unknown"])
    assert invalid_message == Config.usage()
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

  test "tools list advertises worker argument schemas and hides architect tools without architect session", %{repo: repo} do
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
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties", "patch", "required"]) == ["nodes"]
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties", "patch", "properties", "nodes", "minItems"]) == 1
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties", "work_package_id", "type"]) == "string"

    update_plan_one_of = get_in(tools_by_name, ["update_task_plan", "inputSchema", "oneOf"])
    patch_update_schema = Enum.find(update_plan_one_of, &(Map.get(&1, "required") == ["expected_version", "patch"]))
    append_update_schema = Enum.find(update_plan_one_of, &(Map.get(&1, "required") == ["expected_version", "title"]))

    assert patch_update_schema["additionalProperties"] == false
    assert append_update_schema["additionalProperties"] == false
    assert Map.has_key?(patch_update_schema["properties"], "patch")
    refute Map.has_key?(patch_update_schema["properties"], "title")
    assert Map.has_key?(append_update_schema["properties"], "title")
    refute Map.has_key?(append_update_schema["properties"], "patch")

    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties", "patch", "properties", "nodes", "items", "anyOf"]) == [
             %{"required" => ["title"]},
             %{"required" => ["id"], "anyOf" => [%{"required" => ["title"]}, %{"required" => ["body"]}, %{"required" => ["status"]}]}
           ]

    assert get_in(tools_by_name, ["set_status", "inputSchema", "required"]) == ["status", "expected_status"]
    assert get_in(tools_by_name, ["report_blocker", "inputSchema", "properties", "blocker_id", "type"]) == "string"
    assert get_in(tools_by_name, ["resolve_blocker", "inputSchema", "required"]) == ["blocker_id", "resolution", "summary", "idempotency_key"]
    assert get_in(tools_by_name, ["attach_branch", "inputSchema", "required"]) == ["branch", "head_sha"]
    assert get_in(tools_by_name, ["attach_branch", "inputSchema", "properties", "head_sha", "type"]) == "string"

    pr_metadata_schema = %{
      "type" => "object",
      "additionalProperties" => true,
      "properties" => %{
        "head_sha" => %{"type" => "string"},
        "head" => %{
          "type" => "object",
          "additionalProperties" => true,
          "properties" => %{"sha" => %{"type" => "string"}},
          "required" => ["sha"]
        }
      },
      "anyOf" => [%{"required" => ["head_sha"]}, %{"required" => ["head"]}]
    }

    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "allOf"]) == [
             %{"anyOf" => [%{"required" => ["url"]}, %{"required" => ["number"]}]},
             %{
               "anyOf" => [
                 %{"required" => ["head_sha"]},
                 %{
                   "required" => ["metadata"],
                   "properties" => %{"metadata" => pr_metadata_schema}
                 }
               ]
             }
           ]

    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "properties", "head_sha", "type"]) == "string"
    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "properties", "metadata", "type"]) == "object"
    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "required"]) == ["metadata"]
    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "anyOf"]) == [%{"required" => ["url"]}, %{"required" => ["number"]}]
    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "properties", "metadata"]) == pr_metadata_schema
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "required"]) == ["summary", "tests", "artifacts", "head_sha"]
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "reviews", "type"]) == "array"
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "tests", "minItems"]) == 1
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "tests", "items", "type"]) == "string"
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "tests", "items", "pattern"]) == "\\S"
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "artifacts", "minItems"]) == 1
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "artifacts", "items", "type"]) == "string"
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "artifacts", "items", "pattern"]) == "\\S"
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "reviews", "items", "required"]) == ["lane", "verdict"]
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "head_sha", "type"]) == "string"
    assert get_in(tools_by_name, ["submit_review_package", "inputSchema", "properties", "acceptance_criteria_met", "type"]) == "boolean"

    refute Map.has_key?(tools_by_name, "read_child_status")
    refute Map.has_key?(tools_by_name, "mint_child_worker_key")

    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WORKER-TOOLS-LIST", kind: "mcp"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: minted.grant.secret_hash)
    worker_server = Server.new(Config.default(repo: repo), initialized: true, session: worker_session)

    worker_response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "worker-tools", "method" => "tools/list", "params" => %{}}, worker_server)

    worker_tools_by_name =
      worker_response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(worker_tools_by_name, "claim_work_key")
    refute Map.has_key?(worker_tools_by_name, "read_child_status")
    refute Map.has_key?(worker_tools_by_name, "mint_child_worker_key")
  end

  test "tools list advertises architect schemas only for architect sessions", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-TOOLS-LIST", kind: "mcp"))

    assert {:ok, architect_work_key} =
             create_architect_work_key(repo, package.id, [
               "read:child_progress",
               "read:child_findings",
               "mint:child_worker_key",
               "read:phase",
               "merge:child_into_phase",
               "split:child_work_package"
             ])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))
    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools = get_in(response, ["result", "tools"])
    tools_by_name = Map.new(tools, &{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "sympp.health")
    assert Map.has_key?(tools_by_name, "get_current_assignment")
    refute Map.has_key?(tools_by_name, "claim_work_key")
    refute Map.has_key?(tools_by_name, "create_child_work_package")
    refute Map.has_key?(tools_by_name, "revoke_child_worker_key")
    assert get_in(tools_by_name, ["read_child_status", "inputSchema", "required"]) == ["work_package_id"]
    assert get_in(tools_by_name, ["read_child_status", "inputSchema", "properties", "work_package_id", "type"]) == "string"
    assert get_in(tools_by_name, ["read_phase_board", "inputSchema", "required"]) == ["phase_id"]
    assert get_in(tools_by_name, ["mint_child_worker_key", "inputSchema", "required"]) == ["work_package_id", "template"]
    assert get_in(tools_by_name, ["mint_child_worker_key", "inputSchema", "properties", "template", "type"]) == "object"
    assert get_in(tools_by_name, ["merge_child_into_phase", "inputSchema", "required"]) == ["work_package_id", "merge_artifact"]
    assert get_in(tools_by_name, ["split_work_package", "inputSchema", "properties", "child_specs", "minItems"]) == 1
  end

  test "tools list exposes only claim refresh for stale architect sessions after grant revocation", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-TOOLS-REVOKED", kind: "mcp"))
    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:phase"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))
    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, architect_assignment.grant_id)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "revoked-architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools_by_name = response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    assert Map.keys(tools_by_name) |> Enum.sort() == ["claim_work_key", "sympp.health"]
  end

  test "tools list preserves ledger failures while revalidating bound sessions" do
    session =
      Session.new(%Assignment{
        grant_id: "grant-1",
        work_package_id: "SYMPP-LEDGER-TOOLS-LIST",
        display_key: "ABCD",
        grant_role: "architect",
        capabilities: ["read:phase"],
        claimed_at: DateTime.utc_now(:microsecond),
        claimed_by: "architect-1"
      })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "tools-list-ledger-failure", "method" => "tools/list", "params" => %{}},
        config: Config.default(repo: FailingAuthRepo),
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_000
    assert get_in(response, ["error", "data", "reason"]) == "ledger_unavailable"
  end

  test "tools list does not treat lifecycle architect capabilities as MCP tool capabilities", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-LIFECYCLE-ONLY", kind: "mcp"))
    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["architect:lifecycle.transition"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))
    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "lifecycle-only-architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools_by_name = response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    assert Map.keys(tools_by_name) |> Enum.sort() == ["get_current_assignment", "sympp.health"]
  end

  test "architect tools reject arguments outside their advertised schemas", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-STRICT", kind: "mcp"))
    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:child_progress", "read:child_findings"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "strict-architect-args",
          "method" => "tools/call",
          "params" => %{"name" => "read_child_status", "arguments" => %{"work_package_id" => package.id, "unexpected" => "value"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(response, ["error", "data", "arguments"]) == ["unexpected"]
  end

  test "worker tools reject arguments outside their advertised schemas", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-STRICT-ARGS", kind: "mcp", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "strict-args",
          "method" => "tools/call",
          "params" => %{"name" => "mark_ready", "arguments" => %{"work_package_id" => package.id}}
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(response, ["error", "data", "arguments"]) == ["work_package_id"]
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

  test "initialized tools call rejects invalid ids without notification side effects", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BAD-ID-CLAIM", kind: "mcp", status: "ready_for_worker"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => %{"bad" => "id"},
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert response["id"] == nil
    assert get_in(response, ["error", "data", "reason"]) == "invalid_request_id"
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
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

  test "stdio decoded payload helper retains response-only initialized state", %{repo: repo} do
    server = Server.new(Config.default(repo: repo))

    init_response =
      Stdio.handle_payload(
        %{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()},
        server
      )

    tools_response =
      Stdio.handle_payload(
        %{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}},
        server
      )

    assert get_in(init_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert is_list(get_in(tools_response, ["result", "tools"]))
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

    display_key_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-display-key",
          "method" => "tools/call",
          "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.display_key, "claimed_by" => "worker-1"}}
        },
        server
      )

    assert get_in(display_key_response, ["error", "data", "reason"]) == "display_key_only"

    {extra_argument_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-extra-argument",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_work_key",
            "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1", "work_package_id" => package.id}
          }
        },
        server
      )

    assert get_in(extra_argument_response, ["error", "data", "reason"]) == "unexpected_argument"

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
    assert get_in(assignment_response, ["error", "data", "reason"]) == "missing_session"
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
    assert get_in(assignment_response, ["error", "data", "reason"]) == "missing_session"

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
    assert get_in(missing_assignment_response, ["error", "data", "reason"]) == "missing_session"

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

    assert get_in(assignment_response, ["error", "data", "reason"]) == "missing_session"
  end

  test "explicit state key reinitialize clears stale live server sessions", %{repo: repo} do
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

    {assignment_response, _server} =
      Server.handle_response_state(
        %{"jsonrpc" => "2.0", "id" => "assignment-after-reinit", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        claimed_server
      )

    assert get_in(reinit_response, ["result", "serverInfo", "name"]) == "symphony-plus-plus"
    assert get_in(assignment_response, ["error", "data", "reason"]) == "missing_session"
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
    assert get_in(stale_assignment_response, ["error", "data", "reason"]) == "missing_session"
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
    assert get_in(assignment_response, ["error", "data", "reason"]) == "missing_session"
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
    assert get_in(assignment_response, ["error", "data", "reason"]) == "missing_session"
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
    assert get_in(nil_key_assignment_response, ["error", "data", "reason"]) == "missing_session"
    assert get_in(blank_key_assignment_response, ["error", "data", "reason"]) == "missing_session"
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
      assert get_in(assignment_response, ["error", "data", "reason"]) == "missing_session"
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
    assert get_in(List.first(responses), ["error", "data", "reason"]) == "missing_session"
    assert server.session.assignment.work_package_id == "SYMPP-NOTIFY-CLAIM"
  end

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

    assert get_in(resource_response, ["error", "data", "reason"]) == "worker_grant_required"

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
    assert get_in(missing_response, ["error", "data", "reason"]) == "missing_session"

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

  test "Phase 7 architect tools return explicit not-yet-implemented errors without minting grants", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-PHASE7", kind: "mcp"))
    assert {:ok, sibling} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-PHASE7-SIBLING", kind: "mcp"))

    assert {:ok, architect_work_key} =
             create_architect_work_key(repo, package.id, ["mint:child_worker_key", "read:phase"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))
    grants_before = repo.aggregate(AccessGrant, :count)

    mint_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "mint-child",
          "method" => "tools/call",
          "params" => %{"name" => "mint_child_worker_key", "arguments" => %{"work_package_id" => package.id, "template" => %{}}}
        },
        repo: repo,
        session: session
      )

    assert get_in(mint_response, ["error", "code"]) == -32_604
    assert get_in(mint_response, ["error", "data", "reason"]) == "phase7_not_implemented"
    assert repo.aggregate(AccessGrant, :count) == grants_before

    out_of_scope_mint_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "mint-child-sibling",
          "method" => "tools/call",
          "params" => %{"name" => "mint_child_worker_key", "arguments" => %{"work_package_id" => sibling.id, "template" => %{}}}
        },
        repo: repo,
        session: session
      )

    assert get_in(out_of_scope_mint_response, ["error", "code"]) == -32_003
    assert get_in(out_of_scope_mint_response, ["error", "data", "reason"]) == "outside_session_scope"

    board_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "phase-board",
          "method" => "tools/call",
          "params" => %{"name" => "read_phase_board", "arguments" => %{"phase_id" => "phase-1"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(board_response, ["error", "code"]) == -32_604
    assert get_in(board_response, ["error", "data", "phase"]) == "Phase 7"
  end

  test "Phase 7 architect stubs validate required arguments before not-implemented", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-STUB-ARGS", kind: "mcp"))
    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:phase"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "phase-board-missing-args",
          "method" => "tools/call",
          "params" => %{"name" => "read_phase_board", "arguments" => %{}}
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "missing_phase_id"
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
    assert get_in(Enum.at(responses, 1), ["error", "data", "reason"]) == "missing_session"
    assert server.session.assignment.work_package_id == "SYMPP-BATCH-CLAIM"
  end

  test "batch claim guard ignores earlier non-claim items on bound sessions", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BATCH-BOUND-CLAIM", kind: "mcp", status: "ready_for_worker"))
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
            "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
          }
        ],
        Server.new(Config.default(repo: repo), initialized: true, session: session)
      )

    assert Enum.map(responses, & &1["id"]) == ["context", "claim"]
    assert get_in(Enum.at(responses, 1), ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert server.session.assignment.work_package_id == package.id
  end

  test "batch final state keeps refreshed claim session after later non-claim items", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BATCH-REFRESHED-CLAIM", kind: "mcp", status: "ready_for_worker"))
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
            "params" => %{"name" => "claim_work_key", "arguments" => %{"secret" => minted.work_key.secret, "claimed_by" => "worker-1"}}
          },
          %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}}
        ],
        Server.new(Config.default(repo: repo), initialized: true, session: stale_session)
      )

    assert Enum.map(responses, & &1["id"]) == ["claim", "assignment"]
    assert get_in(Enum.at(responses, 0), ["result", "structuredContent", "assignment", "capabilities"]) == minted.grant.capabilities
    assert server.session.assignment.capabilities == minted.grant.capabilities
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
              "id" => " worker-plan-node ",
              "title" => "Implement MCP worker tools",
              "status" => "done"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(plan_response, ["result", "structuredContent", "plan_nodes", Access.at(0), "status"]) == "done"
    assert get_in(plan_response, ["result", "structuredContent", "plan_nodes", Access.at(0), "id"]) == "worker-plan-node"

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
            "arguments" => %{"id" => " custom-finding-id ", "title" => "Explicit", "body" => "Caller supplied id", "idempotency_key" => "finding-explicit"}
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

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-WORKER-OWN/worker", "head_sha" => "own-head"})
    attach_tool(repo, second_session, "attach_branch", %{"branch" => "agent/SYMPP-WORKER-OWN/worker", "head_sha" => "own-head"})

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

    assert get_in(finding_regrant_response, ["result", "structuredContent", "finding", "id"]) ==
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

    blank_title_patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "blank-title-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => [%{"id" => plan_node.id, "title" => "   "}]}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(blank_title_patch_response, ["error", "code"]) == -32_602
    assert {:ok, unchanged_after_blank_title} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert Enum.find(unchanged_after_blank_title, &(&1.id == plan_node.id)).title == "Original"

    mixed_patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "mixed-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => [%{"id" => plan_node.id, "status" => "done"}]}, "title" => "Ignored"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(mixed_patch_response, ["error", "data", "reason"]) == "invalid_update_task_plan"
    assert {:ok, unchanged_after_mixed_patch} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert Enum.find(unchanged_after_mixed_patch, &(&1.id == plan_node.id)).status == "pending"

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

    unknown_patch_key_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "unknown-patch-key-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => version, "patch" => %{"nodes" => [%{"id" => plan_node.id, "titel" => "Typo", "status" => "done"}]}}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(unknown_patch_key_response, ["error", "data", "reason"]) == "invalid_patch_node"

    patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{
              "expected_version" => version,
              "work_package_id" => package.id,
              "patch" => %{"nodes" => [%{"id" => " #{plan_node.id} ", "status" => "done", "body" => "Complete"}]}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(patch_response, ["result", "structuredContent", "plan_nodes", Access.at(0), "status"]) == "done"
    assert {:ok, nodes} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert length(nodes) == 2
    assert Enum.find(nodes, &(&1.id == plan_node.id)).body == "Complete"

    read_after_patch_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "read-plan-after-patch", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        repo: repo,
        session: session
      )

    body_only_patch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "body-only-patch-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{
              "expected_version" => get_in(read_after_patch_response, ["result", "structuredContent", "version"]),
              "patch" => %{"nodes" => [%{"id" => plan_node.id, "body" => "Body-only update"}]}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(body_only_patch_response, ["result", "structuredContent", "plan_nodes", Access.at(0), "id"]) == plan_node.id
    assert {:ok, body_only_nodes} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert Enum.find(body_only_nodes, &(&1.id == plan_node.id)).body == "Body-only update"

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

  test "update_task_plan patch can append a new node with caller id", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PLAN-PATCH-ID", kind: "mcp"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    read_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "read-plan", "method" => "tools/call", "params" => %{"name" => "read_task_plan"}},
        repo: repo,
        session: session
      )

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "patch-plan-with-id",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{
              "expected_version" => get_in(read_response, ["result", "structuredContent", "version"]),
              "patch" => %{"nodes" => [%{"id" => " caller-node-1 ", "title" => "Deterministic node", "status" => "pending"}]}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["result", "structuredContent", "plan_nodes", Access.at(0), "id"]) == "caller-node-1"
    assert {:ok, nodes} = PlanningRepository.list_plan_nodes(repo, package.id)
    assert Enum.any?(nodes, &(&1.id == "caller-node-1" and &1.title == "Deterministic node"))
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

    pre_metadata_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pre-metadata-headless-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Headless review before metadata",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(pre_metadata_review_response, ["error", "data", "reason"]) == "missing_head_sha"

    pre_branch_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pre-branch-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Review before branch head",
              "tests" => ["mix test"],
              "artifacts" => ["pre-branch-review-log.txt"],
              "head_sha" => "abc123",
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(pre_branch_review_response, ["error", "data", "reason"]) == "missing_current_head_sha"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-GATES/worker", "head_sha" => " abc123 ", "idempotency_key" => "shared-metadata-key"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/123", "head_sha" => " abc123 "})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/123", "abc123")

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

    assert get_in(headless_review_response, ["error", "data", "reason"]) == "missing_head_sha"

    missing_acceptance_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-acceptance", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "acceptance_criteria_met" in get_in(missing_acceptance_response, ["error", "data", "missing"])

    trimmed_review_response =
      attach_tool(repo, session, "submit_review_package", %{
        "summary" => "Trimmed review values",
        "tests" => [" mix test "],
        "artifacts" => [" review-log.txt "],
        "head_sha" => " abc123 ",
        "reviews" => []
      })

    assert get_in(trimmed_review_response, ["result", "structuredContent", "progress_event", "payload", "tests"]) == ["mix test"]
    assert get_in(trimmed_review_response, ["result", "structuredContent", "progress_event", "payload", "artifacts"]) == ["review-log.txt"]

    assert {:ok, trimmed_artifacts} = PlanningRepository.list_artifacts(repo, package.id)
    assert Enum.any?(trimmed_artifacts, &(&1.path == "review-log.txt"))

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
    assert "review_lanes_complete" in incremental_missing
    assert "acceptance_criteria_met" in incremental_missing
    refute "review_artifacts_attached" in incremental_missing
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

    extra_review_key_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "extra-review-key",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Extra review key",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [%{"lane" => "review_t1", "verdict" => "green", "note" => "typo"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(extra_review_key_response, ["error", "data", "reason"]) == "invalid_reviews"

    duplicate_review_lane_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "duplicate-review-lane",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Duplicate review lane",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [
                %{"lane" => " review_t1 ", "verdict" => "red"},
                %{"lane" => "review_t1", "verdict" => "green"}
              ]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(duplicate_review_lane_response, ["error", "data", "reason"]) == "invalid_reviews"

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
    assert "review_lanes_complete" in latest_missing_lane_missing
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
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/123", "def456")
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-GATES/worker", "head_sha" => "def456"})

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

    stale_review_missing = get_in(stale_review_response, ["error", "data", "missing"])
    assert "review_package_submitted" in stale_review_missing
    assert "review_lanes_complete" in stale_review_missing

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

    pre_ready_finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pre-ready-finding",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Finding before ready", "body" => "Recorded before ready", "idempotency_key" => "pre-ready-finding"}
          }
        },
        repo: repo,
        session: session
      )

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_human_merge"

    post_ready_branch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-branch",
          "method" => "tools/call",
          "params" => %{"name" => "attach_branch", "arguments" => %{"branch" => "agent/SYMPP-READY-GATES/worker", "head_sha" => "new-ready-head"}}
        },
        repo: repo,
        session: session
      )

    post_ready_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Red after ready",
              "tests" => ["mix test"],
              "artifacts" => ["red-after-ready.txt"],
              "head_sha" => "def456",
              "acceptance_criteria_met" => false,
              "reviews" => [%{"lane" => "review_t1", "verdict" => "red"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    post_ready_blocker_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "report_blocker",
            "arguments" => %{"summary" => "Blocked after ready", "idempotency_key" => "post-ready-blocker"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_progress_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-progress",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_progress",
            "arguments" => %{"summary" => "Progress after ready", "idempotency_key" => "post-ready-progress"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-finding",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Finding after ready", "body" => "Too late", "idempotency_key" => "post-ready-finding"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_finding_replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pre-ready-finding-replay",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Finding before ready", "body" => "Recorded before ready", "idempotency_key" => "pre-ready-finding"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_scope_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-scope",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_scope_expansion",
            "arguments" => %{"summary" => "Scope after ready", "idempotency_key" => "post-ready-scope"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_plan_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => 1, "title" => "Plan after ready"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(post_ready_branch_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_review_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_blocker_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_progress_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_finding_response, ["error", "data", "reason"]) == "already_ready"

    assert get_in(pre_ready_finding_response, ["result", "structuredContent", "finding", "id"]) ==
             get_in(post_ready_finding_replay_response, ["result", "structuredContent", "finding", "id"])

    assert get_in(post_ready_scope_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_plan_response, ["error", "data", "reason"]) == "already_ready"
    assert {:ok, ready_package} = WorkPackageRepository.get(repo, package.id)
    assert ready_package.status == "ready_for_human_merge"
  end

  test "review package submitted before PR attach does not satisfy later PR readiness", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PRE-PR-REVIEW", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PRE-PR-REVIEW/worker", "head_sha" => "pre-pr-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Pre-PR review",
      "tests" => ["mix test"],
      "artifacts" => ["pre-pr-review.txt"],
      "head_sha" => "pre-pr-head",
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

    missing = get_in(ready_response, ["error", "data", "missing"])
    assert "pr_attached" in missing
    refute "review_lanes_complete" in missing
    refute "review_artifacts_attached" in missing
  end

  test "branch-only readiness rejects review evidence from an older branch head", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BRANCH-HEAD-REVIEW", kind: "quick_fix", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-BRANCH-HEAD-REVIEW/worker", "head_sha" => "old-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Old head review",
      "tests" => ["mix test"],
      "artifacts" => ["old-head-review.txt"],
      "head_sha" => "old-head",
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}]
    })

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-BRANCH-HEAD-REVIEW/worker", "head_sha" => "new-head"})

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(ready_response, ["error", "data", "missing"])
    assert "review_lanes_complete" in missing
  end

  test "submit_review_package replay remains idempotent after branch head changes", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REVIEW-REPLAY", kind: "mcp", status: "ci_waiting"))

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-REPLAY/worker", "head_sha" => "head-a"})

    review_arguments = %{
      "summary" => "Review head A",
      "tests" => ["mix test"],
      "artifacts" => ["review-head-a.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    }

    first_response = attach_tool(repo, session, "submit_review_package", review_arguments)
    first_event_id = get_in(first_response, ["result", "structuredContent", "progress_event", "id"])

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-REPLAY/worker", "head_sha" => "head-b"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/791", "head_sha" => "head-b"})

    retry_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "retry-review-head-a",
          "method" => "tools/call",
          "params" => %{"name" => "submit_review_package", "arguments" => review_arguments}
        },
        repo: repo,
        session: session
      )

    assert get_in(retry_response, ["result", "structuredContent", "progress_event", "id"]) == first_event_id

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-replay", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_package_submitted" in get_in(ready_response, ["error", "data", "missing"])
  end

  test "submit_review_package exact replay survives worker grant renewal", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REVIEW-REGRANT", kind: "mcp", status: "ci_waiting"))

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-REGRANT/worker", "head_sha" => "head-a"})

    review_arguments = %{
      "summary" => "Review head A",
      "tests" => ["mix test"],
      "artifacts" => ["review-head-a.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    }

    first_response = attach_tool(repo, session, "submit_review_package", review_arguments)
    first_event_id = get_in(first_response, ["result", "structuredContent", "progress_event", "id"])

    assert {:ok, second_minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, second_assignment} = AccessGrantService.claim(repo, second_minted.work_key.secret, claimed_by: "worker-2")
    second_session = MCPHarness.session(second_assignment, proof_hash: second_minted.grant.secret_hash)

    retry_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "retry-review-regrant",
          "method" => "tools/call",
          "params" => %{"name" => "submit_review_package", "arguments" => review_arguments}
        },
        repo: repo,
        session: second_session
      )

    assert get_in(retry_response, ["result", "structuredContent", "progress_event", "id"]) == first_event_id

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, package.id)

    assert 1 ==
             Enum.count(progress_events, fn event ->
               event.status == "review_package_submitted" and event.payload["head_sha"] == "head-a"
             end)
  end

  test "metadata attachments require a scoped live session", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-METADATA-SCOPE", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, sibling_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-METADATA-SIBLING", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_session_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "branch-missing-session",
          "method" => "tools/call",
          "params" => %{"name" => "attach_branch", "arguments" => %{"branch" => "agent/SYMPP-METADATA-SCOPE/worker", "head_sha" => "head-a"}}
        },
        repo: repo
      )

    assert get_in(missing_session_response, ["error", "data", "reason"]) == "missing_session"

    stale_scope_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pr-wrong-package",
          "method" => "tools/call",
          "params" => %{
            "name" => "attach_pr",
            "arguments" => %{"work_package_id" => sibling_package.id, "url" => "https://github.com/example/repo/pull/792", "head_sha" => "head-a"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_scope_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "metadata tools honor caller idempotency keys for repeated matching payloads", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-METADATA-IDEMPOTENCY", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-METADATA-IDEMPOTENCY/worker", "head_sha" => "same-head", "idempotency_key" => "branch-key-1"})
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-METADATA-IDEMPOTENCY/worker", "head_sha" => "same-head", "idempotency_key" => "branch-key-2"})

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)

    assert events
           |> Enum.filter(&(get_in(&1.payload, ["type"]) == "branch" and get_in(&1.payload, ["head_sha"]) == "same-head"))
           |> length() == 2
  end

  test "sync_pr stores dry GitHub metadata and deterministic artifact", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-SYNC",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 status: "ci_waiting"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_pr", %{"number" => 42, "head_sha" => "sync-head"})

    response =
      attach_tool(repo, session, "sync_pr", %{
        "number" => 42,
        "metadata" => %{
          "head_sha" => "sync-head",
          "branch" => "agent/SYMPP-P6-001/github-pr-attachment-sync",
          "changed_files" => [%{"filename" => "elixir/lib/symphony_elixir/symphony_plus_plus/github/client.ex", "status" => "added"}],
          "check_summary" => %{"conclusion" => "success", "token" => "ghp_should_not_surface_nested"},
          "review_state" => %{"state" => "approved"},
          "merge_state" => %{"state" => "clean"},
          "token" => "ghp_should_not_surface"
        }
      })

    payload = get_in(response, ["result", "structuredContent", "progress_event", "payload"])

    assert payload["repository"] == "nextide/symphony-plus-plus"
    assert payload["number"] == 42
    assert payload["url"] == "https://github.com/nextide/symphony-plus-plus/pull/42"
    assert payload["head_sha"] == "sync-head"

    assert payload["changed_files"] == [
             %{"path" => "elixir/lib/symphony_elixir/symphony_plus_plus/github/client.ex", "status" => "added"}
           ]

    assert payload["changed_files_count"] == 1
    refute inspect(payload) =~ "ghp_should_not_surface"
    idempotency_key = get_in(response, ["result", "structuredContent", "progress_event", "idempotency_key"])
    refute idempotency_key =~ "ghp_should_not_surface"

    [_prefix, encoded_key_payload] = String.split(idempotency_key, "mcp:pr:", parts: 2)
    decoded_key_payload = encoded_key_payload |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term()

    refute inspect(decoded_key_payload) =~ "ghp_should_not_surface"
    assert payload["check_summary"]["token"] == "[REDACTED]"
    event_id = get_in(response, ["result", "structuredContent", "progress_event", "id"])

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)
    assert Enum.any?(artifacts, &(&1.kind == "github_pr" and &1.path == "github-pr.json" and &1.uri == payload["url"]))

    attach_tool(repo, session, "attach_pr", %{"number" => 43, "head_sha" => "sync-head"})

    replay_response =
      attach_tool(repo, session, "sync_pr", %{
        "number" => 42,
        "metadata" => %{
          "head_sha" => "sync-head",
          "branch" => "agent/SYMPP-P6-001/github-pr-attachment-sync",
          "changed_files" => [%{"filename" => "elixir/lib/symphony_elixir/symphony_plus_plus/github/client.ex", "status" => "added"}],
          "check_summary" => %{"conclusion" => "success", "token" => "ghp_should_not_surface_nested"},
          "review_state" => %{"state" => "approved"},
          "merge_state" => %{"state" => "clean"},
          "token" => "ghp_should_not_surface"
        }
      })

    assert get_in(replay_response, ["result", "structuredContent", "progress_event", "id"]) == event_id
    assert get_in(replay_response, ["result", "structuredContent", "progress_event", "payload", "number"]) == 42

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)
    pr_artifacts = Enum.filter(artifacts, &(&1.kind == "github_pr" and &1.path == "github-pr.json"))

    assert length(pr_artifacts) == 1
    assert [%{uri: "https://github.com/nextide/symphony-plus-plus/pull/43"}] = pr_artifacts
  end

  test "attach_pr idempotency replay accepts legacy URL-only payload shape", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-LEGACY-REPLAY", kind: "standard_pr", repo: "nextide/symphony-plus-plus", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    idempotency_key = "attach_pr:#{package.id}:legacy-pr-key"

    assert {:ok, legacy_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "pr_attached",
               status: "pr_attached",
               idempotency_key: idempotency_key,
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/42",
                 head_sha: "legacy-head"
               }
             })

    response =
      attach_tool(repo, session, "attach_pr", %{
        "number" => 42,
        "head_sha" => "legacy-head",
        "idempotency_key" => "legacy-pr-key"
      })

    assert get_in(response, ["result", "structuredContent", "progress_event", "id"]) == legacy_event.id

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.count(events, &(&1.idempotency_key == idempotency_key)) == 1
  end

  test "sync_pr malformed metadata returns structured MCP error", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-METADATA-ERROR", kind: "standard_pr", repo: "nextide/symphony-plus-plus", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync_pr",
          "method" => "tools/call",
          "params" => %{"name" => "sync_pr", "arguments" => %{"number" => 42, "metadata" => "bad"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "tool"]) == "sync_pr"
    assert get_in(response, ["error", "data", "reason"]) == "missing_metadata"
  end

  test "sync_pr preserves service error shape for PR metadata lookup failures" do
    session =
      Session.new(
        %Assignment{
          grant_id: "grant-pr-sync-service",
          work_package_id: "SYMPP-PR-SERVICE-ERROR",
          display_key: "ABCD",
          grant_role: "worker",
          capabilities: ["read:own", "write:own"],
          claimed_at: ~U[2026-05-05 00:00:00Z],
          claimed_by: "worker-1"
        },
        proof_hash: "proof"
      )

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync-pr-service-error",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{"number" => 42, "metadata" => %{"head_sha" => "head-a"}}
          }
        },
        repo: BusyPrSyncRepo,
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_000
    assert get_in(response, ["error", "data", "resource"]) == "sync_pr"
    assert get_in(response, ["error", "data", "reason"]) == "ledger_unavailable"
  end

  test "sync_pr requires an attached matching PR and metadata head", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-SYNC-BOUNDARY", kind: "standard_pr", repo: "nextide/symphony-plus-plus", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_attach =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync_pr",
          "method" => "tools/call",
          "params" => %{"name" => "sync_pr", "arguments" => %{"number" => 42, "metadata" => %{"head_sha" => "abc123"}}}
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_attach, ["error", "data", "reason"]) == "missing_attached_pr"

    attach_tool(repo, session, "attach_pr", %{"number" => 42, "head_sha" => "abc123"})

    mismatch =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync_pr",
          "method" => "tools/call",
          "params" => %{"name" => "sync_pr", "arguments" => %{"number" => 43, "metadata" => %{"head_sha" => "abc123"}}}
        },
        repo: repo,
        session: session
      )

    assert get_in(mismatch, ["error", "data", "reason"]) == "pr_mismatch"

    headless =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync_pr",
          "method" => "tools/call",
          "params" => %{"name" => "sync_pr", "arguments" => %{"number" => 42, "head_sha" => "abc123", "metadata" => %{}}}
        },
        repo: repo,
        session: session
      )

    assert get_in(headless, ["error", "data", "reason"]) == "missing_head_sha"
  end

  test "sync_pr resolves URL-only attached PRs by chronology", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-SYNC-CHRONOLOGY", kind: "standard_pr", repo: "nextide/symphony-plus-plus", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    assert {:ok, _current_attach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Current PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/symphony-plus-plus/pull/43", head_sha: "head-a"},
               created_at: ~U[2026-05-05 00:00:02Z]
             })

    assert {:ok, _backfilled_old_attach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Backfilled old PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/symphony-plus-plus/pull/42", head_sha: "head-a"},
               created_at: ~U[2026-05-05 00:00:01Z]
             })

    response =
      attach_tool(repo, session, "sync_pr", %{
        "number" => 43,
        "metadata" => %{"head_sha" => "head-a", "branch" => "agent/SYMPP-P6-001/github-pr-attachment-sync"}
      })

    assert get_in(response, ["result", "structuredContent", "progress_event", "payload", "number"]) == 43
  end

  test "sync_pr resolves PR numbers from standard metadata when package repo is short", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-SYNC-SHORT-REPO", kind: "mcp", repo: "symphony-plus-plus", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/nextide/symphony-plus-plus/pull/43", "head_sha" => "head-a"})

    response =
      attach_tool(repo, session, "sync_pr", %{
        "number" => 43,
        "metadata" => %{
          "head" => %{"sha" => "head-a", "ref" => "agent/SYMPP-P6-001/github-pr-attachment-sync"},
          "base" => %{"repo" => %{"full_name" => "nextide/symphony-plus-plus"}},
          "state" => "open",
          "mergeable_state" => "clean"
        }
      })

    payload = get_in(response, ["result", "structuredContent", "progress_event", "payload"])

    assert payload["repository"] == "nextide/symphony-plus-plus"
    assert payload["number"] == 43
    assert payload["merge_state"] == %{"mergeable_state" => "clean", "state" => "open"}
  end

  test "latest branch head supersedes earlier PR head for review evidence", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-BRANCH-HEAD", kind: "quick_fix", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-BRANCH-HEAD/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/789", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-BRANCH-HEAD/worker", "head_sha" => "head-b"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/789", "head_sha" => "head-a"})

    stale_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Old PR head review",
              "tests" => ["mix test"],
              "artifacts" => ["old-pr-head-review.txt"],
              "head_sha" => "head-a",
              "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_response, ["error", "data", "reason"]) == "stale_head_sha"

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Latest branch head review",
      "tests" => ["mix test"],
      "artifacts" => ["latest-branch-head-review.txt"],
      "head_sha" => "head-b",
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "latest branch head requires matching PR metadata for merge-gated readiness", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CURRENT-HEAD-PR", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-CURRENT-HEAD-PR/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-CURRENT-HEAD-PR/worker", "head_sha" => "head-b"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Latest branch head review",
      "tests" => ["mix test"],
      "artifacts" => ["latest-branch-head-review.txt"],
      "head_sha" => "head-b",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(ready_response, ["error", "data", "missing"])
    assert "pr_attached" in missing
  end

  test "attach_pr alone satisfies pr_attached for policies without current PR state", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-ATTACH-READY", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-ATTACH-READY/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    attach_only_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-attach-only", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(attach_only_response, ["result", "structuredContent", "ready"]) == true
  end

  test "current PR state policy fails missing, invalid, and stale sync state", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-SYNC-READY",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_current_pr_state"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-READY/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    missing_state_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-state", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(missing_state_response, ["error", "data", "missing"])
    refute "pr_attached" in missing
    assert "current_pr_state" in missing

    attach_tool(repo, session, "sync_pr", %{
      "url" => "https://github.com/example/repo/pull/790",
      "metadata" => %{"head_sha" => "head-a", "check_summary" => %{"token" => "x"}}
    })

    invalid_sync_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-invalid-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "current_pr_state" in get_in(invalid_sync_response, ["error", "data", "missing"])

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-READY/worker", "head_sha" => "head-b"})

    stale_sync_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-stale-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "current_pr_state" in get_in(stale_sync_response, ["error", "data", "missing"])

    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-b"})

    sync_pr_state(repo, session, "https://github.com/example/repo/pull/790", "head-b")

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review for advanced head",
      "tests" => ["mix test"],
      "artifacts" => ["review-head-b.txt"],
      "head_sha" => "head-b",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-synced-pr", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "attach_pr with full current state satisfies PR readiness", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-ATTACH-STATE-READY",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_current_pr_state"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-ATTACH-STATE-READY/worker", "head_sha" => "head-a"})

    attach_tool(repo, session, "attach_pr", %{
      "url" => "https://github.com/example/repo/pull/790",
      "metadata" => %{
        "head_sha" => "head-a",
        "check_summary" => %{"conclusion" => "success"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      }
    })

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-attach-state", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "abbreviated branch head does not satisfy PR metadata readiness", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-SHORT-HEAD-READY", kind: "mcp", status: "ci_waiting")
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{
      "branch" => "agent/SYMPP-PR-SHORT-HEAD-READY/worker",
      "head_sha" => "abcdef1"
    })

    attach_tool(repo, session, "attach_pr", %{
      "url" => "https://github.com/example/repo/pull/790",
      "head_sha" => "abcdef1234567890abcdef1234567890abcdef12"
    })

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Short head review",
      "tests" => ["mix test"],
      "artifacts" => ["short-head-review.txt"],
      "head_sha" => "abcdef1",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-short-head", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "pr_attached" in get_in(ready_response, ["error", "data", "missing"])
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

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-BLOCKER/worker", "head_sha" => "abc125"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/125", "head_sha" => "abc125"})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/125", "abc125")

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
    refute "plan_complete" in missing
    refute "branch_attached" in missing
    refute "pr_attached" in missing
    refute "review_package_submitted" in missing
    assert "tests_passed" in missing
    assert "review_lanes_complete" in missing

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "Unrelated scope request",
      "status" => "tests_passed",
      "payload" => %{"lane" => "review_t1", "verdict" => "green"},
      "idempotency_key" => "quick-fix-unrelated-status"
    })

    unrelated_status_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix-unrelated-status", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    unrelated_missing = get_in(unrelated_status_response, ["error", "data", "missing"])
    assert "tests_passed" in unrelated_missing
    assert "review_lanes_complete" in unrelated_missing

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed",
      "status" => "tests_passed",
      "idempotency_key" => "quick-fix-tests"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "T1 review green",
      "status" => "review_t1_green",
      "idempotency_key" => "quick-fix-review-t1"
    })

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-QUICK-FIX/worker", "head_sha" => "quick-fix-head-b"})

    stale_progress_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix-stale-progress", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    stale_progress_missing = get_in(stale_progress_response, ["error", "data", "missing"])
    assert "tests_passed" in stale_progress_missing
    assert "review_lanes_complete" in stale_progress_missing

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed for latest head",
      "status" => "tests_passed",
      "idempotency_key" => "quick-fix-tests-head-b"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "T1 review green for latest head",
      "status" => "review_t1_green",
      "idempotency_key" => "quick-fix-review-t1-head-b"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests failed after latest pass",
      "status" => "tests_failed",
      "idempotency_key" => "quick-fix-tests-head-b-failed"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "T1 review red after latest green",
      "status" => "review_t1_red",
      "idempotency_key" => "quick-fix-review-t1-head-b-red"
    })

    stale_green_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix-stale-green", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    stale_green_missing = get_in(stale_green_response, ["error", "data", "missing"])
    assert "tests_passed" in stale_green_missing
    assert "review_lanes_complete" in stale_green_missing

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed after failure",
      "status" => "tests_passed",
      "idempotency_key" => "quick-fix-tests-head-b-repassed"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "T1 review green after red",
      "status" => "review_t1_green",
      "idempotency_key" => "quick-fix-review-t1-head-b-regreen"
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix-after-progress", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_human_merge"
  end

  test "non-merge readiness accepts branchless review packages when branch metadata is not required", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BRANCHLESS-REVIEW", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Branchless quick-fix review",
      "tests" => ["mix test"],
      "artifacts" => ["branchless-review.txt"],
      "head_sha" => "standalone-head",
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-branchless-review", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "hotfix mark_ready accepts incident-depth review evidence without plan nodes", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-HOTFIX", kind: "hotfix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-HOTFIX/worker", "head_sha" => "hotfix-head"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/812", "head_sha" => "hotfix-head"})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/812", "hotfix-head")

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready hotfix",
      "tests" => ["mix test"],
      "artifacts" => ["hotfix-review.txt"],
      "head_sha" => "hotfix-head",
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-hotfix", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_human_merge"
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

    assert "recommendation_artifact_recorded" in get_in(missing_recommendation_response, ["error", "data", "missing"])
    refute "current_pr_state" in get_in(missing_recommendation_response, ["error", "data", "missing"])

    spoofed_artifact_id =
      "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, Enum.join([package.id, "recommendation", "recommendation.md"], ":")), padding: false)

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Spoofed recommendation",
      "payload" => %{
        "type" => "scope_expansion_request",
        "source_tool" => "request_scope_expansion",
        "recommendation_artifact_id" => spoofed_artifact_id,
        "approved" => false,
        "requested_file_globs" => ["lib/spoof/**"]
      },
      "idempotency_key" => "investigation-spoofed-recommendation"
    })

    spoofed_recommendation_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-spoofed-recommendation", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(spoofed_recommendation_response, ["error", "data", "missing"])
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Spoofed recommendation with protected-looking key",
      "payload" => %{
        "type" => "scope_expansion_request",
        "source_tool" => "request_scope_expansion",
        "recommendation_artifact_id" => spoofed_artifact_id,
        "approved" => false,
        "requested_file_globs" => ["lib/spoof/**"]
      },
      "idempotency_key" => "request_scope_expansion:investigation-spoofed-recommendation"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Spoofed recommendation without protected type",
      "payload" => %{
        "approved" => false,
        "requested_file_globs" => ["lib/spoof/**"]
      },
      "idempotency_key" => "investigation-spoofed-recommendation-fields"
    })

    protected_key_spoof_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-protected-key-spoof", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(protected_key_spoof_response, ["error", "data", "missing"])
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)
    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, package.id)

    for summary <- [
          "Spoofed recommendation",
          "Spoofed recommendation with protected-looking key",
          "Spoofed recommendation without protected type"
        ] do
      event = Enum.find(progress_events, &(&1.summary == summary))
      assert event
      refute Map.has_key?(event.payload, "type")
      refute Map.has_key?(event.payload, "source_tool")
      refute Map.has_key?(event.payload, "recommendation_artifact_id")
      refute Map.has_key?(event.payload, "approved")
      refute Map.has_key?(event.payload, "requested_file_globs")
    end

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => spoofed_artifact_id,
               "work_package_id" => package.id,
               "path" => "recommendation.md",
               "title" => "Spoofed recommendation artifact",
               "kind" => "reference",
               "uri" => "sympp://artifacts/spoofed-recommendation"
             })

    spoofed_artifact_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-spoofed-artifact", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(spoofed_artifact_response, ["error", "data", "missing"])

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "No scope expansion needed",
      "body" => "Recommendation recorded for the investigation package.",
      "idempotency_key" => "investigation-recommendation"
    })

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "Updated recommendation",
      "body" => "Recommendation remains recorded without duplicate canonical artifacts.",
      "idempotency_key" => "investigation-recommendation-updated"
    })

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)

    assert Enum.any?(
             artifacts,
             &(&1.title == "Investigation recommendation" and &1.kind == "recommendation" and &1.path == "recommendation.md" and
                 is_nil(&1.uri))
           )

    repo.get!(Artifact, spoofed_artifact_id)
    |> Ecto.Changeset.change(uri: "sympp://artifacts/canonical-recommendation")
    |> repo.update!()

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "Final recommendation",
      "body" => "Recommendation remains recorded without clearing canonical artifact URI.",
      "idempotency_key" => "investigation-recommendation-final"
    })

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)

    assert Enum.any?(
             artifacts,
             &(&1.title == "Investigation recommendation" and &1.kind == "recommendation" and &1.path == "recommendation.md" and
                 &1.uri == "sympp://artifacts/canonical-recommendation")
           )

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "non-investigation scope requests do not emit recommendation artifact references", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-HOTFIX-SCOPE-REQUEST", kind: "hotfix"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "Need extra file",
      "body" => "Worker recommends expanding allowed files.",
      "idempotency_key" => "hotfix-scope-request",
      "payload" => %{
        "requested_file_globs" => ["lib/other/**"],
        "recommendation_artifact_id" => "artifact_spoofed",
        "source_tool" => "caller"
      }
    })

    assert {:ok, [event]} = PlanningRepository.list_progress_events(repo, package.id)
    assert event.payload["type"] == "scope_expansion_request"
    assert event.payload["source_tool"] == "request_scope_expansion"
    assert event.payload["requested_file_globs"] == ["lib/other/**"]
    refute Map.has_key?(event.payload, "recommendation_artifact_id")

    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)
  end

  test "request_scope_expansion without a session returns an auth error", %{repo: repo} do
    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "scope-without-session",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_scope_expansion",
            "arguments" => %{"summary" => "Need more scope", "idempotency_key" => "missing-session-scope"}
          }
        },
        repo: repo
      )

    assert get_in(response, ["error", "data", "reason"]) == "missing_session"
  end

  test "investigation readiness rejects legacy recommendation event without artifact", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-LEGACY-READY", kind: "investigation", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    legacy_artifact_id =
      "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, Enum.join([package.id, "recommendation", "recommendation.md"], ":")), padding: false)

    assert {:ok, _finding} =
             PlanningRepository.append_finding(repo, %{
               "work_package_id" => package.id,
               "title" => "Recommendation",
               "body" => "No code change needed.",
               "idempotency_key" => "investigation-legacy-finding"
             })

    assert {:ok, event} =
             PlanningRepository.append_audit_progress_event(repo, assignment, %{
               "work_package_id" => package.id,
               "summary" => "Prior recommendation",
               "body" => "Recommendation recorded before artifact markers existed.",
               "idempotency_key" => "request_scope_expansion:investigation-legacy-recommendation",
               "payload" => %{
                 "type" => "scope_expansion_request",
                 "source_tool" => "request_scope_expansion",
                 "approved" => false,
                 "requested_file_globs" => ["lib/legacy/**"],
                 "recommendation_artifact_id" => legacy_artifact_id
               }
             })

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)
    refute Enum.any?(artifacts, &(&1.kind == "recommendation" and &1.path == "recommendation.md"))

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-legacy-recommendation", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(ready_response, ["error", "data", "missing"])
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)

    replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "replay-legacy-recommendation",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_scope_expansion",
            "arguments" => %{
              "summary" => "Prior recommendation",
              "body" => "Recommendation recorded before artifact markers existed.",
              "idempotency_key" => "investigation-legacy-recommendation",
              "payload" => %{
                "requested_file_globs" => ["lib/legacy/**"],
                "recommendation_artifact_id" => legacy_artifact_id
              }
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(replay_response, ["result", "structuredContent", "progress_event", "id"]) == event.id
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)
  end

  test "mark_ready fails recommendation gate when legacy artifact cannot be repaired", %{repo: repo} do
    assert {:ok, owner_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-LEGACY-OWNER", kind: "investigation"))
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-LEGACY-COLLISION", kind: "investigation", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    legacy_artifact_id =
      "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, Enum.join([package.id, "recommendation", "recommendation.md"], ":")), padding: false)

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => legacy_artifact_id,
               "work_package_id" => owner_package.id,
               "path" => "recommendation.md",
               "title" => "Other package recommendation",
               "kind" => "recommendation"
             })

    assert {:ok, _finding} =
             PlanningRepository.append_finding(repo, %{
               "work_package_id" => package.id,
               "title" => "Recommendation",
               "body" => "No code change needed.",
               "idempotency_key" => "investigation-legacy-collision-finding"
             })

    assert {:ok, _event} =
             PlanningRepository.append_audit_progress_event(repo, assignment, %{
               "work_package_id" => package.id,
               "summary" => "Prior recommendation",
               "body" => "Recommendation recorded before artifact markers existed.",
               "idempotency_key" => "request_scope_expansion:investigation-legacy-collision-recommendation",
               "payload" => %{
                 "type" => "scope_expansion_request",
                 "source_tool" => "request_scope_expansion",
                 "approved" => false,
                 "recommendation_artifact_id" => legacy_artifact_id
               }
             })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-legacy-collision", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(response, ["error", "data", "missing"])
  end

  test "unmarked legacy scope event replay does not create recommendation artifact readiness", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-LEGACY-UNMARKED", kind: "investigation", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    assert {:ok, _finding} =
             PlanningRepository.append_finding(repo, %{
               "work_package_id" => package.id,
               "title" => "Recommendation",
               "body" => "No code change needed.",
               "idempotency_key" => "investigation-legacy-unmarked-finding"
             })

    assert {:ok, _event} =
             PlanningRepository.append_audit_progress_event(repo, assignment, %{
               "work_package_id" => package.id,
               "summary" => "Prior scope request",
               "body" => "Raw scope request without canonical recommendation marker.",
               "idempotency_key" => "request_scope_expansion:investigation-legacy-unmarked",
               "payload" => %{
                 "type" => "scope_expansion_request",
                 "source_tool" => "request_scope_expansion",
                 "approved" => false
               }
             })

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-legacy-unmarked", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(response, ["error", "data", "missing"])
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)

    replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "replay-legacy-unmarked",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_scope_expansion",
            "arguments" => %{
              "summary" => "Prior scope request",
              "body" => "Raw scope request without canonical recommendation marker.",
              "idempotency_key" => "investigation-legacy-unmarked"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(replay_response, ["result", "structuredContent", "progress_event", "id"])
    assert {:ok, []} = PlanningRepository.list_artifacts(repo, package.id)

    replay_ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-legacy-unmarked-after-replay", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "recommendation_artifact_recorded" in get_in(replay_ready_response, ["error", "data", "missing"])

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "Canonical recommendation",
      "body" => "Recommendation is now recorded through the current canonical path.",
      "idempotency_key" => "investigation-legacy-unmarked-canonical"
    })

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)

    assert Enum.any?(
             artifacts,
             &(&1.work_package_id == package.id and &1.path == "recommendation.md" and
                 &1.title == "Investigation recommendation" and &1.kind == "recommendation")
           )

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-legacy-unmarked-after-canonical", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "recommendation artifact repair rejects cross-package id collisions", %{repo: repo} do
    assert {:ok, owner_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-OWNER", kind: "investigation"))
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-INVESTIGATION-COLLISION", kind: "investigation"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    colliding_artifact_id =
      "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, Enum.join([package.id, "recommendation", "recommendation.md"], ":")), padding: false)

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => colliding_artifact_id,
               "work_package_id" => owner_package.id,
               "path" => "recommendation.md",
               "title" => "Other package recommendation",
               "kind" => "recommendation"
             })

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "scope-artifact-collision",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_scope_expansion",
            "arguments" => %{
              "summary" => "Recommendation",
              "body" => "Recommendation should not steal another package artifact.",
              "idempotency_key" => "artifact-collision"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "data", "reason"]) == "id_already_exists"
    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, owner_package.id)
    assert Enum.any?(artifacts, &(&1.id == colliding_artifact_id and &1.work_package_id == owner_package.id))
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

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-CAP/worker", "head_sha" => "abc124"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/124", "head_sha" => "abc124"})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/124", "abc124")

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

  test "transactional assignment revalidation rejects expired grants", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-EXPIRED-TX"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    repo.update_all(AccessGrant, set: [expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)])

    assert {:error, :expired} =
             PlanningRepository.append_audit_progress_event(repo, assignment, %{
               "summary" => "Should not write",
               "idempotency_key" => "expired-progress"
             })

    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    progress_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "expired-progress",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"summary" => "Should not write", "idempotency_key" => "expired-progress-mcp"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(progress_response, ["error", "code"]) == -32_001
    assert get_in(progress_response, ["error", "data", "reason"]) == "expired"

    review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "expired-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Should not write",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(review_response, ["error", "code"]) == -32_001
    assert get_in(review_response, ["error", "data", "reason"]) == "expired"

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, work_package.id)
    assert events == []
  end

  test "idempotent progress replay revalidates live grants", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REPLAY-REVOKED"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    first_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "first-progress",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"summary" => "Stored once", "idempotency_key" => "replay-progress"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(first_response, ["result", "structuredContent", "progress_event", "idempotency_key"]) == "append_progress:replay-progress"

    first_event_id = get_in(first_response, ["result", "structuredContent", "progress_event", "id"])
    assert {:ok, second_minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, second_assignment} = AccessGrantService.claim(repo, second_minted.work_key.secret, claimed_by: "worker-2")
    second_session = MCPHarness.session(second_assignment, proof_hash: second_minted.grant.secret_hash)

    renewed_replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "renewed-replay-progress",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"summary" => "Stored once", "idempotency_key" => "replay-progress"}}
        },
        repo: repo,
        session: second_session
      )

    assert get_in(renewed_replay_response, ["result", "structuredContent", "progress_event", "id"]) == first_event_id

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "replay-progress",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"summary" => "Stored once", "idempotency_key" => "replay-progress"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(replay_response, ["error", "data", "reason"]) == "revoked"
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

  defp handle_state_agent, do: Module.concat(Server, HandleState)

  defp handle_state_store_key(server), do: {handle_state_namespace(server.config), server.state_key}

  defp handle_state_namespace(%Config{} = config), do: {config.mode, ledger_namespace(config)}

  defp ledger_namespace(%Config{repo: repo, database: database}) do
    case current_ledger_identity(repo, database) do
      {:ok, identity} -> identity
      :error -> {:configured_database, repo_database_key(repo, database)}
    end
  end

  defp current_ledger_identity(repo, database) do
    case SQL.query(repo, "PRAGMA database_list", [], log: false) do
      {:ok, %{rows: rows}} ->
        case Enum.find(rows, &main_database_row?/1) do
          [_seq, "main", path] -> {:ok, main_database_identity(repo, path, database)}
          _row -> :error
        end

      _result ->
        :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp main_database_row?([_seq, "main", _path]), do: true
  defp main_database_row?(_row), do: false

  defp main_database_identity(repo, path, _database) when is_binary(path) and path != "" do
    {:main_database, repo_database_key(repo, path)}
  end

  defp main_database_identity(repo, _path, nil), do: blank_database_identity(repo)
  defp main_database_identity(repo, _path, database), do: {:configured_database, repo_database_key(repo, database)}

  defp blank_database_identity(repo) when is_pid(repo), do: {:repo_process, repo}

  defp blank_database_identity(repo) when is_atom(repo) do
    case repo.get_dynamic_repo() do
      nil -> {:repo, repo}
      dynamic_repo -> {:dynamic_repo, dynamic_repo}
    end
  end

  defp repo_database_key(repo, database) do
    if function_exported?(repo, :database_key, 1), do: repo.database_key(database), else: database
  end

  defp handle_state_store do
    ensure_handle_state_agent()
    Agent.get(handle_state_agent(), & &1)
  end

  defp put_handle_state_entry(server, entry) do
    ensure_handle_state_agent()
    Agent.update(handle_state_agent(), &Map.put(&1, handle_state_store_key(server), entry))
  end

  defp reset_handle_state_store do
    ensure_handle_state_agent()
    Agent.update(handle_state_agent(), fn _store -> %{} end)
  end

  defp delete_handle_state_entry(server) do
    ensure_handle_state_agent()
    Agent.update(handle_state_agent(), &Map.delete(&1, handle_state_store_key(server)))
  end

  defp ensure_handle_state_agent do
    case Process.whereis(handle_state_agent()) do
      nil ->
        case Agent.start(fn -> %{} end, name: handle_state_agent()) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
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

  defp sync_pr_state(repo, session, url, head_sha) do
    attach_tool(repo, session, "sync_pr", %{
      "url" => url,
      "metadata" => %{
        "head_sha" => head_sha,
        "check_summary" => %{"conclusion" => "success"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      }
    })
  end

  defp append_done_plan(repo, work_package_id) do
    assert {:ok, _plan_node} =
             PlanningRepository.append_plan_node(repo, %{
               "work_package_id" => work_package_id,
               "title" => "Complete implementation",
               "status" => "done"
             })
  end

  defp create_architect_work_key(repo, work_package_id, capabilities \\ ["architect:lifecycle.transition"]) do
    now = DateTime.utc_now(:microsecond)
    work_key = WorkKey.generate()

    with {:ok, _grant} <-
           AccessGrantRepository.create(repo, %{
             work_package_id: work_package_id,
             display_key: work_key.display_key,
             secret_hash: WorkKey.secret_hash(work_key.secret),
             grant_role: "architect",
             capabilities: capabilities,
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
