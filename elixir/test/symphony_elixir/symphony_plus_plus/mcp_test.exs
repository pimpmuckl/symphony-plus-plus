Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
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
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SecretHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  @architect_phase_id "phase-mcp-architect-test"
  @child_worker_grant_provenance "child_worker_delegation"

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

  defmodule MintReadyRaceRepo do
    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    @race_key :sympp_mint_child_ready_race_id

    def arm(child_id, attrs \\ %{status: "claimed"}), do: Process.put(@race_key, {child_id, attrs})
    def disarm, do: Process.delete(@race_key)

    def transaction(fun) do
      Repo.transaction(fn ->
        case Process.get(@race_key) do
          {child_id, attrs} when is_binary(child_id) and is_map(attrs) ->
            Process.delete(@race_key)
            updates = Map.to_list(attrs) ++ [updated_at: DateTime.utc_now(:microsecond)]

            Repo.update_all(
              from(work_package in WorkPackage, where: work_package.id == ^child_id),
              set: updates
            )

          _child_id ->
            :ok
        end

        fun.()
      end)
    end

    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def all(query), do: Repo.all(query)
    def one(query), do: Repo.one(query)
    def update(changeset), do: Repo.update(changeset)
    def update_all(query, updates), do: Repo.update_all(query, updates)
    def rollback(value), do: Repo.rollback(value)
  end

  defmodule MintChildScopeRaceRepo do
    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    @race_key :sympp_mint_child_scope_race

    def arm(child_id, attrs), do: Process.put(@race_key, {child_id, attrs, 0})
    def disarm, do: Process.delete(@race_key)

    def transaction(fun), do: Repo.transaction(fun)

    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def one(query), do: Repo.one(query)

    def update_all(query, updates) do
      case Process.get(@race_key) do
        {child_id, attrs, 2} when is_binary(child_id) and is_map(attrs) ->
          Process.put(@race_key, {child_id, attrs, 3})
          drift_updates = Map.to_list(attrs) ++ [updated_at: DateTime.utc_now(:microsecond)]
          Repo.update_all(from(work_package in WorkPackage, where: work_package.id == ^child_id), set: drift_updates)

        {child_id, attrs, count} when is_integer(count) ->
          Process.put(@race_key, {child_id, attrs, count + 1})

        _race ->
          :ok
      end

      Repo.update_all(query, updates)
    end

    def rollback(value), do: Repo.rollback(value)
  end

  defmodule CreateChildAnchorRaceRepo do
    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    @race_key :sympp_create_child_anchor_race

    def arm(anchor_id, attrs), do: Process.put(@race_key, {anchor_id, attrs})
    def disarm, do: Process.delete(@race_key)

    def transaction(fun) do
      Repo.transaction(fn ->
        case Process.get(@race_key) do
          {anchor_id, attrs} when is_binary(anchor_id) and is_map(attrs) ->
            Process.delete(@race_key)
            updates = Map.to_list(attrs) ++ [updated_at: DateTime.utc_now(:microsecond)]
            Repo.update_all(from(work_package in WorkPackage, where: work_package.id == ^anchor_id), set: updates)

          _race ->
            :ok
        end

        fun.()
      end)
    end

    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def all(query), do: Repo.all(query)
    def one(query), do: Repo.one(query)
    def update_all(query, updates), do: Repo.update_all(query, updates)
    def rollback(value), do: Repo.rollback(value)
  end

  defmodule MintParentGrantRaceRepo do
    import Ecto.Query, only: [from: 2]

    alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    @race_key :sympp_mint_parent_grant_race

    def arm(grant_id, attrs), do: Process.put(@race_key, {grant_id, attrs})
    def disarm, do: Process.delete(@race_key)

    def transaction(fun) do
      Repo.transaction(fn ->
        case Process.get(@race_key) do
          {grant_id, attrs} when is_binary(grant_id) and is_map(attrs) ->
            Process.delete(@race_key)
            updates = Map.to_list(attrs) ++ [updated_at: DateTime.utc_now(:microsecond)]
            Repo.update_all(from(grant in AccessGrant, where: grant.id == ^grant_id), set: updates)

          _race ->
            :ok
        end

        fun.()
      end)
    end

    def get(schema, id), do: Repo.get(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def all(query), do: Repo.all(query)
    def one(query), do: Repo.one(query)
    def update_all(query, updates), do: Repo.update_all(query, updates)
    def rollback(value), do: Repo.rollback(value)
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
    File.rm_rf(test_handoff_store_dir())
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkRequest)
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)

    on_exit(fn ->
      cleanup_test_child_worker_handoffs(repo)
      File.rm_rf(test_handoff_store_dir())
    end)

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

    assert {:ok, nullable_session} = Session.from_map(%{attrs | "work_package_id" => nil, "capabilities" => nil})
    assert nullable_session.assignment.work_package_id == nil
    assert nullable_session.assignment.capabilities == nil

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
    assert %Config{mode: :stdio, repo: Repo, version: version, repo_root: nil} = Config.default()
    assert is_binary(version)
    assert {:ok, %Config{mode: :stdio, database: "tmp/sympp.sqlite3"}} = Config.parse(["--database", "tmp/sympp.sqlite3"])
    assert {:ok, %Config{repo_root: repo_root}} = Config.parse(["--repo-root", " . "])
    assert repo_root == Path.expand(".")
    assert {:error, repo_root_message} = Config.parse(["--repo-root", "  "])
    assert repo_root_message == Config.usage()
    assert {:error, secret_env_message} = Config.parse(["--work-key-secret-env", "SYMPP_MCP_SECRET"])
    assert secret_env_message == Config.usage()

    assert {:ok, %Config{work_key_secret_env: "SYMPP_MCP_SECRET", claimed_by: "worker-1"}} =
             Config.parse(["--work-key-secret-env", "SYMPP_MCP_SECRET", "--claimed-by", "worker-1"])

    assert {:error, message} = Config.parse(["--mode", "http"])
    assert message =~ "Only STDIO MCP mode is supported"
    assert {:error, invalid_message} = Config.parse(["--unknown"])
    assert invalid_message == Config.usage()
  end

  test "MCP timestamp serialization treats naive datetimes as UTC instants" do
    assert Server.mcp_timestamp(~U[2026-05-12 12:34:56.123456Z]) == "2026-05-12T12:34:56.123456Z"
    assert Server.mcp_timestamp(~N[2026-05-12 12:34:56.123456]) == "2026-05-12T12:34:56.123456Z"
    assert Server.mcp_timestamp(nil) == nil
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

  test "health and explicit state keys follow atom-valued dynamic repos" do
    database_path = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()
    repo_name = :"sympp_mcp_named_dynamic_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Repo.start_link(database: database_path, name: repo_name, pool_size: 1, log: false)

    try do
      Repo.put_dynamic_repo(repo_name)
      assert :ok = WorkPackageRepository.migrate(Repo)

      health_response =
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "named-health",
            "method" => "tools/call",
            "params" => %{"name" => "sympp.health", "arguments" => %{}}
          },
          config: Config.default(repo: Repo)
        )

      {_initialize_response, _server} =
        Server.handle_response_state(
          %{"jsonrpc" => "2.0", "id" => "named-init", "method" => "initialize", "params" => initialize_params()},
          Server.new(Config.default(repo: Repo), state_key: "named-dynamic-ledger-state")
        )

      {tools_response, _server} =
        Server.handle_response_state(
          %{"jsonrpc" => "2.0", "id" => "named-tools", "method" => "tools/list", "params" => %{}},
          Server.new(Config.default(repo: Repo), state_key: "named-dynamic-ledger-state")
        )

      assert get_in(health_response, ["result", "structuredContent", "ledger"]) == %{"reachable" => true}
      assert is_list(get_in(tools_response, ["result", "tools"]))
    after
      Repo.put_dynamic_repo(original_repo)
      if Process.alive?(pid), do: GenServer.stop(pid)
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
          McpTask.run(["--work-key-secret-env", env_var, "--claimed-by", "worker-1"])
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

  test "mix task rejects work key secret environment without claimed_by" do
    database_path = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()
    env_var = "SYMPP_MCP_TEST_SECRET_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

    try do
      Repo.put_dynamic_repo(pid)
      assert :ok = WorkPackageRepository.migrate(Repo)
      assert {:ok, package} = WorkPackageRepository.create(Repo, WorkPackageFactory.attrs(id: "SYMPP-P3-CLAIMED-BY"))
      assert {:ok, minted} = AccessGrantService.mint_worker_grant(Repo, package.id)
      System.put_env(env_var, minted.work_key.secret)

      assert_raise Mix.Error, ~r/Usage: mix sympp\.mcp/, fn ->
        capture_io("", fn ->
          McpTask.run(["--work-key-secret-env", env_var])
        end)
      end

      assert {:error, usage} = Config.parse(["--work-key-secret-env", env_var, "--claimed-by", "  "])
      assert usage =~ "Usage: mix sympp.mcp"
    after
      System.delete_env(env_var)
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  test "mix task claims an unclaimed work key from environment when claimed_by is provided" do
    database_path = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()
    env_var = "SYMPP_MCP_TEST_SECRET_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

    try do
      Repo.put_dynamic_repo(pid)
      assert :ok = WorkPackageRepository.migrate(Repo)
      assert {:ok, package} = WorkPackageRepository.create(Repo, WorkPackageFactory.attrs(id: "SYMPP-P10-003"))
      assert {:ok, minted} = AccessGrantService.mint_worker_grant(Repo, package.id)
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
          McpTask.run(["--work-key-secret-env", env_var, "--claimed-by", "worker-env-1"])
        end)

      refute output =~ minted.work_key.secret
      [_init_response, response] = decode_json_lines(output)
      assignment = Jason.decode!(get_in(response, ["result", "contents", Access.at(0), "text"]))

      assert assignment["work_package_id"] == "SYMPP-P10-003"
      assert assignment["claimed_by"] == "worker-env-1"
      assert {:ok, claimed_grant} = AccessGrantRepository.get(Repo, minted.grant.id)
      assert claimed_grant.claimed_by == "worker-env-1"
    after
      System.delete_env(env_var)
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  test "mix task health uses the database-scoped work-key session ledger" do
    database_path = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()
    env_var = "SYMPP_MCP_TEST_SECRET_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

    try do
      Repo.put_dynamic_repo(pid)
      assert :ok = WorkPackageRepository.migrate(Repo)
      assert {:ok, package} = WorkPackageRepository.create(Repo, WorkPackageFactory.attrs(id: "SYMPP-P10-006-HEALTH"))
      assert {:ok, minted} = AccessGrantService.mint_worker_grant(Repo, package.id)
      System.put_env(env_var, minted.work_key.secret)

      input =
        [
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}),
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "health",
            "method" => "tools/call",
            "params" => %{"name" => "sympp.health", "arguments" => %{}}
          }),
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "assignment",
            "method" => "resources/read",
            "params" => %{"uri" => "sympp://assignment/current"}
          }),
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "progress",
            "method" => "tools/call",
            "params" => %{
              "name" => "append_progress",
              "arguments" => %{
                "summary" => "Health reached the scoped ledger",
                "idempotency_key" => "test-health-scoped-ledger"
              }
            }
          })
        ]
        |> Enum.join("\n")
        |> Kernel.<>("\n")

      output =
        capture_io(input, fn ->
          McpTask.run(["--database", database_path, "--work-key-secret-env", env_var, "--claimed-by", "worker-health-1"])
        end)

      responses = decode_json_lines(output)
      health_response = Enum.find(responses, &(Map.get(&1, "id") == "health"))
      assignment_response = Enum.find(responses, &(Map.get(&1, "id") == "assignment"))
      progress_response = Enum.find(responses, &(Map.get(&1, "id") == "progress"))
      assignment = Jason.decode!(get_in(assignment_response, ["result", "contents", Access.at(0), "text"]))

      assert get_in(health_response, ["result", "structuredContent", "status"]) == "ok"
      assert get_in(health_response, ["result", "structuredContent", "ledger"]) == %{"reachable" => true}
      assert assignment["work_package_id"] == package.id
      assert get_in(progress_response, ["result", "structuredContent", "progress_event", "id"])
      refute output =~ minted.work_key.secret
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

    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "properties", "number", "anyOf"]) == [
             %{"type" => "integer", "minimum" => 1},
             %{"type" => "string", "pattern" => "^[1-9][0-9]*$"}
           ]

    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "properties", "metadata", "type"]) == "object"
    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "required"]) == ["metadata"]

    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "allOf"]) == [
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

    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "properties", "metadata", "type"]) == "object"

    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "properties", "number", "anyOf"]) == [
             %{"type" => "integer", "minimum" => 1},
             %{"type" => "string", "pattern" => "^[1-9][0-9]*$"}
           ]

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
    {_anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-TOOLS-LIST", [
        "read:child_progress",
        "read:child_findings",
        "read:work_request",
        "mint:child_worker_key",
        "read:phase",
        "approve:child_ready_state",
        "approve:scope_expansion",
        "merge:child_into_phase",
        "split:child_work_package"
      ])

    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools = get_in(response, ["result", "tools"])
    tools_by_name = Map.new(tools, &{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "sympp.health")
    assert Map.has_key?(tools_by_name, "get_current_assignment")
    refute Map.has_key?(tools_by_name, "claim_work_key")
    refute Map.has_key?(tools_by_name, "create_child_work_package")
    refute Map.has_key?(tools_by_name, "revoke_child_worker_key")
    assert get_in(tools_by_name, ["list_work_requests", "inputSchema", "required"]) == []
    assert get_in(tools_by_name, ["list_work_requests", "inputSchema", "properties", "status", "type"]) == "string"
    assert get_in(tools_by_name, ["read_work_request", "inputSchema", "required"]) == ["work_request_id"]
    assert get_in(tools_by_name, ["read_work_request", "inputSchema", "properties", "work_request_id", "type"]) == "string"
    assert get_in(tools_by_name, ["read_child_status", "inputSchema", "required"]) == ["work_package_id"]
    assert get_in(tools_by_name, ["read_child_status", "inputSchema", "properties", "work_package_id", "type"]) == "string"
    assert get_in(tools_by_name, ["read_phase_board", "inputSchema", "required"]) == ["phase_id"]
    assert get_in(tools_by_name, ["approve_scope_expansion", "inputSchema", "required"]) == ["work_package_id", "allowed_file_globs", "rationale"]
    assert get_in(tools_by_name, ["approve_scope_expansion", "inputSchema", "properties", "allowed_file_globs", "minItems"]) == 1
    assert get_in(tools_by_name, ["approve_child_ready_state", "inputSchema", "required"]) == ["work_package_id", "rationale"]
    assert get_in(tools_by_name, ["approve_child_ready_state", "inputSchema", "properties", "request_id", "type"]) == "string"
    assert get_in(tools_by_name, ["mint_child_worker_key", "inputSchema", "required"]) == ["work_package_id", "template"]
    assert get_in(tools_by_name, ["mint_child_worker_key", "inputSchema", "properties", "template", "type"]) == "object"
    assert get_in(tools_by_name, ["merge_child_into_phase", "inputSchema", "required"]) == ["work_package_id", "merge_artifact"]
    assert get_in(tools_by_name, ["merge_child_into_phase", "inputSchema", "properties", "merge_artifact", "required"]) == ["status", "uri"]
    assert get_in(tools_by_name, ["split_work_package", "inputSchema", "properties", "child_specs", "minItems"]) == 1
  end

  test "tools list hides WorkRequest reads for legacy architect sessions", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-WR-TOOLS-LEGACY", kind: "mcp"))
    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:work_request"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))
    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "legacy-architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools_by_name = response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "sympp.health")
    assert Map.has_key?(tools_by_name, "get_current_assignment")
    refute Map.has_key?(tools_by_name, "list_work_requests")
    refute Map.has_key?(tools_by_name, "read_work_request")
  end

  test "tools list hides WorkRequest reads when phase scope snapshot is missing", %{repo: repo} do
    {_anchor, session, grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-TOOLS-MISSING-SCOPE", [
        "read:work_request"
      ])

    repo.update_all(
      from(access_grant in AccessGrant, where: access_grant.id == ^grant.id),
      set: [scope_base_branch: nil]
    )

    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "missing-scope-architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools_by_name = response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    refute Map.has_key?(tools_by_name, "list_work_requests")
    refute Map.has_key?(tools_by_name, "read_work_request")
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

  test "stdio read errors keep expected disconnects graceful" do
    assert :ok = Stdio.handle_read_error(:terminated)
    assert :ok = Stdio.handle_read_error(:closed)

    assert_raise IO.StreamError, fn ->
      Stdio.handle_read_error(:eperm)
    end
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

  test "architect mutating tools require their specific grant capabilities", %{repo: repo} do
    {package, session} = create_architect_session(repo, "SYMPP-ARCHITECT-MUTATION-CAPABILITY", ["read:phase"])

    counts_before = {
      repo.aggregate(WorkPackage, :count),
      repo.aggregate(AccessGrant, :count),
      repo.aggregate(ProgressEvent, :count),
      repo.aggregate(Artifact, :count)
    }

    denied_calls = [
      {"create_child_work_package", %{"package" => %{"id" => "SYMPP-ARCHITECT-DENIED-CHILD", "title" => "Denied", "acceptance_criteria" => ["Denied"]}}},
      {"mint_child_worker_key", %{"work_package_id" => package.id, "template" => child_worker_template()}},
      {"revoke_child_worker_key", %{"grant_id" => "grant-denied", "reason" => "Denied"}},
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

  test "architect WorkRequest read tools are scoped, filtered, redacted, and read-only", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-READ", [
        "read:work_request"
      ])

    in_scope =
      create_work_request!(repo,
        id: "WR-MCP-WR-IN",
        title: "Read WorkRequests",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing",
        human_description: "Use Bearer raw-secret-value for validation",
        constraints: %{"safe" => "visible", "token" => "raw-secret-value"}
      )

    _other_repo =
      create_work_request!(repo,
        id: "WR-MCP-WR-OTHER-REPO",
        repo: "nextide/other",
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    other_branch =
      create_work_request!(repo,
        id: "WR-MCP-WR-OTHER-BRANCH",
        repo: anchor.repo,
        base_branch: "main",
        status: "ready_for_slicing"
      )

    _other_status =
      create_work_request!(repo,
        id: "WR-MCP-WR-OTHER-STATUS",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "draft"
      )

    assert {:ok, _open_question} =
             WorkRequestRepository.ask_question(repo, in_scope.id, work_request_question_attrs(id: "WRQ-MCP-WR-OPEN"))

    assert {:ok, answered_question} =
             WorkRequestRepository.ask_question(repo, in_scope.id, work_request_question_attrs(id: "WRQ-MCP-WR-ANSWERED"))

    assert {:ok, _answered} =
             WorkRequestRepository.answer_question(repo, answered_question.id, "open", %{
               answer: "Bearer raw-secret-value",
               answered_by: "operator-1"
             })

    assert {:ok, closed_question} =
             WorkRequestRepository.ask_question(repo, in_scope.id, work_request_question_attrs(id: "WRQ-MCP-WR-CLOSED"))

    assert {:ok, _closed} = WorkRequestRepository.close_question(repo, closed_question.id, "open")

    assert {:ok, _decision} =
             WorkRequestRepository.record_decision(
               repo,
               in_scope.id,
               work_request_decision_attrs(id: "WRD-MCP-WR-1", decision: "Use https://example.test/path?sig=raw-secret-value")
             )

    assert {:ok, _planned} = WorkRequestRepository.add_planned_slice(repo, in_scope.id, work_request_planned_slice_attrs(id: "WRS-MCP-WR-PLANNED"))
    assert {:ok, approved} = WorkRequestRepository.add_planned_slice(repo, in_scope.id, work_request_planned_slice_attrs(id: "WRS-MCP-WR-APPROVED"))
    assert {:ok, skipped} = WorkRequestRepository.add_planned_slice(repo, in_scope.id, work_request_planned_slice_attrs(id: "WRS-MCP-WR-SKIPPED"))
    repo.update!(Ecto.Changeset.change(approved, status: "approved"))
    repo.update!(Ecto.Changeset.change(skipped, status: "skipped"))

    counts_before = {
      repo.aggregate(WorkRequest, :count),
      repo.aggregate(WorkPackage, :count),
      repo.aggregate(AccessGrant, :count),
      repo.aggregate(ProgressEvent, :count),
      repo.aggregate(Artifact, :count)
    }

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    list_payload = get_in(list_response, ["result", "structuredContent"])

    assert list_payload["scope"] == %{"repo" => anchor.repo, "base_branch" => anchor.base_branch}
    assert list_payload["filters"] == %{"status" => "ready_for_slicing"}
    assert list_payload["total_count"] == 1

    assert [
             %{
               "id" => "WR-MCP-WR-IN",
               "title" => "Read WorkRequests",
               "repo" => "nextide/symphony-plus-plus",
               "base_branch" => "symphony-plus-plus/beta",
               "status" => "ready_for_slicing"
             } = listed_work_request
           ] = list_payload["work_requests"]

    refute Map.has_key?(listed_work_request, "open_question_count")
    refute Map.has_key?(listed_work_request, "decision_count")
    refute Map.has_key?(listed_work_request, "planned_slice_count")

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => in_scope.id})
    read_payload = get_in(read_response, ["result", "structuredContent"])

    assert read_payload["work_request"]["id"] == in_scope.id
    assert read_payload["work_request"]["constraints"]["safe"] == "visible"
    assert read_payload["work_request"]["constraints"]["token"] == "[REDACTED]"
    assert Enum.map(read_payload["clarification_questions"], & &1["id"]) == ["WRQ-MCP-WR-OPEN", "WRQ-MCP-WR-ANSWERED", "WRQ-MCP-WR-CLOSED"]
    assert Enum.at(read_payload["clarification_questions"], 1)["answer"] == "[REDACTED]"
    assert Enum.map(read_payload["decision_log_entries"], & &1["id"]) == ["WRD-MCP-WR-1"]
    assert Enum.at(read_payload["decision_log_entries"], 0)["decision"] =~ "[REDACTED]"
    assert Enum.map(read_payload["planned_slices"], & &1["id"]) == ["WRS-MCP-WR-PLANNED", "WRS-MCP-WR-APPROVED", "WRS-MCP-WR-SKIPPED"]
    assert Enum.at(read_payload["planned_slices"], 0)["review_lanes"] == ["review_t1", "[REDACTED]", "review_t2"]

    assert read_payload["summary"] == %{
             "open_question_count" => 1,
             "answered_question_count" => 1,
             "closed_question_count" => 1,
             "decision_count" => 1,
             "planned_slice_count" => 1,
             "approved_slice_count" => 1,
             "dispatched_slice_count" => 0,
             "skipped_slice_count" => 1
           }

    refute inspect(list_response) =~ "WR-MCP-WR-OTHER-REPO"
    refute inspect(read_response) =~ "raw-secret-value"

    out_of_scope_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => other_branch.id})

    assert get_in(out_of_scope_response, ["error", "code"]) == -32_004
    assert get_in(out_of_scope_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(out_of_scope_response) =~ other_branch.id

    assert {
             repo.aggregate(WorkRequest, :count),
             repo.aggregate(WorkPackage, :count),
             repo.aggregate(AccessGrant, :count),
             repo.aggregate(ProgressEvent, :count),
             repo.aggregate(Artifact, :count)
           } == counts_before
  end

  test "WorkRequest MCP reads require dedicated capability and fixed scope arguments", %{repo: repo} do
    {_package, insufficient_session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-AUTHZ", ["read:phase"])

    list_denied = mcp_tool(repo, insufficient_session, "list_work_requests", %{})
    assert get_in(list_denied, ["error", "code"]) == -32_001
    assert get_in(list_denied, ["error", "data", "reason"]) == "insufficient_capability"

    read_denied = mcp_tool(repo, insufficient_session, "read_work_request", %{"work_request_id" => "WR-MCP-WR-MISSING"})
    assert get_in(read_denied, ["error", "code"]) == -32_001
    assert get_in(read_denied, ["error", "data", "reason"]) == "insufficient_capability"

    {_package, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-STRICT", ["read:work_request"])

    repo_argument_response = mcp_tool(repo, session, "list_work_requests", %{"repo" => "nextide/other"})
    assert get_in(repo_argument_response, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(repo_argument_response, ["error", "data", "arguments"]) == ["repo"]

    branch_argument_response = mcp_tool(repo, session, "list_work_requests", %{"base_branch" => "other"})
    assert get_in(branch_argument_response, ["error", "data", "reason"]) == "unexpected_argument"
    assert get_in(branch_argument_response, ["error", "data", "arguments"]) == ["base_branch"]

    invalid_status_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "merged"})
    assert get_in(invalid_status_response, ["error", "data", "reason"]) == "invalid_status"
  end

  test "WorkRequest MCP reads reject legacy nil-phase architect grants", %{repo: repo} do
    {anchor, session} = create_architect_session(repo, "SYMPP-ARCHITECT-WR-LEGACY", ["read:work_request"])

    original_scope =
      create_work_request!(repo,
        id: "WR-MCP-WR-LEGACY-ORIGINAL",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-LEGACY-SIBLING",
        repo: "nextide/other",
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    repo.update!(Ecto.Changeset.change(anchor, repo: sibling.repo))

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    assert get_in(list_response, ["error", "code"]) == -32_003
    assert get_in(list_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(list_response) =~ original_scope.id
    refute inspect(list_response) =~ sibling.id

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => sibling.id})
    assert get_in(read_response, ["error", "code"]) == -32_003
    assert get_in(read_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(read_response) =~ sibling.id
  end

  test "WorkRequest MCP reads fail closed when architect scope snapshot is missing", %{repo: repo} do
    {_anchor, session, grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MISSING-SCOPE", [
        "read:work_request"
      ])

    repo.update_all(
      from(access_grant in AccessGrant, where: access_grant.id == ^grant.id),
      set: [scope_base_branch: nil]
    )

    list_response = mcp_tool(repo, session, "list_work_requests", %{})
    assert get_in(list_response, ["error", "code"]) == -32_003
    assert get_in(list_response, ["error", "data", "reason"]) == "outside_session_scope"

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => "WR-MCP-WR-IN"})
    assert get_in(read_response, ["error", "code"]) == -32_003
    assert get_in(read_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "WorkRequest MCP reads reject drifted architect scope snapshots", %{repo: repo} do
    {anchor, session, grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-DRIFTED-SCOPE", [
        "read:work_request"
      ])

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-DRIFTED-SIBLING",
        repo: "nextide/other",
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    repo.update_all(
      from(access_grant in AccessGrant, where: access_grant.id == ^grant.id),
      set: [scope_repo: sibling.repo]
    )

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    assert get_in(list_response, ["error", "code"]) == -32_003
    assert get_in(list_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(list_response) =~ sibling.id

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => sibling.id})
    assert get_in(read_response, ["error", "code"]) == -32_003
    assert get_in(read_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(read_response) =~ sibling.id
  end

  test "phase architect creates child work package inside scoped phase", %{repo: repo} do
    {anchor, session} =
      create_architect_session(repo, "SYMPP-P7-002-CREATE-ANCHOR", [
        "create:child_work_package",
        "read:phase"
      ])

    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-CREATED-CHILD",
          "title" => "Implement child lane",
          "acceptance_criteria" => ["Child lane complete"],
          "allowed_file_globs" => ["./elixir\\lib\\symphony_elixir/**"]
        }
      })

    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) == "SYMPP-P7-002-CREATED-CHILD"
    assert get_in(response, ["result", "structuredContent", "work_package", "kind"]) == "phase_child"
    assert get_in(response, ["result", "structuredContent", "work_package", "phase_id"]) == @architect_phase_id
    assert get_in(response, ["result", "structuredContent", "work_package", "parent_id"]) == anchor.id
    assert get_in(response, ["result", "structuredContent", "work_package", "base_branch"]) == "symphony-plus-plus/beta"
    assert get_in(response, ["result", "structuredContent", "work_package", "repo"]) == "nextide/symphony-plus-plus"

    assert {:ok, child} = WorkPackageRepository.get(repo, "SYMPP-P7-002-CREATED-CHILD")
    assert child.status == "ready_for_worker"
    assert child.policy_template == "phase_child"
    assert child.allowed_file_globs == ["elixir/lib/symphony_elixir/**"]
  end

  test "phase architect with delegation-only capabilities can create, mint, and read child", %{repo: repo} do
    {anchor, session, grant} =
      create_phase_architect_session(repo, "SYMPP-P7-002-DELEGATION-ONLY-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:child_progress",
        "read:child_findings"
      ])

    assert grant.phase_id == @architect_phase_id
    assert grant.scope_repo == anchor.repo
    assert grant.scope_base_branch == anchor.base_branch

    child_id = create_child_work_package(repo, session, "SYMPP-P7-002-DELEGATION-ONLY-CHILD")

    mint_response =
      mcp_tool(repo, session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    assert get_in(mint_response, ["result", "structuredContent", "worker_grant", "work_package_id"]) == child_id

    status_response = mcp_tool(repo, session, "read_child_status", %{"work_package_id" => child_id})

    assert get_in(status_response, ["result", "structuredContent", "work_package", "id"]) == child_id
    assert get_in(status_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_worker"
  end

  test "phase architect cannot create child outside scoped phase or base branch", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(repo, "SYMPP-P7-002-CREATE-SCOPE-ANCHOR", [
        "create:child_work_package",
        "read:phase"
      ])

    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-p7-002-outside", title: "Outside phase"})

    out_of_phase_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-OUT-OF-PHASE",
          "title" => "Invalid child",
          "phase_id" => other_phase.id,
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(out_of_phase_response, ["error", "code"]) == -32_003
    assert get_in(out_of_phase_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-OUT-OF-PHASE")

    wrong_base_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-WRONG-BASE",
          "title" => "Wrong base",
          "base_branch" => "main",
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(wrong_base_response, ["error", "code"]) == -32_602
    assert get_in(wrong_base_response, ["error", "data", "reason"]) == "base_branch_scope_mismatch"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-WRONG-BASE")

    empty_globs_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-EMPTY-GLOBS",
          "title" => "Empty globs",
          "allowed_file_globs" => [],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(empty_globs_response, ["error", "code"]) == -32_602
    assert get_in(empty_globs_response, ["error", "data", "reason"]) == "missing_allowed_file_globs"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-EMPTY-GLOBS")
  end

  test "phase architect with empty anchor globs requires explicit child file scope", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-EMPTY-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: []
      )

    inherited_empty_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-INHERITED-EMPTY-GLOBS",
          "title" => "Inherited empty globs",
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(inherited_empty_response, ["error", "code"]) == -32_602
    assert get_in(inherited_empty_response, ["error", "data", "reason"]) == "missing_allowed_file_globs"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-INHERITED-EMPTY-GLOBS")

    explicit_empty_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-EXPLICIT-EMPTY-GLOBS",
          "title" => "Explicit empty globs",
          "allowed_file_globs" => [],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(explicit_empty_response, ["error", "code"]) == -32_602
    assert get_in(explicit_empty_response, ["error", "data", "reason"]) == "missing_allowed_file_globs"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-EXPLICIT-EMPTY-GLOBS")

    explicit_scope_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-UNBOUNDED-EXPLICIT-GLOBS",
          "title" => "Explicit globs without anchor scope",
          "allowed_file_globs" => ["elixir/lib/**"],
          "acceptance_criteria" => ["Child carries concrete file scope"]
        }
      })

    assert get_in(explicit_scope_response, ["result", "structuredContent", "work_package", "id"]) ==
             "SYMPP-P7-002-UNBOUNDED-EXPLICIT-GLOBS"

    assert {:ok, child} = WorkPackageRepository.get(repo, "SYMPP-P7-002-UNBOUNDED-EXPLICIT-GLOBS")
    assert child.allowed_file_globs == ["elixir/lib/**"]
  end

  test "phase architect child delegation fails closed after anchor repo or base branch drift", %{repo: repo} do
    for {field, drifted_value, suffix} <- [
          {:base_branch, "main", "BASE"},
          {:repo, "nextide/other", "REPO"}
        ] do
      {anchor, session} =
        create_architect_session(repo, "SYMPP-P7-002-#{suffix}-DRIFT-ANCHOR", [
          "create:child_work_package",
          "mint:child_worker_key",
          "read:phase"
        ])

      child_id = create_child_work_package(repo, session, "SYMPP-P7-002-#{suffix}-DRIFT-CHILD")
      assert {:ok, _anchor} = WorkPackageRepository.update(repo, anchor.id, Map.put(%{}, field, drifted_value))

      create_response =
        mcp_tool(repo, session, "create_child_work_package", %{
          "package" => %{
            "id" => "SYMPP-P7-002-#{suffix}-DRIFT-NEW-CHILD",
            "title" => "Drifted anchor child",
            "acceptance_criteria" => ["Should not be created"]
          }
        })

      assert get_in(create_response, ["error", "code"]) == -32_003
      assert get_in(create_response, ["error", "data", "reason"]) == "outside_session_scope"
      assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-#{suffix}-DRIFT-NEW-CHILD")

      grants_before = repo.aggregate(AccessGrant, :count)

      mint_response =
        mcp_tool(repo, session, "mint_child_worker_key", %{
          "work_package_id" => child_id,
          "template" => child_worker_template()
        })

      assert get_in(mint_response, ["error", "code"]) == -32_003
      assert get_in(mint_response, ["error", "data", "reason"]) == "outside_session_scope"
      assert repo.aggregate(AccessGrant, :count) == grants_before
    end
  end

  test "phase architect child delegation fails closed when frozen scope snapshot is missing", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(repo, "SYMPP-P7-002-MISSING-SNAPSHOT-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, session, "SYMPP-P7-002-MISSING-SNAPSHOT-CHILD")

    repo.query!(
      "UPDATE sympp_access_grants SET scope_repo = NULL, scope_base_branch = NULL WHERE id = ?",
      [session.assignment.grant_id]
    )

    create_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-MISSING-SNAPSHOT-NEW-CHILD",
          "title" => "Missing snapshot child",
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(create_response, ["error", "code"]) == -32_003
    assert get_in(create_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-MISSING-SNAPSHOT-NEW-CHILD")

    grants_before = repo.aggregate(AccessGrant, :count)

    mint_response =
      mcp_tool(repo, session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    assert get_in(mint_response, ["error", "code"]) == -32_003
    assert get_in(mint_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert repo.aggregate(AccessGrant, :count) == grants_before

    status_response = mcp_tool(repo, session, "read_child_status", %{"work_package_id" => child_id})

    assert get_in(status_response, ["error", "code"]) == -32_003
    assert get_in(status_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "phase architect read_child_status fails closed for missing child IDs", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(repo, "SYMPP-P7-002-MISSING-STATUS-ANCHOR", [
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    response = mcp_tool(repo, session, "read_child_status", %{"work_package_id" => "SYMPP-P7-002-MISSING-STATUS-CHILD"})

    assert get_in(response, ["error", "code"]) == -32_003
    assert get_in(response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "legacy nil-phase architect grant cannot use child delegation or status", %{repo: repo} do
    phase_id = ensure_architect_phase(repo)

    {anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-NIL-PHASE-ANCHOR",
        [
          "create:child_work_package",
          "mint:child_worker_key",
          "read:child_progress",
          "read:child_findings"
        ],
        phase_id: phase_id
      )

    assert is_nil(session.assignment.phase_id)

    assert {:ok, child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-NIL-PHASE-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: phase_id,
                 parent_id: anchor.id,
                 base_branch: anchor.base_branch,
                 repo: anchor.repo,
                 status: "ready_for_worker"
               )
             )

    create_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-NIL-PHASE-NEW-CHILD",
          "title" => "Nil phase child",
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(create_response, ["error", "code"]) == -32_003
    assert get_in(create_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-NIL-PHASE-NEW-CHILD")

    grants_before = repo.aggregate(AccessGrant, :count)

    mint_response =
      mcp_tool(repo, session, "mint_child_worker_key", %{
        "work_package_id" => child.id,
        "template" => child_worker_template()
      })

    assert get_in(mint_response, ["error", "code"]) == -32_003
    assert get_in(mint_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert repo.aggregate(AccessGrant, :count) == grants_before

    status_response = mcp_tool(repo, session, "read_child_status", %{"work_package_id" => child.id})

    assert get_in(status_response, ["error", "code"]) == -32_003
    assert get_in(status_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "phase architect child creation revalidates anchor scope inside insert transaction", %{repo: repo} do
    {anchor, session} =
      create_architect_session(repo, "SYMPP-P7-002-CREATE-RACE-ANCHOR", [
        "create:child_work_package",
        "read:phase"
      ])

    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-p7-002-create-race", title: "Create race"})
    CreateChildAnchorRaceRepo.arm(anchor.id, %{phase_id: other_phase.id})

    response =
      try do
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "create_child_work_package",
            "method" => "tools/call",
            "params" => %{
              "name" => "create_child_work_package",
              "arguments" => %{
                "package" => %{
                  "id" => "SYMPP-P7-002-CREATE-RACE-CHILD",
                  "title" => "Create race child",
                  "acceptance_criteria" => ["Should not be created"]
                }
              }
            }
          },
          config: Config.default(repo: CreateChildAnchorRaceRepo),
          session: session
        )
      after
        CreateChildAnchorRaceRepo.disarm()
      end

    assert get_in(response, ["error", "code"]) == -32_003
    assert get_in(response, ["error", "data", "reason"]) == "outside_session_scope"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-CREATE-RACE-CHILD")
  end

  test "phase architect cannot create child work package with blank scoped fields", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(repo, "SYMPP-P7-002-BLANK-SCOPE-ANCHOR", [
        "create:child_work_package",
        "read:phase"
      ])

    blank_scope_cases = [
      {"phase_id", " ", "invalid_phase_id"},
      {"parent_id", "null", "invalid_parent_id"},
      {"repo", "", "invalid_repo"},
      {"base_branch", " NULL ", "invalid_base_branch"}
    ]

    for {key, value, reason} <- blank_scope_cases do
      child_id = "SYMPP-P7-002-BLANK-" <> (key |> String.replace("_", "-") |> String.upcase())

      response =
        mcp_tool(repo, session, "create_child_work_package", %{
          "package" => %{
            "id" => child_id,
            "title" => "Blank scoped field",
            "acceptance_criteria" => ["Should not be created"],
            key => value
          }
        })

      assert get_in(response, ["error", "code"]) == -32_602
      assert get_in(response, ["error", "data", "reason"]) == reason
      assert {:error, :not_found} = WorkPackageRepository.get(repo, child_id)
    end
  end

  test "phase architect can narrow child globs under supported non-prefix anchor globs", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-GLOB-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: ["elixir/**/*.ex"]
      )

    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-CHILD",
          "title" => "Narrow glob child",
          "allowed_file_globs" => ["elixir/lib/**/*.ex"],
          "acceptance_criteria" => ["Child scope stays inside anchor glob"]
        }
      })

    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) == "SYMPP-P7-002-GLOB-CHILD"
    assert {:ok, child} = WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-CHILD")
    assert child.allowed_file_globs == ["elixir/lib/**/*.ex"]
  end

  test "phase architect child glob scope rejects traversal and invalid broadening", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-GLOB-SCOPE-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: ["elixir/lib/foo/*.ex"]
      )

    traversal_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-TRAVERSAL",
          "title" => "Traversal child",
          "allowed_file_globs" => ["elixir/lib/../../priv/**"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(traversal_response, ["error", "code"]) == -32_602
    assert get_in(traversal_response, ["error", "data", "reason"]) == "path_traversal_allowed_file_globs"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-TRAVERSAL")

    encoded_traversal_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-ENCODED-TRAVERSAL",
          "title" => "Encoded traversal child",
          "allowed_file_globs" => ["elixir/lib/%2e%2e/priv/**"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(encoded_traversal_response, ["error", "data", "reason"]) == "path_traversal_allowed_file_globs"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-ENCODED-TRAVERSAL")

    encoded_slash_traversal_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-ENCODED-SLASH-TRAVERSAL",
          "title" => "Encoded slash traversal child",
          "allowed_file_globs" => ["elixir/lib%2f..%2fpriv/**"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(encoded_slash_traversal_response, ["error", "data", "reason"]) ==
             "path_traversal_allowed_file_globs"

    assert {:error, :not_found} =
             WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-ENCODED-SLASH-TRAVERSAL")

    broadening_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-BROADENING",
          "title" => "Broadening child",
          "allowed_file_globs" => ["elixir/*/foo/*.ex"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(broadening_response, ["error", "code"]) == -32_602
    assert get_in(broadening_response, ["error", "data", "reason"]) == "child_scope_outside_phase"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-BROADENING")
  end

  test "phase architect child glob scope rejects encoded backslash traversal", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-ENCODED-BACKSLASH-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: ["elixir/**"]
      )

    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-ENCODED-BACKSLASH-TRAVERSAL",
          "title" => "Encoded backslash traversal child",
          "allowed_file_globs" => ["elixir/lib%5c..%5cpriv/**"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "path_traversal_allowed_file_globs"

    assert {:error, :not_found} =
             WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-ENCODED-BACKSLASH-TRAVERSAL")
  end

  test "phase architect child glob scope rejects encoded separator broadening", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-ENCODED-SEPARATOR-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: ["elixir/*"]
      )

    encoded_slash_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-ENCODED-SLASH-BROADENING",
          "title" => "Encoded slash broadening child",
          "allowed_file_globs" => ["elixir/lib%2fsecret"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(encoded_slash_response, ["error", "code"]) == -32_602
    assert get_in(encoded_slash_response, ["error", "data", "reason"]) == "invalid_allowed_file_globs"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-ENCODED-SLASH-BROADENING")

    encoded_backslash_response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-ENCODED-BACKSLASH-BROADENING",
          "title" => "Encoded backslash broadening child",
          "allowed_file_globs" => ["elixir/lib%5csecret"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(encoded_backslash_response, ["error", "code"]) == -32_602
    assert get_in(encoded_backslash_response, ["error", "data", "reason"]) == "invalid_allowed_file_globs"

    assert {:error, :not_found} =
             WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-ENCODED-BACKSLASH-BROADENING")
  end

  test "phase architect child glob scope rejects child double-star missing required anchor suffix", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-GLOB-SUFFIX-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: ["foo/**/bar"]
      )

    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-GLOB-MISSING-SUFFIX",
          "title" => "Missing suffix child",
          "allowed_file_globs" => ["foo/**"],
          "acceptance_criteria" => ["Should not be created"]
        }
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "child_scope_outside_phase"
    assert {:error, :not_found} = WorkPackageRepository.get(repo, "SYMPP-P7-002-GLOB-MISSING-SUFFIX")
  end

  test "phase architect can narrow wildcard child globs inside wildcard anchor globs", %{repo: repo} do
    {_anchor, session} =
      create_architect_session(
        repo,
        "SYMPP-P7-002-WILDCARD-ANCHOR",
        ["create:child_work_package", "read:phase"],
        allowed_file_globs: ["elixir/*/foo/*.ex"]
      )

    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => "SYMPP-P7-002-WILDCARD-CHILD",
          "title" => "Wildcard narrowed child",
          "allowed_file_globs" => ["elixir/lib/foo/*.ex"],
          "acceptance_criteria" => ["Child wildcard scope stays inside anchor glob"]
        }
      })

    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) == "SYMPP-P7-002-WILDCARD-CHILD"
    assert {:ok, child} = WorkPackageRepository.get(repo, "SYMPP-P7-002-WILDCARD-CHILD")
    assert child.allowed_file_globs == ["elixir/lib/foo/*.ex"]
  end

  test "phase architect mints child worker grant and worker is isolated to child package", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-CHILD")
    sibling_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-SIBLING")

    mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    assert get_in(mint_response, ["result", "structuredContent", "worker_grant", "work_package_id"]) == child_id
    assert get_in(mint_response, ["result", "structuredContent", "worker_grant", "grant_role"]) == "worker"

    assert get_in(mint_response, ["result", "structuredContent", "worker_grant", "capabilities"]) == [
             "worker:claim",
             "worker:lifecycle.transition"
           ]

    worker_grant = get_in(mint_response, ["result", "structuredContent", "worker_grant"])
    refute Map.has_key?(worker_grant, "secret")
    refute Map.has_key?(worker_grant, "secret_returned_once")
    assert worker_grant["secret_in_response"] == false
    assert worker_grant["secret_handoff"]["status"] == "stored"
    assert worker_grant["secret_handoff"]["secret_in_stdout"] == false
    assert worker_grant["secret_handoff"]["claimed_by"] == "sympp-child-worker:#{child_id}"
    assert is_binary(worker_grant["secret_handoff"]["run_mcp_command"])
    assert worker_grant["secret_handoff"]["run_mcp_command"] =~ "sympp-child-worker:#{child_id}"
    assert handoff_secret_absent?(worker_grant["secret_handoff"], worker_grant["secret_handoff"]["run_mcp_command"])
    refute Map.has_key?(worker_grant["secret_handoff"], "tradeoff")

    content_text = get_in(mint_response, ["result", "content", Access.at(0), "text"])
    refute content_text =~ ~s("secret":)
    refute content_text =~ "secret_returned_once"
    assert content_text =~ "run_mcp_command"
    assert content_text =~ "sympp-child-worker:#{child_id}"
    assert handoff_secret_absent?(worker_grant["secret_handoff"], content_text)

    assert [metadata_path] = Path.wildcard(Path.join([test_handoff_store_dir(), "metadata", "handoff-*.json"]))
    metadata_content = File.read!(metadata_path)
    assert {:ok, metadata} = Jason.decode(metadata_content)
    assert metadata["work_package_id"] == child_id
    assert metadata["worker_grant_id"] == worker_grant["id"]
    assert handoff_secret_absent?(worker_grant["secret_handoff"], metadata_content)
    refute Map.has_key?(metadata, "secret")
    refute Map.has_key?(metadata, "claimed_by")
    refute Map.has_key?(metadata, "run_mcp_command")

    worker_session = claim_child_worker_from_mint_response(repo, mint_response, worker_grant["secret_handoff"]["claimed_by"])

    assignment_response = mcp_tool(repo, worker_session, "get_current_assignment", %{})
    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == child_id
    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "phase_id"]) == nil

    own_resource_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "read-child-task-plan",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/#{child_id}/task_plan.md"}
        },
        repo: repo,
        session: worker_session
      )

    assert get_in(own_resource_response, ["result", "contents", Access.at(0), "text"]) =~ child_id

    sibling_resource_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "read-sibling-task-plan",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/#{sibling_id}/task_plan.md"}
        },
        repo: repo,
        session: worker_session
      )

    assert get_in(sibling_resource_response, ["error", "code"]) == -32_003
    assert get_in(sibling_resource_response, ["error", "data", "reason"]) == "outside_session_scope"

    child_status_response =
      mcp_tool(repo, architect_session, "read_child_status", %{"work_package_id" => child_id})

    assert get_in(child_status_response, ["result", "structuredContent", "work_package", "id"]) == child_id
    assert get_in(child_status_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_worker"
  end

  test "child worker key handoff bootstraps MCP through Windows Credential Manager", %{repo: repo} do
    if windows?() do
      {_anchor, architect_session} =
        create_architect_session(repo, "SYMPP-P7-002-MINT-WINCRED-ANCHOR", [
          "create:child_work_package",
          "mint:child_worker_key",
          "read:phase"
        ])

      child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-WINCRED-CHILD")

      mint_response =
        mcp_tool(repo, architect_session, "mint_child_worker_key", %{
          "work_package_id" => child_id,
          "template" => child_worker_template(%{"mode" => "windows-credential-manager"})
        })

      worker_grant = get_in(mint_response, ["result", "structuredContent", "worker_grant"])
      handoff = Map.fetch!(worker_grant, "secret_handoff")
      claimed_by = Map.fetch!(handoff, "claimed_by")

      assert worker_grant["secret_in_response"] == false
      refute Map.has_key?(worker_grant, "secret")
      refute Map.has_key?(worker_grant, "secret_returned_once")
      assert handoff["mode"] == "windows-credential-manager"
      assert is_binary(handoff["target"])
      assert claimed_by == "sympp-child-worker:#{child_id}"
      assert is_binary(handoff["run_mcp_command"])
      assert handoff["run_mcp_command"] =~ handoff["target"]
      assert handoff["run_mcp_command"] =~ claimed_by

      try do
        input =
          [
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize", "params" => initialize_params()}),
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => "health",
              "method" => "tools/call",
              "params" => %{"name" => "sympp.health", "arguments" => %{}}
            }),
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => "assignment",
              "method" => "resources/read",
              "params" => %{"uri" => "sympp://assignment/current"}
            })
          ]
          |> Enum.join("\n")
          |> Kernel.<>("\n")

        {output, status} =
          run_mcp_with_windows_credential_handoff(
            handoff,
            claimed_by,
            current_main_database_path(repo),
            input
          )

        assert status == 0, output
        refute output =~ ~s("secret")
        refute output =~ "SYMPP_WORK_KEY_SECRET"

        responses = decode_json_objects_from_mixed_output(output)
        response_summary = json_rpc_response_summary(responses)
        health_response = Enum.find(responses, &(Map.get(&1, "id") == "health"))
        assignment_response = Enum.find(responses, &(Map.get(&1, "id") == "assignment"))

        assert health_response, inspect(response_summary)
        assert assignment_response, inspect(response_summary)

        assignment_text = get_in(assignment_response, ["result", "contents", Access.at(0), "text"])
        assert is_binary(assignment_text), inspect(response_summary)
        assignment = Jason.decode!(assignment_text)

        assert get_in(health_response, ["result", "structuredContent", "status"]) == "ok"
        assert get_in(health_response, ["result", "structuredContent", "ledger"]) == %{"reachable" => true}
        assert assignment["work_package_id"] == child_id
        assert assignment["claimed_by"] == claimed_by

        assert {:ok, claimed_grant} = AccessGrantRepository.get(repo, worker_grant["id"])
        assert claimed_grant.claimed_by == claimed_by
        assert %DateTime{} = claimed_grant.claimed_at
      after
        cleanup_child_worker_handoff(handoff, claimed_by)
      end
    else
      assert test_secret_handoff_mode() == "local-private-file"
    end
  end

  test "child worker key minting ignores normal worker grants when checking active child mint", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-NORMAL-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-NORMAL-CHILD")

    assert {:ok, pending_normal} = AccessGrantService.mint_worker_grant(repo, child_id)
    assert pending_normal.grant.provenance == nil

    assert {:ok, claimed_normal} = AccessGrantService.mint_worker_grant(repo, child_id)
    assert claimed_normal.grant.provenance == nil
    assert {:ok, _normal_assignment} = AccessGrantService.claim(repo, claimed_normal.work_key.secret, claimed_by: "normal-worker")

    mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    child_worker_grant_id = get_in(mint_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(child_worker_grant_id)

    assert {:ok, child_worker_grant} = AccessGrantRepository.get(repo, child_worker_grant_id)
    assert child_worker_grant.provenance == @child_worker_grant_provenance

    remint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    assert get_in(remint_response, ["error", "code"]) == -32_602
    assert get_in(remint_response, ["error", "data", "reason"]) == "active_child_worker_grant_exists"

    assert {:ok, pending_normal_grant} = AccessGrantRepository.get(repo, pending_normal.grant.id)
    assert pending_normal_grant.revoked_at == nil
    assert pending_normal_grant.claimed_at == nil
    assert pending_normal_grant.provenance == nil

    assert {:ok, claimed_normal_grant} = AccessGrantRepository.get(repo, claimed_normal.grant.id)
    assert claimed_normal_grant.revoked_at == nil
    assert %DateTime{} = claimed_normal_grant.claimed_at
    assert claimed_normal_grant.provenance == nil

    assert {:ok, active_child_worker_grant} = AccessGrantRepository.get(repo, child_worker_grant_id)
    assert active_child_worker_grant.revoked_at == nil
    assert active_child_worker_grant.claimed_at == nil
    assert active_child_worker_grant.provenance == @child_worker_grant_provenance
  end

  test "child worker key minting rejects remint while active child worker grant exists", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-DUPLICATE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-DUPLICATE-CHILD")

    first_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    first_grant_id = get_in(first_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(first_grant_id)
    assert get_in(first_response, ["result", "structuredContent", "worker_grant", "secret_in_response"]) == false
    grants_before_remint = repo.aggregate(AccessGrant, :count)

    second_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    assert get_in(second_response, ["error", "code"]) == -32_602
    assert get_in(second_response, ["error", "data", "reason"]) == "active_child_worker_grant_exists"
    assert repo.aggregate(AccessGrant, :count) == grants_before_remint

    assert {:ok, first_grant} = AccessGrantRepository.get(repo, first_grant_id)
    assert first_grant.provenance == @child_worker_grant_provenance
    assert first_grant.revoked_at == nil
    assert first_grant.claimed_at == nil

    _worker_session = claim_child_worker_from_mint_response(repo, first_response, "worker-1")
    grants_before_claimed_remint = repo.aggregate(AccessGrant, :count)

    third_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    assert get_in(third_response, ["error", "code"]) == -32_602
    assert get_in(third_response, ["error", "data", "reason"]) == "active_child_worker_grant_exists"
    assert repo.aggregate(AccessGrant, :count) == grants_before_claimed_remint

    assert {:ok, claimed_grant} = AccessGrantRepository.get(repo, first_grant_id)
    assert claimed_grant.revoked_at == nil
    assert %DateTime{} = claimed_grant.claimed_at
    assert claimed_grant.provenance == @child_worker_grant_provenance
  end

  test "child worker key minting rejects broader grants and worker callers", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-BROADER-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-BROADER-CHILD")

    broader_capability_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => %{"capabilities" => ["worker:claim", "read:phase"]}
      })

    assert get_in(broader_capability_response, ["error", "code"]) == -32_602
    assert get_in(broader_capability_response, ["error", "data", "reason"]) == "broader_child_grant"

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, child_id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: minted.grant.secret_hash)

    worker_mint_response =
      mcp_tool(repo, worker_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    assert get_in(worker_mint_response, ["error", "code"]) == -32_001
    assert get_in(worker_mint_response, ["error", "data", "reason"]) == "architect_grant_required"
  end

  test "child worker key minting validates private handoff template narrowly", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-HANDOFF-TEMPLATE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-HANDOFF-TEMPLATE-CHILD")

    invalid_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template(%{"claimed_by" => "  "})
      })

    assert get_in(invalid_response, ["error", "code"]) == -32_602
    assert get_in(invalid_response, ["error", "data", "reason"]) == "invalid_secret_handoff"

    unexpected_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template(%{"env_var" => "SYMPP_OTHER_SECRET"})
      })

    assert get_in(unexpected_response, ["error", "code"]) == -32_602
    assert get_in(unexpected_response, ["error", "data", "reason"]) == "unexpected_secret_handoff_field"
    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, child_id)
    assert active_worker_grants(grants) == []
  end

  test "child worker key minting requires configured repo_root for private handoff", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-MISSING-ROOT-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-MISSING-ROOT-CHILD")

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "mint_child_worker_key",
          "method" => "tools/call",
          "params" => %{
            "name" => "mint_child_worker_key",
            "arguments" => %{"work_package_id" => child_id, "template" => child_worker_template()}
          }
        },
        config: Config.default(repo: repo),
        session: architect_session
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "missing_repo_root"

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, child_id)
    assert Enum.filter(grants, &(&1.provenance == @child_worker_grant_provenance)) == []
    assert active_worker_grants(grants) == []
  end

  test "child worker key minting validates repo_root contains handoff script before minting", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-BAD-ROOT-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-BAD-ROOT-CHILD")
    bad_repo_root = Path.join(System.tmp_dir!(), "sympp-missing-handoff-script-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bad_repo_root)

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "mint_child_worker_key",
          "method" => "tools/call",
          "params" => %{
            "name" => "mint_child_worker_key",
            "arguments" => %{"work_package_id" => child_id, "template" => child_worker_template()}
          }
        },
        config: Config.default(repo: repo, repo_root: bad_repo_root),
        session: architect_session
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "invalid_repo_root"

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, child_id)
    assert Enum.filter(grants, &(&1.provenance == @child_worker_grant_provenance)) == []
    assert active_worker_grants(grants) == []
  end

  test "child worker key minting rolls back the new grant when private handoff storage or metadata fails", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-HANDOFF-FAIL-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-HANDOFF-FAIL-CHILD")
    bad_store_dir = Path.join(test_handoff_store_dir(), "not-a-directory")
    File.mkdir_p!(Path.dirname(bad_store_dir))
    File.write!(bad_store_dir, "blocks handoff directory creation")

    response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template(%{"store_dir" => bad_store_dir})
      })

    assert get_in(response, ["error", "code"]) == -32_602
    reason = get_in(response, ["error", "data", "reason"])
    assert is_binary(reason)
    refute reason =~ ~s("secret":)

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, child_id)
    child_delegated_grants = Enum.filter(grants, &(&1.provenance == @child_worker_grant_provenance))
    assert child_delegated_grants == []
    assert active_worker_grants(grants) == []

    metadata_failure_child_id =
      create_child_work_package(repo, architect_session, "SYMPP-P7-002-HANDOFF-METADATA-FAIL-CHILD")

    metadata_failure_store_dir = Path.join(test_handoff_store_dir(), "metadata-failure")
    File.rm_rf!(metadata_failure_store_dir)
    File.mkdir_p!(metadata_failure_store_dir)
    File.write!(Path.join(metadata_failure_store_dir, "metadata"), "blocks managed metadata directory")

    metadata_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => metadata_failure_child_id,
        "template" => child_worker_template(%{"store_dir" => metadata_failure_store_dir})
      })

    assert get_in(metadata_response, ["error", "code"]) == -32_602
    metadata_reason = get_in(metadata_response, ["error", "data", "reason"])
    assert is_binary(metadata_reason)
    assert metadata_reason =~ "secret handoff metadata"
    assert metadata_reason =~ "new_handoff_cleanup="
    refute metadata_reason =~ ~s("secret":)

    assert {:ok, metadata_failure_grants} = AccessGrantRepository.list_for_work_package(repo, metadata_failure_child_id)
    assert Enum.filter(metadata_failure_grants, &(&1.provenance == @child_worker_grant_provenance)) == []
    assert active_worker_grants(metadata_failure_grants) == []
  end

  test "child worker key minting rejects child packages not ready for worker", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-NOT-READY-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-NOT-READY-CHILD")
    assert {:ok, _child} = WorkPackageRepository.update(repo, child_id, %{status: "claimed"})

    grants_before = repo.aggregate(AccessGrant, :count)

    response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "child_not_ready_for_worker"
    assert repo.aggregate(AccessGrant, :count) == grants_before
  end

  test "child worker key minting revalidates ready state inside the mint transaction", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-RACE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-RACE-CHILD")
    grants_before = repo.aggregate(AccessGrant, :count)
    MintReadyRaceRepo.arm(child_id)

    response =
      try do
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "mint_child_worker_key",
            "method" => "tools/call",
            "params" => %{
              "name" => "mint_child_worker_key",
              "arguments" => %{"work_package_id" => child_id, "template" => child_worker_template()}
            }
          },
          config: test_mcp_config(MintReadyRaceRepo),
          session: architect_session
        )
      after
        MintReadyRaceRepo.disarm()
      end

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "child_not_ready_for_worker"
    assert repo.aggregate(AccessGrant, :count) == grants_before

    assert {:ok, child} = WorkPackageRepository.get(repo, child_id)
    assert child.status == "ready_for_worker"
  end

  test "child worker key minting revalidates child scope after ready-state guard", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-SCOPE-RACE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-SCOPE-RACE-CHILD")

    assert {:ok, sibling_anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-SCOPE-RACE-SIBLING",
                 kind: "mcp",
                 phase_id: @architect_phase_id,
                 base_branch: anchor.base_branch,
                 repo: anchor.repo,
                 status: "planning"
               )
             )

    grants_before = repo.aggregate(AccessGrant, :count)
    MintChildScopeRaceRepo.arm(child_id, %{parent_id: sibling_anchor.id})

    response =
      try do
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "mint_child_worker_key",
            "method" => "tools/call",
            "params" => %{
              "name" => "mint_child_worker_key",
              "arguments" => %{"work_package_id" => child_id, "template" => child_worker_template()}
            }
          },
          config: test_mcp_config(MintChildScopeRaceRepo),
          session: architect_session
        )
      after
        MintChildScopeRaceRepo.disarm()
      end

    assert get_in(response, ["error", "code"]) == -32_003
    assert get_in(response, ["error", "data", "reason"]) == "outside_session_scope"
    assert repo.aggregate(AccessGrant, :count) == grants_before

    assert {:ok, child} = WorkPackageRepository.get(repo, child_id)
    assert child.parent_id == anchor.id
  end

  test "child worker key minting rejects revoked or expired parent architect grant inside transaction", %{repo: repo} do
    for {suffix, grant_update, expected_reason} <- [
          {"REVOKED", %{revoked_at: DateTime.utc_now(:microsecond)}, "revoked"},
          {"EXPIRED", %{expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)}, "expired"}
        ] do
      {_anchor, architect_session} =
        create_architect_session(repo, "SYMPP-P7-002-MINT-PARENT-#{suffix}-ANCHOR", [
          "create:child_work_package",
          "mint:child_worker_key",
          "read:phase"
        ])

      child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-PARENT-#{suffix}-CHILD")
      grants_before = repo.aggregate(AccessGrant, :count)
      MintParentGrantRaceRepo.arm(architect_session.assignment.grant_id, grant_update)

      response =
        try do
          MCPHarness.request(
            %{
              "jsonrpc" => "2.0",
              "id" => "mint_child_worker_key",
              "method" => "tools/call",
              "params" => %{
                "name" => "mint_child_worker_key",
                "arguments" => %{"work_package_id" => child_id, "template" => child_worker_template()}
              }
            },
            config: test_mcp_config(MintParentGrantRaceRepo),
            session: architect_session
          )
        after
          MintParentGrantRaceRepo.disarm()
        end

      assert get_in(response, ["error", "code"]) == -32_001
      assert get_in(response, ["error", "data", "reason"]) == expected_reason
      assert repo.aggregate(AccessGrant, :count) == grants_before
    end
  end

  test "child worker key minting uses transaction-current parent architect expiry", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-PARENT-SHORTENED-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-PARENT-SHORTENED-CHILD")
    shortened_expires_at = DateTime.utc_now(:microsecond) |> DateTime.add(60, :second) |> DateTime.truncate(:microsecond)
    MintParentGrantRaceRepo.arm(architect_session.assignment.grant_id, %{expires_at: shortened_expires_at})

    response =
      try do
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "mint_child_worker_key",
            "method" => "tools/call",
            "params" => %{
              "name" => "mint_child_worker_key",
              "arguments" => %{"work_package_id" => child_id, "template" => child_worker_template()}
            }
          },
          config: test_mcp_config(MintParentGrantRaceRepo),
          session: architect_session
        )
      after
        MintParentGrantRaceRepo.disarm()
      end

    assert get_in(response, ["result", "structuredContent", "worker_grant", "work_package_id"]) == child_id
    minted_expires_at = get_in(response, ["result", "structuredContent", "worker_grant", "expires_at"])
    assert {:ok, minted_expires_at, _offset} = DateTime.from_iso8601(minted_expires_at)
    assert DateTime.compare(DateTime.truncate(minted_expires_at, :microsecond), shortened_expires_at) != :gt

    {_anchor, broader_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-PARENT-SHORT-BROAD-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    broader_child_id = create_child_work_package(repo, broader_session, "SYMPP-P7-002-MINT-PARENT-SHORT-BROAD-CHILD")
    broader_shortened_expires_at = DateTime.utc_now(:microsecond) |> DateTime.add(60, :second) |> DateTime.truncate(:microsecond)
    requested_expires_at = DateTime.utc_now(:microsecond) |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)
    MintParentGrantRaceRepo.arm(broader_session.assignment.grant_id, %{expires_at: broader_shortened_expires_at})

    broader_response =
      try do
        MCPHarness.request(
          %{
            "jsonrpc" => "2.0",
            "id" => "mint_child_worker_key",
            "method" => "tools/call",
            "params" => %{
              "name" => "mint_child_worker_key",
              "arguments" => %{
                "work_package_id" => broader_child_id,
                "template" => %{"expires_at" => DateTime.to_iso8601(requested_expires_at)}
              }
            }
          },
          config: test_mcp_config(MintParentGrantRaceRepo),
          session: broader_session
        )
      after
        MintParentGrantRaceRepo.disarm()
      end

    assert get_in(broader_response, ["error", "code"]) == -32_602
    assert get_in(broader_response, ["error", "data", "reason"]) == "broader_child_grant"
  end

  test "phase architect cannot mint or read child worker key for sibling anchor, sibling phase, or mismatched base branch", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-SCOPE-ANCHOR", [
        "mint:child_worker_key",
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    assert {:ok, sibling_anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-SIBLING-ANCHOR",
                 kind: "mcp",
                 phase_id: @architect_phase_id,
                 base_branch: "symphony-plus-plus/beta",
                 repo: "nextide/symphony-plus-plus",
                 status: "planning"
               )
             )

    assert {:ok, sibling_anchor_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-SIBLING-ANCHOR-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: sibling_anchor.id,
                 base_branch: "symphony-plus-plus/beta",
                 repo: "nextide/symphony-plus-plus",
                 status: "ready_for_worker"
               )
             )

    sibling_anchor_child_updated_at = sibling_anchor_child.updated_at

    sibling_anchor_mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => sibling_anchor_child.id,
        "template" => child_worker_template()
      })

    assert get_in(sibling_anchor_mint_response, ["error", "code"]) == -32_003
    assert get_in(sibling_anchor_mint_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert {:ok, unchanged_sibling_anchor_child} = WorkPackageRepository.get(repo, sibling_anchor_child.id)
    assert unchanged_sibling_anchor_child.updated_at == sibling_anchor_child_updated_at

    sibling_anchor_status_response =
      mcp_tool(repo, architect_session, "read_child_status", %{"work_package_id" => sibling_anchor_child.id})

    assert get_in(sibling_anchor_status_response, ["error", "code"]) == -32_003
    assert get_in(sibling_anchor_status_response, ["error", "data", "reason"]) == "outside_session_scope"

    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-p7-002-mint-outside", title: "Mint outside phase"})

    assert {:ok, out_of_phase_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-OUT-OF-PHASE",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: other_phase.id,
                 parent_id: "SYMPP-P7-002-MINT-SCOPE-ANCHOR",
                 base_branch: "symphony-plus-plus/beta",
                 repo: "nextide/symphony-plus-plus",
                 status: "ready_for_worker"
               )
             )

    out_of_phase_child_updated_at = out_of_phase_child.updated_at

    out_of_phase_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => out_of_phase_child.id,
        "template" => child_worker_template()
      })

    assert get_in(out_of_phase_response, ["error", "code"]) == -32_003
    assert get_in(out_of_phase_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert {:ok, unchanged_out_of_phase_child} = WorkPackageRepository.get(repo, out_of_phase_child.id)
    assert unchanged_out_of_phase_child.updated_at == out_of_phase_child_updated_at

    assert {:ok, wrong_base_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-WRONG-BASE",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: "SYMPP-P7-002-MINT-SCOPE-ANCHOR",
                 base_branch: "main",
                 repo: "nextide/symphony-plus-plus",
                 status: "ready_for_worker"
               )
             )

    wrong_base_child_updated_at = wrong_base_child.updated_at

    wrong_base_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => wrong_base_child.id,
        "template" => child_worker_template()
      })

    assert get_in(wrong_base_response, ["error", "code"]) == -32_602
    assert get_in(wrong_base_response, ["error", "data", "reason"]) == "base_branch_scope_mismatch"
    assert {:ok, unchanged_wrong_base_child} = WorkPackageRepository.get(repo, wrong_base_child.id)
    assert unchanged_wrong_base_child.updated_at == wrong_base_child_updated_at
  end

  test "phase architect mint revalidates child file scope before worker grant creation", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-MINT-FILE-SCOPE-ANCHOR", [
        "mint:child_worker_key",
        "read:phase"
      ])

    assert {:ok, broader_file_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-002-MINT-BROADER-FILE-SCOPE",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: anchor.id,
                 base_branch: anchor.base_branch,
                 repo: anchor.repo,
                 status: "ready_for_worker",
                 allowed_file_globs: ["**"]
               )
             )

    broader_file_child_updated_at = broader_file_child.updated_at
    grants_before_mint = repo.aggregate(AccessGrant, :count)

    response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => broader_file_child.id,
        "template" => child_worker_template()
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "overbroad_allowed_file_globs"
    assert repo.aggregate(AccessGrant, :count) == grants_before_mint

    assert {:ok, unchanged_child} = WorkPackageRepository.get(repo, broader_file_child.id)
    assert unchanged_child.updated_at == broader_file_child_updated_at
  end

  test "phase architect read_child_status revalidates phase anchor drift", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-READ-DRIFT-ANCHOR", [
        "create:child_work_package",
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-READ-DRIFT-CHILD")

    response = mcp_tool(repo, architect_session, "read_child_status", %{"work_package_id" => anchor.id})
    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) == anchor.id

    child_response = mcp_tool(repo, architect_session, "read_child_status", %{"work_package_id" => child_id})
    assert get_in(child_response, ["result", "structuredContent", "work_package", "id"]) == child_id

    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-p7-002-read-drift", title: "Read drift"})
    assert {:ok, _anchor} = WorkPackageRepository.update(repo, anchor.id, %{phase_id: other_phase.id})

    drifted_response = mcp_tool(repo, architect_session, "read_child_status", %{"work_package_id" => anchor.id})

    assert get_in(drifted_response, ["error", "code"]) == -32_003
    assert get_in(drifted_response, ["error", "data", "reason"]) == "outside_session_scope"

    drifted_child_response = mcp_tool(repo, architect_session, "read_child_status", %{"work_package_id" => child_id})

    assert get_in(drifted_child_response, ["error", "code"]) == -32_003
    assert get_in(drifted_child_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "phase architect read_child_status rejects detached and repo-drifted anchors", %{repo: repo} do
    {detached_anchor, detached_session} =
      create_architect_session(repo, "SYMPP-P7-002-READ-DETACHED-ANCHOR", [
        "create:child_work_package",
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    detached_child_id = create_child_work_package(repo, detached_session, "SYMPP-P7-002-READ-DETACHED-CHILD")

    assert {:ok, _anchor} = WorkPackageRepository.update(repo, detached_anchor.id, %{phase_id: nil})

    detached_anchor_response = mcp_tool(repo, detached_session, "read_child_status", %{"work_package_id" => detached_anchor.id})
    detached_child_response = mcp_tool(repo, detached_session, "read_child_status", %{"work_package_id" => detached_child_id})

    assert get_in(detached_anchor_response, ["error", "code"]) == -32_003
    assert get_in(detached_anchor_response, ["error", "data", "reason"]) == "outside_session_scope"
    assert get_in(detached_child_response, ["error", "code"]) == -32_003
    assert get_in(detached_child_response, ["error", "data", "reason"]) == "outside_session_scope"

    {repo_drift_anchor, repo_drift_session} =
      create_architect_session(repo, "SYMPP-P7-002-READ-REPO-DRIFT-ANCHOR", [
        "read:child_progress",
        "read:child_findings",
        "read:phase"
      ])

    assert {:ok, _anchor} = WorkPackageRepository.update(repo, repo_drift_anchor.id, %{repo: "nextide/other-repo"})

    repo_drift_response = mcp_tool(repo, repo_drift_session, "read_child_status", %{"work_package_id" => repo_drift_anchor.id})

    assert get_in(repo_drift_response, ["error", "code"]) == -32_003
    assert get_in(repo_drift_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "phase child readiness approval and merge record update phase progress", %{repo: repo} do
    architect_capabilities = [
      "create:child_work_package",
      "mint:child_worker_key",
      "read:child_progress",
      "read:child_findings",
      "read:phase",
      "approve:child_ready_state",
      "merge:child_into_phase"
    ]

    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-003-FLOW-ANCHOR", architect_capabilities)

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-003-FLOW-CHILD")
    worker_session = claim_phase_child_worker(repo, architect_session, child_id)
    advance_child_worker_to_ci_waiting(repo, worker_session)
    attach_phase_child_ready_evidence(repo, worker_session, child_id, "p7-003-flow-head")

    ready_response = mcp_tool(repo, worker_session, "mark_ready", %{})

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_architect_merge"

    worker_approval_response =
      mcp_tool(repo, worker_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "worker cannot approve"
      })

    assert get_in(worker_approval_response, ["error", "code"]) == -32_001
    assert get_in(worker_approval_response, ["error", "data", "reason"]) == "architect_grant_required"

    blank_request_id_response =
      mcp_tool(repo, architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Required evidence is green",
        "request_id" => "   "
      })

    assert get_in(blank_request_id_response, ["error", "code"]) == -32_602
    assert get_in(blank_request_id_response, ["error", "data", "reason"]) == "blank_request_id"

    assert {:ok, ready_child} = WorkPackageRepository.get(repo, child_id)
    assert ready_child.status == "ready_for_architect_merge"

    approval_response =
      mcp_tool(repo, architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Required evidence is green",
        "request_id" => "p7-003-approval-flow"
      })

    assert get_in(approval_response, ["result", "structuredContent", "work_package", "status"]) == "merging_into_phase"
    assert get_in(approval_response, ["result", "structuredContent", "approval", "payload", "type"]) == "child_ready_approval"
    approval_event = repo.get!(ProgressEvent, get_in(approval_response, ["result", "structuredContent", "approval", "id"]))
    assert approval_event.actor_id == architect_session.assignment.claimed_by
    assert approval_event.actor_type == "architect"
    assert approval_event.access_grant_id == architect_session.assignment.grant_id
    assert approval_event.payload["source_tool"] == "approve_child_ready_state"

    approval_replay_response =
      mcp_tool(repo, architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Required evidence is green",
        "request_id" => "p7-003-approval-flow"
      })

    assert get_in(approval_replay_response, ["result", "structuredContent", "work_package", "status"]) == "merging_into_phase"

    assert get_in(approval_replay_response, ["result", "structuredContent", "approval", "id"]) ==
             get_in(approval_response, ["result", "structuredContent", "approval", "id"])

    approval_changed_rationale_replay_response =
      mcp_tool(repo, architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Edited retry explanation",
        "request_id" => "p7-003-approval-flow"
      })

    assert get_in(approval_changed_rationale_replay_response, ["result", "structuredContent", "approval", "id"]) ==
             get_in(approval_response, ["result", "structuredContent", "approval", "id"])

    assert get_in(approval_changed_rationale_replay_response, ["result", "structuredContent", "approval", "payload", "rationale"]) ==
             "Required evidence is green"

    renewed_architect_session = renew_phase_architect_session(repo, anchor, architect_capabilities)

    approval_renewal_response =
      mcp_tool(repo, renewed_architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Required evidence is green",
        "request_id" => "p7-003-approval-flow"
      })

    assert get_in(approval_renewal_response, ["result", "structuredContent", "approval", "id"]) ==
             get_in(approval_response, ["result", "structuredContent", "approval", "id"])

    worker_close_response =
      mcp_tool(repo, worker_session, "set_status", %{
        "status" => "closed",
        "expected_status" => "merging_into_phase",
        "reason" => "worker cannot close child after architect approval"
      })

    assert get_in(worker_close_response, ["error", "data", "reason"]) == "child_under_architect_control"

    worker_progress_response =
      mcp_tool(repo, worker_session, "append_progress", %{
        "summary" => "late worker update",
        "status" => "late_worker_update",
        "idempotency_key" => "late-worker-update-after-architect-approval"
      })

    assert get_in(worker_progress_response, ["error", "data", "reason"]) == "child_under_architect_control"

    worker_report_blocker_response =
      mcp_tool(repo, worker_session, "report_blocker", %{
        "summary" => "late blocker",
        "body" => "worker cannot add blockers while architect owns the merge",
        "idempotency_key" => "late-worker-blocker-after-architect-approval"
      })

    assert get_in(worker_report_blocker_response, ["error", "data", "reason"]) == "child_under_architect_control"

    worker_attach_pr_replay_response =
      mcp_tool(repo, worker_session, "attach_pr", %{
        "url" => "https://github.com/nextide/symphony-plus-plus/pull/7003",
        "head_sha" => "p7-003-flow-head"
      })

    assert get_in(worker_attach_pr_replay_response, ["result", "structuredContent", "progress_event", "id"])

    worker_attach_pr_mutation_response =
      mcp_tool(repo, worker_session, "attach_pr", %{
        "url" => "https://github.com/nextide/symphony-plus-plus/pull/7003",
        "head_sha" => "late-worker-head"
      })

    assert get_in(worker_attach_pr_mutation_response, ["error", "data", "reason"]) == "child_under_architect_control"

    worker_review_package_replay_response =
      mcp_tool(repo, worker_session, "submit_review_package", ready_review_package_args("p7-003-flow-head"))

    assert get_in(worker_review_package_replay_response, ["result", "structuredContent", "progress_event", "id"])

    worker_review_package_mutation_response =
      mcp_tool(
        repo,
        worker_session,
        "submit_review_package",
        "p7-003-flow-head"
        |> ready_review_package_args()
        |> Map.put("summary", "Late worker review package")
      )

    assert get_in(worker_review_package_mutation_response, ["error", "data", "reason"]) == "child_under_architect_control"

    worker_merge_response =
      mcp_tool(repo, worker_session, "set_status", %{
        "status" => "merged_into_phase",
        "expected_status" => "merging_into_phase",
        "reason" => "worker cannot record phase merge"
      })

    assert get_in(worker_merge_response, ["error", "data", "reason"]) == "child_under_architect_control"

    merge_artifact = %{
      "status" => "merged_into_phase",
      "uri" => "https://github.com/nextide/symphony-plus-plus/pull/7003",
      "summary" => "Recorded local phase merge",
      "commit_sha" => "p7-003-flow-head"
    }

    merge_response =
      mcp_tool(repo, architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_artifact
      })

    assert get_in(merge_response, ["result", "structuredContent", "work_package", "status"]) == "merged_into_phase"
    assert get_in(merge_response, ["result", "structuredContent", "artifact", "kind"]) == "phase_merge"
    assert get_in(merge_response, ["result", "structuredContent", "merge_artifact", "status"]) == "merged_into_phase"
    assert get_in(merge_response, ["result", "structuredContent", "artifact", "metadata", "commit_sha"]) == "p7-003-flow-head"
    merge_event = repo.get!(ProgressEvent, get_in(merge_response, ["result", "structuredContent", "merge", "id"]))
    assert merge_event.actor_id == architect_session.assignment.claimed_by
    assert merge_event.actor_type == "architect"
    assert merge_event.access_grant_id == architect_session.assignment.grant_id
    assert merge_event.payload["source_tool"] == "merge_child_into_phase"

    post_merge_worker_report_blocker_response =
      mcp_tool(repo, worker_session, "report_blocker", %{
        "summary" => "post-merge blocker",
        "body" => "worker cannot add blockers after the child merged",
        "idempotency_key" => "post-merge-worker-blocker"
      })

    assert get_in(post_merge_worker_report_blocker_response, ["error", "data", "reason"]) == "child_under_architect_control"

    merge_replay_response =
      mcp_tool(repo, architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_artifact
      })

    assert get_in(merge_replay_response, ["result", "structuredContent", "work_package", "status"]) == "merged_into_phase"

    assert get_in(merge_replay_response, ["result", "structuredContent", "merge", "id"]) ==
             get_in(merge_response, ["result", "structuredContent", "merge", "id"])

    merge_renewal_response =
      mcp_tool(repo, renewed_architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_artifact
      })

    assert get_in(merge_renewal_response, ["result", "structuredContent", "merge", "id"]) ==
             get_in(merge_response, ["result", "structuredContent", "merge", "id"])

    different_actor_architect_session = renew_phase_architect_session(repo, anchor, architect_capabilities, "architect-2")

    different_actor_merge_replay_response =
      mcp_tool(repo, different_actor_architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_artifact
      })

    assert get_in(different_actor_merge_replay_response, ["result", "structuredContent", "merge", "id"]) ==
             get_in(merge_response, ["result", "structuredContent", "merge", "id"])

    merge_update_artifact = %{
      "status" => "merged_into_phase",
      "uri" => "https://github.com/nextide/symphony-plus-plus/pull/7003#merge-commit",
      "summary" => "Updated local phase merge",
      "commit_sha" => "p7-003-flow-head-updated"
    }

    merge_update_response =
      mcp_tool(repo, renewed_architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_update_artifact
      })

    assert get_in(merge_update_response, ["result", "structuredContent", "work_package", "status"]) == "merged_into_phase"

    refute get_in(merge_update_response, ["result", "structuredContent", "merge", "id"]) ==
             get_in(merge_response, ["result", "structuredContent", "merge", "id"])

    assert get_in(merge_update_response, ["result", "structuredContent", "artifact", "uri"]) ==
             "https://github.com/nextide/symphony-plus-plus/pull/7003#merge-commit"

    assert get_in(merge_update_response, ["result", "structuredContent", "artifact", "metadata", "commit_sha"]) ==
             "p7-003-flow-head-updated"

    stale_merge_replay_response =
      mcp_tool(repo, renewed_architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_artifact
      })

    assert get_in(stale_merge_replay_response, ["result", "structuredContent", "merge", "id"]) ==
             get_in(merge_response, ["result", "structuredContent", "merge", "id"])

    assert get_in(stale_merge_replay_response, ["result", "structuredContent", "artifact", "uri"]) ==
             "https://github.com/nextide/symphony-plus-plus/pull/7003#merge-commit"

    assert get_in(stale_merge_replay_response, ["result", "structuredContent", "merge_artifact", "uri"]) ==
             "https://github.com/nextide/symphony-plus-plus/pull/7003#merge-commit"

    board_response = mcp_tool(repo, architect_session, "read_phase_board", %{"phase_id" => @architect_phase_id})

    assert get_in(board_response, ["result", "structuredContent", "summary", "child_count"]) == 1
    assert get_in(board_response, ["result", "structuredContent", "summary", "merged_child_count"]) == 1
    assert get_in(board_response, ["result", "structuredContent", "summary", "open_child_count"]) == 0

    phase = repo.get!(Phase, @architect_phase_id)
    assert {:ok, _phase} = repo.update(Ecto.Changeset.change(phase, status: "closed"))

    closed_phase_exact_replay_response =
      mcp_tool(repo, renewed_architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => merge_update_artifact
      })

    assert get_in(closed_phase_exact_replay_response, ["error", "code"]) == -32_602
    assert get_in(closed_phase_exact_replay_response, ["error", "data", "reason"]) == "phase_not_active"

    closed_phase_merge_update_response =
      mcp_tool(repo, renewed_architect_session, "merge_child_into_phase", %{
        "work_package_id" => child_id,
        "merge_artifact" => %{
          "status" => "merged_into_phase",
          "uri" => "https://github.com/nextide/symphony-plus-plus/pull/7003#post-close-update",
          "summary" => "Late local phase merge update"
        }
      })

    assert get_in(closed_phase_merge_update_response, ["error", "code"]) == -32_602
    assert get_in(closed_phase_merge_update_response, ["error", "data", "reason"]) == "phase_not_active"

    assert repo.get_by(Artifact, work_package_id: child_id, kind: "phase_merge").uri ==
             "https://github.com/nextide/symphony-plus-plus/pull/7003#merge-commit"

    assert repo.get_by(Artifact, work_package_id: child_id, kind: "phase_merge").metadata["commit_sha"] ==
             "p7-003-flow-head-updated"
  end

  test "phase architect approval replay survives grant renewal after child blocks", %{repo: repo} do
    architect_capabilities = [
      "create:child_work_package",
      "mint:child_worker_key",
      "read:child_progress",
      "read:child_findings",
      "read:phase",
      "approve:child_ready_state"
    ]

    {anchor, architect_session} = create_architect_session(repo, "SYMPP-P7-003-APPROVAL-REPLAY-ANCHOR", architect_capabilities)

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-003-APPROVAL-REPLAY-CHILD")
    worker_session = claim_phase_child_worker(repo, architect_session, child_id)
    advance_child_worker_to_ci_waiting(repo, worker_session)
    attach_phase_child_ready_evidence(repo, worker_session, child_id, "p7-003-approval-replay-head")

    assert get_in(mcp_tool(repo, worker_session, "mark_ready", %{}), ["result", "structuredContent", "ready"]) == true

    approval_response =
      mcp_tool(repo, architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Ready before downstream merge blocker",
        "request_id" => "p7-003-approval-before-blocker"
      })

    assert get_in(approval_response, ["result", "structuredContent", "work_package", "status"]) == "merging_into_phase"

    block_response =
      mcp_tool(repo, worker_session, "set_status", %{
        "status" => "blocked",
        "expected_status" => "merging_into_phase",
        "reason" => "phase merge is blocked by a conflict"
      })

    assert get_in(block_response, ["result", "structuredContent", "work_package", "status"]) == "blocked"

    blocker_response =
      mcp_tool(repo, worker_session, "report_blocker", %{
        "summary" => "Phase merge conflict",
        "body" => "Architect approval happened, but the child needs worker follow-up before merge.",
        "idempotency_key" => "p7-003-post-approval-blocker"
      })

    assert get_in(blocker_response, ["result", "structuredContent", "progress_event", "payload", "active"]) == true

    renewed_architect_session = renew_phase_architect_session(repo, anchor, architect_capabilities)

    approval_replay_response =
      mcp_tool(repo, renewed_architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Ready before downstream merge blocker",
        "request_id" => "p7-003-approval-before-blocker"
      })

    assert get_in(approval_replay_response, ["result", "structuredContent", "work_package", "status"]) == "blocked"

    assert get_in(approval_replay_response, ["result", "structuredContent", "approval", "id"]) ==
             get_in(approval_response, ["result", "structuredContent", "approval", "id"])

    blocker_id = get_in(blocker_response, ["result", "structuredContent", "progress_event", "payload", "blocker_id"])

    resolve_response =
      mcp_tool(repo, worker_session, "resolve_blocker", %{
        "blocker_id" => blocker_id,
        "resolution" => "merge blocker resolved",
        "summary" => "Phase merge conflict resolved",
        "idempotency_key" => "p7-003-post-approval-blocker-resolved"
      })

    assert get_in(resolve_response, ["result", "structuredContent", "progress_event", "payload", "active"]) == false

    [
      {"blocked", "implementing"},
      {"implementing", "reviewing"},
      {"reviewing", "ci_waiting"}
    ]
    |> Enum.each(fn {expected_status, status} ->
      response =
        mcp_tool(repo, worker_session, "set_status", %{
          "expected_status" => expected_status,
          "status" => status,
          "reason" => "rework phase child after merge blocker"
        })

      assert get_in(response, ["result", "structuredContent", "work_package", "status"]) == status
    end)

    attach_phase_child_ready_evidence(repo, worker_session, child_id, "p7-003-approval-replay-head-reworked")

    assert get_in(mcp_tool(repo, worker_session, "mark_ready", %{}), ["result", "structuredContent", "work_package", "status"]) ==
             "ready_for_architect_merge"

    reapproval_response =
      mcp_tool(repo, renewed_architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Ready before downstream merge blocker",
        "request_id" => "p7-003-approval-before-blocker"
      })

    assert get_in(reapproval_response, ["result", "structuredContent", "work_package", "status"]) == "merging_into_phase"

    refute get_in(reapproval_response, ["result", "structuredContent", "approval", "id"]) ==
             get_in(approval_response, ["result", "structuredContent", "approval", "id"])

    reapproval_replay_response =
      mcp_tool(repo, renewed_architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Edited retry after rework",
        "request_id" => "p7-003-approval-before-blocker"
      })

    assert get_in(reapproval_replay_response, ["result", "structuredContent", "approval", "id"]) ==
             get_in(reapproval_response, ["result", "structuredContent", "approval", "id"])

    original_approval = repo.get!(ProgressEvent, get_in(approval_response, ["result", "structuredContent", "approval", "id"]))
    reapproval = repo.get!(ProgressEvent, get_in(reapproval_response, ["result", "structuredContent", "approval", "id"]))

    refute reapproval.inserted_at == original_approval.inserted_at

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, child_id)

    assert 2 ==
             Enum.count(progress_events, fn event ->
               event.status == "child_ready_approved" and get_in(event.payload, ["request_id"]) == "p7-003-approval-before-blocker"
             end)

    [
      {"merging_into_phase", "blocked"},
      {"blocked", "implementing"},
      {"implementing", "reviewing"},
      {"reviewing", "ci_waiting"}
    ]
    |> Enum.each(fn {expected_status, status} ->
      response =
        mcp_tool(repo, worker_session, "set_status", %{
          "expected_status" => expected_status,
          "status" => status,
          "reason" => "rework phase child before a distinct approval request"
        })

      assert get_in(response, ["result", "structuredContent", "work_package", "status"]) == status
    end)

    attach_phase_child_ready_evidence(repo, worker_session, child_id, "p7-003-approval-replay-head-second-reworked")

    assert get_in(mcp_tool(repo, worker_session, "mark_ready", %{}), ["result", "structuredContent", "work_package", "status"]) ==
             "ready_for_architect_merge"

    distinct_reapproval_response =
      mcp_tool(repo, renewed_architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Ready after a second rework cycle",
        "request_id" => "p7-003-approval-after-second-rework"
      })

    assert get_in(distinct_reapproval_response, ["result", "structuredContent", "work_package", "status"]) == "merging_into_phase"

    stale_approval_replay_response =
      mcp_tool(repo, renewed_architect_session, "approve_child_ready_state", %{
        "work_package_id" => child_id,
        "rationale" => "Stale retry from the previous ready cycle",
        "request_id" => "p7-003-approval-before-blocker"
      })

    assert get_in(stale_approval_replay_response, ["error", "code"]) == -32_602
    assert get_in(stale_approval_replay_response, ["error", "data", "reason"]) == "child_not_ready_for_architect"
  end

  test "phase architect cannot approve child readiness when gates are failed", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-003-FAILED-GATES-ANCHOR", [
        "read:child_progress",
        "read:child_findings",
        "read:phase",
        "approve:child_ready_state"
      ])

    assert {:ok, child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-003-FAILED-GATES-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: anchor.id,
                 repo: anchor.repo,
                 base_branch: anchor.base_branch,
                 allowed_file_globs: anchor.allowed_file_globs,
                 status: "ready_for_architect_merge"
               )
             )

    response =
      mcp_tool(repo, architect_session, "approve_child_ready_state", %{
        "work_package_id" => child.id,
        "rationale" => "should fail without evidence"
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "readiness_failed"
    assert "plan_complete" in get_in(response, ["error", "data", "missing"])
    assert "acceptance_criteria_met" in get_in(response, ["error", "data", "missing"])

    assert {:ok, unchanged_child} = WorkPackageRepository.get(repo, child.id)
    assert unchanged_child.status == "ready_for_architect_merge"
  end

  test "phase architect merge record validates merge artifact", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-003-MERGE-ARTIFACT-ANCHOR", [
        "read:phase",
        "merge:child_into_phase"
      ])

    assert {:ok, child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-003-MERGE-ARTIFACT-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: anchor.id,
                 repo: anchor.repo,
                 base_branch: anchor.base_branch,
                 allowed_file_globs: anchor.allowed_file_globs,
                 status: "merging_into_phase"
               )
             )

    missing_uri_response =
      mcp_tool(repo, architect_session, "merge_child_into_phase", %{
        "work_package_id" => child.id,
        "merge_artifact" => %{"status" => "merged_into_phase"}
      })

    assert get_in(missing_uri_response, ["error", "code"]) == -32_602
    assert get_in(missing_uri_response, ["error", "data", "reason"]) == "missing_merge_artifact_uri"

    invalid_status_response =
      mcp_tool(repo, architect_session, "merge_child_into_phase", %{
        "work_package_id" => child.id,
        "merge_artifact" => %{"status" => "merged", "uri" => "https://github.com/nextide/symphony-plus-plus/pull/7004"}
      })

    assert get_in(invalid_status_response, ["error", "code"]) == -32_602
    assert get_in(invalid_status_response, ["error", "data", "reason"]) == "invalid_merge_artifact_status"

    assert {:ok, unchanged_child} = WorkPackageRepository.get(repo, child.id)
    assert unchanged_child.status == "merging_into_phase"
  end

  test "phase architect cannot finalize child merge after phase closes", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-003-MERGE-CLOSED-PHASE-ANCHOR", [
        "read:phase",
        "merge:child_into_phase"
      ])

    assert {:ok, child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-003-MERGE-CLOSED-PHASE-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: anchor.id,
                 repo: anchor.repo,
                 base_branch: anchor.base_branch,
                 allowed_file_globs: anchor.allowed_file_globs,
                 status: "merging_into_phase"
               )
             )

    phase = repo.get!(Phase, @architect_phase_id)
    assert {:ok, _phase} = repo.update(Ecto.Changeset.change(phase, status: "closed"))

    response =
      mcp_tool(repo, architect_session, "merge_child_into_phase", %{
        "work_package_id" => child.id,
        "merge_artifact" => %{
          "status" => "merged_into_phase",
          "uri" => "https://github.com/nextide/symphony-plus-plus/pull/7005"
        }
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "phase_not_active"

    assert {:ok, unchanged_child} = WorkPackageRepository.get(repo, child.id)
    assert unchanged_child.status == "merging_into_phase"
  end

  test "phase architect cannot replay pending child merge after phase closes", %{repo: repo} do
    {anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-003-MERGE-CLOSED-REPLAY-ANCHOR", [
        "read:phase",
        "merge:child_into_phase"
      ])

    assert {:ok, child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-003-MERGE-CLOSED-REPLAY-CHILD",
                 kind: "phase_child",
                 policy_template: "phase_child",
                 phase_id: @architect_phase_id,
                 parent_id: anchor.id,
                 repo: anchor.repo,
                 base_branch: anchor.base_branch,
                 allowed_file_globs: anchor.allowed_file_globs,
                 status: "merging_into_phase"
               )
             )

    merge_artifact = %{
      "status" => "merged_into_phase",
      "uri" => "https://github.com/nextide/symphony-plus-plus/pull/7006",
      "summary" => "Pending phase merge event"
    }

    assert {:ok, _event} = append_child_merge_progress_event(repo, architect_session, child.id, merge_artifact)

    phase = repo.get!(Phase, @architect_phase_id)
    assert {:ok, _phase} = repo.update(Ecto.Changeset.change(phase, status: "closed"))

    response =
      mcp_tool(repo, architect_session, "merge_child_into_phase", %{
        "work_package_id" => child.id,
        "merge_artifact" => merge_artifact
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "phase_not_active"

    assert {:ok, unchanged_child} = WorkPackageRepository.get(repo, child.id)
    assert unchanged_child.status == "merging_into_phase"
    assert repo.get_by(Artifact, work_package_id: child.id, kind: "phase_merge") == nil
  end

  test "remaining Phase 7 architect stubs return explicit not-yet-implemented errors", %{repo: repo} do
    {_package, session} =
      create_architect_session(repo, "SYMPP-ARCHITECT-PHASE7", [
        "read:phase",
        "revoke:child_worker_key"
      ])

    grants_before = repo.aggregate(AccessGrant, :count)

    revoke_response =
      mcp_tool(repo, session, "revoke_child_worker_key", %{"grant_id" => "grant-placeholder", "reason" => "not wired"})

    assert get_in(revoke_response, ["error", "code"]) == -32_604
    assert get_in(revoke_response, ["error", "data", "reason"]) == "phase7_not_implemented"
    assert repo.aggregate(AccessGrant, :count) == grants_before
  end

  test "Phase 7 architect stubs revalidate phase anchors before not-implemented", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-STUB-DRIFT", kind: "mcp"))
    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-mcp-stub-drift", title: "Stub drift"})

    assert {:ok, architect_work_key} =
             create_architect_work_key(repo, package.id, ["mint:child_worker_key", "read:phase", "revoke:child_worker_key"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    revoke_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "revoke-child-stub",
          "method" => "tools/call",
          "params" => %{
            "name" => "revoke_child_worker_key",
            "arguments" => %{"grant_id" => "grant-placeholder", "reason" => "drift check"}
          }
        },
        config: test_mcp_config(repo),
        session: session
      )

    assert get_in(revoke_response, ["error", "data", "reason"]) == "phase7_not_implemented"

    assert {:ok, _package} = WorkPackageRepository.update(repo, package.id, %{phase_id: other_phase.id})

    stale_revoke_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "revoke-child-stale",
          "method" => "tools/call",
          "params" => %{
            "name" => "revoke_child_worker_key",
            "arguments" => %{"grant_id" => "grant-placeholder", "reason" => "drift check"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_revoke_response, ["error", "code"]) == -32_003
    assert get_in(stale_revoke_response, ["error", "data", "reason"]) == "outside_session_scope"

    stale_mint_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "mint-child-stale-anchor",
          "method" => "tools/call",
          "params" => %{"name" => "mint_child_worker_key", "arguments" => %{"work_package_id" => package.id, "template" => child_worker_template()}}
        },
        config: test_mcp_config(repo),
        session: session
      )

    assert get_in(stale_mint_response, ["error", "code"]) == -32_003
    assert get_in(stale_mint_response, ["error", "data", "reason"]) == "outside_session_scope"
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

    leaked_secret = WorkKey.generate().secret
    second_leaked_secret = WorkKey.generate().secret
    fine_grained_pat = "github_pat_" <> Base.encode16(:crypto.strong_rand_bytes(18), case: :lower)
    query_password = "pw-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    legacy_aws_access_key_id = "AKIA" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :upper)
    legacy_aws_signature = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    text_redacted_progress_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "progress-text-redacted",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_progress",
            "arguments" => %{
              "summary" => "Worker pasted #{leaked_secret} then kept going",
              "idempotency_key" => "worker-progress-text-redacted",
              "payload" => %{
                "Authorization: Bearer #{leaked_secret}" => "present",
                "Authorization: Bearer #{second_leaked_secret}" => "also present",
                "fine_grained_pat" => "Saw #{fine_grained_pat}",
                "note" => "Before Bearer #{leaked_secret} after",
                "password_url" => "Login https://example.test/login?password=#{query_password}&page=1",
                "s3_url" => "Fetch https://bucket.s3.amazonaws.test/object?AWSAccessKeyId=#{legacy_aws_access_key_id}&Signature=#{legacy_aws_signature}&Expires=1",
                "safe_url" => "Review https://example.test/issues/1?w=1",
                "signed_url" => "Fetch https://example.test/download?sig=#{leaked_secret}&page=1"
              }
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(text_redacted_progress_response, ["result", "structuredContent", "progress_event", "summary"]) ==
             "Worker pasted [REDACTED] then kept going"

    text_redacted_payload = get_in(text_redacted_progress_response, ["result", "structuredContent", "progress_event", "payload"])
    assert text_redacted_payload["note"] == "Before [REDACTED] after"
    assert text_redacted_payload["fine_grained_pat"] == "Saw [REDACTED]"
    assert text_redacted_payload["password_url"] == "Login https://example.test/login?password=[REDACTED]&page=1"

    assert text_redacted_payload["s3_url"] ==
             "Fetch https://bucket.s3.amazonaws.test/object?AWSAccessKeyId=[REDACTED]&Signature=[REDACTED]&Expires=1"

    assert text_redacted_payload["safe_url"] == "Review https://example.test/issues/1?w=1"
    assert text_redacted_payload["signed_url"] == "Fetch https://example.test/download?sig=[REDACTED]&page=1"

    redacted_auth_values =
      text_redacted_payload
      |> Enum.filter(fn {key, _value} -> String.starts_with?(key, "Authorization: [REDACTED]") end)
      |> Enum.map(fn {_key, value} -> value end)
      |> Enum.sort()

    assert redacted_auth_values == ["also present", "present"]
    encoded_text_redacted_response = Jason.encode!(get_in(text_redacted_progress_response, ["result", "structuredContent"]))
    refute encoded_text_redacted_response =~ leaked_secret
    refute encoded_text_redacted_response =~ second_leaked_secret
    refute encoded_text_redacted_response =~ fine_grained_pat
    refute encoded_text_redacted_response =~ query_password
    refute encoded_text_redacted_response =~ legacy_aws_access_key_id
    refute encoded_text_redacted_response =~ legacy_aws_signature

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
    assert Enum.any?(get_in(missing_response, ["error", "data", "reasons"]), &(&1["gate"] == "plan_complete"))

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

    sync_request = %{
      "jsonrpc" => "2.0",
      "id" => "sync-pr-replay-mismatch",
      "method" => "tools/call",
      "params" => %{
        "name" => "sync_pr",
        "arguments" => %{
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
        }
      }
    }

    response = MCPHarness.request(sync_request, repo: repo, session: session)

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

    replay_response = MCPHarness.request(sync_request, repo: repo, session: session)

    assert get_in(replay_response, ["result", "structuredContent", "progress_event", "id"]) == event_id

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)
    pr_artifacts = Enum.filter(artifacts, &(&1.kind == "github_pr" and &1.path == "github-pr.json"))

    assert length(pr_artifacts) == 1
    assert [%{uri: "https://github.com/nextide/symphony-plus-plus/pull/43"}] = pr_artifacts
  end

  test "sync_pr replay after different attach is cached but not current readiness evidence", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-SYNC-REPLAY-CURRENT",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 status: "ci_waiting",
                 policy_template: "mcp_current_pr_state"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    head_sha = "abcdef1234567890abcdef1234567890abcdef12"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-REPLAY-CURRENT/worker", "head_sha" => head_sha})
    attach_tool(repo, session, "attach_pr", %{"number" => 42, "head_sha" => head_sha})

    sync_request = %{
      "jsonrpc" => "2.0",
      "id" => "sync-pr-replay-current",
      "method" => "tools/call",
      "params" => %{
        "name" => "sync_pr",
        "arguments" => %{
          "number" => 42,
          "metadata" => %{"head_sha" => head_sha, "check_summary" => %{"conclusion" => "success"}}
        }
      }
    }

    sync_response = MCPHarness.request(sync_request, repo: repo, session: session)
    event_id = get_in(sync_response, ["result", "structuredContent", "progress_event", "id"])

    attach_tool(repo, session, "attach_pr", %{"number" => 43, "head_sha" => head_sha})

    replay_response = MCPHarness.request(sync_request, repo: repo, session: session)
    assert get_in(replay_response, ["result", "structuredContent", "progress_event", "id"]) == event_id

    new_old_sync_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync-pr-old-new-request",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{
              "number" => 42,
              "metadata" => %{"head_sha" => head_sha, "check_summary" => %{"conclusion" => "success"}},
              "idempotency_key" => "new-old-sync"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(new_old_sync_response, ["error", "data", "reason"]) == "pr_mismatch"

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-replayed-old-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "current_pr_state" in get_in(ready_response, ["error", "data", "missing"])

    attach_tool(repo, session, "sync_pr", %{
      "number" => 43,
      "metadata" => %{"head_sha" => head_sha, "check_summary" => %{"conclusion" => "success"}}
    })

    ready_after_current_sync =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-current-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_after_current_sync, ["result", "structuredContent", "ready"]) == true
  end

  test "attach_pr number requires unambiguous repository context for short package repos", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-NUMBER-SHORT-REPO",
                 kind: "mcp",
                 repo: "symphony-plus-plus",
                 status: "ci_waiting"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_context =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "attach_pr",
          "method" => "tools/call",
          "params" => %{"name" => "attach_pr", "arguments" => %{"number" => 42, "head_sha" => "head-a"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_context, ["error", "data", "reason"]) == "missing_repository_use_url_or_owner_repo"

    explicit_repository =
      attach_tool(repo, session, "attach_pr", %{"number" => "42", "repository" => "nextide/symphony-plus-plus", "head_sha" => "head-a"})

    assert get_in(explicit_repository, ["result", "structuredContent", "progress_event", "payload", "url"]) ==
             "https://github.com/nextide/symphony-plus-plus/pull/42"

    url_package =
      WorkPackageFactory.attrs(
        id: "SYMPP-PR-URL-SHORT-REPO",
        kind: "mcp",
        repo: "symphony-plus-plus",
        status: "ci_waiting"
      )

    assert {:ok, url_package} = WorkPackageRepository.create(repo, url_package)
    assert {:ok, url_minted} = AccessGrantService.mint_worker_grant(repo, url_package.id)
    assert {:ok, url_assignment} = AccessGrantService.claim(repo, url_minted.work_key.secret, claimed_by: "worker-1")
    url_session = MCPHarness.session(url_assignment, proof_hash: url_minted.grant.secret_hash)

    url_response =
      attach_tool(repo, url_session, "attach_pr", %{"url" => "https://github.com/nextide/symphony-plus-plus/pull/43", "head_sha" => "head-a"})

    assert get_in(url_response, ["result", "structuredContent", "progress_event", "payload", "number"]) == 43
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

    cased_ref =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync_pr_cased_ref",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{
              "url" => "https://github.com/NextIDE/Symphony-Plus-Plus/pull/42",
              "metadata" => %{"head_sha" => "abc123"}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(cased_ref, ["result", "structuredContent", "progress_event", "payload", "repository"]) == "NextIDE/Symphony-Plus-Plus"

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

    top_level_head =
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

    assert get_in(top_level_head, ["result", "structuredContent", "progress_event", "payload", "head_sha"]) == "abc123"
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

    attached_ref_response =
      attach_tool(repo, session, "sync_pr", %{
        "number" => 43,
        "metadata" => %{
          "head_sha" => "head-a",
          "check_summary" => %{"conclusion" => "success"}
        },
        "idempotency_key" => "number-only-from-attach"
      })

    assert get_in(attached_ref_response, ["result", "structuredContent", "progress_event", "payload", "repository"]) ==
             "nextide/symphony-plus-plus"
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

  test "legacy attached PR URL still satisfies pr_attached evidence", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-LEGACY-URL-READY", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/#{package.id}", "head_sha" => "legacy-head"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://git.example.com/org/repo/pulls/7", "head_sha" => "legacy-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "legacy-head",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-legacy-pr-url", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
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

    attach_tool(repo, session, "sync_pr", %{
      "url" => "https://github.com/example/repo/pull/790",
      "metadata" => %{"head_sha" => "head-a", "state" => "open", "draft" => false}
    })

    raw_state_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-raw-state-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "current_pr_state" in get_in(raw_state_response, ["error", "data", "missing"])

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-READY/worker", "head_sha" => "head-b"})

    stale_sync_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-stale-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "current_pr_state" in get_in(stale_sync_response, ["error", "data", "missing"])

    sync_pr_state(repo, session, "https://github.com/example/repo/pull/790", "head-b")

    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-b"})

    reattach_after_sync_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-reattach-after-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "current_pr_state" in get_in(reattach_after_sync_response, ["error", "data", "missing"])

    attach_tool(repo, session, "sync_pr", %{
      "url" => "https://github.com/example/repo/pull/790",
      "metadata" => %{
        "head_sha" => "head-b",
        "check_summary" => %{"conclusion" => "success", "total_count" => 1},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      }
    })

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

  test "current PR state accepts semantic boolean sync metadata", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-BOOLEAN-SYNC-READY",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_current_pr_state"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-BOOLEAN-SYNC-READY/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})

    attach_tool(repo, session, "sync_pr", %{
      "url" => "https://github.com/example/repo/pull/790",
      "metadata" => %{"head_sha" => "head-a", "mergeable" => true, "merged" => false}
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
        %{"jsonrpc" => "2.0", "id" => "ready-boolean-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "sync_pr refresh for current head satisfies PR attachment evidence", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-SYNC-HEAD-READY",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_current_pr_state"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-HEAD-READY/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-HEAD-READY/worker", "head_sha" => "head-b"})

    attach_tool(repo, session, "sync_pr", %{
      "number" => 790,
      "metadata" => %{
        "head_sha" => "head-b",
        "check_summary" => %{"conclusion" => "success"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      }
    })

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review after sync",
      "tests" => ["mix test"],
      "artifacts" => ["review-head-b.txt"],
      "head_sha" => "head-b",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-sync-head", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "attach_pr with full current state does not satisfy synced PR readiness", %{repo: repo} do
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

    missing_sync_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-attach-state", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "current_pr_state" in get_in(missing_sync_response, ["error", "data", "missing"])
  end

  test "abbreviated branch head satisfies full PR head readiness", %{repo: repo} do
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

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "overly short branch head does not satisfy full PR head readiness", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-TINY-HEAD-READY", kind: "mcp", status: "ci_waiting")
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-TINY-HEAD-READY/worker", "head_sha" => "abc"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "abcdef1234567890abcdef1234567890abcdef12"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Tiny head review",
      "tests" => ["mix test"],
      "artifacts" => ["tiny-head-review.txt"],
      "head_sha" => "abc",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-tiny-head", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "pr_attached" in get_in(ready_response, ["error", "data", "missing"])
  end

  test "validated review-suite result satisfies explicit readiness gate", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-REVIEW-SUITE-READY",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_review_suite_artifact"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-READY/worker", "head_sha" => "suite-head"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/900", "head_sha" => "suite-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "suite-head",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    missing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "missing-review-suite", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_suite_result" in get_in(missing_response, ["error", "data", "missing"])

    result_response =
      attach_tool(repo, session, "attach_review_suite_result", %{
        "work_package_id" => package.id,
        "head_sha" => "suite-head",
        "suite" => "review-suite",
        "anchor" => "phase_gate-suite-head",
        "summary" => "T1 and T2 are green",
        "status" => "passed",
        "verdict" => "green",
        "lane" => "review_t2",
        "round_id" => "phase_gate-suite-head"
      })

    assert get_in(result_response, ["result", "structuredContent", "progress_event", "status"]) == "review_suite_passed"
    assert get_in(result_response, ["result", "structuredContent", "progress_event", "payload", "type"]) == "review_suite_result"
    assert get_in(result_response, ["result", "structuredContent", "progress_event", "payload", "status"]) == "passed"

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)
    assert Enum.any?(artifacts, &(&1.kind == "review_suite" and &1.path == "review-suite-result.json"))

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-review-suite", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true

    post_ready_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-review-suite",
          "method" => "tools/call",
          "params" => %{
            "name" => "attach_review_suite_result",
            "arguments" => %{
              "work_package_id" => package.id,
              "head_sha" => "suite-head",
              "suite" => "review-suite",
              "anchor" => "phase_gate-suite-head-rerun",
              "summary" => "Late review suite rerun",
              "status" => "passed",
              "verdict" => "green",
              "idempotency_key" => "late-review-suite-rerun"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(post_ready_response, ["error", "data", "reason"]) == "already_ready"
  end

  test "scope guard blocks out-of-scope PR files until architect approval expands allowed globs", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-GUARD-READY",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 status: "ci_waiting",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: ["elixir/lib/**"]
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    head_sha = "scope-head-a"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-SCOPE-GUARD-READY/worker", "head_sha" => head_sha})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/nextide/symphony-plus-plus/pull/903", "head_sha" => head_sha})

    attach_tool(repo, session, "sync_pr", %{
      "url" => "https://github.com/nextide/symphony-plus-plus/pull/903",
      "metadata" => %{
        "head_sha" => head_sha,
        "base_branch" => "symphony-plus-plus/beta",
        "changed_files" => [
          %{"filename" => "elixir/lib/symphony_elixir/symphony_plus_plus/readiness/scope_guard.ex", "status" => "added"},
          %{"filename" => "docs/scope-contract.md", "status" => "added", "token" => "ghp_scope_secret"}
        ],
        "check_summary" => %{"conclusion" => "success", "token" => "ghp_scope_secret"},
        "review_state" => %{"state" => "approved"},
        "merge_state" => %{"state" => "clean"}
      }
    })

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    attach_tool(repo, session, "attach_review_suite_result", %{
      "work_package_id" => package.id,
      "head_sha" => head_sha,
      "suite" => "review-suite",
      "anchor" => "phase_gate-scope-head-a",
      "summary" => "T1 and T2 are green",
      "status" => "passed",
      "verdict" => "green"
    })

    request_response =
      attach_tool(repo, session, "request_scope_expansion", %{
        "summary" => "Need docs scope for the contract note",
        "idempotency_key" => "scope-docs-request",
        "payload" => %{"requested_file_globs" => ["docs/**"]}
      })

    request_id = get_in(request_response, ["result", "structuredContent", "progress_event", "id"])

    out_of_scope_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-scope-out", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "scope_guard" in get_in(out_of_scope_response, ["error", "data", "missing"])
    scope_reason = Enum.find(get_in(out_of_scope_response, ["error", "data", "reasons"]), &(&1["gate"] == "scope_guard"))
    assert scope_reason["code"] == "out_of_scope_files"
    assert scope_reason["files"] == ["docs/scope-contract.md"]
    refute inspect(out_of_scope_response) =~ "ghp_scope_secret"

    worker_approval_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "worker-approval-denied",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{"work_package_id" => package.id, "allowed_file_globs" => ["docs/**"], "request_id" => request_id, "rationale" => "Worker cannot approve"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(worker_approval_response, ["error", "data", "reason"]) == "architect_grant_required"

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Spoofed scope approval",
      "idempotency_key" => "spoof-scope-approval",
      "payload" => %{
        "type" => "scope_expansion_approval",
        "source_tool" => "approve_scope_expansion",
        "approved" => true,
        "allowed_file_globs" => ["docs/**"]
      }
    })

    assert {:ok, spoofed_package} = WorkPackageRepository.get(repo, package.id)
    assert spoofed_package.allowed_file_globs == ["elixir/lib/**"]

    spoofed_ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-spoofed-scope", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "scope_guard" in get_in(spoofed_ready_response, ["error", "data", "missing"])

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    overbroad_approval_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "architect-overbroad-scope",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["**"],
              "request_id" => request_id,
              "rationale" => "Overbroad approval must not disable the guard"
            }
          }
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(overbroad_approval_response, ["error", "data", "reason"]) == "overbroad_allowed_file_globs"

    assert {:ok, overbroad_rejected_package} = WorkPackageRepository.get(repo, package.id)
    assert overbroad_rejected_package.allowed_file_globs == ["elixir/lib/**"]

    approval_response =
      attach_tool(repo, architect_session, "approve_scope_expansion", %{
        "work_package_id" => package.id,
        "allowed_file_globs" => ["docs/**"],
        "request_id" => request_id,
        "rationale" => "Docs contract file is part of the current package."
      })

    assert get_in(approval_response, ["result", "structuredContent", "allowed_file_globs"]) == ["elixir/lib/**", "docs/**"]
    assert get_in(approval_response, ["result", "structuredContent", "progress_event", "payload", "approved"]) == true
    approval_event_id = get_in(approval_response, ["result", "structuredContent", "progress_event", "id"])
    approval_event = repo.get!(ProgressEvent, approval_event_id)
    assert approval_event.actor_id == "architect-1"
    assert approval_event.actor_type == "architect"
    assert approval_event.access_grant_id == architect_assignment.grant_id
    assert approval_event.payload["source_tool"] == "approve_scope_expansion"
    assert approval_event.payload["request_id"] == request_id
    refute inspect(approval_event.payload) =~ architect_work_key.secret
    refute inspect(approval_response) =~ architect_work_key.secret

    retry_approval_response =
      attach_tool(repo, architect_session, "approve_scope_expansion", %{
        "work_package_id" => package.id,
        "allowed_file_globs" => ["docs/**"],
        "request_id" => request_id,
        "rationale" => "Docs contract file is part of the current package."
      })

    assert get_in(retry_approval_response, ["result", "structuredContent", "progress_event", "id"]) == approval_event_id

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-scope-approval", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true

    post_ready_retry_response =
      attach_tool(repo, architect_session, "approve_scope_expansion", %{
        "work_package_id" => package.id,
        "allowed_file_globs" => ["docs/**"],
        "request_id" => request_id,
        "rationale" => "Docs contract file is part of the current package."
      })

    assert get_in(post_ready_retry_response, ["result", "structuredContent", "progress_event", "id"]) == approval_event_id
    assert get_in(post_ready_retry_response, ["result", "structuredContent", "allowed_file_globs"]) == ["elixir/lib/**", "docs/**"]

    assert {:ok, renewed_architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, renewed_architect_assignment} =
             AccessGrantRepository.claim(repo, renewed_architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    renewed_architect_session =
      MCPHarness.session(renewed_architect_assignment, proof_hash: WorkKey.secret_hash(renewed_architect_work_key.secret))

    post_ready_renewed_retry_response =
      attach_tool(repo, renewed_architect_session, "approve_scope_expansion", %{
        "work_package_id" => package.id,
        "allowed_file_globs" => ["docs/**"],
        "request_id" => request_id,
        "rationale" => "Docs contract file is part of the current package."
      })

    assert get_in(post_ready_renewed_retry_response, ["result", "structuredContent", "progress_event", "id"]) == approval_event_id
    assert get_in(post_ready_renewed_retry_response, ["result", "structuredContent", "allowed_file_globs"]) == ["elixir/lib/**", "docs/**"]

    assert {:ok, different_architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, different_architect_assignment} =
             AccessGrantRepository.claim(repo, different_architect_work_key.secret, %{claimed_by: "architect-2"}, DateTime.utc_now(:microsecond))

    different_architect_session =
      MCPHarness.session(different_architect_assignment, proof_hash: WorkKey.secret_hash(different_architect_work_key.secret))

    post_ready_different_actor_retry_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-different-actor-scope-retry",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["docs/**"],
              "request_id" => request_id,
              "rationale" => "Docs contract file is part of the current package."
            }
          }
        },
        repo: repo,
        session: different_architect_session
      )

    assert get_in(post_ready_different_actor_retry_response, ["error", "data", "reason"]) == "idempotency_conflict"

    post_ready_new_approval_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-new-scope-approval",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["docs/**", "notes/**"],
              "request_id" => request_id,
              "rationale" => "New post-ready scope must not mutate"
            }
          }
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(post_ready_new_approval_response, ["error", "data", "reason"]) == "already_ready"

    assert {:ok, post_ready_package} = WorkPackageRepository.get(repo, package.id)
    assert post_ready_package.allowed_file_globs == ["elixir/lib/**", "docs/**"]
  end

  test "scope guard uses current-head changed-file paths from sync_pr when a later sync omits file paths", %{repo: repo} do
    changed_paths = [
      "implementation_docs_symphplusplus/README.md",
      "implementation_docs_symphplusplus/docs/01_IMPLEMENTATION_GUIDE.md",
      "implementation_docs_symphplusplus/docs/02_SYSTEM_SPEC.md",
      "implementation_docs_symphplusplus/docs/07_DASHBOARD_SPEC.md",
      "implementation_docs_symphplusplus/docs/09_OPERATIONAL_RUNBOOK.md",
      "implementation_docs_symphplusplus/docs/12_OPERATOR_TRAINING.md",
      "implementation_docs_symphplusplus/docs/13_WORKREQUEST_CONTRACT.md"
    ]

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-GUARD-SYNC-PR",
                 kind: "mcp",
                 repo: "Pimpmuckl/symphony-plus-plus",
                 base_branch: "main",
                 status: "ci_waiting",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: changed_paths
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    head_sha = "scope-docs-head-a"
    pr_url = "https://github.com/Pimpmuckl/symphony-plus-plus/pull/61"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-V2-PRODUCT-001/workrequest-contract", "head_sha" => head_sha})
    attach_tool(repo, session, "attach_pr", %{"url" => pr_url, "head_sha" => head_sha})

    path_sync_response =
      attach_tool(repo, session, "sync_pr", %{
        "url" => pr_url,
        "metadata" => %{
          "head_sha" => head_sha,
          "base" => %{"ref" => "main", "sha" => "base-pr61"},
          "changed_files" => Enum.map(changed_paths, &%{"filename" => &1, "status" => "modified"}),
          "changed_files_count" => length(changed_paths),
          "check_summary" => %{"conclusion" => "success"},
          "review_state" => %{"state" => "approved"},
          "merge_state" => %{"state" => "clean"}
        }
      })

    path_sync_payload = get_in(path_sync_response, ["result", "structuredContent", "progress_event", "payload"])
    assert path_sync_payload["changed_files_available"] == true
    assert path_sync_payload["changed_files_count"] == 7
    assert length(path_sync_payload["changed_files"]) == 7

    count_only_sync_response =
      attach_tool(repo, session, "sync_pr", %{
        "url" => pr_url,
        "metadata" => %{
          "head_sha" => head_sha,
          "base" => %{"ref" => "main", "sha" => "base-pr61"},
          "changed_files" => 7,
          "check_summary" => %{"conclusion" => "success"},
          "review_state" => %{"state" => "approved"},
          "merge_state" => %{"state" => "clean"}
        }
      })

    count_only_payload = get_in(count_only_sync_response, ["result", "structuredContent", "progress_event", "payload"])
    assert count_only_payload["changed_files_available"] == false
    assert count_only_payload["changed_files_count"] == 7

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    attach_tool(repo, session, "attach_review_suite_result", %{
      "work_package_id" => package.id,
      "head_sha" => head_sha,
      "suite" => "review-suite",
      "anchor" => "phase_gate-scope-docs-head-a",
      "summary" => "T1 and T2 are green",
      "status" => "passed",
      "verdict" => "green"
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-doc-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "architect approval repairs overbroad existing scope constraints", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-GUARD-REPAIR",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: ["**"]
               )
             )

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    approval_response =
      attach_tool(repo, architect_session, "approve_scope_expansion", %{
        "work_package_id" => package.id,
        "allowed_file_globs" => ["docs/**"],
        "rationale" => "Replace invalid catch-all with scoped package docs."
      })

    assert get_in(approval_response, ["result", "structuredContent", "allowed_file_globs"]) == ["docs/**"]
    payload = get_in(approval_response, ["result", "structuredContent", "progress_event", "payload"])
    assert payload["previous_allowed_file_globs"] == ["**"]
    assert payload["allowed_file_globs"] == ["docs/**"]

    assert {:ok, repaired_package} = WorkPackageRepository.get(repo, package.id)
    assert repaired_package.allowed_file_globs == ["docs/**"]
  end

  test "scope expansion approval rejects packages without scope guard", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-GUARD-NOT-REQUIRED",
                 kind: "quick_fix",
                 status: "ci_waiting",
                 policy_template: "quick_fix",
                 allowed_file_globs: []
               )
             )

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    approval_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "unguarded-scope-approval",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["docs/**"],
              "rationale" => "Unguarded packages must not record scope approvals."
            }
          }
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(approval_response, ["error", "data", "reason"]) == "scope_guard_not_required"

    assert {:ok, unchanged_package} = WorkPackageRepository.get(repo, package.id)
    assert unchanged_package.allowed_file_globs == []
  end

  test "review-suite result rejects missing head, wrong package, stale head, non-passing verdicts, and failed-result override", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-REVIEW-SUITE-INVALID",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_review_suite_artifact"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    base_args = %{
      "work_package_id" => package.id,
      "head_sha" => "head-a",
      "suite" => "review-suite",
      "anchor" => "phase_gate-head-a",
      "summary" => "Review suite result",
      "status" => "passed",
      "verdict" => "green"
    }

    missing_head_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "missing-head",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => Map.delete(base_args, "head_sha")}
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_head_response, ["error", "data", "reason"]) == "missing_head_sha"

    wrong_package_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "wrong-package",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => Map.put(base_args, "work_package_id", "SYMPP-OTHER")}
        },
        repo: repo,
        session: session
      )

    assert get_in(wrong_package_response, ["error", "data", "reason"]) == "outside_session_scope"

    non_passing_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "non-passing",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => %{base_args | "status" => "failed", "verdict" => "red"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(non_passing_response, ["error", "data", "reason"]) == "non_passing_review_suite_result"

    arbitrary_payload_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "arbitrary-review-suite-payload",
          "method" => "tools/call",
          "params" => %{
            "name" => "attach_review_suite_result",
            "arguments" => Map.put(base_args, "payload", %{"raw_prompt" => "do not expose", "reviewer_internal" => %{"trace" => "hidden"}})
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(arbitrary_payload_response, ["error", "data", "reason"]) == "unexpected_argument"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-INVALID/worker", "head_sha" => "head-a"})

    assert {:ok, _failed_event} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               idempotency_key: "attach_review_suite_result:#{package.id}:failed-review-suite-head-a",
               summary: "Failed review-suite result",
               status: "review_suite_failed",
               payload: %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => "head-a",
                 "suite" => "review-suite",
                 "anchor" => "phase_gate-head-a-failed",
                 "summary" => "Review suite failed",
                 "status" => "failed",
                 "verdict" => "red"
               }
             })

    failed_override_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "failed-override",
          "method" => "tools/call",
          "params" => %{
            "name" => "attach_review_suite_result",
            "arguments" => Map.put(base_args, "idempotency_key", "failed-override-green")
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(failed_override_response, ["error", "data", "reason"]) == "failed_review_suite_result_exists"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-INVALID/worker", "head_sha" => "head-b"})

    stale_head_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-head",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => base_args}
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_head_response, ["error", "data", "reason"]) == "stale_head_sha"
  end

  test "review-suite result idempotent retry replays after current head advances", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-REPLAY", kind: "mcp", status: "ci_waiting", policy_template: "mcp_review_suite_artifact")
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    args = %{
      "work_package_id" => package.id,
      "head_sha" => "head-a",
      "suite" => "review-suite",
      "anchor" => "phase_gate-head-a",
      "summary" => "Review suite result",
      "status" => "passed",
      "verdict" => "green",
      "lane" => "review_t2",
      "reviewer" => "review-suite",
      "round_id" => "phase_gate-head-a",
      "idempotency_key" => "review-suite-head-a"
    }

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-REPLAY/worker", "head_sha" => "head-a"})
    first_response = attach_tool(repo, session, "attach_review_suite_result", args)
    first_event_id = get_in(first_response, ["result", "structuredContent", "progress_event", "id"])

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-REPLAY/worker", "head_sha" => "head-b"})

    replay_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "review-suite-replay", "method" => "tools/call", "params" => %{"name" => "attach_review_suite_result", "arguments" => args}},
        repo: repo,
        session: session
      )

    assert get_in(replay_response, ["result", "structuredContent", "progress_event", "id"]) == first_event_id

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    revoked_replay_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "review-suite-revoked-replay", "method" => "tools/call", "params" => %{"name" => "attach_review_suite_result", "arguments" => args}},
        repo: repo,
        session: session
      )

    assert get_in(revoked_replay_response, ["error", "data", "reason"]) == "revoked"
  end

  test "review-suite readiness uses chronological latest result for the current head", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-ORDER", kind: "mcp", status: "ci_waiting", policy_template: "mcp_review_suite_artifact")
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-ORDER/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/901", "head_sha" => "head-a"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => review_suite_artifact_id(package.id, "head-a"),
               "work_package_id" => package.id,
               "path" => "review-suite-result.json",
               "title" => "Review-suite result",
               "kind" => "review_suite"
             })

    assert {:ok, _newer_passed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:chronological-pass",
               "summary" => "Newer review-suite result passed",
               "status" => "review_suite_passed",
               "created_at" => ~U[2026-05-05 00:00:10Z],
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => "head-a",
                 "suite" => "review-suite",
                 "anchor" => "phase_gate-head-a-pass",
                 "summary" => "Newer review suite passed",
                 "status" => "passed",
                 "verdict" => "green"
               }
             })

    assert {:ok, _older_failed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:chronological-fail",
               "summary" => "Older review-suite result failed",
               "status" => "review_suite_failed",
               "created_at" => ~U[2026-05-05 00:00:00Z],
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => "head-a",
                 "suite" => "review-suite",
                 "anchor" => "phase_gate-head-a-fail",
                 "summary" => "Older review suite failed",
                 "status" => "failed",
                 "verdict" => "red"
               }
             })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-review-suite-order", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "stale and spoofed review-suite evidence cannot satisfy required readiness", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-REVIEW-SUITE-SPOOF",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_review_suite_artifact"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-SPOOF/worker", "head_sha" => "head-a"})

    attach_tool(repo, session, "attach_review_suite_result", %{
      "work_package_id" => package.id,
      "head_sha" => "head-a",
      "suite" => "review-suite",
      "anchor" => "phase_gate-head-a",
      "summary" => "Old head review suite",
      "status" => "passed",
      "verdict" => "green"
    })

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-SPOOF/worker", "head_sha" => "head-b"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/901", "head_sha" => "head-b"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-b",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Spoofed review-suite JSON",
      "idempotency_key" => "spoof-review-suite-json",
      "payload" => %{
        "type" => "review_suite_result",
        "source_tool" => "attach_review_suite_result",
        "work_package_id" => package.id,
        "head_sha" => "head-b",
        "suite" => "review-suite",
        "anchor" => "phase_gate-head-b",
        "status" => "passed",
        "verdict" => "green"
      }
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-spoofed-review-suite", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(ready_response, ["error", "data", "missing"])
    assert "review_suite_result" in missing
    refute "review_package_submitted" in missing
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
    assert Enum.any?(get_in(blocked_response, ["error", "data", "reasons"]), &(&1["gate"] == "no_active_blockers"))

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
    refute "scope_guard" in get_in(missing_recommendation_response, ["error", "data", "missing"])

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

  defp append_child_merge_progress_event(repo, %Session{} = session, child_id, merge_artifact) do
    payload = child_merge_payload(child_id, merge_artifact)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, child_id, %{
      "summary" => Map.get(merge_artifact, "summary") || "Child merged into phase",
      "status" => "merged_into_phase",
      "idempotency_key" => metadata_idempotency_key(payload),
      "payload" => payload
    })
  end

  defp child_merge_payload(child_id, merge_artifact) do
    %{
      "type" => "phase_child_merge",
      "source_tool" => "merge_child_into_phase",
      "work_package_id" => child_id,
      "merge_artifact" => merge_artifact
    }
  end

  defp metadata_idempotency_key(payload) do
    "mcp:" <> Map.get(payload, "type", "metadata") <> ":" <> Base.url_encode64(:erlang.term_to_binary(payload), padding: false)
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

  defp review_suite_artifact_id(work_package_id, head_sha) do
    material = [work_package_id, head_sha, "review-suite-result.json"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-MCP-#{System.unique_integer([:positive])}",
      title: "Improve WorkRequest intake",
      repo: "nextide/symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record the human outcome before slicing.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false},
      desired_dispatch_shape: "single_package",
      status: "draft"
    }

    Enum.into(overrides, defaults)
  end

  defp work_request_question_attrs(overrides) do
    defaults = %{
      category: "scope",
      question: "Which branch should this target?",
      why_needed: "The architect needs the target before slicing."
    }

    Enum.into(overrides, defaults)
  end

  defp work_request_decision_attrs(overrides) do
    defaults = %{
      source_type: "architect",
      decision: "Keep this WorkRequest narrow.",
      rationale: "The next slice owns broader orchestration.",
      scope_impact: "No new runtime tools.",
      created_by: "architect-1"
    }

    Enum.into(overrides, defaults)
  end

  defp work_request_planned_slice_attrs(overrides) do
    defaults = %{
      title: "Add WorkRequest MCP reads",
      goal: "Expose scoped read-only WorkRequest MCP payloads.",
      work_package_kind: "mcp",
      target_base_branch: "symphony-plus-plus/beta",
      branch_pattern: "agent/SYMPP-V2-WR-013/workrequest-read-mcp-tools",
      owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
      forbidden_file_globs: ["elixir/lib/symphony_elixir_web/live/**"],
      acceptance_criteria: ["WorkRequest MCP reads are scoped and redacted."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/mcp_test.exs"],
      review_lanes: ["review_t1", "raw_secret_review_lane", "review_t2"],
      stop_conditions: ["Stop before mutation or dispatch wiring."]
    }

    Enum.into(overrides, defaults)
  end

  defp create_phase_architect_session(repo, work_package_id, capabilities, overrides \\ []) do
    phase_id = ensure_architect_phase(repo)

    package_attrs =
      [
        id: work_package_id,
        kind: "mcp",
        base_branch: "symphony-plus-plus/beta",
        repo: "nextide/symphony-plus-plus",
        allowed_file_globs: ["elixir/lib/**"],
        phase_id: phase_id,
        status: "planning"
      ]
      |> Keyword.merge(overrides)
      |> WorkPackageFactory.attrs()

    assert {:ok, package} = WorkPackageRepository.create(repo, package_attrs)

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, phase_id,
               work_package_id: package.id,
               capabilities: capabilities
             )

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, minted.work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: minted.grant.secret_hash)
    assert {:ok, grant} = AccessGrantRepository.get(repo, minted.grant.id)

    {package, session, grant}
  end

  defp create_architect_session(repo, work_package_id, capabilities, overrides \\ []) do
    package_attrs =
      [
        id: work_package_id,
        kind: "mcp",
        base_branch: "symphony-plus-plus/beta",
        repo: "nextide/symphony-plus-plus",
        allowed_file_globs: ["elixir/lib/**"],
        status: "planning"
      ]
      |> Keyword.merge(overrides)
      |> WorkPackageFactory.attrs()

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               package_attrs
             )

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, capabilities)

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))
    {:ok, package} = WorkPackageRepository.get(repo, package.id)

    {package, session}
  end

  defp active_worker_grants(grants) do
    now = DateTime.utc_now(:microsecond)

    Enum.filter(grants, fn grant ->
      grant.grant_role == "worker" and is_nil(grant.revoked_at) and DateTime.compare(grant.expires_at, now) == :gt
    end)
  end

  defp mcp_tool(repo, session, name, arguments) do
    MCPHarness.request(
      %{
        "jsonrpc" => "2.0",
        "id" => name,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      },
      config: test_mcp_config(repo),
      session: session
    )
  end

  defp test_mcp_config(repo), do: Config.default(repo: repo, repo_root: test_repo_root())

  defp test_repo_root do
    Path.expand("../../../..", __DIR__)
  end

  defp child_worker_template(secret_handoff_overrides \\ %{}) do
    %{
      "secret_handoff" =>
        Map.merge(
          %{
            "mode" => test_secret_handoff_mode(),
            "store_dir" => test_handoff_store_dir()
          },
          secret_handoff_overrides
        )
    }
  end

  defp windows? do
    case :os.type() do
      {:win32, _name} -> true
      _type -> false
    end
  end

  defp test_secret_handoff_mode do
    if windows?(), do: "windows-credential-manager", else: "local-private-file"
  end

  defp test_handoff_store_dir do
    System.tmp_dir!()
    |> Path.join("sympp-mcp-test-worker-secrets")
    |> Path.expand()
  end

  defp test_handoff_opts(claimed_by \\ "worker-1") do
    [
      repo_root: test_repo_root(),
      claimed_by: claimed_by,
      mode: test_secret_handoff_mode(),
      store_dir: test_handoff_store_dir()
    ]
  end

  defp current_main_database_path(repo) do
    assert {:ok, %{rows: rows}} = SQL.query(repo, "PRAGMA database_list", [], log: false)

    case Enum.find(rows, &main_database_row?/1) do
      [_seq, "main", path] when is_binary(path) and path != "" -> path
      row -> flunk("expected file-backed test ledger for external MCP bootstrap, got: #{inspect(row)}")
    end
  end

  defp run_mcp_with_windows_credential_handoff(handoff, claimed_by, database_path, input) do
    powershell = powershell_executable!()
    input_path = Path.join(System.tmp_dir!(), "sympp-mcp-stdin-#{System.unique_integer([:positive])}.jsonl")
    runner_path = Path.join(System.tmp_dir!(), "sympp-mcp-runner-#{System.unique_integer([:positive])}.cmd")

    try do
      File.write!(input_path, input)

      File.write!(runner_path, """
      @echo off
      "%SYMPP_MCP_TEST_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%SYMPP_MCP_TEST_SCRIPT%" run-mcp -Target "%SYMPP_MCP_TEST_TARGET%" -Database "%SYMPP_MCP_TEST_DATABASE%" -ClaimedBy "%SYMPP_MCP_TEST_CLAIMED_BY%" -ElixirDir "%SYMPP_MCP_TEST_ELIXIR_DIR%" < "%SYMPP_MCP_TEST_STDIN_FILE%"
      exit /b %ERRORLEVEL%
      """)

      System.cmd(
        "cmd.exe",
        ["/d", "/s", "/c", runner_path],
        cd: test_repo_root(),
        env: [
          {"MIX_ENV", "test"},
          {"MISE_NO_CONFIG", "1"},
          {"SYMPP_MCP_TEST_STDIN_FILE", input_path},
          {"SYMPP_MCP_TEST_POWERSHELL", powershell},
          {"SYMPP_MCP_TEST_SCRIPT", Path.join(test_repo_root(), "scripts/sympp-worker-secret.ps1")},
          {"SYMPP_MCP_TEST_TARGET", Map.fetch!(handoff, "target")},
          {"SYMPP_MCP_TEST_DATABASE", database_path},
          {"SYMPP_MCP_TEST_CLAIMED_BY", claimed_by},
          {"SYMPP_MCP_TEST_ELIXIR_DIR", Path.join(test_repo_root(), "elixir")}
        ],
        stderr_to_stdout: true
      )
    after
      File.rm(input_path)
      File.rm(runner_path)
    end
  end

  defp powershell_executable! do
    powershell = Enum.find_value(["powershell.exe", "powershell", "pwsh"], &System.find_executable/1)
    assert is_binary(powershell), "Windows Credential Manager MCP bootstrap test requires powershell.exe or pwsh"
    powershell
  end

  defp cleanup_test_child_worker_handoffs(repo) do
    grants =
      repo.all(
        from(grant in AccessGrant,
          where: grant.provenance == ^@child_worker_grant_provenance
        )
      )

    Enum.each(grants, fn grant ->
      with {:ok, work_package} <- WorkPackageRepository.get(repo, grant.work_package_id) do
        SecretHandoff.delete_worker_secret_by_grant(work_package, grant, test_handoff_opts())
      end
    end)
  end

  defp claim_phase_child_worker(repo, architect_session, child_id) do
    mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template(%{"claimed_by" => "worker-1"})
      })

    claim_child_worker_from_mint_response(repo, mint_response, "worker-1")
  end

  defp claim_child_worker_from_mint_response(repo, mint_response, claimed_by) do
    worker_grant = get_in(mint_response, ["result", "structuredContent", "worker_grant"])
    handoff = Map.fetch!(worker_grant, "secret_handoff")

    session =
      case Map.fetch!(handoff, "mode") do
        "local-private-file" ->
          worker_secret = File.read!(Map.fetch!(handoff, "path"))
          assert {:ok, worker_assignment} = AccessGrantService.claim(repo, worker_secret, claimed_by: claimed_by)
          MCPHarness.session(worker_assignment, proof_hash: WorkKey.secret_hash(worker_secret))

        "windows-credential-manager" ->
          # Windows Credential Manager retrieval is covered by the dedicated run-mcp bootstrap test.
          claim_child_worker_without_secret(repo, Map.fetch!(worker_grant, "id"), claimed_by)
      end

    cleanup_child_worker_handoff(handoff, claimed_by)
    session
  end

  defp claim_child_worker_without_secret(repo, grant_id, claimed_by) do
    now = DateTime.utc_now(:microsecond)

    assert {1, _rows} =
             repo.update_all(
               from(grant in AccessGrant, where: grant.id == ^grant_id),
               set: [claimed_at: now, claimed_by: claimed_by, updated_at: now]
             )

    assert {:ok, grant} = AccessGrantRepository.get(repo, grant_id)
    assert {:ok, session} = Session.from_grant(grant, DateTime.utc_now(:microsecond), proof_hash: grant.secret_hash)
    session
  end

  defp cleanup_child_worker_handoff(handoff, claimed_by) do
    assert :ok = SecretHandoff.delete_worker_secret(handoff, test_handoff_opts(claimed_by))
  end

  defp handoff_secret_absent?(%{"mode" => "local-private-file", "path" => path}, text) when is_binary(text) do
    case File.read(path) do
      {:ok, secret} when is_binary(secret) and secret != "" -> not String.contains?(text, secret)
      _other -> true
    end
  end

  defp handoff_secret_absent?(_handoff, text), do: is_binary(text)

  defp renew_phase_architect_session(repo, anchor, capabilities, claimed_by \\ "architect-1") do
    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, anchor.phase_id,
               work_package_id: anchor.id,
               capabilities: capabilities
             )

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, minted.work_key.secret, %{claimed_by: claimed_by}, DateTime.utc_now(:microsecond))

    MCPHarness.session(architect_assignment, proof_hash: minted.grant.secret_hash)
  end

  defp advance_child_worker_to_ci_waiting(repo, worker_session) do
    [
      {"ready_for_worker", "claimed"},
      {"claimed", "planning"},
      {"planning", "implementing"},
      {"implementing", "reviewing"},
      {"reviewing", "ci_waiting"}
    ]
    |> Enum.each(fn {expected_status, status} ->
      response =
        mcp_tool(repo, worker_session, "set_status", %{
          "expected_status" => expected_status,
          "status" => status,
          "reason" => "advance phase child test flow"
        })

      assert get_in(response, ["result", "structuredContent", "work_package", "status"]) == status
    end)
  end

  defp attach_phase_child_ready_evidence(repo, worker_session, child_id, head_sha) do
    append_done_plan(repo, child_id)
    attach_tool(repo, worker_session, "attach_branch", %{"branch" => "agent/#{child_id}/worker", "head_sha" => head_sha})
    attach_tool(repo, worker_session, "attach_pr", %{"url" => "https://github.com/nextide/symphony-plus-plus/pull/7003", "head_sha" => head_sha})

    attach_tool(repo, worker_session, "submit_review_package", ready_review_package_args(head_sha))
  end

  defp ready_review_package_args(head_sha) do
    %{
      "summary" => "Ready for architect review",
      "tests" => ["mix test elixir/test/symphony_elixir/symphony_plus_plus/mcp_test.exs"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "review_t1", "verdict" => "green"}, %{"lane" => "review_t2", "verdict" => "green"}]
    }
  end

  defp create_child_work_package(repo, session, child_id) do
    response =
      mcp_tool(repo, session, "create_child_work_package", %{
        "package" => %{
          "id" => child_id,
          "title" => "Implement #{child_id}",
          "acceptance_criteria" => ["Complete #{child_id}"]
        }
      })

    assert get_in(response, ["result", "structuredContent", "work_package", "id"]) == child_id
    child_id
  end

  defp create_architect_work_key(repo, work_package_id, capabilities \\ ["architect:lifecycle.transition"]) do
    now = DateTime.utc_now(:microsecond)
    work_key = WorkKey.generate()
    phase_id = phase_id_for_architect_grant(repo, work_package_id, capabilities)

    attrs = %{
      work_package_id: work_package_id,
      display_key: work_key.display_key,
      secret_hash: WorkKey.secret_hash(work_key.secret),
      grant_role: "architect",
      capabilities: capabilities,
      expires_at: DateTime.add(now, 86_400, :second)
    }

    attrs = if phase_id, do: Map.put(attrs, :phase_id, phase_id), else: attrs

    with {:ok, _grant} <- AccessGrantRepository.create(repo, attrs) do
      {:ok, work_key}
    end
  end

  defp phase_id_for_architect_grant(repo, work_package_id, capabilities) do
    if "read:phase" in capabilities do
      phase_id = ensure_architect_phase(repo)
      assert {:ok, _work_package} = WorkPackageRepository.update(repo, work_package_id, %{phase_id: phase_id})
      phase_id
    end
  end

  defp ensure_architect_phase(repo) do
    case PhaseRepository.get(repo, @architect_phase_id) do
      {:ok, phase} ->
        phase.id

      {:error, :not_found} ->
        assert {:ok, phase} = PhaseRepository.create(repo, %{id: @architect_phase_id, title: "MCP architect test phase"})
        phase.id
    end
  end

  defp decode_json_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp decode_json_objects_from_mixed_output(output) do
    output
    |> String.split(~r/\R/, trim: true)
    |> Enum.map(&String.trim_leading/1)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(&Jason.decode!/1)
  end

  defp json_rpc_response_summary(responses) do
    Enum.map(responses, fn response ->
      result = Map.get(response, "result", %{})

      %{
        id: Map.get(response, "id"),
        error: get_in(response, ["error", "data", "reason"]) || get_in(response, ["error", "message"]),
        result_keys: if(is_map(result), do: Map.keys(result), else: [])
      }
    end)
  end
end
