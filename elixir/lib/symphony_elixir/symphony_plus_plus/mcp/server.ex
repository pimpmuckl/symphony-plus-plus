defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Server do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Auth, Config, Session}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer, as: PlanningRenderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
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
    "request_scope_expansion",
    "attach_branch",
    "attach_pr",
    "submit_review_package",
    "mark_ready"
  ]
  @version_resource "sympp://health/version"
  @assignment_resource "sympp://assignment/current"

  @enforce_keys [:config]
  defstruct [:config, :session, initialized: false]

  @type t :: %__MODULE__{config: Config.t(), session: Session.t() | nil, initialized: boolean()}

  defguardp valid_request_id(id) when is_binary(id) or is_number(id) or is_nil(id)
  defguardp invalid_request_id(id) when not is_binary(id) and not is_number(id) and not is_nil(id)

  @spec new(Config.t(), keyword()) :: t()
  def new(%Config{} = config, opts \\ []) do
    %__MODULE__{
      config: config,
      session: Keyword.get(opts, :session),
      initialized: Keyword.get(opts, :initialized, false)
    }
  end

  @spec handle(term(), t()) :: map() | [map()] | nil
  def handle(payload, %__MODULE__{} = server) do
    payload
    |> handle_state(server)
    |> elem(0)
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

  def handle_state(payload, %__MODULE__{} = server), do: {do_handle(payload, server), server}

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
    {responses, server} =
      Enum.reduce(payloads, {[], server}, fn payload, {responses, server} ->
        {response, server} = handle_batch_item(payload, server)
        responses = if is_nil(response), do: responses, else: [response | responses]
        {responses, server}
      end)

    responses = Enum.reverse(responses)
    {if(responses == [], do: nil, else: responses), server}
  end

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

  defp dispatch("tools/list", params, _server) when is_map(params) do
    {:ok,
     %{
       "tools" => [health_tool_spec() | Enum.map(@worker_tools, &worker_tool_spec/1)]
     }}
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
    case claim_work_key(params, server) do
      {:ok, result, _session} -> {:ok, tool_result(result)}
      {:error, code, message, data} -> {:error, code, message, data}
    end
  end

  defp dispatch("tools/call", %{"name" => name} = params, %__MODULE__{} = server) when name in @worker_tools do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        worker_tool(name, arguments, server)

      _arguments ->
        {:error, -32_602, "Invalid params", %{"tool" => name, "reason" => "invalid_tool_arguments"}}
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
    case Auth.require_session(session, config.repo) do
      {:ok, session} -> {:ok, json_resource(@assignment_resource, Session.public_assignment(session))}
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
          {:ok, _session} ->
            read_virtual_resource(config.repo, work_package_id, file_name, uri)

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

  defp worker_tool_input_schema("claim_work_key") do
    schema(%{"secret" => string_schema(), "claimed_by" => string_schema()}, ["secret"])
  end

  defp worker_tool_input_schema(name) when name in ["get_current_assignment", "read_context", "read_task_plan", "mark_ready"] do
    schema(%{}, [])
  end

  defp worker_tool_input_schema("update_task_plan") do
    schema(
      scoped_properties(%{
        "body" => nullable_string_schema(),
        "id" => string_schema(),
        "status" => string_schema(),
        "title" => string_schema()
      }),
      ["title"]
    )
  end

  defp worker_tool_input_schema("append_finding") do
    schema(
      scoped_properties(%{
        "body" => string_schema(),
        "id" => string_schema(),
        "severity" => string_schema(),
        "title" => string_schema()
      }),
      ["title", "body"]
    )
  end

  defp worker_tool_input_schema(name) when name in ["append_progress", "report_blocker", "request_scope_expansion"] do
    schema(progress_properties(), ["summary", "idempotency_key"])
  end

  defp worker_tool_input_schema("set_status") do
    schema(scoped_properties(%{"status" => string_schema()}), ["status"])
  end

  defp worker_tool_input_schema("attach_branch") do
    schema(metadata_properties(%{"branch" => string_schema()}), ["branch"])
  end

  defp worker_tool_input_schema("attach_pr") do
    schema(metadata_properties(%{"url" => string_schema(), "head_sha" => nullable_string_schema()}), ["url"])
  end

  defp worker_tool_input_schema("submit_review_package") do
    schema(metadata_properties(%{"summary" => string_schema(), "tests" => array_schema(), "artifacts" => array_schema()}), [])
  end

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
  defp nullable_string_schema, do: %{"type" => ["string", "null"]}
  defp object_schema, do: %{"type" => "object", "additionalProperties" => true}
  defp array_schema, do: %{"type" => "array", "items" => %{}}

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
      {:ok, %Session{}} ->
        work_package_id = Session.work_package_id(session)

        {:ok,
         [
           %{
             "uri" => @assignment_resource,
             "name" => "Current Symphony++ assignment",
             "mimeType" => "application/json"
           }
         ] ++ work_package_resources(work_package_id)}

      {:error, {:service_unavailable, reason}} ->
        service_error(reason, @assignment_resource)

      {:error, _reason} ->
        {:ok, []}
    end
  end

  defp assignment_resources(_session, _repo), do: {:ok, []}

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

  defp handle_claim_work_key(params, id, %__MODULE__{} = server) do
    case claim_work_key(params, server) do
      {:ok, result, session} -> {response(id, tool_result(result)), %{server | session: session}}
      {:error, code, message, data} -> {error_response(id, code, message, data), server}
    end
  end

  defp claim_work_key(params, %__MODULE__{config: config}) do
    with {:ok, arguments} <- tool_arguments(params, "claim_work_key"),
         {:ok, secret} <- required_argument(arguments, "secret"),
         claimed_by <- optional_argument(arguments, "claimed_by", "worker"),
         proof_hash = WorkKey.secret_hash(secret),
         {:ok, assignment} <- AccessGrantService.claim(config.repo, secret, claimed_by: claimed_by),
         {:ok, session} <- Session.from_grant(live_grant!(config.repo, assignment.grant_id), DateTime.utc_now(:microsecond), proof_hash: proof_hash) do
      {:ok, %{"assignment" => Session.public_assignment(session)}, session}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "claim_work_key", "reason" => reason}}
      {:error, reason} -> {:error, -32_001, "Unauthorized", %{"tool" => "claim_work_key", "reason" => reason_text(reason)}}
    end
  rescue
    _error -> {:error, -32_000, "Server error", %{"tool" => "claim_work_key", "reason" => "ledger_unavailable"}}
  end

  defp live_grant!(repo, grant_id) do
    {:ok, grant} = SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository.get(repo, grant_id)
    grant
  end

  defp worker_tool("get_current_assignment", _arguments, %__MODULE__{config: config, session: session}) do
    case Auth.require_session(session, config.repo) do
      {:ok, session} -> {:ok, tool_result(%{"assignment" => Session.public_assignment(session)})}
      {:error, reason} -> auth_error(reason, "get_current_assignment")
    end
  end

  defp worker_tool("read_context", _arguments, %__MODULE__{config: config, session: session}) do
    read_current_virtual_file(config.repo, session, "context.md")
  end

  defp worker_tool("read_task_plan", _arguments, %__MODULE__{config: config, session: session}) do
    read_current_virtual_file(config.repo, session, "task_plan.md")
  end

  defp worker_tool("update_task_plan", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, title} <- required_argument(arguments, "title"),
         status <- optional_argument(arguments, "status", "pending"),
         body <- optional_argument(arguments, "body", nil),
         attrs = %{
           "work_package_id" => Session.work_package_id(session),
           "title" => title,
           "body" => body,
           "status" => status
         },
         {:ok, plan_node} <- PlanningRepository.append_plan_node(config.repo, maybe_put_id(attrs, arguments)) do
      {:ok, tool_result(%{"plan_node" => plan_node_payload(plan_node)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "update_task_plan", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "update_task_plan")
    end
  end

  defp worker_tool("append_finding", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, title} <- required_argument(arguments, "title"),
         {:ok, body} <- required_argument(arguments, "body"),
         attrs = %{
           "work_package_id" => Session.work_package_id(session),
           "title" => title,
           "body" => body,
           "severity" => optional_argument(arguments, "severity", "info")
         },
         {:ok, finding} <- PlanningRepository.append_finding(config.repo, maybe_put_id(attrs, arguments)) do
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
         {:ok, work_package} <-
           LifecycleService.transition(config.repo, Session.work_package_id(session), status, actor(session)) do
      {:ok, tool_result(%{"work_package" => work_package_payload(work_package)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "set_status", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "set_status")
    end
  end

  defp worker_tool("report_blocker", arguments, %__MODULE__{config: config, session: session}) do
    append_scoped_progress(config.repo, session, arguments, "report_blocker", %{
      "type" => "blocker",
      "source_tool" => "report_blocker",
      "active" => true
    })
  end

  defp worker_tool("request_scope_expansion", arguments, %__MODULE__{config: config, session: session}) do
    append_scoped_progress(config.repo, session, arguments, "request_scope_expansion", %{
      "type" => "scope_expansion_request",
      "source_tool" => "request_scope_expansion",
      "approved" => false
    })
  end

  defp worker_tool("attach_branch", arguments, %__MODULE__{config: config, session: session}) do
    case required_argument(arguments, "branch") do
      {:ok, branch} ->
        append_metadata_event(config.repo, session, arguments, "attach_branch", "branch_attached", %{"type" => "branch", "branch" => branch})

      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "attach_branch", "reason" => reason}}
    end
  end

  defp worker_tool("attach_pr", arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, url} <- required_argument(arguments, "url"),
         head_sha <- optional_argument(arguments, "head_sha", nil) do
      append_metadata_event(config.repo, session, arguments, "attach_pr", "pr_attached", %{"type" => "pr", "url" => url, "head_sha" => head_sha})
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "attach_pr", "reason" => reason}}
    end
  end

  defp worker_tool("submit_review_package", arguments, %__MODULE__{config: config, session: session}) do
    append_metadata_event(config.repo, session, arguments, "submit_review_package", "review_package_submitted", %{
      "type" => "review_package",
      "summary" => Map.get(arguments, "summary"),
      "tests" => Map.get(arguments, "tests"),
      "artifacts" => Map.get(arguments, "artifacts", [])
    })
  end

  defp worker_tool("mark_ready", _arguments, %__MODULE__{config: config, session: session}) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, state} <- PlanningRepository.get_state(config.repo, Session.work_package_id(session)),
         :ok <- readiness_gates(state),
         ready_status <- terminal_ready_status(state.work_package),
         {:ok, work_package} <- LifecycleService.transition(config.repo, state.work_package.id, ready_status, actor(session)) do
      {:ok, tool_result(%{"work_package" => work_package_payload(work_package), "ready" => true})}
    else
      {:error, {:readiness_failed, missing}} ->
        {:error, -32_602, "Invalid params", %{"tool" => "mark_ready", "reason" => "readiness_failed", "missing" => missing}}

      {:error, reason} ->
        worker_error(reason, "mark_ready")
    end
  end

  defp read_current_virtual_file(repo, session, file_name) do
    with {:ok, session} <- Auth.require_session(session, repo),
         {:ok, markdown} <- PlanningRenderer.render(repo, Session.work_package_id(session), file_name) do
      {:ok, tool_result(%{"uri" => "sympp://work-packages/#{Session.work_package_id(session)}/#{file_name}", "text" => markdown})}
    else
      {:error, reason} -> worker_error(reason, "read_#{file_name}")
    end
  end

  defp append_scoped_progress(repo, session, arguments, tool, payload) do
    with {:ok, session} <- scoped_session(repo, session, arguments),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments),
         attrs = %{
           "summary" => summary,
           "body" => optional_argument(arguments, "body", nil),
           "status" => optional_argument(arguments, "status", "recorded"),
           "idempotency_key" => idempotency_key,
           "payload" => merge_tool_payload(caller_payload, payload)
         },
         {:ok, event} <- PlanningService.append_authenticated_progress_event(repo, session.assignment, attrs) do
      {:ok, tool_result(%{"progress_event" => progress_event_payload(event)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
      {:error, reason} -> worker_error(reason, tool)
    end
  end

  defp append_metadata_event(repo, session, arguments, tool, status, payload) do
    payload = Map.put(payload, "source_tool", tool)

    arguments =
      Map.put_new(arguments, "summary", status)
      |> Map.put_new("status", status)
      |> Map.put_new("idempotency_key", metadata_idempotency_key(payload))

    append_scoped_progress(repo, session, arguments, tool, payload)
  end

  defp readiness_gates(state) do
    missing =
      []
      |> maybe_missing(state.work_package.status != "ci_waiting", "status_ci_waiting")
      |> maybe_missing(active_blocker?(state.progress_events), "no_active_blockers")
      |> maybe_missing(incomplete_plan?(state.plan_nodes), "plan_complete")
      |> maybe_missing(not metadata_present?(state.progress_events, "branch"), "branch_attached")
      |> maybe_missing(pr_required?(state.work_package) and not metadata_present?(state.progress_events, "pr"), "pr_attached")
      |> maybe_missing(not metadata_present?(state.progress_events, "review_package"), "review_package_submitted")

    if missing == [], do: :ok, else: {:error, {:readiness_failed, Enum.reverse(missing)}}
  end

  defp active_blocker?(progress_events) do
    Enum.any?(progress_events, &(payload_type?(&1, "blocker", "report_blocker") and Map.get(&1.payload || %{}, "active") == true))
  end

  defp incomplete_plan?(plan_nodes), do: Enum.any?(plan_nodes, &(&1.status == "pending"))

  defp pr_required?(%WorkPackage{kind: "investigation"}), do: false
  defp pr_required?(%WorkPackage{}), do: true

  defp metadata_present?(progress_events, type), do: Enum.any?(progress_events, &payload_type?(&1, type, metadata_tool(type)))

  defp metadata_tool("branch"), do: "attach_branch"
  defp metadata_tool("pr"), do: "attach_pr"
  defp metadata_tool("review_package"), do: "submit_review_package"

  defp payload_type?(%ProgressEvent{payload: payload}, type, source_tool) when is_map(payload) do
    Map.get(payload, "type") == type and Map.get(payload, "source_tool") == source_tool
  end

  defp payload_type?(%ProgressEvent{}, _type, _source_tool), do: false

  defp maybe_missing(missing, true, name), do: [name | missing]
  defp maybe_missing(missing, false, _name), do: missing

  defp terminal_ready_status(%WorkPackage{kind: "phase_child"}), do: "ready_for_architect_merge"
  defp terminal_ready_status(%WorkPackage{}), do: "ready_for_human_merge"

  defp worker_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp worker_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp worker_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp scoped_session(repo, session, arguments) when is_map(arguments) do
    case Auth.require_session(session, repo) do
      {:ok, session} -> require_argument_scope(session, Map.get(arguments, "work_package_id"))
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_argument_scope(session, nil), do: {:ok, session}
  defp require_argument_scope(session, work_package_id) when work_package_id == session.assignment.work_package_id, do: {:ok, session}
  defp require_argument_scope(_session, _work_package_id), do: {:error, :forbidden}

  defp tool_arguments(params, tool) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) -> {:ok, arguments}
      _arguments -> {:tool_error, "invalid_#{tool}_arguments"}
    end
  end

  defp required_argument(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:tool_error, "missing_#{key}"}, else: {:ok, value}

      _value ->
        {:tool_error, "missing_#{key}"}
    end
  end

  defp optional_argument(arguments, key, default) do
    case Map.get(arguments, key, default) do
      value when is_binary(value) -> if String.trim(value) == "", do: default, else: value
      nil -> default
      value -> value
    end
  end

  defp optional_payload(arguments) do
    case Map.get(arguments, "payload", %{}) do
      payload when is_map(payload) -> {:ok, payload}
      _payload -> {:tool_error, "invalid_payload"}
    end
  end

  defp merge_tool_payload(caller_payload, tool_payload) when tool_payload == %{} do
    Map.drop(caller_payload, ["source_tool"])
  end

  defp merge_tool_payload(caller_payload, tool_payload), do: Map.merge(caller_payload, tool_payload)

  defp maybe_put_id(attrs, arguments) do
    case Map.get(arguments, "id") do
      id when is_binary(id) and id != "" -> Map.put(attrs, "id", id)
      _id -> attrs
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

  defp plan_node_payload(%PlanNode{} = plan_node) do
    %{"id" => plan_node.id, "title" => plan_node.title, "status" => plan_node.status}
  end

  defp progress_event_payload(%ProgressEvent{} = event) do
    %{"id" => event.id, "summary" => event.summary, "status" => event.status, "idempotency_key" => event.idempotency_key}
  end

  defp work_package_payload(%WorkPackage{} = work_package) do
    %{"id" => work_package.id, "kind" => work_package.kind, "status" => work_package.status}
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
