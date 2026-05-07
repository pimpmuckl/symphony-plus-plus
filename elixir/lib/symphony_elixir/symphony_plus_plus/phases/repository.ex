defmodule SymphonyElixir.SymphonyPlusPlus.Phases.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository

  @type repo :: module()
  @type error ::
          :database_busy
          | :id_already_exists
          | :not_found
          | {:migration_failed, term()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec migrate(repo()) :: :ok | {:error, error()}
  def migrate(repo) when is_atom(repo) do
    Ecto.Migrator.run(repo, WorkPackageRepository.migrations_path(), :up, all: true, log: false)
    :ok
  rescue
    error -> {:error, {:migration_failed, error}}
  end

  @spec create(repo(), map()) :: {:ok, Phase.t()} | {:error, error()}
  def create(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs
    |> Phase.create_changeset()
    |> repo.insert()
    |> normalize_insert_result()
  rescue
    _error in Ecto.ConstraintError -> {:error, :id_already_exists}
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get(repo(), String.t()) :: {:ok, Phase.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(Phase, id) do
      nil -> {:error, :not_found}
      phase -> {:ok, phase}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list(repo()) :: {:ok, [Phase.t()]} | {:error, error()}
  def list(repo) when is_atom(repo) do
    phases =
      repo.all(
        from(phase in Phase,
          order_by: [asc: phase.inserted_at, asc: phase.id]
        )
      )

    {:ok, phases}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp normalize_insert_result({:ok, phase}), do: {:ok, phase}

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

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    if String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end
end
