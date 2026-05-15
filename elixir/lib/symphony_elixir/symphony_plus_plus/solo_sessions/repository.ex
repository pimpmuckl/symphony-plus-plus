defmodule SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession

  @default_current_session_retry_attempts 50
  @solo_session_migration_version 20_260_515_150_000
  @solo_session_migration_module SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppSoloSessions

  @type repo :: module()
  @type error ::
          :current_session_conflict
          | :database_busy
          | :id_already_exists
          | :invalid_stale_after_days
          | :invalid_status
          | :invalid_transition
          | :invalid_workspace_path
          | :not_found
          | :stale_status
          | {:constraint_failed, String.t()}
          | {:migration_failed, term()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec migrate(repo()) :: :ok | {:error, error()}
  def migrate(repo) when is_atom(repo) do
    :ok = load_solo_session_migration()

    Ecto.Migrator.run(repo, [{@solo_session_migration_version, @solo_session_migration_module}], :up,
      all: true,
      log: false
    )

    :ok
  rescue
    error -> {:error, {:migration_failed, error}}
  end

  @spec create_or_attach_current(repo(), map()) :: {:ok, SoloSession.t()} | {:error, error()}
  def create_or_attach_current(repo, attrs) when is_atom(repo) and is_map(attrs) do
    with {:ok, attrs} <- normalize_session_attrs(attrs) do
      do_create_or_attach_current(repo, attrs, current_session_retry_attempts())
    end
  end

  @spec get(repo(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(SoloSession, id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list(repo()) :: {:ok, [SoloSession.t()]} | {:error, error()}
  @spec list(repo(), map()) :: {:ok, [SoloSession.t()]} | {:error, error()}
  def list(repo, filters \\ %{}) when is_atom(repo) and is_map(filters) do
    with {:ok, filters} <- normalize_session_filters(filters) do
      sessions =
        filters
        |> list_query()
        |> repo.all()

      {:ok, sessions}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update_status(repo(), String.t(), String.t(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def update_status(repo, id, current_status, next_status)
      when is_atom(repo) and is_binary(id) and is_binary(current_status) and is_binary(next_status) do
    current_status = String.trim(current_status)
    next_status = String.trim(next_status)

    with :ok <- validate_status(current_status),
         :ok <- validate_status(next_status),
         :ok <- validate_transition(current_status, next_status) do
      update_valid_status(repo, id, current_status, next_status)
    end
  end

  @spec archive_stale(repo()) :: {:ok, non_neg_integer()} | {:error, error()}
  def archive_stale(repo) when is_atom(repo) do
    archive_stale(repo, DateTime.utc_now(:microsecond), 30)
  end

  @spec archive_stale(repo(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, error()}
  def archive_stale(repo, %DateTime{} = now) when is_atom(repo) do
    archive_stale(repo, now, 30)
  end

  @spec archive_stale(repo(), DateTime.t(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, error()}
  def archive_stale(repo, %DateTime{} = now, stale_after_days)
      when is_atom(repo) and is_integer(stale_after_days) and stale_after_days > 0 do
    cutoff = DateTime.add(now, -stale_after_days * 24 * 60 * 60, :second)

    {count, _rows} =
      repo.update_all(
        from(session in SoloSession,
          where: session.status in ^SoloSession.current_statuses(),
          where: session.last_activity_at < ^cutoff
        ),
        set: [status: "archived", archived_at: now, updated_at: now]
      )

    {:ok, count}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  def archive_stale(repo, %DateTime{}, _stale_after_days) when is_atom(repo), do: {:error, :invalid_stale_after_days}

  defp do_create_or_attach_current(repo, attrs, attempts_left) do
    repo
    |> create_or_attach_current_transaction(attrs)
    |> handle_create_or_attach_result(repo, attrs, attempts_left)
  end

  defp create_or_attach_current_transaction(repo, attrs) do
    repo.transaction(fn ->
      case current_or_insert_session(repo, attrs) do
        {:ok, session} -> session
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp handle_create_or_attach_result({:ok, session}, _repo, _attrs, _attempts_left), do: {:ok, session}

  defp handle_create_or_attach_result({:error, reason}, repo, attrs, attempts_left)
       when reason in [:current_session_conflict, :database_busy] do
    retry_create_or_attach_or_error(repo, attrs, attempts_left, reason)
  end

  defp handle_create_or_attach_result({:error, reason}, _repo, _attrs, _attempts_left), do: {:error, reason}

  defp retry_create_or_attach_or_error(_repo, _attrs, 0, terminal_error), do: {:error, terminal_error}

  defp retry_create_or_attach_or_error(repo, attrs, attempts_left, _terminal_error) do
    Process.sleep(retry_delay_ms(attempts_left, current_session_retry_attempts()))
    do_create_or_attach_current(repo, attrs, attempts_left - 1)
  end

  defp current_or_insert_session(repo, attrs) do
    case current_by_scope(repo, attrs) do
      %SoloSession{} = session -> touch_current_session(repo, session)
      nil -> insert_current_session(repo, attrs)
    end
  end

  defp current_by_scope(repo, attrs) do
    with repo_name when is_binary(repo_name) <- Map.get(attrs, "repo"),
         base_branch when is_binary(base_branch) <- Map.get(attrs, "base_branch"),
         workspace_path when is_binary(workspace_path) <- Map.get(attrs, "workspace_path"),
         caller_id when is_binary(caller_id) <- Map.get(attrs, "caller_id") do
      repo.one(
        from(session in SoloSession,
          where: session.repo == ^repo_name,
          where: session.base_branch == ^base_branch,
          where: session.workspace_path == ^workspace_path,
          where: session.caller_id == ^caller_id,
          where: session.status in ^SoloSession.current_statuses(),
          order_by: [desc: session.last_activity_at, desc: session.inserted_at, desc: session.id],
          limit: 1
        )
      )
    else
      _value -> nil
    end
  end

  defp touch_current_session(repo, %SoloSession{id: id}) do
    now = DateTime.utc_now(:microsecond)

    id
    |> current_session_update_query()
    |> repo.update_all(set: [last_activity_at: now, updated_at: now])
    |> case do
      {1, _rows} -> {:ok, repo.get!(SoloSession, id)}
      {0, _rows} -> {:error, current_session_stale_error(repo, id)}
    end
  end

  defp insert_current_session(repo, attrs) do
    attrs
    |> SoloSession.create_changeset()
    |> repo.insert()
    |> normalize_session_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp update_valid_status(repo, id, current_status, next_status) do
    now = DateTime.utc_now(:microsecond)

    updates = [
      status: next_status,
      last_activity_at: now,
      updated_at: now
    ]

    updates =
      if next_status == "archived" do
        Keyword.put(updates, :archived_at, now)
      else
        updates
      end

    repo.transaction(fn ->
      id
      |> status_update_query(current_status)
      |> repo.update_all(set: updates)
      |> case do
        {1, _rows} -> repo.get!(SoloSession, id)
        {0, _rows} -> repo.rollback(stale_status_error(repo, id, current_status))
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp validate_status(status) do
    if status in SoloSession.statuses() do
      :ok
    else
      {:error, :invalid_status}
    end
  end

  defp validate_transition(status, status), do: {:error, :invalid_transition}
  defp validate_transition("active", next_status) when next_status in ["paused", "completed", "archived"], do: :ok
  defp validate_transition("paused", next_status) when next_status in ["active", "completed", "archived"], do: :ok
  defp validate_transition("completed", "archived"), do: :ok
  defp validate_transition(_current_status, _next_status), do: {:error, :invalid_transition}

  defp current_session_update_query(id) do
    from(session in SoloSession,
      where: session.id == ^id,
      where: session.status in ^SoloSession.current_statuses()
    )
  end

  defp status_update_query(id, current_status) do
    from(session in SoloSession,
      where: session.id == ^id,
      where: session.status == ^current_status
    )
  end

  defp list_query(filters) do
    base_query =
      from(session in SoloSession,
        order_by: [desc: session.last_activity_at, desc: session.inserted_at, asc: session.id]
      )

    Enum.reduce(filters, base_query, fn
      {"repo", repo_name}, query when is_binary(repo_name) and repo_name != "" ->
        from(session in query, where: session.repo == ^repo_name)

      {"base_branch", base_branch}, query when is_binary(base_branch) and base_branch != "" ->
        from(session in query, where: session.base_branch == ^base_branch)

      {"workspace_path", workspace_path}, query when is_binary(workspace_path) and workspace_path != "" ->
        from(session in query, where: session.workspace_path == ^workspace_path)

      {"caller_id", caller_id}, query when is_binary(caller_id) and caller_id != "" ->
        from(session in query, where: session.caller_id == ^caller_id)

      {"status", status}, query when is_binary(status) and status != "" ->
        from(session in query, where: session.status == ^status)

      _filter, query ->
        query
    end)
  end

  defp current_session_stale_error(repo, id) do
    case get(repo, id) do
      {:ok, %SoloSession{}} -> :current_session_conflict
      {:error, reason} -> reason
    end
  end

  defp stale_status_error(repo, id, current_status) do
    case get(repo, id) do
      {:ok, %SoloSession{status: status}} when status != current_status -> :stale_status
      {:ok, %SoloSession{}} -> :stale_status
      {:error, reason} -> reason
    end
  end

  defp normalize_session_insert_result({:ok, session}), do: {:ok, session}

  defp normalize_session_insert_result({:error, %Changeset{} = changeset}) do
    cond do
      changeset_constraint_error?(changeset, :id, :unique) -> {:error, :id_already_exists}
      changeset_constraint_error?(changeset, :repo, :unique) -> {:error, :current_session_conflict}
      true -> {:error, changeset}
    end
  end

  defp changeset_constraint_error?(changeset, field, constraint) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, options}} -> Keyword.get(options, :constraint) == constraint
      _error -> false
    end)
  end

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    cond do
      solo_session_id_constraint?(constraint) -> {:error, :id_already_exists}
      current_scope_constraint?(constraint) -> {:error, :current_session_conflict}
      true -> {:error, {:constraint_failed, constraint}}
    end
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    cond do
      String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") ->
        {:error, :database_busy}

      current_scope_constraint?(message) ->
        {:error, :current_session_conflict}

      solo_session_id_constraint?(message) ->
        {:error, :id_already_exists}

      true ->
        {:error, {:storage_failed, message}}
    end
  end

  defp solo_session_id_constraint?(constraint) do
    constraint in ["sympp_solo_sessions_id_unique_index", "sympp_solo_sessions_id_index"] or
      (String.contains?(constraint, "sympp_solo_sessions") and String.contains?(constraint, ".id"))
  end

  defp current_scope_constraint?(constraint) do
    constraint in [
      "sympp_solo_sessions_current_scope_unique_index",
      "sympp_solo_sessions_repo_base_branch_workspace_path_caller_id_index"
    ] or
      (String.contains?(constraint, "sympp_solo_sessions") and String.contains?(constraint, ".repo") and
         String.contains?(constraint, ".base_branch") and String.contains?(constraint, ".workspace_path") and
         String.contains?(constraint, ".caller_id"))
  end

  defp normalize_session_attrs(attrs) do
    attrs
    |> normalize_keys()
    |> trim_text_fields(["repo", "base_branch", "caller_id", "title"])
    |> normalize_workspace_path()
  end

  defp normalize_session_filters(filters) do
    filters
    |> normalize_keys()
    |> trim_text_fields(["repo", "base_branch", "caller_id", "status"])
    |> normalize_workspace_path()
  end

  defp normalize_workspace_path(attrs) do
    case Map.fetch(attrs, "workspace_path") do
      {:ok, workspace_path} ->
        with {:ok, workspace_path} <- canonical_workspace_path(workspace_path) do
          {:ok, Map.put(attrs, "workspace_path", workspace_path)}
        end

      :error ->
        {:ok, attrs}
    end
  end

  defp canonical_workspace_path(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:ok, value}

      Path.type(value) != :absolute ->
        {:error, :invalid_workspace_path}

      true ->
        workspace_path =
          value
          |> Path.expand()
          |> canonicalize_existing_segments()
          |> normalize_host_path_key()

        {:ok, workspace_path}
    end
  end

  defp canonical_workspace_path(value), do: {:ok, value}

  defp load_solo_session_migration do
    if Code.ensure_loaded?(@solo_session_migration_module) do
      :ok
    else
      @solo_session_migration_version
      |> solo_session_migration_file()
      |> Code.compile_file()

      :ok
    end
  end

  defp solo_session_migration_file(version) do
    Path.join(migrations_path(), "#{version}_create_sympp_solo_sessions.exs")
  end

  defp canonicalize_existing_segments(path) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical_path} -> canonical_path
      {:error, _reason} -> path
    end
  end

  defp normalize_host_path_key(path) do
    case :os.type() do
      {:win32, _name} ->
        path
        |> String.replace("\\", "/")
        |> String.downcase()

      _type ->
        path
    end
  end

  defp trim_text_fields(attrs, fields) do
    Enum.reduce(fields, attrs, fn field, acc ->
      Map.update(acc, field, nil, &trim_text/1)
    end)
  end

  defp trim_text(value) when is_binary(value), do: String.trim(value)
  defp trim_text(value), do: value

  defp retry_delay_ms(attempts_left, total_attempts) do
    used_attempts = max(total_attempts - attempts_left, 0)
    min(100, 5 + used_attempts * 5)
  end

  defp current_session_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_solo_session_current_retry_attempts, @default_current_session_retry_attempts)
    |> max(0)
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  @doc false
  @spec migrations_path() :: Path.t()
  def migrations_path do
    Application.app_dir(:symphony_elixir, "priv/symphony_plus_plus/repo/migrations")
  end
end
