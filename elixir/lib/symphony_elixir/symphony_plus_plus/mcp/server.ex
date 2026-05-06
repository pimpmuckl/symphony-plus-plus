defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Server do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Client, DryClient, PullRequest}
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Auth, Config, Session}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer, as: PlanningRenderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @protocol_version "2025-03-26"
  @health_tool "sympp.health"
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
    "revoke_child_worker_key",
    "request_child_replan",
    "approve_child_ready_state",
    "merge_child_into_phase",
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
  @child_worker_template_keys ["capabilities", "expires_at"]
  @child_worker_capabilities ["worker:claim", "worker:lifecycle.transition"]
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
  defstruct [:config, :session, :state_key, :state_key_version, state_key_explicit: false, initialized: false]

  @type t :: %__MODULE__{
          config: Config.t(),
          session: Session.t() | nil,
          state_key: term(),
          state_key_version: integer() | nil,
          state_key_explicit: boolean(),
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
      {:ok, %{"name" => "claim_work_key"} = params} ->
        handle_claim_work_key(params, id, server)

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
      {:ok, %{"name" => "claim_work_key"} = params} ->
        handle_claim_work_key_notification(params, server)

      params_result ->
        dispatch_notification(params_result, "tools/call", server)
        {nil, server}
    end
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
        server
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
        session = if stale_explicit_session?(server, state_key_version), do: nil, else: server.session

        %{
          server
          | initialized: server.initialized or stored.initialized,
            session: session,
            state_key_version: state_key_version
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
    timestamp_ms = monotonic_ms()
    state_key_version = monotonic_state_key_version()
    stored_server = %{stored_handle_state_server(server) | state_key_version: state_key_version}
    update_handle_state_store(&Map.put(&1, handle_state_store_key(server), {stored_server, timestamp_ms, server.state_key_explicit}))
    state_key_version
  end

  defp delete_handle_state(%__MODULE__{} = server) do
    update_handle_state_store(&Map.delete(&1, handle_state_store_key(server)))
    :ok
  end

  defp invalidate_explicit_handle_state(%__MODULE__{} = server) do
    timestamp_ms = monotonic_ms()
    state_key_version = monotonic_state_key_version()

    tombstone = %{
      stored_handle_state_server(server)
      | initialized: false,
        session: nil,
        state_key_version: state_key_version
    }

    update_handle_state_store(&Map.put(&1, handle_state_store_key(server), {tombstone, timestamp_ms, true}))
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
         %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => %{"name" => "claim_work_key"}},
         %__MODULE__{initialized: true}
       )
       when valid_request_id(id),
       do: true

  defp batch_claim_work_key_request?(%{"jsonrpc" => "2.0", "id" => _id, "method" => "tools/call"}, %__MODULE__{initialized: true}),
    do: false

  defp batch_claim_work_key_request?(
         %{"jsonrpc" => "2.0", "method" => "tools/call", "params" => %{"name" => "claim_work_key"}},
         %__MODULE__{initialized: true}
       ),
       do: true

  defp batch_claim_work_key_request?(_payload, %__MODULE__{}), do: false

  defp batch_claim_work_key_rebind_item(%{"id" => id}, %__MODULE__{} = server) when valid_request_id(id) do
    {error_response(id, -32_001, "Unauthorized", %{"tool" => "claim_work_key", "reason" => "session_already_bound"}), server}
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

  defp dispatch("tools/list", params, %__MODULE__{config: config, session: session}) when is_map(params) do
    case tool_specs_for_session(config.repo, session) do
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

  defp dispatch("tools/call", %{"name" => "claim_work_key"} = params, %__MODULE__{} = server) do
    with {:ok, _arguments} <- worker_tool_arguments(params, "claim_work_key"),
         {:ok, result, _session} <- claim_work_key(params, server) do
      {:ok, tool_result(result)}
    else
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @worker_tools do
    case worker_tool_arguments(params, name) do
      {:ok, arguments} ->
        worker_tool(name, arguments, server)

      {:error, code, message, data} ->
        {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @architect_tools do
    with :ok <- authorize_architect_tool_call(server, name),
         {:ok, arguments} <- architect_tool_arguments(params, name) do
      architect_tool(name, arguments, server)
    else
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

  defp dispatch("resources/read", %{"uri" => @version_resource}, %__MODULE__{} = server) do
    payload = %{"version" => server.config.version, "mode" => Atom.to_string(server.config.mode)}
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
    ledger = ledger_health(config.repo)

    %{
      "status" => if(ledger["reachable"], do: "ok", else: "degraded"),
      "version" => config.version,
      "mode" => Atom.to_string(config.mode),
      "ledger" => ledger
    }
  end

  defp health_tool_spec do
    %{
      "name" => @health_tool,
      "title" => "Symphony++ health",
      "description" => "Returns server version and ledger reachability without exposing package data.",
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

  defp architect_tool_description("approve_scope_expansion") do
    "Approve additional allowed file globs for this scoped work package."
  end

  defp architect_tool_description("read_phase_board") do
    "Read the architect grant's scoped phase board."
  end

  defp architect_tool_description(name) when name in @phase7_stub_architect_tools do
    "Phase 7 architect tool #{name}; authorization is enforced, but behavior is not implemented yet."
  end

  defp worker_tool_input_schema("claim_work_key") do
    schema(%{"secret" => string_schema(), "claimed_by" => string_schema()}, ["secret", "claimed_by"])
  end

  defp worker_tool_input_schema(name) when name in ["get_current_assignment", "read_context", "read_task_plan", "mark_ready"] do
    schema(%{}, [])
  end

  defp worker_tool_input_schema("update_task_plan") do
    patch_schema = schema(scoped_properties(%{"expected_version" => integer_schema(), "patch" => plan_patch_schema()}), ["expected_version", "patch"])

    append_schema =
      schema(
        scoped_properties(%{
          "body" => nullable_string_schema(),
          "expected_version" => integer_schema(),
          "id" => string_schema(),
          "status" => string_schema(),
          "title" => string_schema()
        }),
        ["expected_version", "title"]
      )

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
    |> Map.put("oneOf", [patch_schema, append_schema])
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
    |> Map.put("allOf", [
      %{"anyOf" => [%{"required" => ["url"]}, %{"required" => ["number"]}]},
      %{
        "anyOf" => [
          %{"required" => ["head_sha"]},
          %{"required" => ["metadata"], "properties" => %{"metadata" => metadata_head_schema()}}
        ]
      }
    ])
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
    |> Map.put("allOf", [
      %{"anyOf" => [%{"required" => ["url"]}, %{"required" => ["number"]}]},
      %{
        "anyOf" => [
          %{"required" => ["head_sha"]},
          %{
            "required" => ["metadata"],
            "properties" => %{"metadata" => metadata_head_schema()}
          }
        ]
      }
    ])
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
    schema(%{"work_package_id" => string_schema(), "rationale" => string_schema()}, ["work_package_id", "rationale"])
  end

  defp architect_tool_input_schema("merge_child_into_phase") do
    schema(%{"work_package_id" => string_schema(), "merge_artifact" => object_schema()}, ["work_package_id", "merge_artifact"])
  end

  defp architect_tool_input_schema("split_work_package") do
    schema(%{"work_package_id" => string_schema(), "child_specs" => nonempty_object_array_schema()}, ["work_package_id", "child_specs"])
  end

  defp architect_tool_input_schema("publish_phase_update") do
    schema(%{"phase_id" => string_schema(), "update" => object_schema()}, ["phase_id", "update"])
  end

  defp tool_specs_for_session(_repo, nil) do
    {:ok, [health_tool_spec() | Enum.map(@worker_tools, &worker_tool_spec/1)]}
  end

  defp tool_specs_for_session(repo, session) do
    case Auth.require_session(session, repo) do
      {:ok, %Session{assignment: %{grant_role: "architect"}} = session} ->
        {:ok, [health_tool_spec(), worker_tool_spec("get_current_assignment") | architect_tool_specs_for_session(session)]}

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

  defp claimable_tool_specs, do: [health_tool_spec(), worker_tool_spec("claim_work_key")]

  defp architect_tool_specs_for_session(%Session{assignment: %{capabilities: capabilities}}) do
    @architect_tools
    |> Enum.filter(&(architect_tool_required_capabilities(&1) -- capabilities == []))
    |> Enum.map(&architect_tool_spec/1)
  end

  defp architect_tool_specs_for_session(_session), do: []

  defp schema(properties, required) do
    %{"type" => "object", "additionalProperties" => false, "properties" => properties, "required" => required}
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
  defp nonblank_string_schema, do: %{"type" => "string", "minLength" => 1, "pattern" => "\\S"}
  defp boolean_schema, do: %{"type" => "boolean"}
  defp integer_schema, do: %{"type" => "integer"}

  defp pr_number_schema do
    %{"anyOf" => [%{"type" => "integer", "minimum" => 1}, %{"type" => "string", "pattern" => "^[1-9][0-9]*$"}]}
  end

  defp nullable_string_schema, do: %{"type" => ["string", "null"]}
  defp object_schema, do: %{"type" => "object", "additionalProperties" => true}

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

  defp nonempty_string_array_schema, do: %{"type" => "array", "minItems" => 1, "items" => nonblank_string_schema()}
  defp nonempty_object_array_schema, do: %{"type" => "array", "minItems" => 1, "items" => object_schema()}

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

  defp ledger_health(repo) when is_atom(repo) do
    case SQL.query(repo, "SELECT 1", [], log: false) do
      {:ok, _result} -> %{"reachable" => true}
      {:error, _reason} -> %{"reachable" => false, "error" => "ledger_unavailable"}
    end
  rescue
    _error -> %{"reachable" => false, "error" => "ledger_unavailable"}
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

  defp handle_claim_work_key(params, id, %__MODULE__{} = server) do
    case claim_work_key(params, server) do
      {:ok, result, session} -> {response(id, tool_result(result)), %{server | session: session}}
      {:error, code, message, data} -> {error_response(id, code, message, data), server}
    end
  end

  defp handle_claim_work_key_notification(params, %__MODULE__{} = server) do
    case claim_work_key(params, server) do
      {:ok, _result, session} -> {nil, %{server | session: session}}
      {:error, _code, _message, _data} -> {nil, server}
    end
  end

  defp claim_work_key(params, %__MODULE__{config: config, session: %Session{} = session}) do
    with {:ok, arguments} <- worker_tool_arguments(params, "claim_work_key"),
         {:ok, secret} <- required_argument(arguments, "secret"),
         {:ok, claimed_by} <- required_argument(arguments, "claimed_by"),
         :ok <- require_full_secret(secret) do
      proof_hash = WorkKey.secret_hash(secret)

      case claim_work_key_with_bound_session(config.repo, session, secret, proof_hash, claimed_by) do
        {:ok, _result, _session} = success -> success
        {:error, reason} -> claim_error(reason)
      end
    else
      {:error, code, message, data} -> {:error, code, message, data}
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "claim_work_key", "reason" => reason}}
      {:error, reason} -> claim_error(reason)
      _not_same_session -> {:error, -32_001, "Unauthorized", %{"tool" => "claim_work_key", "reason" => "session_already_bound"}}
    end
  rescue
    _error -> {:error, -32_000, "Server error", %{"tool" => "claim_work_key", "reason" => "ledger_unavailable"}}
  end

  defp claim_work_key(params, %__MODULE__{config: config}) do
    with {:ok, arguments} <- worker_tool_arguments(params, "claim_work_key"),
         {:ok, secret} <- required_argument(arguments, "secret"),
         {:ok, claimed_by} <- required_argument(arguments, "claimed_by"),
         :ok <- require_full_secret(secret) do
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
         {:ok, session} <- Session.from_grant(grant, DateTime.utc_now(:microsecond), proof_hash: proof_hash),
         :ok <- require_mcp_claimable_assignment(session.assignment) do
      {:ok, session}
    end
  end

  defp claim_or_reconnect_session(repo, secret, proof_hash, claimed_by) do
    case AccessGrantService.claim(repo, secret, claimed_by: claimed_by) do
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

  defp reconnect_claimed_session(repo, proof_hash, claimed_by) do
    with {:ok, grant} <- AccessGrantRepository.find_by_secret_hash(repo, proof_hash),
         :ok <- require_same_claim_owner(grant, claimed_by),
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
      require_mcp_claimable_assignment(grant)
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
         {:ok, {child, minted}} <- mint_child_worker_key_transaction(config.repo, session, work_package_id, template) do
      {:ok,
       tool_result(%{
         "work_package" => child_work_package_payload(child),
         "worker_grant" => child_worker_grant_payload(minted)
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "mint_child_worker_key", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "mint_child_worker_key")
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
         {:ok, board_scope} <- require_architect_phase_board_scope(config.repo, session, phase_id),
         {:ok, board} <- Dashboard.phase_board(config.repo, phase_id) do
      {:ok, tool_result(json_safe_payload(filter_phase_board(board, board_scope)))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_phase_board", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "read_phase_board")
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

  defp require_architect_phase_board_scope(repo, %Session{} = session, phase_id) do
    with {:ok, grant} <- require_live_architect_grant(repo, session),
         {:ok, anchor} <- architect_anchor_work_package(repo, session),
         :ok <- require_architect_anchor_scope(anchor, grant, phase_id),
         {:ok, board_scope} <- phase_board_scope_filter(grant) do
      {:ok, board_scope}
    else
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp phase_board_scope_filter(%AccessGrant{} = grant) do
    if architect_explicit_phase_grant?(grant) do
      with {:ok, repo} <- frozen_scope_value(grant.scope_repo),
           {:ok, base_branch} <- frozen_scope_value(grant.scope_base_branch) do
        {:ok, {:repo_base, repo, base_branch}}
      else
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, :phase}
    end
  end

  defp frozen_scope_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :phase_scope_not_available}
      trimmed -> {:ok, trimmed}
    end
  end

  defp frozen_scope_value(_value), do: {:error, :phase_scope_not_available}

  defp filter_phase_board(board, :phase), do: board

  defp filter_phase_board(%{groups: groups} = board, {:repo_base, repo, base_branch}) do
    filtered_groups =
      Map.new(groups, fn {status, cards} ->
        {status, Enum.filter(cards, &phase_board_card_in_scope?(&1, repo, base_branch))}
      end)

    %{board | groups: filtered_groups, total_count: phase_board_total_count(filtered_groups)}
  end

  defp phase_board_card_in_scope?(%{repo: card_repo, base_branch: card_base_branch}, repo, base_branch),
    do: card_repo == repo and card_base_branch == base_branch

  defp phase_board_card_in_scope?(_card, _repo, _base_branch), do: false

  defp phase_board_total_count(groups) do
    groups
    |> Map.values()
    |> Enum.map(&length/1)
    |> Enum.sum()
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
    case architect_anchor_work_package(repo, session) do
      {:ok, anchor} -> require_anchor_status_phase_scope(repo, session, anchor.phase_id)
      {:error, :not_found} -> {:error, :phase_scope_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_anchor_status_phase_scope(repo, %Session{} = session, phase_id) do
    if explicit_phase_id?(phase_id) do
      require_child_phase_anchor_status(repo, session)
    else
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
         {:ok, child} <- WorkPackageRepository.get(repo, work_package_id),
         :ok <- require_phase_child_scope(child, anchor, phase_id) do
      {:ok, child}
    end
  end

  defp require_phase_child_scope(%WorkPackage{kind: "phase_child", phase_id: phase_id} = child, anchor, phase_id) do
    cond do
      child.parent_id != anchor.id -> {:error, :phase_scope_not_available}
      child.repo != anchor.repo -> {:tool_error, "repo_scope_mismatch"}
      child.base_branch != anchor.base_branch -> {:tool_error, "base_branch_scope_mismatch"}
      true -> :ok
    end
  end

  defp require_phase_child_scope(%WorkPackage{}, _anchor, _phase_id), do: {:error, :phase_scope_not_available}

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

  defp mint_child_worker_key_transaction(repo, %Session{} = session, work_package_id, template) do
    case repo.transaction(fn ->
           mint_child_worker_key_or_rollback(repo, session, work_package_id, template)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mint_child_worker_key_or_rollback(repo, %Session{} = session, work_package_id, template) do
    case mint_child_worker_key_in_transaction(repo, session, work_package_id, template) do
      {:ok, result} -> result
      {:tool_error, reason} -> repo.rollback({:tool_error, reason})
      {:error, reason} -> repo.rollback({:error, reason})
    end
  end

  defp mint_child_worker_key_in_transaction(repo, %Session{} = session, work_package_id, template) do
    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, architect_grant} <- require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         {:ok, phase_id, anchor} <- architect_child_phase_anchor(repo, session, architect_grant),
         {:ok, grant_opts} <- child_worker_grant_opts(template, architect_grant),
         {:ok, child} <- require_child_ready_for_mint(repo, work_package_id, anchor, phase_id),
         {:ok, minted} <- AccessGrantService.mint_worker_grant(repo, child.id, grant_opts) do
      {:ok, {child, minted}}
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
    with {:ok, child} <- WorkPackageRepository.get(repo, work_package_id),
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

  defp require_child_globs_within_anchor(_child_globs, []), do: {:tool_error, "child_scope_outside_phase"}

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

  defp glob_segments_within?(child_segments, ["**" | anchor_tail]) do
    glob_segments_within?(child_segments, anchor_tail) or
      case child_segments do
        [] -> false
        [_child_head | child_tail] -> glob_segments_within?(child_tail, ["**" | anchor_tail])
      end
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
      {:ok, [capabilities: capabilities, expires_at: expires_at]}
    end
  end

  defp validate_child_worker_template_keys(template) do
    unexpected = template |> Map.keys() |> Enum.reject(&(&1 in @child_worker_template_keys))
    if unexpected == [], do: :ok, else: {:tool_error, "unexpected_template_field"}
  end

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

  defp child_worker_expires_at(_template, _architect_grant), do: {:error, :phase_scope_not_available}

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
      DateTime.compare(expires_at, architect_expires_at) == :gt -> {:tool_error, "broader_child_grant"}
      DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) != :gt -> {:tool_error, "invalid_expires_at"}
      true -> :ok
    end
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

      {:ok, nil} ->
        {:error, :not_found}

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
  defp maybe_upsert_pr_artifact(repo, %Session{} = session, payload, false), do: upsert_pr_artifact(repo, session, payload)

  defp upsert_pr_artifact(repo, %Session{} = session, payload) do
    attrs = %{
      "id" => pr_artifact_id(session.assignment.work_package_id),
      "work_package_id" => session.assignment.work_package_id,
      "path" => "github-pr.json",
      "title" => pr_artifact_title(payload),
      "kind" => "github_pr",
      "uri" => Map.get(payload, "url")
    }

    case PlanningRepository.get_artifact(repo, attrs["id"]) do
      {:ok, nil} -> append_pr_artifact(repo, attrs)
      {:ok, %Artifact{} = artifact} -> update_pr_artifact(repo, artifact, attrs)
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_pr_artifact(repo, attrs) do
    case PlanningService.append_artifact(repo, attrs) do
      {:ok, _artifact} -> :ok
      {:error, :id_already_exists} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_pr_artifact(repo, %Artifact{} = artifact, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {String.to_existing_atom(key), value} end)

    case PlanningRepository.update_artifact(repo, artifact, attrs) do
      {:ok, _artifact} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp pr_artifact_title(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_integer(number) do
    "GitHub PR #{repository}##{number}"
  end

  defp pr_artifact_title(_payload), do: "GitHub PR metadata"

  defp pr_artifact_id(work_package_id) do
    material = [work_package_id, "github-pr.json"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
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

      {:ok, nil} ->
        {:error, :not_found}

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
           :ok <- readiness_gates(state) do
        ready_status = terminal_ready_status(state.work_package)
        LifecycleService.transition(repo, state.work_package, ready_status, actor(session))
      end
    end)
  end

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

  defp require_live_grant(%AccessGrant{}, _now), do: {:error, :phase_scope_not_available}

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

  defp reject_ready_work_package(%WorkPackage{status: status}) when status in ["ready_for_human_merge", "ready_for_architect_merge"], do: {:tool_error, "already_ready"}
  defp reject_ready_work_package(%WorkPackage{}), do: :ok

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
      {:error, reason} -> worker_error(reason, tool)
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

      {:error, reason} ->
        worker_error(reason, tool)
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

      {:error, reason} ->
        repo.rollback(reason)
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
      {:error, reason} -> worker_error(reason, "attach_review_suite_result")
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

  defp readiness_gates(state) do
    required_review_lanes = required_review_lanes(state.work_package)

    reasons = readiness_failure_reasons(state, required_review_lanes)
    missing = missing_readiness_gates(reasons)

    if missing == [], do: :ok, else: {:error, {:readiness_failed, missing, reasons}}
  end

  defp missing_readiness_gates(reasons) do
    reasons
    |> Enum.map(&Map.fetch!(&1, "gate"))
    |> Enum.uniq()
  end

  defp readiness_failure_reasons(state, required_review_lanes) do
    [
      {state.work_package.status != "ci_waiting", "status_ci_waiting"},
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

  defp readiness_failure_reason(gate) do
    %{
      "gate" => gate,
      "code" => gate,
      "message" => readiness_failure_message(gate)
    }
  end

  defp readiness_failure_message("status_ci_waiting"), do: "Work package must be in ci_waiting before mark_ready."
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
  defp readiness_failure_message("review_lanes_complete"), do: "Required review lanes are not green."
  defp readiness_failure_message("findings_documented"), do: "Investigation findings are missing."
  defp readiness_failure_message("recommendation_artifact_recorded"), do: "Investigation recommendation artifact is missing."
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
      {:ok, policy} -> get_in(policy, [:review_suite, :required]) || []
      {:error, _reason} -> []
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
          |> Enum.reduce(%{}, fn review, verdicts -> Map.put(verdicts, Map.get(review, "lane"), Map.get(review, "verdict")) end)

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
      latest_generic_progress_status(progress_events, head_boundary_sequence, ["#{lane}_green", "#{lane}_red", "#{lane}_failed"]) == "#{lane}_green"
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

  defp terminal_ready_status(%WorkPackage{kind: "phase_child"}), do: "ready_for_architect_merge"
  defp terminal_ready_status(%WorkPackage{}), do: "ready_for_human_merge"

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

  defp validate_worker_arguments(name, arguments) do
    allowed = MapSet.new(allowed_worker_argument_keys(name))
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
      case validate_architect_required_arguments(name, arguments) do
        :ok -> {:ok, arguments}
        {:error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => reason}}
      end
    end
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

  defp validate_architect_required_arguments(name, arguments) do
    schema = architect_tool_input_schema(name)
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
    case {Map.get(arguments, key), get_in(properties, [key, "type"])} do
      {value, "string"} when is_binary(value) ->
        if String.trim(value) == "", do: {:error, "missing_#{key}"}, else: :ok

      {value, "object"} when is_map(value) ->
        :ok

      {[_head | _tail] = values, "array"} ->
        validate_required_architect_array_argument(properties, key, values)

      {_value, _type} ->
        {:error, "missing_#{key}"}
    end
  end

  defp validate_required_architect_array_argument(properties, key, values) do
    case get_in(properties, [key, "items", "type"]) do
      "string" ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")), do: :ok, else: {:error, "invalid_#{key}"}

      _item_type ->
        if Enum.all?(values, &is_map/1), do: :ok, else: {:error, "invalid_#{key}"}
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

  defp plan_node_payload(%PlanNode{} = plan_node) do
    %{"id" => plan_node.id, "title" => plan_node.title, "status" => plan_node.status}
  end

  defp progress_event_payload(%ProgressEvent{} = event) do
    %{
      "id" => event.id,
      "summary" => event.summary,
      "status" => event.status,
      "idempotency_key" => event.idempotency_key,
      "payload" => event.payload || %{}
    }
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

  defp child_worker_grant_payload(%{grant: grant, work_key: work_key}) do
    %{
      "id" => grant.id,
      "work_package_id" => grant.work_package_id,
      "display_key" => grant.display_key,
      "grant_role" => grant.grant_role,
      "capabilities" => grant.capabilities || [],
      "expires_at" => DateTime.to_iso8601(grant.expires_at),
      "secret" => work_key.secret,
      "secret_returned_once" => true
    }
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
    case dispatch(method, params, server) do
      {:ok, result} -> response(id, result)
      {:error, code, message, data} -> error_response(id, code, message, data)
    end
  end

  defp dispatch_request({:error, code, message, data}, _method, id, %__MODULE__{}) do
    error_response(id, code, message, data)
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
