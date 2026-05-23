defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Server do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Client, DryClient, PullRequest, PullRequestArtifact}
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Service, as: GuidanceRequestService
  alias SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Auth, Config, Repository, Session}
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer, as: PlanningRenderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.ReviewProfiles
  alias SymphonyElixir.SymphonyPlusPlus.SecretHandoff
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository, as: SoloSessionRepository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service, as: SoloSessionService
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDispatch
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service, as: WorkPackageService

  @protocol_version "2025-03-26"
  @health_tool "sympp.health"
  @solo_tools ["solo_attach", "solo_append", "solo_show", "solo_list", "solo_update_status"]
  @bootstrap_tools ["claim_private_handoff", "create_work_request"]
  @session_claim_tools ["claim_work_key", "claim_private_handoff"]
  @private_handoff_claim_keys [
    "mode",
    "path",
    "target",
    "grant_id",
    "display_key",
    "work_package_id",
    "database",
    "namespace_repo_root"
  ]
  @solo_show_entry_limit 50
  @worker_tools [
    "claim_work_key",
    "get_current_assignment",
    "read_context",
    "read_task_plan",
    "update_task_plan",
    "append_finding",
    "append_progress",
    "set_status",
    "report_blocker",
    "resolve_blocker",
    "create_guidance_request",
    "read_guidance_request",
    "request_scope_expansion",
    "attach_branch",
    "attach_pr",
    "sync_pr",
    "submit_review_package",
    "attach_review_suite_result",
    "mark_ready"
  ]
  @architect_tools [
    "create_child_work_package",
    "mint_child_worker_key",
    "revoke_child_worker_key",
    "list_work_requests",
    "read_work_request",
    "list_guidance_requests",
    "read_guidance_request",
    "answer_guidance_request",
    "escalate_guidance_request",
    "set_work_request_status",
    "ask_work_request_question",
    "answer_work_request_question",
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
  @phase7_stub_architect_tools [
    "request_child_replan",
    "split_work_package",
    "publish_phase_update"
  ]
  @child_work_package_keys [
    "acceptance_criteria",
    "allowed_file_globs",
    "base_branch",
    "branch_pattern",
    "engineering_scope",
    "id",
    "kind",
    "owner_id",
    "parent_id",
    "phase_id",
    "policy_template",
    "product_description",
    "repo",
    "status",
    "title"
  ]
  @child_worker_template_keys ["capabilities", "expires_at", "secret_handoff"]
  @child_worker_secret_handoff_keys ["claimed_by", "mode", "store_dir"]
  @child_worker_secret_handoff_payload_keys [
    :claimed_by,
    :claimed_by_required,
    :display_key,
    :env_var,
    :mode,
    :namespace_repo_root,
    :path,
    :run_mcp_command,
    :secret_in_stdout,
    :status,
    :store,
    :target,
    :work_package_id
  ]
  @child_worker_capabilities ["worker:claim", "worker:lifecycle.transition"]
  @child_worker_ready_status "ready_for_worker"
  @child_worker_resettable_statuses ["claimed", "planning", "implementing", "reviewing", "ci_waiting", "blocked"]
  @child_worker_recyclable_statuses [@child_worker_ready_status | @child_worker_resettable_statuses]
  @child_worker_grant_provenance "child_worker_delegation"
  @version_resource "sympp://health/version"
  @assignment_resource "sympp://assignment/current"
  @finding_replay_retry_attempts 50
  @handle_state_ttl_ms 86_400_000
  @explicit_handle_state_ttl_ms 604_800_000
  @handle_state_agent Module.concat(__MODULE__, HandleState)
  @scope_guard_gate "scope_guard"
  @plan_append_argument_keys ["body", "expected_version", "id", "status", "title", "work_package_id"]
  @plan_patch_argument_keys ["expected_version", "patch", "work_package_id"]
  @plan_node_patch_keys ["body", "id", "status", "title"]

  @enforce_keys [:config]
  defstruct [
    :config,
    :session,
    :state_key,
    :state_key_version,
    state_key_explicit: false,
    session_refresh_required: false,
    initialized: false
  ]

  @type t :: %__MODULE__{
          config: Config.t(),
          session: Session.t() | nil,
          state_key: term(),
          state_key_version: integer() | nil,
          state_key_explicit: boolean(),
          session_refresh_required: boolean(),
          initialized: boolean()
        }

  defguardp valid_request_id(id) when is_binary(id) or is_number(id) or is_nil(id)
  defguardp invalid_request_id(id) when not is_binary(id) and not is_number(id) and not is_nil(id)

  @spec new(Config.t(), keyword()) :: t()
  def new(%Config{} = config, opts \\ []) do
    {state_key, state_key_explicit?} = state_key_option(opts)

    %__MODULE__{
      config: config,
      session: Keyword.get(opts, :session),
      state_key: state_key,
      state_key_version: nil,
      state_key_explicit: state_key_explicit?,
      session_refresh_required: false,
      initialized: Keyword.get(opts, :initialized, false)
    }
  end

  defp state_key_option(opts) do
    case Keyword.fetch(opts, :state_key) do
      {:ok, state_key} -> explicit_state_key_option(state_key)
      :error -> {make_ref(), false}
    end
  end

  defp explicit_state_key_option(nil), do: {make_ref(), false}

  defp explicit_state_key_option(state_key) when is_binary(state_key) do
    if String.trim(state_key) == "", do: {make_ref(), false}, else: {state_key, true}
  end

  defp explicit_state_key_option(state_key), do: {state_key, true}

  @spec handle(term(), t()) :: map() | [map()] | nil
  def handle(payload, %__MODULE__{} = server) do
    payload
    |> handle_response_state(server)
    |> elem(0)
  end

  @doc false
  @spec handle_response_state(term(), t()) :: {map() | [map()] | nil, t()}
  def handle_response_state(payload, %__MODULE__{} = server) do
    cleanup_default_handle_states()
    server = restore_handle_state(payload, server)
    {response, updated_server} = handle_state(payload, server)
    updated_server = persist_handle_state(payload, response, server, updated_server)
    {response, updated_server}
  end

  @spec handle_state(term(), t()) :: {map() | [map()] | nil, t()}
  def handle_state(%{"jsonrpc" => "2.0", "method" => "initialize"} = payload, %__MODULE__{} = server) do
    response = do_handle(payload, server)

    case response do
      %{"result" => _result} -> {response, %{server | initialized: true}}
      _response -> {response, server}
    end
  end

  def handle_state(payloads, %__MODULE__{} = server) when is_list(payloads) do
    cond do
      payloads == [] ->
        {error_response(nil, -32_600, "Invalid Request", %{"reason" => "empty_batch"}), server}

      Enum.any?(payloads, &initialize_request?/1) ->
        {error_response(nil, -32_600, "Invalid Request", %{"reason" => "initialize_must_be_standalone"}), server}

      true ->
        handle_batch(payloads, server)
    end
  end

  def handle_state(
        %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call"} = payload,
        %__MODULE__{initialized: true} = server
      )
      when valid_request_id(id) do
    case request_params(payload) do
      {:ok, %{"name" => name} = params} when name in @session_claim_tools ->
        handle_session_claim_tool(name, params, id, server)

      _params ->
        {do_handle(payload, server), server}
    end
  end

  def handle_state(%{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call"} = payload, %__MODULE__{initialized: true} = server)
      when invalid_request_id(id) do
    {do_handle(payload, server), server}
  end

  def handle_state(%{"jsonrpc" => "2.0", "method" => "tools/call"} = payload, %__MODULE__{initialized: true} = server) do
    case request_params(payload) do
      {:ok, %{"name" => name} = params} when name in @session_claim_tools ->
        handle_session_claim_tool_notification(name, params, server)

      params_result ->
        dispatch_notification(params_result, "tools/call", server)
        {nil, server}
    end
  end

  def handle_state(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = payload, %__MODULE__{initialized: true} = server)
      when is_binary(method) and valid_request_id(id) do
    payload
    |> request_params()
    |> dispatch_request_state(method, id, server)
  end

  def handle_state(payload, %__MODULE__{} = server), do: {do_handle(payload, server), server}

  defp restore_handle_state(payload, %__MODULE__{initialized: false, session: nil, state_key_explicit: true} = server) do
    if initialize_request?(payload) do
      server
    else
      restore_explicit_handle_state(server)
    end
  end

  defp restore_handle_state(payload, %__MODULE__{state_key_explicit: true} = server) do
    if initialize_request?(payload) do
      if server.initialized do
        # Duplicate initialize on a reused explicit MCP server must not silently
        # downgrade a stale bound identity into generic unbound discovery. The
        # recovery paths are an explicit re-claim on this session or a new MCP
        # process/session that starts from the fresh unbound surface.
        restore_explicit_handle_state(server)
      else
        %{server | initialized: false, session: nil}
      end
    else
      restore_explicit_handle_state(server)
    end
  end

  defp restore_handle_state(payload, %__MODULE__{state_key_explicit: false} = server) do
    if initialize_request?(payload) do
      case {server.initialized, lookup_handle_state(server)} do
        {true, _stored} ->
          server

        {false, {%__MODULE__{}, _timestamp_ms, _explicit?}} ->
          delete_handle_state(server)
          %{server | initialized: false, session: nil}

        _stored ->
          server
      end
    else
      restore_handle_state(server)
    end
  end

  defp restore_handle_state(_payload, %__MODULE__{} = server), do: restore_handle_state(server)

  defp restore_explicit_handle_state(%__MODULE__{} = server) do
    case lookup_handle_state(server) do
      {%__MODULE__{} = stored, timestamp_ms, _explicit?} ->
        state_key_version = stored.state_key_version || timestamp_ms

        session_refresh_required? =
          stored.session_refresh_required or stale_explicit_session?(server, state_key_version)

        session = if session_refresh_required?, do: nil, else: server.session

        %{
          server
          | initialized: server.initialized or stored.initialized,
            session: session,
            state_key_version: state_key_version,
            session_refresh_required: session_refresh_required?
        }

      _stored ->
        server
    end
  end

  defp restore_handle_state(%__MODULE__{} = server) do
    case lookup_handle_state(server) do
      {%__MODULE__{} = stored, _timestamp_ms, _explicit?} ->
        %{server | initialized: server.initialized or stored.initialized, session: server.session || stored.session}

      _stored ->
        server
    end
  end

  defp stale_explicit_session?(%__MODULE__{session_refresh_required: true, state_key_version: version}, timestamp_ms)
       when version == timestamp_ms,
       do: true

  defp stale_explicit_session?(%__MODULE__{session: nil}, _timestamp_ms), do: false
  defp stale_explicit_session?(%__MODULE__{state_key_version: nil}, _timestamp_ms), do: true
  defp stale_explicit_session?(%__MODULE__{state_key_version: state_key_version}, timestamp_ms), do: timestamp_ms > state_key_version

  defp persist_handle_state(payload, response, %__MODULE__{state_key_explicit: true} = server, %__MODULE__{} = updated_server) do
    if initialize_request?(payload) do
      case response do
        %{"result" => _result} ->
          timestamp_ms = put_handle_state(updated_server)
          %{updated_server | state_key_version: timestamp_ms}

        %{"error" => %{"data" => %{"reason" => "already_initialized"}}} ->
          updated_server

        _response ->
          invalidate_explicit_handle_state(server)
          %{updated_server | state_key_version: nil}
      end
    else
      persist_handle_state(server, updated_server)
    end
  end

  defp persist_handle_state(_payload, _response, %__MODULE__{} = server, %__MODULE__{} = updated_server) do
    persist_handle_state(server, updated_server)
  end

  defp persist_handle_state(%__MODULE__{} = server, %__MODULE__{} = updated_server) do
    timestamp_ms =
      cond do
        updated_server.session_refresh_required ->
          put_handle_state(updated_server)

        server.initialized != updated_server.initialized or server.session != updated_server.session ->
          put_handle_state(updated_server)

        lookup_handle_state(updated_server) != nil ->
          refresh_handle_state(updated_server)

        true ->
          nil
      end

    if is_integer(timestamp_ms), do: %{updated_server | state_key_version: timestamp_ms}, else: updated_server
  end

  defp put_handle_state(%__MODULE__{} = server) do
    key = handle_state_store_key(server)
    timestamp_ms = monotonic_ms()
    state_key_version = monotonic_state_key_version()
    stored_server = %{stored_handle_state_server(server) | state_key_version: state_key_version}
    update_handle_state_store(&Map.put(&1, key, {stored_server, timestamp_ms, server.state_key_explicit}))
    state_key_version
  end

  defp delete_handle_state(%__MODULE__{} = server) do
    key = handle_state_store_key(server)
    update_handle_state_store(&Map.delete(&1, key))
    :ok
  end

  defp invalidate_explicit_handle_state(%__MODULE__{} = server) do
    key = handle_state_store_key(server)
    timestamp_ms = monotonic_ms()
    state_key_version = monotonic_state_key_version()

    tombstone = %{
      stored_handle_state_server(server)
      | initialized: false,
        session: nil,
        state_key_version: state_key_version
    }

    update_handle_state_store(&Map.put(&1, key, {tombstone, timestamp_ms, true}))
    :ok
  end

  defp stored_handle_state_server(%__MODULE__{state_key_explicit: true} = server), do: %{server | session: nil}
  defp stored_handle_state_server(%__MODULE__{} = server), do: server

  defp lookup_handle_state(%__MODULE__{} = server) do
    handle_state_store()
    |> Map.get(handle_state_store_key(server))
  end

  defp refresh_handle_state(%__MODULE__{} = server) do
    case lookup_handle_state(server) do
      {%__MODULE__{} = stored_server, _timestamp_ms, _explicit?} -> put_handle_state(stored_server)
      _state -> nil
    end
  end

  defp cleanup_default_handle_states do
    now = monotonic_ms()

    update_handle_state_store(fn store ->
      store
      |> Map.reject(fn
        {_state_key, {%__MODULE__{}, timestamp_ms, false}} ->
          now - timestamp_ms > @handle_state_ttl_ms

        {_state_key, {%__MODULE__{}, timestamp_ms, true}} ->
          now - timestamp_ms > @explicit_handle_state_ttl_ms

        _entry ->
          false
      end)
    end)

    :ok
  end

  defp monotonic_state_key_version, do: System.unique_integer([:monotonic, :positive])

  defp update_handle_state_store(fun) do
    ensure_handle_state_agent()
    Agent.update(@handle_state_agent, fun)
  end

  defp handle_state_store do
    ensure_handle_state_agent()
    Agent.get(@handle_state_agent, & &1)
  end

  defp ensure_handle_state_agent do
    case Process.whereis(@handle_state_agent) do
      nil ->
        case Agent.start_link(fn -> %{} end, name: @handle_state_agent) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp handle_state_store_key(%__MODULE__{} = server), do: {handle_state_namespace(server.config), server.state_key}
  defp handle_state_namespace(%Config{} = config), do: {config.mode, ledger_namespace(config)}

  defp ledger_namespace(%Config{repo: repo, database: database}) do
    case current_ledger_identity(repo, database) do
      {:ok, identity} -> identity
      :error -> {:configured_database, repo_database_key(repo, database)}
    end
  end

  defp current_ledger_identity(repo, database) do
    case repo_query(repo, "PRAGMA database_list", [], log: false) do
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

  defp repo_query(repo, sql, params, opts) when is_atom(repo) do
    cond do
      repo_module_query?(repo) ->
        repo.query(sql, params, opts)

      true ->
        case dynamic_repo_identity(repo) do
          pid when is_pid(pid) -> SQL.query(pid, sql, params, opts)
          dynamic_repo when is_atom(dynamic_repo) and dynamic_repo != repo -> SQL.query(dynamic_repo, sql, params, opts)
          _repo -> SQL.query(repo, sql, params, opts)
        end
    end
  end

  defp repo_query(repo, sql, params, opts), do: SQL.query(repo, sql, params, opts)

  defp repo_module_query?(repo) do
    case Code.ensure_loaded(repo) do
      {:module, _module} -> function_exported?(repo, :query, 3)
      {:error, _reason} -> false
    end
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
    case dynamic_repo_identity(repo) do
      nil -> {:repo, repo}
      dynamic_repo -> {:dynamic_repo, dynamic_repo}
    end
  end

  defp blank_database_identity(repo), do: {:repo, repo}

  defp dynamic_repo_identity(repo) when is_atom(repo) do
    if function_exported?(repo, :get_dynamic_repo, 0), do: repo.get_dynamic_repo(), else: nil
  end

  defp repo_database_key(repo, database) when is_atom(repo) do
    if function_exported?(repo, :database_key, 1), do: repo.database_key(database), else: database
  end

  defp repo_database_key(_repo, database), do: database

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp do_handle([], %__MODULE__{}) do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "empty_batch"})
  end

  defp do_handle(payloads, %__MODULE__{} = server) when is_list(payloads) do
    if Enum.any?(payloads, &initialize_request?/1) do
      error_response(nil, -32_600, "Invalid Request", %{"reason" => "initialize_must_be_standalone"})
    else
      handle_batch(payloads, server)
      |> elem(0)
    end
  end

  defp do_handle(%{"id" => id}, %__MODULE__{}) when invalid_request_id(id) do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id}, %__MODULE__{}) when invalid_request_id(id) do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => method}, %__MODULE__{initialized: false})
       when is_binary(method) and method != "initialize" and valid_request_id(id) do
    error_response(id, -32_000, "Server error", %{"reason" => "server_not_initialized"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => "initialize"}, %__MODULE__{initialized: true})
       when valid_request_id(id) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "already_initialized"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => method} = request, %__MODULE__{} = server)
       when is_binary(method) and valid_request_id(id) do
    request
    |> request_params()
    |> dispatch_request(method, id, server)
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => _id, "method" => method}, %__MODULE__{}) when is_binary(method) do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id, "method" => _method}, %__MODULE__{}) when valid_request_id(id) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "invalid_method"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "method" => "initialize"}, %__MODULE__{}) do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "initialize_requires_id"})
  end

  defp do_handle(%{"jsonrpc" => "2.0", "method" => method} = notification, %__MODULE__{}) when is_binary(method) do
    if Map.has_key?(notification, "id") do
      error_response(nil, -32_600, "Invalid Request", %{"reason" => "invalid_request_id"})
    end
  end

  defp do_handle(%{"jsonrpc" => "2.0", "id" => id}, %__MODULE__{}) when valid_request_id(id) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "missing_method"})
  end

  defp do_handle(%{"jsonrpc" => version, "id" => id}, %__MODULE__{}) when version != "2.0" and valid_request_id(id) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "invalid_jsonrpc_version"})
  end

  defp do_handle(%{"jsonrpc" => version}, %__MODULE__{}) when version != "2.0" do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "invalid_jsonrpc_version"})
  end

  defp do_handle(%{"id" => id, "method" => method}, %__MODULE__{}) when is_binary(method) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "invalid_jsonrpc_version"})
  end

  defp do_handle(%{"id" => id, "method" => _method}, %__MODULE__{}) when valid_request_id(id) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "invalid_method"})
  end

  defp do_handle(%{"id" => id}, %__MODULE__{}) do
    error_response(id, -32_600, "Invalid Request", %{"reason" => "missing_method"})
  end

  defp do_handle(_payload, %__MODULE__{}) do
    error_response(nil, -32_600, "Invalid Request", %{"reason" => "request_must_be_object"})
  end

  defp handle_batch(payloads, %__MODULE__{} = server) do
    {items, _claimed?} =
      Enum.map_reduce(payloads, false, fn payload, claimed? ->
        if claimed? and batch_claim_work_key_request?(payload, server) do
          {{payload, batch_claim_work_key_rebind_item(payload, server)}, true}
        else
          item = handle_batch_item(payload, server)

          claim_succeeded? =
            batch_claim_work_key_request?(payload, server) and batch_claim_work_key_success?(item, server)

          {{payload, item}, claimed? or claim_succeeded?}
        end
      end)

    responses =
      items
      |> Enum.map(fn {_payload, {response, _server}} -> response end)
      |> Enum.reject(&is_nil/1)

    updated_server = batch_updated_server(items, server)

    {if(responses == [], do: nil, else: responses), updated_server}
  end

  defp batch_updated_server(items, %__MODULE__{} = server) do
    Enum.reduce(items, server, fn
      {_payload, {%{"error" => _error}, %__MODULE__{} = _updated_server}}, server ->
        server

      {payload, {_response, %__MODULE__{session: %Session{}} = updated_server}}, server ->
        if batch_claim_work_key_request?(payload, server), do: updated_server, else: server

      _item, server ->
        server
    end)
  end

  defp batch_claim_work_key_success?(
         {%{"result" => %{"structuredContent" => %{"assignment" => _assignment}}}, %__MODULE__{}},
         %__MODULE__{}
       ),
       do: true

  defp batch_claim_work_key_success?({nil, %__MODULE__{session: %Session{} = updated_session}}, %__MODULE__{session: original_session}) do
    original_session == nil or updated_session != original_session
  end

  defp batch_claim_work_key_success?(_item, %__MODULE__{}), do: false

  defp batch_claim_work_key_request?(
         %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => name}},
         %__MODULE__{initialized: true}
       )
       when name in @session_claim_tools and valid_request_id(id),
       do: true

  defp batch_claim_work_key_request?(%{"jsonrpc" => "2.0", "id" => _id, "method" => "tools/call"}, %__MODULE__{initialized: true}),
    do: false

  defp batch_claim_work_key_request?(
         %{"jsonrpc" => "2.0", "method" => "tools/call", "params" => %{"name" => name}},
         %__MODULE__{initialized: true}
       )
       when name in @session_claim_tools,
       do: true

  defp batch_claim_work_key_request?(_payload, %__MODULE__{}), do: false

  defp batch_claim_work_key_rebind_item(%{"id" => id, "params" => %{"name" => name}}, %__MODULE__{} = server)
       when valid_request_id(id) and name in @session_claim_tools do
    {error_response(id, -32_001, "Unauthorized", %{"tool" => name, "reason" => "session_already_bound"}), server}
  end

  defp batch_claim_work_key_rebind_item(_payload, %__MODULE__{} = server), do: {nil, server}

  defp dispatch(
         "initialize",
         %{"protocolVersion" => protocol_version, "clientInfo" => client_info, "capabilities" => capabilities},
         %__MODULE__{config: config}
       )
       when is_binary(protocol_version) and is_map(client_info) and is_map(capabilities) do
    {:ok,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{
         "tools" => %{},
         "resources" => %{}
       },
       "serverInfo" => %{
         "name" => "symphony-plus-plus",
         "version" => config.version
       }
     }}
  end

  defp dispatch(
         "initialize",
         %{"protocolVersion" => protocol_version, "clientInfo" => client_info, "capabilities" => capabilities},
         _server
       )
       when is_binary(protocol_version) and (not is_map(client_info) or not is_map(capabilities)) do
    {:error, -32_602, "Invalid params", %{"reason" => "invalid_initialize_params"}}
  end

  defp dispatch("initialize", %{"protocolVersion" => protocol_version}, _server) when is_binary(protocol_version) do
    {:error, -32_602, "Invalid params", %{"reason" => "invalid_initialize_params"}}
  end

  defp dispatch("initialize", params, _server) when not is_map(params) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("initialize", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "missing_protocol_version", "supported" => @protocol_version}}
  end

  defp dispatch("tools/list", params, %__MODULE__{} = server) when is_map(params) do
    case tool_specs_for_server(server) do
      {:ok, tools} -> {:ok, %{"tools" => tools}}
      {:error, reason} -> worker_error(reason, "tools/list")
    end
  end

  defp dispatch("tools/list", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("tools/call", %{"name" => @health_tool} = params, %__MODULE__{} = server) do
    case Map.get(params, "arguments", %{}) do
      arguments when arguments == %{} ->
        result = health(server)

        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => Jason.encode!(result)}],
           "structuredContent" => result,
           "isError" => false
         }}

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => @health_tool, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @solo_tools do
    with :ok <- authorize_solo_tool_call(server, name),
         {:ok, arguments} <- solo_tool_arguments(params, name) do
      solo_tool(name, arguments, server)
    else
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => "claim_work_key"} = params, %__MODULE__{} = server) do
    with {:ok, _arguments} <- worker_tool_arguments(params, "claim_work_key"),
         {:ok, result, session} <- claim_work_key(params, server) do
      {:ok, tool_result(result), %{server | session: session, session_refresh_required: false}}
    else
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => "claim_private_handoff"} = params, %__MODULE__{} = server) do
    with {:ok, _arguments} <- bootstrap_tool_arguments(params, "claim_private_handoff"),
         {:ok, result, session} <- claim_private_handoff(params, server) do
      {:ok, tool_result(result), %{server | session: session, session_refresh_required: false}}
    else
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => "create_work_request"} = params, %__MODULE__{} = server) do
    case prepare_bootstrap_tool_call(server, params, "create_work_request") do
      {:ok, arguments} -> bootstrap_tool("create_work_request", arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch(
         "tools/call",
         %{"name" => "read_guidance_request"} = params,
         %__MODULE__{session: %Session{assignment: %{grant_role: "architect"}}} = server
       ) do
    case prepare_architect_tool_call(server, params, "read_guidance_request") do
      {:ok, arguments} -> read_guidance_request_tool(arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "read_guidance_request")
    end
  end

  defp dispatch("tools/call", %{"name" => "read_guidance_request"} = params, %__MODULE__{session: nil} = server) do
    case prepare_architect_tool_call(server, params, "read_guidance_request") do
      {:ok, arguments} -> read_guidance_request_tool(arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "read_guidance_request")
    end
  end

  defp dispatch("tools/call", %{"name" => "read_guidance_request"} = params, %__MODULE__{} = server) do
    case prepare_worker_tool_call(server, params, "read_guidance_request") do
      {:ok, arguments} -> read_guidance_request_tool(arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> worker_error(reason, "read_guidance_request")
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @worker_tools do
    case prepare_worker_tool_call(server, params, name) do
      {:ok, arguments} -> worker_tool(name, arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> worker_error(reason, name)
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @architect_tools do
    case prepare_architect_tool_call(server, params, name) do
      {:ok, arguments} -> architect_tool(name, arguments, server)
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, name)
    end
  end

  defp dispatch("tools/call", %{"name" => name}, _server) when is_binary(name) do
    {:error, -32_601, "Method not found", %{"tool" => name}}
  end

  defp dispatch("tools/call", params, _server) when is_map(params) do
    {:error, -32_602, "Invalid params", %{"reason" => "missing_tool_name"}}
  end

  defp dispatch("tools/call", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("resources/list", params, %__MODULE__{config: config, session: session}) when is_map(params) do
    base_resources = [
      %{
        "uri" => @version_resource,
        "name" => "Symphony++ version",
        "mimeType" => "application/json"
      }
    ]

    case assignment_resources(session, config.repo) do
      {:ok, resources} -> {:ok, %{"resources" => base_resources ++ resources}}
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("resources/list", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("resources/read", %{"uri" => @version_resource}, %__MODULE__{config: %Config{} = config}) do
    payload = %{
      "version" => config.version,
      "source" => source_identity(config),
      "mode" => Atom.to_string(config.mode)
    }

    {:ok, json_resource(@version_resource, payload)}
  end

  defp dispatch("resources/read", %{"uri" => @assignment_resource}, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_assignment_introspection(session.assignment) do
      {:ok, json_resource(@assignment_resource, Session.public_assignment(session))}
    else
      {:error, :unsupported_grant_role} -> auth_error({:unauthorized, :unsupported_grant_role}, @assignment_resource)
      {:error, reason} -> auth_error(reason, @assignment_resource)
    end
  end

  defp dispatch("resources/read", %{"uri" => "sympp://work-packages/" <> rest = uri}, %__MODULE__{
         config: config,
         session: session
       }) do
    case work_package_resource_id(rest) do
      {:ok, work_package_id, file_name} ->
        case Auth.require_work_package(session, work_package_id, config.repo) do
          {:ok, session} ->
            read_worker_virtual_resource(config.repo, session, work_package_id, file_name, uri)

          {:error, reason} ->
            auth_error(reason, uri)
        end

      :error ->
        {:error, -32_602, "Invalid params", %{"resource" => uri, "reason" => "invalid_work_package_resource_uri"}}
    end
  end

  defp dispatch("resources/read", %{"uri" => uri}, _server) when is_binary(uri) do
    {:error, -32_601, "Method not found", %{"resource" => uri}}
  end

  defp dispatch("resources/read", params, _server) when not is_map(params) do
    {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object"}}
  end

  defp dispatch("resources/read", _params, _server) do
    {:error, -32_602, "Invalid params", %{"reason" => "missing_resource_uri"}}
  end

  defp dispatch(_method, _params, _server) do
    {:error, -32_601, "Method not found", %{}}
  end

  defp health(%__MODULE__{config: %Config{} = config}) do
    ledger = ledger_health(config)

    %{
      "status" => if(ledger["reachable"], do: "ok", else: "degraded"),
      "version" => config.version,
      "source" => source_identity(config),
      "mode" => Atom.to_string(config.mode),
      "ledger" => ledger
    }
  end

  defp source_identity(%Config{source_revision: revision}) when is_binary(revision) and revision != "" do
    %{"revision" => String.downcase(revision)}
  end

  defp source_identity(%Config{}), do: %{"revision" => nil}

  defp ledger_health(%Config{repo: repo, database: database}) do
    case normalized_database(database) do
      nil -> default_ledger_health(repo)
      database -> configured_ledger_health(repo, database)
    end
  end

  defp default_ledger_health(repo) do
    case live_main_database_path(repo) do
      {:ok, path} -> %{"reachable" => true, "identity" => sqlite_ledger_identity(path, "default")}
      :memory -> %{"reachable" => true, "identity" => sqlite_ledger_identity(":memory:", "default")}
      :error -> generic_default_ledger_health(repo)
    end
  end

  defp generic_default_ledger_health(repo) do
    identity = repo_configured_ledger_identity(repo, "default")

    try do
      case repo_query(repo, "SELECT 1", [], log: false) do
        {:ok, _result} -> %{"reachable" => true, "identity" => identity}
        {:error, _reason} -> %{"reachable" => false, "error" => "ledger_unavailable", "identity" => identity}
      end
    rescue
      _error -> %{"reachable" => false, "error" => "ledger_unavailable", "identity" => identity}
    end
  end

  defp configured_ledger_health(repo, database) do
    case configured_ledger(database, "explicit") do
      {:sqlite, path, identity} ->
        case configured_server_ledger_for_explicit_database(repo, database, "explicit") do
          {:server, identity} -> repo_reachable_ledger_health(repo, identity)
          nil -> configured_sqlite_ledger_health(repo, path, identity)
        end

      {:server, identity} ->
        if explicit_database_matches_repo_config?(repo, database) do
          repo_reachable_ledger_health(repo, identity)
        else
          unavailable_ledger_health(identity)
        end
    end
  end

  defp configured_sqlite_ledger_health(repo, path, identity) do
    case {path, live_main_database_path(repo)} do
      {":memory:", :memory} ->
        %{"reachable" => true, "identity" => identity}

      {path, {:ok, live_path}} when is_binary(path) ->
        if Repo.same_database_path?(path, live_path) do
          %{"reachable" => true, "identity" => identity}
        else
          unavailable_ledger_health(identity)
        end

      _unmatched ->
        unavailable_ledger_health(identity)
    end
  end

  defp repo_reachable_ledger_health(repo, identity) do
    try do
      case repo_query(repo, "SELECT 1", [], log: false) do
        {:ok, _result} -> %{"reachable" => true, "identity" => identity}
        {:error, _reason} -> unavailable_ledger_health(identity)
      end
    rescue
      _error -> unavailable_ledger_health(identity)
    end
  end

  defp unavailable_ledger_health(identity),
    do: %{"reachable" => false, "error" => "ledger_unavailable", "identity" => identity}

  defp configured_ledger(database, source) do
    cond do
      Repo.memory_database?(database) ->
        {:sqlite, ":memory:", sqlite_ledger_identity(":memory:", source)}

      sqlite_file_uri?(database) ->
        {:sqlite, Repo.sqlite_file_uri_path(database), sqlite_file_uri_identity(database, source)}

      remote_database_identity?(database) ->
        {:server, server_ledger_identity(database, source)}

      true ->
        {:sqlite, database, sqlite_ledger_identity(database, source)}
    end
  end

  defp configured_ledger_identity(database, source), do: database |> configured_ledger(source) |> ledger_identity()

  defp ledger_identity({:sqlite, _path, identity}), do: identity
  defp ledger_identity({:server, identity}), do: identity

  defp repo_configured_ledger_identity(repo, source) do
    case repo_configured_database_for_identity(repo) do
      database when is_binary(database) -> configured_ledger_identity(database, source)
      _database -> unknown_ledger_identity(source)
    end
  end

  defp configured_server_ledger_for_explicit_database(repo, database, source) do
    with config when is_list(config) <- repo_config_for_identity(repo),
         true <- explicit_database_name_matches_repo_config?(config, database),
         identity_database when is_binary(identity_database) <- configured_server_database_for_identity(config) do
      {:server, server_ledger_identity(identity_database, source)}
    else
      _unmatched -> nil
    end
  end

  defp sqlite_file_uri_identity(database, source) do
    case Repo.sqlite_file_uri_path(database) do
      path when is_binary(path) and path != "" -> sqlite_ledger_identity(path, source)
      _path -> %{"kind" => "sqlite", "source" => source, "display_path" => "file:[redacted]", "default_home" => false}
    end
  end

  defp sqlite_ledger_identity(path, source) do
    %{
      "kind" => "sqlite",
      "source" => source,
      "display_path" => sqlite_display_path(path),
      "default_home" => default_home_database_path?(path)
    }
  end

  defp server_ledger_identity(database, source) do
    %{
      "kind" => "server",
      "source" => source,
      "endpoint" => safe_server_endpoint(database)
    }
  end

  defp live_main_database_path(repo) do
    case repo_query(repo, "PRAGMA database_list", [], log: false) do
      {:ok, %{rows: rows}} ->
        case Enum.find(rows, &main_database_row?/1) do
          [_seq, "main", path] when is_binary(path) and path != "" -> {:ok, path}
          [_seq, "main", ""] -> :memory
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

  defp normalized_database(database) when is_binary(database) do
    case String.trim(database) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalized_database(_database), do: nil

  defp sqlite_file_uri?("file:" <> _uri), do: true
  defp sqlite_file_uri?(_database), do: false

  defp remote_database_identity?(database) when is_binary(database) do
    remote_database_uri?(database) or server_database_dsn?(database) or credential_bearing_database_string?(database)
  end

  defp remote_database_uri?(database) do
    case URI.parse(database) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and scheme != "file" and is_binary(host) -> true
      %URI{scheme: scheme} when scheme in ["http", "https", "postgres", "postgresql", "mysql", "mssql"] -> true
      _uri -> false
    end
  rescue
    _error -> false
  end

  defp credential_bearing_database_string?(database) do
    database =~ ~r/(^|[;?\s])(password|passwd|pwd|secret|token|api[_-]?key)=/i
  end

  defp safe_server_endpoint(database) do
    case URI.parse(database) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        port_part = if is_integer(port), do: ":#{port}", else: ""
        "#{safe_endpoint_part(scheme)}://#{safe_endpoint_host(host)}#{port_part}"

      %URI{scheme: scheme} when is_binary(scheme) ->
        "#{safe_endpoint_part(scheme)}://[redacted]"

      _uri ->
        safe_server_dsn_endpoint(database)
    end
  rescue
    _error -> safe_server_dsn_endpoint(database)
  end

  defp safe_endpoint_part(part) do
    if part =~ ~r/\A[a-zA-Z][a-zA-Z0-9+.-]*\z/, do: String.downcase(part), else: "server"
  end

  defp safe_endpoint_host(host) do
    host = String.downcase(host)

    if host =~ ~r/\A[0-9a-z.:\-]+\z/ do
      if String.contains?(host, ":") and not String.starts_with?(host, "["),
        do: "[#{host}]",
        else: host
    else
      "[redacted]"
    end
  end

  defp safe_server_dsn_endpoint(database) do
    with values when map_size(values) > 0 <- server_database_dsn_values(database),
         host when is_binary(host) <- server_database_dsn_host(values) do
      {dsn_host, embedded_port} = split_server_dsn_host_port(host)
      port = server_database_dsn_port(values)
      "server://#{safe_endpoint_host(dsn_host)}#{if(port == "", do: embedded_port, else: port)}"
    else
      _missing_host -> "server"
    end
  end

  defp server_database_dsn?(database) do
    values = server_database_dsn_values(database)

    Enum.any?(["host", "hostname", "server", "addr", "address", "datasource"], &Map.has_key?(values, &1)) or
      Map.has_key?(values, "dbname") or
      (Map.has_key?(values, "database") and (Map.has_key?(values, "port") or Map.has_key?(values, "trustedconnection")))
  end

  defp server_database_dsn_values(database) when is_binary(database) do
    ~r/(?:^|[;\s])([A-Za-z][A-Za-z _-]*)\s*=\s*([^;\s]+)/
    |> Regex.scan(database)
    |> Map.new(fn [_match, key, value] -> {normalize_server_dsn_key(key), trim_server_dsn_value(value)} end)
  end

  defp server_database_dsn_values(_database), do: %{}

  defp normalize_server_dsn_key(key) do
    key
    |> String.downcase()
    |> String.replace(~r/[\s_-]/, "")
  end

  defp trim_server_dsn_value(value) do
    value
    |> String.trim()
    |> String.trim("\"'")
  end

  defp server_database_dsn_host(values) do
    Enum.find_value(["host", "hostname", "server", "addr", "address", "datasource"], &Map.get(values, &1))
  end

  defp server_database_dsn_port(values), do: Map.get(values, "port") |> safe_endpoint_port()

  defp split_server_dsn_host_port(host) do
    host =
      host
      |> String.trim()
      |> String.replace(~r/\A(?:tcp|udp):/i, "")

    case String.split(host, ",", parts: 2) do
      [dsn_host, port] -> {dsn_host, safe_endpoint_port(port)}
      [dsn_host] -> {dsn_host, ""}
    end
  end

  defp safe_endpoint_port(port) when is_binary(port) do
    port = String.trim(port)

    if port =~ ~r/\A\d{1,5}\z/ and String.to_integer(port) <= 65_535 do
      ":#{port}"
    else
      ""
    end
  end

  defp safe_endpoint_port(port) when is_integer(port) and port >= 0 and port <= 65_535, do: ":#{port}"

  defp safe_endpoint_port(_port), do: ""

  defp repo_config_for_identity(repo) when is_atom(repo) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0) do
      repo.config()
    end
  rescue
    _error -> nil
  end

  defp repo_config_for_identity(_repo), do: nil

  defp repo_configured_database_for_identity(repo) do
    repo
    |> repo_config_for_identity()
    |> configured_database_for_identity()
  end

  defp explicit_database_matches_repo_config?(repo, database) do
    case repo_configured_database_for_identity(repo) do
      repo_database when is_binary(repo_database) -> repo_database == database
      _database -> false
    end
  end

  defp configured_database_for_identity(config) when is_list(config) do
    configured_database_url_for_identity(config) ||
      configured_database_host_for_identity(config) ||
      config |> Keyword.get(:database) |> normalized_database()
  end

  defp configured_database_for_identity(_config), do: nil

  defp configured_server_database_for_identity(config) when is_list(config) do
    configured_database_url_for_identity(config) || configured_database_host_for_identity(config)
  end

  defp configured_server_database_for_identity(_config), do: nil

  defp configured_database_url_for_identity(config) do
    config
    |> Keyword.get(:url)
    |> normalized_database()
  end

  defp configured_database_host_for_identity(config) do
    host =
      config
      |> Keyword.get(:hostname)
      |> case do
        host when is_binary(host) and host != "" -> host
        _missing -> Keyword.get(config, :host)
      end
      |> normalized_database()

    if is_binary(host) do
      port = Keyword.get(config, :port) |> safe_endpoint_port()
      "server://#{safe_endpoint_host(host)}#{port}"
    end
  end

  defp explicit_database_name_matches_repo_config?(config, database) do
    config
    |> Keyword.get(:database)
    |> normalized_database()
    |> Kernel.==(database)
  end

  defp sqlite_display_path(":memory:"), do: ":memory:"

  defp sqlite_display_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> normalize_display_separator()
    |> display_home_relative_path()
  end

  defp normalize_display_separator(path), do: String.replace(path, "\\", "/")

  defp display_home_relative_path(path) do
    with home when is_binary(home) and home != "" <- System.user_home(),
         normalized_home <- home |> Path.expand() |> normalize_display_separator(),
         true <- path == normalized_home or String.starts_with?(path, normalized_home <> "/") do
      relative = binary_part(path, byte_size(normalized_home), byte_size(path) - byte_size(normalized_home))

      case String.trim_leading(relative, "/") do
        "" -> "$HOME"
        relative -> "$HOME/" <> relative
      end
    else
      _not_home -> path
    end
  end

  defp default_home_database_path?(path) when is_binary(path) do
    with home when is_binary(home) and home != "" <- System.user_home() do
      default_home_database =
        [home, ".agents", "splusplus", "symphony_plus_plus.sqlite3"]
        |> Path.join()
        |> Path.expand()

      Repo.same_database_path?(path, default_home_database)
    else
      _missing_home -> false
    end
  end

  defp default_home_database_path?(_path), do: false

  defp unknown_ledger_identity(source), do: %{"kind" => "unknown", "source" => source}

  defp health_tool_spec do
    %{
      "name" => @health_tool,
      "title" => "Symphony++ health",
      "description" => "Returns server version, ledger reachability, and safe ledger identity without exposing package data.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{}
      }
    }
  end

  defp worker_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => "Symphony++ worker tool #{name}.",
      "inputSchema" => worker_tool_input_schema(name)
    }
  end

  defp solo_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => solo_tool_description(name),
      "inputSchema" => solo_tool_input_schema(name)
    }
  end

  defp bootstrap_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => bootstrap_tool_description(name),
      "inputSchema" => bootstrap_tool_input_schema(name)
    }
  end

  defp solo_tool_description("solo_attach") do
    "Create or attach a local Solo Session for a repo, base branch, absolute workspace path, and caller id."
  end

  defp solo_tool_description("solo_append") do
    "Append one redacted entry to a local Solo Session using the existing Solo Session service."
  end

  defp solo_tool_description("solo_show") do
    "Read a local Solo Session and its latest 50 ordered entries."
  end

  defp solo_tool_description("solo_list") do
    "List local Solo Sessions using optional repo, base branch, workspace path, caller id, and status filters."
  end

  defp solo_tool_description("solo_update_status") do
    "Move a local Solo Session between valid lifecycle statuses with optimistic current-status checking."
  end

  defp bootstrap_tool_description("claim_private_handoff") do
    "Safely bind the MCP session from redacted local-private-file handoff metadata without passing a raw work key."
  end

  defp bootstrap_tool_description("create_work_request") do
    "Create a local Symphony++ WorkRequest with creator provenance and return a redacted architect handoff."
  end

  defp architect_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => architect_tool_description(name),
      "inputSchema" => architect_tool_input_schema(name)
    }
  end

  defp architect_tool_description("read_child_status") do
    "Read the architect grant's scoped child work-package status without Phase 7 delegation."
  end

  defp architect_tool_description("create_child_work_package") do
    "Create a phase-child work package inside the architect grant's current phase."
  end

  defp architect_tool_description("mint_child_worker_key") do
    "Mint a narrower worker grant for a phase-child work package in the architect grant's current phase."
  end

  defp architect_tool_description("revoke_child_worker_key") do
    "Revoke one live child-worker grant for a same-phase child package in the architect grant's current phase."
  end

  defp architect_tool_description("list_work_requests") do
    "List WorkRequests scoped to the architect grant's repo and base branch."
  end

  defp architect_tool_description("read_work_request") do
    "Read a scoped WorkRequest with clarification questions, decisions, planned slices, and status summaries."
  end

  defp architect_tool_description("list_guidance_requests") do
    "List package-scoped guidance requests visible to the architect grant's phase, repo, and base branch."
  end

  defp architect_tool_description("read_guidance_request") do
    "Read one package-scoped guidance request visible to the architect grant."
  end

  defp architect_tool_description("answer_guidance_request") do
    "Answer an open package-scoped guidance request."
  end

  defp architect_tool_description("escalate_guidance_request") do
    "Escalate an open guidance request to human_info_needed and project it as an active package blocker."
  end

  defp architect_tool_description("set_work_request_status") do
    "Move a scoped WorkRequest between valid statuses with optimistic current-status checking."
  end

  defp architect_tool_description("ask_work_request_question") do
    "Add a clarification question to a scoped WorkRequest."
  end

  defp architect_tool_description("answer_work_request_question") do
    "Answer an open clarification question that belongs to a scoped WorkRequest."
  end

  defp architect_tool_description("close_work_request_question") do
    "Close an open clarification question that belongs to a scoped WorkRequest without recording an answer."
  end

  defp architect_tool_description("record_work_request_decision") do
    "Record a durable decision log entry on a scoped WorkRequest. source_type must be one of: #{Enum.join(DecisionLogEntry.source_types(), ", ")}."
  end

  defp architect_tool_description("add_work_request_planned_slice") do
    "Add a planned slice to a scoped WorkRequest."
  end

  defp architect_tool_description("approve_work_request_planned_slice") do
    "Approve a planned slice that belongs to a scoped WorkRequest."
  end

  defp architect_tool_description("skip_work_request_planned_slice") do
    "Skip a planned slice that belongs to a scoped WorkRequest."
  end

  defp architect_tool_description("mark_work_request_sliced") do
    "Mark a scoped WorkRequest sliced using the existing approved-slice requirement."
  end

  defp architect_tool_description("dispatch_work_request_planned_slice") do
    "Dispatch one approved planned slice into a WorkPackage and private worker handoff."
  end

  defp architect_tool_description("prepare_work_package_worktree") do
    "Prepare a scoped WorkPackage git worktree and record only its worktree_path."
  end

  defp architect_tool_description("cleanup_work_package_worktree") do
    "Clean up a scoped WorkPackage git worktree after validating the recorded path and dirty state."
  end

  defp architect_tool_description("approve_scope_expansion") do
    "Approve additional allowed file globs for this scoped work package."
  end

  defp architect_tool_description("read_phase_board") do
    "Read the architect grant's scoped phase board."
  end

  defp architect_tool_description("approve_child_ready_state") do
    "Approve a ready phase-child package for merge into the architect's phase."
  end

  defp architect_tool_description("merge_child_into_phase") do
    "Record a local phase merge artifact and mark a phase child merged into the architect's phase."
  end

  defp architect_tool_description(name) when name in @phase7_stub_architect_tools do
    "Phase 7 architect tool #{name}; authorization is enforced, but behavior is not implemented yet."
  end

  defp solo_tool_input_schema("solo_attach") do
    schema(
      %{
        "repo" => string_schema(),
        "base_branch" => string_schema(),
        "workspace_path" => string_schema(),
        "caller_id" => string_schema(),
        "title" => nullable_string_schema()
      },
      ["repo", "base_branch", "workspace_path", "caller_id"]
    )
  end

  defp solo_tool_input_schema("solo_append") do
    schema(
      %{
        "session_id" => string_schema(),
        "entry_kind" => string_schema(),
        "title" => string_schema(),
        "body" => nullable_string_schema(),
        "status" => nullable_string_schema(),
        "idempotency_key" => nullable_string_schema(),
        "payload" => object_schema()
      },
      ["session_id", "entry_kind", "title"]
    )
  end

  defp solo_tool_input_schema("solo_show"), do: schema(%{"session_id" => string_schema()}, ["session_id"])

  defp solo_tool_input_schema("solo_list") do
    schema(
      %{
        "repo" => string_schema(),
        "base_branch" => string_schema(),
        "workspace_path" => string_schema(),
        "caller_id" => string_schema(),
        "status" => string_schema()
      },
      []
    )
  end

  defp solo_tool_input_schema("solo_update_status") do
    schema(
      %{
        "session_id" => string_schema(),
        "current_status" => string_schema(),
        "next_status" => string_schema()
      },
      ["session_id", "current_status", "next_status"]
    )
  end

  defp bootstrap_tool_input_schema("claim_private_handoff") do
    handoff_schema =
      schema(
        %{
          "mode" => string_enum_schema(["local-private-file"]),
          "path" => string_schema(),
          "target" => string_schema(),
          "grant_id" => string_schema(),
          "display_key" => string_schema(),
          "work_package_id" => string_schema(),
          "database" => nullable_string_schema(),
          "namespace_repo_root" => string_schema()
        },
        ["mode", "path", "target", "grant_id", "display_key", "work_package_id"]
      )

    schema(
      %{
        "claimed_by" => string_schema(),
        "private_handoff" => handoff_schema,
        "mode" => string_enum_schema(["local-private-file"]),
        "path" => string_schema(),
        "target" => string_schema(),
        "grant_id" => string_schema(),
        "display_key" => string_schema(),
        "work_package_id" => string_schema(),
        "database" => nullable_string_schema(),
        "namespace_repo_root" => string_schema()
      },
      ["claimed_by"]
    )
    |> always_validate(%{
      "anyOf" => [
        %{"required" => ["private_handoff"]},
        %{"required" => ["mode", "path", "target", "grant_id", "display_key", "work_package_id"]}
      ]
    })
  end

  defp bootstrap_tool_input_schema("create_work_request") do
    schema(
      %{
        "repo" => string_schema(),
        "base_branch" => string_schema(),
        "title" => string_schema(),
        "description" => string_schema(),
        "human_description" => string_schema(),
        "request_kind" => string_enum_schema(WorkRequest.work_types()),
        "workflow_mode" => string_enum_schema(WorkRequest.dispatch_shapes()),
        "constraints" => object_schema(),
        "status" => string_enum_schema(WorkRequest.statuses()),
        "claimed_by" => string_schema(),
        "creator_kind" => string_enum_schema(WorkRequest.creator_kinds()),
        "created_by_kind" => string_enum_schema(WorkRequest.creator_kinds()),
        "creator_name" => string_schema(),
        "created_by_name" => string_schema(),
        "created_via" => string_schema()
      },
      ["repo", "base_branch", "title", "request_kind"]
    )
    |> always_validate(%{"anyOf" => [%{"required" => ["description"]}, %{"required" => ["human_description"]}]})
  end

  defp worker_tool_input_schema("claim_work_key") do
    schema(%{"secret" => string_schema(), "claimed_by" => string_schema()}, ["secret", "claimed_by"])
  end

  defp worker_tool_input_schema(name) when name in ["get_current_assignment", "read_context", "read_task_plan", "mark_ready"] do
    schema(%{}, [])
  end

  defp worker_tool_input_schema("update_task_plan") do
    schema(
      scoped_properties(%{
        "body" => nullable_string_schema(),
        "expected_version" => integer_schema(),
        "id" => string_schema(),
        "patch" => plan_patch_schema(),
        "status" => string_schema(),
        "title" => string_schema()
      }),
      ["expected_version"]
    )
    |> always_validate(%{
      "oneOf" => [
        %{
          "required" => ["patch"],
          "not" => %{"anyOf" => [%{"required" => ["id"]}, %{"required" => ["title"]}, %{"required" => ["body"]}, %{"required" => ["status"]}]}
        },
        %{"required" => ["title"], "not" => %{"required" => ["patch"]}}
      ]
    })
  end

  defp worker_tool_input_schema("append_finding") do
    schema(
      scoped_properties(%{
        "body" => string_schema(),
        "id" => string_schema(),
        "idempotency_key" => string_schema(),
        "severity" => string_schema(),
        "title" => string_schema()
      }),
      ["title", "body", "idempotency_key"]
    )
  end

  defp worker_tool_input_schema(name) when name in ["append_progress", "request_scope_expansion"] do
    schema(progress_properties(), ["summary", "idempotency_key"])
  end

  defp worker_tool_input_schema("report_blocker") do
    schema(Map.put(progress_properties(), "blocker_id", string_schema()), ["summary", "idempotency_key"])
  end

  defp worker_tool_input_schema("resolve_blocker") do
    schema(
      progress_properties()
      |> Map.merge(%{"blocker_id" => string_schema(), "resolution" => string_schema()}),
      ["blocker_id", "resolution", "summary", "idempotency_key"]
    )
  end

  defp worker_tool_input_schema("create_guidance_request") do
    schema(
      scoped_properties(%{
        "summary" => string_schema(),
        "question" => string_schema(),
        "context" => string_schema(),
        "idempotency_key" => string_schema()
      }),
      ["summary", "question", "context", "idempotency_key"]
    )
  end

  defp worker_tool_input_schema("read_guidance_request") do
    schema(scoped_properties(%{"guidance_request_id" => string_schema()}), ["guidance_request_id"])
  end

  defp worker_tool_input_schema("set_status") do
    schema(scoped_properties(%{"status" => string_schema(), "expected_status" => string_schema(), "reason" => nullable_string_schema()}), [
      "status",
      "expected_status"
    ])
  end

  defp worker_tool_input_schema("attach_branch") do
    schema(metadata_properties(%{"branch" => string_schema(), "head_sha" => string_schema()}), ["branch", "head_sha"])
  end

  defp worker_tool_input_schema("attach_pr") do
    schema(
      metadata_properties(%{
        "url" => string_schema(),
        "number" => pr_number_schema(),
        "repository" => string_schema(),
        "head_sha" => string_schema(),
        "metadata" => object_schema()
      }),
      []
    )
    |> require_pr_identity_and_head()
  end

  defp worker_tool_input_schema("sync_pr") do
    schema(
      metadata_properties(%{
        "url" => string_schema(),
        "number" => pr_number_schema(),
        "repository" => string_schema(),
        "head_sha" => string_schema(),
        "metadata" => object_schema()
      }),
      ["metadata"]
    )
    |> require_pr_identity_and_head()
  end

  defp worker_tool_input_schema("submit_review_package") do
    schema(
      metadata_properties(%{
        "summary" => string_schema(),
        "tests" => nonempty_string_array_schema(),
        "artifacts" => nonempty_string_array_schema(),
        "reviews" => review_entries_schema(),
        "head_sha" => string_schema(),
        "acceptance_criteria_met" => boolean_schema()
      }),
      ["summary", "tests", "artifacts", "head_sha"]
    )
  end

  defp worker_tool_input_schema("attach_review_suite_result") do
    schema(
      scoped_properties(%{
        "anchor" => string_schema(),
        "head_sha" => string_schema(),
        "idempotency_key" => string_schema(),
        "lane" => string_schema(),
        "reviewer" => string_schema(),
        "round_id" => string_schema(),
        "status" => string_schema(),
        "suite" => string_schema(),
        "summary" => string_schema(),
        "verdict" => string_schema()
      }),
      ["work_package_id", "head_sha", "status", "verdict", "suite", "anchor", "summary"]
    )
  end

  defp architect_tool_input_schema("create_child_work_package"), do: schema(%{"package" => object_schema()}, ["package"])

  defp architect_tool_input_schema("mint_child_worker_key") do
    schema(%{"work_package_id" => string_schema(), "template" => object_schema()}, ["work_package_id", "template"])
  end

  defp architect_tool_input_schema("revoke_child_worker_key") do
    schema(%{"grant_id" => string_schema(), "reason" => string_schema()}, ["grant_id", "reason"])
  end

  defp architect_tool_input_schema("list_work_requests"), do: schema(%{"status" => string_schema()}, [])

  defp architect_tool_input_schema("read_work_request"), do: schema(%{"work_request_id" => string_schema()}, ["work_request_id"])

  defp architect_tool_input_schema("list_guidance_requests") do
    schema(%{"status" => string_schema(), "work_package_id" => string_schema()}, [])
  end

  defp architect_tool_input_schema("read_guidance_request") do
    worker_tool_input_schema("read_guidance_request")
  end

  defp architect_tool_input_schema("answer_guidance_request") do
    schema(
      %{
        "guidance_request_id" => string_schema(),
        "answer" => string_schema(),
        "answered_by" => string_schema()
      },
      ["guidance_request_id", "answer"]
    )
  end

  defp architect_tool_input_schema("escalate_guidance_request") do
    schema(
      %{
        "guidance_request_id" => string_schema(),
        "reason" => string_schema(),
        "recommended_language" => string_schema(),
        "decision_prompt" => decision_prompt_schema()
      },
      ["guidance_request_id", "reason", "recommended_language"]
    )
  end

  defp architect_tool_input_schema("set_work_request_status") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "current_status" => string_schema(),
        "next_status" => string_schema()
      },
      ["work_request_id", "current_status", "next_status"]
    )
  end

  defp architect_tool_input_schema("ask_work_request_question") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "category" => string_schema(),
        "question" => string_schema(),
        "why_needed" => string_schema(),
        "decision_prompt" => decision_prompt_schema(),
        "asked_by_agent_run_id" => string_schema()
      },
      ["work_request_id", "category", "question", "why_needed"]
    )
  end

  defp architect_tool_input_schema("answer_work_request_question") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "question_id" => string_schema(),
        "current_status" => string_schema(),
        "answer" => string_schema(),
        "answered_by" => string_schema()
      },
      ["work_request_id", "question_id", "current_status", "answer"]
    )
  end

  defp architect_tool_input_schema("close_work_request_question") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "question_id" => string_schema(),
        "current_status" => string_schema()
      },
      ["work_request_id", "question_id", "current_status"]
    )
  end

  defp architect_tool_input_schema("record_work_request_decision") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "source_type" => string_enum_schema(DecisionLogEntry.source_types()),
        "decision" => string_schema(),
        "rationale" => string_schema(),
        "scope_impact" => string_schema(),
        "created_by" => string_schema(),
        "source_id" => string_schema()
      },
      ["work_request_id", "source_type", "decision", "rationale", "scope_impact", "created_by"]
    )
  end

  defp architect_tool_input_schema("add_work_request_planned_slice") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "title" => string_schema(),
        "goal" => string_schema(),
        "work_package_kind" => string_enum_schema(StateMachine.standalone_kinds()),
        "target_base_branch" => string_schema(),
        "owned_file_globs" => string_array_schema(),
        "forbidden_file_globs" => string_array_schema(),
        "acceptance_criteria" => string_array_schema(),
        "validation_steps" => string_array_schema(),
        "review_lanes" => string_array_schema(),
        "stop_conditions" => string_array_schema(),
        "branch_pattern" => string_schema()
      },
      [
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
    )
  end

  defp architect_tool_input_schema(name) when name in ["approve_work_request_planned_slice", "skip_work_request_planned_slice"] do
    schema(
      %{
        "work_request_id" => string_schema(),
        "planned_slice_id" => string_schema(),
        "current_status" => string_schema()
      },
      ["work_request_id", "planned_slice_id", "current_status"]
    )
  end

  defp architect_tool_input_schema("mark_work_request_sliced") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "current_status" => string_schema()
      },
      ["work_request_id", "current_status"]
    )
  end

  defp architect_tool_input_schema("dispatch_work_request_planned_slice") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "planned_slice_id" => string_schema(),
        "claimed_by" => string_schema(),
        "secret_handoff" => string_schema(),
        "secret_store_dir" => string_schema(),
        "repo_root" => string_schema()
      },
      ["work_request_id", "planned_slice_id", "claimed_by"]
    )
  end

  defp architect_tool_input_schema("prepare_work_package_worktree") do
    schema(
      %{
        "work_package_id" => string_schema(),
        "repo_root" => string_schema(),
        "base_branch" => string_schema(),
        "branch" => string_schema()
      },
      ["work_package_id", "repo_root", "base_branch", "branch"]
    )
  end

  defp architect_tool_input_schema("cleanup_work_package_worktree") do
    schema(%{"work_package_id" => string_schema()}, ["work_package_id"])
  end

  defp architect_tool_input_schema("read_child_status"), do: schema(%{"work_package_id" => string_schema()}, ["work_package_id"])

  defp architect_tool_input_schema("approve_scope_expansion") do
    schema(
      %{
        "work_package_id" => string_schema(),
        "allowed_file_globs" => nonempty_string_array_schema(),
        "request_id" => string_schema(),
        "rationale" => string_schema()
      },
      ["work_package_id", "allowed_file_globs", "rationale"]
    )
  end

  defp architect_tool_input_schema("read_phase_board"), do: schema(%{"phase_id" => string_schema()}, ["phase_id"])

  defp architect_tool_input_schema("request_child_replan") do
    schema(%{"work_package_id" => string_schema(), "reason" => string_schema()}, ["work_package_id", "reason"])
  end

  defp architect_tool_input_schema("approve_child_ready_state") do
    schema(
      %{"work_package_id" => string_schema(), "rationale" => string_schema(), "request_id" => string_schema()},
      ["work_package_id", "rationale"]
    )
  end

  defp architect_tool_input_schema("merge_child_into_phase"),
    do: schema(%{"work_package_id" => string_schema(), "merge_artifact" => merge_artifact_schema()}, ["work_package_id", "merge_artifact"])

  defp architect_tool_input_schema("split_work_package") do
    schema(%{"work_package_id" => string_schema(), "child_specs" => nonempty_object_array_schema()}, ["work_package_id", "child_specs"])
  end

  defp architect_tool_input_schema("publish_phase_update") do
    schema(%{"phase_id" => string_schema(), "update" => object_schema()}, ["phase_id", "update"])
  end

  defp tool_specs_for_session(_config, nil) do
    {:ok, unbound_tool_specs()}
  end

  defp tool_specs_for_session(%Config{repo: repo}, session) do
    with :ok <- prepare_mcp_repository(repo) do
      case Auth.require_session(session, repo) do
        {:ok, %Session{assignment: %{grant_role: "architect"}}} ->
          {:ok, [health_tool_spec(), worker_tool_spec("get_current_assignment") | architect_tool_specs()]}

        {:ok, %Session{assignment: %{grant_role: "worker"}}} ->
          {:ok, [health_tool_spec() | Enum.map(@worker_tools, &worker_tool_spec/1)]}

        {:ok, %Session{}} ->
          {:error, {:unauthorized, :unsupported_grant_role}}

        {:error, {:service_unavailable, _reason} = reason} ->
          {:error, reason}

        {:error, _reason} ->
          {:ok, claimable_tool_specs()}
      end
    end
  end

  defp claimable_tool_specs, do: [health_tool_spec(), worker_tool_spec("claim_work_key"), bootstrap_tool_spec("claim_private_handoff")]

  defp unbound_tool_specs do
    [health_tool_spec()] ++
      Enum.map(@solo_tools, &solo_tool_spec/1) ++
      [worker_tool_spec("claim_work_key")] ++
      Enum.map(@bootstrap_tools, &bootstrap_tool_spec/1) ++ architect_tool_specs()
  end

  defp architect_tool_specs, do: Enum.map(@architect_tools, &architect_tool_spec/1)

  defp tool_specs_for_server(%__MODULE__{session_refresh_required: true}), do: {:ok, claimable_tool_specs()}

  defp tool_specs_for_server(%__MODULE__{config: config, session: session}), do: tool_specs_for_session(config, session)

  defp schema(properties, required) do
    %{"type" => "object", "additionalProperties" => false, "properties" => properties, "required" => required}
  end

  defp always_validate(schema, constraint), do: Map.merge(schema, %{"if" => %{}, "then" => constraint})

  defp require_pr_identity_and_head(schema) do
    always_validate(schema, %{
      "allOf" => [
        %{"anyOf" => [%{"required" => ["url"]}, %{"required" => ["number"]}]},
        %{
          "anyOf" => [
            %{"required" => ["head_sha"]},
            %{"required" => ["metadata"], "properties" => %{"metadata" => metadata_head_schema()}}
          ]
        }
      ]
    })
  end

  defp scoped_properties(properties), do: Map.put(properties, "work_package_id", string_schema())

  defp progress_properties do
    scoped_properties(%{
      "summary" => string_schema(),
      "body" => nullable_string_schema(),
      "status" => string_schema(),
      "idempotency_key" => string_schema(),
      "payload" => object_schema()
    })
  end

  defp metadata_properties(properties) do
    properties
    |> Map.merge(%{
      "body" => nullable_string_schema(),
      "idempotency_key" => string_schema(),
      "payload" => object_schema(),
      "status" => string_schema(),
      "summary" => string_schema()
    })
    |> scoped_properties()
  end

  defp string_schema, do: %{"type" => "string"}
  defp string_enum_schema(values) when is_list(values), do: %{"type" => "string", "enum" => values}
  defp nonblank_string_schema, do: %{"type" => "string", "minLength" => 1, "pattern" => "\\S"}
  defp boolean_schema, do: %{"type" => "boolean"}
  defp integer_schema, do: %{"type" => "integer"}

  defp pr_number_schema do
    %{"anyOf" => [%{"type" => "integer", "minimum" => 1}, %{"type" => "string", "pattern" => "^[1-9][0-9]*$"}]}
  end

  defp nullable_string_schema, do: %{"type" => ["string", "null"]}
  defp object_schema, do: %{"type" => "object", "additionalProperties" => true}

  defp decision_prompt_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "tl_dr" => nonblank_string_schema(),
        "details" => nonblank_string_schema(),
        "options" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 4,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "id" => nonblank_string_schema(),
              "label" => nonblank_string_schema(),
              "description" => nonblank_string_schema(),
              "pros" => string_array_schema(),
              "cons" => string_array_schema(),
              "answer" => nonblank_string_schema()
            },
            "required" => ["id", "label", "answer"]
          }
        },
        "custom_redirect_label" => nonblank_string_schema()
      },
      "required" => ["tl_dr", "details", "options"]
    }
  end

  defp nonempty_string_array_schema, do: %{"type" => "array", "minItems" => 1, "items" => nonblank_string_schema()}
  defp string_array_schema, do: %{"type" => "array", "items" => nonblank_string_schema()}
  defp nonempty_object_array_schema, do: %{"type" => "array", "minItems" => 1, "items" => object_schema()}

  defp metadata_head_schema do
    %{
      "type" => "object",
      "additionalProperties" => true,
      "properties" => %{
        "head_sha" => string_schema(),
        "head" => %{
          "type" => "object",
          "additionalProperties" => true,
          "properties" => %{"sha" => string_schema()},
          "required" => ["sha"]
        }
      },
      "anyOf" => [%{"required" => ["head_sha"]}, %{"required" => ["head"]}]
    }
  end

  defp merge_artifact_schema do
    %{
      "type" => "object",
      "additionalProperties" => true,
      "properties" => %{
        "status" => string_schema(),
        "uri" => string_schema(),
        "summary" => string_schema(),
        "commit_sha" => string_schema(),
        "merge_commit_sha" => string_schema()
      },
      "required" => ["status", "uri"]
    }
  end

  defp plan_patch_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "nodes" => %{
          "type" => "array",
          "minItems" => 1,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "id" => string_schema(),
              "title" => string_schema(),
              "body" => nullable_string_schema(),
              "status" => string_schema()
            },
            "anyOf" => [
              %{"required" => ["title"]},
              %{
                "required" => ["id"],
                "anyOf" => [%{"required" => ["title"]}, %{"required" => ["body"]}, %{"required" => ["status"]}]
              }
            ]
          }
        }
      },
      "required" => ["nodes"]
    }
  end

  defp review_entries_schema do
    %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{"lane" => string_schema(), "verdict" => string_schema()},
        "required" => ["lane", "verdict"]
      }
    }
  end

  defp work_package_resource_id(rest) when is_binary(rest) do
    case String.split(rest, "/", parts: 2) do
      [work_package_id, resource_path] ->
        if String.trim(work_package_id) != "" and valid_resource_path?(resource_path) do
          {:ok, work_package_id, resource_path}
        else
          :error
        end

      _parts ->
        :error
    end
  end

  defp valid_resource_path?(resource_path) when is_binary(resource_path) do
    String.trim(resource_path) != "" and not String.contains?(resource_path, "/")
  end

  defp assignment_resources(nil, _repo), do: {:ok, []}

  defp assignment_resources(%Session{} = session, repo) do
    case Auth.require_session(session, repo) do
      {:ok, %Session{} = session} ->
        assignment_resources_for_session(session)

      {:error, {:service_unavailable, reason}} ->
        service_error(reason, @assignment_resource)

      {:error, _reason} ->
        {:ok, []}
    end
  end

  defp assignment_resources(_session, _repo), do: {:ok, []}

  defp assignment_resources_for_session(%Session{assignment: %{grant_role: "worker"}} = session) do
    case require_worker_assignment(session.assignment) do
      :ok -> listed_assignment_resources(session)
      {:error, _reason} -> {:ok, []}
    end
  end

  defp assignment_resources_for_session(%Session{assignment: %{grant_role: "architect"}} = session) do
    case require_assignment_introspection(session.assignment) do
      :ok -> listed_current_assignment_resource(session)
      {:error, _reason} -> {:ok, []}
    end
  end

  defp assignment_resources_for_session(%Session{}), do: {:ok, []}

  defp listed_assignment_resources(%Session{} = session) do
    work_package_id = Session.work_package_id(session)

    with {:ok, assignment_resources} <- listed_current_assignment_resource(session) do
      {:ok, assignment_resources ++ work_package_resources(work_package_id)}
    end
  end

  defp listed_current_assignment_resource(%Session{}) do
    {:ok,
     [
       %{
         "uri" => @assignment_resource,
         "name" => "Current Symphony++ assignment",
         "mimeType" => "application/json"
       }
     ]}
  end

  defp work_package_resources(work_package_id) do
    Enum.map(PlanningRenderer.virtual_files(), fn file_name ->
      %{
        "uri" => "sympp://work-packages/#{work_package_id}/#{file_name}",
        "name" => file_name,
        "mimeType" => "text/markdown"
      }
    end)
  end

  defp read_virtual_resource(repo, work_package_id, file_name, uri) do
    if file_name in PlanningRenderer.virtual_files() do
      case PlanningRenderer.render(repo, work_package_id, file_name) do
        {:ok, markdown} -> {:ok, text_resource(uri, markdown, "text/markdown")}
        {:error, reason} -> service_error(reason, uri)
      end
    else
      {:error, -32_601, "Method not found", %{"resource" => uri, "reason" => "unknown_virtual_file"}}
    end
  end

  defp read_worker_virtual_resource(repo, %Session{} = session, work_package_id, file_name, uri) do
    case require_worker_assignment(session.assignment) do
      :ok -> read_virtual_resource(repo, work_package_id, file_name, uri)
      {:error, reason} -> auth_error({:unauthorized, reason}, uri)
    end
  end

  defp handle_session_claim_tool("claim_work_key", params, id, %__MODULE__{} = server) do
    handle_claim_work_key(params, id, server)
  end

  defp handle_session_claim_tool("claim_private_handoff", params, id, %__MODULE__{} = server) do
    case claim_private_handoff(params, server) do
      {:ok, result, session} ->
        {response(id, tool_result(result)), %{server | session: session, session_refresh_required: false}}

      {:error, code, message, data} ->
        {error_response(id, code, message, data), server}
    end
  end

  defp handle_session_claim_tool_notification("claim_work_key", params, %__MODULE__{} = server) do
    handle_claim_work_key_notification(params, server)
  end

  defp handle_session_claim_tool_notification("claim_private_handoff", params, %__MODULE__{} = server) do
    case claim_private_handoff(params, server) do
      {:ok, _result, session} -> {nil, %{server | session: session, session_refresh_required: false}}
      {:error, _code, _message, _data} -> {nil, server}
    end
  end

  defp handle_claim_work_key(params, id, %__MODULE__{} = server) do
    case claim_work_key(params, server) do
      {:ok, result, session} ->
        {response(id, tool_result(result)), %{server | session: session, session_refresh_required: false}}

      {:error, code, message, data} ->
        {error_response(id, code, message, data), server}
    end
  end

  defp handle_claim_work_key_notification(params, %__MODULE__{} = server) do
    case claim_work_key(params, server) do
      {:ok, _result, session} -> {nil, %{server | session: session, session_refresh_required: false}}
      {:error, _code, _message, _data} -> {nil, server}
    end
  end

  defp claim_work_key(params, %__MODULE__{config: config, session: %Session{} = session}) do
    with {:ok, arguments} <- worker_tool_arguments(params, "claim_work_key"),
         {:ok, secret} <- required_argument(arguments, "secret"),
         {:ok, claimed_by} <- required_argument(arguments, "claimed_by"),
         :ok <- require_full_secret(secret),
         :ok <- prepare_mcp_repository(config.repo) do
      proof_hash = WorkKey.secret_hash(secret)

      case claim_work_key_with_bound_session(config.repo, session, secret, proof_hash, claimed_by) do
        {:ok, _result, _session} = success -> success
        {:error, reason} -> claim_error(reason)
      end
    else
      {:error, code, message, data} -> {:error, code, message, data}
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "claim_work_key", "reason" => reason}}
      {:error, reason} -> claim_error(reason)
    end
  rescue
    _error -> {:error, -32_000, "Server error", %{"tool" => "claim_work_key", "reason" => "ledger_unavailable"}}
  end

  defp claim_work_key(params, %__MODULE__{config: config}) do
    with {:ok, arguments} <- worker_tool_arguments(params, "claim_work_key"),
         {:ok, secret} <- required_argument(arguments, "secret"),
         {:ok, claimed_by} <- required_argument(arguments, "claimed_by"),
         :ok <- require_full_secret(secret),
         :ok <- prepare_mcp_repository(config.repo) do
      proof_hash = WorkKey.secret_hash(secret)

      case claim_unbound_work_key(config.repo, secret, proof_hash, claimed_by) do
        {:ok, _result, _session} = success -> success
        {:error, reason} -> claim_error(reason)
      end
    else
      {:error, code, message, data} -> {:error, code, message, data}
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "claim_work_key", "reason" => reason}}
      {:error, reason} -> claim_error(reason)
    end
  rescue
    _error -> {:error, -32_000, "Server error", %{"tool" => "claim_work_key", "reason" => "ledger_unavailable"}}
  end

  defp claim_private_handoff(params, %__MODULE__{config: config, session: %Session{} = session}) do
    with {:ok, arguments} <- bootstrap_tool_arguments(params, "claim_private_handoff"),
         {:ok, claimed_by} <- required_argument(arguments, "claimed_by"),
         {:ok, handoff} <- private_handoff_argument(arguments),
         :ok <- prepare_mcp_repository(config.repo),
         {:ok, secret} <- private_handoff_secret(config, handoff, claimed_by) do
      proof_hash = WorkKey.secret_hash(secret)

      case claim_work_key_with_bound_session(config.repo, session, secret, proof_hash, claimed_by) do
        {:ok, _result, _session} = success -> success
        {:error, reason} -> private_handoff_claim_error(reason)
      end
    else
      {:error, code, message, data} -> {:error, code, message, data}
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "claim_private_handoff", "reason" => reason}}
      {:error, reason} -> private_handoff_claim_error(reason)
    end
  rescue
    _error -> {:error, -32_000, "Server error", %{"tool" => "claim_private_handoff", "reason" => "ledger_unavailable"}}
  end

  defp claim_private_handoff(params, %__MODULE__{config: config}) do
    with {:ok, arguments} <- bootstrap_tool_arguments(params, "claim_private_handoff"),
         {:ok, claimed_by} <- required_argument(arguments, "claimed_by"),
         {:ok, handoff} <- private_handoff_argument(arguments),
         :ok <- prepare_mcp_repository(config.repo),
         {:ok, secret} <- private_handoff_secret(config, handoff, claimed_by) do
      proof_hash = WorkKey.secret_hash(secret)

      case claim_unbound_work_key(config.repo, secret, proof_hash, claimed_by) do
        {:ok, _result, _session} = success -> success
        {:error, reason} -> private_handoff_claim_error(reason)
      end
    else
      {:error, code, message, data} -> {:error, code, message, data}
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "claim_private_handoff", "reason" => reason}}
      {:error, reason} -> private_handoff_claim_error(reason)
    end
  rescue
    _error -> {:error, -32_000, "Server error", %{"tool" => "claim_private_handoff", "reason" => "ledger_unavailable"}}
  end

  defp private_handoff_argument(arguments) do
    with :ok <- reject_private_handoff_secret_material(arguments),
         {:ok, handoff} <- private_handoff_argument_payload(arguments),
         :ok <- reject_private_handoff_secret_material(handoff),
         :ok <- require_private_handoff_fields(handoff),
         :ok <- require_private_handoff_mode(handoff) do
      {:ok, handoff}
    end
  end

  defp private_handoff_argument_payload(%{"private_handoff" => handoff} = arguments) when is_map(handoff) do
    if Enum.any?(@private_handoff_claim_keys, &Map.has_key?(arguments, &1)) do
      {:tool_error, "private_handoff_argument_conflict"}
    else
      {:ok, handoff}
    end
  end

  defp private_handoff_argument_payload(%{"private_handoff" => _handoff}), do: {:tool_error, "invalid_private_handoff"}

  defp private_handoff_argument_payload(arguments) do
    handoff = Map.take(arguments, @private_handoff_claim_keys)
    if map_size(handoff) == 0, do: {:tool_error, "missing_private_handoff"}, else: {:ok, handoff}
  end

  defp reject_private_handoff_secret_material(map) when is_map(map) do
    forbidden = ["secret", "secret_hash", "run_mcp_command"]

    if Enum.any?(forbidden, &private_handoff_key_present?(map, &1)) do
      {:tool_error, "secret_material_not_allowed"}
    else
      :ok
    end
  end

  defp private_handoff_key_present?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))
  end

  defp require_private_handoff_fields(handoff) do
    Enum.find_value(["mode", "path", "target", "grant_id", "display_key", "work_package_id"], :ok, fn key ->
      case private_handoff_string(handoff, key) do
        {:ok, _value} -> nil
        {:error, reason} -> {:tool_error, reason}
      end
    end)
  end

  defp require_private_handoff_mode(handoff) do
    case private_handoff_string(handoff, "mode") do
      {:ok, "local-private-file"} -> :ok
      {:ok, _mode} -> {:tool_error, "unsupported_private_handoff_mode"}
      {:error, reason} -> {:tool_error, reason}
    end
  end

  defp private_handoff_secret(%Config{} = config, handoff, claimed_by) do
    with {:ok, work_package_id} <- private_handoff_string(handoff, "work_package_id"),
         {:ok, grant_id} <- private_handoff_string(handoff, "grant_id"),
         {:ok, display_key} <- private_handoff_string(handoff, "display_key"),
         {:ok, target} <- private_handoff_string(handoff, "target"),
         {:ok, grant} <- AccessGrantRepository.get(config.repo, grant_id),
         {:ok, work_package} <- WorkPackageRepository.get(config.repo, work_package_id),
         :ok <- validate_private_handoff_grant(grant, work_package, display_key, target),
         :ok <- AccessGrantService.require_live_package_authority(config.repo, grant) do
      read_private_handoff_secret_from_known_store(work_package, grant, handoff, config, claimed_by)
    end
  end

  defp validate_private_handoff_grant(%AccessGrant{} = grant, %WorkPackage{} = work_package, display_key, target) do
    expected_target = "SymphonyPlusPlus:worker:#{work_package.id}:#{grant.display_key}:#{grant.id}"

    cond do
      grant.work_package_id != work_package.id -> {:error, :private_handoff_metadata_mismatch}
      grant.display_key != display_key -> {:error, :private_handoff_metadata_mismatch}
      target != expected_target -> {:error, :private_handoff_metadata_mismatch}
      true -> :ok
    end
  end

  defp read_private_handoff_secret_from_known_store(%WorkPackage{} = work_package, %AccessGrant{} = grant, handoff, %Config{} = config, claimed_by) do
    config
    |> private_handoff_read_opts(handoff, claimed_by)
    |> Enum.reduce_while({:error, :private_handoff_missing_file}, fn opts, last_error ->
      case SecretHandoff.read_local_private_file_secret(work_package, grant, handoff, opts) do
        {:ok, secret} -> {:halt, {:ok, secret}}
        {:error, reason} -> {:cont, last_private_handoff_error(last_error, reason)}
      end
    end)
  end

  defp last_private_handoff_error({:error, :private_handoff_missing_file}, reason), do: {:error, reason}

  defp last_private_handoff_error({:error, reason} = last_error, _reason)
       when reason in [
              :private_handoff_metadata_mismatch,
              :private_handoff_not_regular_file,
              :private_handoff_path_mismatch,
              :private_handoff_path_traversal,
              :private_handoff_secret_mismatch,
              :private_handoff_secret_too_large
            ],
       do: last_error

  defp last_private_handoff_error({:error, _reason} = last_error, :missing_repo_root), do: last_error
  defp last_private_handoff_error({:error, _reason} = last_error, {:handoff_metadata_invalid, _metadata_reason}), do: last_error
  defp last_private_handoff_error(_last_error, reason), do: {:error, reason}

  defp private_handoff_read_opts(%Config{} = config, handoff, claimed_by) do
    repo_roots = private_handoff_repo_roots(config, handoff)
    databases = private_handoff_database_entries(config, handoff)
    store_dirs = private_handoff_store_dirs()

    for repo_root <- repo_roots,
        {database, allow_database_scan?} <- databases,
        store_dir <- store_dirs do
      [
        mode: "local-private-file",
        namespace_repo_root: repo_root,
        repo_root: repo_root,
        claimed_by: claimed_by
      ]
      |> put_optional_handoff_opt(:database, database)
      |> put_optional_handoff_opt(:allow_database_metadata_scan?, allow_database_scan?)
      |> put_optional_handoff_opt(:store_dir, store_dir)
    end
  end

  defp private_handoff_repo_roots(%Config{repo_root: repo_root}, handoff) do
    case private_handoff_namespace_repo_root(handoff) do
      namespace_repo_root when is_binary(namespace_repo_root) ->
        nonblank_unique_paths([namespace_repo_root])

      nil ->
        [repo_root, SecretHandoff.local_operator_repo_root() | SecretHandoff.local_operator_namespace_repo_roots()]
        |> nonblank_unique_paths()
    end
  end

  defp private_handoff_namespace_repo_root(handoff) do
    case private_handoff_optional_string(handoff, "namespace_repo_root") do
      {:ok, repo_root} -> repo_root
      {:error, _reason} -> nil
    end
  end

  defp private_handoff_database_entries(%Config{} = config, handoff) do
    case private_handoff_optional_string(handoff, "database") do
      {:ok, database} when is_binary(database) ->
        [{database, private_handoff_database_matches_config?(config, database)}]

      {:ok, nil} ->
        [config.database, live_dispatch_database_or_nil(config.repo), nil]
        |> unique_optional_values()
        |> private_handoff_database_entries_without_explicit_database()

      {:error, _reason} ->
        [config.database, live_dispatch_database_or_nil(config.repo), nil]
        |> unique_optional_values()
        |> private_handoff_database_entries_without_explicit_database()
    end
  end

  defp private_handoff_database_entries_without_explicit_database(databases) do
    Enum.map(databases, &{&1, false})
  end

  defp private_handoff_database_matches_config?(%Config{} = config, database) do
    Enum.any?([config.database, live_dispatch_database_or_nil(config.repo)], &same_handoff_database?(database, &1))
  end

  defp same_handoff_database?(database, candidate) do
    case {normalize_optional_value(database), normalize_optional_value(candidate)} do
      {database, candidate} when is_binary(database) and is_binary(candidate) ->
        Repo.same_database_path?(database, candidate)

      _database ->
        false
    end
  end

  defp live_dispatch_database_or_nil(repo) do
    case live_file_backed_dispatch_database(repo) do
      {:ok, database} -> database
      _result -> nil
    end
  end

  defp private_handoff_store_dirs do
    [Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir), nil]
    |> unique_optional_values()
  end

  defp nonblank_unique_paths(values) do
    values
    |> Enum.filter(&filled_string?/1)
    |> Enum.map(&Path.expand(String.trim(&1)))
    |> Enum.uniq()
  end

  defp unique_optional_values(values) do
    values
    |> Enum.map(&normalize_optional_value/1)
    |> Enum.uniq()
  end

  defp normalize_optional_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_value(nil), do: nil
  defp normalize_optional_value(value), do: value

  defp private_handoff_string(handoff, key) do
    case private_handoff_fetch(handoff, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, "missing_#{key}"}
    end
  end

  defp private_handoff_optional_string(handoff, key) do
    case private_handoff_fetch(handoff, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:ok, nil}

      _value ->
        {:error, "invalid_#{key}"}
    end
  end

  defp private_handoff_fetch(handoff, key) when is_map(handoff) do
    Map.get(handoff, key) || Map.get(handoff, String.to_atom(key))
  end

  defp claim_work_key_with_bound_session(repo, %Session{} = session, secret, proof_hash, claimed_by) do
    if session.proof_hash == proof_hash do
      with :ok <- require_same_claim_owner(session.assignment, claimed_by),
           {:ok, session} <- revalidate_bound_session(repo, session, proof_hash) do
        {:ok, %{"assignment" => Session.public_assignment(session)}, session}
      end
    else
      case Auth.require_session(session, repo) do
        {:ok, %Session{}} -> {:error, :session_already_bound}
        {:error, {:service_unavailable, _reason} = reason} -> {:error, reason}
        {:error, _reason} -> claim_unbound_work_key(repo, secret, proof_hash, claimed_by)
      end
    end
  end

  defp claim_unbound_work_key(repo, secret, proof_hash, claimed_by) do
    with :ok <- require_mcp_claimable_secret(repo, proof_hash),
         {:ok, session} <- claim_or_reconnect_session(repo, secret, proof_hash, claimed_by) do
      {:ok, %{"assignment" => Session.public_assignment(session)}, session}
    end
  end

  defp revalidate_bound_session(repo, %Session{} = session, proof_hash) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, session.assignment.grant_id),
         :ok <- AccessGrantService.require_live_package_authority(repo, grant),
         {:ok, session} <- Session.from_grant(grant, DateTime.utc_now(:microsecond), proof_hash: proof_hash),
         :ok <- require_mcp_claimable_assignment(session.assignment) do
      {:ok, session}
    end
  end

  defp claim_or_reconnect_session(repo, secret, proof_hash, claimed_by) do
    case claim_access_grant(repo, secret, claimed_by: claimed_by) do
      {:ok, assignment} ->
        with :ok <- require_mcp_claimable_assignment(assignment) do
          {:ok, Session.new(assignment, proof_hash: proof_hash)}
        end

      {:error, :already_claimed} ->
        reconnect_claimed_session(repo, proof_hash, claimed_by)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_access_grant(repo, secret, opts) do
    claim = &AccessGrantService.claim/3
    claim.(repo, secret, opts)
  end

  defp reconnect_claimed_session(repo, proof_hash, claimed_by) do
    with {:ok, grant} <- AccessGrantRepository.find_by_secret_hash(repo, proof_hash),
         :ok <- require_same_claim_owner(grant, claimed_by),
         :ok <- AccessGrantService.require_live_package_authority(repo, grant),
         {:ok, session} <- Session.from_grant(grant, DateTime.utc_now(:microsecond), proof_hash: proof_hash),
         :ok <- require_mcp_claimable_assignment(session.assignment) do
      {:ok, session}
    end
  end

  defp require_same_claim_owner(%{claimed_by: claimed_by}, claimed_by), do: :ok
  defp require_same_claim_owner(_grant, _claimed_by), do: {:error, :already_claimed}

  defp require_full_secret(secret) do
    if String.length(secret) == 4 do
      {:error, :display_key_only}
    else
      :ok
    end
  end

  defp require_mcp_claimable_secret(repo, proof_hash) do
    with {:ok, grant} <- AccessGrantRepository.find_by_secret_hash(repo, proof_hash) do
      with :ok <- AccessGrantService.require_live_package_authority(repo, grant) do
        require_mcp_claimable_assignment(grant)
      end
    end
  end

  defp require_worker_assignment(%{grant_role: "worker"}), do: :ok
  defp require_worker_assignment(_assignment), do: {:error, :worker_grant_required}

  defp require_architect_assignment(%{grant_role: "architect"}), do: :ok
  defp require_architect_assignment(_assignment), do: {:error, :architect_grant_required}

  defp require_mcp_claimable_assignment(%{grant_role: role}) when role in ["worker", "architect"], do: :ok
  defp require_mcp_claimable_assignment(_assignment), do: {:error, :unsupported_grant_role}

  defp require_assignment_introspection(%{grant_role: role}) when role in ["worker", "architect"], do: :ok
  defp require_assignment_introspection(_assignment), do: {:error, :unsupported_grant_role}

  defp require_architect_capability(%{capabilities: capabilities}, capability) when is_list(capabilities) do
    if capability in capabilities do
      :ok
    else
      {:error, :insufficient_capability}
    end
  end

  defp require_architect_capability(_assignment, _capability), do: {:error, :insufficient_capability}

  defp authorize_architect_tool_call(%__MODULE__{session: nil}, name) do
    {:error, -32_001, "Unauthorized", %{"resource" => name, "reason" => "claim_required", "action" => "claim_work_key"}}
  end

  defp authorize_architect_tool_call(%__MODULE__{config: config, session: session}, name) do
    with {:ok, _session} <- architect_session(config.repo, session, architect_tool_required_capabilities(name)) do
      :ok
    end
  end

  defp architect_tool_required_capabilities("read_child_status"), do: ["read:child_progress", "read:child_findings"]
  defp architect_tool_required_capabilities(name), do: [architect_tool_capability(name)]

  defp claim_error(:database_busy), do: service_error(:database_busy, "claim_work_key")
  defp claim_error({:storage_failed, _reason} = reason), do: service_error(reason, "claim_work_key")
  defp claim_error({:migration_failed, _reason} = reason), do: service_error(reason, "claim_work_key")
  defp claim_error(reason), do: {:error, -32_001, "Unauthorized", %{"tool" => "claim_work_key", "reason" => reason_text(reason)}}

  defp private_handoff_claim_error(:database_busy), do: service_error(:database_busy, "claim_private_handoff")
  defp private_handoff_claim_error({:storage_failed, _reason} = reason), do: service_error(reason, "claim_private_handoff")
  defp private_handoff_claim_error({:migration_failed, _reason} = reason), do: service_error(reason, "claim_private_handoff")

  defp private_handoff_claim_error(reason) do
    {:error, -32_001, "Unauthorized", %{"tool" => "claim_private_handoff", "reason" => reason_text(reason)}}
  end

  defp prepare_worker_tool_call(%__MODULE__{} = server, params, name) do
    with :ok <- require_tool_arguments_object(params, name),
         :ok <- preauthorize_worker_tool_call(server, name),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, name),
         :ok <- authorize_worker_tool_call(server, name) do
      worker_tool_arguments(params, name)
    end
  end

  defp prepare_architect_tool_call(%__MODULE__{} = server, params, name) do
    with :ok <- require_tool_arguments_object(params, name),
         :ok <- preauthorize_architect_tool_call(server, name),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, name),
         :ok <- authorize_architect_tool_call(server, name) do
      architect_tool_arguments(params, name)
    end
  end

  defp prepare_bootstrap_tool_call(%__MODULE__{} = server, params, name) do
    with :ok <- require_tool_arguments_object(params, name),
         :ok <- authorize_bootstrap_tool_call(server, name),
         :ok <- prepare_mcp_repository_for_tool(server.config.repo, name) do
      bootstrap_tool_arguments(params, name)
    end
  end

  defp require_tool_arguments_object(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) -> :ok
      _arguments -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp preauthorize_worker_tool_call(%__MODULE__{session: session}, "get_current_assignment") do
    with {:ok, session} <- Auth.require_session(session) do
      require_assignment_introspection(session.assignment)
    end
  end

  defp preauthorize_worker_tool_call(%__MODULE__{session: session}, _name) do
    with {:ok, session} <- Auth.require_session(session) do
      require_worker_assignment(session.assignment)
    end
  end

  defp preauthorize_architect_tool_call(%__MODULE__{session: nil} = server, name) do
    authorize_architect_tool_call(server, name)
  end

  defp preauthorize_architect_tool_call(%__MODULE__{session: session}, name) do
    with {:ok, session} <- Auth.require_session(session),
         :ok <- require_architect_assignment(session.assignment) do
      require_architect_capabilities(session.assignment, architect_tool_required_capabilities(name))
    end
  end

  defp authorize_bootstrap_tool_call(%__MODULE__{session_refresh_required: true}, tool) do
    {:error, -32_001, "Unauthorized", %{"tool" => tool, "reason" => "claim_required", "action" => "claim_private_handoff"}}
  end

  defp authorize_bootstrap_tool_call(%__MODULE__{session: nil}, _tool), do: :ok

  defp authorize_bootstrap_tool_call(%__MODULE__{}, tool) do
    {:error, -32_001, "Unauthorized", %{"tool" => tool, "reason" => "bootstrap_tools_require_unbound_session"}}
  end

  defp prepare_mcp_repository(repo), do: Repository.ensure_migrated(repo)

  defp prepare_mcp_repository_for_tool(repo, tool) do
    case prepare_mcp_repository(repo) do
      :ok -> :ok
      {:error, reason} -> service_error(reason, tool)
    end
  end

  defp bootstrap_tool("create_work_request", arguments, %__MODULE__{config: config}) do
    with {:ok, requested_claimed_by} <- create_work_request_requested_claimed_by(arguments),
         {:ok, attrs} <- create_work_request_attrs(arguments, requested_claimed_by),
         {:ok, work_request} <- WorkRequestService.create(config.repo, attrs) do
      effective_claimed_by = requested_claimed_by || ArchitectHandoff.claimed_by()

      {:ok, tool_result(create_work_request_handoff_payload(config, work_request, effective_claimed_by))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => reason}}
      {:error, reason} -> create_work_request_error(reason)
    end
  end

  defp create_work_request_attrs(arguments, claimed_by) do
    with {:ok, repo} <- required_argument(arguments, "repo"),
         {:ok, base_branch} <- required_argument(arguments, "base_branch"),
         {:ok, title} <- required_argument(arguments, "title"),
         {:ok, request_kind} <- required_argument(arguments, "request_kind"),
         {:ok, description} <- create_work_request_description(arguments),
         {:ok, workflow_mode} <- optional_string_argument(arguments, "workflow_mode", "architect_led_feature_branch"),
         {:ok, constraints} <- optional_object_argument(arguments, "constraints"),
         {:ok, status} <- optional_string_argument(arguments, "status", "ready_for_clarification"),
         {:ok, creator_kind} <- create_work_request_creator_kind(arguments),
         {:ok, creator_name} <- create_work_request_creator_name(arguments, claimed_by),
         {:ok, created_via} <- optional_string_argument(arguments, "created_via", "mcp") do
      {:ok,
       %{
         "repo" => repo,
         "base_branch" => base_branch,
         "title" => title,
         "work_type" => request_kind,
         "human_description" => description,
         "desired_dispatch_shape" => workflow_mode,
         "constraints" => constraints || %{},
         "status" => status,
         "creator_kind" => creator_kind,
         "creator_name" => creator_name,
         "created_via" => created_via
       }}
    end
  end

  defp create_work_request_description(arguments) do
    result =
      case optional_string_argument(arguments, "human_description") do
        {:ok, nil} -> optional_string_argument(arguments, "description")
        {:ok, description} -> {:ok, description}
        {:tool_error, reason} -> {:tool_error, reason}
      end

    case result do
      {:ok, nil} -> {:tool_error, "missing_description"}
      other -> other
    end
  end

  defp create_work_request_requested_claimed_by(arguments) do
    optional_string_argument(arguments, "claimed_by")
  end

  defp create_work_request_creator_kind(arguments) do
    case optional_string_argument(arguments, "creator_kind") do
      {:ok, nil} -> optional_string_argument(arguments, "created_by_kind", "agent")
      {:ok, kind} -> {:ok, kind}
      {:tool_error, reason} -> {:tool_error, reason}
    end
  end

  defp create_work_request_creator_name(arguments, claimed_by) do
    case optional_string_argument(arguments, "creator_name") do
      {:ok, nil} ->
        case optional_string_argument(arguments, "created_by_name") do
          {:ok, nil} -> {:ok, claimed_by || "mcp-agent"}
          result -> result
        end

      result ->
        result
    end
  end

  defp create_work_request_handoff_payload(%Config{} = config, %WorkRequest{} = work_request, claimed_by) do
    case create_work_request_architect_handoff(config, work_request, claimed_by) do
      {:ok, handoff} ->
        %{
          "status" => "created",
          "work_request" => work_request_payload(work_request),
          "architect_handoff" => json_safe_payload(handoff),
          "claim" => %{"tool" => "claim_private_handoff", "claimed_by" => claimed_by},
          "launch_prompt" => Map.get(handoff, :prompt)
        }

      {:tool_error, reason} ->
        create_work_request_partial_handoff_payload(work_request, reason)

      {:error, reason} ->
        create_work_request_partial_handoff_payload(work_request, reason)
    end
  end

  defp create_work_request_partial_handoff_payload(%WorkRequest{} = work_request, reason) do
    %{
      "status" => "partial_success",
      "work_request" => work_request_payload(work_request),
      "architect_handoff" => nil,
      "handoff_error" => %{
        "reason" => reason_text(reason),
        "message" => ArchitectHandoff.error_message(reason)
      },
      "retry" => %{
        "type" => "manual_architect_handoff_replay",
        "work_request_id" => work_request.id,
        "operator_action" => "prepare_architect_handoff"
      }
    }
  end

  defp create_work_request_architect_handoff(%Config{} = config, %WorkRequest{} = work_request, claimed_by) do
    with {:ok, handoff_opts} <- create_work_request_handoff_opts(config, claimed_by) do
      ArchitectHandoff.create_or_replay(config.repo, work_request.id,
        local_operator?: true,
        secret_handoff_opts: handoff_opts
      )
    end
  end

  defp create_work_request_handoff_opts(%Config{} = config, claimed_by) do
    with {:ok, repo_root} <- config_repo_root(config),
         :ok <- validate_child_secret_handoff_repo_root(repo_root, "local-private-file") do
      opts =
        [
          mode: "local-private-file",
          repo_root: repo_root,
          claimed_by: claimed_by
        ]
        |> put_optional_handoff_opt(:store_dir, Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir))

      {:ok, put_optional_handoff_opt(opts, :database, create_work_request_handoff_database(config))}
    end
  end

  defp create_work_request_handoff_database(%Config{} = config) do
    case dispatch_handoff_database(config.database, config.repo) do
      {:ok, database} -> database
      _result -> nil
    end
  end

  defp architect_tool("list_work_requests", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "read:work_request"),
         {:ok, status} <- optional_work_request_status(arguments),
         {:ok, filters, scope} <- scoped_work_request_filters(config.repo, session),
         filters = work_request_list_filters(filters, status),
         {:ok, work_requests} <- WorkRequestService.list(config.repo, work_request_repository_filters(filters)) do
      work_requests = filter_scoped_work_requests(work_requests, filters)
      cards = work_request_cards(work_requests)

      {:ok,
       tool_result(%{
         "work_requests" => cards,
         "total_count" => length(cards),
         "scope" => scope,
         "filters" => work_request_filter_payload(status)
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "list_work_requests", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "list_work_requests")
    end
  end

  defp architect_tool("read_work_request", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "read:work_request"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, filters, scope} <- scoped_work_request_filters(config.repo, session),
         {:ok, work_request} <- scoped_work_request(config.repo, work_request_id, filters),
         {:ok, payload} <- work_request_detail_payload(config.repo, work_request) do
      {:ok, tool_result(Map.put(payload, "scope", scope))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_work_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_work_request")
      {:error, reason} -> architect_error(reason, "read_work_request")
    end
  end

  defp architect_tool("list_guidance_requests", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "read:guidance_request"),
         {:ok, status} <- optional_guidance_request_status(arguments),
         {:ok, work_package_id} <- optional_string_argument(arguments, "work_package_id"),
         {:ok, filters, scope} <- scoped_guidance_request_filters(config.repo, session),
         filters = guidance_request_list_filters(filters, status, work_package_id),
         {:ok, guidance_requests} <- GuidanceRequestService.list_visible_to_architect(config.repo, filters) do
      cards = guidance_request_cards(guidance_requests)

      {:ok,
       tool_result(%{
         "guidance_requests" => cards,
         "total_count" => length(cards),
         "scope" => scope,
         "filters" => guidance_request_filter_payload(status, work_package_id)
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "list_guidance_requests", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "list_guidance_requests")
    end
  end

  defp architect_tool("answer_guidance_request", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "write:guidance_request"),
         {:ok, guidance_request_id} <- required_argument(arguments, "guidance_request_id"),
         {:ok, answer} <- required_argument(arguments, "answer"),
         {:ok, answered_by} <- optional_string_argument(arguments, "answered_by", session_claimed_by(session)),
         {:ok, filters, scope} <- scoped_guidance_request_filters(config.repo, session),
         {:ok, _guidance_request} <- GuidanceRequestService.get_visible_to_architect(config.repo, guidance_request_id, filters),
         {:ok, guidance_request} <-
           GuidanceRequestService.answer(config.repo, guidance_request_id, %{
             "answer" => answer,
             "answered_by" => answered_by,
             "answered_at" => DateTime.utc_now(:microsecond)
           }) do
      {:ok,
       tool_result(%{
         "guidance_request" => guidance_request_payload(guidance_request),
         "scope" => scope,
         "status" => %{"guidance_request_status" => guidance_request.status}
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "answer_guidance_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("answer_guidance_request")
      {:error, reason} -> architect_error(reason, "answer_guidance_request")
    end
  end

  defp architect_tool("escalate_guidance_request", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "write:guidance_request"),
         {:ok, guidance_request_id} <- required_argument(arguments, "guidance_request_id"),
         {:ok, reason} <- required_argument(arguments, "reason"),
         {:ok, recommended_language} <- required_argument(arguments, "recommended_language"),
         {:ok, decision_prompt} <- optional_decision_prompt_argument(arguments, "decision_prompt"),
         {:ok, result} <-
           escalate_guidance_request_transaction(
             config.repo,
             session,
             guidance_request_id,
             reason,
             recommended_language,
             decision_prompt
           ) do
      {:ok, tool_result(result)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "escalate_guidance_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("escalate_guidance_request")
      {:error, reason} -> architect_error(reason, "escalate_guidance_request")
    end
  end

  defp architect_tool("set_work_request_status", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "write:work_request"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, next_status} <- required_argument(arguments, "next_status"),
         {:ok, filters, scope} <- scoped_work_request_filters(config.repo, session),
         {:ok, _work_request} <- scoped_work_request(config.repo, work_request_id, filters),
         {:ok, updated_work_request} <- WorkRequestService.update_status(config.repo, work_request_id, current_status, next_status) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "scope" => scope,
         "status" => %{
           "previous_status" => current_status,
           "current_status" => updated_work_request.status
         }
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "set_work_request_status", "reason" => reason}}
      {:error, :not_found} -> not_found_error("set_work_request_status")
      {:error, reason} -> architect_error(reason, "set_work_request_status")
    end
  end

  defp architect_tool("ask_work_request_question", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "write:work_request"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, category} <- required_argument(arguments, "category"),
         {:ok, question} <- required_argument(arguments, "question"),
         {:ok, why_needed} <- required_argument(arguments, "why_needed"),
         {:ok, decision_prompt} <- optional_decision_prompt_argument(arguments, "decision_prompt"),
         {:ok, asked_by_agent_run_id} <- optional_string_argument(arguments, "asked_by_agent_run_id"),
         {:ok, filters, scope} <- scoped_work_request_filters(config.repo, session),
         {:ok, _work_request} <- scoped_work_request(config.repo, work_request_id, filters),
         {:ok, question_record} <-
           WorkRequestService.ask_question(
             config.repo,
             work_request_id,
             optional_put(
               %{
                 "category" => category,
                 "question" => question,
                 "why_needed" => why_needed
               },
               "decision_prompt",
               decision_prompt
             )
             |> optional_put(
               "asked_by_agent_run_id",
               asked_by_agent_run_id
             )
           ),
         {:ok, updated_work_request} <- scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "clarification_question" => clarification_question_payload(question_record),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "ask_work_request_question", "reason" => reason}}
      {:error, :not_found} -> not_found_error("ask_work_request_question")
      {:error, reason} -> architect_error(reason, "ask_work_request_question")
    end
  end

  defp architect_tool("answer_work_request_question", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "write:work_request"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, question_id} <- required_argument(arguments, "question_id"),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, answer} <- required_argument(arguments, "answer"),
         {:ok, answered_by} <- optional_string_argument(arguments, "answered_by", session_claimed_by(session)),
         {:ok, filters, scope} <- scoped_work_request_filters(config.repo, session),
         {:ok, _work_request} <- scoped_work_request(config.repo, work_request_id, filters),
         {:ok, _question} <- scoped_work_request_question(config.repo, work_request_id, question_id),
         {:ok, question_record} <-
           WorkRequestService.answer_question(config.repo, question_id, current_status, %{
             "answer" => answer,
             "answered_by" => answered_by
           }),
         {:ok, updated_work_request} <- scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "clarification_question" => clarification_question_payload(question_record),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "previous_question_status" => current_status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "answer_work_request_question", "reason" => reason}}
      {:error, :not_found} -> not_found_error("answer_work_request_question")
      {:error, reason} -> architect_error(reason, "answer_work_request_question")
    end
  end

  defp architect_tool("close_work_request_question", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "write:work_request"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, question_id} <- required_argument(arguments, "question_id"),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, filters, scope} <- scoped_work_request_filters(config.repo, session),
         {:ok, _work_request} <- scoped_work_request(config.repo, work_request_id, filters),
         {:ok, _question} <- scoped_work_request_question(config.repo, work_request_id, question_id),
         {:ok, question_record} <- WorkRequestService.close_question(config.repo, question_id, current_status),
         {:ok, updated_work_request} <- scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "clarification_question" => clarification_question_payload(question_record),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "previous_question_status" => current_status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "close_work_request_question", "reason" => reason}}
      {:error, :not_found} -> not_found_error("close_work_request_question")
      {:error, reason} -> architect_error(reason, "close_work_request_question")
    end
  end

  defp architect_tool("record_work_request_decision", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "write:work_request"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, source_type} <- required_argument(arguments, "source_type"),
         {:ok, decision} <- required_argument(arguments, "decision"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, scope_impact} <- required_argument(arguments, "scope_impact"),
         {:ok, created_by} <- required_argument(arguments, "created_by"),
         {:ok, source_id} <- optional_string_argument(arguments, "source_id"),
         {:ok, filters, scope} <- scoped_work_request_filters(config.repo, session),
         {:ok, _work_request} <- scoped_work_request(config.repo, work_request_id, filters),
         {:ok, decision_record} <-
           WorkRequestService.record_decision(
             config.repo,
             work_request_id,
             optional_put(
               %{
                 "source_type" => source_type,
                 "decision" => decision,
                 "rationale" => rationale,
                 "scope_impact" => scope_impact,
                 "created_by" => created_by
               },
               "source_id",
               source_id
             )
           ),
         {:ok, updated_work_request} <- scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "decision_log_entry" => decision_log_entry_payload(decision_record),
         "scope" => scope,
         "status" => %{"work_request_status" => updated_work_request.status}
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "record_work_request_decision", "reason" => reason}}
      {:error, :not_found} -> not_found_error("record_work_request_decision")
      {:error, reason} -> architect_error(reason, "record_work_request_decision")
    end
  end

  defp architect_tool("add_work_request_planned_slice", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "write:work_request"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, title} <- required_argument(arguments, "title"),
         {:ok, goal} <- required_argument(arguments, "goal"),
         {:ok, work_package_kind} <- required_argument(arguments, "work_package_kind"),
         {:ok, target_base_branch} <- required_argument(arguments, "target_base_branch"),
         {:ok, owned_file_globs} <- required_string_array(arguments, "owned_file_globs"),
         {:ok, forbidden_file_globs} <- required_string_array(arguments, "forbidden_file_globs"),
         {:ok, acceptance_criteria} <- required_string_array(arguments, "acceptance_criteria"),
         {:ok, validation_steps} <- required_string_array(arguments, "validation_steps"),
         {:ok, review_lanes} <- required_string_array(arguments, "review_lanes"),
         {:ok, stop_conditions} <- required_string_array(arguments, "stop_conditions"),
         {:ok, branch_pattern} <- optional_string_argument(arguments, "branch_pattern"),
         {:ok, filters, scope} <- scoped_work_request_filters(config.repo, session),
         {:ok, work_request} <- scoped_work_request(config.repo, work_request_id, filters),
         :ok <- require_planned_slice_authoring_status(work_request.status),
         :ok <- require_planned_slice_target_base_branch_scope(work_request, target_base_branch),
         {:ok, planned_slice} <-
           WorkRequestService.add_planned_slice(
             config.repo,
             work_request_id,
             optional_put(
               %{
                 "title" => title,
                 "goal" => goal,
                 "work_package_kind" => work_package_kind,
                 "target_base_branch" => target_base_branch,
                 "owned_file_globs" => owned_file_globs,
                 "forbidden_file_globs" => forbidden_file_globs,
                 "acceptance_criteria" => acceptance_criteria,
                 "validation_steps" => validation_steps,
                 "review_lanes" => review_lanes,
                 "stop_conditions" => stop_conditions
               },
               "branch_pattern",
               branch_pattern
             )
           ),
         {:ok, updated_work_request} <- scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "planned_slice" => planned_slice_payload(planned_slice),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "planned_slice_status" => planned_slice.status
         }
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "add_work_request_planned_slice", "reason" => reason}}
      {:error, %Ecto.Changeset{}} -> {:error, -32_602, "Invalid params", %{"tool" => "add_work_request_planned_slice", "reason" => "invalid_planned_slice"}}
      {:error, :not_found} -> not_found_error("add_work_request_planned_slice")
      {:error, reason} -> architect_error(reason, "add_work_request_planned_slice")
    end
  end

  defp architect_tool("approve_work_request_planned_slice", arguments, %__MODULE__{config: config, session: session}) do
    mutate_work_request_planned_slice_status("approve_work_request_planned_slice", arguments, config.repo, session, "approved")
  end

  defp architect_tool("skip_work_request_planned_slice", arguments, %__MODULE__{config: config, session: session}) do
    mutate_work_request_planned_slice_status("skip_work_request_planned_slice", arguments, config.repo, session, "skipped")
  end

  defp architect_tool("mark_work_request_sliced", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "write:work_request"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, filters, scope} <- scoped_work_request_filters(config.repo, session),
         {:ok, _work_request} <- scoped_work_request(config.repo, work_request_id, filters),
         {:ok, updated_work_request} <- WorkRequestService.mark_sliced(config.repo, work_request_id, current_status) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "scope" => scope,
         "status" => %{
           "previous_status" => current_status,
           "current_status" => updated_work_request.status
         }
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "mark_work_request_sliced", "reason" => reason}}
      {:error, :not_found} -> not_found_error("mark_work_request_sliced")
      {:error, reason} -> architect_error(reason, "mark_work_request_sliced")
    end
  end

  defp architect_tool("dispatch_work_request_planned_slice", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "dispatch:work_request"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, planned_slice_id} <- required_argument(arguments, "planned_slice_id"),
         {:ok, claimed_by} <- required_argument(arguments, "claimed_by"),
         {:ok, filters, scope} <- scoped_work_request_filters(config.repo, session),
         {:ok, work_request} <- scoped_work_request(config.repo, work_request_id, filters),
         {:ok, planned_slice} <- scoped_work_request_planned_slice(config.repo, work_request_id, planned_slice_id),
         :ok <- require_planned_slice_target_base_branch_scope(work_request, planned_slice.target_base_branch),
         :ok <- require_approved_dispatch_planned_slice(planned_slice),
         {:ok, handoff_opts} <- dispatch_planned_slice_handoff_opts(config, arguments, claimed_by),
         {:ok, dispatch} <- PlannedSliceDispatch.dispatch(config.repo, work_request_id, planned_slice_id, handoff_opts) do
      {:ok, tool_result(dispatch_work_request_planned_slice_payload(dispatch, scope))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "dispatch_work_request_planned_slice", "reason" => reason}}
      {:error, :not_found} -> not_found_error("dispatch_work_request_planned_slice")
      {:error, reason} -> dispatch_work_request_planned_slice_error(reason)
    end
  end

  defp architect_tool("prepare_work_package_worktree", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "dispatch:work_request"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, repo_root} <- required_argument(arguments, "repo_root"),
         {:ok, base_branch} <- required_argument(arguments, "base_branch"),
         {:ok, branch} <- required_argument(arguments, "branch"),
         {:ok, _work_package, scope} <- scoped_worktree_work_package(config.repo, session, work_package_id),
         :ok <- require_worktree_repo_root_scope(repo_root, config.repo_root),
         {:ok, result} <-
           WorkPackageService.prepare_worktree(config.repo, work_package_id, %{
             "repo_root" => repo_root,
             "base_branch" => base_branch,
             "branch" => branch
           }),
         {:ok, audit_event} <- append_worktree_lifecycle_audit(config.repo, session, work_package_id, "prepare_work_package_worktree", result) do
      {:ok, tool_result(worktree_lifecycle_payload(result, scope, audit_event))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "prepare_work_package_worktree", "reason" => reason}}
      {:error, :not_found} -> not_found_error("prepare_work_package_worktree")
      {:error, reason} -> architect_error(reason, "prepare_work_package_worktree")
    end
  end

  defp architect_tool("cleanup_work_package_worktree", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "dispatch:work_request"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, _work_package, scope} <- scoped_worktree_work_package(config.repo, session, work_package_id),
         {:ok, result} <- WorkPackageService.cleanup_worktree(config.repo, work_package_id),
         {:ok, audit_event} <- maybe_append_cleanup_worktree_audit(config.repo, session, work_package_id, result) do
      {:ok, tool_result(worktree_lifecycle_payload(result, scope, audit_event))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "cleanup_work_package_worktree", "reason" => reason}}
      {:error, :not_found} -> not_found_error("cleanup_work_package_worktree")
      {:error, reason} -> architect_error(reason, "cleanup_work_package_worktree")
    end
  end

  defp architect_tool("read_child_status", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, ["read:child_progress", "read:child_findings"]),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         :ok <- require_architect_child_status_scope(config.repo, session, work_package_id),
         {:ok, summary} <- PlanningRepository.get_status_summary(config.repo, work_package_id) do
      {:ok,
       tool_result(%{
         "work_package" => work_package_payload(summary.work_package),
         "plan_version" => plan_version(summary.plan_nodes),
         "finding_count" => summary.finding_count,
         "progress_event_count" => summary.progress_event_count,
         "artifact_count" => summary.artifact_count
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_child_status", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "read_child_status")
    end
  end

  defp architect_tool("create_child_work_package", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "create:child_work_package"),
         {:ok, package} <- required_object(arguments, "package"),
         {:ok, work_package} <- create_child_work_package_transaction(config.repo, session, package) do
      {:ok, tool_result(%{"work_package" => child_work_package_payload(work_package)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "create_child_work_package", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "create_child_work_package")
    end
  end

  defp architect_tool("mint_child_worker_key", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "mint:child_worker_key"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, template} <- required_object(arguments, "template"),
         {:ok, payload} <- mint_child_worker_key(config, session, work_package_id, template) do
      {:ok, tool_result(payload)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "mint_child_worker_key", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "mint_child_worker_key")
    end
  end

  defp architect_tool("revoke_child_worker_key", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "revoke:child_worker_key"),
         {:ok, grant_id} <- required_revoke_child_worker_string(arguments, "grant_id"),
         {:ok, reason} <- required_revoke_child_worker_string(arguments, "reason"),
         {:ok, payload} <- revoke_child_worker_key_transaction(config.repo, session, grant_id, reason) do
      {:ok, tool_result(payload)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "revoke_child_worker_key", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "revoke_child_worker_key")
    end
  end

  defp architect_tool("approve_scope_expansion", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "approve:scope_expansion"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         :ok <- require_architect_work_package_scope(session, work_package_id),
         {:ok, allowed_file_globs} <- required_string_list(arguments, "allowed_file_globs"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, result} <- approve_scope_expansion_transaction(config.repo, session, arguments, allowed_file_globs, rationale) do
      {:ok, tool_result(result)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "approve_scope_expansion", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "approve_scope_expansion")
    end
  end

  defp architect_tool("read_phase_board", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "read:phase"),
         {:ok, phase_id} <- required_argument(arguments, "phase_id"),
         :ok <- require_architect_phase_scope(config.repo, session, phase_id),
         {:ok, grant} <- require_architect_phase_board_grant(config.repo, session, phase_id),
         {:ok, board} <- Dashboard.phase_board_for_grant(config.repo, phase_id, grant) do
      {:ok, tool_result(json_safe_payload(board))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_phase_board", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "read_phase_board")
    end
  end

  defp architect_tool("approve_child_ready_state", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "approve:child_ready_state"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, request_id} <- optional_request_id(arguments, "request_id"),
         {:ok, result} <-
           approve_child_ready_state_transaction(config.repo, session, work_package_id, rationale, request_id) do
      {:ok, tool_result(result)}
    else
      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "approve_child_ready_state", "reason" => reason}}

      {:error, {:readiness_failed, missing, reasons}} ->
        {:error, -32_602, "Invalid params", %{"tool" => "approve_child_ready_state", "reason" => "readiness_failed", "missing" => missing, "reasons" => reasons}}

      {:error, reason} ->
        architect_error(reason, "approve_child_ready_state")
    end
  end

  defp architect_tool("merge_child_into_phase", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- architect_session(config.repo, session, "merge:child_into_phase"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, merge_artifact} <- required_object(arguments, "merge_artifact"),
         {:ok, result} <- merge_child_into_phase_transaction(config.repo, session, work_package_id, merge_artifact) do
      {:ok, tool_result(result)}
    else
      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "merge_child_into_phase", "reason" => reason}}

      {:error, reason} ->
        architect_error(reason, "merge_child_into_phase")
    end
  end

  defp architect_tool(name, arguments, %__MODULE__{config: config, session: session}) when name in @phase7_stub_architect_tools do
    with {:ok, session} <- architect_session(config.repo, session, architect_tool_capability(name)),
         :ok <- require_architect_target_scope(config.repo, session, arguments) do
      phase7_not_implemented(name)
    else
      {:error, reason} -> architect_error(reason, name)
    end
  end

  defp mutate_work_request_planned_slice_status(tool, arguments, repo, session, next_status) do
    with {:ok, session} <- architect_session(repo, session, "write:work_request"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, planned_slice_id} <- required_argument(arguments, "planned_slice_id"),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, filters, scope} <- scoped_work_request_filters(repo, session),
         {:ok, work_request} <- scoped_work_request(repo, work_request_id, filters),
         :ok <- require_planned_slice_authoring_status(work_request.status),
         {:ok, _planned_slice} <- scoped_work_request_planned_slice(repo, work_request_id, planned_slice_id),
         {:ok, planned_slice} <-
           update_work_request_planned_slice_status(
             repo,
             work_request_id,
             planned_slice_id,
             current_status,
             next_status
           ),
         {:ok, updated_work_request} <- scoped_work_request(repo, work_request_id, filters) do
      {:ok,
       tool_result(%{
         "work_request" => work_request_mutation_payload(updated_work_request),
         "planned_slice" => planned_slice_payload(planned_slice),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "previous_planned_slice_status" => current_status,
           "planned_slice_status" => planned_slice.status
         }
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  defp update_work_request_planned_slice_status(repo, work_request_id, planned_slice_id, current_status, "approved") do
    WorkRequestService.approve_planned_slice(repo, work_request_id, planned_slice_id, current_status)
  end

  defp update_work_request_planned_slice_status(repo, work_request_id, planned_slice_id, current_status, "skipped") do
    WorkRequestService.skip_planned_slice(repo, work_request_id, planned_slice_id, current_status)
  end

  defp dispatch_planned_slice_handoff_opts(%Config{} = config, arguments, claimed_by) do
    with {:ok, repo_root} <- dispatch_planned_slice_repo_root(config, arguments),
         {:ok, secret_handoff} <- optional_string_argument(arguments, "secret_handoff", "auto"),
         {:ok, secret_store_dir} <- optional_string_argument(arguments, "secret_store_dir"),
         :ok <- validate_child_secret_handoff_mode(secret_handoff),
         :ok <- validate_child_secret_handoff_repo_root(repo_root, secret_handoff),
         {:ok, database} <- dispatch_handoff_database(config.database, config.repo) do
      {:ok,
       [
         repo_root: repo_root,
         claimed_by: claimed_by
       ]
       |> put_optional_handoff_opt(:database, database)
       |> put_optional_handoff_opt(:mode, normalize_child_secret_handoff_mode(secret_handoff))
       |> put_optional_handoff_opt(:store_dir, secret_store_dir)}
    end
  end

  defp dispatch_planned_slice_repo_root(%Config{} = config, arguments) do
    case optional_string_argument(arguments, "repo_root") do
      {:ok, nil} -> config_repo_root(config)
      {:ok, repo_root} -> {:ok, Path.expand(repo_root)}
      {:tool_error, reason} -> {:tool_error, reason}
    end
  end

  defp dispatch_handoff_database(nil, repo) do
    with {:ok, live_database} <- live_file_backed_dispatch_database(repo),
         configured_database <- configured_repo_dispatch_database(repo) do
      dispatch_handoff_database_for_default_config(configured_database, live_database)
    end
  end

  defp dispatch_handoff_database(database, repo) when is_binary(database) do
    database
    |> String.trim()
    |> dispatch_handoff_database_for_trimmed_config(database, repo)
  end

  defp dispatch_handoff_database_for_default_config({:ok, configured_database}, live_database) do
    cond do
      configured_dispatch_database_matches_live?(configured_database, live_database) and
          writable_dispatch_database?(configured_database) ->
        {:ok, configured_database}

      configured_dispatch_database_matches_live?(configured_database, live_database) ->
        {:tool_error, "read_only_database"}

      true ->
        {:ok, live_database}
    end
  end

  defp dispatch_handoff_database_for_default_config(:none, live_database), do: {:ok, live_database}

  defp dispatch_handoff_database_for_trimmed_config("", _database, repo), do: dispatch_handoff_database(nil, repo)

  defp dispatch_handoff_database_for_trimmed_config(_trimmed_database, database, repo) do
    dispatch_handoff_database_for_configured_path(database, repo)
  end

  defp dispatch_handoff_database_for_configured_path(database, repo) when is_binary(database) do
    with false <- Repo.memory_database?(database),
         {:ok, live_database} <- live_file_backed_dispatch_database(repo) do
      database
      |> normalize_configured_dispatch_database()
      |> configured_dispatch_database_result(live_database)
    else
      true -> {:tool_error, "file_backed_database_required"}
      error -> error
    end
  end

  defp configured_dispatch_database_result(configured_database, live_database) do
    if configured_dispatch_database_matches_live?(configured_database, live_database) and
         writable_dispatch_database?(configured_database) do
      {:ok, configured_database}
    else
      configured_dispatch_database_error(configured_database, live_database)
    end
  end

  defp normalize_configured_dispatch_database("file:" <> _uri = database) do
    normalize_sqlite_file_uri(database)
  end

  defp normalize_configured_dispatch_database(database) when is_binary(database) do
    if Path.type(database) == :absolute do
      database
    else
      Path.expand(database)
    end
  end

  defp normalize_sqlite_file_uri(database) do
    case Repo.sqlite_file_uri_path(database) do
      path when is_binary(path) and path != "" ->
        put_sqlite_file_uri_path(database, Path.expand(path))

      _path ->
        database
    end
  end

  defp put_sqlite_file_uri_path("file:" <> uri, expanded_path) do
    encoded_path = encode_sqlite_file_uri_path(expanded_path)

    case String.split(uri, "?", parts: 2) do
      [_uri_path, query] -> "file:" <> encoded_path <> "?" <> query
      [_uri_path] -> "file:" <> encoded_path
    end
  end

  defp encode_sqlite_file_uri_path(path) do
    path
    |> String.replace("\\", "/")
    |> URI.encode(&sqlite_file_uri_path_char?/1)
  end

  defp sqlite_file_uri_path_char?(char), do: URI.char_unreserved?(char) or char in [?/, ?:]

  defp writable_dispatch_database?("file:" <> _uri = database) do
    query_params = sqlite_file_uri_query_params(database)
    mode = query_params |> Map.get("mode", "") |> String.downcase()

    mode not in ["ro", "memory"] and not truthy_sqlite_uri_param?(Map.get(query_params, "immutable"))
  end

  defp writable_dispatch_database?(_database), do: true

  defp configured_dispatch_database_error(configured_database, live_database) do
    if configured_dispatch_database_matches_live?(configured_database, live_database) do
      {:tool_error, "read_only_database"}
    else
      {:tool_error, "database_scope_mismatch"}
    end
  end

  defp configured_dispatch_database_matches_live?("file:" <> _uri = database, live_database) do
    case Repo.sqlite_file_uri_path(database) do
      path when is_binary(path) and path != "" ->
        Repo.same_database_path?(path, live_database)

      _path ->
        false
    end
  end

  defp configured_dispatch_database_matches_live?(database, live_database) do
    Repo.same_database_path?(database, live_database)
  end

  defp configured_repo_dispatch_database(repo) when is_atom(repo) do
    cond do
      function_exported?(repo, :database_path_if_present, 0) ->
        repo.database_path_if_present()
        |> configured_repo_dispatch_database_value()

      function_exported?(repo, :database_path, 0) ->
        repo.database_path()
        |> configured_repo_dispatch_database_value()

      true ->
        :none
    end
  rescue
    _error -> :none
  catch
    _kind, _reason -> :none
  end

  defp configured_repo_dispatch_database(_repo), do: :none

  defp configured_repo_dispatch_database_value(database) when is_binary(database) do
    if String.trim(database) == "" do
      :none
    else
      configured_repo_dispatch_database_path_value(database)
    end
  end

  defp configured_repo_dispatch_database_value(_database), do: :none

  defp configured_repo_dispatch_database_path_value(database) when is_binary(database) do
    if Repo.memory_database?(database) do
      :none
    else
      {:ok, normalize_configured_dispatch_database(database)}
    end
  end

  defp sqlite_file_uri_query_params("file:" <> uri) do
    case String.split(uri, "?", parts: 2) do
      [_path, query] -> URI.decode_query(query)
      [_path] -> %{}
    end
  end

  defp truthy_sqlite_uri_param?(value) when is_binary(value), do: String.downcase(value) in ["1", "true", "yes", "on"]
  defp truthy_sqlite_uri_param?(_value), do: false

  defp live_file_backed_dispatch_database(repo) do
    case live_main_database_path(repo) do
      {:ok, path} -> {:ok, path}
      :memory -> {:tool_error, "file_backed_database_required"}
      :error -> {:tool_error, "database_required"}
    end
  end

  defp require_approved_dispatch_planned_slice(%PlannedSlice{status: "approved"}), do: :ok

  defp require_approved_dispatch_planned_slice(%PlannedSlice{status: status}),
    do: {:error, {:invalid_planned_slice_status, status}}

  defp dispatch_work_request_planned_slice_error({:invalid_planned_slice_status, _status}) do
    {:error, -32_602, "Invalid params", %{"tool" => "dispatch_work_request_planned_slice", "reason" => "invalid_planned_slice_status"}}
  end

  defp dispatch_work_request_planned_slice_error({:invalid_work_request_status, _status}) do
    {:error, -32_602, "Invalid params", %{"tool" => "dispatch_work_request_planned_slice", "reason" => "invalid_work_request_status"}}
  end

  defp dispatch_work_request_planned_slice_error({:planned_slice_scope_violation, _errors}) do
    {:error, -32_602, "Invalid params", %{"tool" => "dispatch_work_request_planned_slice", "reason" => "planned_slice_scope_violation"}}
  end

  defp dispatch_work_request_planned_slice_error({:unsupported_standalone_kind, _kind}) do
    {:error, -32_602, "Invalid params", %{"tool" => "dispatch_work_request_planned_slice", "reason" => "unsupported_standalone_kind"}}
  end

  defp dispatch_work_request_planned_slice_error({:dispatch_link_failed, _reason, recovery}) do
    {:error, -32_000, "Server error",
     %{
       "tool" => "dispatch_work_request_planned_slice",
       "reason" => "dispatch_link_failed",
       "recovery" => dispatch_link_recovery_payload(recovery)
     }}
  end

  defp dispatch_work_request_planned_slice_error(reason), do: architect_error(reason, "dispatch_work_request_planned_slice")

  defp append_worktree_lifecycle_audit(repo, %Session{} = session, work_package_id, source_tool, result) do
    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, work_package_id, %{
      "summary" => worktree_lifecycle_summary(source_tool, result.status),
      "status" => result.status,
      "idempotency_key" => worktree_lifecycle_idempotency_key(work_package_id, source_tool, result),
      "payload" => %{
        "type" => "worktree_lifecycle",
        "source_tool" => source_tool,
        "work_package_id" => work_package_id,
        "worktree_path" => audit_local_path(result.worktree_path),
        "repo_root" => audit_local_path(result.repo_root),
        "branch" => result.branch,
        "base_branch" => result.base_branch,
        "status" => result.status
      }
    })
  end

  defp maybe_append_cleanup_worktree_audit(_repo, _session, _work_package_id, %{status: "already_clean"}), do: {:ok, nil}

  defp maybe_append_cleanup_worktree_audit(repo, %Session{} = session, work_package_id, result) do
    append_worktree_lifecycle_audit(repo, session, work_package_id, "cleanup_work_package_worktree", result)
  end

  defp audit_local_path(nil), do: nil
  defp audit_local_path(_path), do: "[REDACTED]"

  defp worktree_lifecycle_summary("prepare_work_package_worktree", "already_prepared"), do: "WorkPackage worktree already prepared"
  defp worktree_lifecycle_summary("prepare_work_package_worktree", _status), do: "Prepared WorkPackage worktree"
  defp worktree_lifecycle_summary("cleanup_work_package_worktree", _status), do: "Cleaned WorkPackage worktree"

  defp worktree_lifecycle_idempotency_key(work_package_id, source_tool, result) do
    fingerprint =
      :sha256
      |> :crypto.hash([to_string(result.status), "\0", to_string(result.worktree_path), "\0", to_string(result.branch)])
      |> Base.url_encode64(padding: false)

    "worktree_lifecycle:#{source_tool}:#{work_package_id}:#{fingerprint}"
  end

  defp require_architect_phase_board_grant(repo, %Session{} = session, phase_id) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, anchor} <- architect_anchor_work_package(repo, session),
         :ok <- require_architect_anchor_scope(anchor, grant, phase_id),
         {:ok, _filters} <- Dashboard.phase_board_filters_for_grant(grant) do
      {:ok, grant}
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, :forbidden} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scoped_work_request_filters(repo, %Session{} = session) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         :ok <- require_work_request_anchor_scope(repo, session, grant),
         {:ok, filters} <- Dashboard.phase_board_filters_for_grant(grant),
         {:ok, scope} <- work_request_scope_payload(filters),
         {:ok, scope} <- maybe_put_handoff_phase_scope(repo, scope, grant) do
      {:ok, work_request_filters_from_scope(scope), scope}
    else
      {:error, :forbidden} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scoped_guidance_request_filters(repo, %Session{} = session) do
    with {:ok, filters, scope} <- scoped_work_request_filters(repo, session),
         {:ok, phase_id} <- architect_phase_scope(repo, session) do
      scope = Map.put(scope, "phase_id", phase_id)
      {:ok, Map.put(filters, "phase_id", phase_id), scope}
    end
  end

  defp require_work_request_anchor_scope(repo, %Session{} = session, %AccessGrant{} = grant) do
    if architect_explicit_phase_grant?(grant) do
      require_architect_phase_anchor(repo, session, grant.phase_id)
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp work_request_scope_payload(filters) when is_list(filters) do
    repo = Keyword.get(filters, :repo)
    base_branch = Keyword.get(filters, :base_branch)

    if filled_string?(repo) and filled_string?(base_branch) do
      {:ok, %{"repo" => String.trim(repo), "base_branch" => String.trim(base_branch)}}
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp work_request_filters_from_scope(%{"repo" => repo, "base_branch" => base_branch, "phase_id" => phase_id}) do
    %{"repo" => repo, "base_branch" => base_branch, "phase_id" => phase_id}
  end

  defp work_request_filters_from_scope(%{"repo" => repo, "base_branch" => base_branch}) do
    %{"repo" => repo, "base_branch" => base_branch}
  end

  defp maybe_put_handoff_phase_scope(repo, scope, %AccessGrant{} = grant) do
    case ArchitectHandoff.handoff_phase_grant?(repo, grant) do
      {:ok, true} -> {:ok, Map.put(scope, "phase_id", grant.phase_id)}
      {:ok, false} -> {:ok, scope}
      {:error, reason} -> {:error, reason}
    end
  end

  defp work_request_list_filters(filters, nil), do: filters
  defp work_request_list_filters(filters, status), do: Map.put(filters, "status", status)

  defp work_request_repository_filters(filters) do
    Map.take(filters, ["repo", "base_branch", "status"])
  end

  defp filter_scoped_work_requests(work_requests, filters) do
    Enum.filter(work_requests, &work_request_matches_filters?(&1, filters))
  end

  defp work_request_filter_payload(nil), do: %{}
  defp work_request_filter_payload(status), do: %{"status" => status}

  defp optional_work_request_status(arguments) do
    case Map.fetch(arguments, "status") do
      :error ->
        {:ok, nil}

      {:ok, status} when is_binary(status) ->
        status = String.trim(status)

        if status in WorkRequest.statuses() do
          {:ok, status}
        else
          {:tool_error, "invalid_status"}
        end

      {:ok, _status} ->
        {:tool_error, "invalid_status"}
    end
  end

  defp optional_guidance_request_status(arguments) do
    case Map.fetch(arguments, "status") do
      :error ->
        {:ok, nil}

      {:ok, status} when is_binary(status) ->
        status = String.trim(status)

        if status in GuidanceRequest.statuses() do
          {:ok, status}
        else
          {:tool_error, "invalid_status"}
        end

      {:ok, _status} ->
        {:tool_error, "invalid_status"}
    end
  end

  defp guidance_request_list_filters(filters, nil, nil), do: filters
  defp guidance_request_list_filters(filters, status, nil) when is_binary(status), do: Map.put(filters, "status", status)

  defp guidance_request_list_filters(filters, nil, work_package_id) when is_binary(work_package_id) do
    Map.put(filters, "work_package_id", work_package_id)
  end

  defp guidance_request_list_filters(filters, status, work_package_id) when is_binary(status) and is_binary(work_package_id) do
    filters
    |> Map.put("status", status)
    |> Map.put("work_package_id", work_package_id)
  end

  defp guidance_request_filter_payload(nil, nil), do: %{}
  defp guidance_request_filter_payload(status, nil) when is_binary(status), do: %{"status" => status}
  defp guidance_request_filter_payload(nil, work_package_id) when is_binary(work_package_id), do: %{"work_package_id" => work_package_id}

  defp guidance_request_filter_payload(status, work_package_id) do
    %{"status" => status, "work_package_id" => work_package_id}
  end

  defp optional_string_argument(arguments, key, default \\ nil) do
    case Map.fetch(arguments, key) do
      :error ->
        {:ok, default}

      {:ok, nil} ->
        {:ok, default}

      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, default}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp session_claimed_by(%Session{assignment: %{claimed_by: claimed_by}}) when is_binary(claimed_by) do
    case String.trim(claimed_by) do
      "" -> "architect"
      trimmed -> trimmed
    end
  end

  defp session_claimed_by(%Session{}), do: "architect"

  defp scoped_work_request(repo, work_request_id, filters) do
    with {:ok, %WorkRequest{} = work_request} <- WorkRequestService.get(repo, work_request_id),
         :ok <- require_work_request_scope(work_request, filters) do
      {:ok, work_request}
    else
      {:error, :forbidden} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scoped_work_request_question(repo, work_request_id, question_id) do
    with {:ok, questions} <- WorkRequestService.list_questions(repo, work_request_id) do
      case Enum.find(questions, &(&1.id == question_id)) do
        %ClarificationQuestion{} = question -> {:ok, question}
        nil -> {:error, :not_found}
      end
    end
  end

  defp scoped_work_request_planned_slice(repo, work_request_id, planned_slice_id) do
    WorkRequestService.get_planned_slice(repo, work_request_id, planned_slice_id)
  end

  defp scoped_worktree_work_package(repo, %Session{} = session, work_package_id) do
    with {:ok, %WorkPackage{} = work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, filters, scope} <- scoped_work_request_filters(repo, session),
         :ok <- require_worktree_work_package_scope(repo, work_package, filters) do
      {:ok, work_package, scope}
    else
      {:error, :forbidden} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_worktree_work_package_scope(repo, %WorkPackage{} = work_package, filters) do
    case linked_work_request_for_work_package(repo, work_package.id) do
      nil -> {:error, :forbidden}
      %WorkRequest{} = work_request -> require_work_request_scope(work_request, filters)
    end
  end

  defp require_worktree_repo_root_scope(_repo_root, nil), do: {:error, :invalid_repo_root}

  defp require_worktree_repo_root_scope(repo_root, scoped_repo_root) do
    with {:ok, repo_root} <- PathSafety.canonicalize(repo_root),
         {:ok, scoped_repo_root} <- PathSafety.canonicalize(scoped_repo_root),
         true <- same_filesystem_path?(repo_root, scoped_repo_root) do
      :ok
    else
      false -> {:error, :invalid_repo_root}
      {:error, _reason} -> {:error, :invalid_repo_root}
    end
  end

  defp same_filesystem_path?(left, right), do: comparable_filesystem_path(left) == comparable_filesystem_path(right)

  defp comparable_filesystem_path(path) do
    path =
      path
      |> Path.expand()
      |> String.replace("\\", "/")
      |> String.trim_trailing("/")

    if match?({:win32, _name}, :os.type()), do: String.downcase(path), else: path
  end

  defp linked_work_request_for_work_package(repo, work_package_id) do
    repo.one(
      from(planned_slice in PlannedSlice,
        join: work_request in WorkRequest,
        on: work_request.id == planned_slice.work_request_id,
        where: planned_slice.work_package_id == ^work_package_id,
        select: work_request,
        limit: 1
      )
    )
  end

  defp require_work_request_scope(%WorkRequest{} = work_request, filters) do
    if work_request_matches_filters?(work_request, filters) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp require_planned_slice_target_base_branch_scope(%WorkRequest{} = work_request, target_base_branch) do
    if work_request.base_branch == target_base_branch do
      :ok
    else
      {:tool_error, "target_base_branch_scope_mismatch"}
    end
  end

  defp require_planned_slice_authoring_status(status) when status in ["ready_for_slicing", "sliced"], do: :ok
  defp require_planned_slice_authoring_status(_status), do: {:tool_error, "invalid_status"}

  defp work_request_matches_filters?(%WorkRequest{} = work_request, filters) do
    Enum.all?(filters, fn
      {"repo", repo} when is_binary(repo) -> work_request.repo == repo
      {"base_branch", base_branch} when is_binary(base_branch) -> work_request.base_branch == base_branch
      {"status", status} when is_binary(status) -> work_request.status == status
      {"phase_id", phase_id} when is_binary(phase_id) -> ArchitectHandoff.phase_id_for_work_request(work_request) == phase_id
      _filter -> true
    end)
  end

  defp require_architect_target_scope(repo, %Session{} = session, %{"work_package_id" => work_package_id}) do
    with :ok <- require_architect_work_package_scope(session, work_package_id) do
      require_architect_current_phase_anchor(repo, session)
    end
  end

  defp require_architect_target_scope(repo, %Session{} = session, %{"phase_id" => phase_id}) do
    with :ok <- require_architect_phase_scope(repo, session, phase_id) do
      require_architect_phase_anchor(repo, session, phase_id)
    end
  end

  defp require_architect_target_scope(repo, %Session{} = session, _arguments) do
    require_architect_current_phase_anchor(repo, session)
  end

  defp require_architect_current_phase_anchor(repo, %Session{} = session) do
    case architect_phase_scope(repo, session) do
      {:ok, phase_id} -> require_architect_phase_anchor(repo, session, phase_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_architect_child_status_scope(repo, %Session{} = session, work_package_id) do
    if Session.work_package_id(session) == work_package_id do
      require_architect_anchor_status_scope(repo, session)
    else
      case require_architect_child_work_package_scope(repo, session, work_package_id) do
        {:ok, _child} -> :ok
        {:error, reason} -> {:error, reason}
        {:tool_error, _reason} -> {:error, :phase_scope_not_available}
      end
    end
  end

  defp require_architect_anchor_status_scope(repo, %Session{} = session) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, anchor} <- architect_anchor_work_package(repo, session) do
      require_anchor_status_phase_scope(repo, session, anchor, grant)
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_anchor_status_phase_scope(repo, %Session{} = session, %WorkPackage{} = anchor, %AccessGrant{} = grant) do
    cond do
      architect_explicit_phase_grant?(grant) ->
        require_frozen_anchor_scope(anchor, grant)

      explicit_phase_id?(anchor.phase_id) ->
        require_child_phase_anchor_status(repo, session)

      true ->
        :ok
    end
  end

  defp require_child_phase_anchor_status(repo, %Session{} = session) do
    case architect_child_phase_anchor(repo, session) do
      {:ok, _phase_id, _anchor} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_architect_child_work_package_scope(repo, %Session{} = session, work_package_id) do
    with {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session),
         {:ok, child} <- scoped_child_work_package(repo, work_package_id),
         :ok <- require_phase_child_scope(child, anchor, phase_id) do
      {:ok, child}
    end
  end

  defp scoped_child_work_package(repo, work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, child} -> {:ok, child}
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_phase_child_scope(%WorkPackage{kind: "phase_child", phase_id: phase_id} = child, anchor, phase_id) do
    cond do
      child.parent_id != anchor.id -> {:error, :phase_scope_not_available}
      child.repo != anchor.repo -> {:tool_error, "repo_scope_mismatch"}
      child.base_branch != anchor.base_branch -> {:tool_error, "base_branch_scope_mismatch"}
      true -> require_phase_child_file_scope(child, anchor)
    end
  end

  defp require_phase_child_scope(%WorkPackage{}, _anchor, _phase_id), do: {:error, :phase_scope_not_available}

  defp require_phase_child_file_scope(%WorkPackage{} = child, %WorkPackage{} = anchor) do
    with {:ok, anchor_globs} <- normalize_child_scope_globs(anchor.allowed_file_globs || []),
         {:ok, child_globs} <- normalize_child_scope_globs(child.allowed_file_globs || []),
         :ok <- require_child_file_scope_present(child_globs),
         :ok <- reject_overbroad_child_globs(child_globs) do
      require_child_globs_within_anchor(child_globs, anchor_globs)
    end
  end

  defp create_child_work_package_transaction(repo, %Session{} = session, package) do
    case repo.transaction(fn ->
           create_child_work_package_or_rollback(repo, session, package)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_child_work_package_or_rollback(repo, %Session{} = session, package) do
    case create_child_work_package_in_transaction(repo, session, package) do
      {:ok, result} -> result
      {:tool_error, reason} -> repo.rollback({:tool_error, reason})
      {:error, reason} -> repo.rollback({:error, reason})
    end
  end

  defp create_child_work_package_in_transaction(repo, %Session{} = session, package) do
    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, _architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, attrs} <- child_work_package_attrs(repo, session, package) do
      WorkPackageRepository.create(repo, attrs)
    end
  end

  defp mint_child_worker_key(%Config{} = config, %Session{} = session, work_package_id, template) do
    with {:ok, handoff_template} <- child_worker_secret_handoff_template(template),
         {:ok, handoff_opts} <- child_worker_secret_handoff_opts(config, work_package_id, handoff_template),
         {:ok, {child, minted, handoff}} <-
           mint_child_worker_key_transaction(config.repo, session, work_package_id, template, handoff_opts) do
      {:ok,
       %{
         "work_package" => child_work_package_payload(child),
         "worker_grant" => child_worker_grant_payload(minted, handoff)
       }}
    end
  end

  defp mint_child_worker_key_transaction(repo, %Session{} = session, work_package_id, template, handoff_opts) do
    case repo.transaction(fn ->
           mint_child_worker_key_or_rollback(repo, session, work_package_id, template, handoff_opts)
         end) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:tool_error, reason, cleanup_context}} ->
        {:tool_error, cleanup_child_worker_failed_mint(reason, cleanup_context, handoff_opts)}

      {:error, {:tool_error, reason}} ->
        {:tool_error, reason}

      {:error, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mint_child_worker_key_or_rollback(repo, %Session{} = session, work_package_id, template, handoff_opts) do
    case mint_child_worker_key_in_transaction(repo, session, work_package_id, template, handoff_opts) do
      {:ok, result} -> result
      {:tool_error, reason, cleanup_context} -> repo.rollback({:tool_error, reason, cleanup_context})
      {:tool_error, reason} -> repo.rollback({:tool_error, reason})
      {:error, reason} -> repo.rollback({:error, reason})
    end
  end

  defp mint_child_worker_key_in_transaction(repo, %Session{} = session, work_package_id, template, handoff_opts) do
    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session, architect_grant),
         {:ok, grant_opts} <- child_worker_grant_opts(template, architect_grant),
         {:ok, _prechecked_child} <- require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id),
         :ok <- lock_work_package(repo, work_package_id),
         :ok <- reject_active_child_worker_grant(repo, work_package_id),
         {:ok, child} <- require_child_ready_for_mint(repo, work_package_id, anchor, phase_id),
         {:ok, minted} <- AccessGrantService.mint_worker_grant(repo, child.id, grant_opts) do
      store_child_worker_key_handoff(child, minted, handoff_opts)
    end
  end

  defp store_child_worker_key_handoff(%WorkPackage{} = child, minted, handoff_opts) do
    with {:ok, handoff, _worker_grant} <- store_child_worker_secret_handoff(child, minted, handoff_opts) do
      {:ok, {child, minted, handoff}}
    end
  end

  defp store_child_worker_secret_handoff(%WorkPackage{} = child, minted, handoff_opts) do
    worker_grant = child_worker_grant_secret_payload(minted)
    metadata_worker_grant = redacted_child_worker_grant(worker_grant)

    case SecretHandoff.store_worker_secret(%{work_package: child, worker_grant: worker_grant}, handoff_opts) do
      {:ok, handoff} ->
        store_child_worker_secret_handoff_metadata(child, metadata_worker_grant, handoff, handoff_opts)

      {:error, reason} ->
        {:tool_error, secret_handoff_reason(reason)}
    end
  end

  defp store_child_worker_secret_handoff_metadata(%WorkPackage{} = child, worker_grant, handoff, handoff_opts) do
    case SecretHandoff.store_worker_secret_metadata(child, worker_grant, handoff, handoff_opts) do
      :ok ->
        {:ok, child_worker_secret_handoff_payload(handoff), redacted_child_worker_grant(worker_grant)}

      {:error, reason} ->
        cleanup = new_child_worker_handoff_cleanup(child, worker_grant, handoff, metadata_stored: false)
        {:tool_error, secret_handoff_reason(reason), cleanup}
    end
  end

  defp new_child_worker_handoff_cleanup(%WorkPackage{} = child, worker_grant, handoff, opts) do
    %{
      child: child,
      worker_grant: redacted_child_worker_grant(worker_grant),
      handoff: handoff,
      metadata_stored: Keyword.fetch!(opts, :metadata_stored)
    }
  end

  defp cleanup_child_worker_failed_mint(reason, cleanup_context, handoff_opts) do
    cleanup_result =
      cleanup_context
      |> cleanup_new_child_worker_handoff(handoff_opts)
      |> Enum.map(fn {key, value} -> {key, cleanup_status(value)} end)

    child_worker_handoff_tool_error(reason, cleanup_result)
  end

  defp cleanup_new_child_worker_handoff(%{metadata_stored: false, handoff: handoff}, handoff_opts) do
    %{new_handoff_cleanup: SecretHandoff.delete_worker_secret(handoff, handoff_opts)}
  end

  defp cleanup_status(:ok), do: "ok"
  defp cleanup_status({:error, reason}), do: "failed: #{reason_text(reason)}"

  defp child_worker_handoff_tool_error(reason, metadata) do
    reason
    |> reason_text()
    |> maybe_append_secret_handoff_metadata(metadata)
  end

  defp secret_handoff_reason(reason), do: SecretHandoff.error_message(reason)

  defp maybe_append_secret_handoff_metadata(reason, metadata) do
    details = Enum.map_join(metadata, ", ", fn {key, value} -> "#{key}=#{value}" end)

    "#{reason}; #{details}"
  end

  defp revoke_child_worker_key_transaction(repo, %Session{} = session, grant_id, reason) do
    run_architect_transaction(repo, fn ->
      revoke_child_worker_key_in_transaction(repo, session, grant_id, reason)
    end)
  end

  defp revoke_child_worker_key_in_transaction(repo, %Session{} = session, grant_id, reason) do
    now = DateTime.utc_now(:microsecond)

    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session, architect_grant),
         {:ok, candidate_grant} <- scoped_child_worker_grant_for_revoke(repo, grant_id, anchor, phase_id, now),
         :ok <- lock_work_package(repo, candidate_grant.work_package_id),
         :ok <- lock_access_grant(repo, grant_id),
         {:ok, grant} <- scoped_child_worker_grant_for_revoke(repo, grant_id, anchor, phase_id, now),
         {:ok, child} <- require_transaction_current_child_scope(repo, grant.work_package_id, anchor, phase_id),
         :ok <- require_child_worker_recyclable_status(child),
         {:ok, revoked_grant} <- revoke_live_child_worker_grant(repo, grant, now),
         {:ok, reset_child} <- reset_child_worker_for_recycle(repo, child, now),
         {:ok, event} <- append_child_worker_revoke_event(repo, session, child, reset_child, revoked_grant, reason) do
      {:ok, child_worker_revoke_result(reset_child, revoked_grant, event, reason, child.status)}
    end
  end

  defp required_revoke_child_worker_string(arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:tool_error, "invalid_#{key}"}

      :error ->
        {:tool_error, "missing_#{key}"}
    end
  end

  defp scoped_child_worker_grant_for_revoke(repo, grant_id, %WorkPackage{} = anchor, phase_id, %DateTime{} = now) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id),
         {:ok, work_package_id} <- child_worker_grant_work_package_id(grant),
         {:ok, _child} <- require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id),
         :ok <- require_live_child_worker_grant_for_revoke(grant, now) do
      {:ok, grant}
    end
  end

  defp child_worker_grant_work_package_id(%AccessGrant{work_package_id: work_package_id}) when is_binary(work_package_id) do
    case String.trim(work_package_id) do
      "" -> {:error, :phase_scope_not_available}
      trimmed -> {:ok, trimmed}
    end
  end

  defp child_worker_grant_work_package_id(%AccessGrant{}), do: {:error, :phase_scope_not_available}

  defp require_live_child_worker_grant_for_revoke(%AccessGrant{grant_role: "worker", provenance: @child_worker_grant_provenance} = grant, now) do
    cond do
      not child_worker_grant_capabilities?(grant.capabilities || []) ->
        {:tool_error, "not_child_worker_grant"}

      match?(%DateTime{}, grant.revoked_at) ->
        {:tool_error, "child_worker_grant_already_revoked"}

      not live_expires_at?(grant.expires_at, now) ->
        {:tool_error, "child_worker_grant_expired"}

      true ->
        :ok
    end
  end

  defp require_live_child_worker_grant_for_revoke(%AccessGrant{}, _now), do: {:tool_error, "not_child_worker_grant"}

  defp child_worker_grant_capabilities?(capabilities) when is_list(capabilities) do
    Enum.all?(capabilities, &(&1 in @child_worker_capabilities))
  end

  defp child_worker_grant_capabilities?(_capabilities), do: false

  defp require_child_worker_recyclable_status(%WorkPackage{status: status}) when status in @child_worker_recyclable_statuses, do: :ok
  defp require_child_worker_recyclable_status(%WorkPackage{}), do: {:tool_error, "child_not_recyclable"}

  defp revoke_live_child_worker_grant(repo, %AccessGrant{} = grant, %DateTime{} = now) do
    query =
      from(access_grant in AccessGrant,
        where:
          access_grant.id == ^grant.id and access_grant.work_package_id == ^grant.work_package_id and
            access_grant.grant_role == "worker" and access_grant.provenance == ^@child_worker_grant_provenance and
            is_nil(access_grant.revoked_at) and (is_nil(access_grant.expires_at) or access_grant.expires_at > ^now)
      )

    case repo.update_all(query, set: [revoked_at: now, updated_at: now]) do
      {1, _rows} -> AccessGrantRepository.get(repo, grant.id)
      {0, _rows} -> classify_child_worker_revoke_miss(repo, grant.id, now)
    end
  end

  defp classify_child_worker_revoke_miss(repo, grant_id, %DateTime{} = now) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id) do
      case require_live_child_worker_grant_for_revoke(grant, now) do
        :ok -> {:tool_error, "child_worker_revoke_conflict"}
        {:tool_error, reason} -> {:tool_error, reason}
      end
    end
  end

  defp reset_child_worker_for_recycle(_repo, %WorkPackage{status: @child_worker_ready_status} = child, _now), do: {:ok, child}

  defp reset_child_worker_for_recycle(repo, %WorkPackage{status: status} = child, %DateTime{} = now)
       when status in @child_worker_resettable_statuses do
    query =
      from(work_package in WorkPackage,
        where: work_package.id == ^child.id and work_package.kind == "phase_child" and work_package.status == ^status
      )

    case repo.update_all(query, set: [status: @child_worker_ready_status, updated_at: now]) do
      {1, _rows} -> WorkPackageRepository.get(repo, child.id)
      {0, _rows} -> {:tool_error, "child_worker_recycle_status_conflict"}
    end
  end

  defp reset_child_worker_for_recycle(_repo, %WorkPackage{}, _now), do: {:tool_error, "child_not_recyclable"}

  defp append_child_worker_revoke_event(
         repo,
         %Session{} = session,
         %WorkPackage{} = previous_child,
         %WorkPackage{} = reset_child,
         %AccessGrant{} = grant,
         reason
       ) do
    payload = child_worker_revoke_payload(reset_child.id, grant, reason, previous_child.status, reset_child.status)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, reset_child.id, %{
      "summary" => "Child worker grant revoked for recycle",
      "body" => "Recycle reason: #{redacted_child_worker_revoke_reason(reason)}; child status: #{previous_child.status} -> #{reset_child.status}",
      "status" => "child_worker_key_revoked",
      "idempotency_key" => metadata_idempotency_key(payload),
      "payload" => payload
    })
  end

  defp child_worker_revoke_payload(work_package_id, %AccessGrant{} = grant, reason, previous_status, new_status) do
    %{
      "type" => "child_worker_key_revoke",
      "source_tool" => "revoke_child_worker_key",
      "work_package_id" => work_package_id,
      "grant_id" => grant.id,
      "reason" => redacted_child_worker_revoke_reason(reason),
      "revoked_at" => timestamp(grant.revoked_at),
      "previous_status" => previous_status,
      "new_status" => new_status,
      "status_reset" => previous_status != new_status,
      "private_handoff_cleanup" => "not_attempted"
    }
  end

  defp child_worker_revoke_result(%WorkPackage{} = child, %AccessGrant{} = grant, %ProgressEvent{} = event, reason, previous_status) do
    %{
      "work_package" => child_work_package_payload(child),
      "revoked_worker_grant" => revoked_child_worker_grant_payload(grant),
      "recycle" => %{
        "status" => "revoked",
        "reason" => redacted_child_worker_revoke_reason(reason),
        "previous_child_status" => previous_status,
        "new_child_status" => child.status,
        "status_reset" => previous_status != child.status,
        "remint_available" => true,
        "remint_precondition" => "child_status_ready_for_worker",
        "private_handoff_cleanup" => "not_attempted"
      },
      "revocation_event" => progress_event_payload(event)
    }
  end

  defp revoked_child_worker_grant_payload(%AccessGrant{} = grant) do
    %{
      "id" => grant.id,
      "work_package_id" => grant.work_package_id,
      "grant_role" => grant.grant_role,
      "capabilities" => grant.capabilities || [],
      "expires_at" => timestamp(grant.expires_at),
      "revoked_at" => timestamp(grant.revoked_at),
      "secret_in_response" => false
    }
  end

  defp redacted_child_worker_revoke_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> Redactor.redact_text()
  end

  defp approve_child_ready_state_transaction(repo, %Session{} = session, work_package_id, rationale, request_id) do
    run_architect_transaction(repo, fn ->
      approve_child_ready_state_in_transaction(repo, session, work_package_id, rationale, request_id)
    end)
  end

  defp approve_child_ready_state_in_transaction(repo, %Session{} = session, work_package_id, rationale, request_id) do
    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session, architect_grant),
         {:ok, child} <- require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id),
         :ok <- lock_work_package(repo, child.id),
         {:ok, state} <- PlanningRepository.get_state(repo, child.id) do
      approve_child_ready_state_result(repo, session, state, rationale, request_id)
    end
  end

  defp approve_child_ready_state_result(repo, %Session{} = session, state, rationale, request_id) do
    case existing_child_ready_approval(repo, session, state, rationale, request_id) do
      {:ok, %ProgressEvent{} = event} ->
        replay_or_complete_child_ready_approval(repo, session, state, event)

      {:error, :not_found} ->
        with :ok <-
               require_child_status(
                 state.work_package,
                 "ready_for_architect_merge",
                 "child_not_ready_for_architect"
               ),
             :ok <- child_ready_approval_gates(repo, state),
             {:ok, event} <-
               append_child_ready_approval_event(repo, session, state.work_package, rationale, request_id),
             {:ok, approved_child} <- architect_phase_child_transition(repo, session, state.work_package, "merging_into_phase") do
          {:ok, child_ready_approval_result(approved_child, event)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_or_complete_child_ready_approval(
         repo,
         %Session{} = session,
         %{work_package: %WorkPackage{status: "ready_for_architect_merge"}} = state,
         %ProgressEvent{} = event
       ) do
    with :ok <- child_ready_approval_gates(repo, state),
         {:ok, approved_child} <- architect_phase_child_transition(repo, session, state.work_package, "merging_into_phase") do
      {:ok, child_ready_approval_result(approved_child, event)}
    end
  end

  defp replay_or_complete_child_ready_approval(_repo, %Session{}, state, %ProgressEvent{} = event) do
    {:ok, child_ready_approval_result(state.work_package, event)}
  end

  defp merge_child_into_phase_transaction(repo, %Session{} = session, work_package_id, merge_artifact) do
    run_architect_transaction(repo, fn ->
      merge_child_into_phase_in_transaction(repo, session, work_package_id, merge_artifact)
    end)
  end

  defp merge_child_into_phase_in_transaction(repo, %Session{} = session, work_package_id, merge_artifact) do
    with {:ok, merge_artifact} <- normalized_merge_artifact(merge_artifact),
         :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session, architect_grant),
         {:ok, child} <- require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id),
         :ok <- lock_work_package(repo, child.id),
         {:ok, state} <- PlanningRepository.get_state(repo, child.id) do
      merge_child_into_phase_result(repo, session, state, merge_artifact)
    end
  end

  defp merge_child_into_phase_result(repo, %Session{} = session, state, merge_artifact) do
    case existing_child_merge_record(repo, session, state.work_package.id, merge_artifact) do
      {:ok, %ProgressEvent{} = event} ->
        replay_or_complete_child_merge(repo, session, state, event, merge_artifact)

      {:error, :not_found} ->
        record_new_child_merge(repo, session, state, merge_artifact)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_or_complete_child_merge(
         repo,
         %Session{} = session,
         %{work_package: %WorkPackage{status: "merging_into_phase"}} = state,
         %ProgressEvent{} = event,
         merge_artifact
       ) do
    with :ok <- require_active_child_phase(repo, state.work_package),
         {:ok, artifact} <- record_phase_merge_artifact(repo, state.work_package, merge_artifact),
         {:ok, merged_child} <- architect_phase_child_transition(repo, session, state.work_package, "merged_into_phase") do
      {:ok, child_merge_result(merged_child, event, artifact, merge_artifact)}
    end
  end

  defp replay_or_complete_child_merge(repo, %Session{}, state, %ProgressEvent{} = event, merge_artifact) do
    with :ok <- require_active_child_phase(repo, state.work_package),
         {:ok, artifact} <- current_phase_merge_artifact(repo, state.work_package, merge_artifact) do
      {:ok, child_merge_result(state.work_package, event, artifact, current_merge_artifact(artifact))}
    end
  end

  defp record_new_child_merge(
         repo,
         %Session{} = session,
         %{work_package: %WorkPackage{status: "merging_into_phase"}} = state,
         merge_artifact
       ) do
    with :ok <- require_active_child_phase(repo, state.work_package),
         {:ok, artifact} <- record_phase_merge_artifact(repo, state.work_package, merge_artifact),
         {:ok, event} <- append_child_merge_event(repo, session, state.work_package, merge_artifact),
         {:ok, merged_child} <- architect_phase_child_transition(repo, session, state.work_package, "merged_into_phase") do
      {:ok, child_merge_result(merged_child, event, artifact, merge_artifact)}
    end
  end

  defp record_new_child_merge(
         repo,
         %Session{} = session,
         %{work_package: %WorkPackage{status: "merged_into_phase"}} = state,
         merge_artifact
       ) do
    with :ok <- require_active_child_phase(repo, state.work_package),
         {:ok, artifact} <- record_phase_merge_artifact(repo, state.work_package, merge_artifact),
         {:ok, event} <- append_child_merge_event(repo, session, state.work_package, merge_artifact) do
      {:ok, child_merge_result(state.work_package, event, artifact, merge_artifact)}
    end
  end

  defp record_new_child_merge(_repo, %Session{}, state, _merge_artifact) do
    require_child_status(state.work_package, "merging_into_phase", "child_not_approved_for_merge")
  end

  defp require_active_child_phase(repo, %WorkPackage{} = child) do
    case readiness_phase(repo, child) do
      {:ok, %{status: "active"}} -> :ok
      {:ok, _phase} -> {:tool_error, "phase_not_active"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_phase_merge_artifact(repo, %WorkPackage{} = child, merge_artifact) do
    case PlanningRepository.get_artifact(repo, phase_merge_artifact_id(child.id)) do
      {:ok, nil} ->
        with :ok <- require_active_child_phase(repo, child) do
          record_phase_merge_artifact(repo, child, merge_artifact)
        end

      {:ok, %Artifact{} = artifact} ->
        {:ok, artifact}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_child_ready_for_mint(repo, work_package_id, %WorkPackage{} = anchor, phase_id) when is_binary(work_package_id) do
    now = DateTime.utc_now(:microsecond)

    query =
      from(work_package in WorkPackage,
        where:
          work_package.id == ^work_package_id and work_package.status == "ready_for_worker" and
            work_package.kind == "phase_child" and work_package.phase_id == ^phase_id and work_package.parent_id == ^anchor.id and
            work_package.repo == ^anchor.repo and work_package.base_branch == ^anchor.base_branch
      )

    case repo.update_all(query, set: [updated_at: now]) do
      {1, _rows} -> require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id)
      {0, _rows} -> classify_child_ready_mint_miss(repo, work_package_id, anchor, phase_id)
    end
  end

  defp require_transaction_current_child_scope(repo, work_package_id, anchor, phase_id) do
    with {:ok, child} <- scoped_child_work_package(repo, work_package_id),
         :ok <- require_phase_child_scope(child, anchor, phase_id) do
      {:ok, child}
    end
  end

  defp classify_child_ready_mint_miss(repo, work_package_id, anchor, phase_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, child} ->
        case require_phase_child_scope(child, anchor, phase_id) do
          :ok -> {:tool_error, "child_not_ready_for_worker"}
          {:error, reason} -> {:error, reason}
          {:tool_error, reason} -> {:tool_error, reason}
        end

      {:error, _reason} ->
        {:error, :phase_scope_not_available}
    end
  end

  defp require_child_status(%WorkPackage{status: status}, status, _reason), do: :ok
  defp require_child_status(%WorkPackage{}, _status, reason), do: {:tool_error, reason}

  defp child_ready_approval_gates(repo, state) do
    required_review_lanes = required_review_lanes(state.work_package)

    with {:ok, reasons} <- readiness_failure_reasons(repo, state, required_review_lanes) do
      reasons = Enum.reject(reasons, &(Map.get(&1, "gate") in ["status_ci_waiting", "status_reviewing"]))
      missing = missing_readiness_gates(reasons)

      if missing == [], do: :ok, else: {:error, {:readiness_failed, missing, reasons}}
    end
  end

  defp existing_child_ready_approval(repo, %Session{} = session, %{work_package: %WorkPackage{} = child}, _rationale, request_id)
       when is_binary(request_id) do
    ready_cycle_id = child_ready_approval_ready_cycle_id(child)

    case current_cycle_child_ready_approval_event(repo, session, child.id, request_id, ready_cycle_id) do
      {:ok, %ProgressEvent{} = event} ->
        {:ok, event}

      {:error, :not_found} ->
        replay_latest_child_ready_approval_event(repo, session, child, request_id, ready_cycle_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_child_ready_approval(_repo, %Session{}, _state, _rationale, _request_id), do: {:error, :not_found}

  defp current_cycle_child_ready_approval_event(_repo, %Session{}, _work_package_id, _request_id, nil), do: {:error, :not_found}

  defp current_cycle_child_ready_approval_event(repo, %Session{} = session, work_package_id, request_id, ready_cycle_id) do
    identity = child_ready_approval_request_identity(work_package_id, request_id, ready_cycle_id)
    idempotency_key = child_ready_approval_idempotency_key(work_package_id, request_id, nil, ready_cycle_id)

    case PlanningRepository.get_progress_event_by_idempotency_key(
           repo,
           work_package_id,
           idempotency_key,
           session.assignment.grant_id
         ) do
      {:ok, event} ->
        validate_child_ready_approval_event(event, session, identity)

      {:error, :not_found} ->
        replay_child_ready_approval_event(repo, session, work_package_id, idempotency_key, identity)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replay_latest_child_ready_approval_event(repo, %Session{} = session, %WorkPackage{} = child, request_id, ready_cycle_id) do
    with {:ok, event} <- latest_child_ready_approval_event(repo, child.id, request_id),
         :ok <- child_ready_approval_event_matches_current_cycle?(repo, event, child, ready_cycle_id) do
      event_ready_cycle_id = Map.get(event.payload || %{}, "ready_cycle_id")
      identity = child_ready_approval_request_identity(child.id, request_id, event_ready_cycle_id)

      validate_child_ready_approval_event(event, session, identity)
    end
  end

  defp latest_child_ready_approval_event(repo, work_package_id, request_id) do
    case PlanningRepository.list_progress_events(repo, work_package_id) do
      {:ok, progress_events} ->
        progress_events
        |> Enum.filter(&child_ready_approval_request_event?(&1, request_id))
        |> List.last()
        |> case do
          %ProgressEvent{} = event -> {:ok, event}
          nil -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp child_ready_approval_request_event?(%ProgressEvent{status: "child_ready_approved", payload: payload}, request_id)
       when is_map(payload) do
    Map.take(payload, ["type", "source_tool", "request_id"]) == %{
      "type" => "child_ready_approval",
      "source_tool" => "approve_child_ready_state",
      "request_id" => request_id
    }
  end

  defp child_ready_approval_request_event?(%ProgressEvent{}, _request_id), do: false

  defp latest_child_ready_approval_event(repo, work_package_id) do
    case PlanningRepository.list_progress_events(repo, work_package_id) do
      {:ok, progress_events} ->
        progress_events
        |> Enum.filter(&child_ready_approval_event?/1)
        |> List.last()
        |> case do
          %ProgressEvent{} = event -> {:ok, event}
          nil -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp child_ready_approval_event?(%ProgressEvent{status: "child_ready_approved", payload: payload}) when is_map(payload) do
    Map.take(payload, ["type", "source_tool"]) == %{
      "type" => "child_ready_approval",
      "source_tool" => "approve_child_ready_state"
    }
  end

  defp child_ready_approval_event?(%ProgressEvent{}), do: false

  defp child_ready_approval_event_matches_current_cycle?(
         _repo,
         %ProgressEvent{payload: payload},
         %WorkPackage{status: "ready_for_architect_merge"},
         ready_cycle_id
       )
       when is_map(payload) do
    if Map.get(payload, "ready_cycle_id") == ready_cycle_id, do: :ok, else: {:error, :not_found}
  end

  defp child_ready_approval_event_matches_current_cycle?(repo, %ProgressEvent{} = event, %WorkPackage{id: child_id, status: status}, _ready_cycle_id)
       when status in ["merging_into_phase", "merged_into_phase", "blocked"] do
    with {:ok, latest_event} <- latest_child_ready_approval_event(repo, child_id) do
      if latest_event.id == event.id, do: :ok, else: {:error, :not_found}
    end
  end

  defp child_ready_approval_event_matches_current_cycle?(_repo, %ProgressEvent{}, %WorkPackage{}, _ready_cycle_id), do: {:error, :not_found}

  defp append_child_ready_approval_event(repo, %Session{} = session, %WorkPackage{} = child, rationale, request_id) do
    operation_id = if is_binary(request_id), do: nil, else: child_ready_approval_operation_id()
    ready_cycle_id = child_ready_approval_ready_cycle_id(child)
    payload = child_ready_approval_payload(child.id, rationale, request_id, operation_id, ready_cycle_id)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, child.id, %{
      "summary" => "Child ready state approved",
      "status" => "child_ready_approved",
      "idempotency_key" => child_ready_approval_idempotency_key(child.id, request_id, operation_id, ready_cycle_id),
      "payload" => payload
    })
  end

  defp child_ready_approval_payload(work_package_id, rationale, request_id, operation_id, ready_cycle_id) do
    %{
      "type" => "child_ready_approval",
      "source_tool" => "approve_child_ready_state",
      "work_package_id" => work_package_id,
      "rationale" => rationale
    }
    |> maybe_put_filled_string("request_id", request_id)
    |> maybe_put_filled_string("operation_id", operation_id)
    |> maybe_put_filled_string("ready_cycle_id", ready_cycle_id)
  end

  defp child_ready_approval_idempotency_key(work_package_id, request_id, _operation_id, ready_cycle_id) when is_binary(request_id) do
    child_ready_approval_request_identity(work_package_id, request_id, ready_cycle_id)
    |> metadata_idempotency_key()
  end

  defp child_ready_approval_idempotency_key(work_package_id, _request_id, operation_id, _ready_cycle_id) do
    child_ready_approval_operation_payload(work_package_id)
    |> Map.put("operation_id", operation_id)
    |> metadata_idempotency_key()
  end

  defp child_ready_approval_operation_payload(work_package_id) do
    %{
      "type" => "child_ready_approval",
      "source_tool" => "approve_child_ready_state",
      "work_package_id" => work_package_id
    }
  end

  defp child_ready_approval_request_identity(work_package_id, request_id, ready_cycle_id) do
    work_package_id
    |> child_ready_approval_operation_payload()
    |> Map.put("request_id", request_id)
    |> maybe_put_filled_string("ready_cycle_id", ready_cycle_id)
  end

  defp child_ready_approval_ready_cycle_id(%WorkPackage{status: "ready_for_architect_merge", updated_at: %DateTime{} = updated_at}) do
    DateTime.to_iso8601(updated_at)
  end

  defp child_ready_approval_ready_cycle_id(%WorkPackage{}), do: nil

  defp child_ready_approval_operation_id do
    "approval_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp child_ready_approval_result(%WorkPackage{} = child, %ProgressEvent{} = event) do
    %{
      "work_package" => child_work_package_payload(child),
      "approval" => progress_event_payload(event)
    }
  end

  defp normalized_merge_artifact(merge_artifact) when is_map(merge_artifact) do
    with {:ok, status} <- merge_artifact_string(merge_artifact, "status"),
         :ok <- require_merge_artifact_status(status),
         {:ok, uri} <- merge_artifact_string(merge_artifact, "uri") do
      merge_artifact =
        merge_artifact
        |> trim_string_values()
        |> Map.put("status", status)
        |> Map.put("uri", uri)

      {:ok, merge_artifact}
    end
  end

  defp merge_artifact_string(merge_artifact, key) do
    case Map.get(merge_artifact, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_merge_artifact_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "missing_merge_artifact_#{key}"}
    end
  end

  defp require_merge_artifact_status("merged_into_phase"), do: :ok
  defp require_merge_artifact_status(_status), do: {:tool_error, "invalid_merge_artifact_status"}

  defp trim_string_values(value) when is_map(value) do
    Map.new(value, fn
      {key, string} when is_binary(string) -> {key, String.trim(string)}
      {key, nested} -> {key, trim_string_values(nested)}
    end)
  end

  defp trim_string_values(values) when is_list(values), do: Enum.map(values, &trim_string_values/1)
  defp trim_string_values(value), do: value

  defp existing_child_merge_record(repo, %Session{} = session, work_package_id, merge_artifact) do
    payload = child_merge_payload(work_package_id, merge_artifact)
    idempotency_key = metadata_idempotency_key(payload)

    case PlanningRepository.get_progress_event_by_idempotency_key(
           repo,
           work_package_id,
           idempotency_key,
           session.assignment.grant_id
         ) do
      {:ok, event} -> validate_child_merge_event(event, session, payload)
      {:error, :not_found} -> replay_child_merge_event(repo, session, work_package_id, idempotency_key, payload)
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_child_ready_approval_event(repo, %Session{} = session, work_package_id, idempotency_key, expected_identity) do
    with {:ok, event} <- existing_child_progress_event(repo, work_package_id, idempotency_key) do
      validate_child_ready_approval_event(event, session, expected_identity)
    end
  end

  defp replay_child_merge_event(repo, %Session{} = session, work_package_id, idempotency_key, expected_payload) do
    with {:ok, event} <- existing_child_progress_event(repo, work_package_id, idempotency_key) do
      validate_child_merge_event(event, session, expected_payload)
    end
  end

  defp existing_child_progress_event(repo, work_package_id, idempotency_key) do
    case PlanningRepository.list_progress_events(repo, work_package_id) do
      {:ok, progress_events} -> matching_progress_event(progress_events, idempotency_key)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_child_ready_approval_event(event, session, expected_identity) do
    if event.status == "child_ready_approved" and child_ready_approval_identity_matches?(event.payload, expected_identity) do
      with :ok <- child_progress_event_actor_matches?(event, session), do: {:ok, event}
    else
      {:error, :idempotency_conflict}
    end
  end

  defp child_ready_approval_identity_matches?(payload, expected_identity) when is_map(payload) do
    payload
    |> Map.take(["type", "source_tool", "work_package_id", "request_id", "ready_cycle_id"])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Kernel.==(expected_identity)
  end

  defp child_ready_approval_identity_matches?(_payload, _expected_identity), do: false

  defp validate_child_merge_event(event, session, expected_payload) do
    if event.status == "merged_into_phase" and event.payload == expected_payload do
      with :ok <- child_progress_event_actor_role_matches?(event, session), do: {:ok, event}
    else
      {:error, :idempotency_conflict}
    end
  end

  defp child_progress_event_actor_matches?(%ProgressEvent{actor_id: event_actor_id, actor_type: event_actor_type}, %Session{} = session) do
    current_actor_id = session.assignment.claimed_by
    current_actor_type = session.assignment.grant_role

    cond do
      filled_string?(event_actor_type) and event_actor_type != current_actor_type ->
        {:error, :idempotency_conflict}

      filled_string?(event_actor_id) and filled_string?(current_actor_id) ->
        if String.trim(event_actor_id) == String.trim(current_actor_id), do: :ok, else: {:error, :idempotency_conflict}

      filled_string?(event_actor_id) ->
        {:error, :idempotency_conflict}

      true ->
        :ok
    end
  end

  defp child_progress_event_actor_role_matches?(%ProgressEvent{actor_type: event_actor_type}, %Session{} = session) do
    current_actor_type = session.assignment.grant_role

    if filled_string?(event_actor_type) and event_actor_type != current_actor_type do
      {:error, :idempotency_conflict}
    else
      :ok
    end
  end

  defp append_child_merge_event(repo, %Session{} = session, %WorkPackage{} = child, merge_artifact) do
    payload = child_merge_payload(child.id, merge_artifact)

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, child.id, %{
      "summary" => Map.get(merge_artifact, "summary") || "Child merged into phase",
      "status" => "merged_into_phase",
      "idempotency_key" => metadata_idempotency_key(payload),
      "payload" => payload
    })
  end

  defp child_merge_payload(work_package_id, merge_artifact) do
    %{
      "type" => "phase_child_merge",
      "source_tool" => "merge_child_into_phase",
      "work_package_id" => work_package_id,
      "merge_artifact" => merge_artifact
    }
  end

  defp record_phase_merge_artifact(repo, %WorkPackage{} = child, merge_artifact) do
    attrs = %{
      id: phase_merge_artifact_id(child.id),
      work_package_id: child.id,
      path: "phase-merge.json",
      title: "Phase merge record",
      kind: "phase_merge",
      uri: Map.fetch!(merge_artifact, "uri"),
      metadata: merge_artifact
    }

    case PlanningRepository.get_artifact(repo, attrs.id) do
      {:ok, nil} -> PlanningRepository.append_artifact(repo, attrs)
      {:ok, %Artifact{} = artifact} -> PlanningRepository.update_artifact(repo, artifact, Map.drop(attrs, [:id, :work_package_id]))
      {:error, reason} -> {:error, reason}
    end
  end

  defp phase_merge_artifact_id(work_package_id) do
    material = [work_package_id, "phase-merge.json"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp child_merge_result(%WorkPackage{} = child, %ProgressEvent{} = event, %Artifact{} = artifact, merge_artifact) do
    %{
      "work_package" => child_work_package_payload(child),
      "merge" => progress_event_payload(event),
      "artifact" => artifact_payload(artifact),
      "merge_artifact" => merge_artifact
    }
  end

  defp current_merge_artifact(%Artifact{} = artifact) do
    artifact
    |> artifact_metadata()
    |> Map.put("status", "merged_into_phase")
    |> Map.put("uri", artifact.uri)
  end

  defp artifact_metadata(%Artifact{metadata: metadata}) when is_map(metadata), do: metadata
  defp artifact_metadata(%Artifact{}), do: %{}

  defp architect_phase_child_transition(repo, %Session{} = session, %WorkPackage{} = child, next_status) do
    actor =
      session
      |> actor()
      |> Map.put(:work_package_id, child.id)
      |> Map.update!(:capabilities, &Enum.uniq(["architect:lifecycle.transition" | &1]))

    with :ok <- StateMachine.validate_transition(child, next_status, actor) do
      WorkPackageRepository.update_status(repo, child.id, child.status, next_status)
    end
  end

  defp reject_active_child_worker_grant(repo, work_package_id) do
    now = DateTime.utc_now(:microsecond)

    query =
      from(grant in AccessGrant,
        where:
          grant.work_package_id == ^work_package_id and grant.grant_role == "worker" and is_nil(grant.revoked_at) and
            grant.provenance == ^@child_worker_grant_provenance and
            (is_nil(grant.expires_at) or grant.expires_at > ^now),
        select: count(grant.id)
      )

    case repo.one(query) do
      0 -> :ok
      nil -> :ok
      _active_count -> {:tool_error, "active_child_worker_grant_exists"}
    end
  end

  defp architect_anchor_work_package(repo, %Session{} = session) do
    case Session.work_package_id(session) do
      work_package_id when is_binary(work_package_id) -> WorkPackageRepository.get(repo, work_package_id)
      _work_package_id -> {:error, :phase_scope_not_available}
    end
  end

  defp child_work_package_attrs(repo, %Session{} = session, package) do
    with {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session),
         :ok <- validate_child_work_package_keys(package),
         {:ok, title} <- required_argument(package, "title"),
         {:ok, acceptance_criteria} <- required_string_list(package, "acceptance_criteria"),
         {:ok, allowed_file_globs} <- child_allowed_file_globs(package, anchor),
         :ok <- require_child_field_match(package, "kind", "phase_child", "invalid_child_kind"),
         :ok <- require_child_field_match(package, "policy_template", "phase_child", "invalid_policy_template"),
         :ok <- require_child_field_match(package, "status", "ready_for_worker", "invalid_child_status"),
         :ok <- require_child_field_match(package, "repo", anchor.repo, "repo_scope_mismatch"),
         :ok <- require_child_field_match(package, "base_branch", anchor.base_branch, "base_branch_scope_mismatch"),
         :ok <- require_child_field_match(package, "phase_id", phase_id, :phase_scope_not_available),
         :ok <- require_child_field_match(package, "parent_id", anchor.id, "parent_scope_mismatch"),
         {:ok, branch_pattern} <- optional_child_string(package, "branch_pattern"),
         {:ok, product_description} <- optional_child_string(package, "product_description", anchor.product_description),
         {:ok, engineering_scope} <- optional_child_string(package, "engineering_scope", anchor.engineering_scope),
         {:ok, owner_id} <- optional_child_string(package, "owner_id") do
      attrs =
        %{
          "acceptance_criteria" => acceptance_criteria,
          "allowed_file_globs" => allowed_file_globs,
          "base_branch" => anchor.base_branch,
          "kind" => "phase_child",
          "parent_id" => anchor.id,
          "phase_id" => phase_id,
          "policy_template" => "phase_child",
          "repo" => anchor.repo,
          "status" => "ready_for_worker",
          "title" => title
        }
        |> maybe_put_id(package)
        |> put_optional_child_value("branch_pattern", branch_pattern)
        |> put_optional_child_value("product_description", product_description)
        |> put_optional_child_value("engineering_scope", engineering_scope)
        |> put_optional_child_value("owner_id", owner_id)

      {:ok, attrs}
    end
  end

  defp validate_child_work_package_keys(package) do
    unexpected = package |> Map.keys() |> Enum.reject(&(&1 in @child_work_package_keys))

    cond do
      "context_slice" in unexpected -> {:tool_error, "unsupported_context_slice"}
      unexpected == [] -> :ok
      true -> {:tool_error, "unexpected_package_field"}
    end
  end

  defp child_allowed_file_globs(package, %WorkPackage{} = anchor) do
    with {:ok, default_globs} <- normalize_child_scope_globs(anchor.allowed_file_globs || []),
         {:ok, globs} <- optional_child_string_list(package, "allowed_file_globs", default_globs),
         :ok <- require_child_file_scope_present(globs),
         :ok <- reject_overbroad_child_globs(globs),
         :ok <- require_child_globs_within_anchor(globs, default_globs) do
      {:ok, globs}
    end
  end

  defp require_child_file_scope_present([]), do: {:tool_error, "missing_allowed_file_globs"}
  defp require_child_file_scope_present(_globs), do: :ok

  defp reject_overbroad_child_globs(globs) do
    if Enum.any?(globs, &ScopeGuard.overbroad_glob?/1) do
      {:tool_error, "overbroad_allowed_file_globs"}
    else
      :ok
    end
  end

  defp require_child_globs_within_anchor(_child_globs, []), do: :ok

  defp require_child_globs_within_anchor(child_globs, anchor_globs) do
    if Enum.all?(child_globs, &glob_within_any_anchor?(&1, anchor_globs)) do
      :ok
    else
      {:tool_error, "child_scope_outside_phase"}
    end
  end

  defp glob_within_any_anchor?(child_glob, anchor_globs) do
    Enum.any?(anchor_globs, &glob_within_anchor?(child_glob, &1))
  end

  defp glob_within_anchor?(child_glob, anchor_glob) do
    with {:ok, child_segments} <- child_glob_segments(child_glob),
         {:ok, anchor_segments} <- child_glob_segments(anchor_glob) do
      glob_segments_within?(child_segments, anchor_segments)
    else
      {:tool_error, _reason} -> false
    end
  end

  defp child_glob_segments(glob) do
    glob = normalize_child_glob(glob)

    cond do
      glob == "" -> {:tool_error, "missing_allowed_file_globs"}
      traversal_glob?(glob) -> {:tool_error, "path_traversal_allowed_file_globs"}
      encoded_separator_glob?(glob) -> {:tool_error, "invalid_allowed_file_globs"}
      true -> {:ok, String.split(glob, "/", trim: true)}
    end
  end

  defp glob_segments_within?([], []), do: true
  defp glob_segments_within?([], _anchor_segments), do: false
  defp glob_segments_within?(_child_segments, []), do: false
  defp glob_segments_within?(child_segments, ["**"]), do: not Enum.any?(child_segments, &traversal_segment?/1)

  defp glob_segments_within?(["**" | child_tail], ["**" | anchor_tail]) do
    glob_segments_within?(child_tail, ["**" | anchor_tail])
  end

  defp glob_segments_within?([_child_head | child_tail] = child_segments, ["**" | anchor_tail]) do
    glob_segments_within?(child_segments, anchor_tail) or
      glob_segments_within?(child_tail, ["**" | anchor_tail])
  end

  defp glob_segments_within?(["**" | _child_tail], [_anchor_head | _anchor_tail]), do: false

  defp glob_segments_within?([child_head | child_tail], [anchor_head | anchor_tail]) do
    segment_within_anchor?(child_head, anchor_head) and glob_segments_within?(child_tail, anchor_tail)
  end

  defp segment_within_anchor?(child_segment, anchor_segment) do
    cond do
      child_segment == anchor_segment -> true
      anchor_segment == "*" -> child_segment != "**"
      child_segment == "**" -> false
      literal_glob?(child_segment) -> ScopeGuard.glob_match?(anchor_segment, child_segment)
      simple_star_segment_subset?(child_segment, anchor_segment) -> true
      true -> false
    end
  end

  defp literal_glob?(glob), do: not String.contains?(glob, ["*", "?", "["])

  defp simple_star_segment_subset?(child_segment, anchor_segment) do
    with {:ok, {anchor_prefix, anchor_suffix}} <- simple_star_bounds(anchor_segment),
         {child_prefix, child_suffix} <- segment_literal_bounds(child_segment) do
      String.starts_with?(child_prefix, anchor_prefix) and String.ends_with?(child_suffix, anchor_suffix)
    else
      :error -> false
    end
  end

  defp simple_star_bounds(segment) do
    cond do
      String.contains?(segment, ["?", "["]) -> :error
      segment |> String.graphemes() |> Enum.count(&(&1 == "*")) != 1 -> :error
      true -> {:ok, segment |> String.split("*", parts: 2) |> List.to_tuple()}
    end
  end

  defp segment_literal_bounds(segment) do
    tokens = segment_tokens(String.graphemes(segment), [])

    prefix =
      tokens
      |> Enum.take_while(&match?({:literal, _char}, &1))
      |> literal_token_string()

    suffix =
      tokens
      |> Enum.reverse()
      |> Enum.take_while(&match?({:literal, _char}, &1))
      |> Enum.reverse()
      |> literal_token_string()

    {prefix, suffix}
  end

  defp segment_tokens([], acc), do: Enum.reverse(acc)
  defp segment_tokens(["*" | rest], acc), do: segment_tokens(rest, [:wildcard | acc])
  defp segment_tokens(["?" | rest], acc), do: segment_tokens(rest, [:wildcard | acc])

  defp segment_tokens(["[" | rest], acc) do
    case drop_character_class(rest, false) do
      {:ok, rest} -> segment_tokens(rest, [:wildcard | acc])
      :error -> segment_tokens(rest, [{:literal, "["} | acc])
    end
  end

  defp segment_tokens([char | rest], acc), do: segment_tokens(rest, [{:literal, char} | acc])

  defp drop_character_class([], _has_content?), do: :error
  defp drop_character_class(["]" | _rest], false), do: :error
  defp drop_character_class(["]" | rest], true), do: {:ok, rest}
  defp drop_character_class([_char | rest], _has_content?), do: drop_character_class(rest, true)

  defp literal_token_string(tokens) do
    Enum.map_join(tokens, "", fn {:literal, char} -> char end)
  end

  defp require_child_field_match(package, key, expected, reason) do
    case Map.fetch(package, key) do
      :error -> :ok
      {:ok, nil} -> {:tool_error, "invalid_#{key}"}
      {:ok, value} when is_binary(value) -> require_nonblank_field_match(value, key, expected, reason)
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp require_nonblank_field_match(value, key, expected, reason) do
    case String.trim(value) do
      "" -> {:tool_error, "invalid_#{key}"}
      trimmed -> reject_null_string_field(trimmed, key, expected, reason)
    end
  end

  defp reject_null_string_field(trimmed, key, expected, reason) do
    if String.downcase(trimmed) == "null" do
      {:tool_error, "invalid_#{key}"}
    else
      require_optional_field_match(trimmed, expected, reason)
    end
  end

  defp require_optional_field_match(expected, expected, _reason), do: :ok
  defp require_optional_field_match(_value, _expected, reason) when is_atom(reason), do: {:error, reason}
  defp require_optional_field_match(_value, _expected, reason), do: {:tool_error, reason}

  defp optional_child_string(package, key, default \\ nil) do
    case Map.fetch(package, key) do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, value} when is_binary(value) -> {:ok, blank_default(value, default)}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp optional_child_string_list(package, key, default) do
    case Map.fetch(package, key) do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, values} when is_list(values) -> normalize_child_string_list(values, key)
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp normalize_child_string_list([], key), do: {:tool_error, "missing_#{key}"}

  defp normalize_child_string_list(values, key) do
    if Enum.all?(values, &(is_binary(&1) and normalize_child_glob(&1) != "")) do
      case normalize_child_scope_globs(values) do
        {:ok, []} -> {:tool_error, "missing_#{key}"}
        {:ok, globs} -> {:ok, globs}
        {:tool_error, reason} -> {:tool_error, reason}
      end
    else
      {:tool_error, "invalid_#{key}"}
    end
  end

  defp normalize_child_scope_globs(globs) when is_list(globs) do
    normalized_globs =
      globs
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&normalize_child_glob/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      Enum.any?(normalized_globs, &traversal_glob?/1) ->
        {:tool_error, "path_traversal_allowed_file_globs"}

      Enum.any?(normalized_globs, &encoded_separator_glob?/1) ->
        {:tool_error, "invalid_allowed_file_globs"}

      true ->
        {:ok, normalized_globs}
    end
  end

  defp normalize_child_scope_globs(_globs), do: {:ok, []}

  defp normalize_child_glob(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.replace(~r/\A\.\//, "")
  end

  defp normalize_child_glob(_value), do: ""

  defp traversal_glob?(glob) when is_binary(glob) do
    glob
    |> String.split("/", trim: true)
    |> Enum.any?(&traversal_segment?/1)
  end

  defp traversal_glob?(_glob), do: false

  defp encoded_separator_glob?(glob) when is_binary(glob) do
    glob
    |> String.split("/", trim: true)
    |> Enum.any?(&encoded_separator_segment?/1)
  end

  defp encoded_separator_glob?(_glob), do: false

  defp encoded_separator_segment?(segment) when is_binary(segment) do
    segment
    |> String.trim()
    |> String.downcase()
    |> encoded_separator_segment?(0)
  end

  defp encoded_separator_segment?(_segment), do: false

  defp encoded_separator_segment?(segment, depth) do
    cond do
      String.contains?(segment, ["/", "\\"]) ->
        true

      depth >= 3 ->
        false

      true ->
        decoded_segment = URI.decode(segment)

        decoded_segment != segment and encoded_separator_segment?(decoded_segment, depth + 1)
    end
  rescue
    ArgumentError -> false
  end

  defp traversal_segment?(segment) when is_binary(segment) do
    segment
    |> String.trim()
    |> String.downcase()
    |> traversal_segment?(0)
  end

  defp traversal_segment?(_segment), do: false

  defp traversal_segment?(segment, depth) do
    cond do
      segment in [".", ".."] ->
        true

      segment |> path_separator_segments() |> Enum.any?(&(&1 in [".", ".."])) ->
        true

      depth >= 3 ->
        false

      true ->
        decoded_segment = segment |> URI.decode() |> String.replace("\\", "/")

        decoded_segment != segment and traversal_segment?(decoded_segment, depth + 1)
    end
  rescue
    ArgumentError -> false
  end

  defp path_separator_segments(segment) do
    segment
    |> String.replace("\\", "/")
    |> String.split("/", trim: true)
  end

  defp blank_default(value, default) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp put_optional_child_value(attrs, _key, nil), do: attrs
  defp put_optional_child_value(attrs, key, value), do: Map.put(attrs, key, value)

  defp child_worker_grant_opts(template, %AccessGrant{} = architect_grant) do
    with :ok <- validate_child_worker_template_keys(template),
         {:ok, capabilities} <- child_worker_capabilities(template),
         {:ok, expires_at} <- child_worker_expires_at(template, architect_grant) do
      {:ok, [capabilities: capabilities, expires_at: expires_at, provenance: @child_worker_grant_provenance]}
    end
  end

  defp validate_child_worker_template_keys(template) do
    unexpected = template |> Map.keys() |> Enum.reject(&(&1 in @child_worker_template_keys))
    if unexpected == [], do: :ok, else: {:tool_error, "unexpected_template_field"}
  end

  defp child_worker_secret_handoff_template(template) do
    with :ok <- validate_child_worker_template_keys(template) do
      case Map.fetch(template, "secret_handoff") do
        :error -> {:ok, %{}}
        {:ok, nil} -> {:ok, %{}}
        {:ok, handoff} when is_map(handoff) -> normalize_child_worker_secret_handoff_template(handoff)
        {:ok, _handoff} -> {:tool_error, "invalid_secret_handoff"}
      end
    end
  end

  defp normalize_child_worker_secret_handoff_template(handoff) do
    unexpected = handoff |> Map.keys() |> Enum.reject(&(&1 in @child_worker_secret_handoff_keys))

    with true <- unexpected == [] || {:tool_error, "unexpected_secret_handoff_field"},
         {:ok, mode} <- optional_child_secret_handoff_string(handoff, "mode"),
         :ok <- validate_child_secret_handoff_mode(mode),
         {:ok, store_dir} <- optional_child_secret_handoff_string(handoff, "store_dir"),
         {:ok, claimed_by} <- optional_child_secret_handoff_string(handoff, "claimed_by") do
      {:ok,
       %{}
       |> put_optional_handoff_template_value(:mode, normalize_child_secret_handoff_mode(mode))
       |> put_optional_handoff_template_value(:store_dir, store_dir)
       |> put_optional_handoff_template_value(:claimed_by, claimed_by)}
    end
  end

  defp optional_child_secret_handoff_string(handoff, key) do
    case Map.fetch(handoff, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "invalid_secret_handoff"}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:tool_error, "invalid_secret_handoff"}
    end
  end

  defp validate_child_secret_handoff_mode(nil), do: :ok

  defp validate_child_secret_handoff_mode(mode) when is_binary(mode) do
    if normalize_child_secret_handoff_mode(mode) in SecretHandoff.valid_modes(),
      do: :ok,
      else: {:tool_error, "invalid_secret_handoff"}
  end

  defp normalize_child_secret_handoff_mode(nil), do: nil
  defp normalize_child_secret_handoff_mode(mode) when is_binary(mode), do: String.downcase(mode)

  defp put_optional_handoff_template_value(template, _key, nil), do: template
  defp put_optional_handoff_template_value(template, key, value), do: Map.put(template, key, value)

  defp child_worker_secret_handoff_opts(%Config{} = config, work_package_id, handoff_template) do
    with {:ok, repo_root} <- config_repo_root(config),
         :ok <- validate_child_secret_handoff_repo_root(repo_root, Map.get(handoff_template, :mode)) do
      opts = [
        repo_root: repo_root,
        claimed_by: Map.get(handoff_template, :claimed_by) || default_child_worker_claimed_by(work_package_id)
      ]

      {:ok,
       opts
       |> put_optional_handoff_opt(:database, child_worker_handoff_database(config))
       |> put_optional_handoff_opt(:mode, Map.get(handoff_template, :mode))
       |> put_optional_handoff_opt(:store_dir, Map.get(handoff_template, :store_dir))}
    end
  end

  defp child_worker_handoff_database(%Config{database: database}) when is_binary(database) do
    case normalized_database(database) do
      nil -> nil
      database -> database
    end
  end

  defp child_worker_handoff_database(%Config{repo: repo}), do: live_dispatch_database_or_nil(repo)

  defp config_repo_root(%Config{repo_root: repo_root}) when is_binary(repo_root) do
    case String.trim(repo_root) do
      "" -> {:tool_error, "missing_repo_root"}
      trimmed -> {:ok, Path.expand(trimmed)}
    end
  end

  defp config_repo_root(%Config{}), do: {:tool_error, "missing_repo_root"}

  defp validate_child_secret_handoff_repo_root(repo_root, mode) do
    script_path = Path.join([repo_root, "scripts", child_secret_handoff_script_name(mode)])

    if File.regular?(script_path), do: :ok, else: {:tool_error, "invalid_repo_root"}
  end

  defp child_secret_handoff_script_name("windows-credential-manager"), do: "sympp-worker-secret.ps1"
  defp child_secret_handoff_script_name("local-private-file"), do: local_private_file_handoff_script_name()
  defp child_secret_handoff_script_name(_auto_or_nil), do: child_secret_handoff_script_name(default_child_secret_handoff_mode())

  defp default_child_secret_handoff_mode, do: "local-private-file"

  defp local_private_file_handoff_script_name do
    if match?({:win32, _name}, :os.type()), do: "sympp-worker-secret.ps1", else: "sympp-worker-secret.sh"
  end

  defp default_child_worker_claimed_by(work_package_id), do: "sympp-child-worker:#{work_package_id}"

  defp put_optional_handoff_opt(opts, _key, nil), do: opts
  defp put_optional_handoff_opt(opts, _key, value) when is_binary(value) and value == "", do: opts
  defp put_optional_handoff_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp child_worker_capabilities(template) do
    case Map.fetch(template, "capabilities") do
      :error -> {:ok, @child_worker_capabilities}
      {:ok, nil} -> {:ok, @child_worker_capabilities}
      {:ok, capabilities} when is_list(capabilities) -> normalize_child_worker_capabilities(capabilities)
      {:ok, _capabilities} -> {:tool_error, "invalid_capabilities"}
    end
  end

  defp normalize_child_worker_capabilities([_head | _tail] = capabilities) do
    if Enum.all?(capabilities, &(is_binary(&1) and String.trim(&1) != "")) do
      capabilities = capabilities |> Enum.map(&String.trim/1) |> Enum.uniq()

      if Enum.all?(capabilities, &(&1 in @child_worker_capabilities)) do
        {:ok, capabilities}
      else
        {:tool_error, "broader_child_grant"}
      end
    else
      {:tool_error, "invalid_capabilities"}
    end
  end

  defp normalize_child_worker_capabilities(_capabilities), do: {:tool_error, "invalid_capabilities"}

  defp child_worker_expires_at(template, %{expires_at: %DateTime{} = architect_expires_at}) do
    with {:ok, expires_at} <- optional_child_worker_expires_at(template, architect_expires_at),
         :ok <- require_child_expires_before_architect(expires_at, architect_expires_at) do
      {:ok, expires_at}
    end
  end

  defp child_worker_expires_at(template, %{expires_at: nil}) do
    with {:ok, expires_at} <- optional_child_worker_expires_at(template, nil),
         :ok <- require_child_expiry_live(expires_at) do
      {:ok, expires_at}
    end
  end

  defp optional_child_worker_expires_at(template, default) do
    case Map.fetch(template, "expires_at") do
      :error -> {:ok, default}
      {:ok, nil} -> {:ok, default}
      {:ok, value} when is_binary(value) -> parse_child_worker_expires_at(value)
      {:ok, _value} -> {:tool_error, "invalid_expires_at"}
    end
  end

  defp parse_child_worker_expires_at(value) do
    case String.trim(value) do
      "" ->
        {:tool_error, "invalid_expires_at"}

      trimmed ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
          {:error, _reason} -> {:tool_error, "invalid_expires_at"}
        end
    end
  end

  defp require_child_expires_before_architect(expires_at, architect_expires_at) do
    cond do
      is_nil(expires_at) -> {:tool_error, "broader_child_grant"}
      DateTime.compare(expires_at, architect_expires_at) == :gt -> {:tool_error, "broader_child_grant"}
      DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) != :gt -> {:tool_error, "invalid_expires_at"}
      true -> :ok
    end
  end

  defp require_child_expiry_live(nil), do: :ok

  defp require_child_expiry_live(%DateTime{} = expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) == :gt,
      do: :ok,
      else: {:tool_error, "invalid_expires_at"}
  end

  defp solo_tool("solo_attach", arguments, %__MODULE__{config: config}) do
    with :ok <- prepare_solo_repository(config.repo),
         {:ok, repo_name} <- required_argument(arguments, "repo"),
         {:ok, base_branch} <- required_argument(arguments, "base_branch"),
         {:ok, workspace_path} <- required_argument(arguments, "workspace_path"),
         {:ok, caller_id} <- required_argument(arguments, "caller_id"),
         {:ok, session} <-
           SoloSessionService.create_or_attach_current(config.repo, %{
             "repo" => repo_name,
             "base_branch" => base_branch,
             "workspace_path" => workspace_path,
             "caller_id" => caller_id,
             "title" => Map.get(arguments, "title")
           }) do
      {:ok, tool_result(%{"action" => "solo_attach", "solo_session" => solo_session_payload(session)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "solo_attach", "reason" => reason}}
      {:error, reason} -> solo_error(reason, "solo_attach")
    end
  end

  defp solo_tool("solo_append", arguments, %__MODULE__{config: config}) do
    with :ok <- prepare_solo_repository(config.repo),
         {:ok, session_id} <- required_argument(arguments, "session_id"),
         {:ok, entry_kind} <- required_argument(arguments, "entry_kind"),
         {:ok, title} <- required_argument(arguments, "title"),
         {:ok, payload} <- optional_object_argument(arguments, "payload"),
         attrs <-
           %{"entry_kind" => entry_kind, "title" => title}
           |> put_optional_solo_attr(arguments, "body")
           |> put_optional_solo_attr(arguments, "status")
           |> put_optional_solo_attr(arguments, "idempotency_key")
           |> put_optional_solo_payload(payload),
         {:ok, entry} <- SoloSessionService.append_entry(config.repo, session_id, attrs) do
      {:ok, tool_result(%{"action" => "solo_append", "entry" => solo_entry_payload(entry)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "solo_append", "reason" => reason}}
      {:error, reason} -> solo_error(reason, "solo_append")
    end
  end

  defp solo_tool("solo_show", arguments, %__MODULE__{config: config}) do
    with :ok <- prepare_solo_repository(config.repo),
         {:ok, session_id} <- required_argument(arguments, "session_id"),
         {:ok, session} <- SoloSessionService.get(config.repo, session_id),
         {:ok, entries} <- SoloSessionService.list_entries(config.repo, session_id) do
      recent_entries = recent_solo_entries(entries)

      {:ok,
       tool_result(%{
         "action" => "solo_show",
         "solo_session" => solo_session_payload(session),
         "entries" => Enum.map(recent_entries, &solo_entry_payload/1),
         "entry_count" => length(entries),
         "entries_returned" => length(recent_entries),
         "entries_truncated" => length(entries) > length(recent_entries)
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "solo_show", "reason" => reason}}
      {:error, reason} -> solo_error(reason, "solo_show")
    end
  end

  defp solo_tool("solo_list", arguments, %__MODULE__{config: config}) do
    with :ok <- prepare_solo_repository(config.repo),
         {:ok, filters} <- solo_list_filters(arguments),
         {:ok, sessions} <- SoloSessionService.list(config.repo, filters) do
      {:ok, tool_result(%{"action" => "solo_list", "solo_sessions" => Enum.map(sessions, &solo_session_payload/1)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "solo_list", "reason" => reason}}
      {:error, reason} -> solo_error(reason, "solo_list")
    end
  end

  defp solo_tool("solo_update_status", arguments, %__MODULE__{config: config}) do
    with :ok <- prepare_solo_repository(config.repo),
         {:ok, session_id} <- required_argument(arguments, "session_id"),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, next_status} <- required_argument(arguments, "next_status"),
         {:ok, session} <- SoloSessionService.update_status(config.repo, session_id, current_status, next_status) do
      {:ok, tool_result(%{"action" => "solo_update_status", "solo_session" => solo_session_payload(session)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "solo_update_status", "reason" => reason}}
      {:error, reason} -> solo_error(reason, "solo_update_status")
    end
  end

  defp prepare_solo_repository(repo), do: SoloSessionRepository.migrate(repo)

  defp put_optional_solo_attr(attrs, arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, nil} -> attrs
      {:ok, value} -> Map.put(attrs, key, value)
      :error -> attrs
    end
  end

  defp put_optional_solo_payload(attrs, nil), do: attrs
  defp put_optional_solo_payload(attrs, payload), do: Map.put(attrs, "payload", payload)

  defp recent_solo_entries(entries), do: Enum.take(entries, -@solo_show_entry_limit)

  defp solo_list_filters(arguments) do
    Enum.reduce_while(["repo", "base_branch", "workspace_path", "caller_id", "status"], {:ok, %{}}, fn key, {:ok, filters} ->
      case Map.fetch(arguments, key) do
        :error -> {:cont, {:ok, filters}}
        {:ok, nil} -> {:cont, {:ok, filters}}
        {:ok, value} when is_binary(value) -> {:cont, {:ok, Map.put(filters, key, value)}}
        {:ok, _value} -> {:halt, {:tool_error, "invalid_#{key}"}}
      end
    end)
  end

  defp worker_tool("get_current_assignment", _arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_assignment_introspection(session.assignment) do
      {:ok, tool_result(%{"assignment" => Session.public_assignment(session)})}
    else
      {:error, reason} -> worker_error(reason, "get_current_assignment")
    end
  end

  defp worker_tool("read_context", _arguments, %__MODULE__{config: config, session: session}) do
    read_current_virtual_file(config.repo, session, "context.md")
  end

  defp worker_tool("read_task_plan", _arguments, %__MODULE__{config: config, session: session}) do
    read_task_plan_file(config.repo, session)
  end

  defp worker_tool("update_task_plan", arguments, %__MODULE__{config: config, session: session}) do
    case scoped_session(config.repo, session, arguments) do
      {:ok, session} -> normalize_update_task_plan_result(update_task_plan(config.repo, session, arguments))
      {:error, reason} -> worker_error(reason, "update_task_plan")
    end
  end

  defp worker_tool("append_finding", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, title} <- required_argument(arguments, "title"),
         {:ok, body} <- required_argument(arguments, "body"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         idempotency_key = String.trim(idempotency_key),
         {:ok, finding_id} <- optional_finding_id(arguments, session, idempotency_key),
         attrs = %{
           "id" => finding_id,
           "work_package_id" => Session.work_package_id(session),
           "title" => title,
           "body" => body,
           "severity" => optional_argument(arguments, "severity", "info"),
           "idempotency_key" => idempotency_key,
           "access_grant_id" => session.assignment.grant_id,
           "caller_supplied_id" => Map.has_key?(arguments, "id")
         },
         {:ok, finding} <- append_authenticated_idempotent_finding(config.repo, session, finding_id, attrs) do
      {:ok, tool_result(%{"finding" => %{"id" => finding.id, "title" => finding.title, "severity" => finding.severity}})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "append_finding", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "append_finding")
    end
  end

  defp worker_tool("append_progress", arguments, %__MODULE__{config: config, session: session}) do
    append_scoped_progress(config.repo, session, arguments, "append_progress", %{})
  end

  defp worker_tool("set_status", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, status} <- required_argument(arguments, "status"),
         {:ok, expected_status} <- required_argument(arguments, "expected_status"),
         {:ok, reason} <- optional_reason(arguments),
         :ok <- reject_ready_status(status),
         {:ok, work_package} <- set_status_transaction(config.repo, session, expected_status, status, reason) do
      {:ok, tool_result(%{"work_package" => work_package_payload(work_package)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "set_status", "reason" => reason}}
      {:error, _code, _message, _data} = error -> error
      {:error, reason} -> worker_error(reason, "set_status")
    end
  end

  defp worker_tool("report_blocker", arguments, %__MODULE__{config: config, session: session}) do
    case optional_blocker_id(arguments) do
      {:ok, blocker_id} ->
        append_scoped_progress(config.repo, session, arguments, "report_blocker", %{
          "type" => "blocker",
          "source_tool" => "report_blocker",
          "blocker_id" => blocker_id,
          "active" => true
        })

      {:error, reason} ->
        worker_error(reason, "report_blocker")
    end
  end

  defp worker_tool("resolve_blocker", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, blocker_id} <- required_argument(arguments, "blocker_id"),
         {:ok, resolution} <- required_argument(arguments, "resolution") do
      append_scoped_progress(config.repo, session, arguments, "resolve_blocker", %{
        "type" => "blocker",
        "source_tool" => "resolve_blocker",
        "blocker_id" => blocker_id,
        "resolution" => resolution,
        "active" => false
      })
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "resolve_blocker", "reason" => reason}}
    end
  end

  defp worker_tool("create_guidance_request", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, question} <- required_argument(arguments, "question"),
         {:ok, context} <- required_argument(arguments, "context"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, guidance_request} <-
           GuidanceRequestService.create_for_worker(config.repo, session.assignment, %{
             "summary" => summary,
             "question" => question,
             "context" => context,
             "idempotency_key" => idempotency_key
           }) do
      {:ok, tool_result(%{"guidance_request" => guidance_request_payload(guidance_request)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "create_guidance_request", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "create_guidance_request")
    end
  end

  defp worker_tool("request_scope_expansion", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_worker_assignment(session.assignment),
         {:ok, payload} <- request_scope_expansion_payload(config.repo, session) do
      append_scoped_progress(config.repo, session, arguments, "request_scope_expansion", payload)
    else
      {:error, reason} -> worker_error(reason, "request_scope_expansion")
    end
  end

  defp worker_tool("attach_branch", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, branch} <- required_argument(arguments, "branch"),
         {:ok, head_sha} <- required_argument(arguments, "head_sha") do
      append_metadata_event(config.repo, session, arguments, "attach_branch", "branch_attached", %{"type" => "branch", "branch" => branch, "head_sha" => head_sha})
    else
      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "attach_branch", "reason" => reason}}

      {:error, reason} ->
        worker_error(reason, "attach_branch")
    end
  end

  defp worker_tool("attach_pr", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, payload} <- pr_metadata_payload(config.repo, session, arguments, "attach_pr") do
      append_pr_metadata(config.repo, session, arguments, "attach_pr", "pr_attached", payload)
      |> metadata_tool_response("attach_pr")
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "attach_pr", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "attach_pr")
    end
  end

  defp worker_tool("sync_pr", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, payload} <- pr_metadata_payload(config.repo, session, arguments, "sync_pr") do
      append_pr_metadata(config.repo, session, arguments, "sync_pr", "pr_synced", payload)
      |> metadata_tool_response("sync_pr")
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "sync_pr", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "sync_pr")
    end
  end

  defp worker_tool("submit_review_package", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, tests} <- required_string_list(arguments, "tests"),
         {:ok, artifacts} <- required_string_list(arguments, "artifacts"),
         artifacts = Enum.uniq(artifacts),
         {:ok, reviews} <- optional_review_list(arguments, "reviews"),
         {:ok, acceptance_criteria_met} <- optional_boolean(arguments, "acceptance_criteria_met", nil),
         {:ok, result} <-
           submit_review_package_transaction(config.repo, session, arguments, artifacts, %{
             "type" => "review_package",
             "summary" => summary,
             "tests" => tests,
             "artifacts" => artifacts,
             "reviews" => reviews,
             "acceptance_criteria_met" => acceptance_criteria_met
           }) do
      {:ok, result}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "submit_review_package", "reason" => reason}}
      {:error, _code, _message, _data} = error -> error
      {:error, reason} -> worker_error(reason, "submit_review_package")
    end
  end

  defp worker_tool("attach_review_suite_result", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, requested_head_sha} <- required_argument(arguments, "head_sha"),
         {:ok, suite} <- required_argument(arguments, "suite"),
         {:ok, anchor} <- required_argument(arguments, "anchor"),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, status} <- required_argument(arguments, "status"),
         {:ok, verdict} <- required_argument(arguments, "verdict"),
         :ok <- require_passing_review_suite_result(status, verdict),
         {:ok, result} <-
           attach_review_suite_result_transaction(config.repo, session, arguments, %{
             "type" => "review_suite_result",
             "source_tool" => "attach_review_suite_result",
             "work_package_id" => work_package_id,
             "head_sha" => requested_head_sha,
             "suite" => suite,
             "anchor" => anchor,
             "summary" => summary,
             "status" => normalized_review_suite_status(status),
             "verdict" => normalized_review_suite_verdict(verdict)
           }) do
      {:ok, result}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "attach_review_suite_result", "reason" => reason}}
      {:error, _code, _message, _data} = error -> error
      {:error, reason} -> worker_error(reason, "attach_review_suite_result")
    end
  end

  defp worker_tool("mark_ready", _arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_worker_assignment(session.assignment),
         {:ok, work_package} <- mark_ready_transaction(config.repo, session) do
      {:ok, tool_result(%{"work_package" => work_package_payload(work_package), "ready" => true})}
    else
      {:error, {:readiness_failed, missing, reasons}} ->
        {:error, -32_602, "Invalid params", %{"tool" => "mark_ready", "reason" => "readiness_failed", "missing" => missing, "reasons" => reasons}}

      {:error, {:readiness_failed, missing}} ->
        {:error, -32_602, "Invalid params", %{"tool" => "mark_ready", "reason" => "readiness_failed", "missing" => missing}}

      {:error, reason} ->
        worker_error(reason, "mark_ready")
    end
  end

  defp read_guidance_request_tool(arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, guidance_request_id} <- required_argument(arguments, "guidance_request_id") do
      read_guidance_request_for_session(config.repo, session, guidance_request_id, arguments)
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_guidance_request", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "read_guidance_request")
    end
  end

  defp read_guidance_request_for_session(
         repo,
         %Session{assignment: %{grant_role: "worker"}} = session,
         guidance_request_id,
         arguments
       ) do
    with {:ok, session} <- scoped_session(repo, session, arguments),
         {:ok, guidance_request} <-
           GuidanceRequestService.get_for_worker(repo, session.assignment, guidance_request_id) do
      {:ok, tool_result(%{"guidance_request" => guidance_request_payload(guidance_request)})}
    else
      {:error, :not_found} -> not_found_error("read_guidance_request")
      {:error, reason} -> worker_error(reason, "read_guidance_request")
    end
  end

  defp read_guidance_request_for_session(
         repo,
         %Session{assignment: %{grant_role: "architect"}} = session,
         guidance_request_id,
         arguments
       ) do
    with {:ok, session} <- architect_session(repo, session, "read:guidance_request"),
         {:ok, work_package_id} <- optional_string_argument(arguments, "work_package_id"),
         {:ok, filters, scope} <- scoped_guidance_request_filters(repo, session),
         {:ok, guidance_request} <-
           GuidanceRequestService.get_visible_to_architect(repo, guidance_request_id, filters),
         :ok <- require_guidance_request_work_package(guidance_request, work_package_id) do
      {:ok, tool_result(%{"guidance_request" => guidance_request_payload(guidance_request), "scope" => scope})}
    else
      {:error, :not_found} -> not_found_error("read_guidance_request")
      {:error, reason} -> architect_error(reason, "read_guidance_request")
    end
  end

  defp read_guidance_request_for_session(_repo, %Session{}, _guidance_request_id, _arguments) do
    auth_error({:unauthorized, :unsupported_grant_role}, "read_guidance_request")
  end

  defp require_guidance_request_work_package(%GuidanceRequest{}, nil), do: :ok

  defp require_guidance_request_work_package(%GuidanceRequest{work_package_id: work_package_id}, work_package_id), do: :ok

  defp require_guidance_request_work_package(%GuidanceRequest{}, _work_package_id), do: {:error, :not_found}

  defp pr_metadata_payload(repo, %Session{} = session, arguments, source_tool) do
    case legacy_attach_pr_payload(arguments, source_tool) do
      {:ok, payload} -> {:ok, payload}
      :error -> github_pr_metadata_payload(repo, session, arguments, source_tool)
    end
  end

  defp github_pr_metadata_payload(repo, %Session{} = session, arguments, source_tool) do
    with {:ok, %WorkPackage{} = work_package} <- WorkPackageRepository.get(repo, Session.work_package_id(session)),
         {:ok, metadata_input} <- pr_metadata_input(arguments, source_tool),
         {:ok, arguments} <- pr_reference_arguments(repo, session, arguments, source_tool),
         {:ok, ref} <- PullRequest.parse(arguments, work_package.repo),
         {:ok, metadata} <- Client.fetch_pull_request(DryClient, ref, metadata: metadata_input),
         {:ok, payload} <- PullRequest.metadata(metadata, ref, pr_fallback_head_sha(arguments, source_tool)) do
      {:ok, Map.put(payload, "source_tool", source_tool)}
    else
      {:tool_error, reason} ->
        {:tool_error, reason}

      {:error, reason} when reason in [:database_busy] ->
        {:error, reason}

      {:error, {reason, _detail} = error} when reason in [:storage_failed, :migration_failed, :service_unavailable] ->
        {:error, error}

      {:error, :missing_repository} ->
        {:tool_error, pr_missing_repository_reason(arguments, source_tool)}

      {:error, reason} ->
        {:tool_error, reason_text(reason)}
    end
  end

  defp legacy_attach_pr_payload(arguments, "attach_pr") do
    with url when is_binary(url) <- Map.get(arguments, "url"),
         trimmed_url = String.trim(url),
         true <- trimmed_url != "",
         true <- non_github_url?(trimmed_url) do
      payload =
        %{"type" => "pr", "source_tool" => "attach_pr", "url" => trimmed_url}
        |> maybe_put_filled_string("head_sha", Map.get(arguments, "head_sha"))

      {:ok, payload}
    else
      _value -> :error
    end
  end

  defp legacy_attach_pr_payload(_arguments, _source_tool), do: :error

  defp non_github_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        String.downcase(host) != "github.com"

      _uri ->
        false
    end
  rescue
    _error in URI.Error -> false
  end

  defp maybe_put_filled_string(payload, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> payload
      trimmed -> Map.put(payload, key, trimmed)
    end
  end

  defp maybe_put_filled_string(payload, _key, _value), do: payload

  defp metadata_tool_response({:ok, _result} = result, _tool), do: result
  defp metadata_tool_response({:error, _code, _message, _data} = error, _tool), do: error
  defp metadata_tool_response({:tool_error, reason}, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
  defp metadata_tool_response({:error, reason}, tool), do: worker_error(reason, tool)

  defp pr_fallback_head_sha(arguments, tool) when tool in ["attach_pr", "sync_pr"], do: Map.get(arguments, "head_sha")

  defp pr_reference_arguments(repo, %Session{} = session, arguments, "sync_pr") do
    if Map.has_key?(arguments, "number") and not filled_string?(Map.get(arguments, "repository")) and not filled_string?(Map.get(arguments, "url")) do
      with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, Session.work_package_id(session)),
           {:ok, {repository, _number}} <- latest_attached_pr_ref(progress_events) do
        {:ok, Map.put(arguments, "repository", repository)}
      end
    else
      {:ok, arguments}
    end
  end

  defp pr_reference_arguments(_repo, %Session{}, arguments, _source_tool), do: {:ok, arguments}

  defp pr_missing_repository_reason(arguments, "attach_pr") do
    if Map.has_key?(arguments, "number") and not filled_string?(Map.get(arguments, "url")) do
      "missing_repository_use_url_or_owner_repo"
    else
      "missing_repository"
    end
  end

  defp pr_missing_repository_reason(_arguments, _source_tool), do: "missing_repository"

  defp validate_pr_sync_target(_repo, %Session{}, _ref, "attach_pr"), do: :ok

  defp validate_pr_sync_target(repo, %Session{} = session, ref, "sync_pr") do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, Session.work_package_id(session)),
         {:ok, attached_ref} <- latest_attached_pr_ref(progress_events) do
      if attached_ref == normalized_pr_ref(ref.repository, ref.number), do: :ok, else: {:tool_error, "pr_mismatch"}
    end
  end

  defp latest_attached_pr_ref(progress_events) do
    case latest_attached_pr_ref_with_sequence(progress_events) do
      {:ok, ref, _sequence} -> {:ok, ref}
      {:tool_error, reason} -> {:tool_error, reason}
    end
  end

  defp latest_attached_pr_ref_with_sequence(progress_events) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find_value(&attached_pr_ref_with_sequence/1)
    |> case do
      nil -> {:tool_error, "missing_attached_pr"}
      {ref, sequence} -> {:ok, ref, sequence}
    end
  end

  defp attached_pr_ref_with_sequence(%ProgressEvent{payload: payload, sequence: sequence} = event) when is_map(payload) do
    if payload_type?(event, "pr", "attach_pr"), do: pr_payload_ref_with_sequence(payload, sequence)
  end

  defp attached_pr_ref_with_sequence(_event), do: nil

  defp pr_payload_ref_with_sequence(payload, sequence) do
    case pr_payload_ref(payload) do
      nil -> nil
      ref -> {ref, sequence}
    end
  end

  defp pr_payload_ref(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_integer(number), do: normalized_pr_ref(repository, number)
  defp pr_payload_ref(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_binary(number), do: normalized_pr_ref(repository, number)

  defp pr_payload_ref(%{"url" => url}) when is_binary(url) do
    case PullRequest.parse(%{"url" => url}, nil) do
      {:ok, ref} -> normalized_pr_ref(ref.repository, ref.number)
      {:error, _reason} -> legacy_url_ref(url)
    end
  end

  defp pr_payload_ref(_payload), do: nil

  defp normalized_pr_ref(repository, number) when is_binary(repository), do: {String.downcase(repository), number}

  defp legacy_url_ref(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        if String.downcase(host) == "github.com", do: nil, else: {:url, url}

      _uri ->
        {:url, url}
    end
  rescue
    _error in URI.Error -> {:url, url}
  end

  defp chronological_progress_events(progress_events) do
    Enum.sort_by(progress_events, fn %ProgressEvent{created_at: created_at, sequence: sequence, id: id} ->
      {created_at || DateTime.from_unix!(0), sequence || 0, id || ""}
    end)
  end

  defp pr_metadata_input(arguments, "attach_pr") do
    case Map.get(arguments, "metadata") do
      metadata when is_map(metadata) -> {:ok, metadata}
      nil -> {:ok, %{"head_sha" => Map.get(arguments, "head_sha")}}
      _metadata -> {:tool_error, "invalid_metadata"}
    end
  end

  defp pr_metadata_input(arguments, "sync_pr") do
    case Map.get(arguments, "metadata") do
      metadata when is_map(metadata) -> {:ok, metadata}
      _metadata -> {:tool_error, "missing_metadata"}
    end
  end

  defp append_pr_metadata(repo, %Session{} = session, arguments, tool, status, payload) do
    with {:ok, idempotency_key, attrs} <- metadata_event_attrs(session, arguments, tool, status, payload),
         {:ok, replay?} <- progress_event_replay?(repo, session, idempotency_key),
         :ok <- validate_pr_sync_target_unless_replay(repo, session, payload, tool, replay?) do
      run_worker_transaction(repo, fn ->
        append_pr_metadata_event(repo, session, attrs, idempotency_key, tool, payload, replay?)
      end)
    end
  end

  defp append_pr_metadata_event(repo, session, attrs, idempotency_key, tool, payload, replay?) do
    with {:ok, event_result} <- append_progress_event_or_replay(repo, session, attrs, idempotency_key, tool),
         :ok <- maybe_upsert_pr_artifact(repo, session, payload, replay?) do
      {:ok, event_result}
    end
  end

  defp validate_pr_sync_target_unless_replay(_repo, %Session{}, _arguments, _tool, true), do: :ok
  defp validate_pr_sync_target_unless_replay(_repo, %Session{}, _payload, "attach_pr", false), do: :ok

  defp validate_pr_sync_target_unless_replay(repo, %Session{} = session, payload, tool, false) do
    with {:ok, ref} <- PullRequest.parse(payload, nil) do
      validate_pr_sync_target(repo, session, ref, tool)
    end
  end

  defp progress_event_replay?(repo, %Session{} = session, idempotency_key) do
    case existing_progress_event(repo, session, idempotency_key) do
      {:ok, %ProgressEvent{}} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_upsert_pr_artifact(_repo, %Session{}, _payload, true), do: :ok

  defp maybe_upsert_pr_artifact(repo, %Session{} = session, payload, false) do
    PullRequestArtifact.upsert(repo, session.assignment.work_package_id, payload)
  end

  defp request_scope_expansion_payload(repo, %Session{} = session) do
    payload = %{
      "type" => "scope_expansion_request",
      "source_tool" => "request_scope_expansion",
      "approved" => false
    }

    case WorkPackageRepository.get(repo, session.assignment.work_package_id) do
      {:ok, %WorkPackage{kind: "investigation"} = work_package} ->
        {:ok, Map.put(payload, "recommendation_artifact_id", recommendation_artifact_id(work_package.id))}

      {:ok, %WorkPackage{}} ->
        {:ok, payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reject_ready_status(status) when status in ["ready_for_human_merge", "ready_for_architect_merge"] do
    {:tool_error, "use_mark_ready"}
  end

  defp reject_ready_status(_status), do: :ok

  defp require_expected_status(%WorkPackage{status: expected_status}, expected_status), do: :ok
  defp require_expected_status(%WorkPackage{}, _expected_status), do: {:tool_error, "stale_status"}

  defp set_status_transaction(repo, %Session{} = session, expected_status, status, reason) do
    repo
    |> run_worker_transaction(fn ->
      with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
           {:ok, state} <- PlanningRepository.get_state(repo, Session.work_package_id(session)),
           :ok <- require_expected_status(state.work_package, expected_status),
           :ok <- reject_architect_controlled_child(state.work_package, status),
           {:ok, _event} <- append_status_reason_event(repo, session, expected_status, status, reason) do
        LifecycleService.transition(repo, state.work_package, status, actor(session))
      end
    end)
  end

  defp mark_ready_transaction(repo, %Session{} = session) do
    repo
    |> run_worker_transaction(fn ->
      with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
           :ok <- lock_work_package(repo, Session.work_package_id(session)),
           {:ok, state} <- PlanningRepository.get_state(repo, Session.work_package_id(session)),
           :ok <- readiness_gates(repo, state),
           ready_status = StateMachine.terminal_readiness_status(state.work_package),
           :ok <- StateMachine.validate_ready_transition(state.work_package, ready_status, actor(session)) do
        WorkPackageRepository.update_status(repo, state.work_package.id, state.work_package.status, ready_status)
      end
    end)
  end

  defp escalate_guidance_request_transaction(
         repo,
         %Session{} = session,
         guidance_request_id,
         reason,
         recommended_language,
         decision_prompt
       ) do
    repo
    |> run_architect_transaction(fn ->
      with {:ok, filters, scope} <- scoped_guidance_request_filters(repo, session),
           {:ok, guidance_request} <-
             GuidanceRequestService.get_visible_to_architect(repo, guidance_request_id, filters),
           :ok <- lock_work_package(repo, guidance_request.work_package_id),
           blocker_id = guidance_request_blocker_id(guidance_request.id),
           {:ok, escalated} <-
             GuidanceRequestService.escalate_human_info_needed(repo, guidance_request.id, %{
               "human_info_reason" => reason,
               "recommended_language" => recommended_language,
               "decision_prompt" => decision_prompt,
               "blocker_id" => blocker_id
             }),
           {:ok, blocker_event} <-
             PlanningRepository.append_audit_progress_event_for_work_package(
               repo,
               session.assignment,
               guidance_request.work_package_id,
               guidance_request_blocker_attrs(escalated, reason, recommended_language, blocker_id)
             ) do
        {:ok,
         %{
           "guidance_request" => guidance_request_payload(escalated),
           "blocker" => %{
             "id" => blocker_id,
             "active" => true,
             "progress_event_id" => blocker_event.id,
             "recommended_language" => recommended_language
           },
           "scope" => scope,
           "status" => %{"guidance_request_status" => escalated.status}
         }}
      end
    end)
  end

  defp guidance_request_blocker_attrs(%GuidanceRequest{} = guidance_request, reason, recommended_language, blocker_id) do
    %{
      "summary" => "Human info needed for guidance request: #{guidance_request.summary}",
      "body" => "Reason: #{reason}\n\nRecommended language: #{recommended_language}",
      "status" => "blocked",
      "idempotency_key" => "guidance_request_human_info_needed:#{guidance_request.id}",
      "payload" => %{
        "type" => "blocker",
        "source_tool" => "report_blocker",
        "blocker_id" => blocker_id,
        "active" => true,
        "guidance_request_id" => guidance_request.id,
        "guidance_request_status" => guidance_request.status,
        "human_info_needed" => true,
        "reason" => reason,
        "recommended_language" => recommended_language
      }
    }
  end

  defp guidance_request_blocker_id(guidance_request_id), do: "guidance_request:#{guidance_request_id}"

  defp approve_scope_expansion_transaction(repo, %Session{} = session, arguments, allowed_file_globs, rationale) do
    repo.transaction(fn ->
      work_package_id = Session.work_package_id(session)

      with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
           :ok <- lock_work_package(repo, work_package_id),
           {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
           :ok <- require_scope_guard_package(state.work_package),
           {:ok, result} <-
             approve_scope_expansion_result(
               repo,
               session,
               state.work_package,
               arguments,
               allowed_file_globs,
               rationale
             ) do
        result
      else
        {:tool_error, reason} -> repo.rollback({:tool_error, reason})
        {:error, reason} -> repo.rollback({:error, reason})
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp approve_scope_expansion_result(
         repo,
         %Session{} = session,
         %WorkPackage{} = work_package,
         arguments,
         allowed_file_globs,
         rationale
       ) do
    case existing_scope_expansion_approval(
           repo,
           session,
           work_package.id,
           arguments,
           allowed_file_globs,
           rationale
         ) do
      {:ok, event} ->
        {:ok, scope_expansion_approval_result(work_package, event)}

      {:error, :not_found} ->
        with :ok <- reject_ready_work_package(work_package),
             {:ok, effective_globs} <- ScopeGuard.approve_file_globs(work_package, allowed_file_globs),
             {:ok, updated_work_package} <-
               WorkPackageRepository.update(repo, work_package.id, %{"allowed_file_globs" => effective_globs}),
             {:ok, event} <-
               PlanningRepository.append_audit_progress_event(
                 repo,
                 session.assignment,
                 scope_expansion_approval_attrs(
                   work_package,
                   updated_work_package,
                   arguments,
                   allowed_file_globs,
                   rationale
                 )
               ) do
          {:ok, scope_expansion_approval_result(updated_work_package, event)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_scope_expansion_approval(
         repo,
         %Session{} = session,
         work_package_id,
         arguments,
         allowed_file_globs,
         rationale
       ) do
    idempotency_key =
      scope_expansion_approval_idempotency_key(
        work_package_id,
        arguments,
        allowed_file_globs,
        rationale
      )

    case PlanningRepository.get_progress_event_by_idempotency_key(
           repo,
           work_package_id,
           idempotency_key,
           session.assignment.grant_id
         ) do
      {:ok, event} ->
        validate_scope_expansion_approval_event(event, session, arguments, allowed_file_globs, rationale)

      {:error, :not_found} ->
        with {:ok, event} <- existing_work_package_progress_event(repo, session, idempotency_key) do
          validate_scope_expansion_approval_event(event, session, arguments, allowed_file_globs, rationale)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_scope_expansion_approval_event(
         %ProgressEvent{} = event,
         %Session{} = session,
         arguments,
         allowed_file_globs,
         rationale
       ) do
    with :ok <- scope_expansion_approval_actor_matches?(event, session),
         :ok <- scope_expansion_approval_payload_matches?(event, arguments, allowed_file_globs, rationale) do
      {:ok, event}
    end
  end

  defp scope_expansion_approval_actor_matches?(%ProgressEvent{actor_id: event_actor_id}, %Session{} = session) do
    current_actor_id = session.assignment.claimed_by

    cond do
      filled_string?(event_actor_id) and filled_string?(current_actor_id) ->
        if String.trim(event_actor_id) == String.trim(current_actor_id), do: :ok, else: {:error, :idempotency_conflict}

      filled_string?(event_actor_id) ->
        {:error, :idempotency_conflict}

      true ->
        :ok
    end
  end

  defp scope_expansion_approval_payload_matches?(
         %ProgressEvent{summary: summary, body: body, status: status, payload: payload},
         arguments,
         allowed_file_globs,
         rationale
       )
       when is_map(payload) do
    expected_request_id = optional_trimmed_string(arguments, "request_id")

    if summary == "Scope expansion approved" and
         body == rationale and
         status == "scope_expansion_approved" and
         Map.get(payload, "type") == "scope_expansion_approval" and
         Map.get(payload, "source_tool") == "approve_scope_expansion" and
         Map.get(payload, "approved") == true and
         Map.get(payload, "request_id") == expected_request_id and
         Map.get(payload, "approved_file_globs") == allowed_file_globs do
      :ok
    else
      {:error, :idempotency_conflict}
    end
  end

  defp scope_expansion_approval_payload_matches?(%ProgressEvent{}, _arguments, _allowed_file_globs, _rationale) do
    {:error, :idempotency_conflict}
  end

  defp scope_expansion_approval_result(%WorkPackage{} = work_package, %ProgressEvent{} = event) do
    %{
      "work_package" => work_package_payload(work_package),
      "allowed_file_globs" => Map.get(event.payload || %{}, "allowed_file_globs", work_package.allowed_file_globs),
      "progress_event" => progress_event_payload(event)
    }
  end

  defp require_scope_guard_package(%WorkPackage{} = work_package) do
    if ScopeGuard.required?(work_package), do: :ok, else: {:error, "scope_guard_not_required"}
  end

  defp scope_expansion_approval_attrs(%WorkPackage{} = previous_work_package, %WorkPackage{} = updated_work_package, arguments, allowed_file_globs, rationale) do
    request_id = optional_trimmed_string(arguments, "request_id")

    payload =
      %{
        "type" => "scope_expansion_approval",
        "source_tool" => "approve_scope_expansion",
        "approved" => true,
        "request_id" => request_id,
        "approved_file_globs" => allowed_file_globs,
        "previous_allowed_file_globs" => previous_work_package.allowed_file_globs || [],
        "allowed_file_globs" => updated_work_package.allowed_file_globs || []
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    %{
      "summary" => "Scope expansion approved",
      "body" => rationale,
      "status" => "scope_expansion_approved",
      "idempotency_key" =>
        scope_expansion_approval_idempotency_key(
          previous_work_package.id,
          arguments,
          allowed_file_globs,
          rationale
        ),
      "payload" => payload
    }
  end

  defp scope_expansion_approval_idempotency_key(
         work_package_id,
         arguments,
         allowed_file_globs,
         rationale
       ) do
    request_id = optional_trimmed_string(arguments, "request_id")

    %{
      "type" => "scope_expansion_approval",
      "source_tool" => "approve_scope_expansion",
      "work_package_id" => work_package_id,
      "request_id" => request_id,
      "approved_file_globs" => allowed_file_globs,
      "rationale" => rationale
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> metadata_idempotency_key()
  end

  defp optional_trimmed_string(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end
  end

  defp optional_request_id(arguments, key) do
    case Map.get(arguments, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "blank_request_id"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "invalid_request_id"}
    end
  end

  defp run_architect_transaction(repo, fun) do
    case repo.transaction(fn -> rollback_architect_transaction_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_architect_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_architect_transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})
  defp rollback_architect_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp run_worker_transaction(repo, fun) do
    case repo.transaction(fn -> rollback_worker_transaction_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:mcp_error, code, message, data}} -> {:error, code, message, data}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_worker_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_worker_transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})

  defp rollback_worker_transaction_result(repo, {:error, code, message, data}) do
    repo.rollback({:mcp_error, code, message, data})
  end

  defp rollback_worker_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp architect_session(repo, session, capability) when is_binary(capability) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_architect_assignment(session.assignment),
         :ok <- require_architect_capability(session.assignment, capability) do
      {:ok, session}
    end
  end

  defp architect_session(repo, session, capabilities) when is_list(capabilities) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_architect_assignment(session.assignment),
         :ok <- require_architect_capabilities(session.assignment, capabilities) do
      {:ok, session}
    end
  end

  defp require_live_architect_grant(repo, %Session{} = session) do
    case AccessGrantRepository.get(repo, session.assignment.grant_id) do
      {:ok, %AccessGrant{} = grant} ->
        with :ok <- require_session_grant_match(session.assignment, grant),
             :ok <- require_live_grant(grant, DateTime.utc_now(:microsecond)),
             :ok <- require_architect_assignment(session.assignment) do
          {:ok, grant}
        end

      {:error, :not_found} ->
        {:error, :phase_scope_not_available}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_session_grant_match(assignment, %AccessGrant{} = grant) do
    if assignment.grant_id == grant.id and
         assignment.work_package_id == grant.work_package_id and
         assignment.phase_id == grant.phase_id and
         assignment.display_key == grant.display_key and
         assignment.grant_role == grant.grant_role and
         assignment.capabilities == grant.capabilities and
         assignment.claimed_at == grant.claimed_at and
         assignment.claimed_by == grant.claimed_by do
      :ok
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp require_live_grant(%AccessGrant{revoked_at: %DateTime{}}, _now), do: {:error, :assignment_revoked}

  defp require_live_grant(%AccessGrant{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    if DateTime.compare(expires_at, now) == :gt do
      :ok
    else
      {:error, :expired}
    end
  end

  defp require_live_grant(%AccessGrant{expires_at: nil}, %DateTime{}), do: :ok

  defp require_architect_capabilities(assignment, capabilities) do
    Enum.reduce_while(capabilities, :ok, fn capability, :ok ->
      case require_architect_capability(assignment, capability) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp require_architect_work_package_scope(%Session{} = session, work_package_id) do
    if Session.work_package_id(session) == work_package_id do
      :ok
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp require_architect_phase_scope(repo, %Session{} = session, phase_id) do
    case architect_phase_scope(repo, session) do
      {:ok, ^phase_id} -> :ok
      {:ok, _other_phase_id} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp architect_phase_scope(repo, %Session{} = session) do
    case Session.phase_id(session) do
      phase_id when is_binary(phase_id) and phase_id != "" -> {:ok, phase_id}
      nil -> architect_session_anchor_phase_scope(repo, session)
      _phase_id -> {:error, :phase_scope_not_available}
    end
  end

  defp architect_session_anchor_phase_scope(repo, %Session{} = session) when is_atom(repo) do
    case Session.work_package_id(session) do
      work_package_id when is_binary(work_package_id) -> architect_anchor_phase_scope(repo, work_package_id)
      _work_package_id -> {:error, :phase_scope_not_available}
    end
  end

  defp architect_session_anchor_phase_scope(_repo, %Session{}), do: {:error, :phase_scope_not_available}

  defp architect_anchor_phase_scope(repo, work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %{phase_id: phase_id}} when is_binary(phase_id) and phase_id != "" -> {:ok, phase_id}
      {:ok, _work_package} -> {:error, :phase_scope_not_available}
      {:error, _reason} -> {:error, :phase_scope_not_available}
    end
  end

  defp architect_child_phase_anchor(repo, %Session{} = session) do
    with {:ok, grant} <- require_live_architect_grant(repo, session) do
      architect_child_phase_anchor(repo, session, grant)
    end
  end

  defp architect_child_phase_anchor(repo, %Session{} = session, %AccessGrant{} = grant) do
    with {:ok, phase_id} <- explicit_grant_phase_id(grant),
         {:ok, anchor} <- architect_anchor_work_package(repo, session),
         :ok <- require_frozen_anchor_scope(anchor, grant) do
      {:ok, phase_id, anchor}
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp explicit_grant_phase_id(%AccessGrant{phase_id: phase_id}) when is_binary(phase_id) and phase_id != "", do: {:ok, phase_id}
  defp explicit_grant_phase_id(%AccessGrant{}), do: {:error, :phase_scope_not_available}

  defp require_architect_phase_anchor(repo, %Session{} = session, phase_id) when is_atom(repo) and is_binary(phase_id) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, anchor} <- architect_anchor_work_package(repo, session) do
      require_architect_anchor_scope(anchor, grant, phase_id)
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_architect_anchor_scope(%WorkPackage{} = anchor, %AccessGrant{} = grant, phase_id) do
    cond do
      anchor.phase_id != phase_id ->
        {:error, :phase_scope_not_available}

      architect_explicit_phase_grant?(grant) ->
        require_frozen_anchor_scope(anchor, grant)

      true ->
        :ok
    end
  end

  defp architect_explicit_phase_grant?(%AccessGrant{grant_role: "architect", phase_id: phase_id}) when is_binary(phase_id) and phase_id != "",
    do: true

  defp architect_explicit_phase_grant?(%AccessGrant{}), do: false

  defp explicit_phase_id?(phase_id) when is_binary(phase_id), do: String.trim(phase_id) != ""
  defp explicit_phase_id?(_phase_id), do: false

  defp require_frozen_anchor_scope(%WorkPackage{} = anchor, %AccessGrant{} = grant) do
    if grant.phase_id == anchor.phase_id and grant.scope_repo == anchor.repo and grant.scope_base_branch == anchor.base_branch do
      :ok
    else
      {:error, :phase_scope_not_available}
    end
  end

  defp architect_tool_capability("create_child_work_package"), do: "create:child_work_package"
  defp architect_tool_capability("mint_child_worker_key"), do: "mint:child_worker_key"
  defp architect_tool_capability("revoke_child_worker_key"), do: "revoke:child_worker_key"
  defp architect_tool_capability("list_work_requests"), do: "read:work_request"
  defp architect_tool_capability("read_work_request"), do: "read:work_request"
  defp architect_tool_capability("list_guidance_requests"), do: "read:guidance_request"
  defp architect_tool_capability("read_guidance_request"), do: "read:guidance_request"
  defp architect_tool_capability("answer_guidance_request"), do: "write:guidance_request"
  defp architect_tool_capability("escalate_guidance_request"), do: "write:guidance_request"
  defp architect_tool_capability("set_work_request_status"), do: "write:work_request"
  defp architect_tool_capability("ask_work_request_question"), do: "write:work_request"
  defp architect_tool_capability("answer_work_request_question"), do: "write:work_request"
  defp architect_tool_capability("close_work_request_question"), do: "write:work_request"
  defp architect_tool_capability("record_work_request_decision"), do: "write:work_request"
  defp architect_tool_capability("add_work_request_planned_slice"), do: "write:work_request"
  defp architect_tool_capability("approve_work_request_planned_slice"), do: "write:work_request"
  defp architect_tool_capability("skip_work_request_planned_slice"), do: "write:work_request"
  defp architect_tool_capability("mark_work_request_sliced"), do: "write:work_request"
  defp architect_tool_capability("dispatch_work_request_planned_slice"), do: "dispatch:work_request"
  defp architect_tool_capability("prepare_work_package_worktree"), do: "dispatch:work_request"
  defp architect_tool_capability("cleanup_work_package_worktree"), do: "dispatch:work_request"
  defp architect_tool_capability("read_phase_board"), do: "read:phase"
  defp architect_tool_capability("approve_scope_expansion"), do: "approve:scope_expansion"
  defp architect_tool_capability("request_child_replan"), do: "request:child_replan"
  defp architect_tool_capability("approve_child_ready_state"), do: "approve:child_ready_state"
  defp architect_tool_capability("merge_child_into_phase"), do: "merge:child_into_phase"
  defp architect_tool_capability("split_work_package"), do: "split:child_work_package"
  defp architect_tool_capability("publish_phase_update"), do: "publish:phase_update"

  defp phase7_not_implemented(tool) do
    {:error, -32_604, "Not implemented",
     %{
       "tool" => tool,
       "reason" => "phase7_not_implemented",
       "phase" => "Phase 7",
       "detail" => "This Phase 7 architect workflow is not implemented in the current package."
     }}
  end

  defp read_current_virtual_file(repo, session, file_name) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_worker_assignment(session.assignment),
         {:ok, markdown} <- PlanningRenderer.render(repo, Session.work_package_id(session), file_name) do
      {:ok, tool_result(%{"uri" => "sympp://work-packages/#{Session.work_package_id(session)}/#{file_name}", "text" => markdown})}
    else
      {:error, reason} -> worker_error(reason, "read_#{file_name}")
    end
  end

  defp normalize_update_task_plan_result({:tool_error, reason}),
    do: {:error, -32_602, "Invalid params", %{"tool" => "update_task_plan", "reason" => reason}}

  defp normalize_update_task_plan_result({:error, reason}),
    do: worker_error(reason, "update_task_plan")

  defp normalize_update_task_plan_result(result), do: result

  defp read_task_plan_file(repo, session) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_worker_assignment(session.assignment),
         work_package_id = Session.work_package_id(session),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
         {:ok, markdown} <- PlanningRenderer.render_state(state, "task_plan.md") do
      {:ok,
       tool_result(%{
         "uri" => "sympp://work-packages/#{work_package_id}/task_plan.md",
         "text" => markdown,
         "version" => plan_version(state.plan_nodes)
       })}
    else
      {:error, reason} -> worker_error(reason, "read_task_plan.md")
    end
  end

  defp update_task_plan(repo, session, arguments) do
    with {:ok, expected_version} <- required_integer(arguments, "expected_version"),
         work_package_id = Session.work_package_id(session),
         {:ok, plan_nodes, version} <-
           apply_plan_update(repo, session.assignment, work_package_id, expected_version, arguments) do
      {:ok,
       tool_result(%{
         "plan_nodes" => Enum.map(plan_nodes, &plan_node_payload/1),
         "version" => version
       })}
    end
  end

  defp apply_plan_update(repo, assignment, work_package_id, expected_version, %{"patch" => patch} = arguments) when is_map(patch) do
    with :ok <- require_update_task_plan_keys(arguments, @plan_patch_argument_keys) do
      transaction_plan_update(repo, assignment, work_package_id, expected_version, fn ->
        apply_plan_patch(repo, work_package_id, patch)
      end)
    end
  end

  defp apply_plan_update(_repo, _assignment, _work_package_id, _expected_version, %{"patch" => _patch}) do
    {:tool_error, "invalid_patch"}
  end

  defp apply_plan_update(repo, assignment, work_package_id, expected_version, arguments) do
    with :ok <- require_update_task_plan_keys(arguments, @plan_append_argument_keys) do
      transaction_plan_update(repo, assignment, work_package_id, expected_version, fn ->
        append_plan_node_from_arguments(repo, work_package_id, arguments)
      end)
    end
  end

  defp transaction_plan_update(repo, assignment, work_package_id, expected_version, update_fun) do
    transaction_fun = fn ->
      transaction_result(repo, assignment, work_package_id, expected_version, update_fun)
    end

    case repo.transaction(transaction_fun) do
      {:ok, {plan_nodes, version}} -> {:ok, plan_nodes, version}
      {:error, reason} -> reason
    end
  end

  defp transaction_result(repo, assignment, work_package_id, expected_version, update_fun) do
    with :ok <- PlanningService.require_valid_assignment(repo, assignment),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
         :ok <- reject_ready_work_package(state.work_package),
         plan_nodes = state.plan_nodes,
         :ok <- require_plan_version(plan_nodes, expected_version),
         {:ok, updated_plan_nodes} <- transaction_result(repo, update_fun.()),
         {:ok, refreshed_plan_nodes} <- PlanningRepository.list_plan_nodes(repo, work_package_id) do
      {updated_plan_nodes, plan_version(refreshed_plan_nodes)}
    else
      {:tool_error, reason} -> repo.rollback({:tool_error, reason})
      {:error, reason} -> repo.rollback({:error, reason})
    end
  end

  defp transaction_result(_repo, {:ok, result}), do: {:ok, result}
  defp transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})
  defp transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp lock_access_grant(repo, grant_id) do
    query = from(access_grant in AccessGrant, where: access_grant.id == ^grant_id)

    case repo.update_all(query, set: [id: grant_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :phase_scope_not_available}
    end
  end

  defp append_plan_node_from_arguments(repo, work_package_id, arguments) do
    with {:ok, title} <- required_argument(arguments, "title"),
         attrs = %{
           "work_package_id" => work_package_id,
           "title" => title,
           "body" => optional_argument(arguments, "body", nil),
           "status" => optional_argument(arguments, "status", "pending")
         },
         {:ok, plan_node} <- PlanningRepository.append_plan_node(repo, maybe_put_id(attrs, arguments)) do
      {:ok, [plan_node]}
    end
  end

  defp apply_plan_patch(repo, work_package_id, patch) do
    nodes = Map.get(patch, "nodes", [])

    cond do
      not is_list(nodes) -> {:tool_error, "missing_patch_nodes"}
      nodes == [] -> {:tool_error, "missing_patch_nodes"}
      true -> apply_plan_node_patches(repo, work_package_id, nodes)
    end
  end

  defp apply_plan_node_patches(repo, work_package_id, nodes) do
    nodes
    |> Enum.reduce_while({:ok, []}, &apply_plan_node_patch_step(repo, work_package_id, &1, &2))
    |> reverse_plan_patch_result()
  end

  defp apply_plan_node_patch_step(repo, work_package_id, node_attrs, {:ok, plan_nodes}) do
    case apply_plan_node_patch(repo, work_package_id, node_attrs) do
      {:ok, plan_node} -> {:cont, {:ok, [plan_node | plan_nodes]}}
      {:tool_error, reason} -> {:halt, {:tool_error, reason}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp reverse_plan_patch_result({:ok, plan_nodes}), do: {:ok, Enum.reverse(plan_nodes)}
  defp reverse_plan_patch_result({:tool_error, reason}), do: {:tool_error, reason}
  defp reverse_plan_patch_result({:error, reason}), do: {:error, reason}

  defp apply_plan_node_patch(repo, work_package_id, %{"id" => id} = attrs) when is_binary(id) do
    id = String.trim(id)
    updates = Map.take(attrs, ["title", "body", "status"])

    with :ok <- require_known_plan_node_patch_keys(attrs),
         true <- id != "" || {:tool_error, "invalid_patch_node"},
         {:ok, existing_nodes} <- PlanningRepository.list_plan_nodes(repo, work_package_id) do
      existing_node = Enum.find(existing_nodes, &(&1.id == id))
      patch_existing_or_append_plan_node(repo, work_package_id, existing_node, id, attrs, updates)
    else
      {:tool_error, reason} -> {:tool_error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_plan_node_patch(_repo, _work_package_id, %{"id" => _id}), do: {:tool_error, "invalid_patch_node"}

  defp apply_plan_node_patch(repo, work_package_id, attrs) when is_map(attrs) do
    with :ok <- require_known_plan_node_patch_keys(attrs),
         {:ok, title} <- required_argument(attrs, "title") do
      PlanningRepository.append_plan_node(repo, %{
        "work_package_id" => work_package_id,
        "title" => title,
        "body" => optional_argument(attrs, "body", nil),
        "status" => optional_argument(attrs, "status", "pending")
      })
    end
  end

  defp apply_plan_node_patch(_repo, _work_package_id, _attrs), do: {:tool_error, "invalid_patch_node"}

  defp patch_existing_or_append_plan_node(repo, _work_package_id, %PlanNode{}, id, _attrs, updates) do
    with :ok <- require_plan_node_updates(updates) do
      PlanningService.update_plan_node(repo, id, updates)
    end
  end

  defp patch_existing_or_append_plan_node(repo, work_package_id, nil, id, attrs, _updates) do
    with {:ok, title} <- required_argument(attrs, "title") do
      PlanningRepository.append_plan_node(repo, %{
        "id" => id,
        "work_package_id" => work_package_id,
        "title" => title,
        "body" => optional_argument(attrs, "body", nil),
        "status" => optional_argument(attrs, "status", "pending")
      })
    end
  end

  defp require_known_plan_node_patch_keys(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in @plan_node_patch_keys)), do: :ok, else: {:tool_error, "invalid_patch_node"}
  end

  defp require_update_task_plan_keys(arguments, allowed_keys) do
    if Enum.all?(Map.keys(arguments), &(&1 in allowed_keys)), do: :ok, else: {:tool_error, "invalid_update_task_plan"}
  end

  defp require_plan_node_updates(updates) when map_size(updates) == 0, do: {:tool_error, "invalid_patch_node"}
  defp require_plan_node_updates(_updates), do: :ok

  defp require_plan_version(plan_nodes, expected_version) do
    if plan_version(plan_nodes) == expected_version, do: :ok, else: {:tool_error, "stale_plan_version"}
  end

  defp plan_version(plan_nodes) do
    material =
      Enum.map(plan_nodes, fn node ->
        %{
          id: node.id,
          title: node.title,
          body: node.body,
          status: node.status,
          position: node.position,
          updated_at: timestamp_version_part(node.updated_at)
        }
      end)

    :crypto.hash(:sha256, :erlang.term_to_binary(material))
    |> binary_part(0, 8)
    |> :binary.decode_unsigned()
    |> rem(9_007_199_254_740_991)
  end

  defp timestamp_version_part(nil), do: nil
  defp timestamp_version_part(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)

  defp append_authenticated_idempotent_finding(repo, %Session{} = session, finding_id, attrs) do
    work_package_id = Session.work_package_id(session)

    transaction_fun = fn ->
      append_authenticated_idempotent_finding_tx(repo, session, work_package_id, finding_id, attrs)
    end

    case run_worker_transaction(repo, transaction_fun) do
      {:error, :finding_insert_conflict} ->
        replay_finding_after_insert_conflict(repo, session.assignment, work_package_id, finding_id, attrs)

      result ->
        result
    end
  end

  defp append_authenticated_idempotent_finding_tx(repo, %Session{} = session, work_package_id, finding_id, attrs) do
    with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
         {:error, :id_already_exists} <-
           repo |> PlanningRepository.list_findings(work_package_id) |> find_existing_finding(finding_id, attrs),
         {:error, :id_already_exists} <-
           repo |> PlanningRepository.list_findings(work_package_id) |> find_existing_finding_by_idempotency(attrs),
         :ok <- reject_ready_evidence_mutation(repo, session, "append_finding") do
      case PlanningRepository.append_finding(repo, attrs) do
        {:ok, finding} ->
          {:ok, finding}

        {:error, reason} when reason in [:id_already_exists, :idempotency_key_conflict] ->
          {:error, :finding_insert_conflict}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp replay_finding_after_insert_conflict(repo, assignment, work_package_id, finding_id, attrs) do
    with :ok <- PlanningService.require_valid_assignment(repo, assignment) do
      replay_attempts = finding_replay_retry_attempts()

      case find_existing_finding_with_retry(repo, work_package_id, finding_id, attrs, replay_attempts) do
        {:error, :id_already_exists} ->
          find_existing_finding_by_idempotency_with_retry(repo, work_package_id, attrs, replay_attempts)

        result ->
          result
      end
    end
  end

  defp find_existing_finding_with_retry(repo, work_package_id, finding_id, attrs, attempts_left) do
    retry_fun = fn ->
      find_existing_finding_with_retry(repo, work_package_id, finding_id, attrs, attempts_left - 1)
    end

    repo
    |> PlanningRepository.list_findings(work_package_id)
    |> find_existing_finding(finding_id, attrs)
    |> retry_finding_replay_read(retry_fun, attempts_left)
  end

  defp find_existing_finding_by_idempotency_with_retry(repo, work_package_id, attrs, attempts_left) do
    retry_fun = fn ->
      find_existing_finding_by_idempotency_with_retry(repo, work_package_id, attrs, attempts_left - 1)
    end

    repo
    |> PlanningRepository.list_findings(work_package_id)
    |> find_existing_finding_by_idempotency(attrs)
    |> retry_finding_replay_read(retry_fun, attempts_left)
  end

  defp retry_finding_replay_read({:error, reason}, retry_fun, attempts_left)
       when reason in [:id_already_exists, :database_busy] and attempts_left > 0 do
    Process.sleep(5)
    retry_fun.()
  end

  defp retry_finding_replay_read(result, _retry_fun, _attempts_left), do: result

  defp find_existing_finding({:ok, findings}, finding_id, attrs) do
    case Enum.find(findings, &(&1.id == finding_id)) do
      %{} = finding ->
        if finding_idempotency_match?(finding, attrs) do
          idempotent_finding_result(finding, attrs)
        else
          {:tool_error, "idempotency_conflict"}
        end

      nil ->
        {:error, :id_already_exists}
    end
  end

  defp find_existing_finding({:error, reason}, _finding_id, _attrs), do: {:error, reason}

  defp find_existing_finding_by_idempotency({:ok, findings}, attrs) do
    case Enum.find(findings, &finding_idempotency_match?(&1, attrs)) do
      %{} = finding -> idempotent_finding_result(finding, attrs)
      nil -> {:error, :id_already_exists}
    end
  end

  defp find_existing_finding_by_idempotency({:error, reason}, _attrs), do: {:error, reason}

  defp finding_idempotency_match?(finding, attrs) do
    finding.idempotency_key == Map.get(attrs, "idempotency_key")
  end

  defp idempotent_finding_result(finding, attrs) do
    fields = if Map.get(attrs, "caller_supplied_id"), do: ["id", "title", "body", "severity"], else: ["title", "body", "severity"]
    expected = Map.take(attrs, fields)
    actual = Map.take(%{"id" => finding.id, "title" => finding.title, "body" => finding.body, "severity" => finding.severity}, fields)

    if expected == actual do
      {:ok, finding}
    else
      {:tool_error, "idempotency_conflict"}
    end
  end

  defp optional_finding_id(arguments, session, idempotency_key) do
    case Map.get(arguments, "id") do
      id when is_binary(id) ->
        case String.trim(id) do
          "" -> {:tool_error, "invalid_id"}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:ok, generated_finding_id(session, idempotency_key)}

      _id ->
        {:tool_error, "invalid_id"}
    end
  end

  defp generated_finding_id(session, idempotency_key) do
    material = [session.assignment.work_package_id, session.assignment.grant_id, idempotency_key] |> Enum.join(":")
    "finding_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp finding_replay_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_finding_replay_retry_attempts, @finding_replay_retry_attempts)
    |> max(0)
  end

  defp progress_replay_retry_attempts, do: finding_replay_retry_attempts()

  defp append_scoped_progress(repo, session, arguments, tool, payload) do
    with {:ok, session} <- scoped_session(repo, session, arguments),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments) do
      idempotency_key = scoped_progress_idempotency_key(tool, String.trim(idempotency_key), session)

      attrs = %{
        "summary" => summary,
        "body" => optional_argument(arguments, "body", nil),
        "status" => optional_argument(arguments, "status", "recorded"),
        "idempotency_key" => idempotency_key,
        "payload" => merge_tool_payload(tool, caller_payload, payload)
      }

      append_progress_event_or_replay(repo, session, attrs, idempotency_key, tool)
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
      {:error, reason} -> worker_error(reason, tool)
    end
  end

  defp append_status_reason_event(_repo, %Session{}, _expected_status, _status, nil), do: {:ok, nil}

  defp append_status_reason_event(repo, %Session{} = session, expected_status, status, reason) when is_binary(reason) do
    payload = %{"type" => "status_transition", "from_status" => expected_status, "to_status" => status}
    idempotency_payload = Map.put(payload, "reason_event_id", System.unique_integer([:positive, :monotonic]))

    append_scoped_progress(
      repo,
      session,
      %{
        "summary" => "Status changed to #{status}",
        "body" => reason,
        "status" => "status_changed",
        "idempotency_key" => metadata_idempotency_key(Map.put(idempotency_payload, "reason", reason))
      },
      "set_status",
      payload
    )
  end

  defp optional_reason(arguments) do
    case Map.get(arguments, "reason") do
      nil ->
        {:ok, nil}

      reason when is_binary(reason) ->
        case String.trim(reason) do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      _reason ->
        {:tool_error, "invalid_reason"}
    end
  end

  defp append_progress_event_or_replay(repo, %Session{} = session, attrs, idempotency_key, tool) do
    case existing_progress_event(repo, session, idempotency_key) do
      {:ok, event} ->
        replay_progress_event(repo, session, event, attrs, tool)

      {:error, :not_found} ->
        append_new_progress_event_or_replay(repo, session, attrs, idempotency_key, tool)

      {:error, reason} ->
        worker_error(reason, tool)
    end
  end

  defp append_new_progress_event_or_replay(repo, %Session{} = session, attrs, idempotency_key, tool) do
    transaction_fun = fn ->
      with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
           :ok <- reject_ready_evidence_mutation(repo, session, tool),
           {:ok, event} <- PlanningService.append_authenticated_progress_event(repo, session.assignment, attrs),
           :ok <- append_investigation_recommendation_artifact(repo, session, tool, event) do
        {:ok, event}
      end
    end

    case run_worker_transaction(repo, transaction_fun) do
      {:ok, event} ->
        {:ok, tool_result(%{"progress_event" => progress_event_payload(event)})}

      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}

      {:error, :idempotency_key_conflict} ->
        replay_progress_event_with_retry(repo, session, attrs, idempotency_key, tool, progress_replay_retry_attempts())

      {:error, reason} ->
        worker_error(reason, tool)
    end
  end

  defp append_investigation_recommendation_artifact(repo, %Session{} = session, "request_scope_expansion", %ProgressEvent{} = event) do
    if Map.has_key?(event.payload || %{}, "recommendation_artifact_id") do
      append_recommendation_artifact(repo, session, event)
    else
      :ok
    end
  end

  defp append_investigation_recommendation_artifact(_repo, %Session{}, _tool, %ProgressEvent{}), do: :ok

  defp append_recommendation_artifact(repo, %Session{} = session, %ProgressEvent{}) do
    work_package_id = session.assignment.work_package_id

    attrs = %{
      "id" => recommendation_artifact_id(work_package_id),
      "work_package_id" => work_package_id,
      "path" => "recommendation.md",
      "title" => "Investigation recommendation",
      "kind" => "recommendation"
    }

    append_recommendation_artifact(attrs, repo)
  end

  defp append_recommendation_artifact(attrs, repo) do
    case PlanningRepository.get_artifact(repo, attrs["id"]) do
      {:ok, nil} ->
        case PlanningService.append_artifact(repo, attrs) do
          {:ok, _artifact} -> :ok
          {:error, :id_already_exists} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, %Artifact{} = artifact} ->
        repair_recommendation_artifact(repo, attrs, artifact)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repair_recommendation_artifact(repo, attrs, %Artifact{} = artifact) do
    if artifact.work_package_id == attrs["work_package_id"] do
      case PlanningRepository.update_artifact(repo, artifact, recommendation_artifact_repair_attrs(attrs, artifact)) do
        {:ok, _artifact} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :id_already_exists}
    end
  end

  defp recommendation_artifact_repair_attrs(attrs, %Artifact{} = artifact) do
    %{
      work_package_id: attrs["work_package_id"],
      path: attrs["path"],
      title: attrs["title"],
      kind: attrs["kind"],
      uri: repaired_recommendation_artifact_uri(attrs, artifact)
    }
  end

  defp repaired_recommendation_artifact_uri(%{"uri" => uri}, %Artifact{}) when not is_nil(uri), do: uri

  defp repaired_recommendation_artifact_uri(attrs, %Artifact{} = artifact) do
    if artifact.work_package_id == attrs["work_package_id"] and artifact.path == attrs["path"] and artifact.title == attrs["title"] and artifact.kind == attrs["kind"] do
      artifact.uri
    else
      nil
    end
  end

  defp recommendation_artifact_id(work_package_id) do
    material = [work_package_id, "recommendation", "recommendation.md"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp reject_ready_evidence_mutation(repo, %Session{} = session, tool)
       when tool in [
              "append_finding",
              "append_progress",
              "attach_branch",
              "attach_pr",
              "sync_pr",
              "report_blocker",
              "request_scope_expansion",
              "resolve_blocker",
              "submit_review_package",
              "attach_review_suite_result"
            ] do
    work_package_id = Session.work_package_id(session)

    with :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id) do
      reject_ready_work_package(state.work_package)
    end
  end

  defp reject_ready_evidence_mutation(_repo, %Session{}, _tool), do: :ok

  defp reject_ready_work_package(%WorkPackage{kind: "phase_child", status: status}) when status in ["merging_into_phase", "merged_into_phase"] do
    {:tool_error, "child_under_architect_control"}
  end

  defp reject_ready_work_package(%WorkPackage{status: status}) when status in ["ready_for_human_merge", "ready_for_architect_merge"],
    do: {:tool_error, "already_ready"}

  defp reject_ready_work_package(%WorkPackage{}), do: :ok

  defp reject_architect_controlled_child(%WorkPackage{kind: "phase_child", status: "merging_into_phase"}, "blocked"), do: :ok

  defp reject_architect_controlled_child(%WorkPackage{kind: "phase_child", status: status}, _next_status)
       when status in ["merging_into_phase", "merged_into_phase"] do
    {:tool_error, "child_under_architect_control"}
  end

  defp reject_architect_controlled_child(%WorkPackage{}, _next_status), do: :ok

  defp replay_progress_event_with_retry(repo, %Session{} = session, attrs, idempotency_key, tool, attempts_left) do
    retry_fun = fn ->
      replay_progress_event_with_retry(repo, session, attrs, idempotency_key, tool, attempts_left - 1)
    end

    repo
    |> replay_progress_event(session, attrs, idempotency_key, tool)
    |> retry_missing_progress_event(retry_fun, attempts_left)
  end

  defp replay_progress_event(repo, %Session{} = session, %ProgressEvent{} = event, attrs, tool) do
    case PlanningService.require_valid_assignment(repo, session.assignment) do
      :ok -> replay_matching_progress_event(repo, session, event, attrs, tool)
      {:error, reason} -> worker_error(reason, tool)
    end
  end

  defp replay_progress_event(repo, %Session{} = session, attrs, idempotency_key, tool) do
    case existing_progress_event(repo, session, idempotency_key) do
      {:ok, event} -> replay_progress_event(repo, session, event, attrs, tool)
      {:error, reason} -> worker_error(reason, tool)
    end
  end

  defp existing_progress_event(repo, %Session{} = session, idempotency_key) do
    case PlanningRepository.get_progress_event_by_idempotency_key(
           repo,
           Session.work_package_id(session),
           idempotency_key,
           session.assignment.grant_id
         ) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> existing_work_package_progress_event(repo, session, idempotency_key)
      {:error, reason} -> {:error, reason}
    end
  end

  defp existing_work_package_progress_event(repo, %Session{} = session, idempotency_key) do
    case PlanningRepository.list_progress_events(repo, Session.work_package_id(session)) do
      {:ok, progress_events} ->
        matching_progress_event(progress_events, idempotency_key)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp matching_progress_event(progress_events, idempotency_key) do
    case Enum.find(progress_events, fn event -> event.idempotency_key == idempotency_key end) do
      %ProgressEvent{} = event -> {:ok, event}
      nil -> {:error, :not_found}
    end
  end

  defp retry_missing_progress_event({:error, _code, _message, %{"reason" => "not_found"}}, retry_fun, attempts_left) when attempts_left > 0 do
    Process.sleep(5)
    retry_fun.()
  end

  defp retry_missing_progress_event(result, _retry_fun, _attempts_left), do: result

  defp replay_matching_progress_event(_repo, %Session{} = _session, %ProgressEvent{} = event, attrs, tool) do
    if progress_replay_matches?(event, attrs) do
      {:ok, tool_result(%{"progress_event" => progress_event_payload(event)})}
    else
      {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => "idempotency_conflict"}}
    end
  end

  defp progress_replay_matches?(%ProgressEvent{} = event, attrs) do
    normalized_payload = normalized_progress_payload(event, attrs)

    event.summary == Map.get(attrs, "summary") and
      event.body == Map.get(attrs, "body") and
      event.status == Map.get(attrs, "status") and
      progress_payload_replay_matches?(event.payload, normalized_payload)
  end

  defp progress_payload_replay_matches?(%{"type" => "scope_expansion_request", "source_tool" => "request_scope_expansion"} = existing, normalized) do
    existing == normalized or
      legacy_scope_expansion_replay_matches?(existing, normalized)
  end

  defp progress_payload_replay_matches?(%{"type" => "pr", "source_tool" => "attach_pr"} = existing, %{"type" => "pr", "source_tool" => "attach_pr"} = normalized) do
    existing == normalized or legacy_attach_pr_replay_matches?(existing, normalized)
  end

  defp progress_payload_replay_matches?(existing, normalized), do: existing == normalized

  defp legacy_scope_expansion_replay_matches?(existing, normalized) do
    legacy_normalized =
      case Map.fetch(existing, "recommendation_artifact_id") do
        {:ok, artifact_id} -> Map.put(normalized, "recommendation_artifact_id", artifact_id)
        :error -> Map.delete(normalized, "recommendation_artifact_id")
      end

    existing == legacy_normalized
  end

  defp legacy_attach_pr_replay_matches?(existing, normalized) do
    existing == Map.take(normalized, ["type", "source_tool", "url", "head_sha"])
  end

  defp normalized_progress_payload(%ProgressEvent{} = event, attrs) do
    attrs
    |> Map.merge(%{
      "id" => "replay_probe",
      "work_package_id" => event.work_package_id,
      "sequence" => 1,
      "created_at" => event.created_at || DateTime.utc_now(:microsecond)
    })
    |> ProgressEvent.create_changeset(trusted_audit_metadata: true)
    |> Ecto.Changeset.apply_changes()
    |> Map.get(:payload)
  end

  defp metadata_event_attrs(%Session{} = session, arguments, tool, status, payload) do
    payload = Map.put(payload, "source_tool", tool)

    arguments =
      Map.put_new(arguments, "summary", status)
      |> Map.put_new("status", status)
      |> Map.put_new("idempotency_key", metadata_idempotency_key(payload))
      |> canonical_metadata_event_status(tool, status)

    with {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments),
         :ok <- validate_metadata_caller_payload(tool, caller_payload) do
      idempotency_key = scoped_progress_idempotency_key(tool, String.trim(idempotency_key), session)

      {:ok, idempotency_key,
       %{
         "summary" => summary,
         "body" => optional_argument(arguments, "body", nil),
         "status" => optional_argument(arguments, "status", "recorded"),
         "idempotency_key" => idempotency_key,
         "payload" => merge_tool_payload(tool, caller_payload, payload)
       }}
    end
  end

  defp canonical_metadata_event_status(arguments, "attach_review_suite_result", status), do: Map.put(arguments, "status", status)
  defp canonical_metadata_event_status(arguments, _tool, _status), do: arguments

  defp validate_metadata_caller_payload("attach_review_suite_result", caller_payload) when map_size(caller_payload) == 0, do: :ok
  defp validate_metadata_caller_payload("attach_review_suite_result", _caller_payload), do: {:tool_error, "unexpected_payload"}
  defp validate_metadata_caller_payload(_tool, _caller_payload), do: :ok

  defp append_metadata_event(repo, session, arguments, tool, status, payload) do
    case metadata_event_attrs(session, arguments, tool, status, payload) do
      {:ok, idempotency_key, attrs} -> append_progress_event_or_replay(repo, session, attrs, idempotency_key, tool)
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
    end
  end

  defp review_package_requested_head_sha(arguments) do
    case optional_head_sha(arguments) do
      {:ok, nil} -> {:tool_error, "missing_head_sha"}
      result -> result
    end
  end

  defp review_package_head_sha(head_sha, progress_events, %WorkPackage{} = work_package) do
    current_head_sha = latest_current_head_sha(progress_events)

    cond do
      is_binary(current_head_sha) and head_sha == current_head_sha ->
        {:ok, head_sha}

      is_binary(current_head_sha) ->
        {:tool_error, "stale_head_sha"}

      merge_required?(work_package) ->
        {:tool_error, "missing_current_head_sha"}

      true ->
        {:ok, head_sha}
    end
  end

  defp optional_head_sha(arguments) do
    case Map.fetch(arguments, "head_sha") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, head_sha} when is_binary(head_sha) ->
        case String.trim(head_sha) do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _head_sha} ->
        {:tool_error, "invalid_head_sha"}
    end
  end

  defp submit_review_package_transaction(repo, %Session{} = session, arguments, artifacts, payload) do
    case repo.transaction(fn ->
           submit_review_package_transaction_body(repo, session, arguments, artifacts, payload)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, {:mcp_error, code, message, data}} -> {:error, code, message, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp submit_review_package_transaction_body(repo, %Session{} = session, arguments, artifacts, payload) do
    work_package_id = Session.work_package_id(session)

    with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
         {:ok, requested_head_sha} <- review_package_requested_head_sha(arguments) do
      payload = Map.put(payload, "head_sha", requested_head_sha)

      submit_or_replay_review_package(
        repo,
        session,
        arguments,
        artifacts,
        payload,
        requested_head_sha,
        state.work_package,
        state.progress_events
      )
    else
      {:tool_error, reason} ->
        repo.rollback({:mcp_error, -32_602, "Invalid params", %{"tool" => "submit_review_package", "reason" => reason}})

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp submit_or_replay_review_package(
         repo,
         %Session{} = session,
         arguments,
         artifacts,
         payload,
         requested_head_sha,
         work_package,
         progress_events
       ) do
    case replay_existing_metadata_event(repo, session, arguments, "submit_review_package", "review_package_submitted", payload, progress_events) do
      {:ok, result} ->
        result

      :not_found ->
        submit_new_review_package(
          repo,
          session,
          arguments,
          artifacts,
          payload,
          requested_head_sha,
          work_package,
          progress_events
        )

      {:error, code, message, data} ->
        repo.rollback({:mcp_error, code, message, data})
    end
  end

  defp submit_new_review_package(repo, %Session{} = session, arguments, artifacts, payload, requested_head_sha, work_package, progress_events) do
    case review_package_head_sha(requested_head_sha, progress_events, work_package) do
      {:ok, head_sha} ->
        case append_metadata_event(repo, session, arguments, "submit_review_package", "review_package_submitted", payload) do
          {:ok, result} -> persist_review_artifacts_or_rollback(repo, session, artifacts, head_sha, result)
          {:error, code, message, data} -> repo.rollback({:mcp_error, code, message, data})
        end

      {:tool_error, reason} ->
        repo.rollback({:mcp_error, -32_602, "Invalid params", %{"tool" => "submit_review_package", "reason" => reason}})
    end
  end

  defp replay_existing_metadata_event(repo, %Session{} = session, arguments, tool, status, payload, progress_events) do
    case metadata_event_attrs(session, arguments, tool, status, payload) do
      {:ok, idempotency_key, attrs} ->
        case existing_metadata_event(repo, session, idempotency_key, tool, progress_events) do
          {:ok, event} -> replay_progress_event(repo, session, event, attrs, tool)
          {:error, :not_found} -> :not_found
          {:error, reason} -> worker_error(reason, tool)
        end

      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
    end
  end

  defp existing_metadata_event(_repo, %Session{}, idempotency_key, "submit_review_package", progress_events) when is_list(progress_events) do
    case Enum.find(progress_events, fn event -> event.idempotency_key == idempotency_key end) do
      %ProgressEvent{} = event -> {:ok, event}
      nil -> {:error, :not_found}
    end
  end

  defp existing_metadata_event(repo, %Session{} = session, idempotency_key, _tool, _progress_events) do
    PlanningRepository.get_progress_event_by_idempotency_key(
      repo,
      Session.work_package_id(session),
      idempotency_key,
      session.assignment.grant_id
    )
  end

  defp persist_review_artifacts_or_rollback(repo, %Session{} = session, artifacts, head_sha, result) do
    case append_review_artifacts(repo, session, artifacts, head_sha) do
      :ok -> result
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp append_review_artifacts(repo, %Session{} = session, artifacts, head_sha) do
    work_package_id = Session.work_package_id(session)

    case PlanningRepository.list_artifacts(repo, work_package_id) do
      {:ok, existing_artifacts} ->
        append_review_artifacts(repo, work_package_id, existing_artifacts, head_sha, artifacts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_review_artifacts(repo, work_package_id, existing_artifacts, head_sha, artifacts) do
    Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
      case append_review_artifact(repo, work_package_id, existing_artifacts, head_sha, artifact) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp append_review_artifact(repo, work_package_id, existing_artifacts, head_sha, artifact) do
    if persisted_review_artifact?(existing_artifacts, work_package_id, head_sha, artifact) do
      :ok
    else
      attrs = %{
        "id" => review_artifact_id(work_package_id, head_sha, artifact),
        "work_package_id" => work_package_id,
        "path" => artifact,
        "title" => artifact,
        "kind" => "review",
        "uri" => review_artifact_uri(artifact)
      }

      case PlanningService.append_artifact(repo, attrs) do
        {:ok, _artifact} -> :ok
        {:error, :id_already_exists} -> replay_review_artifact(repo, work_package_id, head_sha, artifact)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp replay_review_artifact(repo, work_package_id, head_sha, artifact) do
    case PlanningRepository.list_artifacts(repo, work_package_id) do
      {:ok, artifacts} ->
        if persisted_review_artifact?(artifacts, work_package_id, head_sha, artifact) do
          :ok
        else
          {:error, :id_already_exists}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp review_artifact_id(work_package_id, head_sha, artifact) do
    material = [work_package_id, head_sha || "no-head", artifact] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp review_artifact_uri(artifact) do
    if String.contains?(artifact, "://"), do: artifact, else: nil
  end

  defp attach_review_suite_result_transaction(repo, %Session{} = session, arguments, payload) do
    case repo.transaction(fn ->
           attach_review_suite_result_transaction_body(repo, session, arguments, payload)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, {:mcp_error, code, message, data}} -> {:error, code, message, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attach_review_suite_result_transaction_body(repo, %Session{} = session, arguments, payload) do
    case replay_existing_review_suite_result(repo, session, arguments, payload) do
      {:ok, result} ->
        result

      :new ->
        append_new_review_suite_result(repo, session, arguments, payload)

      {:error, code, message, data} ->
        repo.rollback({:mcp_error, code, message, data})
    end
  end

  defp replay_existing_review_suite_result(repo, %Session{} = session, arguments, payload) do
    case PlanningService.require_valid_assignment(repo, session.assignment) do
      :ok -> replay_existing_review_suite_result_for_valid_assignment(repo, session, arguments, payload)
      {:error, reason} -> worker_error(reason, "attach_review_suite_result")
    end
  end

  defp replay_existing_review_suite_result_for_valid_assignment(repo, %Session{} = session, arguments, payload) do
    replay_payload = review_suite_payload(payload, arguments, Map.fetch!(payload, "head_sha"))

    case metadata_event_attrs(session, arguments, "attach_review_suite_result", "review_suite_passed", replay_payload) do
      {:ok, idempotency_key, attrs} -> replay_existing_review_suite_result_event(repo, session, idempotency_key, attrs)
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "attach_review_suite_result", "reason" => reason}}
    end
  end

  defp replay_existing_review_suite_result_event(repo, %Session{} = session, idempotency_key, attrs) do
    case existing_progress_event(repo, session, idempotency_key) do
      {:ok, event} -> replay_progress_event(repo, session, event, attrs, "attach_review_suite_result")
      {:error, :not_found} -> :new
      {:error, reason} -> worker_error(reason, "attach_review_suite_result")
    end
  end

  defp append_new_review_suite_result(repo, %Session{} = session, arguments, payload) do
    work_package_id = Session.work_package_id(session)
    requested_head_sha = Map.fetch!(payload, "head_sha")

    with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
         {:ok, head_sha} <- review_package_head_sha(requested_head_sha, state.progress_events, state.work_package),
         :ok <- reject_failed_review_suite_result_override(state.progress_events, work_package_id, head_sha),
         payload <- review_suite_payload(payload, arguments, head_sha),
         {:ok, result} <- append_metadata_event(repo, session, arguments, "attach_review_suite_result", "review_suite_passed", payload),
         :ok <- append_review_suite_artifact(repo, work_package_id, head_sha) do
      result
    else
      {:tool_error, reason} ->
        repo.rollback({:mcp_error, -32_602, "Invalid params", %{"tool" => "attach_review_suite_result", "reason" => reason}})

      {:error, code, message, data} ->
        repo.rollback({:mcp_error, code, message, data})

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp review_suite_payload(payload, arguments, head_sha) do
    payload
    |> Map.put("head_sha", head_sha)
    |> maybe_put_review_suite_field(arguments, "lane")
    |> maybe_put_review_suite_field(arguments, "reviewer")
    |> maybe_put_review_suite_field(arguments, "round_id")
  end

  defp maybe_put_review_suite_field(payload, arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: payload, else: Map.put(payload, key, value)

      _value ->
        payload
    end
  end

  defp reject_failed_review_suite_result_override(progress_events, work_package_id, head_sha) do
    if Enum.any?(progress_events, &failed_review_suite_result_event?(&1, work_package_id, head_sha)) do
      {:tool_error, "failed_review_suite_result_exists"}
    else
      :ok
    end
  end

  defp failed_review_suite_result_event?(event, work_package_id, head_sha) do
    payload = event.payload

    dedicated_review_suite_result_event?(event, work_package_id) and
      review_head_matches?(payload, head_sha) and
      Map.get(payload, "work_package_id") == work_package_id and
      not (review_suite_status_passed?(Map.get(payload, "status")) and review_suite_verdict_passed?(Map.get(payload, "verdict")))
  end

  defp require_passing_review_suite_result(status, verdict) do
    if review_suite_status_passed?(status) and review_suite_verdict_passed?(verdict) do
      :ok
    else
      {:tool_error, "non_passing_review_suite_result"}
    end
  end

  defp normalized_review_suite_status(status) when is_binary(status), do: status |> String.trim() |> String.downcase()
  defp normalized_review_suite_status(_status), do: ""
  defp normalized_review_suite_verdict(verdict) when is_binary(verdict), do: verdict |> String.trim() |> String.downcase()
  defp normalized_review_suite_verdict(_verdict), do: ""

  defp review_suite_status_passed?(status) do
    normalized_review_suite_status(status) in ["passed", "pass", "green", "success"]
  end

  defp review_suite_verdict_passed?(verdict) do
    normalized_review_suite_verdict(verdict) in ["green", "passed", "pass", "success", "approved"]
  end

  defp append_review_suite_artifact(repo, work_package_id, head_sha) do
    case PlanningRepository.list_artifacts(repo, work_package_id) do
      {:ok, artifacts} -> maybe_append_review_suite_artifact(repo, work_package_id, head_sha, artifacts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_append_review_suite_artifact(repo, work_package_id, head_sha, artifacts) do
    if persisted_review_suite_artifact?(artifacts, work_package_id, head_sha) do
      :ok
    else
      insert_review_suite_artifact(repo, work_package_id, head_sha)
    end
  end

  defp insert_review_suite_artifact(repo, work_package_id, head_sha) do
    attrs = %{
      "id" => review_suite_artifact_id(work_package_id, head_sha),
      "work_package_id" => work_package_id,
      "path" => "review-suite-result.json",
      "title" => "Review-suite result",
      "kind" => "review_suite"
    }

    case PlanningService.append_artifact(repo, attrs) do
      {:ok, _artifact} -> :ok
      {:error, :id_already_exists} -> replay_review_suite_artifact(repo, work_package_id, head_sha)
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_review_suite_artifact(repo, work_package_id, head_sha) do
    case PlanningRepository.list_artifacts(repo, work_package_id) do
      {:ok, artifacts} -> replay_review_suite_artifact_result(work_package_id, head_sha, artifacts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_review_suite_artifact_result(work_package_id, head_sha, artifacts) do
    if persisted_review_suite_artifact?(artifacts, work_package_id, head_sha) do
      :ok
    else
      {:error, :id_already_exists}
    end
  end

  defp review_suite_artifact_id(work_package_id, head_sha) do
    material = [work_package_id, head_sha, "review-suite-result.json"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp persisted_review_suite_artifact?(artifacts, work_package_id, head_sha) do
    expected_id = review_suite_artifact_id(work_package_id, head_sha)

    Enum.any?(
      artifacts,
      &(&1.id == expected_id and &1.work_package_id == work_package_id and &1.kind == "review_suite" and &1.path == "review-suite-result.json")
    )
  end

  defp scoped_progress_idempotency_key("submit_review_package", idempotency_key, %Session{} = session) do
    ["submit_review_package", session.assignment.work_package_id, idempotency_key] |> Enum.join(":")
  end

  defp scoped_progress_idempotency_key("attach_review_suite_result", idempotency_key, %Session{} = session) do
    ["attach_review_suite_result", session.assignment.work_package_id, idempotency_key] |> Enum.join(":")
  end

  defp scoped_progress_idempotency_key(tool, idempotency_key, %Session{} = session) when tool in ["attach_branch", "attach_pr", "sync_pr"] do
    [tool, session.assignment.work_package_id, idempotency_key] |> Enum.join(":")
  end

  defp scoped_progress_idempotency_key(tool, idempotency_key, %Session{}), do: tool <> ":" <> idempotency_key

  defp readiness_gates(repo, state) do
    required_review_lanes = required_review_lanes(state.work_package)

    with {:ok, reasons} <- readiness_failure_reasons(repo, state, required_review_lanes) do
      missing = missing_readiness_gates(reasons)

      if missing == [], do: :ok, else: {:error, {:readiness_failed, missing, reasons}}
    end
  end

  defp missing_readiness_gates(reasons) do
    reasons
    |> Enum.map(&Map.fetch!(&1, "gate"))
    |> Enum.uniq()
  end

  defp readiness_failure_reasons(repo, state, required_review_lanes) do
    with {:ok, phase_child_reasons} <- phase_child_readiness_failure_reasons(repo, state.work_package) do
      {:ok, base_readiness_failure_reasons(state, required_review_lanes) ++ phase_child_reasons}
    end
  end

  defp base_readiness_failure_reasons(state, required_review_lanes) do
    [
      {readiness_status_missing?(state.work_package), readiness_status_gate(state.work_package)},
      {active_blocker?(state.progress_events), "no_active_blockers"},
      {incomplete_plan?(state), "plan_complete"},
      {acceptance_missing?(state), "acceptance_criteria_met"},
      {tests_missing?(state), "tests_passed"},
      {merge_metadata_missing?(state, "branch"), "branch_attached"},
      {merge_metadata_missing?(state, "pr"), "pr_attached"},
      {current_pr_state_missing?(state), "current_pr_state"},
      {review_suite_result_missing?(state), "review_suite_result"},
      {ScopeGuard.missing?(state.work_package, state.progress_events), @scope_guard_gate},
      {review_package_missing?(state, required_review_lanes), "review_package_submitted"},
      {review_artifacts_missing?(state, required_review_lanes), "review_artifacts_attached"},
      {review_lanes_missing?(state, required_review_lanes), "review_lanes_complete"},
      {investigation_findings_missing?(state), "findings_documented"},
      {investigation_recommendation_missing?(state), "recommendation_artifact_recorded"}
    ]
    |> Enum.flat_map(fn
      {true, @scope_guard_gate} -> ScopeGuard.failure_reasons(state.work_package, state.progress_events)
      {true, gate} -> [readiness_failure_reason(gate)]
      {false, _gate} -> []
    end)
  end

  defp phase_child_readiness_failure_reasons(repo, %WorkPackage{kind: "phase_child"} = child) do
    with {:ok, phase} <- readiness_phase(repo, child),
         {:ok, parent} <- readiness_phase_parent(repo, child) do
      reasons =
        []
        |> maybe_add_readiness_reason(phase.status != "active", "phase_active")
        |> maybe_add_readiness_reason(not readiness_phase_child_scope_ok?(child, parent), "phase_child_scope")

      {:ok, Enum.reverse(reasons)}
    end
  end

  defp phase_child_readiness_failure_reasons(_repo, %WorkPackage{}), do: {:ok, []}

  defp readiness_phase(repo, %WorkPackage{phase_id: phase_id}) when is_binary(phase_id) do
    if filled_string?(phase_id) do
      case PhaseRepository.get(repo, phase_id) do
        {:ok, phase} -> {:ok, phase}
        {:error, :not_found} -> {:ok, %{status: nil}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, %{status: nil}}
    end
  end

  defp readiness_phase(_repo, %WorkPackage{}), do: {:ok, %{status: nil}}

  defp readiness_phase_parent(repo, %WorkPackage{parent_id: parent_id}) when is_binary(parent_id) do
    if filled_string?(parent_id) do
      case WorkPackageRepository.get(repo, parent_id) do
        {:ok, parent} -> {:ok, parent}
        {:error, :not_found} -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, nil}
    end
  end

  defp readiness_phase_parent(_repo, %WorkPackage{}), do: {:ok, nil}

  defp readiness_phase_child_scope_ok?(%WorkPackage{} = child, %WorkPackage{} = parent) do
    child.parent_id == parent.id and child.phase_id == parent.phase_id and child.repo == parent.repo and child.base_branch == parent.base_branch and
      require_phase_child_file_scope(child, parent) == :ok
  end

  defp readiness_phase_child_scope_ok?(%WorkPackage{}, _parent), do: false

  defp maybe_add_readiness_reason(reasons, true, gate), do: [readiness_failure_reason(gate) | reasons]
  defp maybe_add_readiness_reason(reasons, false, _gate), do: reasons

  defp readiness_failure_reason(gate) do
    %{
      "gate" => gate,
      "code" => gate,
      "message" => readiness_failure_message(gate)
    }
  end

  defp readiness_failure_message("status_ci_waiting"), do: "Work package must be in ci_waiting before mark_ready."
  defp readiness_failure_message("status_reviewing"), do: "Work package must be in reviewing before mark_ready when CI is not required."
  defp readiness_failure_message("no_active_blockers"), do: "Active blockers must be resolved before mark_ready."
  defp readiness_failure_message("plan_complete"), do: "Required package plan nodes must be complete."
  defp readiness_failure_message("acceptance_criteria_met"), do: "Acceptance criteria evidence is missing."
  defp readiness_failure_message("tests_passed"), do: "Focused test evidence is missing."
  defp readiness_failure_message("branch_attached"), do: "Current branch metadata is missing."
  defp readiness_failure_message("pr_attached"), do: "Current PR metadata is missing."
  defp readiness_failure_message("current_pr_state"), do: "Current synced PR state is missing."
  defp readiness_failure_message("review_suite_result"), do: "Current-head review-suite result evidence is missing."
  defp readiness_failure_message("review_package_submitted"), do: "Current-head review package is missing."
  defp readiness_failure_message("review_artifacts_attached"), do: "Current-head review artifacts are missing."
  defp readiness_failure_message("review_lanes_complete"), do: "Required review profiles are not green."
  defp readiness_failure_message("findings_documented"), do: "Investigation findings are missing."
  defp readiness_failure_message("recommendation_artifact_recorded"), do: "Investigation recommendation artifact is missing."
  defp readiness_failure_message("phase_active"), do: "Phase must be active before phase child readiness."
  defp readiness_failure_message("phase_child_scope"), do: "Phase child must remain inside its parent phase repo, base branch, and file scope."
  defp readiness_failure_message(_gate), do: "Readiness gate is not satisfied."

  defp merge_metadata_missing?(state, "pr") do
    current_head_sha = latest_current_head_sha(state.progress_events)

    merge_required?(state.work_package) and
      pr_required?(state.work_package) and
      not metadata_present?(state.progress_events, "pr", current_head_sha)
  end

  defp merge_metadata_missing?(state, metadata_type) do
    current_head_sha = latest_current_head_sha(state.progress_events)

    merge_required?(state.work_package) and
      not metadata_present?(state.progress_events, metadata_type, current_head_sha)
  end

  defp current_pr_state_missing?(state) do
    current_head_sha = latest_current_head_sha(state.progress_events)

    merge_required?(state.work_package) and
      pr_required?(state.work_package) and
      required_gate?(state.work_package, "current_pr_state") and
      not current_pr_state_present?(state.progress_events, current_head_sha)
  end

  defp review_suite_result_missing?(state) do
    required_gate?(state.work_package, "review_suite_result") and
      not review_suite_result_present?(state.progress_events, state.artifacts, state.work_package.id, review_head_sha_for_readiness(state))
  end

  defp review_suite_result_present?(_progress_events, _artifacts, _work_package_id, nil), do: false

  defp review_suite_result_present?(progress_events, artifacts, work_package_id, readiness_head_sha) do
    case latest_review_suite_result_event(progress_events, work_package_id, readiness_head_sha) do
      %ProgressEvent{payload: payload} ->
        valid_review_suite_result_payload?(payload, work_package_id, readiness_head_sha) and
          persisted_review_suite_artifact?(artifacts, work_package_id, Map.fetch!(payload, "head_sha"))

      nil ->
        false
    end
  end

  defp latest_review_suite_result_event(progress_events, work_package_id, readiness_head_sha) do
    progress_events
    |> chronological_progress_events()
    |> Enum.filter(&(dedicated_review_suite_result_event?(&1, work_package_id) and review_head_matches?(&1.payload, readiness_head_sha)))
    |> List.last()
  end

  defp dedicated_review_suite_result_event?(%ProgressEvent{idempotency_key: idempotency_key} = event, work_package_id) do
    payload_type?(event, "review_suite_result", "attach_review_suite_result") and
      is_binary(idempotency_key) and String.starts_with?(idempotency_key, "attach_review_suite_result:#{work_package_id}:")
  end

  defp valid_review_suite_result_payload?(%{} = payload, work_package_id, readiness_head_sha) do
    Map.get(payload, "work_package_id") == work_package_id and
      review_head_matches?(payload, readiness_head_sha) and
      review_suite_status_passed?(Map.get(payload, "status")) and
      review_suite_verdict_passed?(Map.get(payload, "verdict")) and
      filled_string?(Map.get(payload, "suite")) and
      filled_string?(Map.get(payload, "anchor")) and
      filled_string?(Map.get(payload, "summary"))
  end

  defp valid_review_suite_result_payload?(_payload, _work_package_id, _readiness_head_sha), do: false

  defp review_package_missing?(state, required_review_lanes) do
    readiness_head_sha = review_head_sha_for_readiness(state)

    merge_required?(state.work_package) and required_review_lanes != [] and
      current_head_review_package_events(state.progress_events, readiness_head_sha) == []
  end

  defp review_artifacts_missing?(state, required_review_lanes) do
    merge_required?(state.work_package) and required_review_lanes != [] and
      not review_artifacts_present?(state.progress_events, state.artifacts, state.work_package.id)
  end

  defp review_lanes_missing?(state, required_review_lanes) do
    required_review_lanes != [] and not review_lanes_present?(state, required_review_lanes)
  end

  defp investigation_findings_missing?(state), do: state.work_package.kind == "investigation" and state.findings == []

  defp investigation_recommendation_missing?(state) do
    state.work_package.kind == "investigation" and
      not recommendation_artifact_recorded?(state.artifacts, state.work_package.id)
  end

  defp required_review_lanes(%WorkPackage{} = work_package) do
    case LifecycleService.policy_for(work_package) do
      {:ok, policy} ->
        policy
        |> get_in([:review_suite, :required])
        |> ReviewProfiles.normalize_profiles()

      {:error, _reason} ->
        []
    end
  end

  defp merge_required?(%WorkPackage{} = work_package) do
    work_package.kind in ["hotfix", "adapter", "mcp", "skill", "hooks", "phase_child"]
  end

  defp review_lanes_present?(_state, []), do: true

  defp review_lanes_present?(state, required_lanes) do
    if merge_required?(state.work_package) do
      review_package_lanes_present?(state.progress_events, required_lanes)
    else
      review_package_lanes_present?(state.progress_events, required_lanes, review_head_sha_for_readiness(state)) or
        progress_review_lanes_present?(state.progress_events, required_lanes)
    end
  end

  defp review_package_lanes_present?(progress_events, required_lanes) do
    review_package_lanes_present?(progress_events, required_lanes, latest_current_head_sha(progress_events))
  end

  defp review_package_lanes_present?(progress_events, required_lanes, readiness_head_sha) do
    readiness_head_sha = normalize_review_readiness_head_sha(readiness_head_sha)

    latest_verdicts =
      case latest_review_package_event(progress_events, readiness_head_sha) do
        %ProgressEvent{} = event ->
          event
          |> review_package_reviews(readiness_head_sha)
          |> Enum.reduce(%{}, fn review, verdicts ->
            Map.put(verdicts, ReviewProfiles.normalize_profile(Map.get(review, "lane")), Map.get(review, "verdict"))
          end)

        nil ->
          %{}
      end

    Enum.all?(required_lanes, fn lane ->
      Map.get(latest_verdicts, lane) == "green"
    end)
  end

  defp progress_review_lanes_present?(progress_events, required_lanes) do
    head_boundary_sequence = latest_branch_event_sequence(progress_events)

    Enum.all?(required_lanes, fn lane ->
      green_statuses = ReviewProfiles.green_statuses(lane)

      latest_status =
        latest_generic_progress_status(
          progress_events,
          head_boundary_sequence,
          ReviewProfiles.statuses(lane)
        )

      latest_status in green_statuses
    end)
  end

  defp generic_append_progress_event?(%ProgressEvent{payload: payload}) when is_map(payload) do
    Map.get(payload, "source_tool") == nil
  end

  defp generic_append_progress_event?(%ProgressEvent{payload: nil}), do: true
  defp generic_append_progress_event?(%ProgressEvent{}), do: false

  defp review_artifacts_present?(progress_events, artifacts, work_package_id) do
    current_head_sha = latest_current_head_sha(progress_events)
    artifact_references = current_head_review_artifact_references(progress_events, current_head_sha)

    artifact_references != [] and
      Enum.all?(artifact_references, fn {path, artifact_head_sha} ->
        persisted_review_artifact?(artifacts, work_package_id, artifact_head_sha, path)
      end)
  end

  defp current_head_review_artifact_references(progress_events, current_head_sha) do
    case latest_review_package_event(progress_events, current_head_sha) do
      %ProgressEvent{} = event -> review_package_artifact_references(event, current_head_sha)
      nil -> []
    end
  end

  defp latest_review_package_event(progress_events, current_head_sha) do
    progress_events
    |> current_head_review_package_events(current_head_sha)
    |> Enum.reverse()
    |> Enum.find(fn event -> review_package_artifact_paths(event, current_head_sha) != [] end)
  end

  defp current_head_review_package_events(progress_events, current_head_sha) do
    Enum.filter(progress_events, fn event ->
      payload_type?(event, "review_package", "submit_review_package") and current_head_review_package?(event, current_head_sha)
    end)
  end

  defp current_head_review_package?(%ProgressEvent{payload: payload}, current_head_sha) when is_map(payload) do
    review_head_matches?(payload, current_head_sha)
  end

  defp current_head_review_package?(%ProgressEvent{}, _current_head_sha), do: false

  defp review_head_matches?(payload, :any_head) when is_map(payload) do
    head_sha = Map.get(payload, "head_sha")
    is_binary(head_sha) and String.trim(head_sha) != ""
  end

  defp review_head_matches?(payload, current_head_sha) when is_map(payload) and is_binary(current_head_sha) do
    Map.get(payload, "head_sha") == current_head_sha
  end

  defp review_head_matches?(_payload, _current_head_sha), do: false

  defp review_package_artifact_paths(%ProgressEvent{payload: payload}, current_head_sha) when is_map(payload) do
    artifacts = Map.get(payload, "artifacts")

    if is_list(artifacts) and review_head_matches?(payload, current_head_sha) do
      Enum.filter(artifacts, &(is_binary(&1) and String.trim(&1) != ""))
    else
      []
    end
  end

  defp review_package_artifact_paths(%ProgressEvent{}, _current_head_sha), do: []

  defp review_package_artifact_references(%ProgressEvent{payload: payload} = event, current_head_sha) when is_map(payload) do
    event
    |> review_package_artifact_paths(current_head_sha)
    |> Enum.map(&{&1, Map.get(payload, "head_sha")})
  end

  defp review_package_artifact_references(%ProgressEvent{}, _current_head_sha), do: []

  defp persisted_review_artifact?(artifacts, work_package_id, head_sha, path) do
    expected_id = review_artifact_id(work_package_id, head_sha, path)
    Enum.any?(artifacts, &(&1.id == expected_id and &1.kind == "review" and &1.path == path))
  end

  defp review_package_reviews(%ProgressEvent{payload: payload}, current_head_sha) when is_map(payload) do
    reviews = Map.get(payload, "reviews")

    cond do
      not is_list(reviews) ->
        []

      not review_head_matches?(payload, current_head_sha) ->
        []

      true ->
        normalize_review_entries(reviews)
    end
  end

  defp review_package_reviews(%ProgressEvent{}, _current_head_sha), do: []

  defp normalize_review_entries(reviews) do
    reviews
    |> Enum.filter(&valid_review_entry?/1)
    |> Enum.map(fn review ->
      %{
        "lane" => review |> Map.get("lane", "") |> String.trim() |> String.downcase(),
        "verdict" => review |> Map.get("verdict", "") |> String.trim() |> String.downcase()
      }
    end)
  end

  defp valid_review_entry?(%{"lane" => lane, "verdict" => verdict} = review) do
    Map.keys(review) |> Enum.sort() == ["lane", "verdict"] and
      is_binary(lane) and String.trim(lane) != "" and is_binary(verdict) and String.trim(verdict) != ""
  end

  defp valid_review_entry?(_review), do: false

  defp latest_current_head_sha(progress_events) do
    latest_metadata_head_sha(progress_events, "branch", "attach_branch")
  end

  defp latest_metadata_head_sha(progress_events, type, source_tool) do
    progress_events
    |> Enum.filter(&payload_type?(&1, type, source_tool))
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{payload: payload} -> latest_metadata_payload_head_sha(payload)
      _event -> nil
    end)
  end

  defp latest_metadata_payload_head_sha(payload) do
    case Map.get(payload || %{}, "head_sha") do
      head_sha when is_binary(head_sha) and head_sha != "" -> head_sha
      _ -> nil
    end
  end

  defp active_blocker?(progress_events) do
    progress_events
    |> Enum.filter(&blocker_event?/1)
    |> Enum.reduce(%{}, fn event, blockers ->
      Map.put(blockers, blocker_id(event), Map.get(event.payload || %{}, "active") == true)
    end)
    |> Map.values()
    |> Enum.any?(& &1)
  end

  defp blocker_event?(%ProgressEvent{payload: payload}) when is_map(payload) do
    Map.get(payload, "type") == "blocker" and Map.get(payload, "source_tool") in ["report_blocker", "resolve_blocker"]
  end

  defp blocker_event?(%ProgressEvent{}), do: false

  defp blocker_id(%ProgressEvent{payload: payload, idempotency_key: idempotency_key, id: id}) do
    blocker_id = Map.get(payload || %{}, "blocker_id")
    normalize_blocker_id(blocker_id || idempotency_key || id)
  end

  defp incomplete_plan?(state) do
    plan_required?(state.work_package) and (state.plan_nodes == [] or Enum.any?(state.plan_nodes, &(&1.status == "pending")))
  end

  defp readiness_status_missing?(%WorkPackage{} = work_package) do
    if ci_waiting_required?(work_package) do
      work_package.status != "ci_waiting"
    else
      work_package.status not in ["reviewing", "ci_waiting"]
    end
  end

  defp readiness_status_gate(%WorkPackage{} = work_package), do: if(ci_waiting_required?(work_package), do: "status_ci_waiting", else: "status_reviewing")
  defp ci_waiting_required?(%WorkPackage{} = work_package), do: required_gate?(work_package, "ci_waiting")

  defp plan_required?(%WorkPackage{} = work_package) do
    case LifecycleService.policy_for(work_package) do
      {:ok, policy} -> get_in(policy, [:constraints, :planning_depth]) == "package"
      {:error, _reason} -> true
    end
  end

  defp acceptance_missing?(state) do
    required_gate?(state.work_package, "package_acceptance") and not acceptance_recorded?(state.progress_events)
  end

  defp tests_missing?(state) do
    required_gate?(state.work_package, "focused_tests") and not tests_recorded?(state)
  end

  defp required_gate?(%WorkPackage{} = work_package, gate) do
    case LifecycleService.policy_for(work_package) do
      {:ok, policy} -> gate in Map.get(policy, :required_gates, [])
      {:error, _reason} -> false
    end
  end

  defp acceptance_recorded?(progress_events) do
    current_head_sha = latest_current_head_sha(progress_events)

    case latest_review_package_event(progress_events, current_head_sha) do
      %ProgressEvent{payload: payload} when is_map(payload) -> Map.get(payload, "acceptance_criteria_met") == true
      _event -> false
    end
  end

  defp tests_recorded?(state) do
    if merge_required?(state.work_package) do
      review_package_tests_recorded?(state.progress_events)
    else
      review_package_tests_recorded?(state) or progress_status_recorded?(state.progress_events, "tests_passed")
    end
  end

  defp review_package_tests_recorded?(progress_events) when is_list(progress_events) do
    review_package_tests_recorded?(progress_events, latest_current_head_sha(progress_events))
  end

  defp review_package_tests_recorded?(%{progress_events: progress_events} = state) do
    review_package_tests_recorded?(progress_events, review_head_sha_for_readiness(state))
  end

  defp review_package_tests_recorded?(progress_events, readiness_head_sha) do
    readiness_head_sha = normalize_review_readiness_head_sha(readiness_head_sha)

    case latest_review_package_event(progress_events, readiness_head_sha) do
      %ProgressEvent{payload: payload} when is_map(payload) ->
        tests = Map.get(payload, "tests")
        is_list(tests) and Enum.any?(tests, &(is_binary(&1) and String.trim(&1) != ""))

      _event ->
        false
    end
  end

  defp review_head_sha_for_readiness(%{work_package: %WorkPackage{} = work_package, progress_events: progress_events}) do
    current_head_sha = latest_current_head_sha(progress_events)

    cond do
      is_binary(current_head_sha) -> current_head_sha
      merge_required?(work_package) -> nil
      true -> :any_head
    end
  end

  defp normalize_review_readiness_head_sha(head_sha) when is_binary(head_sha), do: head_sha
  defp normalize_review_readiness_head_sha(:any_head), do: :any_head
  defp normalize_review_readiness_head_sha(_head_sha), do: nil

  defp progress_status_recorded?(progress_events, expected_status) do
    head_boundary_sequence = latest_branch_event_sequence(progress_events)
    statuses = [expected_status, failed_status(expected_status)]

    latest_generic_progress_status(progress_events, head_boundary_sequence, statuses) == expected_status
  end

  defp latest_generic_progress_status(progress_events, head_boundary_sequence, statuses) do
    statuses = MapSet.new(statuses)

    progress_events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{status: status} = event ->
        status = normalized_status(status)

        if generic_append_progress_event?(event) and progress_after_head_boundary?(event, head_boundary_sequence) and MapSet.member?(statuses, status) do
          status
        end

      _event ->
        nil
    end)
  end

  defp failed_status("tests_passed"), do: "tests_failed"
  defp failed_status(status), do: status <> "_failed"

  defp latest_branch_event_sequence(progress_events) do
    progress_events
    |> Enum.reverse()
    |> Enum.find(&payload_type?(&1, "branch", "attach_branch"))
    |> case do
      %ProgressEvent{sequence: sequence} when is_integer(sequence) -> sequence
      _event -> nil
    end
  end

  defp progress_after_head_boundary?(%ProgressEvent{}, nil), do: true
  defp progress_after_head_boundary?(%ProgressEvent{sequence: sequence}, boundary_sequence) when is_integer(sequence), do: sequence > boundary_sequence
  defp progress_after_head_boundary?(%ProgressEvent{}, _boundary_sequence), do: false

  defp normalized_status(status) when is_binary(status), do: status |> String.trim() |> String.downcase()
  defp normalized_status(_status), do: ""

  defp pr_required?(%WorkPackage{kind: "investigation"}), do: false
  defp pr_required?(%WorkPackage{}), do: true

  defp metadata_present?(progress_events, "pr", head_sha) when is_binary(head_sha) do
    case latest_attached_pr_ref(progress_events) do
      {:ok, attached_ref} ->
        Enum.any?(progress_events, fn
          %ProgressEvent{payload: payload} = event when is_map(payload) ->
            payload_type?(event, "pr", ["attach_pr", "sync_pr"]) and head_sha_matches?(Map.get(payload, "head_sha"), head_sha) and
              pr_payload_ref(payload) == attached_ref

          %ProgressEvent{} ->
            false
        end)

      {:tool_error, _reason} ->
        false
    end
  end

  defp metadata_present?(progress_events, type, head_sha) when is_binary(head_sha) do
    Enum.any?(progress_events, fn
      %ProgressEvent{payload: payload} = event when is_map(payload) ->
        payload_type?(event, type, metadata_tool(type)) and head_sha_matches?(Map.get(payload, "head_sha"), head_sha)

      %ProgressEvent{} ->
        false
    end)
  end

  defp metadata_present?(_progress_events, _type, _head_sha), do: false

  defp current_pr_state_present?(progress_events, head_sha) when is_binary(head_sha) do
    case latest_attached_pr_ref_with_sequence(progress_events) do
      {:ok, attached_ref, attach_sequence} ->
        Enum.any?(progress_events, fn
          %ProgressEvent{payload: payload} = event when is_map(payload) ->
            payload_type?(event, "pr", "sync_pr") and progress_after_pr_attach_boundary?(event, attach_sequence) and
              head_sha_matches?(Map.get(payload, "head_sha"), head_sha) and
              pr_payload_ref(payload) == attached_ref and current_pr_state_payload?(payload)

          %ProgressEvent{} ->
            false
        end)

      {:tool_error, _reason} ->
        false
    end
  end

  defp current_pr_state_present?(_progress_events, _head_sha), do: false

  defp progress_after_pr_attach_boundary?(%ProgressEvent{}, nil), do: true
  defp progress_after_pr_attach_boundary?(%ProgressEvent{sequence: sequence}, attach_sequence) when is_integer(sequence), do: sequence > attach_sequence
  defp progress_after_pr_attach_boundary?(%ProgressEvent{}, _attach_sequence), do: false

  defp current_pr_state_payload?(%{"source_tool" => "sync_pr"} = payload) do
    semantic_pr_state?(payload, "check_summary", ["conclusion", "state", "status"]) or
      semantic_pr_state?(payload, "review_state", ["decision", "state", "status"]) or
      semantic_pr_state?(payload, "merge_state", ["mergeable_state", "state", "status"]) or
      semantic_pr_boolean?(payload, "merge_state", ["mergeable", "merged"])
  end

  defp current_pr_state_payload?(_payload), do: false

  defp semantic_pr_state?(payload, key, semantic_keys) do
    case Map.get(payload, key) do
      value when is_map(value) ->
        Enum.any?(semantic_keys, fn semantic_key ->
          semantic_pr_value?(value, semantic_key)
        end)

      _value ->
        false
    end
  end

  defp semantic_pr_value(value, key), do: Map.get(value, key) || Map.get(value, String.to_atom(key))

  defp semantic_pr_value?(value, "state") do
    case semantic_pr_value(value, "state") do
      state when is_binary(state) ->
        normalized = state |> String.trim() |> String.downcase()
        normalized != "" and normalized not in ["open", "closed"]

      _state ->
        false
    end
  end

  defp semantic_pr_value?(value, key), do: value |> semantic_pr_value(key) |> filled_string?()

  defp semantic_pr_boolean?(payload, key, semantic_keys) do
    case Map.get(payload, key) do
      value when is_map(value) ->
        Enum.any?(semantic_keys, fn semantic_key ->
          is_boolean(Map.get(value, semantic_key)) or is_boolean(Map.get(value, String.to_atom(semantic_key)))
        end)

      _value ->
        false
    end
  end

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp recommendation_artifact_recorded?(artifacts, work_package_id) do
    artifact_id = recommendation_artifact_id(work_package_id)

    Enum.any?(
      artifacts,
      &(&1.id == artifact_id and &1.work_package_id == work_package_id and &1.path == "recommendation.md" and
          &1.title == "Investigation recommendation" and &1.kind == "recommendation")
    )
  end

  defp metadata_tool("branch"), do: "attach_branch"
  defp metadata_tool("pr"), do: "attach_pr"
  defp metadata_tool("review_package"), do: "submit_review_package"

  defp head_sha_matches?(left, right), do: PullRequest.head_sha_matches?(left, right)

  defp payload_type?(%ProgressEvent{payload: payload}, type, source_tools) when is_map(payload) and is_list(source_tools) do
    Map.get(payload, "type") == type and Map.get(payload, "source_tool") in source_tools
  end

  defp payload_type?(%ProgressEvent{payload: payload}, type, source_tool) when is_map(payload) do
    Map.get(payload, "type") == type and Map.get(payload, "source_tool") == source_tool
  end

  defp payload_type?(%ProgressEvent{}, _type, _source_tool), do: false

  defp solo_error(:not_found, tool), do: {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}
  defp solo_error(reason, tool), do: worker_error(reason, tool)

  defp create_work_request_error(%Ecto.Changeset{}) do
    {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => "invalid_work_request"}}
  end

  defp create_work_request_error(:id_already_exists) do
    {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => "id_already_exists"}}
  end

  defp create_work_request_error(:database_busy), do: service_error(:database_busy, "create_work_request")
  defp create_work_request_error({:storage_failed, _reason} = reason), do: service_error(reason, "create_work_request")

  defp create_work_request_error(reason) do
    {:error, -32_602, "Invalid params", %{"tool" => "create_work_request", "reason" => reason_text(reason)}}
  end

  defp worker_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp worker_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error(:expired, resource), do: auth_error({:unauthorized, :expired}, resource)
  defp worker_error(:assignment_revoked, resource), do: auth_error({:unauthorized, :revoked}, resource)
  defp worker_error(:assignment_mismatch, resource), do: auth_error({:unauthorized, :assignment_mismatch}, resource)
  defp worker_error(:worker_grant_required, resource), do: auth_error({:unauthorized, :worker_grant_required}, resource)
  defp worker_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp worker_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp worker_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp worker_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp worker_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp architect_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp architect_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:expired, resource), do: auth_error({:unauthorized, :expired}, resource)
  defp architect_error(:assignment_revoked, resource), do: auth_error({:unauthorized, :revoked}, resource)
  defp architect_error(:architect_grant_required, resource), do: auth_error({:unauthorized, :architect_grant_required}, resource)
  defp architect_error(:insufficient_capability, resource), do: auth_error({:unauthorized, :insufficient_capability}, resource)
  defp architect_error(:phase_scope_not_available, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp architect_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp scoped_session(repo, session, arguments) when is_map(arguments) do
    case Auth.require_session(session, repo) do
      {:ok, session} ->
        with :ok <- require_worker_assignment(session.assignment) do
          require_argument_scope(session, Map.get(arguments, "work_package_id"))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_argument_scope(session, nil), do: {:ok, session}
  defp require_argument_scope(session, work_package_id) when work_package_id == session.assignment.work_package_id, do: {:ok, session}
  defp require_argument_scope(_session, _work_package_id), do: {:error, :forbidden}

  defp authorize_solo_tool_call(%__MODULE__{session_refresh_required: true}, tool) do
    {:error, -32_001, "Unauthorized", %{"tool" => tool, "reason" => "claim_required", "action" => "claim_work_key"}}
  end

  defp authorize_solo_tool_call(%__MODULE__{session: nil}, _tool), do: :ok

  defp authorize_solo_tool_call(%__MODULE__{}, tool) do
    {:error, -32_001, "Unauthorized", %{"tool" => tool, "reason" => "solo_tools_require_unbound_session"}}
  end

  defp authorize_worker_tool_call(%__MODULE__{config: config, session: session}, "get_current_assignment") do
    case Auth.require_session(session, config.repo) do
      {:ok, session} -> require_assignment_introspection(session.assignment)
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_worker_tool_call(%__MODULE__{config: config, session: session}, _tool) do
    case Auth.require_session(session, config.repo) do
      {:ok, session} -> require_worker_assignment(session.assignment)
      {:error, reason} -> {:error, reason}
    end
  end

  defp solo_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_solo_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp worker_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_worker_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp architect_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_architect_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp bootstrap_tool_arguments(params, name) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_bootstrap_arguments(name, arguments)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
    end
  end

  defp validate_worker_arguments(name, arguments) do
    allowed = MapSet.new(allowed_worker_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected == [] do
      {:ok, arguments}
    else
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    end
  end

  defp validate_solo_arguments(name, arguments) do
    allowed = MapSet.new(allowed_solo_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected == [] do
      {:ok, arguments}
    else
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    end
  end

  defp validate_architect_arguments(name, arguments) do
    allowed = MapSet.new(allowed_architect_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected != [] do
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    else
      case validate_tool_required_arguments(architect_tool_input_schema(name), arguments) do
        :ok -> {:ok, arguments}
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      end
    end
  end

  defp validate_bootstrap_arguments(name, arguments) do
    allowed = MapSet.new(allowed_bootstrap_argument_keys(name))
    unexpected = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(allowed, &1))

    if unexpected != [] do
      {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "unexpected_argument", "arguments" => unexpected}}
    else
      validation_arguments = bootstrap_validation_arguments(name, arguments)

      case validate_tool_required_arguments(bootstrap_tool_input_schema(name), validation_arguments) do
        :ok -> {:ok, arguments}
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      end
    end
  end

  defp allowed_solo_argument_keys(name) do
    name
    |> solo_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
  end

  defp allowed_worker_argument_keys(name) do
    name
    |> worker_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
  end

  defp allowed_architect_argument_keys(name) do
    name
    |> architect_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
  end

  defp allowed_bootstrap_argument_keys(name) do
    name
    |> bootstrap_tool_input_schema()
    |> Map.get("properties", %{})
    |> Map.keys()
  end

  defp bootstrap_validation_arguments("create_work_request", arguments) do
    if blank_argument?(Map.get(arguments, "description")) and nonblank_argument?(Map.get(arguments, "human_description")) do
      Map.put(arguments, "description", Map.get(arguments, "human_description"))
    else
      arguments
    end
  end

  defp bootstrap_validation_arguments(_name, arguments), do: arguments

  defp blank_argument?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_argument?(nil), do: true
  defp blank_argument?(_value), do: false

  defp nonblank_argument?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank_argument?(_value), do: false

  defp validate_tool_required_arguments(schema, arguments) do
    properties = Map.get(schema, "properties", %{})

    schema
    |> Map.get("required", [])
    |> Enum.find_value(:ok, fn key ->
      case validate_required_architect_argument(arguments, properties, key) do
        :ok -> nil
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp validate_required_architect_argument(arguments, properties, key) do
    case Map.fetch(arguments, key) do
      :error -> {:error, "missing_#{key}"}
      {:ok, nil} -> {:error, "missing_#{key}"}
      {:ok, value} -> validate_required_architect_argument_value(properties, key, value)
    end
  end

  defp validate_required_architect_argument_value(properties, key, value) do
    case get_in(properties, [key, "type"]) do
      "string" -> validate_required_architect_string_argument(key, value)
      "object" -> validate_required_architect_object_argument(key, value)
      "array" -> validate_required_architect_array_argument_value(properties, key, value)
      _type -> {:error, "invalid_#{key}"}
    end
  end

  defp validate_required_architect_string_argument(key, value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, "missing_#{key}"}, else: :ok
  end

  defp validate_required_architect_string_argument(key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_architect_object_argument(_key, value) when is_map(value), do: :ok
  defp validate_required_architect_object_argument(key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_architect_array_argument_value(properties, key, values) when is_list(values) do
    validate_required_architect_array_argument(properties, key, values)
  end

  defp validate_required_architect_array_argument_value(_properties, key, _value), do: {:error, "invalid_#{key}"}

  defp validate_required_architect_array_argument(properties, key, values) do
    cond do
      properties |> Map.get(key, %{}) |> Map.get("minItems", 0) > 0 and values == [] ->
        {:error, "missing_#{key}"}

      get_in(properties, [key, "items", "type"]) == "string" ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")), do: :ok, else: {:error, "invalid_#{key}"}

      true ->
        if Enum.all?(values, &is_map/1), do: :ok, else: {:error, "invalid_#{key}"}
    end
  end

  defp required_string_array(arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, values} when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          {:ok, Enum.map(values, &String.trim/1)}
        else
          {:tool_error, "invalid_#{key}"}
        end

      :error ->
        {:tool_error, "missing_#{key}"}

      {:ok, _values} ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  defp required_argument(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "missing_#{key}"}
    end
  end

  defp required_object(arguments, key) do
    case Map.get(arguments, key) do
      value when is_map(value) -> {:ok, value}
      _value -> {:tool_error, "missing_#{key}"}
    end
  end

  defp optional_object_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp optional_decision_prompt_argument(arguments, key) do
    with {:ok, prompt} <- optional_object_argument(arguments, key) do
      case HumanDecisionPrompt.normalize(prompt) do
        {:ok, normalized} -> {:ok, normalized}
        {:error, reason} -> {:tool_error, "#{key} #{HumanDecisionPrompt.error_message(reason)}"}
      end
    end
  end

  defp required_integer(arguments, key) do
    case Map.get(arguments, key) do
      value when is_integer(value) -> {:ok, value}
      _value -> {:tool_error, "missing_#{key}"}
    end
  end

  defp required_list(arguments, key) do
    case Map.get(arguments, key) do
      [_head | _tail] = value -> {:ok, value}
      nil -> {:tool_error, "missing_#{key}"}
      [] -> {:tool_error, "missing_#{key}"}
      _value -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp required_string_list(arguments, key) do
    with {:ok, values} <- required_list(arguments, key) do
      if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
        {:ok, Enum.map(values, &String.trim/1)}
      else
        {:tool_error, "invalid_#{key}"}
      end
    end
  end

  defp required_review_list(arguments, key) do
    with {:ok, values} <- required_list(arguments, key) do
      if Enum.all?(values, &valid_review_entry?/1) and unique_review_lanes?(values) do
        {:ok, values}
      else
        {:tool_error, "invalid_#{key}"}
      end
    end
  end

  defp unique_review_lanes?(reviews) do
    lanes =
      Enum.map(reviews, fn %{"lane" => lane} ->
        lane |> String.trim() |> String.downcase()
      end)

    Enum.uniq(lanes) == lanes
  end

  defp optional_review_list(arguments, key) do
    case Map.get(arguments, key) do
      nil -> {:ok, []}
      [] -> {:ok, []}
      _reviews -> required_review_list(arguments, key)
    end
  end

  defp optional_boolean(arguments, key, default) do
    case Map.fetch(arguments, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
      :error -> {:ok, default}
    end
  end

  defp optional_argument(arguments, key, default) do
    case Map.get(arguments, key, default) do
      value when is_binary(value) -> if String.trim(value) == "", do: default, else: value
      nil -> default
      value -> value
    end
  end

  defp optional_blocker_id(arguments) do
    default = Map.get(arguments, "idempotency_key")

    case Map.get(arguments, "blocker_id") do
      value when is_binary(value) -> {:ok, if(String.trim(value) == "", do: normalize_blocker_id(default), else: String.trim(value))}
      nil -> {:ok, normalize_blocker_id(default)}
      _value -> {:error, :invalid_blocker_id}
    end
  end

  defp normalize_blocker_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_blocker_id(value), do: value

  defp optional_payload(arguments) do
    case Map.get(arguments, "payload", %{}) do
      payload when is_map(payload) -> {:ok, payload}
      _payload -> {:tool_error, "invalid_payload"}
    end
  end

  defp merge_tool_payload("append_progress", caller_payload, tool_payload) do
    caller_payload
    |> drop_protected_append_progress_payload()
    |> Map.merge(tool_payload)
  end

  defp merge_tool_payload("attach_review_suite_result", _caller_payload, tool_payload), do: tool_payload

  defp merge_tool_payload(_tool, caller_payload, tool_payload) when tool_payload == %{} do
    Map.drop(caller_payload, ["source_tool"])
  end

  defp merge_tool_payload(_tool, caller_payload, %{"type" => "scope_expansion_request", "source_tool" => "request_scope_expansion"} = tool_payload) do
    caller_payload
    |> Map.drop(["source_tool", "recommendation_artifact_id"])
    |> Map.merge(tool_payload)
  end

  defp merge_tool_payload(_tool, caller_payload, tool_payload), do: Map.merge(caller_payload, tool_payload)

  defp drop_protected_append_progress_payload(%{"type" => type} = caller_payload) when type in ["scope_expansion_request", "scope_expansion_approval"] do
    Map.drop(caller_payload, [
      "type",
      "source_tool",
      "recommendation_artifact_id",
      "approved",
      "requested_file_globs",
      "approved_file_globs",
      "allowed_file_globs",
      "previous_allowed_file_globs",
      "request_id"
    ])
  end

  defp drop_protected_append_progress_payload(caller_payload) do
    Map.drop(caller_payload, [
      "source_tool",
      "recommendation_artifact_id",
      "approved",
      "requested_file_globs",
      "approved_file_globs",
      "allowed_file_globs",
      "previous_allowed_file_globs",
      "request_id"
    ])
  end

  defp maybe_put_id(attrs, arguments) do
    case Map.get(arguments, "id") do
      id when is_binary(id) ->
        case String.trim(id) do
          "" -> attrs
          trimmed -> Map.put(attrs, "id", trimmed)
        end

      _id ->
        attrs
    end
  end

  defp metadata_idempotency_key(payload), do: "mcp:" <> Map.get(payload, "type", "metadata") <> ":" <> Base.url_encode64(:erlang.term_to_binary(payload), padding: false)

  defp actor(%Session{} = session) do
    %{
      grant_id: session.assignment.grant_id,
      grant_role: session.assignment.grant_role,
      capabilities: session.assignment.capabilities,
      work_package_id: session.assignment.work_package_id
    }
  end

  defp work_request_cards(work_requests) do
    Enum.map(work_requests, &work_request_card_payload/1)
  end

  defp work_request_card_payload(%WorkRequest{} = work_request) do
    %{
      "id" => work_request.id,
      "title" => Redactor.redact_text(work_request.title),
      "repo" => work_request.repo,
      "base_branch" => work_request.base_branch,
      "work_type" => work_request.work_type,
      "desired_dispatch_shape" => work_request.desired_dispatch_shape,
      "creator" => work_request_creator_payload(work_request),
      "status" => work_request.status,
      "inserted_at" => timestamp(work_request.inserted_at),
      "updated_at" => timestamp(work_request.updated_at)
    }
  end

  defp guidance_request_cards(guidance_requests) do
    Enum.map(guidance_requests, &guidance_request_card_payload/1)
  end

  defp guidance_request_card_payload(%GuidanceRequest{} = guidance_request) do
    %{
      "id" => guidance_request.id,
      "work_package_id" => guidance_request.work_package_id,
      "summary" => Redactor.redact_text(guidance_request.summary),
      "status" => guidance_request.status,
      "requested_by" => guidance_request.requested_by,
      "answered_by" => guidance_request.answered_by,
      "blocker_id" => guidance_request.blocker_id,
      "inserted_at" => timestamp(guidance_request.inserted_at),
      "updated_at" => timestamp(guidance_request.updated_at)
    }
  end

  defp guidance_request_payload(%GuidanceRequest{} = guidance_request) do
    %{
      "id" => guidance_request.id,
      "work_package_id" => guidance_request.work_package_id,
      "summary" => Redactor.redact_text(guidance_request.summary),
      "question" => Redactor.redact_text(guidance_request.question),
      "context" => Redactor.redact_text(guidance_request.context),
      "status" => guidance_request.status,
      "requested_by" => guidance_request.requested_by,
      "answer" => Redactor.redact_text(guidance_request.answer),
      "answered_by" => guidance_request.answered_by,
      "answered_at" => timestamp(guidance_request.answered_at),
      "human_info_reason" => Redactor.redact_text(guidance_request.human_info_reason),
      "recommended_language" => Redactor.redact_text(guidance_request.recommended_language),
      "decision_prompt" => Redactor.redact_output(guidance_request.decision_prompt),
      "blocker_id" => guidance_request.blocker_id,
      "inserted_at" => timestamp(guidance_request.inserted_at),
      "updated_at" => timestamp(guidance_request.updated_at)
    }
  end

  defp work_request_detail_payload(repo, %WorkRequest{} = work_request) do
    with {:ok, questions} <- WorkRequestService.list_questions(repo, work_request.id),
         {:ok, decisions} <- WorkRequestService.list_decisions(repo, work_request.id),
         {:ok, planned_slices} <- WorkRequestService.list_planned_slices(repo, work_request.id) do
      {:ok,
       %{
         "work_request" => work_request_payload(work_request),
         "clarification_questions" => Enum.map(questions, &clarification_question_payload/1),
         "decision_log_entries" => Enum.map(decisions, &decision_log_entry_payload/1),
         "planned_slices" => Enum.map(planned_slices, &planned_slice_payload/1),
         "summary" => work_request_summary_payload(questions, decisions, planned_slices)
       }}
    end
  end

  defp work_request_payload(%WorkRequest{} = work_request) do
    %{
      "id" => work_request.id,
      "title" => Redactor.redact_text(work_request.title),
      "repo" => work_request.repo,
      "base_branch" => work_request.base_branch,
      "work_type" => work_request.work_type,
      "human_description" => Redactor.redact_text(work_request.human_description),
      "constraints" => Redactor.redact_output(work_request.constraints || %{}),
      "desired_dispatch_shape" => work_request.desired_dispatch_shape,
      "creator" => work_request_creator_payload(work_request),
      "status" => work_request.status,
      "inserted_at" => timestamp(work_request.inserted_at),
      "updated_at" => timestamp(work_request.updated_at)
    }
  end

  defp work_request_creator_payload(%WorkRequest{} = work_request) do
    %{
      "kind" => work_request.creator_kind,
      "name" => Redactor.redact_text(work_request.creator_name),
      "via" => work_request.created_via
    }
  end

  defp work_request_mutation_payload(%WorkRequest{} = work_request) do
    %{
      "id" => work_request.id,
      "status" => work_request.status,
      "updated_at" => timestamp(work_request.updated_at)
    }
  end

  defp clarification_question_payload(%ClarificationQuestion{} = question) do
    %{
      "id" => question.id,
      "work_request_id" => question.work_request_id,
      "sequence" => question.sequence,
      "category" => Redactor.redact_text(question.category),
      "question" => Redactor.redact_text(question.question),
      "why_needed" => Redactor.redact_text(question.why_needed),
      "decision_prompt" => Redactor.redact_output(question.decision_prompt),
      "status" => question.status,
      "asked_by_agent_run_id" => Redactor.redact_text(question.asked_by_agent_run_id),
      "answer" => Redactor.redact_text(question.answer),
      "answered_by" => Redactor.redact_text(question.answered_by),
      "answered_at" => timestamp(question.answered_at),
      "inserted_at" => timestamp(question.inserted_at),
      "updated_at" => timestamp(question.updated_at)
    }
  end

  defp decision_log_entry_payload(%DecisionLogEntry{} = decision) do
    %{
      "id" => decision.id,
      "work_request_id" => decision.work_request_id,
      "sequence" => decision.sequence,
      "source_type" => Redactor.redact_text(decision.source_type),
      "source_id" => Redactor.redact_text(decision.source_id),
      "decision" => Redactor.redact_text(decision.decision),
      "rationale" => Redactor.redact_text(decision.rationale),
      "scope_impact" => Redactor.redact_text(decision.scope_impact),
      "created_by" => Redactor.redact_text(decision.created_by),
      "created_at" => timestamp(decision.created_at),
      "inserted_at" => timestamp(decision.inserted_at),
      "updated_at" => timestamp(decision.updated_at)
    }
  end

  defp planned_slice_payload(%PlannedSlice{} = planned_slice) do
    %{
      "id" => planned_slice.id,
      "work_request_id" => planned_slice.work_request_id,
      "sequence" => planned_slice.sequence,
      "title" => Redactor.redact_text(planned_slice.title),
      "goal" => Redactor.redact_text(planned_slice.goal),
      "work_package_kind" => planned_slice.work_package_kind,
      "target_base_branch" => planned_slice.target_base_branch,
      "branch_pattern" => Redactor.redact_text(planned_slice.branch_pattern),
      "owned_file_globs" => Enum.map(planned_slice.owned_file_globs || [], &Redactor.redact_text/1),
      "forbidden_file_globs" => Enum.map(planned_slice.forbidden_file_globs || [], &Redactor.redact_text/1),
      "acceptance_criteria" => Enum.map(planned_slice.acceptance_criteria || [], &Redactor.redact_text/1),
      "validation_steps" => Enum.map(planned_slice.validation_steps || [], &Redactor.redact_text/1),
      "review_lanes" => Enum.map(planned_slice.review_lanes || [], &Redactor.redact_text/1),
      "stop_conditions" => Enum.map(planned_slice.stop_conditions || [], &Redactor.redact_text/1),
      "status" => planned_slice.status,
      "work_package_id" => planned_slice.work_package_id,
      "dispatched_at" => timestamp(planned_slice.dispatched_at),
      "inserted_at" => timestamp(planned_slice.inserted_at),
      "updated_at" => timestamp(planned_slice.updated_at)
    }
  end

  defp dispatch_work_request_planned_slice_payload(
         %{work_request: %WorkRequest{} = work_request, planned_slice: %PlannedSlice{} = planned_slice} = dispatch,
         scope
       ) do
    create_work =
      dispatch
      |> PlannedSliceDispatch.response_payload()
      |> Map.fetch!(:create_work)

    %{
      "work_request" => %{"id" => work_request.id},
      "planned_slice" => %{
        "id" => planned_slice.id,
        "status" => planned_slice.status,
        "work_package_id" => planned_slice.work_package_id,
        "dispatched_at" => timestamp(planned_slice.dispatched_at)
      },
      "work_package" => dispatch_work_package_payload(Map.fetch!(create_work, :work_package)),
      "worker_handoff" => %{
        "worker_grant" => dispatch_worker_grant_payload(Map.fetch!(create_work, :worker_grant)),
        "secret_handoff" => dispatch_secret_handoff_payload(Map.get(create_work, :worker_secret_handoff))
      },
      "scope" => scope,
      "status" => %{"planned_slice_status" => planned_slice.status}
    }
  end

  defp dispatch_work_package_payload(work_package) when is_map(work_package) do
    work_package
    |> json_safe_payload()
    |> Map.take(["id", "kind", "status", "repo", "base_branch"])
  end

  defp dispatch_worker_grant_payload(worker_grant) when is_map(worker_grant) do
    worker_grant
    |> json_safe_payload()
    |> Map.drop(["display_key", "secret", "secret_handoff", "secret_returned_once"])
    |> Map.put("secret_in_response", false)
  end

  defp dispatch_secret_handoff_payload(nil), do: nil

  defp dispatch_secret_handoff_payload(handoff) when is_map(handoff) do
    handoff
    |> json_safe_payload()
    |> Map.drop(["display_key", "secret", "payload"])
  end

  defp dispatch_link_recovery_payload(recovery) when is_map(recovery) do
    %{}
    |> put_optional_recovery_value("work_package_id", recovery_value(recovery, :work_package_id))
    |> put_optional_recovery_value("worker_grant_id", recovery_value(recovery, :worker_grant_id))
    |> put_optional_recovery_value(
      "worker_secret_handoff",
      dispatch_secret_handoff_payload(recovery_value(recovery, :worker_secret_handoff))
    )
    |> put_optional_recovery_value("cleanup", safe_recovery_value(recovery_value(recovery, :cleanup)))
  end

  defp dispatch_link_recovery_payload(_recovery), do: %{}

  defp recovery_value(recovery, key) do
    Map.get(recovery, key) || Map.get(recovery, to_string(key))
  end

  defp put_optional_recovery_value(payload, _key, nil), do: payload
  defp put_optional_recovery_value(payload, key, value), do: Map.put(payload, key, value)

  defp safe_recovery_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, map_value} -> {to_string(key), safe_recovery_value(map_value)} end)
    |> Map.new()
  end

  defp safe_recovery_value(value) when is_list(value), do: Enum.map(value, &safe_recovery_value/1)
  defp safe_recovery_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_recovery_value(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp safe_recovery_value(value), do: inspect(value)

  defp work_request_summary_payload(questions, decisions, planned_slices) do
    %{
      "open_question_count" => Enum.count(questions, &(&1.status == "open")),
      "answered_question_count" => Enum.count(questions, &(&1.status == "answered")),
      "closed_question_count" => Enum.count(questions, &(&1.status == "closed")),
      "decision_count" => length(decisions),
      "planned_slice_count" => Enum.count(planned_slices, &(&1.status == "planned")),
      "approved_slice_count" => Enum.count(planned_slices, &(&1.status == "approved")),
      "dispatched_slice_count" => Enum.count(planned_slices, &(&1.status == "dispatched")),
      "skipped_slice_count" => Enum.count(planned_slices, &(&1.status == "skipped"))
    }
  end

  @doc false
  @spec mcp_timestamp(DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  def mcp_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  def mcp_timestamp(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  def mcp_timestamp(nil), do: nil

  defp timestamp(timestamp), do: mcp_timestamp(timestamp)

  defp not_found_error(tool) do
    {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}
  end

  defp tool_result(payload) do
    %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}],
      "structuredContent" => payload,
      "isError" => false
    }
  end

  defp json_safe_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp solo_session_payload(%SoloSession{} = session) do
    %{
      "id" => Redactor.redact_text(session.id),
      "repo" => Redactor.redact_text(session.repo),
      "base_branch" => Redactor.redact_text(session.base_branch),
      "workspace_path" => Redactor.redact_text(session.workspace_path),
      "caller_id" => Redactor.redact_text(session.caller_id),
      "session_key" => Redactor.redact_text(session.session_key),
      "title" => Redactor.redact_text(session.title),
      "status" => Redactor.redact_text(session.status),
      "last_activity_at" => timestamp(session.last_activity_at),
      "archived_at" => timestamp(session.archived_at),
      "created_at" => timestamp(session.inserted_at),
      "updated_at" => timestamp(session.updated_at)
    }
  end

  defp solo_entry_payload(%SoloSessionEntry{} = entry) do
    %{
      "id" => Redactor.redact_text(entry.id),
      "solo_session_id" => Redactor.redact_text(entry.solo_session_id),
      "entry_kind" => Redactor.redact_text(entry.entry_kind),
      "title" => Redactor.redact_text(entry.title),
      "body" => Redactor.redact_text(entry.body),
      "status" => Redactor.redact_text(entry.status),
      "sequence" => entry.sequence,
      "idempotency_key" => Redactor.redact_text(entry.idempotency_key),
      "payload" => Redactor.redact_output(entry.payload || %{}),
      "created_at" => timestamp(entry.created_at),
      "updated_at" => timestamp(entry.updated_at)
    }
  end

  defp plan_node_payload(%PlanNode{} = plan_node) do
    %{"id" => plan_node.id, "title" => plan_node.title, "status" => plan_node.status}
  end

  defp progress_event_payload(%ProgressEvent{} = event) do
    %{
      "id" => event.id,
      "summary" => Redactor.redact_text(event.summary),
      "status" => Redactor.redact_text(event.status),
      "idempotency_key" => Redactor.redact_text(event.idempotency_key),
      "payload" => Redactor.redact_output(event.payload || %{})
    }
  end

  defp progress_event_payload(nil), do: nil

  defp artifact_payload(%Artifact{} = artifact) do
    %{
      "id" => artifact.id,
      "path" => Redactor.redact_text(artifact.path),
      "title" => Redactor.redact_text(artifact.title),
      "kind" => artifact.kind,
      "uri" => Redactor.redact_text(artifact.uri),
      "metadata" => Redactor.redact_output(artifact.metadata || %{})
    }
  end

  defp worktree_lifecycle_payload(result, scope, audit_event) do
    %{
      "work_package" => work_package_worktree_payload(result.work_package),
      "worktree" => %{
        "status" => result.status,
        "path" => Redactor.redact_text(result.worktree_path),
        "repo_root" => Redactor.redact_text(result.repo_root),
        "branch" => result.branch,
        "base_branch" => result.base_branch
      },
      "worker_launch" => worktree_worker_launch_payload(result),
      "audit_event" => progress_event_payload(audit_event),
      "scope" => scope
    }
  end

  defp worktree_worker_launch_payload(%{worktree_path: worktree_path, branch: branch, base_branch: base_branch})
       when is_binary(worktree_path) and is_binary(branch) and is_binary(base_branch) do
    %{
      "workspace_path" => Redactor.redact_text(worktree_path),
      "branch" => branch,
      "base_branch" => base_branch,
      "instruction" => "Use this worktree only for the assigned WorkPackage."
    }
  end

  defp worktree_worker_launch_payload(_result), do: nil

  defp work_package_worktree_payload(%WorkPackage{} = work_package) do
    work_package
    |> work_package_payload()
    |> Map.put("worktree_path", Redactor.redact_text(work_package.worktree_path))
  end

  defp work_package_payload(%WorkPackage{} = work_package) do
    %{"id" => work_package.id, "kind" => work_package.kind, "status" => work_package.status}
  end

  defp child_work_package_payload(%WorkPackage{} = work_package) do
    work_package
    |> work_package_payload()
    |> Map.merge(%{
      "acceptance_criteria" => work_package.acceptance_criteria || [],
      "allowed_file_globs" => work_package.allowed_file_globs || [],
      "base_branch" => work_package.base_branch,
      "parent_id" => work_package.parent_id,
      "phase_id" => work_package.phase_id,
      "policy_template" => work_package.policy_template,
      "repo" => work_package.repo,
      "title" => work_package.title
    })
  end

  defp child_worker_grant_payload(%{grant: grant}, secret_handoff) do
    %{
      "id" => grant.id,
      "work_package_id" => grant.work_package_id,
      "display_key" => grant.display_key,
      "grant_role" => grant.grant_role,
      "capabilities" => grant.capabilities || [],
      "expires_at" => timestamp(grant.expires_at),
      "secret_in_response" => false,
      "secret_handoff" => secret_handoff
    }
  end

  defp child_worker_grant_secret_payload(%{grant: grant, work_key: work_key}) do
    %{
      "id" => grant.id,
      "work_package_id" => grant.work_package_id,
      "display_key" => grant.display_key,
      "grant_role" => grant.grant_role,
      "capabilities" => grant.capabilities || [],
      "expires_at" => timestamp(grant.expires_at),
      "secret" => work_key.secret
    }
  end

  defp live_expires_at?(nil, %DateTime{}), do: true
  defp live_expires_at?(%DateTime{} = expires_at, %DateTime{} = now), do: DateTime.compare(expires_at, now) == :gt

  defp redacted_child_worker_grant(worker_grant) when is_map(worker_grant) do
    Map.delete(worker_grant, "secret")
  end

  defp child_worker_secret_handoff_payload(handoff) when is_map(handoff) do
    handoff
    |> Map.take(@child_worker_secret_handoff_payload_keys)
    |> json_safe_payload()
  end

  defp json_resource(uri, payload) do
    %{
      "contents" => [
        %{
          "uri" => uri,
          "mimeType" => "application/json",
          "text" => Jason.encode!(payload)
        }
      ]
    }
  end

  defp text_resource(uri, text, mime_type) do
    %{
      "contents" => [
        %{
          "uri" => uri,
          "mimeType" => mime_type,
          "text" => text
        }
      ]
    }
  end

  defp auth_error(:unauthorized, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}
  end

  defp auth_error({:unauthorized, reason}, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}
  end

  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)

  defp auth_error(:forbidden, resource) do
    {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}
  end

  defp service_error(_reason, resource) do
    {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp request_params(%{"params" => params}) when is_map(params) or is_list(params), do: {:ok, params}

  defp request_params(%{"params" => _params}),
    do: {:error, -32_602, "Invalid params", %{"reason" => "params_must_be_object_or_array"}}

  defp request_params(_request), do: {:ok, %{}}

  defp dispatch_request({:ok, params}, method, id, %__MODULE__{} = server) do
    dispatch_request_state({:ok, params}, method, id, server)
    |> elem(0)
  end

  defp dispatch_request({:error, code, message, data}, _method, id, %__MODULE__{}) do
    error_response(id, code, message, data)
  end

  defp dispatch_request_state({:ok, params}, method, id, %__MODULE__{} = server) do
    case dispatch(method, params, server) do
      {:ok, result} -> {response(id, result), server}
      {:ok, result, %__MODULE__{} = updated_server} -> {response(id, result), updated_server}
      {:error, code, message, data} -> {error_response(id, code, message, data), server}
    end
  end

  defp dispatch_request_state({:error, code, message, data}, _method, id, %__MODULE__{} = server) do
    {error_response(id, code, message, data), server}
  end

  defp dispatch_notification({:ok, params}, method, %__MODULE__{} = server) do
    _result = dispatch(method, params, server)
    nil
  end

  defp dispatch_notification({:error, _code, _message, _data}, _method, %__MODULE__{}), do: nil

  defp initialize_request?(%{"jsonrpc" => "2.0", "method" => "initialize"}), do: true
  defp initialize_request?(_payload), do: false

  defp handle_batch_item(payload, %__MODULE__{} = server) when is_map(payload), do: handle_state(payload, server)

  defp handle_batch_item(_payload, %__MODULE__{} = server) do
    {error_response(nil, -32_600, "Invalid Request", %{"reason" => "request_must_be_object"}), server}
  end

  defp error_response(id, code, message, data) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message, "data" => data}}
  end
end
