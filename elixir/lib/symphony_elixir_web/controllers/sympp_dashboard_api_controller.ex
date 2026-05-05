defmodule SymphonyElixirWeb.SymppDashboardApiController do
  @moduledoc """
  Read-oriented JSON API for Symphony++ dashboard state.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.TrackerAdapter
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixirWeb.Endpoint

  @type auth_context :: {:grant, AccessGrant.t()}
  @board_session_key "sympp_board_grant_id"

  @spec authorize_board_browser(Conn.t(), term()) :: Conn.t()
  def authorize_board_browser(conn, _opts) do
    case authorize_board_request(conn) do
      {:ok, %AccessGrant{} = grant} -> Conn.put_session(conn, @board_session_key, grant.id)
      {:error, :unauthorized} -> conn |> board_login_response() |> Conn.halt()
      {:error, reason} -> conn |> board_browser_error_response(reason) |> Conn.halt()
    end
  end

  @spec authorize_board_session(map()) :: :ok | {:error, term()}
  def authorize_board_session(session) when is_map(session) do
    session
    |> Map.get(@board_session_key)
    |> authorize_board_grant_id()
    |> case do
      {:ok, %AccessGrant{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec board_session(Conn.t(), map()) :: Conn.t()
  def board_session(conn, %{"work_key" => secret}) when is_binary(secret) do
    secret = String.trim(secret)

    case authorize_board_secret(secret) do
      {:ok, %AccessGrant{} = grant} ->
        conn
        |> Conn.put_session(@board_session_key, grant.id)
        |> redirect(to: "/sympp/board")

      {:error, :forbidden} ->
        conn |> board_login_response(status: 403, message: "The work key is not allowed to open the board.") |> Conn.halt()

      {:error, :database_busy} ->
        conn |> board_login_response(status: 503, message: "The dashboard ledger is busy. Try again.") |> Conn.halt()

      {:error, {:storage_failed, _reason}} ->
        conn |> board_login_response(status: 503, message: "The board ledger could not be read.") |> Conn.halt()

      {:error, {:repo_start_failed, _reason}} ->
        conn |> board_login_response(status: 503, message: "The board ledger could not be opened.") |> Conn.halt()

      {:error, _reason} ->
        conn |> board_login_response(status: 401, message: "The work key could not access the board.") |> Conn.halt()
    end
  end

  def board_session(conn, _params) do
    conn |> board_login_response(status: 400, message: "Enter a work key to open the board.") |> Conn.halt()
  end

  @spec board(Conn.t(), map()) :: Conn.t()
  def board(conn, _params) do
    send_repo_response(conn, fn repo, secret ->
      with {:ok, auth_context} <- auth_context(conn, repo, secret),
           :ok <- require_global_board(auth_context),
           {:ok, payload} <- Dashboard.board(repo) do
        json(conn, payload)
      end
    end)
  end

  @spec detail(Conn.t(), map()) :: Conn.t()
  def detail(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, work_package_id, &Dashboard.detail/2)
  end

  @spec timeline(Conn.t(), map()) :: Conn.t()
  def timeline(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, work_package_id, &Dashboard.timeline/2)
  end

  @spec artifacts(Conn.t(), map()) :: Conn.t()
  def artifacts(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, work_package_id, &Dashboard.artifacts/2)
  end

  @spec blockers(Conn.t(), map()) :: Conn.t()
  def blockers(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, work_package_id, &Dashboard.blockers/2)
  end

  @spec grants(Conn.t(), map()) :: Conn.t()
  def grants(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, work_package_id, &Dashboard.grants/2)
  end

  @spec agent_runs(Conn.t(), map()) :: Conn.t()
  def agent_runs(conn, %{"work_package_id" => work_package_id}) do
    send_package_response(conn, work_package_id, &Dashboard.agent_runs/2)
  end

  defp send_package_response(conn, work_package_id, fetch_fun) do
    send_repo_response(conn, fn repo, secret ->
      with {:ok, auth_context} <- auth_context(conn, repo, secret),
           :ok <- require_work_package(auth_context, work_package_id),
           {:ok, payload} <- fetch_fun.(repo, work_package_id) do
        json(conn, scoped_package_payload(auth_context, payload))
      end
    end)
  end

  defp send_repo_response(conn, fun) when is_function(fun, 2) do
    case bearer_secret(conn) do
      nil -> {:error, :unauthorized}
      secret -> send_authenticated_repo_response(secret, fun)
    end
    |> case do
      {:error, reason} -> error_response(conn, reason)
      %Conn{} = conn -> conn
    end
  end

  defp authorize_board_request(conn) do
    with {:error, :unauthorized} <- conn |> Conn.get_session(@board_session_key) |> authorize_board_grant_id() do
      case bearer_secret(conn) do
        nil -> {:error, :unauthorized}
        secret -> authorize_board_secret(secret)
      end
    end
  end

  defp authorize_board_secret(secret) do
    with true <- auth_storage_ready?(secret),
         {:ok, {:grant, %AccessGrant{} = grant} = auth_context} <- authenticate_with_existing_repo(secret),
         :ok <- require_global_board(auth_context) do
      {:ok, grant}
    else
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec authorize_board_grant_id(term()) :: {:ok, AccessGrant.t()} | {:error, term()}
  def authorize_board_grant_id(grant_id) when is_binary(grant_id) do
    with true <- dashboard_storage_present?(),
         {:ok, {:grant, %AccessGrant{} = grant} = auth_context} <- authenticate_grant_id_with_existing_repo(grant_id),
         :ok <- require_global_board(auth_context) do
      {:ok, grant}
    else
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def authorize_board_grant_id(_grant_id), do: {:error, :unauthorized}

  defp send_authenticated_repo_response(secret, fun) do
    if auth_storage_ready?(secret) do
      send_after_repo_auth(secret, fun)
    else
      {:error, :unauthorized}
    end
  end

  defp send_after_repo_auth(secret, fun) do
    with {:ok, {:grant, %AccessGrant{}}} <- authenticate_with_existing_repo(secret) do
      with_dashboard_repo(fn repo -> fun.(repo, secret) end)
    end
  end

  defp auth_storage_ready?(secret), do: WorkKey.secret_shape?(secret) and dashboard_storage_present?()

  defp authenticate_with_existing_repo(secret) do
    case with_dashboard_repo(fn repo -> grant_auth_context(repo, secret) end, migrate?: false) do
      {:error, {:storage_failed, message}} when is_binary(message) ->
        if missing_schema_message?(message), do: {:error, :unauthorized}, else: {:error, {:storage_failed, message}}

      result ->
        result
    end
  end

  defp authenticate_grant_id_with_existing_repo(grant_id) do
    case with_dashboard_repo(fn repo -> grant_id_auth_context(repo, grant_id) end, migrate?: false) do
      {:error, {:storage_failed, message}} when is_binary(message) ->
        if missing_schema_message?(message), do: {:error, :unauthorized}, else: {:error, {:storage_failed, message}}

      result ->
        result
    end
  end

  defp dashboard_storage_present? do
    case configured_repo() do
      Repo -> configured_repo_storage_present?()
      nil -> configured_repo_storage_present?()
      configured_repo -> custom_repo_storage_present?(configured_repo)
    end
  end

  defp configured_repo_storage_present? do
    configured_repo_storage_present?(Repo.database_path_if_present(), Process.whereis(Repo))
  end

  defp configured_repo_storage_present?(nil, pid) when is_pid(pid), do: local_repo_storage_present?(pid)
  defp configured_repo_storage_present?(nil, nil), do: false

  defp configured_repo_storage_present?(path, pid) when is_pid(pid) do
    local_repo_storage_present?(pid) or repo_matches_database?(pid, path) or
      :global.whereis_name(Repo.process_key(path)) != :undefined or persistent_database_present?(path)
  end

  defp configured_repo_storage_present?(path, nil), do: persistent_database_present?(path)

  defp local_repo_storage_present?(pid), do: not explicit_database_configured?() and repo_persistent_storage_present?(pid)

  defp explicit_database_configured? do
    Application.get_env(:symphony_elixir, :sympp_repo_database) != nil or configured_repo_database_configured?()
  end

  defp configured_repo_database_configured? do
    :symphony_elixir
    |> Application.get_env(Repo, [])
    |> Keyword.get(:database)
    |> configured_database_value?()
  end

  defp configured_database_value?(database_path) when is_binary(database_path), do: String.trim(database_path) != ""
  defp configured_database_value?(nil), do: false
  defp configured_database_value?(_database_path), do: true

  defp custom_repo_storage_present?(repo) do
    if ecto_repo?(repo) do
      custom_ecto_repo_storage_present?(repo)
    else
      true
    end
  end

  defp custom_ecto_repo_storage_present?(repo) do
    database_path = custom_repo_database_path(repo)

    case Process.whereis(repo) do
      pid when is_pid(pid) ->
        persistent_database_present?(database_path) and custom_repo_matches_database?(repo, database_path)

      nil ->
        persistent_database_present?(database_path)
    end
  end

  defp persistent_database_present?(database_path) do
    cond do
      Repo.memory_database?(database_path) -> false
      is_binary(database_path) -> filesystem_database_present?(database_path)
      true -> false
    end
  end

  defp filesystem_database_present?(database_path) do
    case filesystem_database_path(database_path) do
      path when is_binary(path) -> String.trim(path) != "" and File.exists?(path)
      _path -> false
    end
  end

  defp repo_persistent_storage_present?(pid) when is_pid(pid) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      case Repo.query("PRAGMA database_list", []) do
        {:ok, %{rows: rows}} ->
          Enum.any?(rows, fn
            [_seq, "main", path] when is_binary(path) and path != "" -> File.exists?(path)
            _row -> false
          end)

        {:error, _reason} ->
          false
      end
    rescue
      _error in Exqlite.Error -> false
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp filesystem_database_path("file:" <> _rest = database_path) do
    case Repo.sqlite_file_uri_path(database_path) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _path -> nil
    end
  end

  defp filesystem_database_path(database_path), do: Path.expand(database_path)

  defp auth_context(_conn, repo, secret) do
    grant_auth_context(repo, secret)
  end

  defp grant_auth_context(repo, secret) do
    normalize_storage_errors(fn ->
      with secret_hash <- WorkKey.secret_hash(secret),
           {:ok, %AccessGrant{} = grant} <- AccessGrantRepository.find_by_secret_hash(repo, secret_hash),
           true <- Plug.Crypto.secure_compare(secret_hash, grant.secret_hash),
           :ok <- live_grant?(grant) do
        {:ok, {:grant, grant}}
      else
        false -> {:error, :unauthorized}
        {:error, :invalid_secret} -> {:error, :unauthorized}
        {:error, :not_found} -> {:error, :unauthorized}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp grant_id_auth_context(repo, grant_id) do
    normalize_storage_errors(fn ->
      with {:ok, %AccessGrant{} = grant} <- AccessGrantRepository.get(repo, grant_id),
           :ok <- live_grant?(grant) do
        {:ok, {:grant, grant}}
      else
        {:error, :not_found} -> {:error, :unauthorized}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp bearer_secret(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      header when is_binary(header) -> bearer_secret_from_header(header)
      nil -> nil
    end
    |> case do
      "" -> nil
      secret -> secret
    end
  end

  defp bearer_secret_from_header(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, secret] when is_binary(secret) ->
        if String.downcase(scheme) == "bearer", do: String.trim(secret), else: nil

      _invalid ->
        nil
    end
  end

  defp live_grant?(%AccessGrant{revoked_at: %DateTime{}}), do: {:error, :unauthorized}
  defp live_grant?(%AccessGrant{claimed_at: nil}), do: {:error, :unauthorized}
  defp live_grant?(%AccessGrant{claimed_by: nil}), do: {:error, :unauthorized}

  defp live_grant?(%AccessGrant{expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) == :gt do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp require_global_board({:grant, %AccessGrant{capabilities: capabilities}}), do: require_capability(capabilities, "read:phase")

  defp require_work_package({:grant, %AccessGrant{} = grant}, work_package_id) do
    cond do
      has_capability?(grant.capabilities, "read:phase") -> :ok
      grant.grant_role == "worker" and grant.work_package_id == work_package_id -> :ok
      has_capability?(grant.capabilities, "read:package") and grant.work_package_id == work_package_id -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp require_capability(capabilities, capability) when is_list(capabilities) do
    if capability in capabilities, do: :ok, else: {:error, :forbidden}
  end

  defp scoped_package_payload({:grant, %AccessGrant{grant_role: "worker", capabilities: capabilities} = grant}, payload)
       when is_map(payload) do
    if has_capability?(capabilities, "read:phase") do
      payload
    else
      scope_worker_package_payload(payload, grant)
    end
  end

  defp scoped_package_payload(_auth_context, payload), do: payload

  defp scope_worker_package_payload(payload, grant) do
    payload
    |> scope_grants(grant)
    |> scope_agent_runs(grant)
    |> redact_worker_activity_identifiers()
    |> redact_worker_metadata_identifiers()
  end

  defp scope_grants(payload, %AccessGrant{id: grant_id}) do
    case fetch_payload_field(payload, :grants) do
      {:ok, grants_key, grants} when is_list(grants) ->
        grants = Enum.filter(grants, &(Map.get(&1, :id) == grant_id or Map.get(&1, "id") == grant_id))

        payload
        |> Map.put(grants_key, grants)
        |> put_summary_count("grant_count", length(grants))
        |> put_summary_count("active_grant_count", Enum.count(grants, &grant_active?/1))

      _missing ->
        payload
    end
  end

  defp scope_agent_runs(payload, %AccessGrant{id: grant_id}) do
    case fetch_payload_field(payload, :agent_runs) do
      {:ok, runs_key, runs} when is_list(runs) ->
        runs = Enum.filter(runs, &(Map.get(&1, :access_grant_id) == grant_id or Map.get(&1, "access_grant_id") == grant_id))

        payload
        |> Map.put(runs_key, runs)
        |> put_summary_count("agent_run_count", length(runs))
        |> put_summary_count("active_agent_run_count", Enum.count(runs, &agent_run_active?/1))

      _missing ->
        payload
    end
  end

  defp fetch_payload_field(payload, key) when is_atom(key) do
    cond do
      Map.has_key?(payload, key) -> {:ok, key, Map.fetch!(payload, key)}
      Map.has_key?(payload, Atom.to_string(key)) -> {:ok, Atom.to_string(key), Map.fetch!(payload, Atom.to_string(key))}
      true -> :error
    end
  end

  defp put_summary_count(%{"summary" => summary} = payload, key, count) when is_map(summary) do
    put_in(payload, ["summary", key], count)
  end

  defp put_summary_count(%{summary: summary} = payload, key, count) when is_map(summary) and is_binary(key) do
    Map.update!(payload, :summary, &Map.put(&1, String.to_existing_atom(key), count))
  end

  defp put_summary_count(payload, _key, _count), do: payload

  defp grant_active?(grant), do: Map.get(grant, :status) == "active" or Map.get(grant, "status") == "active"

  defp agent_run_active?(run) do
    status = Map.get(run, :status) || Map.get(run, "status")
    status in AgentRun.active_statuses()
  end

  defp redact_worker_activity_identifiers(payload) do
    [:progress, :findings, :events, :blockers]
    |> Enum.reduce(payload, fn field, payload -> redact_worker_activity_field(payload, field) end)
  end

  defp redact_worker_activity_field(payload, field) do
    case fetch_payload_field(payload, field) do
      {:ok, field_key, values} when is_list(values) ->
        Map.put(payload, field_key, Enum.map(values, &redact_activity_identifier_fields/1))

      _missing_or_non_list ->
        payload
    end
  end

  defp redact_worker_metadata_identifiers(payload) do
    case fetch_payload_field(payload, :metadata) do
      {:ok, field_key, metadata} when is_map(metadata) ->
        Map.put(payload, field_key, redact_activity_identifier_fields(metadata))

      _missing_or_non_map ->
        payload
    end
  end

  defp redact_activity_identifier_fields(%{} = value) do
    Map.new(value, fn {key, field_value} ->
      cond do
        activity_identifier_key?(key) -> {key, redacted_identifier(field_value)}
        activity_actor_key?(key) -> {key, redact_activity_actor_identifier_fields(field_value)}
        true -> {key, redact_activity_identifier_fields(field_value)}
      end
    end)
  end

  defp redact_activity_identifier_fields(values) when is_list(values), do: Enum.map(values, &redact_activity_identifier_fields/1)
  defp redact_activity_identifier_fields(value), do: value

  defp activity_identifier_key?(key) when key in [:access_grant_id, :agent_run_id, "access_grant_id", "agent_run_id"], do: true
  defp activity_identifier_key?(_key), do: false

  defp activity_actor_key?(key) when key in [:actor, "actor"], do: true
  defp activity_actor_key?(_key), do: false

  defp redact_activity_actor_identifier_fields(%{} = actor) do
    actor
    |> redact_existing_identifier_key(:id)
    |> redact_existing_identifier_key("id")
    |> redact_activity_identifier_fields()
  end

  defp redact_activity_actor_identifier_fields(value), do: redact_activity_identifier_fields(value)

  defp redact_existing_identifier_key(map, key) do
    if Map.has_key?(map, key), do: Map.update!(map, key, &redacted_identifier/1), else: map
  end

  defp redacted_identifier(nil), do: nil
  defp redacted_identifier(""), do: ""
  defp redacted_identifier(_value), do: "[REDACTED]"

  defp has_capability?(capabilities, capability) when is_list(capabilities), do: capability in capabilities
  defp has_capability?(_capabilities, _capability), do: false

  defp error_response(conn, :not_found), do: error_response(conn, 404, "not_found", "Work package not found")
  defp error_response(conn, :unauthorized), do: error_response(conn, 401, "unauthorized", "Unauthorized")
  defp error_response(conn, :forbidden), do: error_response(conn, 403, "forbidden", "Forbidden")
  defp error_response(conn, :database_busy), do: error_response(conn, 503, "database_busy", "Dashboard ledger is busy")

  defp error_response(conn, {:storage_failed, _reason}) do
    error_response(conn, 503, "storage_failed", "Dashboard ledger storage failed")
  end

  defp error_response(conn, _reason), do: error_response(conn, 500, "dashboard_unavailable", "Dashboard API unavailable")

  defp board_browser_error_response(conn, :forbidden) do
    board_login_response(conn, status: 403, message: "The work key is not allowed to open the board.")
  end

  defp board_browser_error_response(conn, :database_busy) do
    board_login_response(conn, status: 503, message: "The dashboard ledger is busy. Try again.")
  end

  defp board_browser_error_response(conn, {:storage_failed, _reason}) do
    board_login_response(conn, status: 503, message: "The board ledger could not be read.")
  end

  defp board_browser_error_response(conn, {:repo_start_failed, _reason}) do
    board_login_response(conn, status: 503, message: "The board ledger could not be opened.")
  end

  defp board_browser_error_response(conn, _reason) do
    board_login_response(conn, status: 500, message: "The board is temporarily unavailable.")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp board_login_response(conn, opts \\ []) do
    status = Keyword.get(opts, :status, 401)
    message = Keyword.get(opts, :message, "Enter a board work key to continue.")
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    body = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Symphony++ board access</title>
      <link rel="stylesheet" href="/dashboard.css">
    </head>
    <body>
      <main class="sympp-board-shell sympp-auth-shell">
        <section class="error-card">
          <p class="eyebrow">Symphony++</p>
          <h1 class="error-title">Board access</h1>
          <p class="error-copy">#{html_escape(message)}</p>
          <form class="sympp-board-filters" method="post" action="/sympp/board/session">
            <input type="hidden" name="_csrf_token" value="#{csrf_token}">
            <label>
              <span>Work key</span>
              <input type="password" name="work_key" autocomplete="current-password" required>
            </label>
            <button class="subtle-button" type="submit">Open board</button>
          </form>
        </section>
      </main>
    </body>
    </html>
    """

    conn
    |> Conn.put_resp_content_type("text/html")
    |> Conn.send_resp(status, body)
  end

  defp html_escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp normalize_storage_errors(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)

    if message |> String.downcase() |> busy_message?() do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end

  defp busy_message?(message) do
    String.contains?(message, "busy") or String.contains?(message, "locked")
  end

  defp missing_schema_message?(message) do
    message
    |> String.downcase()
    |> String.contains?("no such table")
  end

  defp with_dashboard_repo(fun, opts \\ []) when is_function(fun, 1) and is_list(opts) do
    migrate? = Keyword.get(opts, :migrate?, true)

    case configured_repo() do
      Repo -> with_configured_sympp_repo(fun, migrate?)
      repo when is_atom(repo) -> with_custom_repo(repo, fun, migrate?)
      nil -> with_dynamic_dashboard_repo(fun, migrate?)
    end
  end

  defp configured_repo do
    :symphony_elixir
    |> Application.get_env(Endpoint, [])
    |> Keyword.get(:sympp_repo)
    |> Kernel.||(Endpoint.config(:sympp_repo))
  end

  defp with_configured_sympp_repo(fun, migrate?) do
    database_path = Repo.database_path()

    with {:ok, pid, owner} <- configured_sympp_repo(database_path) do
      with_optional_migrated_repo(
        migrate?,
        pid,
        owner,
        database_path,
        fn -> ensure_configured_repo_migrated(pid, owner, database_path) end,
        fn -> call_configured_repo(pid, owner, fun) end
      )
    end
  end

  defp configured_sympp_repo(database_path) do
    case Process.whereis(Repo) do
      pid when is_pid(pid) -> local_configured_repo(pid, database_path)
      nil -> global_or_started_configured_repo(database_path)
    end
  end

  defp local_configured_repo(pid, database_path) do
    if not explicit_database_configured?() or repo_matches_database?(pid, database_path) do
      {:ok, pid, :local}
    else
      global_or_started_configured_repo(database_path)
    end
  end

  defp global_or_started_configured_repo(database_path) do
    case :global.whereis_name(Repo.process_key(database_path)) do
      pid when is_pid(pid) -> {:ok, pid, :dynamic}
      :undefined -> start_linked_repo(database_path)
    end
  end

  defp ensure_configured_repo_migrated(pid, :local, database_path) do
    ensure_repo_migrated(Repo, pid, local_repo_database_path(database_path))
  end

  defp ensure_configured_repo_migrated(pid, _owner, database_path), do: ensure_repo_migrated(Repo, pid, database_path)

  defp local_repo_database_path(fallback) do
    Repo.config()
    |> Keyword.get(:database)
    |> Kernel.||(fallback)
  end

  defp repo_matches_database?(pid, database_path) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      case Repo.query("PRAGMA database_list", []) do
        {:ok, %{rows: rows}} ->
          database_rows_match?(rows, database_path)

        {:error, _reason} ->
          false
      end
    rescue
      _error in Exqlite.Error -> false
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp call_configured_repo(pid, :dynamic, fun), do: call_dynamic_repo(pid, fun)
  defp call_configured_repo(pid, {:direct, _direct_pid}, fun), do: call_dynamic_repo(pid, fun)
  defp call_configured_repo(_pid, _owner, fun), do: fun.(Repo)

  defp call_dynamic_repo(pid, fun) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      fun.(Repo)
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp with_dynamic_dashboard_repo(fun, migrate?) do
    database_path = Repo.database_path()

    with {:ok, pid, owner} <- ensure_repo_started(database_path) do
      with_optional_migrated_repo(
        migrate?,
        pid,
        owner,
        database_path,
        fn -> ensure_repo_migrated(Repo, pid, database_path) end,
        fn -> call_dynamic_repo(pid, fun) end
      )
    end
  end

  defp ensure_repo_started(database_path) do
    case :global.whereis_name(Repo.process_key(database_path)) do
      pid when is_pid(pid) -> {:ok, pid, :shared}
      :undefined -> start_repo(database_path)
    end
  end

  defp start_repo(database_path) do
    child_spec =
      Supervisor.child_spec(
        {Repo, Repo.child_options(database: database_path, name: Repo.process_name(database_path))},
        id: Repo.child_id(database_path)
      )

    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) -> start_supervised_repo(child_spec)
      nil -> start_linked_repo(database_path)
    end
  end

  defp start_supervised_repo(child_spec) do
    case Supervisor.start_child(SymphonyElixir.Supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid, :shared}
      {:ok, pid, _info} -> {:ok, pid, :shared}
      {:error, {:already_started, pid}} -> {:ok, pid, :shared}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp start_linked_repo(database_path) do
    options = Repo.child_options(database: database_path, name: nil)

    case Repo.start_link(options) do
      {:ok, pid} -> unlink_started_repo(pid, {:direct, pid})
      {:error, {:already_started, pid}} -> {:ok, pid, :shared}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp unlink_started_repo(pid, owner) do
    Process.unlink(pid)
    {:ok, pid, owner}
  end

  defp stop_owned_repo(_pid, {:direct, direct_pid}, _database_path), do: stop_direct_repo(direct_pid)

  defp stop_owned_repo(_pid, _owner, _database_path), do: :ok

  defp stop_direct_repo(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp with_custom_repo(repo, fun, migrate?) do
    if ecto_repo?(repo) do
      with_ecto_custom_repo(repo, fun, migrate?)
    else
      fun.(repo)
    end
  end

  defp with_ecto_custom_repo(repo, fun, migrate?) do
    :global.trans({{__MODULE__, :custom_repo}, repo}, fn ->
      with_ecto_custom_repo_locked(repo, fun, migrate?)
    end)
  end

  defp with_ecto_custom_repo_locked(repo, fun, migrate?) do
    database_path = custom_repo_database_path(repo)

    with {:ok, pid, owner} <- ensure_custom_repo_started(repo, database_path) do
      with_optional_migrated_repo(
        migrate?,
        pid,
        owner,
        database_path,
        fn -> ensure_repo_migrated(repo, pid, database_path) end,
        fn -> fun.(repo) end
      )
    end
  end

  defp with_optional_migrated_repo(true, pid, owner, database_path, migrate_fun, call_fun) do
    with_migrated_repo(pid, owner, database_path, migrate_fun, call_fun)
  end

  defp with_optional_migrated_repo(false, pid, owner, database_path, _migrate_fun, call_fun) do
    call_unmigrated_repo(pid, owner, database_path, call_fun)
  end

  defp call_unmigrated_repo(pid, owner, database_path, call_fun) do
    call_fun.()
  after
    stop_owned_repo(pid, owner, database_path)
  end

  defp ecto_repo?(repo) do
    Code.ensure_loaded?(repo) and function_exported?(repo, :__adapter__, 0) and function_exported?(repo, :start_link, 1)
  end

  defp custom_repo_database_path(repo) do
    repo.config()
    |> Keyword.get(:database)
    |> Kernel.||(Repo.database_path())
  end

  defp ensure_custom_repo_started(repo, database_path) do
    case Process.whereis(repo) do
      pid when is_pid(pid) -> reuse_custom_repo(repo, pid, database_path)
      nil -> start_custom_repo(repo, database_path)
    end
  end

  defp reuse_custom_repo(repo, pid, database_path) do
    if custom_repo_matches_database?(repo, database_path) do
      {:ok, pid, :local}
    else
      {:error, {:storage_failed, :database_mismatch}}
    end
  end

  defp custom_repo_matches_database?(repo, database_path) do
    case repo.query("PRAGMA database_list", []) do
      {:ok, %{rows: rows}} ->
        database_rows_match?(rows, database_path)

      {:error, _reason} ->
        false
    end
  rescue
    _error in Exqlite.Error -> false
  end

  defp database_rows_match?(rows, database_path) do
    Enum.any?(rows, fn
      [_seq, "main", path] when path in [nil, ""] -> Repo.memory_database?(database_path)
      [_seq, _name, path] when is_binary(path) and path != "" -> database_row_path_matches?(path, database_path)
      _row -> false
    end)
  end

  defp database_row_path_matches?(path, "file:" <> _rest = database_path) do
    Repo.same_database_path?(path, Repo.sqlite_file_uri_path(database_path))
  end

  defp database_row_path_matches?(path, database_path), do: Repo.same_database_path?(path, database_path)

  defp start_custom_repo(repo, database_path) do
    case repo.start_link(database: database_path, name: repo) do
      {:ok, pid} -> unlink_started_repo(pid, {:direct, pid})
      {:error, {:already_started, pid}} -> {:ok, pid, :local}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp with_migrated_repo(pid, owner, database_path, migrate_fun, call_fun) do
    case migrate_fun.() do
      :ok ->
        try do
          call_fun.()
        after
          stop_owned_repo(pid, owner, database_path)
        end

      {:error, _reason} = error ->
        stop_owned_repo(pid, owner, database_path)
        error
    end
  end

  defp ensure_repo_migrated(repo, pid, database_path) when is_atom(repo) and is_pid(pid) do
    database_key = {repo, Repo.database_key(database_path)}

    if migrated_database?(database_key) and migrated_schema?(repo, pid) do
      :ok
    else
      migrate_with_lock(repo, pid, database_path, database_key)
    end
  end

  defp migrate_with_lock(repo, pid, database_path, database_key) do
    TrackerAdapter.run_with_migration_file_lock(database_path, fn ->
      migrate_if_needed(repo, pid, database_key)
    end)
  end

  defp migrate_if_needed(repo, pid, database_key) do
    if migrated_database?(database_key) and migrated_schema?(repo, pid) do
      :ok
    else
      migrate_repo(repo, pid, database_key)
    end
  end

  defp migrate_repo(Repo, pid, database_key) do
    migration_opts = [all: true, dynamic_repo: pid, log: false]

    Ecto.Migrator.run(Repo, WorkPackageRepository.migrations_path(), :up, migration_opts)

    mark_database_migrated(database_key)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
    error -> {:error, {:migration_failed, error}}
  end

  defp migrate_repo(repo, _pid, database_key) do
    Ecto.Migrator.run(repo, WorkPackageRepository.migrations_path(), :up, all: true, log: false)

    mark_database_migrated(database_key)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
    error -> {:error, {:migration_failed, error}}
  end

  defp migrated_database?(database_key), do: MapSet.member?(migrated_databases(), database_key)

  defp migrated_schema?(Repo, pid) when is_pid(pid) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      repo_schema_migrated?(Repo)
    rescue
      _error in Exqlite.Error -> false
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp migrated_schema?(repo, _pid), do: repo_schema_migrated?(repo)

  defp repo_schema_migrated?(repo) do
    expected_versions = migration_versions()

    case repo.query("SELECT version FROM schema_migrations", []) do
      {:ok, %{rows: rows}} ->
        migrated_versions =
          rows
          |> Enum.map(fn [version] -> to_string(version) end)
          |> MapSet.new()

        expected_versions != [] and MapSet.subset?(MapSet.new(expected_versions), migrated_versions)

      {:error, _reason} ->
        false
    end
  rescue
    _error in Exqlite.Error -> false
  end

  defp migration_versions do
    WorkPackageRepository.migrations_path()
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> Path.basename()
      |> String.split("_", parts: 2)
      |> hd()
    end)
  end

  defp mark_database_migrated(database_key) do
    migrated_databases = MapSet.put(migrated_databases(), database_key)
    Application.put_env(:symphony_elixir, :sympp_dashboard_api_migrated_databases, migrated_databases)
    :ok
  end

  defp migrated_databases do
    case Application.get_env(:symphony_elixir, :sympp_dashboard_api_migrated_databases, MapSet.new()) do
      %MapSet{} = migrated_databases -> migrated_databases
      _invalid -> MapSet.new()
    end
  end
end
