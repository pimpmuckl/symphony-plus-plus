defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository do
  @moduledoc false

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @type repo :: module()
  @type error ::
          :database_busy
          | :not_found
          | :id_already_exists
          | :invalid_status
          | :stale_status
          | {:constraint_failed, String.t()}
          | {:migration_failed, term()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec migrate(repo()) :: :ok | {:error, error()}
  def migrate(repo) when is_atom(repo) do
    Ecto.Migrator.run(repo, migrations_path(), :up, all: true, log: false)
    :ok
  rescue
    error -> {:error, {:migration_failed, error}}
  end

  @spec create(repo(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def create(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs
    |> WorkRequest.create_changeset()
    |> repo.insert()
    |> normalize_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get(repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(WorkRequest, id) do
      nil -> {:error, :not_found}
      work_request -> {:ok, work_request}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list(repo()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  @spec list(repo(), map()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  def list(repo, filters \\ %{}) when is_atom(repo) and is_map(filters) do
    work_requests =
      repo.all(
        filters
        |> normalize_keys()
        |> list_query()
      )

    {:ok, work_requests}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update(repo(), String.t(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def update(repo, id, attrs) when is_atom(repo) and is_binary(id) and is_map(attrs) do
    with {:ok, work_request} <- get(repo, id) do
      work_request
      |> WorkRequest.update_changeset(attrs)
      |> repo.update()
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update_status(repo(), String.t(), String.t(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def update_status(repo, id, current_status, next_status)
      when is_atom(repo) and is_binary(id) and is_binary(current_status) and is_binary(next_status) do
    with :ok <- validate_status(current_status),
         :ok <- validate_status(next_status) do
      update_valid_status(repo, id, current_status, next_status)
    end
  end

  defp list_query(filters) do
    base_query =
      from(work_request in WorkRequest,
        order_by: [asc: work_request.inserted_at, asc: work_request.id]
      )

    Enum.reduce(filters, base_query, fn
      {"status", status}, query when is_binary(status) and status != "" ->
        from(work_request in query, where: work_request.status == ^status)

      {"repo", repo}, query when is_binary(repo) and repo != "" ->
        from(work_request in query, where: work_request.repo == ^repo)

      {"base_branch", base_branch}, query when is_binary(base_branch) and base_branch != "" ->
        from(work_request in query, where: work_request.base_branch == ^base_branch)

      _filter, query ->
        query
    end)
  end

  defp update_valid_status(repo, id, current_status, next_status) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      id
      |> status_update_query(current_status)
      |> repo.update_all(set: [status: next_status, updated_at: now])
      |> case do
        {1, _rows} -> repo.get!(WorkRequest, id)
        {0, _rows} -> repo.rollback(stale_status_error(repo, id))
      end
    end)
    |> case do
      {:ok, work_request} -> {:ok, work_request}
      {:error, error} -> error
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp validate_status(status) do
    if status in WorkRequest.statuses() do
      :ok
    else
      {:error, :invalid_status}
    end
  end

  defp stale_status_error(repo, id) do
    case get(repo, id) do
      {:ok, _work_request} -> {:error, :stale_status}
      {:error, :not_found} = error -> error
      {:error, reason} -> {:error, reason}
    end
  end

  defp status_update_query(id, current_status) do
    from(work_request in WorkRequest,
      where: work_request.id == ^id and work_request.status == ^current_status
    )
  end

  defp normalize_insert_result({:ok, work_request}), do: {:ok, work_request}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    if duplicate_id?(changeset) do
      {:error, :id_already_exists}
    else
      {:error, changeset}
    end
  end

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    cond do
      constraint in ["sympp_work_requests_id_unique_index", "sympp_work_requests_id_index"] ->
        {:error, :id_already_exists}

      String.contains?(constraint, "sympp_work_requests") and String.contains?(constraint, ".id") ->
        {:error, :id_already_exists}

      true ->
        {:error, {:constraint_failed, constraint}}
    end
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    if String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
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
