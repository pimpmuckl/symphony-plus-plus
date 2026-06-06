defmodule SymphonyElixirWeb.MCPHTTPPlug do
  @moduledoc false

  alias Plug.Conn
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, HTTPStateStore, HTTPTransport, Server, Session}
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.SymppBoardLive

  @client_key "__sympp_mcp_local_http_client__"
  @session_header "mcp-session-id"
  @assignment_resource "sympp://assignment/current"
  @work_package_resource_prefix "sympp://work-packages/"
  @max_body_bytes 1_000_000
  @forwarded_headers ["forwarded", "x-real-ip"]

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Conn.t(), keyword()) :: Conn.t()
  def call(%Conn{path_info: ["mcp"]} = conn, _opts) do
    with {:ok, local_daemon_trusted?} <- validate_local_request(conn),
         :ok <- validate_origin(conn),
         :ok <- ensure_state_store_started() do
      dispatch(conn, local_daemon_trusted?)
    else
      {:error, :state_store_unavailable} -> send_json_rpc_error(conn, 503, :ledger_unavailable)
      {:error, reason} -> send_json_rpc_error(conn, 403, reason)
    end
  end

  def call(%Conn{} = conn, _opts), do: conn

  defp ensure_state_store_started do
    case Process.whereis(HTTPStateStore) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        start_state_store()
    end
  end

  defp start_state_store do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) -> start_supervised_state_store()
      nil -> start_direct_state_store()
    end
  end

  defp start_supervised_state_store do
    case Supervisor.restart_child(SymphonyElixir.Supervisor, HTTPStateStore) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, :not_found} -> add_supervised_state_store()
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> {:error, :state_store_unavailable}
    end
  catch
    :exit, _reason -> {:error, :state_store_unavailable}
  end

  defp add_supervised_state_store do
    case Supervisor.start_child(SymphonyElixir.Supervisor, HTTPStateStore) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> {:error, :state_store_unavailable}
    end
  end

  defp start_direct_state_store do
    case GenServer.start(HTTPStateStore, [], name: HTTPStateStore) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> {:error, :state_store_unavailable}
    end
  end

  defp dispatch(%Conn{method: "POST"} = conn, local_daemon_trusted?) do
    with {:ok, payload, conn} <- read_json_body(conn),
         :ok <- reject_batch_payload(payload),
         {:ok, state_key} <- request_state_key(conn, payload),
         :ok <- require_session_for_followup(payload, state_key),
         {:ok, result} <- handle_payload(payload, state_key, local_daemon_trusted?) do
      send_transport_result(conn, result, state_key)
    else
      {:error, :invalid_json, conn} -> send_json_rpc_error(conn, 400, :invalid_json)
      {:error, :body_too_large, conn} -> send_json_rpc_error(conn, 413, :body_too_large)
      {:error, :body_read_failed, conn} -> send_json_rpc_error(conn, 400, :body_read_failed)
      {:error, :batch_not_supported} -> send_json_rpc_error(conn, 400, :batch_not_supported)
      {:error, :invalid_session_id, payload} -> send_json_rpc_error(conn, 400, :invalid_session_id, request_id(payload))
      {:error, :missing_session_id, payload} -> send_json_rpc_error(conn, 400, :missing_session_id, request_id(payload))
      {:error, :ledger_unavailable, payload} -> send_json_rpc_error(conn, 503, :ledger_unavailable, request_id(payload))
    end
  end

  defp dispatch(%Conn{method: "GET"} = conn, _local_daemon_trusted?), do: send_method_not_allowed(conn)
  defp dispatch(%Conn{} = conn, _local_daemon_trusted?), do: send_method_not_allowed(conn)

  defp read_json_body(conn) do
    case Conn.read_body(conn, length: @max_body_bytes, read_length: @max_body_bytes) do
      {:ok, body, conn} -> decode_json_body(body, conn)
      {:more, _partial, conn} -> {:error, :body_too_large, conn}
      {:error, _reason} -> {:error, :body_read_failed, conn}
    end
  end

  defp decode_json_body("", conn), do: {:error, :invalid_json, conn}

  defp decode_json_body(body, conn) do
    case Jason.decode(body) do
      {:ok, payload} -> {:ok, payload, conn}
      {:error, _reason} -> {:error, :invalid_json, conn}
    end
  end

  defp reject_batch_payload(payload) when is_list(payload), do: {:error, :batch_not_supported}
  defp reject_batch_payload(_payload), do: :ok

  defp request_state_key(conn, payload) do
    case Conn.get_req_header(conn, @session_header) do
      [] -> {:ok, nil}
      [state_key] -> normalize_session_id(state_key, payload)
      _multiple -> {:error, :invalid_session_id, payload}
    end
  end

  defp normalize_session_id(state_key, payload) when is_binary(state_key) do
    cond do
      state_key == "" -> {:error, :invalid_session_id, payload}
      byte_size(state_key) > 256 -> {:error, :invalid_session_id, payload}
      not visible_ascii?(state_key) -> {:error, :invalid_session_id, payload}
      HTTPTransport.reserved_state_key?(state_key) -> {:error, :invalid_session_id, payload}
      true -> {:ok, state_key}
    end
  end

  defp visible_ascii?(<<>>), do: true
  defp visible_ascii?(<<byte, rest::binary>>) when byte >= 0x21 and byte <= 0x7E, do: visible_ascii?(rest)
  defp visible_ascii?(_value), do: false

  defp require_session_for_followup(payload, nil) do
    if sessionless_initialize?(payload), do: :ok, else: {:error, :missing_session_id, payload}
  end

  defp require_session_for_followup(_payload, state_key) when is_binary(state_key), do: :ok

  defp handle_payload(payload, nil, local_daemon_trusted?) do
    with_live_repo(payload, fn repo ->
      HTTPTransport.handle(mcp_config(repo, local_daemon_trusted?), payload, client_key: @client_key)
    end)
  end

  defp handle_payload(payload, state_key, local_daemon_trusted?) when is_binary(state_key) do
    config = mcp_config(configured_repo(), local_daemon_trusted?)

    case stored_server(config, state_key) do
      nil ->
        handle_with_live_repo_or_config(config, payload, state_key, local_daemon_trusted?)

      %Server{} = server ->
        handle_stored_server_payload(config, payload, state_key, server, local_daemon_trusted?)
    end
  end

  defp handle_with_live_repo_or_config(config, payload, state_key, local_daemon_trusted?) do
    case handle_with_live_repo(payload, state_key, local_daemon_trusted?) do
      {:error, :ledger_unavailable, ^payload} ->
        HTTPTransport.handle(config, payload, client_key: @client_key, state_key: state_key)

      result ->
        result
    end
  end

  defp handle_stored_server_payload(config, payload, state_key, %Server{} = server, local_daemon_trusted?) do
    cond do
      health_followup?(payload) ->
        handle_with_live_repo_or_config(config, payload, state_key, local_daemon_trusted?)

      repo_backed_followup?(payload, server) ->
        handle_with_live_repo(payload, state_key, local_daemon_trusted?)

      true ->
        HTTPTransport.handle(config, payload, client_key: @client_key, state_key: state_key)
    end
  end

  defp handle_with_live_repo(payload, state_key, local_daemon_trusted?) do
    with_live_repo(payload, fn repo ->
      HTTPTransport.handle(mcp_config(repo, local_daemon_trusted?), payload, client_key: @client_key, state_key: state_key)
    end)
  end

  defp with_live_repo(payload, fun) when is_function(fun, 1) do
    case SymppBoardLive.with_dashboard_repo(fn repo -> {:ok, fun.(repo)} end, initialize_missing?: true) do
      {:ok, transport_result} -> transport_result
      {:error, _reason} -> {:error, :ledger_unavailable, payload}
    end
  end

  defp stored_server(%Config{} = config, state_key), do: HTTPStateStore.get(config, @client_key, state_key)

  defp repo_backed_followup?(%{"method" => "tools/list"}, %Server{session: %Session{}}), do: true
  defp repo_backed_followup?(payload, %Server{}), do: repo_backed_followup?(payload)

  defp health_followup?(%{"method" => "tools/call", "params" => %{"name" => "sympp.health"}}), do: true
  defp health_followup?(_payload), do: false

  defp repo_backed_followup?(%{"method" => "resources/list"}), do: true
  defp repo_backed_followup?(%{"method" => "resources/read", "params" => %{"uri" => uri}}), do: protected_resource_uri?(uri)
  defp repo_backed_followup?(%{"method" => "tools/call", "params" => %{"name" => "sympp.health"}}), do: false
  defp repo_backed_followup?(%{"method" => "tools/call"}), do: true
  defp repo_backed_followup?(_payload), do: false

  defp protected_resource_uri?(uri) when is_binary(uri) do
    uri == @assignment_resource or String.starts_with?(uri, @work_package_resource_prefix)
  end

  defp protected_resource_uri?(_uri), do: false

  defp send_transport_result(conn, %HTTPTransport.Result{status: :no_response, state_key: nil}, request_state_key)
       when is_binary(request_state_key) do
    send_json_rpc_error(conn, 404, :unknown_state_key)
  end

  defp send_transport_result(conn, %HTTPTransport.Result{status: :no_response} = result, _request_state_key) do
    conn
    |> maybe_put_session_header(result.state_key)
    |> Conn.send_resp(202, "")
    |> Conn.halt()
  end

  defp send_transport_result(conn, %HTTPTransport.Result{} = result, _request_state_key) do
    status = if error_reason?(result.response, "unknown_state_key"), do: 404, else: 200

    conn
    |> maybe_put_session_header(result.state_key)
    |> send_json(status, result.response)
  end

  defp maybe_put_session_header(conn, nil), do: conn
  defp maybe_put_session_header(conn, state_key), do: Conn.put_resp_header(conn, @session_header, state_key)

  defp send_method_not_allowed(conn) do
    conn
    |> Conn.put_resp_header("allow", "POST")
    |> send_json_rpc_error(405, :method_not_allowed)
  end

  defp send_json_rpc_error(conn, status, reason, id \\ nil) do
    send_json(conn, status, json_rpc_error(id, reason))
  end

  defp send_json(conn, status, payload) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, Jason.encode!(payload))
    |> Conn.halt()
  end

  defp json_rpc_error(id, :invalid_json), do: error_response(id, -32_700, "Parse error", "invalid_json")
  defp json_rpc_error(id, :body_too_large), do: error_response(id, -32_600, "Invalid Request", "body_too_large")
  defp json_rpc_error(id, :body_read_failed), do: error_response(id, -32_600, "Invalid Request", "body_read_failed")
  defp json_rpc_error(id, :batch_not_supported), do: error_response(id, -32_600, "Invalid Request", "batch_not_supported")
  defp json_rpc_error(id, :invalid_session_id), do: error_response(id, -32_600, "Invalid Request", "invalid_session_id")
  defp json_rpc_error(id, :missing_session_id), do: error_response(id, -32_600, "Invalid Request", "missing_session_id")
  defp json_rpc_error(id, :unknown_state_key), do: error_response(id, -32_600, "Invalid Request", "unknown_state_key")
  defp json_rpc_error(id, :ledger_unavailable), do: error_response(id, -32_000, "Server error", "ledger_unavailable")
  defp json_rpc_error(id, :local_only), do: error_response(id, -32_600, "Invalid Request", "local_only")
  defp json_rpc_error(id, :origin_not_allowed), do: error_response(id, -32_600, "Invalid Request", "origin_not_allowed")
  defp json_rpc_error(id, :method_not_allowed), do: error_response(id, -32_601, "Method not found", "method_not_allowed")

  defp error_response(id, code, message, reason) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message, "data" => %{"reason" => reason}}}
  end

  defp request_id(%{"id" => id}) when is_binary(id) or is_number(id) or is_nil(id), do: id
  defp request_id(_payload), do: nil

  defp error_reason?(%{"error" => %{"data" => %{"reason" => reason}}}, reason), do: true
  defp error_reason?(responses, reason) when is_list(responses), do: Enum.any?(responses, &error_reason?(&1, reason))
  defp error_reason?(_response, _reason), do: false

  defp sessionless_initialize?(%{"jsonrpc" => "2.0", "method" => "initialize"}), do: true

  defp sessionless_initialize?(payloads) when is_list(payloads) do
    payloads != [] and Enum.all?(payloads, &standalone_initialize?/1)
  end

  defp sessionless_initialize?(_payload), do: false

  defp standalone_initialize?(%{"jsonrpc" => "2.0", "method" => "initialize"}), do: true
  defp standalone_initialize?(_payload), do: false

  defp validate_local_request(conn) do
    cond do
      not loopback_address?(conn.remote_ip) -> {:error, :local_only}
      not loopback_host?(conn.host) -> {:error, :local_only}
      forwarded_request?(conn) -> {:error, :local_only}
      # This is the trust signal consumed by local-operator tools; rejected
      # requests never build an MCP server/config.
      true -> {:ok, true}
    end
  end

  defp validate_origin(conn) do
    case Conn.get_req_header(conn, "origin") do
      [] -> :ok
      [origin] -> if same_local_origin?(origin, conn), do: :ok, else: {:error, :origin_not_allowed}
      _multiple -> {:error, :origin_not_allowed}
    end
  end

  defp forwarded_request?(conn) do
    Enum.any?(conn.req_headers, fn {name, _value} ->
      name in @forwarded_headers or String.starts_with?(name, "x-forwarded-")
    end)
  end

  defp same_local_origin?(origin, conn) do
    if visible_ascii?(origin) do
      uri = URI.parse(origin)
      origin_scheme = normalize_scheme(uri.scheme)
      origin_host = normalize_host(uri.host)

      origin_scheme == Atom.to_string(conn.scheme) and
        loopback_host?(origin_host) and
        origin_host == normalize_host(conn.host) and
        origin_port(uri) == request_port(conn)
    else
      false
    end
  rescue
    URI.Error -> false
  end

  defp origin_port(%URI{port: nil, scheme: scheme}), do: default_port(normalize_scheme(scheme))
  defp origin_port(%URI{port: port}), do: port

  defp request_port(%Conn{port: port}), do: port

  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 80

  defp normalize_scheme(nil), do: nil
  defp normalize_scheme(scheme), do: String.downcase(scheme)

  defp loopback_host?(host) when is_binary(host) do
    case normalize_host(host) do
      "localhost" -> true
      normalized_host when is_binary(normalized_host) -> loopback_address_host?(normalized_host)
      _invalid -> false
    end
  end

  defp loopback_host?(_host), do: false

  defp normalize_host(nil), do: nil

  defp normalize_host(host) do
    if visible_ascii?(host) do
      host
      |> String.trim()
      |> String.downcase()
      |> unbracket_ipv6_host()
    end
  end

  defp unbracket_ipv6_host(<<"[", rest::binary>>) do
    if String.ends_with?(rest, "]"), do: binary_part(rest, 0, byte_size(rest) - 1), else: "[" <> rest
  end

  defp unbracket_ipv6_host(host), do: host

  defp loopback_address_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> loopback_address?(address)
      {:error, _reason} -> false
    end
  end

  defp loopback_address?({127, _second, _third, _fourth}), do: true
  defp loopback_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_address?({0, 0, 0, 0, 0, 65_535, first, _second}) when first >= 0x7F00 and first <= 0x7FFF, do: true
  defp loopback_address?(_remote_ip), do: false

  defp configured_repo, do: endpoint_config(:sympp_repo) || Repo

  defp mcp_config(repo, local_daemon_trusted?) do
    Config.default(
      mode: :http,
      repo: repo,
      database: configured_database(repo),
      repo_root:
        endpoint_config(:sympp_repo_root) ||
          Application.get_env(:symphony_elixir, :sympp_repo_root),
      local_daemon_trusted: local_daemon_trusted?
    )
  end

  defp configured_database(repo) do
    repo_database = repo_configured_database(repo)
    sympp_repo_database = Application.get_env(:symphony_elixir, :sympp_repo_database) |> normalize_database()

    cond do
      custom_repo?(repo) and not is_nil(repo_database) -> repo_database
      not is_nil(sympp_repo_database) -> sympp_repo_database
      not is_nil(repo_database) -> repo_database
      true -> nil
    end
  end

  defp custom_repo?(repo) when is_atom(repo), do: repo != Repo
  defp custom_repo?(_repo), do: false

  defp repo_configured_database(repo) when is_atom(repo) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0) do
      repo.config()
      |> Keyword.get(:database)
      |> normalize_database()
    end
  rescue
    _error -> nil
  end

  defp repo_configured_database(_repo), do: nil

  defp normalize_database(database) when is_binary(database) do
    if String.trim(database) == "", do: nil, else: database
  end

  defp normalize_database(database), do: database

  defp endpoint_config(key) do
    :symphony_elixir
    |> Application.get_env(Endpoint, [])
    |> Keyword.get(key)
    |> Kernel.||(Endpoint.config(key))
  end
end
