defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository do
  @moduledoc false

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  import Ecto.Query, only: [from: 2]

  @type repo :: module()
  @type error :: :not_found | :id_already_exists | :stale_status | {:migration_failed, term()} | Changeset.t()

  @spec migrate(repo()) :: :ok | {:error, error()}
  def migrate(repo) when is_atom(repo) do
    Ecto.Migrator.run(repo, migrations_path(), :up, all: true, log: false)
    :ok
  rescue
    error -> {:error, {:migration_failed, error}}
  end

  @spec create(repo(), map()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def create(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs
    |> WorkPackage.create_changeset()
    |> repo.insert()
    |> normalize_insert_result()
  rescue
    _error in Ecto.ConstraintError -> {:error, :id_already_exists}
  end

  @spec get(repo(), String.t()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(WorkPackage, id) do
      nil -> {:error, :not_found}
      work_package -> {:ok, work_package}
    end
  end

  @spec list(repo()) :: {:ok, [WorkPackage.t()]} | {:error, error()}
  def list(repo) when is_atom(repo) do
    work_packages =
      repo.all(
        from(work_package in WorkPackage,
          order_by: [asc: work_package.inserted_at, asc: work_package.id]
        )
      )

    {:ok, work_packages}
  end

  @spec update(repo(), String.t(), map()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def update(repo, id, attrs) when is_atom(repo) and is_binary(id) and is_map(attrs) do
    with {:ok, work_package} <- get(repo, id) do
      work_package
      |> WorkPackage.update_changeset(attrs)
      |> repo.update()
    end
  end

  @spec update_status(repo(), String.t(), String.t(), String.t()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def update_status(repo, id, current_status, next_status)
      when is_atom(repo) and is_binary(id) and is_binary(current_status) and is_binary(next_status) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      id
      |> status_update_query(current_status)
      |> repo.update_all(set: [status: next_status, updated_at: now])
      |> case do
        {1, _rows} -> repo.get!(WorkPackage, id)
        {0, _rows} -> repo.rollback(stale_status_error(repo, id))
      end
    end)
    |> case do
      {:ok, work_package} -> {:ok, work_package}
      {:error, error} -> error
    end
  end

  defp normalize_insert_result({:ok, work_package}), do: {:ok, work_package}

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

  defp stale_status_error(repo, id) do
    case get(repo, id) do
      {:ok, _work_package} -> {:error, :stale_status}
      {:error, :not_found} = error -> error
    end
  end

  defp status_update_query(id, current_status) do
    from(work_package in WorkPackage,
      where: work_package.id == ^id and work_package.status == ^current_status
    )
  end

  defp migrations_path do
    Application.app_dir(:symphony_elixir, "priv/symphony_plus_plus/repo/migrations")
  end
end
