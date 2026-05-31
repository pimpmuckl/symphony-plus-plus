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
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.GrantScope
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Service, as: CommentService
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Auth, Config, Server, Session, Stdio}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Repository, as: MCPRepository
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SecretHandoff
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository, as: SoloSessionRepository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.SymphonyPlusPlus.TrackerAdapter
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.TestSupport
  alias SymphonyElixir.WorkPackageFactory

  @architect_phase_id "phase-mcp-architect-test"
  @child_worker_grant_provenance "child_worker_delegation"
  @handoff_store_process_key :sympp_mcp_test_handoff_store_dir
  @architect_tool_names [
    "create_child_work_package",
    "mint_child_worker_key",
    "revoke_child_worker_key",
    "list_work_requests",
    "read_work_request",
    "add_comment",
    "list_comments",
    "resolve_comment",
    "resolve_blocker",
    "read_work_request_delivery_board",
    "reconcile_work_request",
    "record_planned_slice_delivery",
    "revoke_planned_slice_worker_key",
    "list_guidance_requests",
    "read_guidance_request",
    "answer_guidance_request",
    "escalate_guidance_request",
    "set_work_request_status",
    "ask_work_request_question",
    "answer_work_request_question",
    "answer_work_request_question_and_record_decision",
    "close_work_request_question",
    "record_work_request_decision",
    "add_work_request_planned_slice",
    "approve_work_request_planned_slice",
    "skip_work_request_planned_slice",
    "mark_work_request_sliced",
    "dispatch_work_request_planned_slice",
    "prepare_work_package_worktree",
    "cleanup_work_package_worktree",
    "read_child_status",
    "approve_scope_expansion",
    "read_phase_board",
    "request_child_replan",
    "approve_child_ready_state",
    "merge_child_into_phase",
    "split_work_package",
    "publish_phase_update"
  ]
  @codex_forbidden_top_level_schema_keys ["oneOf", "anyOf", "allOf", "enum", "not"]

  defmodule FailingAuthRepo do
    def get(_schema, _id), do: raise(RuntimeError, "ledger unavailable")
  end

  defmodule UnexpectedAuthRepo do
    def get(_schema, _id), do: {:error, :ledger_down}
  end

  defmodule FailingHealthRepo do
    def query(_sql, _params, _opts), do: {:error, %RuntimeError{message: "C:/secret/path.sqlite"}}
  end

  defmodule DefaultRemoteHealthRepo do
    def config, do: [hostname: "ledger-prod.example.test", port: 15_432, database: "sympp"]
    def query("PRAGMA database_list", _params, _opts), do: {:error, :unsupported}
    def query(sql, _params, _opts) when is_binary(sql), do: {:ok, %{rows: [[1]]}}
  end

  defmodule DefaultRemoteIpv6HealthRepo do
    def config, do: [hostname: "::1", port: 15_432, database: "sympp"]
    def query("PRAGMA database_list", _params, _opts), do: {:error, :unsupported}
    def query(sql, _params, _opts) when is_binary(sql), do: {:ok, %{rows: [[1]]}}
  end

  defmodule DefaultRemoteDbnameHealthRepo do
    def config, do: [database: "dbname=sympp"]
    def query("PRAGMA database_list", _params, _opts), do: {:error, :unsupported}
    def query(sql, _params, _opts) when is_binary(sql), do: {:ok, %{rows: [[1]]}}
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

  defmodule LocalClaimAuditFailureRepo do
    alias Ecto.Changeset
    alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def transaction(fun), do: Repo.transaction(fun)
    def rollback(value), do: Repo.rollback(value)
    def get(schema, id), do: Repo.get(schema, id)
    def one(query), do: Repo.one(query)
    def all(query), do: Repo.all(query)
    def update(changeset), do: Repo.update(changeset)
    def update_all(query, updates), do: Repo.update_all(query, truncate_claim_timestamps(updates))

    def insert(%Ecto.Changeset{data: %ProgressEvent{}, changes: %{status: "claim_lease_reclaimed"}}) do
      {:error, Changeset.add_error(Changeset.change(%ProgressEvent{}), :id, "forced_reclaim_audit_failure")}
    end

    def insert(changeset), do: Repo.insert(changeset)

    defp truncate_claim_timestamps(set: fields) do
      [
        set:
          Enum.map(fields, fn
            {field, %DateTime{} = timestamp} when field in [:claimed_at, :updated_at] ->
              {field, DateTime.truncate(timestamp, :second)}

            field ->
              field
          end)
      ]
    end

    defp truncate_claim_timestamps(updates), do: updates
  end

  defmodule LocalClaimInsertRaceRepo do
    alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    @race_key :sympp_local_claim_insert_race

    def arm(actor_overrides \\ %{}), do: Process.put(@race_key, actor_overrides)
    def disarm, do: Process.delete(@race_key)

    def transaction(fun), do: Repo.transaction(fun)
    def rollback(value), do: Repo.rollback(value)
    def get(schema, id), do: Repo.get(schema, id)
    def one(query), do: Repo.one(query)
    def all(query), do: Repo.all(query)
    def update(changeset), do: Repo.update(changeset)
    def update_all(query, updates), do: Repo.update_all(query, updates)

    def insert(%Ecto.Changeset{data: %ClaimLease{}} = changeset) do
      if actor_overrides = Process.get(@race_key) do
        Process.delete(@race_key)

        changeset.changes
        |> Map.take([:work_package_id, :actor_kind, :actor_id, :actor_display_name, :stale_after_ms])
        |> Map.merge(actor_overrides)
        |> ClaimLease.create_changeset(now: DateTime.utc_now(:microsecond))
        |> Repo.insert()
      end

      Repo.insert(changeset)
    end

    def insert(changeset), do: Repo.insert(changeset)
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
    def all(query), do: Repo.all(query)
    def one(query), do: Repo.one(query)
    def update(changeset), do: Repo.update(changeset)

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
    assert :ok = SoloSessionRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    reset_handle_state_store()
    handoff_store_dir = unique_test_handoff_store_dir()
    Process.put(@handoff_store_process_key, handoff_store_dir)
    File.rm_rf(handoff_store_dir)
    repo.delete_all(Artifact)
    repo.delete_all(ProgressEvent)
    repo.delete_all(Finding)
    repo.delete_all(PlanNode)
    repo.delete_all(SoloSessionEntry)
    repo.delete_all(SoloSession)
    repo.delete_all(Comment)
    repo.delete_all(ClaimLease)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkRequest)
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)

    on_exit(fn ->
      cleanup_test_child_worker_handoffs(repo, handoff_store_dir)
      File.rm_rf(handoff_store_dir)
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

  test "session grant validation accepts nil expiry and rejects inactive or unclaimed grants" do
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

    scopes = [Scope.work_package(grant.work_package_id)]

    assert {:ok, session} = Session.from_grant(grant, now, proof_hash: "proof", scopes: scopes)
    assert session.assignment.work_package_id == "SYMPP-SESSION-GRANT"
    assert session.assignment.scopes == scopes

    assert Session.from_grant(grant, now, proof_hash: "proof") == {:error, :missing_grant_scopes}
    assert Session.from_grant(%{grant | revoked_at: now}, now, scopes: scopes) == {:error, :revoked}
    assert Session.from_grant(%{grant | expires_at: now}, now, scopes: scopes) == {:error, :expired}
    assert {:ok, nil_expiry_session} = Session.from_grant(%{grant | expires_at: nil}, now, scopes: scopes)
    assert nil_expiry_session.assignment.grant_id == grant.id
    assert Session.from_grant(%{grant | claimed_at: nil}, now, scopes: scopes) == {:error, :unclaimed}
    assert Session.from_grant(%{grant | claimed_by: " "}, now, scopes: scopes) == {:error, :missing_claim_identity}
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

  test "auth helpers reject sessions after package authority reaches a terminal state", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-AUTH-TERMINAL", kind: "mcp", status: "ready_for_worker"))

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    assert {:ok, _terminal_package} = WorkPackageRepository.update(repo, package.id, %{status: "merged"})

    assert Auth.require_session(session, repo) == {:error, {:unauthorized, :work_package_terminal}}
  end

  test "auth helpers preserve live architect sessions and retire them with their anchor package", %{repo: repo} do
    {package, session, _grant} = create_phase_architect_session(repo, "SYMPP-AUTH-ARCH-TERMINAL", ["read:phase"])

    assert {:ok, live_session} = Auth.require_session(session, repo)
    assert live_session.assignment.grant_role == "architect"
    assert live_session.assignment.work_package_id == package.id
    assert live_session.assignment.phase_id == package.phase_id
    assert Scope.work_package(package.id) in live_session.assignment.scopes
    assert Scope.repo(package.repo, package.base_branch) in live_session.assignment.scopes

    assert {:ok, _terminal_package} = WorkPackageRepository.update(repo, package.id, %{status: "merged"})

    assert Auth.require_session(session, repo) == {:error, {:unauthorized, :work_package_terminal}}
  end

  test "config parser defaults to stdio and rejects unsupported modes" do
    assert {:ok, %Config{mode: :stdio, database: nil}} = Config.parse([])

    assert %Config{
             mode: :stdio,
             repo: Repo,
             version: version,
             source_revision: source_revision,
             repo_root: nil
           } = Config.default()

    assert is_binary(version)
    assert is_nil(source_revision) or source_revision =~ ~r/\A[0-9a-f]{40}\z/
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

      assert get_in(health_response, ["result", "structuredContent", "ledger", "reachable"]) == true
      assert is_list(get_in(tools_response, ["result", "tools"]))
    after
      Repo.put_dynamic_repo(original_repo)
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  test "health reports safe default and explicit sqlite ledger identity", %{repo: repo} do
    database_path = current_main_database_path(repo)

    default_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "default-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: repo)
      )

    default_identity = get_in(default_response, ["result", "structuredContent", "ledger", "identity"])

    assert get_in(default_response, ["result", "structuredContent", "ledger", "reachable"]) == true
    assert default_identity["kind"] == "sqlite"
    assert default_identity["source"] == "default"
    assert is_binary(default_identity["display_path"])
    assert is_boolean(default_identity["default_home"])
    assert String.ends_with?(default_identity["display_path"], Path.basename(database_path))

    explicit_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "explicit-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: repo, database: database_path)
      )

    explicit_identity = get_in(explicit_response, ["result", "structuredContent", "ledger", "identity"])

    assert get_in(explicit_response, ["result", "structuredContent", "ledger", "reachable"]) == true
    assert explicit_identity["kind"] == "sqlite"
    assert explicit_identity["source"] == "explicit"
    assert String.ends_with?(explicit_identity["display_path"], Path.basename(database_path))

    mismatched_database_path = WorkPackageFactory.database_path()

    mismatched_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "mismatched-explicit-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: repo, database: mismatched_database_path)
      )

    assert get_in(mismatched_response, ["result", "structuredContent", "status"]) == "degraded"
    assert get_in(mismatched_response, ["result", "structuredContent", "ledger", "reachable"]) == false
    assert get_in(mismatched_response, ["result", "structuredContent", "ledger", "identity", "kind"]) == "sqlite"
    assert get_in(mismatched_response, ["result", "structuredContent", "ledger", "identity", "source"]) == "explicit"
    assert get_in(mismatched_response, ["result", "structuredContent", "ledger", "error"]) == "ledger_unavailable"

    File.rm(mismatched_database_path)
  end

  test "health redacts credential-bearing ledger identity values", %{repo: repo} do
    sqlite_secret = "sqlite_password_that_must_not_echo"
    sqlite_uri = sqlite_file_uri(current_main_database_path(repo), "password=#{sqlite_secret}&cache=shared")

    sqlite_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sqlite-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: repo, database: sqlite_uri)
      )

    assert get_in(sqlite_response, ["result", "structuredContent", "ledger", "identity", "kind"]) == "sqlite"
    assert get_in(sqlite_response, ["result", "structuredContent", "ledger", "identity", "source"]) == "explicit"
    assert get_in(sqlite_response, ["result", "structuredContent", "ledger", "reachable"]) == true
    refute inspect(sqlite_response) =~ sqlite_secret
    refute inspect(sqlite_response) =~ "password="

    remote_secret = "remote_secret_that_must_not_echo"
    remote_database = "https://worker:#{remote_secret}@ledger-prod.example.test:9443/mcp?token=#{remote_secret}"

    remote_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "remote-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: FailingHealthRepo, database: remote_database)
      )

    assert get_in(remote_response, ["result", "structuredContent", "ledger", "reachable"]) == false

    assert get_in(remote_response, ["result", "structuredContent", "ledger", "identity"]) == %{
             "kind" => "server",
             "source" => "explicit",
             "endpoint" => "https://ledger-prod.example.test:9443"
           }

    refute inspect(remote_response) =~ remote_secret
    refute inspect(remote_response) =~ "worker:"
    refute inspect(remote_response) =~ "token="

    dsn_secret = "dsn_password_that_must_not_echo"
    dsn_database = "Server=tcp:ledger-dsn.example.test,1433;Database=sympp;Password=#{dsn_secret}"

    dsn_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "dsn-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: FailingHealthRepo, database: dsn_database)
      )

    assert get_in(dsn_response, ["result", "structuredContent", "ledger", "identity"]) == %{
             "kind" => "server",
             "source" => "explicit",
             "endpoint" => "server://ledger-dsn.example.test:1433"
           }

    refute inspect(dsn_response) =~ dsn_secret
    refute inspect(dsn_response) =~ "Password="
    refute inspect(dsn_response) =~ "Server="
  end

  test "health uses default remote repo config as safe server identity" do
    Code.ensure_loaded!(DefaultRemoteHealthRepo)
    assert {:ok, _result} = DefaultRemoteHealthRepo.query("SELECT 1", [], [])

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "default-remote-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: DefaultRemoteHealthRepo)
      )

    result = get_in(response, ["result", "structuredContent"])

    assert result["status"] == "ok"
    assert result["ledger"]["reachable"] == true

    assert result["ledger"]["identity"] == %{
             "kind" => "server",
             "source" => "default",
             "endpoint" => "server://ledger-prod.example.test:15432"
           }

    refute inspect(response) =~ "dbname=sympp"
    refute inspect(response) =~ "host="

    explicit_name_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "explicit-remote-name-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: DefaultRemoteHealthRepo, database: "sympp")
      )

    assert get_in(explicit_name_response, ["result", "structuredContent", "ledger", "reachable"]) == true

    assert get_in(explicit_name_response, ["result", "structuredContent", "ledger", "identity"]) == %{
             "kind" => "server",
             "source" => "explicit",
             "endpoint" => "server://ledger-prod.example.test:15432"
           }

    ipv6_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "default-remote-ipv6-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: DefaultRemoteIpv6HealthRepo)
      )

    assert get_in(ipv6_response, ["result", "structuredContent", "ledger", "identity"]) == %{
             "kind" => "server",
             "source" => "default",
             "endpoint" => "server://[::1]:15432"
           }

    dbname_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "default-remote-dbname-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: DefaultRemoteDbnameHealthRepo)
      )

    assert get_in(dbname_response, ["result", "structuredContent", "ledger", "reachable"]) == true

    assert get_in(dbname_response, ["result", "structuredContent", "ledger", "identity"]) == %{
             "kind" => "server",
             "source" => "default",
             "endpoint" => "server"
           }

    explicit_dbname_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "explicit-remote-dbname-health",
          "method" => "tools/call",
          "params" => %{"name" => "sympp.health", "arguments" => %{}}
        },
        config: Config.default(repo: DefaultRemoteDbnameHealthRepo, database: "dbname=sympp")
      )

    assert get_in(explicit_dbname_response, ["result", "structuredContent", "ledger", "reachable"]) == true

    assert get_in(explicit_dbname_response, ["result", "structuredContent", "ledger", "identity"]) == %{
             "kind" => "server",
             "source" => "explicit",
             "endpoint" => "server"
           }
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

      reconnect_output =
        capture_io(input, fn ->
          McpTask.run(["--work-key-secret-env", env_var, "--claimed-by", "worker-env-1"])
        end)

      refute reconnect_output =~ minted.work_key.secret
      [_reconnect_init_response, reconnect_response] = decode_json_lines(reconnect_output)
      reconnect_assignment = Jason.decode!(get_in(reconnect_response, ["result", "contents", Access.at(0), "text"]))

      assert reconnect_assignment["work_package_id"] == "SYMPP-P10-003"
      assert reconnect_assignment["claimed_by"] == "worker-env-1"
    after
      System.delete_env(env_var)
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  test "mix task migrates legacy access grant expiry before env secret claim" do
    database_path = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()
    env_var = "SYMPP_MCP_TEST_SECRET_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

    try do
      Repo.put_dynamic_repo(pid)
      assert :ok = WorkPackageRepository.migrate(Repo)
      assert {:ok, package} = WorkPackageRepository.create(Repo, WorkPackageFactory.attrs(id: "SYMPP-MCP-LEGACY-ENV"))

      assert {:ok, minted} =
               AccessGrantService.mint_worker_grant(Repo, package.id, expires_at: ~U[2030-01-01 00:00:00Z])

      rebuild_access_grants_with_not_null_expiry!(pid)
      remove_null_expiry_migration_version!(pid)
      assert access_grant_expiry_not_null?(pid)

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
          McpTask.run(["--database", database_path, "--work-key-secret-env", env_var, "--claimed-by", "worker-legacy-env"])
        end)

      refute output =~ minted.work_key.secret
      [_init_response, response] = decode_json_lines(output)
      assignment = Jason.decode!(get_in(response, ["result", "contents", Access.at(0), "text"]))

      assert assignment["work_package_id"] == "SYMPP-MCP-LEGACY-ENV"
      assert assignment["claimed_by"] == "worker-legacy-env"
      refute access_grant_expiry_not_null?(pid)
      assert schema_migration_recorded?(pid, 20_260_519_120_000)
    after
      System.delete_env(env_var)
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
      File.rm(database_path)
    end
  end

  test "MCP repository preparation is cached after a successful migration" do
    database_path = WorkPackageFactory.database_path()
    original_repo = Repo.get_dynamic_repo()

    {:ok, pid} =
      Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

    try do
      Repo.put_dynamic_repo(pid)
      assert :ok = MCPRepository.ensure_migrated(Repo)

      parent = self()

      lock_task =
        Task.async(fn ->
          TrackerAdapter.migration_file_lock_for_test(database_path, fn ->
            send(parent, :migration_file_lock_acquired)

            receive do
              :release_migration_file_lock -> :ok
            end
          end)
        end)

      assert_receive :migration_file_lock_acquired, 1_000

      ensure_task =
        Task.async(fn ->
          task_original_repo = Repo.get_dynamic_repo()

          try do
            Repo.put_dynamic_repo(pid)
            MCPRepository.ensure_migrated(Repo)
          after
            Repo.put_dynamic_repo(task_original_repo)
          end
        end)

      ensure_result = Task.yield(ensure_task, 500) || Task.shutdown(ensure_task, :brutal_kill)

      send(lock_task.pid, :release_migration_file_lock)
      assert :ok = Task.await(lock_task)
      assert {:ok, :ok} = ensure_result
    after
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
      assert get_in(health_response, ["result", "structuredContent", "ledger", "reachable"]) == true
      assert get_in(health_response, ["result", "structuredContent", "ledger", "identity", "kind"]) == "sqlite"
      assert get_in(health_response, ["result", "structuredContent", "ledger", "identity", "source"]) == "explicit"
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

  test "tools list keeps unbound discovery bootstrap-only before binding", %{repo: repo} do
    unbound_server = Server.new(Config.default(repo: repo), initialized: true)

    unbound_response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "unbound-tools", "method" => "tools/list", "params" => %{}}, unbound_server)

    unbound_tools_by_name =
      unbound_response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    assert Map.keys(unbound_tools_by_name) |> Enum.sort() ==
             Enum.sort([
               "claim_private_handoff",
               "claim_work_key",
               "create_work_request",
               "solo_append",
               "solo_attach",
               "solo_list",
               "solo_show",
               "solo_update_status",
               "sympp.health"
             ])

    assert get_in(unbound_tools_by_name, ["claim_work_key", "inputSchema", "required"]) == ["secret", "claimed_by"]
    assert get_in(unbound_tools_by_name, ["claim_work_key", "inputSchema", "properties", "secret", "type"]) == "string"
    assert get_in(unbound_tools_by_name, ["claim_private_handoff", "inputSchema", "required"]) == ["claimed_by"]
    assert get_in(unbound_tools_by_name, ["claim_private_handoff", "inputSchema", "properties", "private_handoff", "type"]) == "object"

    assert get_in(unbound_tools_by_name, ["claim_private_handoff", "inputSchema", "then", "anyOf"]) == [
             %{"required" => ["private_handoff"]},
             %{"required" => ["mode", "path", "target", "grant_id", "display_key", "work_package_id"]}
           ]

    assert get_in(unbound_tools_by_name, ["create_work_request", "inputSchema", "required"]) == [
             "repo",
             "base_branch",
             "title",
             "request_kind"
           ]

    assert get_in(unbound_tools_by_name, ["create_work_request", "inputSchema", "then", "anyOf"]) == [
             %{"required" => ["description"]},
             %{"required" => ["human_description"]}
           ]

    refute Map.has_key?(unbound_tools_by_name, "get_current_assignment")
    refute Map.has_key?(unbound_tools_by_name, "append_progress")
    refute Map.has_key?(unbound_tools_by_name, "set_status")

    for tool <- @architect_tool_names do
      refute Map.has_key?(unbound_tools_by_name, tool)
    end

    assert {:ok, claim_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-UNBOUND-CLAIM-CALL", kind: "mcp"))
    assert {:ok, claim_minted} = AccessGrantService.mint_worker_grant(repo, claim_package.id)

    claim_response =
      mcp_tool(repo, nil, "claim_work_key", %{
        "secret" => claim_minted.work_key.secret,
        "claimed_by" => "worker-1"
      })

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == "SYMPP-UNBOUND-CLAIM-CALL"

    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WORKER-TOOLS-LIST", kind: "mcp"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: minted.grant.secret_hash)
    worker_server = Server.new(Config.default(repo: repo), initialized: true, session: worker_session)

    worker_response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "worker-tools", "method" => "tools/list", "params" => %{}}, worker_server)

    tools_by_name =
      worker_response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    assert get_in(tools_by_name, ["get_current_assignment", "inputSchema", "required"]) == []
    assert get_in(tools_by_name, ["append_progress", "inputSchema", "required"]) == ["summary", "idempotency_key"]
    assert get_in(tools_by_name, ["append_finding", "inputSchema", "required"]) == ["title", "body", "idempotency_key"]
    assert get_in(tools_by_name, ["read_guidance_request", "inputSchema", "required"]) == ["guidance_request_id"]
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "required"]) == ["expected_version"]
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties", "expected_version", "type"]) == "integer"
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties", "patch", "required"]) == ["nodes"]
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties", "patch", "properties", "nodes", "minItems"]) == 1
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties", "work_package_id", "type"]) == "string"
    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "then", "oneOf"]) != nil

    assert get_in(tools_by_name, ["update_task_plan", "inputSchema", "properties", "patch", "properties", "nodes", "items", "anyOf"]) == [
             %{"required" => ["title"]},
             %{"required" => ["id"], "anyOf" => [%{"required" => ["title"]}, %{"required" => ["body"]}, %{"required" => ["status"]}]}
           ]

    assert get_in(tools_by_name, ["set_status", "inputSchema", "required"]) == ["status", "expected_status"]
    assert get_in(tools_by_name, ["report_blocker", "inputSchema", "properties", "blocker_id", "type"]) == "string"
    assert get_in(tools_by_name, ["resolve_blocker", "inputSchema", "required"]) == ["blocker_id", "resolution", "summary", "idempotency_key"]
    assert get_in(tools_by_name, ["add_comment", "inputSchema", "required"]) == ["target_kind", "target_id", "body"]
    assert get_in(tools_by_name, ["add_comment", "inputSchema", "properties", "target_kind", "enum"]) == ["work_request", "planned_slice", "work_package"]
    assert get_in(tools_by_name, ["add_comment", "inputSchema", "properties", "body", "maxLength"]) == Comment.max_body_length()
    assert get_in(tools_by_name, ["list_comments", "inputSchema", "required"]) == ["target_kind", "target_id"]
    assert get_in(tools_by_name, ["resolve_comment", "inputSchema", "required"]) == ["comment_id"]
    assert get_in(tools_by_name, ["resolve_comment", "inputSchema", "properties", "resolution_note", "maxLength"]) == Comment.max_resolution_note_length()
    assert get_in(tools_by_name, ["attach_branch", "inputSchema", "required"]) == ["branch", "head_sha"]
    assert get_in(tools_by_name, ["attach_branch", "inputSchema", "properties", "head_sha", "type"]) == "string"

    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "properties", "head_sha", "type"]) == "string"
    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "then", "allOf"]) != nil

    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "properties", "number", "anyOf"]) == [
             %{"type" => "integer", "minimum" => 1},
             %{"type" => "string", "pattern" => "^[1-9][0-9]*$"}
           ]

    assert get_in(tools_by_name, ["attach_pr", "inputSchema", "properties", "metadata", "type"]) == "object"
    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "required"]) == ["metadata"]

    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "properties", "metadata", "type"]) == "object"
    assert get_in(tools_by_name, ["sync_pr", "inputSchema", "then", "allOf"]) != nil

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

    refute Map.has_key?(tools_by_name, "claim_work_key")
  end

  test "tools list returns Codex-compatible top-level input schemas for every surface", %{repo: repo} do
    assert {:ok, worker_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CODEX-SCHEMA-WORKER", kind: "mcp"))
    assert {:ok, worker_minted} = AccessGrantService.mint_worker_grant(repo, worker_package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, worker_minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: worker_minted.grant.secret_hash)

    {_anchor, architect_session, _grant} = create_phase_architect_session(repo, "SYMPP-CODEX-SCHEMA-ARCHITECT", ["read:phase"])

    surfaces = [
      {"unbound", Server.new(Config.default(repo: repo), initialized: true)},
      {"worker", Server.new(Config.default(repo: repo), initialized: true, session: worker_session)},
      {"architect", Server.new(test_mcp_config(repo), initialized: true, session: architect_session)}
    ]

    for {surface, server} <- surfaces,
        tool <- tools_for_server(server) do
      schema = Map.fetch!(tool, "inputSchema")

      assert schema["type"] == "object", "#{surface} #{tool["name"]} inputSchema must be a top-level object"

      forbidden = Map.take(schema, @codex_forbidden_top_level_schema_keys)
      assert forbidden == %{}, "#{surface} #{tool["name"]} has Codex-rejected top-level schema keys: #{inspect(Map.keys(forbidden))}"
    end
  end

  test "worker comment tools create list and resolve exact package comments only", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-MCP-COMMENTS", kind: "mcp", repo: "nextide/symphony-plus-plus", base_branch: "main"))

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    work_request =
      create_work_request!(
        repo,
        id: "WR-MCP-COMMENTS",
        repo: work_package.repo,
        base_branch: work_package.base_branch
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-COMMENTS", target_base_branch: work_package.base_branch)
             )

    repo.update!(Ecto.Changeset.change(planned_slice, status: "dispatched", work_package_id: work_package.id))

    work_request_comment_response =
      mcp_tool(repo, session, "add_comment", %{
        "work_package_id" => work_package.id,
        "target_kind" => "work_request",
        "target_id" => work_request.id,
        "body" => "This must stay architect-owned"
      })

    assert get_in(work_request_comment_response, ["error", "code"]) == -32_003
    assert get_in(work_request_comment_response, ["error", "data", "reason"]) == "outside_session_scope"

    planned_slice_comment_response =
      mcp_tool(repo, session, "add_comment", %{
        "work_package_id" => work_package.id,
        "target_kind" => "planned_slice",
        "target_id" => planned_slice.id,
        "body" => "This must stay architect-owned"
      })

    assert get_in(planned_slice_comment_response, ["error", "code"]) == -32_003
    assert get_in(planned_slice_comment_response, ["error", "data", "reason"]) == "outside_session_scope"

    overlong_response =
      mcp_tool(repo, session, "add_comment", %{
        "work_package_id" => work_package.id,
        "target_kind" => "work_package",
        "target_id" => work_package.id,
        "body" => String.duplicate("x", Comment.max_body_length() + 1)
      })

    assert get_in(overlong_response, ["error", "data", "reason"]) =~ "body"

    add_response =
      mcp_tool(repo, session, "add_comment", %{
        "work_package_id" => work_package.id,
        "target_kind" => "work_package",
        "target_id" => work_package.id,
        "body" => "Check sk-secret123 before merge"
      })

    assert comment_id = get_in(add_response, ["result", "structuredContent", "comment", "id"])
    assert get_in(add_response, ["result", "structuredContent", "comment", "body"]) == "Check [REDACTED] before merge"

    list_response =
      mcp_tool(repo, session, "list_comments", %{
        "work_package_id" => work_package.id,
        "target_kind" => "work_package",
        "target_id" => work_package.id
      })

    assert [%{"id" => ^comment_id, "status" => "open"}] = get_in(list_response, ["result", "structuredContent", "comments"])

    resolve_response =
      mcp_tool(repo, session, "resolve_comment", %{
        "comment_id" => comment_id,
        "resolution_note" => "Handled"
      })

    assert get_in(resolve_response, ["result", "structuredContent", "comment", "status"]) == "resolved"
    assert {:ok, %Comment{status: "resolved", source_type: "worker", author_name: "worker-1", resolved_by: "worker-1", resolved_source_type: "worker"}} = CommentService.get(repo, comment_id)

    assert {:ok, other_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-MCP-COMMENTS-OTHER", kind: "mcp"))

    assert {:ok, foreign_comment} =
             CommentService.create(repo, %{
               target_kind: "work_package",
               target_id: other_package.id,
               body: "Foreign",
               source_type: "worker",
               author_name: "other-worker"
             })

    out_of_scope_response =
      mcp_tool(repo, session, "list_comments", %{
        "work_package_id" => work_package.id,
        "target_kind" => "work_package",
        "target_id" => other_package.id
      })

    assert get_in(out_of_scope_response, ["error", "data", "reason"]) == "outside_session_scope"

    out_of_scope_resolve_response =
      mcp_tool(repo, session, "resolve_comment", %{
        "work_package_id" => work_package.id,
        "comment_id" => foreign_comment.id
      })

    assert get_in(out_of_scope_resolve_response, ["error", "data", "reason"]) == "not_found"
  end

  test "architect comment and blocker tools distinguish external WR notes from claimed descendants", %{repo: repo} do
    work_request =
      create_work_request!(
        repo,
        id: "WR-MCP-ARCH-PACKAGE-SURFACES",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(
        repo,
        id: "WR-MCP-ARCH-PACKAGE-SURFACES-SIBLING",
        repo: work_request.repo,
        base_branch: work_request.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-ARCH-PACKAGE-SURFACES", target_base_branch: work_request.base_branch)
             )

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-MCP-ARCH-PACKAGE-SURFACES",
                 kind: "mcp",
                 repo: work_request.repo,
                 base_branch: work_request.base_branch,
                 status: "implementing"
               )
             )

    repo.update!(Ecto.Changeset.change(planned_slice, status: "dispatched", work_package_id: work_package.id))

    {_phase_anchor, phase_session, _phase_grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-MCP-ARCH-PHASE-COMMENTS",
        [
          "read:work_request",
          "write:work_request"
        ],
        repo: work_request.repo,
        base_branch: work_request.base_branch
      )

    work_package =
      repo.update!(Ecto.Changeset.change(work_package, phase_id: phase_session.assignment.phase_id))

    external_response =
      mcp_tool(repo, phase_session, "add_comment", %{
        "target_kind" => "work_request",
        "target_id" => sibling.id,
        "body" => "External note without claiming lifecycle authority"
      })

    assert external_comment_id = get_in(external_response, ["result", "structuredContent", "comment", "id"])
    assert get_in(external_response, ["result", "structuredContent", "comment", "source_type"]) == "architect"

    external_resolve_response =
      mcp_tool(repo, phase_session, "resolve_comment", %{
        "comment_id" => external_comment_id,
        "resolution_note" => "Trying to close an external note"
      })

    assert get_in(external_resolve_response, ["error", "data", "reason"]) == "not_found"

    descendant_write_denied =
      mcp_tool(repo, phase_session, "add_comment", %{
        "target_kind" => "work_package",
        "target_id" => work_package.id,
        "body" => "Phase read scope is not descendant write authority"
      })

    assert get_in(descendant_write_denied, ["error", "code"]) == -32_003
    assert get_in(descendant_write_denied, ["error", "data", "reason"]) == "outside_session_scope"

    {_handoff_anchor, handoff_session, _handoff_grant} =
      create_work_request_handoff_architect_session(repo, work_request, [
        "read:work_request",
        "write:work_request"
      ])

    descendant_comment_response =
      mcp_tool(repo, handoff_session, "add_comment", %{
        "target_kind" => "work_package",
        "target_id" => work_package.id,
        "body" => "Descendant package guidance"
      })

    assert get_in(descendant_comment_response, ["result", "structuredContent", "comment", "target_id"]) == work_package.id

    phase_read_response =
      mcp_tool(repo, phase_session, "list_comments", %{
        "target_kind" => "work_package",
        "target_id" => work_package.id
      })

    assert get_in(phase_read_response, ["result", "structuredContent", "comments"])
           |> Enum.any?(&(&1["target_id"] == work_package.id))

    assert {:ok, _blocker_event} =
             PlanningRepository.append_audit_progress_event_for_work_package(repo, handoff_session.assignment, work_package.id, %{
               "summary" => "Waiting for architect",
               "idempotency_key" => "arch-policy-blocker",
               "payload" => %{
                 "type" => "blocker",
                 "source_tool" => "report_blocker",
                 "blocker_id" => "arch-policy-blocker",
                 "active" => true
               }
             })

    resolve_blocker_response =
      mcp_tool(repo, handoff_session, "resolve_blocker", %{
        "work_package_id" => work_package.id,
        "blocker_id" => "arch-policy-blocker",
        "resolution" => "Architect supplied the missing decision.",
        "summary" => "Cleared architect blocker",
        "idempotency_key" => "arch-policy-blocker-resolved"
      })

    assert get_in(resolve_blocker_response, ["result", "structuredContent", "progress_event", "payload", "active"]) == false
  end

  test "local operator WorkRequest note tools append comments and decisions with redacted provenance", %{repo: repo} do
    work_request =
      create_work_request!(
        repo,
        id: "WR-MCP-LOCAL-OPERATOR-NOTES",
        repo: "nextide/symphony-plus-plus",
        base_branch: "feature/sympp-v21-ledger-claims"
      )

    local_server = local_mcp_server(local_mcp_config(repo), "local-operator-notes-state")
    tools_by_name = tools_for_server(local_server) |> Map.new(&{&1["name"], &1})

    assert get_in(tools_by_name, ["claim_local_architect_assignment", "inputSchema", "required"]) == [
             "work_request_id",
             "architect_anchor_work_package_id",
             "repo",
             "base_branch",
             "caller_id",
             "claimed_by"
           ]

    assert get_in(tools_by_name, ["add_work_request_comment", "inputSchema", "required"]) == ["work_request_id", "body", "created_by"]

    assert get_in(tools_by_name, ["record_work_request_operator_decision", "inputSchema", "required"]) == [
             "work_request_id",
             "decision",
             "rationale",
             "scope_impact",
             "created_by"
           ]

    {comment_response, note_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-comment",
          "method" => "tools/call",
          "params" => %{
            "name" => "add_work_request_comment",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "body" => "Coordinate with ghp_localoperatorcomment before slicing",
              "created_by" => "operator sk-localoperatorauthor"
            }
          }
        },
        local_server
      )

    assert note_server.session == nil
    assert comment_id = get_in(comment_response, ["result", "structuredContent", "comment", "id"])
    assert get_in(comment_response, ["result", "structuredContent", "comment", "body"]) == "Coordinate with [REDACTED] before slicing"
    assert get_in(comment_response, ["result", "structuredContent", "comment", "source_type"]) == "operator"
    assert get_in(comment_response, ["result", "structuredContent", "comment", "author_name"]) == "operator [REDACTED]"
    assert get_in(comment_response, ["result", "structuredContent", "provenance", "created_by"]) == "operator [REDACTED]"

    assert {:ok, %Comment{body: "Coordinate with [REDACTED] before slicing", source_type: "operator", author_name: "operator [REDACTED]"}} =
             CommentService.get(repo, comment_id)

    decision_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-decision",
          "method" => "tools/call",
          "params" => %{
            "name" => "record_work_request_operator_decision",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "decision" => "Mirror result from ghp_localoperatordecision",
              "rationale" => "Related WR needs context from sk-localoperatorrationale",
              "scope_impact" => "Comment-only, no dispatch using bearer localoperatorbearer",
              "created_by" => "operator sk-localoperatordecisionauthor",
              "source_id" => "ghp_localoperatorsource"
            }
          }
        },
        note_server
      )

    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "source_type"]) == "operator"
    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "source_id"]) == "[REDACTED]"
    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "decision"]) == "Mirror result from [REDACTED]"
    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "rationale"]) == "Related WR needs context from [REDACTED]"
    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "scope_impact"]) == "Comment-only, no dispatch using [REDACTED]"
    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "created_by"]) == "operator [REDACTED]"

    assert {:ok, [decision]} = WorkRequestRepository.list_decisions(repo, work_request.id)
    assert decision.source_type == "operator"
    assert decision.source_id == "[REDACTED]"
    assert decision.decision == "Mirror result from [REDACTED]"
    assert decision.created_by == "operator [REDACTED]"

    dispatch_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-dispatch-denied",
          "method" => "tools/call",
          "params" => %{"name" => "dispatch_work_request_planned_slice", "arguments" => %{}}
        },
        note_server
      )

    assert get_in(dispatch_response, ["error", "data", "reason"]) == "claim_required"

    status_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-status-denied",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{}}
        },
        note_server
      )

    assert get_in(status_response, ["error", "data", "reason"]) == "claim_required"
  end

  test "local operator WorkRequest note tools reject nonlocal and remote database modes", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-OPERATOR-NOTES-DENIED")
    arguments = %{"work_request_id" => work_request.id, "body" => "safe note", "created_by" => "operator"}

    stdio_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "stdio-local-operator-denied",
          "method" => "tools/call",
          "params" => %{"name" => "add_work_request_comment", "arguments" => arguments}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(stdio_response, ["error", "code"]) == -32_001
    assert get_in(stdio_response, ["error", "data", "reason"]) == "local_mcp_required"

    remote_config = %{local_mcp_config(repo) | database: "https://ledger.example.test/mcp?token=ghp_remoteoperatorsecret"}

    implicit_state_tools =
      local_mcp_config(repo)
      |> Server.new(initialized: true, local_daemon_trusted: true)
      |> tools_for_server()
      |> Map.new(&{&1["name"], &1})

    remote_tools =
      remote_config
      |> local_mcp_server("remote-local-operator-list-state")
      |> tools_for_server()
      |> Map.new(&{&1["name"], &1})

    refute Map.has_key?(implicit_state_tools, "add_work_request_comment")
    refute Map.has_key?(implicit_state_tools, "record_work_request_operator_decision")
    refute Map.has_key?(remote_tools, "add_work_request_comment")
    refute Map.has_key?(remote_tools, "record_work_request_operator_decision")

    remote_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "remote-local-operator-denied",
          "method" => "tools/call",
          "params" => %{"name" => "add_work_request_comment", "arguments" => arguments}
        },
        local_mcp_server(remote_config, "remote-local-operator-denied-state")
      )

    assert get_in(remote_response, ["error", "code"]) == -32_001
    assert get_in(remote_response, ["error", "data", "reason"]) == "local_database_required"
    refute inspect(remote_response) =~ "ghp_remoteoperatorsecret"

    memory_configs = [
      %{local_mcp_config(repo) | database: ":memory:"},
      %{local_mcp_config(repo) | database: "file:sympp_local_operator_notes?mode=memory&cache=shared"}
    ]

    Enum.with_index(memory_configs, fn memory_config, index ->
      memory_tools =
        memory_config
        |> local_mcp_server("memory-local-operator-list-state-#{index}")
        |> tools_for_server()
        |> Map.new(&{&1["name"], &1})

      refute Map.has_key?(memory_tools, "add_work_request_comment")
      refute Map.has_key?(memory_tools, "record_work_request_operator_decision")

      memory_response =
        Server.handle(
          %{
            "jsonrpc" => "2.0",
            "id" => "memory-local-operator-denied-#{index}",
            "method" => "tools/call",
            "params" => %{"name" => "add_work_request_comment", "arguments" => arguments}
          },
          local_mcp_server(memory_config, "memory-local-operator-denied-state-#{index}")
        )

      assert get_in(memory_response, ["error", "code"]) == -32_001
      assert get_in(memory_response, ["error", "data", "reason"]) == "file_backed_database_required"
    end)
  end

  test "local operator WorkRequest note tools reject bound worker sessions", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-OPERATOR-BOUND-DENIED")

    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-LOCAL-OPERATOR-BOUND", kind: "mcp"))

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    worker_server = %{
      local_mcp_server(local_mcp_config(repo), "local-operator-worker-bound-state")
      | session: MCPHarness.session(worker_assignment, proof_hash: minted.grant.secret_hash)
    }

    worker_tools =
      worker_server
      |> tools_for_server()
      |> Map.new(&{&1["name"], &1})

    refute Map.has_key?(worker_tools, "add_work_request_comment")
    refute Map.has_key?(worker_tools, "record_work_request_operator_decision")

    response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-bound-denied",
          "method" => "tools/call",
          "params" => %{
            "name" => "add_work_request_comment",
            "arguments" => %{"work_request_id" => work_request.id, "body" => "safe note", "created_by" => "operator"}
          }
        },
        worker_server
      )

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "local_operator_unbound_session_required"
  end

  test "local operator WorkRequest note tools require initialized current sessions", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-OPERATOR-SESSION-DENIED")

    arguments = %{
      "work_request_id" => work_request.id,
      "body" => "safe note",
      "created_by" => "operator"
    }

    pre_initialize_server =
      Server.new(local_mcp_config(repo), local_daemon_trusted: true, state_key: "local-operator-pre-init-state")

    pre_initialize_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-pre-init-denied",
          "method" => "tools/call",
          "params" => %{"name" => "add_work_request_comment", "arguments" => arguments}
        },
        pre_initialize_server
      )

    assert get_in(pre_initialize_response, ["error", "code"]) == -32_000
    assert get_in(pre_initialize_response, ["error", "data", "reason"]) == "server_not_initialized"

    refresh_required_server = %{local_mcp_server(local_mcp_config(repo), "local-operator-refresh-state") | session_refresh_required: true}

    refresh_required_tools =
      refresh_required_server
      |> tools_for_server()
      |> Map.new(&{&1["name"], &1})

    refute Map.has_key?(refresh_required_tools, "add_work_request_comment")
    refute Map.has_key?(refresh_required_tools, "record_work_request_operator_decision")

    refresh_required_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-refresh-denied",
          "method" => "tools/call",
          "params" => %{"name" => "add_work_request_comment", "arguments" => arguments}
        },
        refresh_required_server
      )

    assert get_in(refresh_required_response, ["error", "code"]) == -32_001
    assert get_in(refresh_required_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(refresh_required_response, ["error", "data", "action"]) == "claim_private_handoff"
  end

  test "local operator WorkRequest note tools reject invalid local payload fields", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-OPERATOR-PAYLOAD-DENIED")
    local_server = local_mcp_server(local_mcp_config(repo), "local-operator-invalid-payload-state")

    invalid_creator_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-invalid-creator",
          "method" => "tools/call",
          "params" => %{
            "name" => "add_work_request_comment",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "body" => "safe note",
              "created_by" => %{"name" => "operator"}
            }
          }
        },
        local_server
      )

    assert get_in(invalid_creator_response, ["error", "code"]) == -32_602
    assert get_in(invalid_creator_response, ["error", "data", "reason"]) == "invalid_created_by"

    long_decision_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-long-decision",
          "method" => "tools/call",
          "params" => %{
            "name" => "record_work_request_operator_decision",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "decision" => String.duplicate("x", Comment.max_body_length() + 1),
              "rationale" => "safe rationale",
              "scope_impact" => "safe scope",
              "created_by" => "operator"
            }
          }
        },
        local_server
      )

    assert get_in(long_decision_response, ["error", "code"]) == -32_602
    assert get_in(long_decision_response, ["error", "data", "reason"]) == "decision_too_long"

    null_source_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-null-source",
          "method" => "tools/call",
          "params" => %{
            "name" => "record_work_request_operator_decision",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "decision" => "safe decision",
              "rationale" => "safe rationale",
              "scope_impact" => "safe scope",
              "created_by" => "operator",
              "source_id" => nil
            }
          }
        },
        local_server
      )

    assert get_in(null_source_response, ["error", "code"]) == -32_602
    assert get_in(null_source_response, ["error", "data", "reason"]) == "invalid_source_id"
  end

  test "tools list advertises Solo tools only for unbound sessions", %{repo: repo} do
    unbound_server = Server.new(Config.default(repo: repo), initialized: true)

    unbound_response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "solo-tools", "method" => "tools/list", "params" => %{}}, unbound_server)

    unbound_tools_by_name =
      unbound_response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    assert get_in(unbound_tools_by_name, ["solo_attach", "inputSchema", "required"]) == ["repo", "base_branch", "workspace_path", "caller_id"]
    assert get_in(unbound_tools_by_name, ["solo_append", "inputSchema", "required"]) == ["session_id", "entry_kind", "title"]
    assert get_in(unbound_tools_by_name, ["solo_append", "inputSchema", "properties", "payload", "type"]) == "object"
    assert get_in(unbound_tools_by_name, ["solo_show", "inputSchema", "required"]) == ["session_id"]
    assert get_in(unbound_tools_by_name, ["solo_list", "inputSchema", "required"]) == []
    assert get_in(unbound_tools_by_name, ["solo_update_status", "inputSchema", "required"]) == ["session_id", "current_status", "next_status"]

    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-SOLO-WORKER-TOOLS", kind: "mcp"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: minted.grant.secret_hash)

    worker_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "solo-worker-tools", "method" => "tools/list", "params" => %{}},
        Server.new(Config.default(repo: repo), initialized: true, session: worker_session)
      )

    worker_tools_by_name =
      worker_response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    refute Map.has_key?(worker_tools_by_name, "solo_attach")
    refute Map.has_key?(worker_tools_by_name, "solo_append")
    refute Map.has_key?(worker_tools_by_name, "solo_show")
    refute Map.has_key?(worker_tools_by_name, "solo_list")
    refute Map.has_key?(worker_tools_by_name, "solo_update_status")

    {_anchor, architect_session, _grant} = create_phase_architect_session(repo, "SYMPP-SOLO-ARCH-TOOLS", ["read:phase"])

    architect_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "solo-architect-tools", "method" => "tools/list", "params" => %{}},
        Server.new(test_mcp_config(repo), initialized: true, session: architect_session)
      )

    architect_tools_by_name =
      architect_response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    refute Map.has_key?(architect_tools_by_name, "solo_attach")
    refute Map.has_key?(architect_tools_by_name, "solo_append")
    refute Map.has_key?(architect_tools_by_name, "solo_show")
    refute Map.has_key?(architect_tools_by_name, "solo_list")
    refute Map.has_key?(architect_tools_by_name, "solo_update_status")
  end

  test "Solo MCP tools attach append show list redact and replay idempotent appends", %{repo: repo} do
    workspace_path = solo_workspace_path("happy")

    attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => workspace_path,
        "caller_id" => "codex-local",
        "title" => "Plan bearer abcdefghijkl"
      })

    assert get_in(attach_response, ["result", "structuredContent", "action"]) == "solo_attach"
    session = get_in(attach_response, ["result", "structuredContent", "solo_session"])
    assert session["id"] =~ "solo_"
    assert session["session_key"] =~ "solo_key_"
    assert session["title"] == "Plan [REDACTED]"

    append_args = %{
      "session_id" => session["id"],
      "entry_kind" => "progress",
      "title" => "Use ghp_abcdefgh",
      "body" => "Body bearer abcdefghijkl",
      "status" => "recorded",
      "idempotency_key" => "solo-entry-1",
      "payload" => %{"token" => "ghp_abcdefgh", "nested" => %{"url" => "https://example.test/?token=ghp_abcdefgh"}}
    }

    append_response = mcp_tool(repo, nil, "solo_append", append_args)
    entry = get_in(append_response, ["result", "structuredContent", "entry"])
    assert entry["entry_kind"] == "progress"
    assert entry["title"] == "Use [REDACTED]"
    assert entry["body"] == "Body [REDACTED]"
    assert entry["payload"]["token"] == "[REDACTED]"
    assert entry["payload"]["nested"]["url"] == "https://example.test/?token=[REDACTED]"

    replay_response = mcp_tool(repo, nil, "solo_append", %{append_args | "title" => "Changed retry"})
    replay_entry = get_in(replay_response, ["result", "structuredContent", "entry"])
    assert replay_entry["id"] == entry["id"]
    assert replay_entry["title"] == entry["title"]

    show_response = mcp_tool(repo, nil, "solo_show", %{"session_id" => session["id"]})
    assert get_in(show_response, ["result", "structuredContent", "solo_session", "id"]) == session["id"]
    assert [shown_entry] = get_in(show_response, ["result", "structuredContent", "entries"])
    assert shown_entry["id"] == entry["id"]

    list_response =
      mcp_tool(repo, nil, "solo_list", %{
        "repo" => " nextide/example ",
        "base_branch" => "main",
        "workspace_path" => workspace_path,
        "caller_id" => "codex-local",
        "status" => "active"
      })

    assert get_in(list_response, ["result", "structuredContent", "solo_sessions"]) |> Enum.map(& &1["id"]) == [session["id"]]
  end

  test "Solo MCP lifecycle updates follow the Solo Session service contract", %{repo: repo} do
    attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => solo_workspace_path("lifecycle"),
        "caller_id" => "codex-local"
      })

    session_id = get_in(attach_response, ["result", "structuredContent", "solo_session", "id"])

    pause_response =
      mcp_tool(repo, nil, "solo_update_status", %{
        "session_id" => session_id,
        "current_status" => "active",
        "next_status" => "paused"
      })

    assert get_in(pause_response, ["result", "structuredContent", "action"]) == "solo_update_status"
    assert get_in(pause_response, ["result", "structuredContent", "solo_session", "status"]) == "paused"

    resume_response =
      mcp_tool(repo, nil, "solo_update_status", %{
        "session_id" => session_id,
        "current_status" => "paused",
        "next_status" => "active"
      })

    assert get_in(resume_response, ["result", "structuredContent", "solo_session", "status"]) == "active"

    complete_response =
      mcp_tool(repo, nil, "solo_update_status", %{
        "session_id" => session_id,
        "current_status" => "active",
        "next_status" => "completed"
      })

    assert get_in(complete_response, ["result", "structuredContent", "solo_session", "status"]) == "completed"

    archive_response =
      mcp_tool(repo, nil, "solo_update_status", %{
        "session_id" => session_id,
        "current_status" => "completed",
        "next_status" => "archived"
      })

    assert get_in(archive_response, ["result", "structuredContent", "solo_session", "status"]) == "archived"
    assert is_binary(get_in(archive_response, ["result", "structuredContent", "solo_session", "archived_at"]))

    paused_attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => solo_workspace_path("paused-complete"),
        "caller_id" => "codex-local"
      })

    paused_session_id = get_in(paused_attach_response, ["result", "structuredContent", "solo_session", "id"])

    assert get_in(
             mcp_tool(repo, nil, "solo_update_status", %{
               "session_id" => paused_session_id,
               "current_status" => "active",
               "next_status" => "paused"
             }),
             ["result", "structuredContent", "solo_session", "status"]
           ) == "paused"

    assert get_in(
             mcp_tool(repo, nil, "solo_update_status", %{
               "session_id" => paused_session_id,
               "current_status" => "paused",
               "next_status" => "completed"
             }),
             ["result", "structuredContent", "solo_session", "status"]
           ) == "completed"
  end

  test "Solo MCP show returns a bounded recent entry window", %{repo: repo} do
    attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => solo_workspace_path("recent-window"),
        "caller_id" => "codex-local"
      })

    session_id = get_in(attach_response, ["result", "structuredContent", "solo_session", "id"])

    for index <- 1..55 do
      response =
        mcp_tool(repo, nil, "solo_append", %{
          "session_id" => session_id,
          "entry_kind" => "progress",
          "title" => "Entry #{index}",
          "idempotency_key" => "recent-window-#{index}"
        })

      assert get_in(response, ["result", "structuredContent", "entry", "sequence"]) == index
    end

    show_response = mcp_tool(repo, nil, "solo_show", %{"session_id" => session_id})
    show = get_in(show_response, ["result", "structuredContent"])

    assert show["entry_count"] == 55
    assert show["entries_returned"] == 50
    assert show["entries_truncated"] == true
    assert Enum.map(show["entries"], & &1["sequence"]) == Enum.to_list(6..55)
  end

  test "Solo MCP tools surface validation errors without mutating state", %{repo: repo} do
    invalid_attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => "relative/workspace",
        "caller_id" => "codex-local"
      })

    assert get_in(invalid_attach_response, ["error", "data", "reason"]) == "invalid_workspace_path"
    assert repo.aggregate(SoloSession, :count, :id) == 0

    attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => solo_workspace_path("validation"),
        "caller_id" => "codex-local"
      })

    session_id = get_in(attach_response, ["result", "structuredContent", "solo_session", "id"])

    invalid_append_response =
      mcp_tool(repo, nil, "solo_append", %{
        "session_id" => session_id,
        "entry_kind" => "progress",
        "title" => "Reject secret key",
        "idempotency_key" => "wk_" <> String.duplicate("A", 43)
      })

    assert get_in(invalid_append_response, ["error", "data", "reason"]) == "invalid_entry_idempotency_key"
    assert repo.aggregate(SoloSessionEntry, :count, :id) == 0
  end

  test "Solo MCP lifecycle errors are clean and do not mutate sessions", %{repo: repo} do
    attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => solo_workspace_path("lifecycle-errors"),
        "caller_id" => "codex-local"
      })

    session_id = get_in(attach_response, ["result", "structuredContent", "solo_session", "id"])
    assert {:ok, active_before} = SoloSessionRepository.get(repo, session_id)

    stale_response =
      mcp_tool(repo, nil, "solo_update_status", %{
        "session_id" => session_id,
        "current_status" => "paused",
        "next_status" => "completed"
      })

    assert get_in(stale_response, ["error", "data", "reason"]) == "stale_status"
    assert {:ok, active_after_stale} = SoloSessionRepository.get(repo, session_id)
    assert active_after_stale.status == "active"
    assert active_after_stale.last_activity_at == active_before.last_activity_at
    assert active_after_stale.updated_at == active_before.updated_at
    assert active_after_stale.archived_at == active_before.archived_at

    invalid_status_response =
      mcp_tool(repo, nil, "solo_update_status", %{
        "session_id" => session_id,
        "current_status" => "active",
        "next_status" => "claimed"
      })

    assert get_in(invalid_status_response, ["error", "data", "reason"]) == "invalid_status"
    assert {:ok, active_after_invalid_status} = SoloSessionRepository.get(repo, session_id)
    assert active_after_invalid_status.status == "active"
    assert active_after_invalid_status.last_activity_at == active_before.last_activity_at
    assert active_after_invalid_status.updated_at == active_before.updated_at

    invalid_transition_response =
      mcp_tool(repo, nil, "solo_update_status", %{
        "session_id" => session_id,
        "current_status" => "active",
        "next_status" => "active"
      })

    assert get_in(invalid_transition_response, ["error", "data", "reason"]) == "invalid_transition"
    assert {:ok, active_after_invalid_transition} = SoloSessionRepository.get(repo, session_id)
    assert active_after_invalid_transition.status == "active"
    assert active_after_invalid_transition.last_activity_at == active_before.last_activity_at
    assert active_after_invalid_transition.updated_at == active_before.updated_at

    missing_response =
      mcp_tool(repo, nil, "solo_update_status", %{
        "session_id" => "solo_missing",
        "current_status" => "active",
        "next_status" => "paused"
      })

    assert get_in(missing_response, ["error", "code"]) == -32_004
    assert get_in(missing_response, ["error", "data", "reason"]) == "not_found"
    assert repo.aggregate(SoloSession, :count, :id) == 1

    complete_response =
      mcp_tool(repo, nil, "solo_update_status", %{
        "session_id" => session_id,
        "current_status" => "active",
        "next_status" => "completed"
      })

    assert get_in(complete_response, ["result", "structuredContent", "solo_session", "status"]) == "completed"
    assert {:ok, completed_before} = SoloSessionRepository.get(repo, session_id)

    completed_to_active_response =
      mcp_tool(repo, nil, "solo_update_status", %{
        "session_id" => session_id,
        "current_status" => "completed",
        "next_status" => "active"
      })

    assert get_in(completed_to_active_response, ["error", "data", "reason"]) == "invalid_transition"
    assert {:ok, completed_after_invalid_transition} = SoloSessionRepository.get(repo, session_id)
    assert completed_after_invalid_transition.status == "completed"
    assert completed_after_invalid_transition.last_activity_at == completed_before.last_activity_at
    assert completed_after_invalid_transition.updated_at == completed_before.updated_at
  end

  test "Solo MCP calls from bound sessions fail before mutation", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-SOLO-BOUND-DENY", kind: "mcp"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: minted.grant.secret_hash)

    response =
      mcp_tool(
        repo,
        worker_session,
        "solo_attach",
        %{
          "repo" => "nextide/example",
          "base_branch" => "main",
          "workspace_path" => solo_workspace_path("bound"),
          "caller_id" => "codex-local"
        }
      )

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "solo_tools_require_unbound_session"
    assert repo.aggregate(SoloSession, :count, :id) == 0

    attach_response =
      mcp_tool(repo, nil, "solo_attach", %{
        "repo" => "nextide/example",
        "base_branch" => "main",
        "workspace_path" => solo_workspace_path("bound-lifecycle"),
        "caller_id" => "codex-local"
      })

    session_id = get_in(attach_response, ["result", "structuredContent", "solo_session", "id"])

    update_response =
      mcp_tool(
        repo,
        worker_session,
        "solo_update_status",
        %{
          "session_id" => session_id,
          "current_status" => "active",
          "next_status" => "paused"
        }
      )

    assert get_in(update_response, ["error", "code"]) == -32_001
    assert get_in(update_response, ["error", "data", "reason"]) == "solo_tools_require_unbound_session"
    assert {:ok, session} = SoloSessionRepository.get(repo, session_id)
    assert session.status == "active"
  end

  test "tools list advertises static architect schemas for architect sessions", %{repo: repo} do
    {_anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-TOOLS-LIST", [
        "create:child_work_package",
        "read:child_progress",
        "read:child_findings",
        "read:work_request",
        "write:work_request",
        "read:guidance_request",
        "write:guidance_request",
        "mint:child_worker_key",
        "revoke:child_worker_key",
        "read:phase",
        "dispatch:work_request",
        "approve:child_ready_state",
        "approve:scope_expansion",
        "request:child_replan",
        "merge:child_into_phase",
        "split:child_work_package",
        "publish:phase_update"
      ])

    server = Server.new(test_mcp_config(repo), initialized: true, session: session)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools = get_in(response, ["result", "tools"])
    tools_by_name = Map.new(tools, &{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "sympp.health")
    assert Map.has_key?(tools_by_name, "get_current_assignment")
    refute Map.has_key?(tools_by_name, "claim_work_key")

    for tool <- @architect_tool_names do
      assert Map.has_key?(tools_by_name, tool)
    end

    assert get_in(tools_by_name, ["list_work_requests", "inputSchema", "required"]) == []
    assert get_in(tools_by_name, ["list_work_requests", "inputSchema", "properties", "status", "type"]) == "string"
    assert get_in(tools_by_name, ["read_work_request", "inputSchema", "required"]) == ["work_request_id"]
    assert get_in(tools_by_name, ["read_work_request", "inputSchema", "properties", "work_request_id", "type"]) == "string"
    assert get_in(tools_by_name, ["read_work_request", "inputSchema", "properties", "include_planning_scratch", "type"]) == "boolean"
    assert get_in(tools_by_name, ["add_comment", "inputSchema", "required"]) == ["target_kind", "target_id", "body"]
    assert get_in(tools_by_name, ["list_comments", "inputSchema", "required"]) == ["target_kind", "target_id"]
    assert get_in(tools_by_name, ["resolve_comment", "inputSchema", "required"]) == ["comment_id"]
    assert get_in(tools_by_name, ["resolve_blocker", "inputSchema", "required"]) == ["work_package_id", "blocker_id", "resolution", "summary", "idempotency_key"]
    assert get_in(tools_by_name, ["read_work_request_delivery_board", "inputSchema", "required"]) == ["work_request_id"]
    assert get_in(tools_by_name, ["read_work_request_delivery_board", "inputSchema", "properties", "include_planning_scratch", "type"]) == "boolean"
    assert get_in(tools_by_name, ["reconcile_work_request", "inputSchema", "required"]) == ["work_request_id"]
    assert get_in(tools_by_name, ["reconcile_work_request", "inputSchema", "properties", "apply", "type"]) == "boolean"

    delivery_schema = get_in(tools_by_name, ["record_planned_slice_delivery", "inputSchema"])
    revoke_schema = get_in(tools_by_name, ["revoke_planned_slice_worker_key", "inputSchema"])

    assert delivery_schema["required"] == ["work_request_id", "planned_slice_id", "outcome", "idempotency_key"]
    assert get_in(delivery_schema, ["properties", "outcome", "enum"]) == ["pr_merged", "completed_no_pr", "superseded", "abandoned"]
    assert get_in(delivery_schema, ["properties", "idempotency_key", "description"]) =~ "Reusing the same key"
    assert get_in(delivery_schema, ["properties", "merge_commit_sha", "description"]) =~ "strong evidence"

    assert revoke_schema["required"] == ["work_request_id", "planned_slice_id", "grant_id", "reason"]
    assert get_in(revoke_schema, ["properties", "grant_id", "description"]) =~ "Raw worker secrets are never accepted or returned"

    assert get_in(tools_by_name, ["set_work_request_status", "inputSchema", "required"]) == ["work_request_id", "current_status", "next_status"]
    assert get_in(tools_by_name, ["ask_work_request_question", "inputSchema", "required"]) == ["work_request_id", "category", "question", "why_needed"]
    assert get_in(tools_by_name, ["ask_work_request_question", "inputSchema", "properties", "decision_prompt", "required"]) == ["tl_dr", "details", "options"]

    assert get_in(tools_by_name, ["answer_work_request_question", "inputSchema", "required"]) == [
             "work_request_id",
             "question_id",
             "answer"
           ]

    assert get_in(tools_by_name, ["answer_work_request_question", "inputSchema", "properties", "answered_by", "type"]) == "string"
    assert get_in(tools_by_name, ["answer_work_request_question", "inputSchema", "properties", "current_status", "description"]) =~ "Deprecated alias"
    assert get_in(tools_by_name, ["escalate_guidance_request", "inputSchema", "properties", "decision_prompt", "required"]) == ["tl_dr", "details", "options"]
    assert get_in(tools_by_name, ["close_work_request_question", "inputSchema", "required"]) == ["work_request_id", "question_id"]

    assert get_in(tools_by_name, ["answer_work_request_question_and_record_decision", "inputSchema", "required"]) == [
             "work_request_id",
             "question_id",
             "answer",
             "source_type",
             "decision",
             "rationale",
             "scope_impact"
           ]

    assert get_in(tools_by_name, ["record_work_request_decision", "inputSchema", "required"]) == [
             "work_request_id",
             "source_type",
             "decision",
             "rationale",
             "scope_impact",
             "created_by"
           ]

    assert get_in(tools_by_name, ["record_work_request_decision", "inputSchema", "properties", "source_id", "type"]) == "string"
    assert get_in(tools_by_name, ["record_work_request_decision", "inputSchema", "properties", "source_type", "enum"]) == DecisionLogEntry.source_types()

    assert get_in(tools_by_name, ["add_work_request_planned_slice", "inputSchema", "required"]) == [
             "work_request_id",
             "title",
             "goal",
             "work_package_kind",
             "target_base_branch",
             "owned_file_globs",
             "forbidden_file_globs",
             "acceptance_criteria",
             "validation_steps",
             "review_lanes",
             "stop_conditions"
           ]

    assert get_in(tools_by_name, ["add_work_request_planned_slice", "inputSchema", "properties", "owned_file_globs", "type"]) == "array"

    assert get_in(tools_by_name, ["add_work_request_planned_slice", "inputSchema", "properties", "owned_file_globs", "description"]) =~
             "`**` must be a complete path segment"

    planned_slice_kinds = get_in(tools_by_name, ["add_work_request_planned_slice", "inputSchema", "properties", "work_package_kind", "enum"])
    assert planned_slice_kinds == StateMachine.standalone_kinds()
    assert "docs" in planned_slice_kinds

    refute Map.has_key?(get_in(tools_by_name, ["add_work_request_planned_slice", "inputSchema", "properties", "forbidden_file_globs"]), "minItems")
    assert get_in(tools_by_name, ["add_work_request_planned_slice", "inputSchema", "properties", "branch_pattern", "type"]) == "string"

    assert get_in(tools_by_name, ["approve_work_request_planned_slice", "inputSchema", "required"]) == [
             "work_request_id",
             "planned_slice_id",
             "current_status"
           ]

    assert get_in(tools_by_name, ["skip_work_request_planned_slice", "inputSchema", "required"]) == [
             "work_request_id",
             "planned_slice_id",
             "current_status"
           ]

    assert get_in(tools_by_name, ["mark_work_request_sliced", "inputSchema", "required"]) == ["work_request_id", "current_status"]

    assert get_in(tools_by_name, ["dispatch_work_request_planned_slice", "inputSchema", "required"]) == [
             "work_request_id",
             "planned_slice_id",
             "claimed_by"
           ]

    assert get_in(tools_by_name, ["dispatch_work_request_planned_slice", "inputSchema", "properties", "secret_handoff", "type"]) == "string"
    assert get_in(tools_by_name, ["dispatch_work_request_planned_slice", "inputSchema", "properties", "secret_store_dir", "type"]) == "string"

    assert get_in(tools_by_name, ["dispatch_work_request_planned_slice", "inputSchema", "properties", "secret_handoff", "description"]) =~
             "Legacy recovery-only"

    assert get_in(tools_by_name, ["dispatch_work_request_planned_slice", "inputSchema", "properties", "secret_store_dir", "description"]) =~
             "Legacy recovery-only"

    assert get_in(tools_by_name, ["dispatch_work_request_planned_slice", "inputSchema", "properties", "legacy_private_handoff", "type"]) == "boolean"

    assert get_in(tools_by_name, ["dispatch_work_request_planned_slice", "inputSchema", "properties", "legacy_private_handoff", "description"]) =~
             "recovery-only"

    assert get_in(tools_by_name, ["dispatch_work_request_planned_slice", "inputSchema", "properties", "symphony_repo_root", "type"]) == "string"

    assert get_in(tools_by_name, ["dispatch_work_request_planned_slice", "inputSchema", "properties", "symphony_repo_root", "description"]) =~
             "helper/namespace repo root"

    assert get_in(tools_by_name, ["dispatch_work_request_planned_slice", "inputSchema", "properties", "repo_root", "deprecated"]) == true

    assert get_in(tools_by_name, ["dispatch_work_request_planned_slice", "inputSchema", "properties", "repo_root", "description"]) =~
             "Legacy compatibility alias"

    assert get_in(tools_by_name, ["prepare_work_package_worktree", "inputSchema", "required"]) == [
             "work_package_id",
             "target_repo_root",
             "base_branch",
             "branch"
           ]

    assert get_in(tools_by_name, ["prepare_work_package_worktree", "inputSchema", "properties", "target_repo_root", "description"]) =~
             "Target product repository root"

    assert get_in(tools_by_name, ["prepare_work_package_worktree", "inputSchema", "properties", "worktree_parent", "description"]) =~
             "safe Symphony++ worktree root"

    assert get_in(tools_by_name, ["cleanup_work_package_worktree", "inputSchema", "required"]) == [
             "work_package_id",
             "target_repo_root"
           ]

    assert get_in(tools_by_name, ["cleanup_work_package_worktree", "inputSchema", "properties", "target_repo_root", "description"]) =~
             "Target product repository root"

    assert get_in(tools_by_name, ["read_child_status", "inputSchema", "required"]) == ["work_package_id"]
    assert get_in(tools_by_name, ["read_child_status", "inputSchema", "properties", "work_package_id", "type"]) == "string"
    assert get_in(tools_by_name, ["read_phase_board", "inputSchema", "required"]) == ["phase_id"]
    assert get_in(tools_by_name, ["approve_scope_expansion", "inputSchema", "required"]) == ["work_package_id", "allowed_file_globs", "rationale"]
    assert get_in(tools_by_name, ["approve_scope_expansion", "inputSchema", "properties", "allowed_file_globs", "minItems"]) == 1
    assert get_in(tools_by_name, ["approve_child_ready_state", "inputSchema", "required"]) == ["work_package_id", "rationale"]
    assert get_in(tools_by_name, ["approve_child_ready_state", "inputSchema", "properties", "request_id", "type"]) == "string"
    assert get_in(tools_by_name, ["mint_child_worker_key", "inputSchema", "required"]) == ["work_package_id", "template"]
    assert get_in(tools_by_name, ["mint_child_worker_key", "inputSchema", "properties", "template", "type"]) == "object"
    assert get_in(tools_by_name, ["revoke_child_worker_key", "inputSchema", "required"]) == ["grant_id", "reason"]
    assert get_in(tools_by_name, ["revoke_child_worker_key", "inputSchema", "properties", "grant_id", "type"]) == "string"
    assert get_in(tools_by_name, ["merge_child_into_phase", "inputSchema", "required"]) == ["work_package_id", "merge_artifact"]
    assert get_in(tools_by_name, ["merge_child_into_phase", "inputSchema", "properties", "merge_artifact", "required"]) == ["status", "uri"]
    assert get_in(tools_by_name, ["split_work_package", "inputSchema", "properties", "child_specs", "minItems"]) == 1
  end

  test "tools list advertises planned-slice dispatch even when repo_root is not configured", %{repo: repo} do
    {_anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-DISPATCH-TOOLS-NO-ROOT", [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request",
        "read:phase"
      ])

    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "architect-tools-no-root", "method" => "tools/list", "params" => %{}}, server)

    tools_by_name =
      response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "list_work_requests")
    assert Map.has_key?(tools_by_name, "add_work_request_planned_slice")
    assert Map.has_key?(tools_by_name, "dispatch_work_request_planned_slice")
  end

  test "tools list advertises planned-slice dispatch when the ledger cannot be handed off", %{repo: repo} do
    {_anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-DISPATCH-TOOLS-MEMORY-DB", [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request",
        "read:phase"
      ])

    server = Server.new(Config.default(repo: repo, repo_root: test_repo_root(), database: ":memory:"), initialized: true, session: session)

    response =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "architect-tools-memory-db", "method" => "tools/list", "params" => %{}}, server)

    tools_by_name =
      response
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "list_work_requests")
    assert Map.has_key?(tools_by_name, "add_work_request_planned_slice")
    assert Map.has_key?(tools_by_name, "dispatch_work_request_planned_slice")
  end

  test "tools list cannot receive legacy WorkRequest architect sessions from grant creation", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-WR-TOOLS-LEGACY", kind: "mcp"))

    assert {:error, %Ecto.Changeset{} = changeset} =
             create_architect_work_key(repo, package.id, ["read:work_request", "write:work_request"])

    assert {"architect phase-scoped grants require phase scope", []} in Keyword.get_values(changeset.errors, :phase_id)
  end

  test "tools list keeps static architect schemas when phase scope snapshot is missing", %{repo: repo} do
    {_anchor, session, grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-TOOLS-MISSING-SCOPE", [
        "read:work_request",
        "write:work_request"
      ])

    repo.update_all(
      from(access_grant in AccessGrant, where: access_grant.id == ^grant.id),
      set: [scope_base_branch: nil]
    )

    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "missing-scope-architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools_by_name = response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    for tool <- @architect_tool_names do
      assert Map.has_key?(tools_by_name, tool)
    end
  end

  test "tools list keeps static architect schemas when phase anchor no longer matches frozen scope", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-TOOLS-DRIFTED-ANCHOR", [
        "read:work_request",
        "write:work_request"
      ])

    assert {:ok, _anchor} = WorkPackageRepository.update(repo, anchor.id, %{repo: "nextide/other"})

    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "drifted-anchor-architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools_by_name = response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "sympp.health")
    assert Map.has_key?(tools_by_name, "get_current_assignment")

    for tool <- @architect_tool_names do
      assert Map.has_key?(tools_by_name, tool)
    end
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

    assert Map.keys(tools_by_name) |> Enum.sort() == ["claim_private_handoff", "claim_work_key", "sympp.health"]
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

  test "tools list keeps static architect schemas while calls use live capabilities", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-LIVE-CAPABILITY-LIST", kind: "mcp"))

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:phase"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(%{architect_assignment | capabilities: []}, proof_hash: WorkKey.secret_hash(architect_work_key.secret))
    server = Server.new(Config.default(repo: repo), initialized: true, session: session)

    response = Server.handle(%{"jsonrpc" => "2.0", "id" => "live-capability-architect-tools", "method" => "tools/list", "params" => %{}}, server)
    tools_by_name = response |> get_in(["result", "tools"]) |> Map.new(&{&1["name"], &1})

    assert Map.has_key?(tools_by_name, "get_current_assignment")
    assert Map.has_key?(tools_by_name, "sympp.health")

    for tool <- @architect_tool_names do
      assert Map.has_key?(tools_by_name, tool)
    end

    denied_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "lifecycle-only-read-work-request",
          "method" => "tools/call",
          "params" => %{"name" => "list_work_requests", "arguments" => %{}}
        },
        server
      )

    assert get_in(denied_response, ["error", "code"]) == -32_003
    assert get_in(denied_response, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(denied_response, ["error", "data", "reason_code"]) == "insufficient_capability"
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

  test "direct calls fail closed for tools outside the session surface before argument validation", %{repo: repo} do
    unbound_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "unbound-worker-call",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"unexpected" => "value"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(unbound_response, ["error", "code"]) == -32_001
    assert get_in(unbound_response, ["error", "data", "resource"]) == "append_progress"
    assert get_in(unbound_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(unbound_response, ["error", "data", "action"]) == "claim_work_key"

    unbound_guidance_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "unbound-guidance-call",
          "method" => "tools/call",
          "params" => %{"name" => "read_guidance_request", "arguments" => %{"unexpected" => "value"}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(unbound_guidance_response, ["error", "code"]) == -32_001
    assert get_in(unbound_guidance_response, ["error", "data", "resource"]) == "read_guidance_request"
    assert get_in(unbound_guidance_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(unbound_guidance_response, ["error", "data", "action"]) == "claim_work_key"

    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-WORKER-CALL", kind: "mcp"))
    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["read:phase"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    architect_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "architect-worker-call",
          "method" => "tools/call",
          "params" => %{"name" => "append_progress", "arguments" => %{"unexpected" => "value"}}
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(architect_response, ["error", "code"]) == -32_001
    assert get_in(architect_response, ["error", "data", "resource"]) == "append_progress"
    assert get_in(architect_response, ["error", "data", "reason"]) == "worker_grant_required"
    assert {:ok, []} = PlanningRepository.list_progress_events(repo, package.id)

    hidden_shared_tool_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "architect-hidden-shared-tool-call",
          "method" => "tools/call",
          "params" => %{"name" => "read_guidance_request", "arguments" => %{"unexpected" => "value"}}
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(hidden_shared_tool_response, ["error", "code"]) == -32_001
    assert get_in(hidden_shared_tool_response, ["error", "data", "resource"]) == "read_guidance_request"
    assert get_in(hidden_shared_tool_response, ["error", "data", "reason"]) == "insufficient_capability"
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
        config: Config.default(repo: repo, source_revision: "ABCDEF1234567890ABCDEF1234567890ABCDEF12")
      )

    result = get_in(response, ["result", "structuredContent"])
    text = get_in(response, ["result", "content", Access.at(0), "text"])

    assert result["status"] == "ok"
    assert result["ledger"]["reachable"] == true
    assert get_in(result, ["ledger", "identity", "kind"]) == "sqlite"
    assert get_in(result, ["ledger", "identity", "source"]) == "default"
    assert result["mode"] == "stdio"
    assert result["source"] == %{"revision" => "abcdef1234567890abcdef1234567890abcdef12"}
    refute text =~ "SYMPP-P3-001"
  end

  test "version resource includes source revision for stale daemon diagnostics", %{repo: repo} do
    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "version", "method" => "resources/read", "params" => %{"uri" => "sympp://health/version"}},
        config: Config.default(repo: repo, source_revision: "0123456789abcdef0123456789abcdef01234567")
      )

    assert %{"result" => %{"contents" => [%{"text" => text}]}} = response
    payload = Jason.decode!(text)

    assert payload["mode"] == "stdio"
    assert payload["source"] == %{"revision" => "0123456789abcdef0123456789abcdef01234567"}
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
    assert result["ledger"]["reachable"] == false
    assert result["ledger"]["error"] == "ledger_unavailable"
    assert get_in(result, ["ledger", "identity"]) == %{"kind" => "unknown", "source" => "default"}
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

  test "claim_local_assignment claims and reconnects a worker session from scoped local identity", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-RECONNECT")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)
    config = local_mcp_config(repo)

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-RECONNECT",
        repo: package.repo,
        base_branch: package.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-LOCAL-RECONNECT",
                 target_base_branch: package.base_branch,
                 branch_pattern: package.branch_pattern
               )
             )

    repo.update!(Ecto.Changeset.change(planned_slice, work_package_id: package.id))

    {claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(config, "local-claim-state")
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
    assert get_in(claim_response, ["result", "structuredContent", "assignment", "claimed_by"]) == "local-worker-1"
    assert get_in(claim_response, ["result", "structuredContent", "local_claim", "mode"]) == "local-http"
    refute inspect(claim_response) =~ minted.work_key.secret
    assert claimed_server.session.assignment.work_package_id == package.id
    assert claimed_server.session.proof_hash == minted.grant.secret_hash

    assert {:ok, claimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert claimed_grant.claimed_by == "local-worker-1"

    assert %ClaimLease{actor_display_name: "local-worker-1"} =
             repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id))

    {reconnect_response, reconnected_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-reconnect",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" =>
              arguments
              |> Map.put("work_request_id", work_request.id)
          }
        },
        local_mcp_server(config, "local-reconnect-state")
      )

    assert get_in(reconnect_response, ["result", "structuredContent", "assignment", "grant_id"]) == minted.grant.id
    assert get_in(reconnect_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "heartbeat"

    assignment_response =
      Server.handle(
        %{"jsonrpc" => "2.0", "id" => "assignment", "method" => "tools/call", "params" => %{"name" => "get_current_assignment"}},
        reconnected_server
      )

    assert get_in(assignment_response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
  end

  test "claim_local_assignment rejects heartbeat from a different caller_id", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-CALLER-ISOLATION")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)

    {claim_response, _claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-caller-isolation-initial",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-caller-isolation-initial-state")
      )

    assert get_in(claim_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "created"
    assert {:ok, %ClaimLease{id: lease_id, last_seen_at: last_seen_at}} = ClaimLeaseService.current_for_work_package(repo, package.id)

    {other_caller_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-caller-isolation-other",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => Map.put(arguments, "caller_id", "codex-local-test-other")
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-caller-isolation-other-state")
      )

    assert get_in(other_caller_response, ["error", "data", "reason"]) == "claim_lease_active_for_other_actor"
    assert get_in(other_caller_response, ["error", "data", "action"]) == "reuse_claim_identity_or_recycle_stale_claim"
    assert get_in(other_caller_response, ["error", "data", "hint"]) =~ "Reuse the ledger claim values"

    assert {:ok, %ClaimLease{id: ^lease_id, status: "active", last_seen_at: ^last_seen_at}} =
             ClaimLeaseService.current_for_work_package(repo, package.id)

    assert repo.aggregate(
             from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id and claim_lease.status != "active"),
             :count
           ) == 0
  end

  test "claim_local_assignment rejects duplicate caller before grant binding", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-CALLER-IN-FLIGHT")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)

    assert {:ok, %ClaimLease{id: lease_id}} =
             ClaimLeaseService.claim(
               repo,
               package.id,
               local_assignment_claim_actor(arguments),
               stale_after_ms: :timer.minutes(5)
             )

    {other_caller_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-caller-in-flight-other",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => Map.put(arguments, "caller_id", "codex-local-test-overlap")
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-caller-in-flight-other-state")
      )

    assert get_in(other_caller_response, ["error", "data", "reason"]) == "claim_lease_active_for_other_actor"
    assert get_in(other_caller_response, ["error", "data", "action"]) == "reuse_claim_identity_or_recycle_stale_claim"
    assert get_in(other_caller_response, ["error", "data", "hint"]) =~ "Reuse the ledger claim values"

    assert {:ok, %ClaimLease{id: ^lease_id, status: "active", actor_display_name: "local-worker-1"}} =
             ClaimLeaseService.current_for_work_package(repo, package.id)

    assert repo.aggregate(
             from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id and claim_lease.status != "active"),
             :count
           ) == 0
  end

  test "claim_local_assignment claims the newest live worker grant", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-NEWEST-GRANT")
    assert {:ok, older} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, newer} = AccessGrantService.mint_worker_grant(repo, package.id)

    repo.update!(
      Ecto.Changeset.change(older.grant,
        inserted_at: ~U[2026-01-01 00:00:00.000000Z],
        updated_at: ~U[2026-01-01 00:00:00.000000Z]
      )
    )

    repo.update!(
      Ecto.Changeset.change(newer.grant,
        inserted_at: ~U[2026-01-02 00:00:00.000000Z],
        updated_at: ~U[2026-01-02 00:00:00.000000Z]
      )
    )

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-newest-grant",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "local-newest-grant-state")
      )

    assert get_in(response, ["result", "structuredContent", "assignment", "grant_id"]) == newer.grant.id
    assert {:ok, unclaimed_older} = AccessGrantRepository.get(repo, older.grant.id)
    assert unclaimed_older.claimed_at == nil
  end

  test "claim_local_assignment accepts prepared concrete branch for templated package branch", %{repo: repo} do
    package =
      create_local_claim_package!(repo, "SYMPP-LOCAL-PREPARED-BRANCH", branch_pattern: "agent/{{work_package_id}}/{{slug}}")

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    prepared_branch = "agent/SYMPP-LOCAL-PREPARED-BRANCH/final-review-corrections"
    File.mkdir_p!(Path.join(package.worktree_path, ".git"))
    File.write!(Path.join([package.worktree_path, ".git", "HEAD"]), "ref: refs/heads/#{prepared_branch}\n")

    try do
      {response, claimed_server} =
        Server.handle_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "local-prepared-branch",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_local_assignment",
              "arguments" => local_assignment_claim_args(package, %{"branch" => prepared_branch})
            }
          },
          local_mcp_server(local_mcp_config(repo), "local-prepared-branch-state")
        )

      assert get_in(response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
      assert claimed_server.session.assignment.work_package_id == package.id
      refute inspect(response) =~ minted.work_key.secret
    after
      File.rm_rf!(package.worktree_path)
    end
  end

  test "claim_local_assignment rejects unrelated prepared branch for templated package branch", %{repo: repo} do
    package =
      create_local_claim_package!(repo, "SYMPP-LOCAL-TEMPLATE-BRANCH-SCOPE", branch_pattern: "agent/{{work_package_id}}/{{slug}}")

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    unrelated_branch = "feature/main-retarget"
    File.mkdir_p!(Path.join(package.worktree_path, ".git"))
    File.write!(Path.join([package.worktree_path, ".git", "HEAD"]), "ref: refs/heads/#{unrelated_branch}\n")

    try do
      {response, _server} =
        Server.handle_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "local-template-branch-scope",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_local_assignment",
              "arguments" => local_assignment_claim_args(package, %{"branch" => unrelated_branch})
            }
          },
          local_mcp_server(local_mcp_config(repo), "local-template-branch-scope-state")
        )

      assert get_in(response, ["error", "data", "reason"]) == "branch_scope_mismatch"
      assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
      assert unclaimed_grant.claimed_at == nil
    after
      File.rm_rf!(package.worktree_path)
    end
  end

  test "claim_local_assignment diagnoses legacy wildcard branch patterns before claiming", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-WILDCARD-BRANCH")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    repo.update_all(
      from(work_package in WorkPackage, where: work_package.id == ^package.id),
      set: [branch_pattern: "feat/live-triggers-v1-native-audio-evidence-*"]
    )

    wildcard_package = repo.get!(WorkPackage, package.id)
    prepared_branch = "feat/live-triggers-v1-native-audio-evidence-worker"
    File.mkdir_p!(Path.join(wildcard_package.worktree_path, ".git"))
    File.write!(Path.join([wildcard_package.worktree_path, ".git", "HEAD"]), "ref: refs/heads/#{prepared_branch}\n")

    try do
      {response, _server} =
        Server.handle_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "local-wildcard-branch-pattern",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_local_assignment",
              "arguments" => local_assignment_claim_args(wildcard_package, %{"branch" => prepared_branch})
            }
          },
          local_mcp_server(local_mcp_config(repo), "local-wildcard-branch-pattern-state")
        )

      assert get_in(response, ["error", "code"]) == -32_602
      assert get_in(response, ["error", "data", "reason"]) == "unsupported_branch_pattern_wildcard"
      assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
      assert unclaimed_grant.claimed_at == nil
      refute repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id))
    after
      File.rm_rf!(wildcard_package.worktree_path)
    end
  end

  test "claim_local_assignment rejects literal templated branch without prepared git metadata", %{repo: repo} do
    package =
      create_local_claim_package!(repo, "SYMPP-LOCAL-TEMPLATE-UNPREPARED", branch_pattern: "agent/{{work_package_id}}/{{slug}}")

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-template-unprepared",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => local_assignment_claim_args(package, %{"branch" => package.branch_pattern})
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-template-unprepared-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "branch_scope_mismatch"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
    refute repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id))
  end

  test "claim_local_assignment rejects retargeted branch for concrete package branch", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-RETARGETED-BRANCH")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    retargeted_branch = "agent/SYMPP-LOCAL-RETARGETED-BRANCH/retargeted"
    File.mkdir_p!(Path.join(package.worktree_path, ".git"))
    File.write!(Path.join([package.worktree_path, ".git", "HEAD"]), "ref: refs/heads/#{retargeted_branch}\n")

    try do
      {response, _server} =
        Server.handle_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "local-retargeted-branch",
            "method" => "tools/call",
            "params" => %{
              "name" => "claim_local_assignment",
              "arguments" => local_assignment_claim_args(package, %{"branch" => retargeted_branch})
            }
          },
          local_mcp_server(local_mcp_config(repo), "local-retargeted-branch-state")
        )

      assert get_in(response, ["error", "data", "reason"]) == "branch_scope_mismatch"
      assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
      assert unclaimed_grant.claimed_at == nil
      refute repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id))
    after
      File.rm_rf!(package.worktree_path)
    end
  end

  test "claim_local_assignment rereads same-worker lease after concurrent local insert race", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-CLAIM-RACE")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    LocalClaimInsertRaceRepo.arm()

    try do
      {response, _server} =
        Server.handle_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "local-claim-race",
            "method" => "tools/call",
            "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
          },
          local_mcp_server(local_mcp_config(LocalClaimInsertRaceRepo), "local-claim-race-state")
        )

      assert get_in(response, ["result", "structuredContent", "assignment", "work_package_id"]) == package.id
      assert get_in(response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "heartbeat"
      refute inspect(response) =~ minted.work_key.secret
    after
      LocalClaimInsertRaceRepo.disarm()
    end

    assert %ClaimLease{actor_display_name: "local-worker-1"} =
             repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id))

    assert {:ok, claimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert claimed_grant.claimed_by == "local-worker-1"
  end

  test "claim_local_assignment preserves other-worker lease after concurrent local insert race", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-CLAIM-RACE-OTHER")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    LocalClaimInsertRaceRepo.arm(%{
      actor_id: "local:other-worker",
      actor_display_name: "other-worker"
    })

    try do
      {response, _server} =
        Server.handle_state(
          %{
            "jsonrpc" => "2.0",
            "id" => "local-claim-race-other",
            "method" => "tools/call",
            "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
          },
          local_mcp_server(local_mcp_config(LocalClaimInsertRaceRepo), "local-claim-race-other-state")
        )

      assert get_in(response, ["error", "data", "reason"]) == "active_claim_exists"
      refute inspect(response) =~ minted.work_key.secret
    after
      LocalClaimInsertRaceRepo.disarm()
    end

    assert %ClaimLease{actor_display_name: "other-worker"} =
             repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id))

    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
  end

  test "claim_local_assignment rejects wrong local scope without claiming the grant", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-WRONG-SCOPE")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-wrong-scope",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => local_assignment_claim_args(package, %{"base_branch" => "main"})
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-wrong-scope-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "base_branch_scope_mismatch"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
    assert unclaimed_grant.claimed_by == nil
  end

  test "claim_local_assignment rejects packages without recorded local worktree scope", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-MISSING-WORKTREE", worktree_path: nil)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-missing-worktree",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => local_assignment_claim_args(package, %{"worktree_path" => local_claim_worktree_path(package.id)})
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-missing-worktree-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "worktree_scope_required"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
  end

  test "claim_local_assignment rejects terminal work packages before claiming", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-TERMINAL", status: "closed")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-terminal",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "local-terminal-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "work_package_terminal"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
    assert unclaimed_grant.claimed_by == nil
    assert repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id)) == nil
  end

  test "claim_local_assignment requires local daemon generated state", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-TRUST-REQUIRED")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-trust-required",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        Server.new(local_mcp_config(repo), initialized: true, state_key: "caller-supplied-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "local_daemon_trust_required"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
  end

  test "claim_local_assignment requires explicit local HTTP MCP state", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-STATE-REQUIRED")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-state-required",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        Server.new(local_mcp_config(repo), initialized: true)
      )

    assert get_in(response, ["error", "data", "reason"]) == "local_mcp_session_required"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
    assert repo.one(from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id)) == nil
  end

  test "claim_local_assignment returns invalid params for malformed arguments", %{repo: repo} do
    response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-malformed-arguments",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => []}
        },
        local_mcp_server(local_mcp_config(repo), "local-malformed-arguments-state")
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "invalid_tool_arguments"
  end

  test "claim_local_assignment treats paused leases as pause exempt instead of stale", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-PAUSED-LEASE")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)

    {_claim_response, _claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-paused-initial",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-paused-initial-state")
      )

    assert {:ok, %ClaimLease{id: lease_id} = lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert {:ok, paused_lease} = ClaimLeaseService.pause(repo, lease.id, %{"actor_id" => "operator"}, reason: "operator pause")

    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -10, :second)

    paused_lease
    |> ClaimLease.update_changeset(%{last_seen_at: stale_seen_at, stale_after_ms: 1})
    |> repo.update!()

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-paused-reclaim-denied",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-paused-reclaim-denied-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "claim_lease_paused"
    assert {:ok, %ClaimLease{id: ^lease_id, status: "paused"}} = ClaimLeaseService.current_for_work_package(repo, package.id)

    assert repo.aggregate(
             from(claim_lease in ClaimLease, where: claim_lease.work_package_id == ^package.id and claim_lease.status == "reclaimed"),
             :count
           ) == 0
  end

  test "claim_local_assignment records audit evidence when reclaiming a stale lease", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-STALE-RECLAIM")
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    assert {:ok, stale_lease} =
             ClaimLeaseService.claim(
               repo,
               package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:stale-worker", "actor_display_name" => "stale-worker"},
               now: DateTime.add(DateTime.utc_now(:microsecond), -10, :second),
               stale_after_ms: 1
             )

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-stale-reclaim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "local-stale-reclaim-state")
      )

    assert get_in(response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "reclaimed"
    assert get_in(response, ["result", "structuredContent", "local_claim", "reason_codes"]) == ["claim_lease_reclaimed", "worker_recycled"]
    assert get_in(response, ["result", "structuredContent", "local_claim", "claim_event", "status"]) == "claim_lease_reclaimed"

    assert {:ok, reclaimed_lease} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert reclaimed_lease.previous_claim_id == stale_lease.id

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.any?(progress_events, &(&1.status == "claim_lease_reclaimed" and &1.payload["previous_claim_id"] == stale_lease.id))
  end

  test "claim_local_assignment rolls back reclaimed leases when audit append fails", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-RECLAIM-AUDIT-FAILS")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    assert {:ok, stale_lease} =
             ClaimLeaseService.claim(
               repo,
               package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:stale-worker", "actor_display_name" => "stale-worker"},
               now: DateTime.add(DateTime.utc_now(:microsecond), -2, :second),
               stale_after_ms: 1
             )

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-reclaim-audit-fails",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(LocalClaimAuditFailureRepo), "local-reclaim-audit-fails-state")
      )

    assert get_in(response, ["error", "data", "reason"]) =~ "forced_reclaim_audit_failure"
    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, package.id)

    assert {:ok, revoked_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert revoked_grant.revoked_at != nil

    statuses =
      repo.all(
        from(claim_lease in ClaimLease,
          where: claim_lease.work_package_id == ^package.id,
          select: {claim_lease.id, claim_lease.status, claim_lease.release_reason}
        )
      )

    assert {stale_lease.id, "reclaimed", nil} in statuses
    assert Enum.any?(statuses, fn {_id, status, reason} -> status == "released" and reason == "local_assignment_claim_failed" end)
  end

  test "claim_local_assignment releases reclaimed leases when grant binding fails", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-RECLAIM-FAILS")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    assert {:ok, _stale_lease} =
             ClaimLeaseService.claim(
               repo,
               package.id,
               %{"actor_kind" => "agent", "actor_id" => "local:stale-worker", "actor_display_name" => "stale-worker"},
               now: DateTime.add(DateTime.utc_now(:microsecond), -2, :second),
               stale_after_ms: 1
             )

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-reclaim-fails",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => local_assignment_claim_args(package)}
        },
        local_mcp_server(local_mcp_config(repo), "local-reclaim-fails-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "revoked"
    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, package.id)

    statuses =
      repo.all(
        from(claim_lease in ClaimLease,
          where: claim_lease.work_package_id == ^package.id,
          select: {claim_lease.status, claim_lease.release_reason}
        )
      )

    assert {"reclaimed", nil} in statuses
    assert {"released", "local_assignment_claim_failed"} in statuses
  end

  test "claim_local_assignment releases existing heartbeat leases when permanent grant binding fails", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-HEARTBEAT-FAILS")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)

    {_claim_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-heartbeat-initial",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-heartbeat-initial-state")
      )

    assert {:ok, %ClaimLease{id: lease_id, status: "active"}} = ClaimLeaseService.current_for_work_package(repo, package.id)
    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-heartbeat-fails",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-heartbeat-fails-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "revoked"
    assert {:error, :not_found} = ClaimLeaseService.current_for_work_package(repo, package.id)

    statuses =
      repo.all(
        from(claim_lease in ClaimLease,
          where: claim_lease.work_package_id == ^package.id,
          select: {claim_lease.id, claim_lease.status, claim_lease.release_reason}
        )
      )

    assert {lease_id, "released", "local_assignment_claim_failed"} in statuses

    assert {:ok, replacement} = AccessGrantService.mint_worker_grant(repo, package.id)

    {replacement_response, _replacement_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-heartbeat-replacement",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" =>
              local_assignment_claim_args(package, %{
                "caller_id" => "codex-local-replacement",
                "claimed_by" => "replacement-worker"
              })
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-heartbeat-replacement-state")
      )

    assert get_in(replacement_response, ["result", "structuredContent", "assignment", "grant_id"]) == replacement.grant.id
  end

  test "claim_local_assignment releases authority-lost leases before replacement worker claim", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-AUTHORITY-LOST")
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)

    {_claim_response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-authority-lost-initial",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(local_mcp_config(repo), "local-authority-lost-initial-state")
      )

    assert {:ok, %ClaimLease{id: original_lease_id, actor_display_name: "local-worker-1"}} =
             ClaimLeaseService.current_for_work_package(repo, package.id)

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)
    assert {:ok, replacement} = AccessGrantService.mint_worker_grant(repo, package.id)

    {replacement_response, _replacement_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-authority-lost-replacement",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" =>
              local_assignment_claim_args(package, %{
                "caller_id" => "codex-local-authority-lost-replacement",
                "claimed_by" => "replacement-worker"
              })
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-authority-lost-replacement-state")
      )

    assert get_in(replacement_response, ["result", "structuredContent", "assignment", "grant_id"]) == replacement.grant.id
    assert get_in(replacement_response, ["result", "structuredContent", "local_claim", "claim_lease_action"]) == "reclaimed"

    assert {:ok, %ClaimLease{actor_display_name: "replacement-worker", status: "active"}} =
             ClaimLeaseService.current_for_work_package(repo, package.id)

    statuses =
      repo.all(
        from(claim_lease in ClaimLease,
          where: claim_lease.work_package_id == ^package.id,
          select: {claim_lease.id, claim_lease.status, claim_lease.release_reason}
        )
      )

    assert {original_lease_id, "released", "local_assignment_claim_authority_lost"} in statuses
  end

  test "claim_local_assignment rejects cross-branch WorkRequest scope", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-WR-BASE-MISMATCH")

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-LOCAL-BASE-MISMATCH",
        repo: package.repo,
        base_branch: "main",
        status: "ready_for_slicing"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-LOCAL-BASE-MISMATCH",
                 target_base_branch: package.base_branch,
                 branch_pattern: package.branch_pattern
               )
             )

    repo.update!(Ecto.Changeset.change(planned_slice, work_package_id: package.id))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)

    {response, _server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-wr-base-mismatch",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_local_assignment",
            "arguments" => local_assignment_claim_args(package, %{"work_request_id" => work_request.id})
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-wr-base-mismatch-state")
      )

    assert get_in(response, ["error", "data", "reason"]) == "work_request_scope_mismatch"
    assert {:ok, unclaimed_grant} = AccessGrantRepository.get(repo, minted.grant.id)
    assert unclaimed_grant.claimed_at == nil
  end

  test "final sync tools remain idempotent after claim_local_assignment reconnect", %{repo: repo} do
    package = create_local_claim_package!(repo, "SYMPP-LOCAL-FINAL-SYNC", status: "ci_waiting")
    append_done_plan(repo, package.id)
    assert {:ok, _minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    arguments = local_assignment_claim_args(package)
    config = local_mcp_config(repo)

    {_claim_response, claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-final-sync-claim",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(config, "local-final-sync-claim-state")
      )

    head_sha = "abcdef1234567890abcdef1234567890abcdef12"
    attach_tool(repo, claimed_server.session, "attach_branch", %{"branch" => package.branch_pattern, "head_sha" => head_sha})
    attach_tool(repo, claimed_server.session, "attach_pr", %{"number" => 258, "head_sha" => head_sha})

    sync_args = %{
      "number" => 258,
      "metadata" => %{"head_sha" => head_sha, "check_summary" => %{"conclusion" => "success"}}
    }

    sync_response = attach_tool(repo, claimed_server.session, "sync_pr", sync_args)

    review_args = %{
      "summary" => "Ready after local reconnect",
      "tests" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp_test.exs"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    }

    review_response = attach_tool(repo, claimed_server.session, "submit_review_package", review_args)

    {_reconnect_response, reconnected_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-final-sync-reconnect",
          "method" => "tools/call",
          "params" => %{"name" => "claim_local_assignment", "arguments" => arguments}
        },
        local_mcp_server(config, "local-final-sync-reconnect-state")
      )

    sync_replay_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "sync-replay", "method" => "tools/call", "params" => %{"name" => "sync_pr", "arguments" => sync_args}},
        repo: repo,
        session: reconnected_server.session
      )

    review_replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "review-replay",
          "method" => "tools/call",
          "params" => %{"name" => "submit_review_package", "arguments" => review_args}
        },
        repo: repo,
        session: reconnected_server.session
      )

    assert get_in(sync_replay_response, ["result", "structuredContent", "progress_event", "id"]) ==
             get_in(sync_response, ["result", "structuredContent", "progress_event", "id"])

    assert get_in(review_replay_response, ["result", "structuredContent", "progress_event", "id"]) ==
             get_in(review_response, ["result", "structuredContent", "progress_event", "id"])

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.count(progress_events, &(&1.status == "pr_synced")) == 1
    assert Enum.count(progress_events, &(&1.status == "review_package_submitted")) == 1
  end

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

  test "create_work_request creates provenance and a claimable redacted architect handoff", %{repo: repo} do
    store_dir = Path.join(test_handoff_store_dir(), "create-work-request")
    previous_store_dir = Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir)
    Application.put_env(:symphony_elixir, :sympp_worker_secret_store_dir, store_dir)

    on_exit(fn ->
      restore_app_env(:sympp_worker_secret_store_dir, previous_store_dir)
      File.rm_rf(store_dir)
    end)

    response =
      mcp_tool(
        repo,
        nil,
        "create_work_request",
        %{
          "repo" => "nextide/symphony-plus-plus",
          "base_branch" => "main",
          "title" => "Agent-created WorkRequest",
          "description" => "Create a WorkRequest and continue as architect.",
          "request_kind" => "feature",
          "claimed_by" => "kraken-beta-arch"
        },
        config: Config.default(repo: repo, repo_root: test_repo_root())
      )

    payload = get_in(response, ["result", "structuredContent"])
    assert payload["status"] == "created"
    assert payload["work_request"]["creator"] == %{"kind" => "agent", "name" => "kraken-beta-arch", "via" => "mcp"}
    assert payload["work_request"]["status"] == "ready_for_clarification"
    assert is_binary(payload["launch_prompt"])
    assert payload["launch_prompt"] =~ "claim_private_handoff"

    private_handoff = get_in(payload, ["architect_handoff", "secret_handoff"])
    assert private_handoff["mode"] == "local-private-file"
    assert private_handoff["secret_in_stdout"] == false
    refute Map.has_key?(private_handoff, "secret")
    refute Map.has_key?(private_handoff, "secret_hash")
    refute Map.has_key?(private_handoff, "run_mcp_command")
    assert handoff_secret_absent?(private_handoff, inspect(response))

    {claim_response, _claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-created-work-request",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_private_handoff",
            "arguments" => %{"claimed_by" => "kraken-beta-arch", "private_handoff" => private_handoff}
          }
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert handoff_secret_absent?(private_handoff, inspect(claim_response))

    default_owner_response =
      mcp_tool(
        repo,
        nil,
        "create_work_request",
        %{
          "repo" => "nextide/symphony-plus-plus",
          "base_branch" => "main",
          "title" => "Default-owner WorkRequest",
          "description" => "Create a WorkRequest without supplying a claim owner.",
          "request_kind" => "feature"
        },
        config: Config.default(repo: repo, repo_root: test_repo_root())
      )

    default_owner_payload = get_in(default_owner_response, ["result", "structuredContent"])
    assert default_owner_payload["work_request"]["creator"] == %{"kind" => "agent", "name" => "mcp-agent", "via" => "mcp"}
    assert default_owner_payload["claim"] == %{"tool" => "claim_private_handoff", "claimed_by" => "symphony-architect"}

    default_owner_handoff = get_in(default_owner_payload, ["architect_handoff", "secret_handoff"])

    {default_claim_response, _default_claimed_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "claim-default-owner-work-request",
          "method" => "tools/call",
          "params" => %{
            "name" => "claim_private_handoff",
            "arguments" => %{
              "claimed_by" => default_owner_payload["claim"]["claimed_by"],
              "private_handoff" => default_owner_handoff
            }
          }
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(default_claim_response, ["result", "structuredContent", "assignment", "grant_role"]) == "architect"
    assert handoff_secret_absent?(default_owner_handoff, inspect(default_owner_response))
    assert handoff_secret_absent?(default_owner_handoff, inspect(default_claim_response))

    {local_create_response, _local_create_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-create-work-request",
          "method" => "tools/call",
          "params" => %{
            "name" => "create_work_request",
            "arguments" => %{
              "repo" => "nextide/symphony-plus-plus",
              "base_branch" => "main",
              "title" => "Local architect claim WorkRequest",
              "description" => "Create a WorkRequest from a trusted local MCP session.",
              "request_kind" => "feature",
              "claimed_by" => "local-create-arch"
            }
          }
        },
        local_mcp_server(local_mcp_config(repo), "local-create-work-request-state")
      )

    local_create_payload = get_in(local_create_response, ["result", "structuredContent"])
    assert local_create_payload["claim"]["tool"] == "claim_local_architect_assignment"
    assert local_create_payload["claim"]["claimed_by"] == "local-create-arch"
    assert local_create_payload["claim"]["required_runtime_arguments"] == ["caller_id"]
    assert local_create_payload["claim"]["arguments"]["claimed_by"] == "local-create-arch"
    assert local_create_payload["architect_handoff"]["local_architect_claim"]["tool"] == "claim_local_architect_assignment"
    assert local_create_payload["architect_handoff"]["local_architect_claim"]["arguments"]["claimed_by"] == "local-create-arch"
    assert local_create_payload["launch_prompt"] =~ "claim_local_architect_assignment"

    operator_response =
      mcp_tool(
        repo,
        nil,
        "create_work_request",
        %{
          "repo" => "nextide/symphony-plus-plus",
          "base_branch" => "main",
          "title" => "Operator-created WorkRequest",
          "human_description" => "Record supplied operator provenance.",
          "request_kind" => "investigation",
          "creator_kind" => "operator",
          "creator_name" => "JJ",
          "created_via" => "cli",
          "claimed_by" => "operator-arch"
        },
        config: Config.default(repo: repo, repo_root: test_repo_root())
      )

    assert get_in(operator_response, ["result", "structuredContent", "work_request", "creator"]) == %{
             "kind" => "operator",
             "name" => "JJ",
             "via" => "cli"
           }

    partial_response =
      mcp_tool(
        repo,
        nil,
        "create_work_request",
        %{
          "repo" => "nextide/symphony-plus-plus",
          "base_branch" => "main",
          "title" => "Partial handoff WorkRequest",
          "description" => "Create succeeds even when handoff bootstrap is not configured.",
          "request_kind" => "feature",
          "claimed_by" => "partial-arch"
        },
        config: Config.default(repo: repo)
      )

    partial_payload = get_in(partial_response, ["result", "structuredContent"])
    assert partial_payload["status"] == "partial_success"
    assert partial_payload["architect_handoff"] == nil

    assert partial_payload["retry"] == %{
             "type" => "manual_architect_handoff_replay",
             "work_request_id" => get_in(partial_payload, ["work_request", "id"]),
             "operator_action" => "prepare_architect_handoff"
           }

    assert {:ok, %WorkRequest{}} = WorkRequestRepository.get(repo, get_in(partial_payload, ["work_request", "id"]))
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
    refute Map.has_key?(fresh_tools_by_name, "read_work_request")
    assert Map.has_key?(fresh_tools_by_name, "solo_attach")
    refute Map.has_key?(fresh_tools_by_name, "get_current_assignment")
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
    assert Enum.map(read_payload["planned_slices"], & &1["id"]) == ["WRS-MCP-WR-PLANNED", "WRS-MCP-WR-APPROVED"]
    assert Enum.at(read_payload["planned_slices"], 0)["review_lanes"] == ["brief", "[REDACTED]", "normal"]

    assert read_payload["summary"] == %{
             "open_question_count" => 1,
             "answered_question_count" => 1,
             "closed_question_count" => 1,
             "decision_count" => 1,
             "planned_slice_count" => 1,
             "approved_slice_count" => 1,
             "dispatched_slice_count" => 0,
             "skipped_slice_count" => 0
           }

    include_scratch_response =
      mcp_tool(repo, session, "read_work_request", %{
        "work_request_id" => in_scope.id,
        "include_planning_scratch" => true
      })

    include_scratch_payload = get_in(include_scratch_response, ["result", "structuredContent"])

    assert Enum.map(include_scratch_payload["planned_slices"], & &1["id"]) == [
             "WRS-MCP-WR-PLANNED",
             "WRS-MCP-WR-APPROVED",
             "WRS-MCP-WR-SKIPPED"
           ]

    included_slices_by_id = Map.new(include_scratch_payload["planned_slices"], &{&1["id"], &1})
    assert get_in(included_slices_by_id, ["WRS-MCP-WR-SKIPPED", "planning_classification"]) == "planning_scratch"
    assert include_scratch_payload["summary"]["skipped_slice_count"] == 1

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
    {insufficient_anchor, insufficient_session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-AUTHZ", ["read:phase"])

    insufficient_target =
      create_work_request!(repo,
        id: "WR-MCP-WR-AUTHZ",
        repo: insufficient_anchor.repo,
        base_branch: insufficient_anchor.base_branch
      )

    list_denied = mcp_tool(repo, insufficient_session, "list_work_requests", %{})
    assert get_in(list_denied, ["error", "code"]) == -32_003
    assert get_in(list_denied, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(list_denied, ["error", "data", "reason_code"]) == "insufficient_capability"

    read_denied = mcp_tool(repo, insufficient_session, "read_work_request", %{"work_request_id" => insufficient_target.id})
    assert get_in(read_denied, ["error", "code"]) == -32_003
    assert get_in(read_denied, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(read_denied, ["error", "data", "reason_code"]) == "insufficient_capability"

    missing_read_denied = mcp_tool(repo, insufficient_session, "read_work_request", %{"work_request_id" => "WR-MCP-WR-AUTHZ-MISSING"})
    assert get_in(missing_read_denied, ["error", "code"]) == -32_003
    assert get_in(missing_read_denied, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(missing_read_denied, ["error", "data", "reason_code"]) == "insufficient_capability"

    board_denied =
      mcp_tool(repo, insufficient_session, "read_work_request_delivery_board", %{"work_request_id" => insufficient_target.id})

    assert get_in(board_denied, ["error", "code"]) == -32_003
    assert get_in(board_denied, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(board_denied, ["error", "data", "reason_code"]) == "insufficient_capability"

    missing_board_denied =
      mcp_tool(repo, insufficient_session, "read_work_request_delivery_board", %{"work_request_id" => "WR-MCP-WR-AUTHZ-MISSING"})

    assert get_in(missing_board_denied, ["error", "code"]) == -32_003
    assert get_in(missing_board_denied, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(missing_board_denied, ["error", "data", "reason_code"]) == "insufficient_capability"

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

  test "WorkRequest MCP list narrows to explicit WorkRequest read scopes", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-LIST-SCOPED", [
        "read:work_request"
      ])

    visible =
      create_work_request!(repo,
        id: "WR-MCP-WR-LIST-SCOPED",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    hidden =
      create_work_request!(repo,
        id: "WR-MCP-WR-LIST-HIDDEN",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, visible.id)
    remove_grant_scope_type!(repo, session, "repo")

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    list_payload = get_in(list_response, ["result", "structuredContent"])

    assert Enum.map(list_payload["work_requests"], & &1["id"]) == [visible.id]
    refute inspect(list_response) =~ hidden.id

    hidden_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => hidden.id})
    assert get_in(hidden_read_response, ["error", "code"]) == -32_004
    assert get_in(hidden_read_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(hidden_read_response) =~ hidden.id

    hidden_board_response = mcp_tool(repo, session, "read_work_request_delivery_board", %{"work_request_id" => hidden.id})
    assert get_in(hidden_board_response, ["error", "code"]) == -32_004
    assert get_in(hidden_board_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(hidden_board_response) =~ hidden.id
  end

  test "WorkRequest architect grants require phase scope before MCP use", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-WR-LEGACY", kind: "mcp"))

    assert {:error, %Ecto.Changeset{} = changeset} = create_architect_work_key(repo, package.id, ["read:work_request"])
    assert {"architect phase-scoped grants require phase scope", []} in Keyword.get_values(changeset.errors, :phase_id)
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

    missing_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => "WR-MCP-WR-DRIFTED-MISSING"})
    assert get_in(missing_read_response, ["error", "code"]) == -32_003
    assert get_in(missing_read_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "WorkRequest MCP tools for handoff phases are pinned to the handoff WorkRequest", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-SIBLING",
        repo: handoff_work_request.repo,
        base_branch: handoff_work_request.base_branch,
        status: "ready_for_slicing"
      )

    {anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request",
        "write:work_request"
      ])

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    list_payload = get_in(list_response, ["result", "structuredContent"])

    assert list_payload["scope"] == %{
             "repo" => anchor.repo,
             "base_branch" => anchor.base_branch,
             "phase_id" => anchor.phase_id
           }

    assert Enum.map(list_payload["work_requests"], & &1["id"]) == [handoff_work_request.id]

    sibling_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => sibling.id})
    assert get_in(sibling_read_response, ["error", "code"]) == -32_004
    assert get_in(sibling_read_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(sibling_read_response) =~ sibling.id

    sibling_status_response =
      mcp_tool(repo, session, "set_work_request_status", %{
        "work_request_id" => sibling.id,
        "current_status" => "ready_for_slicing",
        "next_status" => "sliced"
      })

    assert get_in(sibling_status_response, ["error", "code"]) == -32_004
    assert get_in(sibling_status_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(sibling_status_response) =~ sibling.id

    assert {:ok, persisted_sibling} = WorkRequestRepository.get(repo, sibling.id)
    assert persisted_sibling.status == "ready_for_slicing"

    target_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => handoff_work_request.id})
    assert get_in(target_read_response, ["result", "structuredContent", "work_request", "id"]) == handoff_work_request.id
  end

  test "WorkRequest MCP scope is not pinned for normal non-handoff phases", %{repo: repo} do
    first =
      create_work_request!(repo,
        id: "WR-MCP-WR-PREFIX-FIRST",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    second =
      create_work_request!(repo,
        id: "WR-MCP-WR-PREFIX-SECOND",
        repo: first.repo,
        base_branch: first.base_branch,
        status: "ready_for_slicing"
      )

    phase_id = "phase-manual-work-request-scope"
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Manual WorkRequest phase"})

    {_anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-PREFIX-NON-HANDOFF", ["read:work_request"],
        phase_id: phase_id,
        repo: first.repo,
        base_branch: first.base_branch
      )

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    list_payload = get_in(list_response, ["result", "structuredContent"])

    assert list_payload["scope"] == %{"repo" => first.repo, "base_branch" => first.base_branch}
    assert Enum.map(list_payload["work_requests"], & &1["id"]) == [first.id, second.id]
  end

  test "WorkRequest MCP tools fail closed for partial handoff provenance", %{repo: repo} do
    first =
      create_work_request!(repo,
        id: "WR-MCP-WR-PARTIAL-HANDOFF-FIRST",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-PARTIAL-HANDOFF-SIBLING",
        repo: first.repo,
        base_branch: first.base_branch,
        status: "ready_for_slicing"
      )

    phase_id = "phase-wr-architect-partial-provenance"
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Partial handoff phase"})

    {_anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-PARTIAL-HANDOFF", ["read:work_request"],
        phase_id: phase_id,
        repo: first.repo,
        base_branch: first.base_branch
      )

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    assert get_in(list_response, ["error", "code"]) == -32_003
    assert get_in(list_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(list_response) =~ sibling.id
  end

  test "WorkRequest MCP tools fail closed when handoff provenance no longer matches a WorkRequest", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-DRIFTED",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-DRIFTED-SIBLING",
        repo: handoff_work_request.repo,
        base_branch: handoff_work_request.base_branch,
        status: "ready_for_slicing"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request"
      ])

    assert {:ok, _drifted} =
             WorkRequestRepository.update(repo, handoff_work_request.id, %{"repo" => "nextide/drifted"})

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    assert get_in(list_response, ["error", "code"]) == -32_003
    assert get_in(list_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(list_response) =~ sibling.id
  end

  test "WorkRequest MCP tools fail closed when handoff WorkRequest leaves eligible status", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-INELIGIBLE",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request"
      ])

    assert {:ok, _draft} = WorkRequestRepository.update_status(repo, handoff_work_request.id, "ready_for_slicing", "draft")

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => handoff_work_request.id})
    assert get_in(read_response, ["error", "code"]) == -32_003
    assert get_in(read_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "WorkRequest MCP tools fail closed when handoff WorkRequest file scope changes", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-FILE-SCOPE",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request"
      ])

    assert {:ok, _narrowed} =
             WorkRequestRepository.update(repo, handoff_work_request.id, %{
               "constraints" => %{"allowed_paths" => ["docs"], "requires_secret" => false}
             })

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => handoff_work_request.id})
    assert get_in(read_response, ["error", "code"]) == -32_003
    assert get_in(read_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "architect WorkRequest mutation tools update scoped clarification state and redact responses", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_clarification"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    status_response =
      mcp_tool(repo, session, "set_work_request_status", %{
        "work_request_id" => work_request.id,
        "current_status" => "ready_for_clarification",
        "next_status" => "clarifying"
      })

    status_payload = get_in(status_response, ["result", "structuredContent"])
    assert status_payload["work_request"]["status"] == "clarifying"
    assert MapSet.new(Map.keys(status_payload["work_request"])) == MapSet.new(["id", "status", "updated_at"])
    assert status_payload["status"] == %{"previous_status" => "ready_for_clarification", "current_status" => "clarifying"}
    assert status_payload["scope"] == %{"repo" => anchor.repo, "base_branch" => anchor.base_branch}

    assert {:ok, persisted_work_request} = WorkRequestRepository.get(repo, work_request.id)
    assert persisted_work_request.status == "clarifying"

    ask_response =
      mcp_tool(repo, session, "ask_work_request_question", %{
        "work_request_id" => work_request.id,
        "category" => "scope",
        "question" => "Can the implementation use Bearer raw_secret_value?",
        "why_needed" => "The architect needs to avoid raw_secret_value leakage.",
        "decision_prompt" => %{
          "tl_dr" => "Choose whether to continue.",
          "details" => "The architect needs a human-readable option picker.",
          "options" => [
            %{
              "id" => "continue",
              "label" => "Continue",
              "description" => "Proceed with the safe path.",
              "pros" => ["Fastest path"],
              "cons" => ["Leaves polish for later"],
              "answer" => "Continue without raw_secret_value."
            }
          ],
          "custom_redirect_label" => "No, and tell the agent what to do differently"
        },
        "asked_by_agent_run_id" => "raw_secret_value"
      })

    ask_payload = get_in(ask_response, ["result", "structuredContent"])
    question_id = get_in(ask_payload, ["clarification_question", "id"])
    assert is_binary(question_id)
    assert get_in(ask_payload, ["clarification_question", "status"]) == "open"
    assert get_in(ask_payload, ["clarification_question", "asked_by_agent_run_id"]) == "[REDACTED]"
    assert get_in(ask_payload, ["clarification_question", "decision_prompt", "tl_dr"]) == "Choose whether to continue."
    assert get_in(ask_payload, ["clarification_question", "decision_prompt", "options", Access.at(0), "answer"]) == "Continue without [REDACTED]."
    assert MapSet.new(Map.keys(ask_payload["work_request"])) == MapSet.new(["id", "status", "updated_at"])
    refute inspect(ask_response) =~ "raw_secret_value"

    wrong_status_response =
      mcp_tool(repo, session, "answer_work_request_question", %{
        "work_request_id" => work_request.id,
        "question_id" => question_id,
        "expected_question_status" => "ready_for_slicing",
        "answer" => "Wrong status domain."
      })

    assert get_in(wrong_status_response, ["error", "data", "reason"]) == "invalid_question_status"
    assert get_in(wrong_status_response, ["error", "data", "status_domain"]) == "clarification_question"
    assert get_in(wrong_status_response, ["error", "data", "expected_statuses"]) == ["open"]
    assert get_in(wrong_status_response, ["error", "data", "got"]) == "ready_for_slicing"

    malformed_status_response =
      mcp_tool(repo, session, "answer_work_request_question", %{
        "work_request_id" => work_request.id,
        "question_id" => question_id,
        "expected_question_status" => 123,
        "answer" => "Malformed status guard."
      })

    assert get_in(malformed_status_response, ["error", "data", "reason"]) == "invalid_question_status"
    assert get_in(malformed_status_response, ["error", "data", "got"]) == "non_string"

    answer_response =
      mcp_tool(repo, session, "answer_work_request_question", %{
        "work_request_id" => work_request.id,
        "question_id" => question_id,
        "answer" => "Use signed URL https://example.test/path?sig=raw_secret_value instead."
      })

    answer_payload = get_in(answer_response, ["result", "structuredContent"])
    assert get_in(answer_payload, ["clarification_question", "status"]) == "answered"
    assert get_in(answer_payload, ["clarification_question", "answered_by"]) == "architect-1"
    refute inspect(answer_response) =~ "raw_secret_value"

    close_ask_response =
      mcp_tool(repo, session, "ask_work_request_question", %{
        "work_request_id" => work_request.id,
        "category" => "acceptance",
        "question" => "Can the stale branch be ignored?",
        "why_needed" => "The architect needs an explicit closure reason."
      })

    close_question_id = get_in(close_ask_response, ["result", "structuredContent", "clarification_question", "id"])

    close_response =
      mcp_tool(repo, session, "close_work_request_question", %{
        "work_request_id" => work_request.id,
        "question_id" => close_question_id,
        "current_status" => "open"
      })

    assert get_in(close_response, ["result", "structuredContent", "clarification_question", "status"]) == "closed"

    combined_ask_response =
      mcp_tool(repo, session, "ask_work_request_question", %{
        "work_request_id" => work_request.id,
        "category" => "product",
        "question" => "Should we keep this backend-only?",
        "why_needed" => "The answer should become decision-log truth."
      })

    combined_question_id = get_in(combined_ask_response, ["result", "structuredContent", "clarification_question", "id"])

    combined_response =
      mcp_tool(repo, session, "answer_work_request_question_and_record_decision", %{
        "work_request_id" => work_request.id,
        "question_id" => combined_question_id,
        "answer" => "Keep it backend-only.",
        "source_type" => "architect",
        "decision" => "Keep the WorkRequest backend-only.",
        "rationale" => "The UI is out of scope.",
        "scope_impact" => "No dashboard changes."
      })

    combined_payload = get_in(combined_response, ["result", "structuredContent"])
    assert get_in(combined_payload, ["clarification_question", "status"]) == "answered"
    assert get_in(combined_payload, ["decision_log_entry", "source_id"]) == combined_question_id
    assert get_in(combined_payload, ["decision_log_entry", "created_by"]) == "architect-1"

    decision_response =
      mcp_tool(repo, session, "record_work_request_decision", %{
        "work_request_id" => work_request.id,
        "source_type" => "architect",
        "source_id" => "comment-1",
        "decision" => "Keep this WorkRequest backend-only with token raw_secret_value excluded.",
        "rationale" => "Dashboard work is out of scope.",
        "scope_impact" => "No dashboard changes.",
        "created_by" => "architect-1"
      })

    decision_payload = get_in(decision_response, ["result", "structuredContent"])
    assert get_in(decision_payload, ["decision_log_entry", "source_id"]) == "comment-1"
    assert decision_payload["status"] == %{"work_request_status" => "clarifying"}
    refute inspect(decision_response) =~ "raw_secret_value"

    assert {:ok, questions} = WorkRequestRepository.list_questions(repo, work_request.id)
    assert Enum.map(questions, & &1.status) == ["answered", "closed", "answered"]
    assert {:ok, decisions} = WorkRequestRepository.list_decisions(repo, work_request.id)
    assert Enum.map(decisions, & &1.source_id) == [combined_question_id, "comment-1"]
  end

  test "ask_work_request_question rejects malformed decision prompts without echoing nested input", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-BAD-PROMPT", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-BAD-DECISION-PROMPT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "clarifying"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    response =
      mcp_tool(repo, session, "ask_work_request_question", %{
        "work_request_id" => work_request.id,
        "category" => "scope",
        "question" => "Can the implementation continue?",
        "why_needed" => "The architect needs a human answer.",
        "decision_prompt" => %{
          "tl_dr" => "Do not leak raw_secret_value.",
          "details" => "This malformed prompt is missing options."
        }
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "decision_prompt must contain 1 to 4 options"
    refute inspect(response) =~ "raw_secret_value"
  end

  test "WorkRequest MCP question mutations leave parent status explicit", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-STATUS-EXPLICIT", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-STATUS-EXPLICIT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_clarification"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    response =
      mcp_tool(repo, session, "ask_work_request_question", %{
        "work_request_id" => work_request.id,
        "category" => "scope",
        "question" => "Should this move status automatically?",
        "why_needed" => "MCP uses explicit status mutation."
      })

    payload = get_in(response, ["result", "structuredContent"])
    assert payload["work_request"]["status"] == "ready_for_clarification"

    assert payload["status"] == %{
             "work_request_status" => "ready_for_clarification",
             "question_status" => "open"
           }

    assert {:ok, persisted_work_request} = WorkRequestRepository.get(repo, work_request.id)
    assert persisted_work_request.status == "ready_for_clarification"
  end

  test "architect WorkRequest planned-slice mutation tools update scoped slices and mark sliced", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-MUTATE", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-MUTATE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing",
        human_description: "Do not return raw_secret_value."
      )

    grant_work_request_scope!(repo, session, work_request.id)

    counts_before = {
      repo.aggregate(WorkPackage, :count),
      repo.aggregate(AccessGrant, :count),
      repo.aggregate(ProgressEvent, :count),
      repo.aggregate(Artifact, :count)
    }

    add_args = %{
      "work_request_id" => work_request.id,
      "title" => "Planned raw_secret_value slice",
      "goal" => "Persist a planned slice without leaking raw_secret_value.",
      "work_package_kind" => "mcp",
      "target_base_branch" => anchor.base_branch,
      "owned_file_globs" => [" elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex "],
      "forbidden_file_globs" => [],
      "acceptance_criteria" => ["MCP planned-slice mutation succeeds."],
      "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp_test.exs"],
      "review_lanes" => ["brief", "raw_secret_review_lane", "normal"],
      "stop_conditions" => ["Stop before dispatch."]
    }

    out_of_scope_response =
      mcp_tool(
        repo,
        session,
        "add_work_request_planned_slice",
        Map.put(add_args, "target_base_branch", "feature/out-of-scope")
      )

    assert get_in(out_of_scope_response, ["error", "code"]) == -32_602
    assert get_in(out_of_scope_response, ["error", "data", "reason"]) == "target_base_branch_scope_mismatch"
    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    changeset_error_response =
      mcp_tool(
        repo,
        session,
        "add_work_request_planned_slice",
        Map.merge(add_args, %{
          "title" => "Invalid raw_secret_value slice",
          "goal" => "Do not echo raw_secret_value in changeset errors.",
          "work_package_kind" => "side_quest",
          "review_lanes" => ["raw_secret_value"]
        })
      )

    assert get_in(changeset_error_response, ["error", "code"]) == -32_602
    assert get_in(changeset_error_response, ["error", "data", "reason"]) == "invalid_planned_slice"
    refute inspect(changeset_error_response) =~ "raw_secret_value"
    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    invalid_docs_scope_response =
      mcp_tool(
        repo,
        session,
        "add_work_request_planned_slice",
        Map.merge(add_args, %{
          "title" => "Invalid docs scope",
          "goal" => "Docs kind cannot own code paths.",
          "work_package_kind" => "docs",
          "owned_file_globs" => ["elixir/lib/**"]
        })
      )

    assert get_in(invalid_docs_scope_response, ["error", "code"]) == -32_602
    assert get_in(invalid_docs_scope_response, ["error", "data", "reason"]) == "planned_slice_scope_violation"

    assert [
             %{
               "field" => "owned_file_globs",
               "value" => "elixir/lib/**",
               "reason" => "non_documentation_owned_glob"
             }
           ] = get_in(invalid_docs_scope_response, ["error", "data", "validation_errors"])

    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    invalid_branch_response =
      mcp_tool(
        repo,
        session,
        "add_work_request_planned_slice",
        Map.put(add_args, "branch_pattern", "feat/live-triggers-v1-native-audio-evidence-*")
      )

    assert get_in(invalid_branch_response, ["error", "data", "reason"]) == "unsupported_branch_pattern_wildcard"

    assert [
             %{
               "field" => "branch_pattern",
               "value" => "feat/live-triggers-v1-native-audio-evidence-*",
               "reason" => "unsupported_branch_pattern_wildcard"
             }
             | _
           ] = get_in(invalid_branch_response, ["error", "data", "validation_errors"])

    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    add_response = mcp_tool(repo, session, "add_work_request_planned_slice", add_args)
    add_payload = get_in(add_response, ["result", "structuredContent"])
    planned_slice_id = get_in(add_payload, ["planned_slice", "id"])

    assert is_binary(planned_slice_id)
    assert add_payload["scope"] == %{"repo" => anchor.repo, "base_branch" => anchor.base_branch}
    assert add_payload["work_request"]["status"] == "ready_for_slicing"
    assert get_in(add_payload, ["planned_slice", "status"]) == "planned"
    assert get_in(add_payload, ["planned_slice", "owned_file_globs"]) == ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"]
    assert get_in(add_payload, ["planned_slice", "forbidden_file_globs"]) == []
    assert get_in(add_payload, ["planned_slice", "branch_pattern"]) == nil
    assert get_in(add_payload, ["planned_slice", "review_lanes"]) == ["brief", "[REDACTED]", "normal"]
    assert add_payload["status"] == %{"work_request_status" => "ready_for_slicing", "planned_slice_status" => "planned"}
    refute inspect(add_response) =~ "raw_secret_value"

    skip_add_response =
      mcp_tool(
        repo,
        session,
        "add_work_request_planned_slice",
        Map.merge(add_args, %{
          "title" => "Skipped follow-up",
          "goal" => "Record a slice that can be skipped.",
          "branch_pattern" => "agent/SYMPP-V2-WR-015/skipped"
        })
      )

    skip_slice_id = get_in(skip_add_response, ["result", "structuredContent", "planned_slice", "id"])

    approve_response =
      mcp_tool(repo, session, "approve_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice_id,
        "current_status" => "planned"
      })

    approve_payload = get_in(approve_response, ["result", "structuredContent"])
    assert get_in(approve_payload, ["planned_slice", "status"]) == "approved"

    assert approve_payload["status"] == %{
             "work_request_status" => "ready_for_slicing",
             "previous_planned_slice_status" => "planned",
             "planned_slice_status" => "approved"
           }

    skip_response =
      mcp_tool(repo, session, "skip_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => skip_slice_id,
        "current_status" => "planned"
      })

    skip_payload = get_in(skip_response, ["result", "structuredContent"])
    assert get_in(skip_payload, ["planned_slice", "status"]) == "skipped"
    assert get_in(skip_payload, ["planned_slice", "branch_pattern"]) == "agent/SYMPP-V2-WR-015/skipped"

    mark_response =
      mcp_tool(repo, session, "mark_work_request_sliced", %{
        "work_request_id" => work_request.id,
        "current_status" => "ready_for_slicing"
      })

    mark_payload = get_in(mark_response, ["result", "structuredContent"])
    assert mark_payload["work_request"]["status"] == "sliced"
    assert mark_payload["status"] == %{"previous_status" => "ready_for_slicing", "current_status" => "sliced"}

    assert {:ok, planned_slices} = WorkRequestRepository.list_planned_slices(repo, work_request.id)
    assert Enum.map(planned_slices, & &1.status) == ["approved", "skipped"]
    assert {:ok, persisted_work_request} = WorkRequestRepository.get(repo, work_request.id)
    assert persisted_work_request.status == "sliced"

    assert {
             repo.aggregate(WorkPackage, :count),
             repo.aggregate(AccessGrant, :count),
             repo.aggregate(ProgressEvent, :count),
             repo.aggregate(Artifact, :count)
           } == counts_before
  end

  test "WorkRequest MCP planned-slice validation rejects unsupported globstar at add and approve", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-GLOBSTAR", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-GLOBSTAR",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing",
        constraints: %{"allowed_paths" => ["scripts", "elixir/lib"], "requires_secret" => false}
      )

    grant_work_request_scope!(repo, session, work_request.id)

    add_args = %{
      "work_request_id" => work_request.id,
      "title" => "Invalid globstar slice",
      "goal" => "Reject invalid globstar placement before dispatch.",
      "work_package_kind" => "mcp",
      "target_base_branch" => anchor.base_branch,
      "owned_file_globs" => ["scripts/**deploy**"],
      "forbidden_file_globs" => [],
      "acceptance_criteria" => ["Invalid globstar placement is rejected early."],
      "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp_test.exs"],
      "review_lanes" => ["normal"],
      "stop_conditions" => ["Stop before dispatch."]
    }

    add_response = mcp_tool(repo, session, "add_work_request_planned_slice", add_args)

    assert get_in(add_response, ["error", "code"]) == -32_602
    assert get_in(add_response, ["error", "data", "reason"]) == "planned_slice_scope_violation"

    assert get_in(add_response, ["error", "data", "validation_errors"]) == [
             %{"field" => "owned_file_globs", "value" => "scripts/**deploy**", "reason" => "unsupported_globstar"}
           ]

    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, Map.delete(add_args, "work_request_id"))

    approve_response =
      mcp_tool(repo, session, "approve_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "current_status" => "planned"
      })

    assert get_in(approve_response, ["error", "code"]) == -32_602
    assert get_in(approve_response, ["error", "data", "reason"]) == "planned_slice_scope_violation"

    assert get_in(approve_response, ["error", "data", "validation_errors"]) == [
             %{"field" => "owned_file_globs", "value" => "scripts/**deploy**", "reason" => "unsupported_globstar"}
           ]

    assert {:ok, persisted_slice} = WorkRequestRepository.get_planned_slice(repo, work_request.id, planned_slice.id)
    assert persisted_slice.status == "planned"
  end

  test "architect WorkRequest planned-slice dispatch tool creates safe worker handoff", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-DISPATCH", [
        "dispatch:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-DISPATCH",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing",
        human_description: "Do not return raw_secret_value."
      )

    grant_work_request_scope!(repo, session, work_request.id)

    secret_title_token = "raw_secret_bootstrap_title"

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-SLICE-DISPATCH",
                 title: "Dispatch #{secret_title_token}",
                 target_base_branch: anchor.base_branch,
                 goal: "Dispatch without leaking raw_secret_value.",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"]
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    live_database_path = current_main_database_path(repo)
    configured_database = sqlite_file_uri(live_database_path, "mode=rwc&cache=shared")
    configured_product_repo_root = Path.join(test_handoff_store_dir(), "configured-product-repo-root")
    File.mkdir_p!(configured_product_repo_root)

    response =
      mcp_tool(
        repo,
        session,
        "dispatch_work_request_planned_slice",
        %{
          "work_request_id" => work_request.id,
          "planned_slice_id" => approved_slice.id,
          "claimed_by" => "worker-dispatch-1",
          "symphony_repo_root" => test_repo_root()
        },
        config: Config.default(repo: repo, repo_root: configured_product_repo_root, database: configured_database)
      )

    payload = get_in(response, ["result", "structuredContent"])
    serialized_response = inspect(response)
    assert payload["scope"] == %{"repo" => anchor.repo, "base_branch" => anchor.base_branch}
    assert payload["work_request"] == %{"id" => work_request.id}
    assert payload["planned_slice"]["id"] == approved_slice.id
    assert payload["planned_slice"]["status"] == "dispatched"
    assert payload["planned_slice"]["work_package_id"] == payload["work_package"]["id"]
    assert is_binary(payload["planned_slice"]["dispatched_at"])
    assert payload["work_package"]["kind"] == "mcp"
    assert payload["work_package"]["repo"] == anchor.repo
    assert payload["work_package"]["base_branch"] == anchor.base_branch
    assert payload["work_package"]["title"] == "Dispatch [REDACTED]"
    assert is_binary(payload["work_package"]["inserted_at"])
    assert is_binary(payload["work_package"]["updated_at"])
    assert payload["worker_handoff"]["worker_grant"]["secret_in_response"] == false
    refute Map.has_key?(payload["worker_handoff"]["worker_grant"], "display_key")
    refute Map.has_key?(payload["worker_handoff"]["worker_grant"], "secret_handoff")
    refute Map.has_key?(payload["worker_handoff"]["worker_grant"], "secret")
    refute Map.has_key?(payload["worker_handoff"]["worker_grant"], "secret_hash")
    assert payload["worker_handoff"]["secret_handoff"] == nil
    refute Map.has_key?(payload["worker_handoff"], "claim_bootstrap")
    assert payload["worker_bootstrap"]["type"] == "ledger_claim"
    assert_same_ledger_database(payload["worker_bootstrap"]["ledger"], live_database_path, "mode=rwc&cache=shared")
    assert payload["worker_bootstrap"]["claim"]["tool"] == "claim_local_assignment"
    assert payload["worker_bootstrap"]["claim"]["arguments"]["repo"] == anchor.repo
    assert payload["worker_bootstrap"]["claim"]["arguments"]["base_branch"] == anchor.base_branch
    assert payload["worker_bootstrap"]["claim"]["arguments"]["work_request_id"] == work_request.id
    assert payload["worker_bootstrap"]["claim"]["arguments"]["work_package_id"] == payload["work_package"]["id"]
    assert payload["worker_bootstrap"]["claim"]["arguments"]["claimed_by"] == "worker-dispatch-1"
    refute Map.has_key?(payload["worker_bootstrap"]["claim"]["arguments"], "branch")
    assert payload["worker_bootstrap"]["claim"]["required_runtime_arguments"] == ["branch", "worktree_path", "caller_id"]

    assert payload["worker_bootstrap"]["required_skills"] == [
             "symphony-plus-plus:symphony-worker",
             "symphony-plus-plus-mcp:symphony-work-package"
           ]

    assert payload["worker_bootstrap"]["supported_skill_sets"] == [
             ["symphony-plus-plus:symphony-worker", "symphony-plus-plus-mcp:symphony-work-package"],
             ["symphony-plus-plus:symphony-worker", "symphony-work-package"]
           ]

    assert payload["worker_bootstrap"]["launch_prompt"] =~ "symphony-plus-plus:symphony-worker"
    assert payload["worker_bootstrap"]["launch_prompt"] =~ "symphony-plus-plus-mcp:symphony-work-package"
    assert payload["worker_bootstrap"]["launch_prompt"] =~ "symphony-work-package"
    assert payload["worker_bootstrap"]["launch_prompt"] =~ "claim_local_assignment"
    assert payload["worker_bootstrap"]["launch_prompt"] =~ "[REDACTED]"
    assert payload["worker_bootstrap"]["legacy_private_handoff"] == %{"normal_path" => false, "recovery_only" => true}
    refute payload["worker_bootstrap"]["launch_prompt"] =~ secret_title_token
    refute serialized_response =~ "raw_secret_value"
    refute serialized_response =~ "secret_hash"
    refute serialized_response =~ secret_title_token
    refute serialized_response =~ "run_mcp_command"
    refute serialized_response =~ "local-private-file"
    refute serialized_response =~ test_dispatch_handoff_store_dir()
    refute serialized_response =~ ".secret"

    assert {:ok, persisted_slice} = WorkRequestRepository.get_planned_slice(repo, work_request.id, approved_slice.id)
    assert persisted_slice.status == "dispatched"
    assert persisted_slice.work_package_id == payload["work_package"]["id"]

    assert {:ok, worker_grants} = AccessGrantRepository.list_for_work_package(repo, payload["work_package"]["id"])
    assert [%AccessGrant{grant_role: "worker", secret_hash: secret_hash}] = worker_grants
    refute serialized_response =~ secret_hash
  end

  test "architect WorkRequest planned-slice dispatch rejects ignored legacy handoff args", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-DISPATCH-IGNORED-LEGACY", [
        "dispatch:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-DISPATCH-IGNORED-LEGACY",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-SLICE-DISPATCH-IGNORED-LEGACY",
                 target_base_branch: anchor.base_branch
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    counts_before = {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)}

    response =
      mcp_tool(repo, session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => approved_slice.id,
        "claimed_by" => "worker-dispatch-ignored-legacy",
        "secret_handoff" => test_secret_handoff_mode(),
        "secret_store_dir" => test_dispatch_handoff_store_dir()
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "legacy_private_handoff_required"
    assert {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)} == counts_before
  end

  test "architect WorkRequest planned-slice dispatch keeps legacy recovery handoff actionable", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-DISPATCH-LEGACY", [
        "dispatch:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-DISPATCH-LEGACY",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-SLICE-DISPATCH-LEGACY",
                 target_base_branch: anchor.base_branch
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    live_database_path = current_main_database_path(repo)
    configured_database = sqlite_file_uri(live_database_path, "mode=rwc&cache=shared")

    response =
      mcp_tool(
        repo,
        session,
        "dispatch_work_request_planned_slice",
        %{
          "work_request_id" => work_request.id,
          "planned_slice_id" => approved_slice.id,
          "claimed_by" => "worker-dispatch-legacy",
          "legacy_private_handoff" => true,
          "secret_handoff" => "local-private-file",
          "secret_store_dir" => test_dispatch_handoff_store_dir()
        },
        config: Config.default(repo: repo, repo_root: test_repo_root(), database: configured_database)
      )

    payload = get_in(response, ["result", "structuredContent"])
    handoff = payload["worker_handoff"]["secret_handoff"]

    assert payload["planned_slice"]["status"] == "dispatched"
    assert payload["worker_bootstrap"]["claim"]["required_runtime_arguments"] == ["branch", "worktree_path", "caller_id"]
    assert handoff["claimed_by"] == "worker-dispatch-legacy"
    assert handoff["mode"] == "local-private-file"
    assert handoff["secret_in_stdout"] == false
    assert is_binary(handoff["path"])
    assert is_binary(handoff["run_mcp_command"])
    assert handoff["run_mcp_command"] =~ handoff["path"]
    refute Map.has_key?(handoff, "display_key")
    refute Map.has_key?(handoff, "payload")
    refute Map.has_key?(handoff, "secret")
    assert handoff_secret_absent?(handoff, inspect(response))
  end

  test "architect WorkRequest planned-slice dispatch rejects sqlite memory database handoff", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-DISPATCH-MEMORY", [
        "dispatch:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-DISPATCH-MEMORY",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-SLICE-DISPATCH-MEMORY",
                 target_base_branch: anchor.base_branch
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    counts_before = {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)}

    response =
      mcp_tool(
        repo,
        session,
        "dispatch_work_request_planned_slice",
        %{
          "work_request_id" => work_request.id,
          "planned_slice_id" => approved_slice.id,
          "claimed_by" => "worker-dispatch-memory",
          "legacy_private_handoff" => true,
          "secret_handoff" => test_secret_handoff_mode(),
          "secret_store_dir" => test_dispatch_handoff_store_dir()
        },
        config: Config.default(repo: repo, repo_root: test_repo_root(), database: ":memory:")
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "file_backed_database_required"
    assert {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)} == counts_before
  end

  test "architect WorkRequest planned-slice dispatch rejects configured database outside the live ledger", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-DISPATCH-DB-SCOPE", [
        "dispatch:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-DISPATCH-DB-SCOPE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-SLICE-DISPATCH-DB-SCOPE",
                 target_base_branch: anchor.base_branch
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    counts_before = {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)}
    other_database = sqlite_file_uri(Path.join(System.tmp_dir!(), "sympp-mcp-other-ledger.sqlite3"), "mode=rwc&cache=shared")

    response =
      mcp_tool(
        repo,
        session,
        "dispatch_work_request_planned_slice",
        %{
          "work_request_id" => work_request.id,
          "planned_slice_id" => approved_slice.id,
          "claimed_by" => "worker-dispatch-db-scope",
          "legacy_private_handoff" => true,
          "secret_handoff" => test_secret_handoff_mode(),
          "secret_store_dir" => test_dispatch_handoff_store_dir()
        },
        config: Config.default(repo: repo, repo_root: test_repo_root(), database: other_database)
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "database_scope_mismatch"
    assert {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)} == counts_before

    read_only_database = sqlite_file_uri(current_main_database_path(repo), "mode=ro")

    read_only_response =
      mcp_tool(
        repo,
        session,
        "dispatch_work_request_planned_slice",
        %{
          "work_request_id" => work_request.id,
          "planned_slice_id" => approved_slice.id,
          "claimed_by" => "worker-dispatch-db-read-only",
          "legacy_private_handoff" => true,
          "secret_handoff" => test_secret_handoff_mode(),
          "secret_store_dir" => test_dispatch_handoff_store_dir()
        },
        config: Config.default(repo: repo, repo_root: test_repo_root(), database: read_only_database)
      )

    assert get_in(read_only_response, ["error", "code"]) == -32_602
    assert get_in(read_only_response, ["error", "data", "reason"]) == "read_only_database"
    assert {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)} == counts_before

    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    default_read_only_response =
      try do
        Application.put_env(:symphony_elixir, :sympp_repo_database, read_only_database)

        mcp_tool(repo, session, "dispatch_work_request_planned_slice", %{
          "work_request_id" => work_request.id,
          "planned_slice_id" => approved_slice.id,
          "claimed_by" => "worker-dispatch-db-default-read-only",
          "legacy_private_handoff" => true,
          "secret_handoff" => test_secret_handoff_mode(),
          "secret_store_dir" => test_dispatch_handoff_store_dir()
        })
      after
        restore_app_env(:sympp_repo_database, original_database)
      end

    assert get_in(default_read_only_response, ["error", "code"]) == -32_602
    assert get_in(default_read_only_response, ["error", "data", "reason"]) == "read_only_database"
    assert {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)} == counts_before
  end

  test "WorkRequest MCP planned-slice dispatch fails closed for scope and invalid slice cases", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-DISPATCH-GUARD", [
        "dispatch:work_request"
      ])

    in_scope =
      create_work_request!(repo,
        id: "WR-MCP-WR-DISPATCH-GUARD",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, in_scope.id)

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-DISPATCH-SIBLING",
        repo: "nextide/other",
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               in_scope.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-WR-DISPATCH-PLANNED", target_base_branch: anchor.base_branch)
             )

    assert {:ok, sibling_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               sibling.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-WR-DISPATCH-SIBLING", target_base_branch: anchor.base_branch)
             )

    out_of_scope_response =
      mcp_tool(repo, session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => sibling.id,
        "planned_slice_id" => sibling_slice.id,
        "claimed_by" => "worker-dispatch-1"
      })

    assert get_in(out_of_scope_response, ["error", "code"]) == -32_004
    assert get_in(out_of_scope_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(out_of_scope_response) =~ sibling.id
    refute inspect(out_of_scope_response) =~ sibling_slice.id

    missing_slice_response =
      mcp_tool(repo, session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => in_scope.id,
        "planned_slice_id" => "WRS-MCP-WR-DISPATCH-MISSING",
        "claimed_by" => "worker-dispatch-1"
      })

    assert get_in(missing_slice_response, ["error", "code"]) == -32_004
    assert get_in(missing_slice_response, ["error", "data", "reason"]) == "not_found"

    planned_response =
      mcp_tool(repo, session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => in_scope.id,
        "planned_slice_id" => planned_slice.id,
        "claimed_by" => "worker-dispatch-1"
      })

    assert get_in(planned_response, ["error", "code"]) == -32_602
    assert get_in(planned_response, ["error", "data", "reason"]) == "invalid_planned_slice_status"
    assert repo.aggregate(WorkPackage, :count) == 1
    assert repo.aggregate(AccessGrant, :count) == 1

    assert {:ok, root_check_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               in_scope.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-WR-DISPATCH-ROOT-CHECK", target_base_branch: anchor.base_branch)
             )

    assert {:ok, approved_root_check_slice} =
             WorkRequestRepository.approve_planned_slice(repo, in_scope.id, root_check_slice.id, "planned")

    bad_repo_root = Path.join(test_handoff_store_dir(), "not-a-symphony-helper-root")
    File.mkdir_p!(bad_repo_root)
    counts_before_bad_root = {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)}

    bad_root_response =
      mcp_tool(repo, session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => in_scope.id,
        "planned_slice_id" => approved_root_check_slice.id,
        "claimed_by" => "worker-dispatch-bad-root",
        "legacy_private_handoff" => true,
        "secret_handoff" => test_secret_handoff_mode(),
        "secret_store_dir" => test_dispatch_handoff_store_dir(),
        "symphony_repo_root" => bad_repo_root
      })

    assert get_in(bad_root_response, ["error", "code"]) == -32_602
    assert get_in(bad_root_response, ["error", "data", "reason"]) == "invalid_repo_root"
    assert get_in(bad_root_response, ["error", "data", "message"]) =~ "symphony_repo_root"
    assert get_in(bad_root_response, ["error", "data", "message"]) =~ "worker secret helper script"
    assert {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)} == counts_before_bad_root

    legacy_bad_root_response =
      mcp_tool(repo, session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => in_scope.id,
        "planned_slice_id" => approved_root_check_slice.id,
        "claimed_by" => "worker-dispatch-legacy-bad-root",
        "legacy_private_handoff" => true,
        "secret_handoff" => test_secret_handoff_mode(),
        "secret_store_dir" => test_dispatch_handoff_store_dir(),
        "repo_root" => bad_repo_root
      })

    assert get_in(legacy_bad_root_response, ["error", "code"]) == -32_602
    assert get_in(legacy_bad_root_response, ["error", "data", "reason"]) == "invalid_repo_root"
    refute get_in(legacy_bad_root_response, ["error", "data", "reason"]) == "unexpected_argument"
    assert {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)} == counts_before_bad_root

    assert {:ok, invalid_glob_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               in_scope.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-DISPATCH-GLOBSTAR",
                 target_base_branch: anchor.base_branch,
                 owned_file_globs: ["scripts/**deploy**"]
               )
             )

    assert {:ok, approved_invalid_glob_slice} =
             WorkRequestRepository.approve_planned_slice(repo, in_scope.id, invalid_glob_slice.id, "planned")

    counts_before_invalid_glob = {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)}

    invalid_glob_response =
      mcp_tool(repo, session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => in_scope.id,
        "planned_slice_id" => approved_invalid_glob_slice.id,
        "claimed_by" => "worker-dispatch-invalid-glob"
      })

    assert get_in(invalid_glob_response, ["error", "code"]) == -32_602
    assert get_in(invalid_glob_response, ["error", "data", "reason"]) == "planned_slice_scope_violation"

    assert get_in(invalid_glob_response, ["error", "data", "validation_errors"]) == [
             %{"field" => "owned_file_globs", "value" => "scripts/**deploy**", "reason" => "unsupported_globstar"}
           ]

    assert {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)} == counts_before_invalid_glob

    assert {:ok, live_database_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               in_scope.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-WR-DISPATCH-LIVE-DATABASE", target_base_branch: anchor.base_branch)
             )

    assert {:ok, approved_live_database_slice} =
             WorkRequestRepository.approve_planned_slice(repo, in_scope.id, live_database_slice.id, "planned")

    live_database = current_main_database_path(repo)
    configured_live_database = sqlite_file_uri(live_database, "mode=rwc&cache=shared")
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    live_database_response =
      try do
        Application.put_env(:symphony_elixir, :sympp_repo_database, configured_live_database)

        mcp_tool(repo, session, "dispatch_work_request_planned_slice", %{
          "work_request_id" => in_scope.id,
          "planned_slice_id" => approved_live_database_slice.id,
          "claimed_by" => "worker-dispatch-1"
        })
      after
        restore_app_env(:sympp_repo_database, original_database)
      end

    live_database_payload = get_in(live_database_response, ["result", "structuredContent"])
    assert live_database_payload["planned_slice"]["status"] == "dispatched"
    assert live_database_payload["worker_handoff"]["secret_handoff"] == nil
    assert live_database_payload["worker_bootstrap"]["claim"]["tool"] == "claim_local_assignment"
    assert_same_ledger_database(live_database_payload["worker_bootstrap"]["ledger"], live_database, "mode=rwc&cache=shared")
    refute inspect(live_database_response) =~ "run_mcp_command"

    assert {:ok, blank_database_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               in_scope.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-WR-DISPATCH-BLANK-DATABASE", target_base_branch: anchor.base_branch)
             )

    assert {:ok, approved_blank_database_slice} =
             WorkRequestRepository.approve_planned_slice(repo, in_scope.id, blank_database_slice.id, "planned")

    blank_database_response =
      mcp_tool(
        repo,
        session,
        "dispatch_work_request_planned_slice",
        %{
          "work_request_id" => in_scope.id,
          "planned_slice_id" => approved_blank_database_slice.id,
          "claimed_by" => "worker-dispatch-1"
        },
        config: Config.default(repo: repo, repo_root: test_repo_root(), database: "   ")
      )

    blank_database_payload = get_in(blank_database_response, ["result", "structuredContent"])
    assert blank_database_payload["planned_slice"]["status"] == "dispatched"
    assert blank_database_payload["worker_handoff"]["secret_handoff"] == nil
    assert blank_database_payload["worker_bootstrap"]["claim"]["tool"] == "claim_local_assignment"
    assert_same_ledger_database(blank_database_payload["worker_bootstrap"]["ledger"], live_database)
    refute inspect(blank_database_response) =~ "run_mcp_command"

    assert {:ok, branch_mismatch_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               in_scope.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-DISPATCH-BRANCH-MISMATCH",
                 target_base_branch: "feature/out-of-scope"
               )
             )

    assert {:ok, approved_branch_mismatch_slice} =
             WorkRequestRepository.approve_planned_slice(repo, in_scope.id, branch_mismatch_slice.id, "planned")

    counts_before_branch_mismatch = {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)}

    branch_mismatch_response =
      mcp_tool(repo, session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => in_scope.id,
        "planned_slice_id" => approved_branch_mismatch_slice.id,
        "claimed_by" => "worker-dispatch-1"
      })

    assert get_in(branch_mismatch_response, ["error", "code"]) == -32_602
    assert get_in(branch_mismatch_response, ["error", "data", "reason"]) == "target_base_branch_scope_mismatch"
    assert {repo.aggregate(WorkPackage, :count), repo.aggregate(AccessGrant, :count)} == counts_before_branch_mismatch
  end

  test "WorkPackage worktree MCP tools fail closed outside linked WorkRequest scope", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WORKTREE-SCOPE", [
        "dispatch:work_request"
      ])

    assert {:ok, unlinked_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-WORKTREE-UNLINKED", kind: "mcp", base_branch: "main")
             )

    prepare_response =
      mcp_tool(repo, session, "prepare_work_package_worktree", %{
        "work_package_id" => unlinked_package.id,
        "target_repo_root" => test_repo_root(),
        "base_branch" => "main",
        "branch" => "feat/worktree"
      })

    assert get_in(prepare_response, ["error", "code"]) == -32_004
    assert get_in(prepare_response, ["error", "data", "reason"]) == "not_found"

    cleanup_response =
      mcp_tool(repo, session, "cleanup_work_package_worktree", %{
        "work_package_id" => unlinked_package.id,
        "target_repo_root" => test_repo_root()
      })

    assert get_in(cleanup_response, ["error", "code"]) == -32_004
    assert get_in(cleanup_response, ["error", "data", "reason"]) == "not_found"

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-PACKAGE-SCOPE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WORKTREE-PACKAGE-SCOPE",
                 title: "Out-of-scope worktree package",
                 target_base_branch: anchor.base_branch,
                 branch_pattern: "feat/worktree",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_packages/**"],
                 acceptance_criteria: ["Keep worktree operations scoped."]
               )
             )

    assert {:ok, stale_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORKTREE-STALE-SCOPE",
                 kind: planned_slice.work_package_kind,
                 title: planned_slice.title,
                 repo: anchor.repo,
                 base_branch: anchor.base_branch,
                 branch_pattern: planned_slice.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: planned_slice.owned_file_globs,
                 acceptance_criteria: planned_slice.acceptance_criteria,
                 status: "ready_for_worker"
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    assert {:ok, _linked_slice} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", stale_package.id)

    assert {:ok, _drifted_package} =
             WorkPackageRepository.update(repo, stale_package.id, %{base_branch: "#{anchor.base_branch}-stale"})

    stale_prepare_response =
      mcp_tool(repo, session, "prepare_work_package_worktree", %{
        "work_package_id" => stale_package.id,
        "target_repo_root" => test_repo_root(),
        "base_branch" => anchor.base_branch,
        "branch" => "feat/worktree"
      })

    assert get_in(stale_prepare_response, ["error", "code"]) == -32_004
    assert get_in(stale_prepare_response, ["error", "data", "reason"]) == "not_found"

    stale_cleanup_response =
      mcp_tool(repo, session, "cleanup_work_package_worktree", %{
        "work_package_id" => stale_package.id,
        "target_repo_root" => test_repo_root()
      })

    assert get_in(stale_cleanup_response, ["error", "code"]) == -32_004
    assert get_in(stale_cleanup_response, ["error", "data", "reason"]) == "not_found"
  end

  test "WorkPackage worktree MCP prepare rejects same-name owner conflicts", %{repo: repo} do
    target_repo_root =
      TestSupport.git_repo_with_origin_fixture!("https://github.com/acme/frontend.git",
        prefix: "sympp-mcp-bare-scope-target"
      )

    previous_trusted_remotes = Application.get_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)

    {anchor, session, _grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-ARCHITECT-WORKTREE-BARE-REPO",
        ["dispatch:work_request"],
        repo: "frontend"
      )

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-BARE-REPO",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WORKTREE-BARE-REPO",
                 title: "Prepare owner-scoped package worktree",
                 target_base_branch: anchor.base_branch,
                 branch_pattern: "feat/bare-repo-worktree",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
                 acceptance_criteria: ["Reject same-name owner conflicts."]
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORKTREE-BARE-REPO",
                 kind: planned_slice.work_package_kind,
                 title: planned_slice.title,
                 repo: work_request.repo,
                 base_branch: planned_slice.target_base_branch,
                 branch_pattern: planned_slice.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: planned_slice.owned_file_globs,
                 acceptance_criteria: planned_slice.acceptance_criteria,
                 status: "ready_for_worker"
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    assert {:ok, _linked_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    try do
      Application.put_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes, ["Pimpmuckl/frontend"])

      response =
        mcp_tool(repo, session, "prepare_work_package_worktree", %{
          "work_package_id" => package.id,
          "target_repo_root" => target_repo_root,
          "base_branch" => anchor.base_branch,
          "branch" => "feat/bare-repo-worktree"
        })

      assert get_in(response, ["error", "code"]) == -32_602
      assert get_in(response, ["error", "data", "reason"]) == "target_repo_root_scope_mismatch"
    after
      restore_app_env(:sympp_repo_identity_trusted_remotes, previous_trusted_remotes)
    end
  end

  test "WorkPackage worktree MCP prepare ignores unrelated host checkout origin", %{repo: repo} do
    fixture =
      "symphony-plus-plus/beta"
      |> TestSupport.git_repo_fixture!(prefix: "sympp-mcp-bare-host-conflict-worktree")
      |> set_relative_owner_origin!("acme/frontend")

    host_repo_root =
      TestSupport.git_repo_with_origin_fixture!("https://github.com/other/frontend.git",
        prefix: "sympp-mcp-host-same-name-other-owner"
      )

    codex_home = Path.join(fixture.root, "codex-home")
    config = Config.default(repo: repo, repo_root: host_repo_root)
    previous_trusted_remotes = Application.get_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes)

    {anchor, session, _grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-ARCHITECT-WORKTREE-HOST-CONFLICT",
        ["dispatch:work_request"],
        repo: "frontend"
      )

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-HOST-CONFLICT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WORKTREE-HOST-CONFLICT",
                 title: "Prepare bare repo target without host conflicts",
                 target_base_branch: anchor.base_branch,
                 branch_pattern: "feat/bare-host-conflict-worktree",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
                 acceptance_criteria: ["Do not let the MCP host checkout affect target repo scope."]
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORKTREE-HOST-CONFLICT",
                 kind: planned_slice.work_package_kind,
                 title: planned_slice.title,
                 repo: work_request.repo,
                 base_branch: planned_slice.target_base_branch,
                 branch_pattern: planned_slice.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: planned_slice.owned_file_globs,
                 acceptance_criteria: planned_slice.acceptance_criteria,
                 status: "ready_for_worker"
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    assert {:ok, _linked_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)
      Application.put_env(:symphony_elixir, :sympp_repo_identity_trusted_remotes, ["acme/frontend"])

      prepare_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root,
            "base_branch" => anchor.base_branch,
            "branch" => "feat/bare-host-conflict-worktree"
          },
          config: config
        )

      prepare_payload = get_in(prepare_response, ["result", "structuredContent"])
      assert prepare_payload["worktree"]["status"] == "prepared"

      cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root
          },
          config: config
        )

      cleanup_payload = get_in(cleanup_response, ["result", "structuredContent"])
      assert cleanup_payload["worktree"]["status"] == "cleaned"
    after
      restore_env("CODEX_HOME", previous_codex_home)
      restore_app_env(:sympp_repo_identity_trusted_remotes, previous_trusted_remotes)
    end
  end

  test "WorkPackage worktree MCP prepare and cleanup accept bare repo with owner-qualified target origin", %{repo: repo} do
    fixture =
      "symphony-plus-plus/beta"
      |> TestSupport.git_repo_fixture!(prefix: "sympp-mcp-bare-origin-worktree")
      |> set_relative_owner_origin!("Pimpmuckl/symphony-plus-plus")

    codex_home = Path.join(fixture.root, "codex-home")
    config = Config.default(repo: repo, repo_root: fixture.repo_root)

    {anchor, session, _grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-ARCHITECT-WORKTREE-BARE-ORIGIN",
        ["dispatch:work_request"],
        repo: "symphony-plus-plus"
      )

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-BARE-ORIGIN",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WORKTREE-BARE-ORIGIN",
                 title: "Prepare bare repo target origin worktree",
                 target_base_branch: anchor.base_branch,
                 branch_pattern: "feat/bare-origin-worktree",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
                 acceptance_criteria: ["Accept unambiguous owner-qualified target origin."]
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORKTREE-BARE-ORIGIN",
                 kind: planned_slice.work_package_kind,
                 title: planned_slice.title,
                 repo: work_request.repo,
                 base_branch: planned_slice.target_base_branch,
                 branch_pattern: planned_slice.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: planned_slice.owned_file_globs,
                 acceptance_criteria: planned_slice.acceptance_criteria,
                 status: "ready_for_worker"
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    assert {:ok, _linked_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      prepare_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root,
            "base_branch" => anchor.base_branch,
            "branch" => "feat/bare-origin-worktree"
          },
          config: config
        )

      prepare_payload = get_in(prepare_response, ["result", "structuredContent"])
      assert prepare_payload["worktree"]["status"] == "prepared"
      assert comparable_path(prepare_payload["worktree"]["target_repo_root"]) == comparable_path(fixture.repo_root)
      assert File.dir?(prepare_payload["worktree"]["path"])

      cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root
          },
          config: config
        )

      cleanup_payload = get_in(cleanup_response, ["result", "structuredContent"])
      assert cleanup_payload["worktree"]["status"] == "cleaned"
      assert cleanup_payload["work_package"]["worktree_path"] == nil
      refute File.exists?(prepare_payload["worktree"]["path"])
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end
  end

  test "WorkPackage worktree MCP tools prepare, audit, and cleanup a linked package", %{repo: repo} do
    fixture = TestSupport.git_repo_fixture!("symphony-plus-plus/beta", prefix: "sympp-mcp-worktree")
    other_fixture = TestSupport.git_repo_fixture!("symphony-plus-plus/beta", prefix: "sympp-mcp-other-worktree")
    same_origin_repo_root = TestSupport.git_repo_with_origin_fixture!(fixture.origin, prefix: "sympp-mcp-same-origin-worktree")
    codex_home = Path.join(fixture.root, "codex-home")
    config = Config.default(repo: repo, repo_root: test_repo_root())

    {anchor, session, _grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-ARCHITECT-WORKTREE-LIFECYCLE",
        [
          "dispatch:work_request"
        ],
        repo: fixture.origin
      )

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WORKTREE-LIFECYCLE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "sliced"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WORKTREE-LIFECYCLE",
                 title: "Prepare package worktree",
                 target_base_branch: anchor.base_branch,
                 branch_pattern: "feat/worktree-lifecycle",
                 owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_packages/**"],
                 acceptance_criteria: ["Prepare and clean worktrees."]
               )
             )

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-WORKTREE-LIFECYCLE",
                 kind: planned_slice.work_package_kind,
                 title: planned_slice.title,
                 repo: work_request.repo,
                 base_branch: planned_slice.target_base_branch,
                 branch_pattern: planned_slice.branch_pattern,
                 product_description: work_request.human_description,
                 allowed_file_globs: planned_slice.owned_file_globs,
                 acceptance_criteria: planned_slice.acceptance_criteria,
                 status: "ready_for_worker"
               )
             )

    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")
    assert {:ok, _linked_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", package.id)

    previous_codex_home = System.get_env("CODEX_HOME")

    try do
      System.put_env("CODEX_HOME", codex_home)

      already_clean_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => other_fixture.repo_root
          },
          config: config
        )

      already_clean_payload = get_in(already_clean_response, ["result", "structuredContent"])
      assert already_clean_payload["worktree"]["status"] == "already_clean"
      assert already_clean_payload["work_package"]["worktree_path"] == nil

      scope_mismatch_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => other_fixture.repo_root,
            "base_branch" => anchor.base_branch,
            "branch" => "feat/wrong-root"
          },
          config: config
        )

      assert get_in(scope_mismatch_response, ["error", "data", "reason"]) == "target_repo_root_scope_mismatch"

      wrong_base_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root,
            "base_branch" => "#{anchor.base_branch}-wrong",
            "branch" => "feat/wrong-base"
          },
          config: config
        )

      assert get_in(wrong_base_response, ["error", "data", "reason"]) == "base_branch_scope_mismatch"

      prepare_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root,
            "base_branch" => anchor.base_branch,
            "branch" => "feat/worktree-lifecycle"
          },
          config: config
        )

      prepare_payload = get_in(prepare_response, ["result", "structuredContent"])
      assert prepare_payload["worktree"]["status"] == "prepared"
      assert prepare_payload["work_package"]["worktree_path"] == prepare_payload["worktree"]["path"]
      assert comparable_path(prepare_payload["worktree"]["target_repo_root"]) == comparable_path(fixture.repo_root)
      assert prepare_payload["worker_launch"]["workspace_path"] == prepare_payload["worktree"]["path"]
      assert prepare_payload["worker_launch"]["instruction"] =~ "Use this worktree only"
      assert prepare_payload["audit_event"]["payload"]["source_tool"] == "prepare_work_package_worktree"
      assert prepare_payload["audit_event"]["payload"]["worktree_path"] == "[REDACTED]"
      assert prepare_payload["audit_event"]["payload"]["target_repo_root"] == "[REDACTED]"
      assert File.dir?(prepare_payload["worktree"]["path"])

      same_origin_cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => same_origin_repo_root
          },
          config: config
        )

      assert get_in(same_origin_cleanup_response, ["error", "data", "reason"]) == "invalid_worktree_path"
      assert File.dir?(prepare_payload["worktree"]["path"])

      cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root
          },
          config: config
        )

      cleanup_payload = get_in(cleanup_response, ["result", "structuredContent"])
      assert cleanup_payload["worktree"]["status"] == "cleaned"
      assert cleanup_payload["audit_event"]["summary"] == "Success removing worktree. Subagent can be closed now."
      assert cleanup_payload["work_package"]["worktree_path"] == nil
      assert cleanup_payload["audit_event"]["payload"]["source_tool"] == "cleanup_work_package_worktree"
      assert cleanup_payload["audit_event"]["payload"]["worktree_path"] == "[REDACTED]"
      assert cleanup_payload["audit_event"]["payload"]["target_repo_root"] == "[REDACTED]"
      refute File.exists?(prepare_payload["worktree"]["path"])

      stale_prepare_response =
        mcp_tool(
          repo,
          session,
          "prepare_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root,
            "base_branch" => anchor.base_branch,
            "branch" => "feat/worktree-lifecycle-stale"
          },
          config: config
        )

      stale_prepare_payload = get_in(stale_prepare_response, ["result", "structuredContent"])
      assert stale_prepare_payload["worktree"]["status"] == "prepared"
      File.rm_rf!(stale_prepare_payload["worktree"]["path"])

      stale_cleanup_response =
        mcp_tool(
          repo,
          session,
          "cleanup_work_package_worktree",
          %{
            "work_package_id" => package.id,
            "target_repo_root" => fixture.repo_root
          },
          config: config
        )

      stale_cleanup_payload = get_in(stale_cleanup_response, ["result", "structuredContent"])
      assert stale_cleanup_payload["worktree"]["status"] == "stale_record_cleared"
      assert stale_cleanup_payload["work_package"]["worktree_path"] == nil
      assert stale_cleanup_payload["audit_event"]["payload"]["source_tool"] == "cleanup_work_package_worktree"
      assert stale_cleanup_payload["audit_event"]["payload"]["status"] == "stale_record_cleared"
    after
      restore_env("CODEX_HOME", previous_codex_home)
    end

    assert {:ok, cleaned_package} = WorkPackageRepository.get(repo, package.id)
    assert cleaned_package.worktree_path == nil

    events =
      repo.all(
        from(progress_event in ProgressEvent,
          where: progress_event.work_package_id == ^package.id,
          order_by: [asc: progress_event.sequence]
        )
      )

    assert Enum.map(events, & &1.payload["source_tool"]) == [
             "prepare_work_package_worktree",
             "cleanup_work_package_worktree",
             "prepare_work_package_worktree",
             "cleanup_work_package_worktree"
           ]
  end

  test "mark WorkRequest sliced MCP tool preserves approved-slice requirement", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-GUARD", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-GUARD",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    response =
      mcp_tool(repo, session, "mark_work_request_sliced", %{
        "work_request_id" => work_request.id,
        "current_status" => "ready_for_slicing"
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "no_approved_slices"

    assert {:ok, persisted_work_request} = WorkRequestRepository.get(repo, work_request.id)
    assert persisted_work_request.status == "ready_for_slicing"
  end

  test "WorkRequest MCP planned-slice mutations require slice authoring status", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-STATUS", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-STATUS",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "draft"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    add_args = %{
      "work_request_id" => work_request.id,
      "title" => "Draft-state slice",
      "goal" => "Should wait until slicing is open.",
      "work_package_kind" => "mcp",
      "target_base_branch" => anchor.base_branch,
      "owned_file_globs" => ["elixir/lib/**"],
      "forbidden_file_globs" => [],
      "acceptance_criteria" => ["WorkRequest is sliceable."],
      "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp_test.exs"],
      "review_lanes" => ["normal"],
      "stop_conditions" => ["Stop before dispatch."]
    }

    add_response = mcp_tool(repo, session, "add_work_request_planned_slice", add_args)
    assert get_in(add_response, ["error", "code"]) == -32_602
    assert get_in(add_response, ["error", "data", "reason"]) == "invalid_status"
    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, Map.delete(add_args, "work_request_id"))

    for tool <- ["approve_work_request_planned_slice", "skip_work_request_planned_slice"] do
      response =
        mcp_tool(repo, session, tool, %{
          "work_request_id" => work_request.id,
          "planned_slice_id" => planned_slice.id,
          "current_status" => "planned"
        })

      assert get_in(response, ["error", "code"]) == -32_602
      assert get_in(response, ["error", "data", "reason"]) == "invalid_status"
    end

    assert {:ok, [persisted_slice]} = WorkRequestRepository.list_planned_slices(repo, work_request.id)
    assert persisted_slice.status == "planned"
  end

  test "WorkRequest MCP planned-slice writes honor planned-slice scope without parent WorkRequest scope", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-EXPLICIT", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-EXPLICIT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-SLICE-EXPLICIT",
                 target_base_branch: anchor.base_branch
               )
             )

    grant_planned_slice_scope!(repo, session, planned_slice.id)
    remove_grant_scope_type!(repo, session, "repo")

    response =
      mcp_tool(repo, session, "approve_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "current_status" => "planned"
      })

    assert get_in(response, ["result", "structuredContent", "planned_slice", "status"]) == "approved"
    assert get_in(response, ["result", "structuredContent", "work_request", "id"]) == work_request.id

    assert {:ok, persisted_slice} = WorkRequestRepository.get_planned_slice(repo, work_request.id, planned_slice.id)
    assert persisted_slice.status == "approved"
  end

  test "WorkRequest MCP mutations require write capability and explicit live phase scope", %{repo: repo} do
    {read_anchor, read_session, _read_grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-READONLY", [
        "read:work_request"
      ])

    read_only_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-READONLY",
        repo: read_anchor.repo,
        base_branch: read_anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, read_only_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               read_only_work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-MUTATE-READONLY",
                 target_base_branch: read_anchor.base_branch
               )
             )

    read_only_response =
      mcp_tool(repo, read_session, "ask_work_request_question", %{
        "work_request_id" => read_only_work_request.id,
        "category" => "scope",
        "question" => "Question?",
        "why_needed" => "Capability check."
      })

    assert get_in(read_only_response, ["error", "code"]) == -32_003
    assert get_in(read_only_response, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(read_only_response, ["error", "data", "reason_code"]) == "insufficient_capability"

    read_only_slice_response =
      mcp_tool(repo, read_session, "add_work_request_planned_slice", %{
        "work_request_id" => read_only_work_request.id,
        "title" => "Denied slice",
        "goal" => "Capability check.",
        "work_package_kind" => "mcp",
        "target_base_branch" => read_anchor.base_branch,
        "owned_file_globs" => [],
        "forbidden_file_globs" => [],
        "acceptance_criteria" => [],
        "validation_steps" => [],
        "review_lanes" => [],
        "stop_conditions" => []
      })

    assert get_in(read_only_slice_response, ["error", "code"]) == -32_003
    assert get_in(read_only_slice_response, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(read_only_slice_response, ["error", "data", "reason_code"]) == "insufficient_capability"

    read_only_dispatch_response =
      mcp_tool(repo, read_session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => read_only_work_request.id,
        "planned_slice_id" => read_only_slice.id,
        "claimed_by" => "worker-1"
      })

    assert get_in(read_only_dispatch_response, ["error", "code"]) == -32_003
    assert get_in(read_only_dispatch_response, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(read_only_dispatch_response, ["error", "data", "reason_code"]) == "insufficient_capability"

    read_only_prepare_response =
      mcp_tool(repo, read_session, "prepare_work_package_worktree", %{
        "work_package_id" => "wp-missing",
        "repo_root" => test_repo_root(),
        "base_branch" => "main",
        "branch" => "feat/denied"
      })

    assert get_in(read_only_prepare_response, ["error", "code"]) == -32_001
    assert get_in(read_only_prepare_response, ["error", "data", "reason"]) == "insufficient_capability"

    read_only_tools =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "read-only-tools", "method" => "tools/list", "params" => %{}},
        repo: repo,
        session: read_session
      )
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    for tool <- @architect_tool_names do
      assert Map.has_key?(read_only_tools, tool)
    end

    assert {:ok, legacy_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-WR-MUTATE-LEGACY", kind: "mcp"))

    assert {:error, %Ecto.Changeset{} = legacy_changeset} =
             create_architect_work_key(repo, legacy_package.id, ["write:work_request"])

    assert {"architect phase-scoped grants require phase scope", []} in Keyword.get_values(legacy_changeset.errors, :phase_id)

    {drift_anchor, drift_session, _drift_grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-DRIFT", [
        "write:work_request",
        "dispatch:work_request"
      ])

    drift_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-DRIFT",
        repo: drift_anchor.repo,
        base_branch: drift_anchor.base_branch,
        status: "draft"
      )

    grant_work_request_scope!(repo, drift_session, drift_work_request.id)

    assert {:ok, drift_planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               drift_work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-MUTATE-DRIFT",
                 target_base_branch: drift_anchor.base_branch
               )
             )

    assert {:ok, _drifted_anchor} = WorkPackageRepository.update(repo, drift_anchor.id, %{repo: "nextide/other"})

    drift_response =
      mcp_tool(repo, drift_session, "set_work_request_status", %{
        "work_request_id" => drift_work_request.id,
        "current_status" => "draft",
        "next_status" => "ready_for_clarification"
      })

    assert get_in(drift_response, ["error", "code"]) == -32_003
    assert get_in(drift_response, ["error", "data", "reason"]) == "outside_session_scope"

    drift_slice_response =
      mcp_tool(repo, drift_session, "mark_work_request_sliced", %{
        "work_request_id" => drift_work_request.id,
        "current_status" => "ready_for_slicing"
      })

    assert get_in(drift_slice_response, ["error", "code"]) == -32_003
    assert get_in(drift_slice_response, ["error", "data", "reason"]) == "outside_session_scope"

    drift_dispatch_response =
      mcp_tool(repo, drift_session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => drift_work_request.id,
        "planned_slice_id" => drift_planned_slice.id,
        "claimed_by" => "worker-1"
      })

    assert get_in(drift_dispatch_response, ["error", "code"]) == -32_003
    assert get_in(drift_dispatch_response, ["error", "data", "reason"]) == "outside_session_scope"

    {revoked_anchor, revoked_session, revoked_grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-REVOKED", [
        "write:work_request",
        "dispatch:work_request"
      ])

    revoked_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-REVOKED",
        repo: revoked_anchor.repo,
        base_branch: revoked_anchor.base_branch,
        status: "draft"
      )

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, revoked_grant.id)

    revoked_response =
      mcp_tool(repo, revoked_session, "set_work_request_status", %{
        "work_request_id" => revoked_work_request.id,
        "current_status" => "draft",
        "next_status" => "ready_for_clarification"
      })

    assert get_in(revoked_response, ["error", "code"]) == -32_001
    assert get_in(revoked_response, ["error", "data", "reason"]) == "revoked"

    revoked_slice_response =
      mcp_tool(repo, revoked_session, "mark_work_request_sliced", %{
        "work_request_id" => revoked_work_request.id,
        "current_status" => "ready_for_slicing"
      })

    assert get_in(revoked_slice_response, ["error", "code"]) == -32_001
    assert get_in(revoked_slice_response, ["error", "data", "reason"]) == "revoked"

    revoked_dispatch_response =
      mcp_tool(repo, revoked_session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => revoked_work_request.id,
        "planned_slice_id" => "WRS-MCP-WR-MUTATE-REVOKED",
        "claimed_by" => "worker-1"
      })

    assert get_in(revoked_dispatch_response, ["error", "code"]) == -32_001
    assert get_in(revoked_dispatch_response, ["error", "data", "reason"]) == "revoked"

    assert {:ok, worker_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WR-MUTATE-WORKER", kind: "mcp"))
    assert {:ok, worker_minted} = AccessGrantService.mint_worker_grant(repo, worker_package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, worker_minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: worker_minted.grant.secret_hash)

    worker_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-WORKER",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta",
        status: "ready_for_slicing"
      )

    assert {:ok, worker_planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               worker_work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-MUTATE-WORKER",
                 target_base_branch: "symphony-plus-plus/beta"
               )
             )

    worker_response =
      mcp_tool(repo, worker_session, "set_work_request_status", %{
        "work_request_id" => worker_work_request.id,
        "current_status" => "draft",
        "next_status" => "ready_for_clarification"
      })

    assert get_in(worker_response, ["error", "code"]) == -32_003
    assert get_in(worker_response, ["error", "data", "reason_code"]) == "insufficient_role"

    worker_slice_response =
      mcp_tool(repo, worker_session, "mark_work_request_sliced", %{
        "work_request_id" => worker_work_request.id,
        "current_status" => "ready_for_slicing"
      })

    assert get_in(worker_slice_response, ["error", "code"]) == -32_003
    assert get_in(worker_slice_response, ["error", "data", "reason_code"]) == "insufficient_role"

    worker_dispatch_response =
      mcp_tool(repo, worker_session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => worker_work_request.id,
        "planned_slice_id" => worker_planned_slice.id,
        "claimed_by" => "worker-1"
      })

    assert get_in(worker_dispatch_response, ["error", "code"]) == -32_003
    assert get_in(worker_dispatch_response, ["error", "data", "reason_code"]) == "insufficient_role"

    anonymous_response =
      mcp_tool(repo, nil, "set_work_request_status", %{
        "work_request_id" => "WR-MCP-WR-MISSING",
        "current_status" => "draft",
        "next_status" => "ready_for_clarification"
      })

    assert get_in(anonymous_response, ["error", "code"]) == -32_001
    assert get_in(anonymous_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(anonymous_response, ["error", "data", "action"]) == "claim_work_key"

    anonymous_slice_response =
      mcp_tool(repo, nil, "mark_work_request_sliced", %{
        "work_request_id" => "WR-MCP-WR-MISSING",
        "current_status" => "ready_for_slicing"
      })

    assert get_in(anonymous_slice_response, ["error", "code"]) == -32_001
    assert get_in(anonymous_slice_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(anonymous_slice_response, ["error", "data", "action"]) == "claim_work_key"

    anonymous_dispatch_response =
      mcp_tool(repo, nil, "dispatch_work_request_planned_slice", %{
        "work_request_id" => "WR-MCP-WR-MISSING",
        "planned_slice_id" => "WRS-MCP-WR-MISSING",
        "claimed_by" => "worker-1"
      })

    assert get_in(anonymous_dispatch_response, ["error", "code"]) == -32_001
    assert get_in(anonymous_dispatch_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(anonymous_dispatch_response, ["error", "data", "action"]) == "claim_work_key"
  end

  test "WorkRequest MCP question mutations fail closed for sibling question ids", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-SIBLING-QUESTION", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-QUESTION-OWNER",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "clarifying"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-QUESTION-SIBLING",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "clarifying"
      )

    assert {:ok, sibling_question} =
             WorkRequestRepository.ask_question(
               repo,
               sibling.id,
               work_request_question_attrs(id: "WRQ-MCP-WR-SIBLING-QUESTION")
             )

    answer_response =
      mcp_tool(repo, session, "answer_work_request_question", %{
        "work_request_id" => work_request.id,
        "question_id" => sibling_question.id,
        "current_status" => "open",
        "answer" => "Do not answer a sibling question.",
        "answered_by" => "architect-1"
      })

    assert get_in(answer_response, ["error", "code"]) == -32_004
    assert get_in(answer_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(answer_response) =~ sibling.id

    close_response =
      mcp_tool(repo, session, "close_work_request_question", %{
        "work_request_id" => work_request.id,
        "question_id" => sibling_question.id,
        "current_status" => "open"
      })

    assert get_in(close_response, ["error", "code"]) == -32_004
    assert get_in(close_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(close_response) =~ sibling.id

    assert {:ok, [persisted_sibling_question]} = WorkRequestRepository.list_questions(repo, sibling.id)
    assert persisted_sibling_question.status == "open"
    assert persisted_sibling_question.answer == nil
  end

  test "WorkRequest MCP planned-slice status mutations fail closed for sibling slice ids", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-SIBLING-SLICE", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-SLICE-OWNER",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-SLICE-SIBLING",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, sibling_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               sibling.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-WR-SIBLING-SLICE")
             )

    approve_response =
      mcp_tool(repo, session, "approve_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => sibling_slice.id,
        "current_status" => "planned"
      })

    assert get_in(approve_response, ["error", "code"]) == -32_004
    assert get_in(approve_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(approve_response) =~ sibling.id

    skip_response =
      mcp_tool(repo, session, "skip_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => sibling_slice.id,
        "current_status" => "planned"
      })

    assert get_in(skip_response, ["error", "code"]) == -32_004
    assert get_in(skip_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(skip_response) =~ sibling.id

    assert {:ok, [persisted_sibling_slice]} = WorkRequestRepository.list_planned_slices(repo, sibling.id)
    assert persisted_sibling_slice.status == "planned"
    assert persisted_sibling_slice.work_package_id == nil
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

    assert String.downcase(worker_grant["secret_handoff"]["run_mcp_command"]) =~
             String.downcase(current_main_database_path(repo))

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
    if windows_credential_manager_integration_enabled?() do
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
        assert get_in(health_response, ["result", "structuredContent", "ledger", "reachable"]) == true
        assert assignment["work_package_id"] == child_id
        assert assignment["claimed_by"] == claimed_by

        assert {:ok, claimed_grant} = AccessGrantRepository.get(repo, worker_grant["id"])
        assert claimed_grant.claimed_by == claimed_by
        assert %DateTime{} = claimed_grant.claimed_at
      after
        cleanup_child_worker_handoff(handoff, claimed_by)
      end
    else
      assert test_secret_handoff_mode() == "auto"
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

  test "phase architect revokes child worker grant and can remint same child", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-RECYCLE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "revoke:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-RECYCLE-CHILD")

    first_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    first_grant_id = get_in(first_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(first_grant_id)
    assert {:ok, first_grant_before_revoke} = AccessGrantRepository.get(repo, first_grant_id)
    assert first_grant_before_revoke.revoked_at == nil
    assert first_grant_before_revoke.provenance == @child_worker_grant_provenance

    revoke_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => first_grant_id,
        "reason" => "worker lost heartbeat"
      })

    revoked_grant = get_in(revoke_response, ["result", "structuredContent", "revoked_worker_grant"])
    assert revoked_grant["id"] == first_grant_id
    assert revoked_grant["work_package_id"] == child_id
    assert revoked_grant["secret_in_response"] == false
    assert is_binary(revoked_grant["revoked_at"])
    refute Map.has_key?(revoked_grant, "display_key")
    refute Map.has_key?(revoked_grant, "secret")
    refute Map.has_key?(revoked_grant, "secret_hash")
    refute Map.has_key?(revoked_grant, "secret_returned_once")

    recycle = get_in(revoke_response, ["result", "structuredContent", "recycle"])
    assert recycle["status"] == "revoked"
    assert recycle["reason"] == "worker lost heartbeat"
    assert recycle["previous_child_status"] == "ready_for_worker"
    assert recycle["new_child_status"] == "ready_for_worker"
    assert recycle["status_reset"] == false
    assert recycle["remint_available"] == true
    assert recycle["private_handoff_cleanup"] == "not_attempted"
    assert recycle["lifecycle_state"] == "recycled"
    assert recycle["reason_codes"] == ["worker_recycled"]

    event = get_in(revoke_response, ["result", "structuredContent", "revocation_event"])
    assert event["status"] == "child_worker_key_revoked"
    assert event["payload"]["type"] == "child_worker_key_revoke"
    assert event["payload"]["source_tool"] == "revoke_child_worker_key"
    assert event["payload"]["work_package_id"] == child_id
    assert event["payload"]["grant_id"] == first_grant_id
    assert event["payload"]["reason"] == "worker lost heartbeat"
    assert event["payload"]["previous_status"] == "ready_for_worker"
    assert event["payload"]["new_status"] == "ready_for_worker"
    assert event["payload"]["status_reset"] == false
    assert event["payload"]["private_handoff_cleanup"] == "not_attempted"
    assert event["payload"]["lifecycle_state"] == "recycled"
    assert event["payload"]["reason_codes"] == ["worker_recycled"]

    content_text = get_in(revoke_response, ["result", "content", Access.at(0), "text"])
    refute content_text =~ "display_key"
    refute content_text =~ "secret_hash"
    refute content_text =~ "secret_returned_once"

    assert {:ok, first_grant_after_revoke} = AccessGrantRepository.get(repo, first_grant_id)
    assert %DateTime{} = first_grant_after_revoke.revoked_at

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, child_id)
    assert Enum.any?(progress_events, &(&1.status == "child_worker_key_revoked" and &1.payload["grant_id"] == first_grant_id))

    second_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    second_grant_id = get_in(second_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(second_grant_id)
    assert second_grant_id != first_grant_id
    assert get_in(second_response, ["result", "structuredContent", "worker_grant", "work_package_id"]) == child_id
  end

  test "phase architect revokes in-progress child worker grant, resets child, and remints", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-RECYCLE-RESET-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "revoke:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-RECYCLE-RESET-CHILD")

    first_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template(%{"claimed_by" => "worker-1"})
      })

    first_grant_id = get_in(first_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(first_grant_id)

    worker_session = claim_child_worker_from_mint_response(repo, first_response, "worker-1")
    advance_child_worker_to_ci_waiting(repo, worker_session)

    assert {:ok, in_progress_child} = WorkPackageRepository.get(repo, child_id)
    assert in_progress_child.status == "ci_waiting"

    revoke_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => first_grant_id,
        "reason" => "worker died during implementation"
      })

    assert get_in(revoke_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_worker"

    recycle = get_in(revoke_response, ["result", "structuredContent", "recycle"])
    assert recycle["status"] == "revoked"
    assert recycle["previous_child_status"] == "ci_waiting"
    assert recycle["new_child_status"] == "ready_for_worker"
    assert recycle["status_reset"] == true
    assert recycle["remint_available"] == true
    assert recycle["reason_codes"] == ["worker_recycled", "work_package_reset_for_recycle"]

    event = get_in(revoke_response, ["result", "structuredContent", "revocation_event"])
    assert event["payload"]["grant_id"] == first_grant_id
    assert event["payload"]["previous_status"] == "ci_waiting"
    assert event["payload"]["new_status"] == "ready_for_worker"
    assert event["payload"]["status_reset"] == true
    assert event["payload"]["reason_codes"] == ["worker_recycled", "work_package_reset_for_recycle"]

    assert {:ok, reset_child} = WorkPackageRepository.get(repo, child_id)
    assert reset_child.status == "ready_for_worker"

    second_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    second_grant_id = get_in(second_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(second_grant_id)
    assert second_grant_id != first_grant_id

    stale_worker_response =
      mcp_tool(repo, worker_session, "set_status", %{
        "expected_status" => "ready_for_worker",
        "status" => "claimed",
        "reason" => "stale worker should not mutate recycled child"
      })

    assert get_in(stale_worker_response, ["error", "code"]) == -32_001
    assert get_in(stale_worker_response, ["error", "data", "reason"]) == "revoked"

    assert {:ok, child_after_stale_worker_attempt} = WorkPackageRepository.get(repo, child_id)
    assert child_after_stale_worker_attempt.status == "ready_for_worker"
  end

  test "child worker revoke rejects normal grants and worker callers", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-REVOKE-NORMAL-ANCHOR", [
        "create:child_work_package",
        "revoke:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-REVOKE-NORMAL-CHILD")

    invalid_grant_id_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => 123,
        "reason" => "invalid grant id"
      })

    assert get_in(invalid_grant_id_response, ["error", "code"]) == -32_602
    assert get_in(invalid_grant_id_response, ["error", "data", "reason"]) == "invalid_grant_id"

    invalid_reason_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => "grant-id",
        "reason" => 123
      })

    assert get_in(invalid_reason_response, ["error", "code"]) == -32_602
    assert get_in(invalid_reason_response, ["error", "data", "reason"]) == "invalid_reason"

    assert {:ok, normal_minted} = AccessGrantService.mint_worker_grant(repo, child_id)

    normal_revoke_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => normal_minted.grant.id,
        "reason" => "not a child-worker grant"
      })

    assert get_in(normal_revoke_response, ["error", "code"]) == -32_602
    assert get_in(normal_revoke_response, ["error", "data", "reason"]) == "not_child_worker_grant"

    assert {:ok, normal_grant_after_revoke_attempt} = AccessGrantRepository.get(repo, normal_minted.grant.id)
    assert normal_grant_after_revoke_attempt.revoked_at == nil

    assert {:ok, worker_minted} = AccessGrantService.mint_worker_grant(repo, child_id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, worker_minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: worker_minted.grant.secret_hash)

    worker_revoke_response =
      mcp_tool(repo, worker_session, "revoke_child_worker_key", %{
        "grant_id" => normal_minted.grant.id,
        "reason" => "worker caller denied"
      })

    assert get_in(worker_revoke_response, ["error", "code"]) == -32_001
    assert get_in(worker_revoke_response, ["error", "data", "reason"]) == "architect_grant_required"
  end

  test "child worker revoke rejects sibling and stale child grants", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-REVOKE-SCOPE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "revoke:child_worker_key",
        "read:phase"
      ])

    {_other_anchor, other_architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-REVOKE-SCOPE-OTHER", [
        "revoke:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-REVOKE-SCOPE-CHILD")

    mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    grant_id = get_in(mint_response, ["result", "structuredContent", "worker_grant", "id"])
    assert is_binary(grant_id)

    sibling_revoke_response =
      mcp_tool(repo, other_architect_session, "revoke_child_worker_key", %{
        "grant_id" => grant_id,
        "reason" => "sibling denied"
      })

    assert get_in(sibling_revoke_response, ["error", "code"]) == -32_003
    assert get_in(sibling_revoke_response, ["error", "data", "reason"]) == "outside_session_scope"

    assert {:ok, grant_after_sibling_attempt} = AccessGrantRepository.get(repo, grant_id)
    assert grant_after_sibling_attempt.revoked_at == nil
  end

  test "child worker revoke rejects already revoked and expired grants", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-REVOKE-STALE-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "revoke:child_worker_key",
        "read:phase"
      ])

    revoked_child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-REVOKE-STALE-REVOKED")

    revoked_mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => revoked_child_id,
        "template" => child_worker_template()
      })

    revoked_grant_id = get_in(revoked_mint_response, ["result", "structuredContent", "worker_grant", "id"])
    assert {:ok, _revoked_grant} = AccessGrantRepository.revoke(repo, revoked_grant_id, DateTime.utc_now(:microsecond))

    already_revoked_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => revoked_grant_id,
        "reason" => "second revoke denied"
      })

    assert get_in(already_revoked_response, ["error", "code"]) == -32_602
    assert get_in(already_revoked_response, ["error", "data", "reason"]) == "child_worker_grant_already_revoked"

    expired_child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-REVOKE-STALE-EXPIRED")

    expired_mint_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => expired_child_id,
        "template" => child_worker_template()
      })

    expired_grant_id = get_in(expired_mint_response, ["result", "structuredContent", "worker_grant", "id"])
    expired_at = DateTime.add(DateTime.utc_now(:microsecond), -60, :second)

    assert {1, _rows} =
             repo.update_all(
               from(grant in AccessGrant, where: grant.id == ^expired_grant_id),
               set: [expires_at: expired_at, updated_at: DateTime.utc_now(:microsecond)]
             )

    expired_revoke_response =
      mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
        "grant_id" => expired_grant_id,
        "reason" => "expired denied"
      })

    assert get_in(expired_revoke_response, ["error", "code"]) == -32_602
    assert get_in(expired_revoke_response, ["error", "data", "reason"]) == "child_worker_grant_expired"

    assert {:ok, expired_grant_after_revoke_attempt} = AccessGrantRepository.get(repo, expired_grant_id)
    assert expired_grant_after_revoke_attempt.revoked_at == nil
  end

  test "child worker revoke rejects architect-controlled child statuses", %{repo: repo} do
    {_anchor, architect_session} =
      create_architect_session(repo, "SYMPP-P7-002-REVOKE-STATUS-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "revoke:child_worker_key",
        "read:phase"
      ])

    for status <- ["ready_for_architect_merge", "merging_into_phase", "merged_into_phase", "closed", "abandoned"] do
      suffix = status |> String.replace("_", "-") |> String.upcase()
      child_id = "SYMPP-P7-002-REVOKE-STATUS-#{suffix}"
      child_id = create_child_work_package(repo, architect_session, child_id)

      mint_response =
        mcp_tool(repo, architect_session, "mint_child_worker_key", %{
          "work_package_id" => child_id,
          "template" => child_worker_template()
        })

      grant_id = get_in(mint_response, ["result", "structuredContent", "worker_grant", "id"])
      assert is_binary(grant_id)
      assert {:ok, _updated_child} = WorkPackageRepository.update(repo, child_id, %{status: status})

      response =
        mcp_tool(repo, architect_session, "revoke_child_worker_key", %{
          "grant_id" => grant_id,
          "reason" => "status denied"
        })

      assert get_in(response, ["error", "code"]) == -32_602
      assert get_in(response, ["error", "data", "reason"]) == "child_not_recyclable"

      assert {:ok, grant_after_revoke_attempt} = AccessGrantRepository.get(repo, grant_id)
      assert grant_after_revoke_attempt.revoked_at == nil
    end
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

  test "child worker key minting defaults to no expiry for non-expiring architect grants", %{repo: repo} do
    {_anchor, architect_session} =
      create_non_expiring_architect_session(repo, "SYMPP-P7-002-MINT-NO-EXPIRY-ANCHOR", [
        "create:child_work_package",
        "mint:child_worker_key",
        "read:phase"
      ])

    child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-NO-EXPIRY-CHILD")

    response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => child_id,
        "template" => child_worker_template()
      })

    assert get_in(response, ["result", "structuredContent", "worker_grant", "work_package_id"]) == child_id
    assert get_in(response, ["result", "structuredContent", "worker_grant", "expires_at"]) == nil

    grant_id = get_in(response, ["result", "structuredContent", "worker_grant", "id"])
    assert {:ok, grant} = AccessGrantRepository.get(repo, grant_id)
    assert grant.expires_at == nil

    explicit_child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-NO-EXPIRY-EXPLICIT")
    explicit_expires_at = DateTime.utc_now(:microsecond) |> DateTime.add(3_600, :second) |> DateTime.truncate(:microsecond)

    explicit_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => explicit_child_id,
        "template" => Map.put(child_worker_template(), "expires_at", DateTime.to_iso8601(explicit_expires_at))
      })

    assert get_in(explicit_response, ["result", "structuredContent", "worker_grant", "work_package_id"]) == explicit_child_id
    minted_expires_at = get_in(explicit_response, ["result", "structuredContent", "worker_grant", "expires_at"])
    assert {:ok, minted_expires_at, _offset} = DateTime.from_iso8601(minted_expires_at)
    assert DateTime.compare(DateTime.truncate(minted_expires_at, :microsecond), explicit_expires_at) == :eq

    expired_child_id = create_child_work_package(repo, architect_session, "SYMPP-P7-002-MINT-NO-EXPIRY-PAST")
    expired_expires_at = DateTime.utc_now(:microsecond) |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    expired_response =
      mcp_tool(repo, architect_session, "mint_child_worker_key", %{
        "work_package_id" => expired_child_id,
        "template" => Map.put(child_worker_template(), "expires_at", DateTime.to_iso8601(expired_expires_at))
      })

    assert get_in(expired_response, ["error", "code"]) == -32_602
    assert get_in(expired_response, ["error", "data", "reason"]) == "invalid_expires_at"
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

    assert get_in(post_merge_worker_report_blocker_response, ["error", "data", "reason"]) == "work_package_terminal"

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

  test "read_phase_board validates required phase_id before dashboard access", %{repo: repo} do
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

  test "remaining Phase 7 architect stubs return explicit not-yet-implemented errors", %{repo: repo} do
    {_package, session} =
      create_architect_session(repo, "SYMPP-ARCHITECT-PHASE7", [
        "read:phase",
        "request:child_replan"
      ])

    grants_before = repo.aggregate(AccessGrant, :count)

    replan_response =
      mcp_tool(repo, session, "request_child_replan", %{"work_package_id" => "SYMPP-ARCHITECT-PHASE7", "reason" => "not wired"})

    assert get_in(replan_response, ["error", "code"]) == -32_604
    assert get_in(replan_response, ["error", "data", "reason"]) == "phase7_not_implemented"
    assert repo.aggregate(AccessGrant, :count) == grants_before
  end

  test "Phase 7 architect stubs revalidate phase anchors before not-implemented", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-STUB-DRIFT", kind: "mcp"))
    assert {:ok, other_phase} = PhaseRepository.create(repo, %{id: "phase-mcp-stub-drift", title: "Stub drift"})

    assert {:ok, architect_work_key} =
             create_architect_work_key(repo, package.id, ["mint:child_worker_key", "read:phase", "request:child_replan"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    replan_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "replan-child-stub",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_child_replan",
            "arguments" => %{"work_package_id" => package.id, "reason" => "drift check"}
          }
        },
        config: test_mcp_config(repo),
        session: session
      )

    assert get_in(replan_response, ["error", "data", "reason"]) == "phase7_not_implemented"

    assert {:ok, _package} = WorkPackageRepository.update(repo, package.id, %{phase_id: other_phase.id})

    stale_replan_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "replan-child-stale",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_child_replan",
            "arguments" => %{"work_package_id" => package.id, "reason" => "drift check"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_replan_response, ["error", "code"]) == -32_003
    assert get_in(stale_replan_response, ["error", "data", "reason"]) == "outside_session_scope"

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
      "tests" => ["mix test", "brief green"],
      "artifacts" => ["review-brief-log.txt"],
      "head_sha" => "abc123",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
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
      "summary" => "Ready after normal",
      "tests" => ["mix test", "normal green"],
      "artifacts" => ["review-normal-log.txt"],
      "head_sha" => "abc123",
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    incremental_review_lanes_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-incremental-review-lanes", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    incremental_missing = get_in(incremental_review_lanes_response, ["error", "data", "missing"])
    refute "review_lanes_complete" in incremental_missing
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
              "reviews" => [%{"lane" => 1, "verdict" => "green"}, %{"lane" => "normal", "verdict" => nil}]
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
              "reviews" => [%{"lane" => "brief", "verdict" => "green", "note" => "typo"}]
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
                %{"lane" => " brief ", "verdict" => "red"},
                %{"lane" => "brief", "verdict" => "green"}
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
              "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
              "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
              "reviews" => %{"lane" => "brief", "verdict" => "green"}
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
              "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
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
              "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "findings"}]
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
              "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => " review_t2 ", "verdict" => " green "}]
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
              "reviews" => [%{"lane" => "brief", "verdict" => "red"}]
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

  test "mark_ready does not require ci_waiting when package policy omits CI", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-NO-CI", kind: "mcp", status: "reviewing"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-no-ci-missing", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(missing_response, ["error", "data", "missing"])
    refute "status_ci_waiting" in missing
    assert "plan_complete" in missing
    assert "acceptance_criteria_met" in missing
    assert "tests_passed" in missing
    assert "pr_attached" in missing
    assert "review_package_submitted" in missing
    assert "review_lanes_complete" in missing

    append_merge_ready_evidence(repo, session, package.id, "head-no-ci")

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-no-ci", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_human_merge"
  end

  test "mark_ready still requires ci_waiting when package policy requires CI", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-CI-REQUIRED", kind: "mcp", status: "reviewing", policy_template: "mcp_ci_required")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    append_merge_ready_evidence(repo, session, package.id, "head-ci-required")

    reviewing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-ci-required-reviewing", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(reviewing_response, ["error", "data", "reason"]) == "readiness_failed"
    assert get_in(reviewing_response, ["error", "data", "missing"]) == ["status_ci_waiting"]

    transition_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "ci-required-transition",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"expected_status" => "reviewing", "status" => "ci_waiting"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(transition_response, ["result", "structuredContent", "work_package", "status"]) == "ci_waiting"

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-ci-required", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_human_merge"
  end

  test "state machine blocks ready transitions from reviewing when package policy requires CI", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-CI-STATE-MACHINE", kind: "mcp", status: "reviewing", policy_template: "mcp_ci_required")
             )

    actor = %{grant_role: "worker", capabilities: ["worker:lifecycle.transition"], work_package_id: package.id}

    assert {:error, :invalid_transition} =
             StateMachine.validate_ready_transition(package, "ready_for_human_merge", actor)

    ci_waiting_package = %{package | status: "ci_waiting"}
    assert :ok = StateMachine.validate_ready_transition(ci_waiting_package, "ready_for_human_merge", actor)
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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

    assert get_in(missing_session_response, ["error", "data", "reason"]) == "claim_required"

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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
              "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
    move_latest_attach_pr_created_at_before_prior_sync(repo, package.id)

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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
        "summary" => "normal is green",
        "status" => "passed",
        "verdict" => "green",
        "lane" => "normal",
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    attach_tool(repo, session, "attach_review_suite_result", %{
      "work_package_id" => package.id,
      "head_sha" => head_sha,
      "suite" => "review-suite",
      "anchor" => "phase_gate-scope-head-a",
      "summary" => "normal is green",
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    attach_tool(repo, session, "attach_review_suite_result", %{
      "work_package_id" => package.id,
      "head_sha" => head_sha,
      "suite" => "review-suite",
      "anchor" => "phase_gate-scope-docs-head-a",
      "summary" => "normal is green",
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
    assert get_in(non_passing_response, ["error", "data", "expected_verdicts"]) == ["green", "clean", "passed", "pass", "success", "approved"]

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

  test "review evidence accepts clean vocabulary and promotes stale package status to reviewing", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-PROMOTE", kind: "mcp", status: "ready_for_worker")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-PROMOTE/worker", "head_sha" => "review-head-a"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Review package is ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "review-head-a",
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    assert {:ok, promoted_after_review_package} = WorkPackageRepository.get(repo, package.id)
    assert promoted_after_review_package.status == "reviewing"

    assert {:ok, suite_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-CLEAN", kind: "mcp", status: "ready_for_worker")
             )

    assert {:ok, suite_minted} = AccessGrantService.mint_worker_grant(repo, suite_package.id)
    assert {:ok, suite_assignment} = AccessGrantService.claim(repo, suite_minted.work_key.secret, claimed_by: "worker-2")
    suite_session = MCPHarness.session(suite_assignment, proof_hash: suite_minted.grant.secret_hash)

    attach_tool(repo, suite_session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-CLEAN/worker", "head_sha" => "suite-head-clean"})

    suite_response =
      attach_tool(repo, suite_session, "attach_review_suite_result", %{
        "work_package_id" => suite_package.id,
        "head_sha" => "suite-head-clean",
        "suite" => "review-suite",
        "anchor" => "review-suite-clean",
        "summary" => "Review completed cleanly",
        "status" => "completed",
        "verdict" => "clean"
      })

    assert get_in(suite_response, ["result", "structuredContent", "progress_event", "payload", "status"]) == "completed"
    assert get_in(suite_response, ["result", "structuredContent", "progress_event", "payload", "verdict"]) == "clean"

    assert {:ok, promoted_after_suite} = WorkPackageRepository.get(repo, suite_package.id)
    assert promoted_after_suite.status == "reviewing"
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
      "lane" => "normal",
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      "payload" => %{"lane" => "brief", "verdict" => "green"},
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
      "summary" => "brief review green",
      "status" => "review_brief_green",
      "idempotency_key" => "quick-fix-review-brief"
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
      "summary" => "brief review green for latest head",
      "status" => "review_brief_green",
      "idempotency_key" => "quick-fix-review-brief-head-b"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests failed after latest pass",
      "status" => "tests_failed",
      "idempotency_key" => "quick-fix-tests-head-b-failed"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "brief review red after latest green",
      "status" => "review_brief_red",
      "idempotency_key" => "quick-fix-review-brief-head-b-red"
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
      "summary" => "brief review green after red",
      "status" => "review_brief_green",
      "idempotency_key" => "quick-fix-review-brief-head-b-regreen"
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

  test "docs mark_ready uses docs gates without investigation recommendation artifacts", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-DOCS", kind: "docs", status: "reviewing"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "docs-worker")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-docs-missing", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(missing_response, ["error", "data", "missing"])
    assert get_in(missing_response, ["error", "data", "reason"]) == "readiness_failed"
    assert "tests_passed" in missing
    assert "review_lanes_complete" in missing
    refute "findings_documented" in missing
    refute "recommendation_artifact_recorded" in missing

    scope_response =
      attach_tool(repo, session, "request_scope_expansion", %{
        "summary" => "Docs scope note",
        "idempotency_key" => "docs-scope-note"
      })

    refute Map.has_key?(get_in(scope_response, ["result", "structuredContent", "progress_event", "payload"]), "recommendation_artifact_id")

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Docs validation passed",
      "status" => "tests_passed",
      "idempotency_key" => "docs-validation"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Docs brief review green",
      "status" => "review_brief_green",
      "idempotency_key" => "docs-review-brief"
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-docs", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "kind"]) == "docs"
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
      "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
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
      "reviews" => [%{"lane" => "emergency", "verdict" => "green"}]
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

    assert get_in(response, ["error", "data", "reason"]) == "claim_required"
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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

  defp tools_for_server(server) do
    %{"result" => %{"tools" => tools}} =
      Server.handle(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list", "params" => %{}}, server)

    tools
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

  defp move_latest_attach_pr_created_at_before_prior_sync(repo, work_package_id) do
    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, work_package_id)

    event =
      progress_events
      |> Enum.filter(fn event ->
        payload = event.payload || %{}
        payload["source_tool"] == "attach_pr" and payload["head_sha"] == "head-b"
      end)
      |> Enum.max_by(&(&1.sequence || 0))

    assert {1, nil} =
             repo.update_all(
               from(progress_event in ProgressEvent, where: progress_event.id == ^event.id),
               set: [created_at: ~U[2020-01-01 00:00:00Z]]
             )
  end

  defp append_done_plan(repo, work_package_id) do
    assert {:ok, _plan_node} =
             PlanningRepository.append_plan_node(repo, %{
               "work_package_id" => work_package_id,
               "title" => "Complete implementation",
               "status" => "done"
             })
  end

  defp append_merge_ready_evidence(repo, session, work_package_id, head_sha) do
    append_done_plan(repo, work_package_id)
    pr_url = "https://github.com/example/repo/pull/#{System.unique_integer([:positive])}"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/#{work_package_id}/worker", "head_sha" => head_sha})
    attach_tool(repo, session, "attach_pr", %{"url" => pr_url, "head_sha" => head_sha})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
      review_lanes: ["brief", "raw_secret_review_lane", "normal"],
      stop_conditions: ["Stop before mutation or dispatch wiring."]
    }

    Enum.into(overrides, defaults)
  end

  defp create_work_request_handoff_architect_session(repo, %WorkRequest{} = work_request, capabilities) do
    phase_id = ArchitectHandoff.phase_id_for_work_request(work_request)

    assert {:ok, _phase} =
             PhaseRepository.create(repo, %{
               id: phase_id,
               title: "Architect handoff for #{work_request.id}"
             })

    package_attrs =
      [
        id: ArchitectHandoff.anchor_id_for_work_request(work_request),
        kind: "delegation",
        title: "Architect handoff: #{work_request.title}",
        repo: work_request.repo,
        base_branch: work_request.base_branch,
        allowed_file_globs: ["elixir/lib", "elixir/lib/**"],
        phase_id: phase_id,
        status: "planning"
      ]
      |> WorkPackageFactory.attrs()

    assert {:ok, anchor} = WorkPackageRepository.create(repo, package_attrs)

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, phase_id,
               work_package_id: anchor.id,
               work_request_id: work_request.id,
               capabilities: capabilities
             )

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, minted.work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: minted.grant.secret_hash)
    assert {:ok, grant} = AccessGrantRepository.get(repo, minted.grant.id)

    {anchor, session, grant}
  end

  defp create_phase_architect_session(repo, work_package_id, capabilities, overrides \\ []) do
    phase_id = Keyword.get(overrides, :phase_id) || ensure_architect_phase(repo)

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

  defp grant_work_request_scope!(repo, %Session{} = session, work_request_id) do
    grant_scope!(repo, session, Scope.work_request(work_request_id), "work_request", work_request_id)
  end

  defp grant_planned_slice_scope!(repo, %Session{} = session, planned_slice_id) do
    grant_scope!(repo, session, Scope.planned_slice(planned_slice_id), "planned_slice", planned_slice_id)
  end

  defp grant_scope!(repo, %Session{} = session, %Scope{} = scope, scope_type, scope_id) do
    assert {:ok, grant} = AccessGrantRepository.get(repo, session.assignment.grant_id)

    attrs = GrantScope.attrs_from_scope(grant.id, scope)

    case repo.insert(GrantScope.create_changeset(attrs)) do
      {:ok, %GrantScope{}} -> :ok
      {:error, %Ecto.Changeset{} = changeset} -> assert_duplicate_grant_scope!(changeset)
    end

    assert {:ok, scope_rows} = AccessGrantRepository.list_scopes(repo, grant.id)
    assert Enum.any?(scope_rows, &(&1.scope_type == scope_type and &1.scope_id == scope_id))
  end

  defp remove_grant_scope_type!(repo, %Session{} = session, scope_type) do
    repo.delete_all(
      from(scope in GrantScope,
        where: scope.access_grant_id == ^session.assignment.grant_id,
        where: scope.scope_type == ^scope_type
      )
    )

    assert {:ok, scope_rows} = AccessGrantRepository.list_scopes(repo, session.assignment.grant_id)
    refute Enum.any?(scope_rows, &(&1.scope_type == scope_type))
  end

  defp assert_duplicate_grant_scope!(%Ecto.Changeset{} = changeset) do
    assert {"has already been taken", opts} = Keyword.fetch!(changeset.errors, :scope_key)
    assert Keyword.get(opts, :constraint) == :unique
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

  defp create_non_expiring_architect_session(repo, work_package_id, capabilities) do
    phase_id = ensure_architect_phase(repo)

    package_attrs =
      [
        id: work_package_id,
        kind: "mcp",
        base_branch: "symphony-plus-plus/beta",
        repo: "nextide/symphony-plus-plus",
        allowed_file_globs: ["elixir/lib/**"],
        status: "planning",
        phase_id: phase_id
      ]
      |> WorkPackageFactory.attrs()

    assert {:ok, package} = WorkPackageRepository.create(repo, package_attrs)

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, phase_id,
               work_package_id: package.id,
               capabilities: capabilities
             )

    assert minted.grant.expires_at == nil

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, minted.work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(minted.work_key.secret))
    {:ok, package} = WorkPackageRepository.get(repo, package.id)

    {package, session}
  end

  defp active_worker_grants(grants) do
    now = DateTime.utc_now(:microsecond)

    Enum.filter(grants, fn grant ->
      grant.grant_role == "worker" and is_nil(grant.revoked_at) and live_expires_at?(grant.expires_at, now)
    end)
  end

  defp live_expires_at?(nil, %DateTime{}), do: true
  defp live_expires_at?(%DateTime{} = expires_at, %DateTime{} = now), do: DateTime.compare(expires_at, now) == :gt

  defp rebuild_access_grants_with_not_null_expiry!(repo_or_pid) do
    query!(repo_or_pid, "PRAGMA foreign_keys = OFF")

    try do
      query!(repo_or_pid, "DROP TABLE IF EXISTS sympp_access_grants_legacy_expiry")

      query!(repo_or_pid, """
      CREATE TABLE sympp_access_grants_legacy_expiry (
        id TEXT PRIMARY KEY NOT NULL,
        work_package_id TEXT NOT NULL REFERENCES sympp_work_packages(id) ON DELETE CASCADE,
        display_key TEXT NOT NULL,
        secret_hash TEXT NOT NULL,
        grant_role TEXT NOT NULL,
        capabilities TEXT NOT NULL DEFAULT '[]',
        expires_at TEXT NOT NULL,
        revoked_at TEXT,
        claimed_at TEXT,
        claimed_by TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        phase_id TEXT REFERENCES sympp_phases(id) ON DELETE CASCADE,
        scope_repo TEXT,
        scope_base_branch TEXT,
        provenance TEXT
      )
      """)

      query!(repo_or_pid, """
      INSERT INTO sympp_access_grants_legacy_expiry (
        id,
        work_package_id,
        display_key,
        secret_hash,
        grant_role,
        capabilities,
        expires_at,
        revoked_at,
        claimed_at,
        claimed_by,
        inserted_at,
        updated_at,
        phase_id,
        scope_repo,
        scope_base_branch,
        provenance
      )
      SELECT
        id,
        work_package_id,
        display_key,
        secret_hash,
        grant_role,
        capabilities,
        expires_at,
        revoked_at,
        claimed_at,
        claimed_by,
        inserted_at,
        updated_at,
        phase_id,
        scope_repo,
        scope_base_branch,
        provenance
      FROM sympp_access_grants
      """)

      query!(repo_or_pid, "DROP TABLE sympp_access_grants")
      query!(repo_or_pid, "ALTER TABLE sympp_access_grants_legacy_expiry RENAME TO sympp_access_grants")
      recreate_access_grant_indexes!(repo_or_pid)
    after
      query!(repo_or_pid, "PRAGMA foreign_keys = ON")
    end
  end

  defp recreate_access_grant_indexes!(repo_or_pid) do
    query!(repo_or_pid, "CREATE UNIQUE INDEX sympp_access_grants_id_unique_index ON sympp_access_grants (id)")
    query!(repo_or_pid, "CREATE UNIQUE INDEX sympp_access_grants_secret_hash_unique_index ON sympp_access_grants (secret_hash)")
    query!(repo_or_pid, "CREATE INDEX sympp_access_grants_work_package_id_index ON sympp_access_grants (work_package_id)")
    query!(repo_or_pid, "CREATE INDEX sympp_access_grants_display_key_index ON sympp_access_grants (display_key)")
    query!(repo_or_pid, "CREATE INDEX sympp_access_grants_grant_role_index ON sympp_access_grants (grant_role)")
    query!(repo_or_pid, "CREATE INDEX sympp_access_grants_phase_id_index ON sympp_access_grants (phase_id)")
  end

  defp remove_null_expiry_migration_version!(repo_or_pid) do
    query!(repo_or_pid, "DELETE FROM schema_migrations WHERE version = ?", [20_260_519_120_000])
  end

  defp access_grant_expiry_not_null?(repo_or_pid) do
    %{rows: rows} = query!(repo_or_pid, "PRAGMA table_info(sympp_access_grants)")

    Enum.any?(rows, fn
      [_cid, "expires_at", _type, not_null, _default_value, _primary_key] -> not_null in [1, true]
      _column -> false
    end)
  end

  defp schema_migration_recorded?(repo_or_pid, version) do
    %{rows: [[count]]} = query!(repo_or_pid, "SELECT COUNT(*) FROM schema_migrations WHERE version = ?", [version])
    count == 1
  end

  defp query!(repo_or_pid, sql, params \\ []) do
    SQL.query!(repo_or_pid, sql, params, log: false)
  end

  defp mcp_tool(repo, session, name, arguments, opts \\ []) do
    MCPHarness.request(
      %{
        "jsonrpc" => "2.0",
        "id" => name,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      },
      config: Keyword.get(opts, :config, test_mcp_config(repo)),
      session: session
    )
  end

  defp test_mcp_config(repo), do: Config.default(repo: repo, repo_root: test_repo_root())

  defp local_mcp_config(repo), do: Config.default(repo: repo, mode: :http, repo_root: test_repo_root(), local_daemon_trusted: true)

  defp local_mcp_server(%Config{} = config, state_key) do
    Server.new(config, initialized: true, local_daemon_trusted: true, state_key: state_key)
  end

  defp create_local_claim_package!(repo, id, overrides \\ []) do
    attrs =
      [
        id: id,
        kind: "mcp",
        repo: "nextide/symphony-plus-plus",
        base_branch: "feature/sympp-v21-ledger-claims",
        branch_pattern: "agent/#{id}/worker",
        worktree_path: local_claim_worktree_path(id),
        status: "ready_for_worker"
      ]
      |> Keyword.merge(overrides)
      |> WorkPackageFactory.attrs()

    assert {:ok, package} = WorkPackageRepository.create(repo, attrs)
    package
  end

  defp local_assignment_claim_args(%WorkPackage{} = package, overrides \\ %{}) do
    %{
      "repo" => package.repo,
      "base_branch" => package.base_branch,
      "work_package_id" => package.id,
      "branch" => package.branch_pattern,
      "worktree_path" => package.worktree_path,
      "caller_id" => "codex-local-test",
      "claimed_by" => "local-worker-1"
    }
    |> Map.merge(overrides)
  end

  defp local_assignment_claim_actor(arguments) do
    worktree_path = local_assignment_actor_worktree_path(arguments["worktree_path"])

    owner_material =
      [
        arguments["repo"],
        arguments["base_branch"],
        arguments["work_package_id"],
        arguments["branch"],
        worktree_path,
        arguments["claimed_by"]
      ]
      |> Enum.join("\0")

    material =
      [
        arguments["repo"],
        arguments["base_branch"],
        arguments["work_package_id"],
        arguments["branch"],
        worktree_path,
        arguments["caller_id"],
        arguments["claimed_by"]
      ]
      |> Enum.join("\0")

    %{
      "actor_kind" => "agent",
      "actor_id" => "local:" <> local_assignment_actor_hash(owner_material) <> ":" <> local_assignment_actor_hash(material),
      "actor_display_name" => arguments["claimed_by"]
    }
  end

  defp local_assignment_actor_worktree_path(path) do
    path = path |> String.trim() |> Path.expand()

    case :os.type() do
      {:win32, _name} -> String.downcase(path)
      _type -> path
    end
  end

  defp local_assignment_actor_hash(material) do
    Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp local_claim_worktree_path(work_package_id) do
    Path.expand(Path.join(System.tmp_dir!(), "sympp-local-claim-#{work_package_id}"))
  end

  defp test_repo_root do
    Path.expand("../../../..", __DIR__)
  end

  defp set_relative_owner_origin!(fixture, owner_repo) do
    relative_origin = "#{owner_repo}.git"
    local_origin = Path.join(fixture.repo_root, relative_origin)

    File.mkdir_p!(Path.dirname(local_origin))
    TestSupport.git_output!(fixture.root, ["clone", "--bare", fixture.origin, local_origin])
    TestSupport.git_output!(fixture.repo_root, ["remote", "set-url", "origin", relative_origin])

    fixture
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

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
    "auto"
  end

  defp test_handoff_store_dir do
    case Process.get(@handoff_store_process_key) do
      nil -> raise "MCP test handoff store directory was not initialized"
      store_dir -> store_dir
    end
  end

  defp unique_test_handoff_store_dir do
    System.tmp_dir!()
    |> Path.join("sympp-mcp-test-worker-secrets-#{System.unique_integer([:positive])}")
    |> Path.expand()
  end

  defp temporary_worker_repo_root(name) do
    repo_root = Path.join(System.tmp_dir!(), "sympp-mcp-#{name}-#{System.unique_integer([:positive])}")
    script_path = Path.join([repo_root, "scripts", local_private_file_script_name()])

    File.mkdir_p!(Path.dirname(script_path))
    File.write!(script_path, "# synthetic worker bootstrap wrapper\n")

    repo_root
  end

  defp local_private_file_script_name do
    if windows?(), do: "sympp-worker-secret.ps1", else: "sympp-worker-secret.sh"
  end

  defp comparable_path(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
    |> then(fn path -> if windows?(), do: String.downcase(path), else: path end)
  end

  defp solo_workspace_path(name) do
    path = Path.join(System.tmp_dir!(), "sympp-mcp-solo-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp test_dispatch_handoff_store_dir do
    test_handoff_store_dir()
    |> Path.join("dispatch-#{System.unique_integer([:positive])}")
  end

  defp test_handoff_opts(claimed_by, store_dir \\ test_handoff_store_dir()) do
    [
      repo_root: test_repo_root(),
      claimed_by: claimed_by,
      mode: test_secret_handoff_mode(),
      store_dir: store_dir
    ]
  end

  defp sqlite_file_uri(path, query) do
    encoded_path =
      path
      |> String.replace("\\", "/")
      |> URI.encode(&sqlite_file_uri_path_char?/1)

    "file:#{encoded_path}?#{query}"
  end

  defp assert_same_ledger_database(%{"database" => actual_database}, expected_path, expected_query \\ nil) do
    actual_path =
      case Repo.sqlite_file_uri_path(actual_database) do
        path when is_binary(path) and path != "" -> path
        _path -> actual_database
      end

    assert Repo.same_database_path?(actual_path, expected_path)

    if expected_query do
      assert actual_database =~ "?#{expected_query}"
    end
  end

  defp sqlite_file_uri_path_char?(char), do: URI.char_unreserved?(char) or char in [?/, ?:]

  defp current_main_database_path(repo) do
    assert {:ok, %{rows: rows}} = SQL.query(repo, "PRAGMA database_list", [], log: false)

    case Enum.find(rows, &main_database_row?/1) do
      [_seq, "main", path] when is_binary(path) and path != "" -> path
      row -> flunk("expected file-backed test ledger for external MCP bootstrap, got: #{inspect(row)}")
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

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
    powershell = powershell_executable()
    assert is_binary(powershell), "Windows Credential Manager MCP bootstrap test requires powershell.exe or pwsh"
    powershell
  end

  defp powershell_executable do
    Enum.find_value(["powershell.exe", "powershell", "pwsh"], &System.find_executable/1)
  end

  defp windows_credential_manager_writable? do
    with true <- windows?(),
         powershell when is_binary(powershell) <- powershell_executable() do
      target = "SymphonyPlusPlus:test:wcm-probe:#{System.unique_integer([:positive])}"
      script_path = Path.join(test_repo_root(), "scripts/sympp-worker-secret.ps1")

      try do
        case System.cmd(
               powershell,
               [
                 "-NoProfile",
                 "-ExecutionPolicy",
                 "Bypass",
                 "-File",
                 script_path,
                 "store",
                 "-Target",
                 target,
                 "-UserName",
                 "sympp-wcm-probe"
               ],
               env: [{"SYMPP_WORK_KEY_SECRET", "synthetic-wcm-probe-secret"}],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> true
          {_output, _status} -> false
        end
      after
        SecretHandoff.delete_worker_secret(%{"mode" => "windows-credential-manager", "target" => target}, repo_root: test_repo_root())
      end
    else
      _unavailable -> false
    end
  rescue
    _error -> false
  end

  defp windows_credential_manager_integration_enabled? do
    System.get_env("SYMPP_RUN_WCM_INTEGRATION") in ["1", "true", "TRUE"] and
      windows_credential_manager_writable?()
  end

  defp cleanup_test_child_worker_handoffs(repo, store_dir) do
    grants =
      repo.all(
        from(grant in AccessGrant,
          where: grant.provenance == ^@child_worker_grant_provenance
        )
      )

    Enum.each(grants, fn grant ->
      with {:ok, work_package} <- WorkPackageRepository.get(repo, grant.work_package_id) do
        SecretHandoff.delete_worker_secret_by_grant(work_package, grant, test_handoff_opts("worker-1", store_dir))
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
    assert {:ok, session} = Auth.session_from_grant(repo, grant, proof_hash: grant.secret_hash)
    session
  end

  defp cleanup_child_worker_handoff(handoff, claimed_by) do
    assert :ok = SecretHandoff.delete_worker_secret(handoff, test_handoff_opts(claimed_by))
  end

  defp json_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
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
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
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
