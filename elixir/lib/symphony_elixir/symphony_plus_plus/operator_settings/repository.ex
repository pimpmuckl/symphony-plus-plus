defmodule SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository do
  @moduledoc false

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings

  @type repo :: module()
  @type error ::
          :database_busy
          | :id_already_exists
          | {:constraint_failed, String.t()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec get(repo()) :: {:ok, Settings.t()} | {:error, error()}
  def get(repo) when is_atom(repo) do
    {:ok, repo.get(Settings, Settings.settings_id()) || Settings.default()}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update(repo(), map()) :: {:ok, Settings.t()} | {:error, error()}
  def update(repo, attrs) when is_atom(repo) and is_map(attrs) do
    repo.transaction(fn ->
      case repo.get(Settings, Settings.settings_id()) do
        nil -> insert_settings_or_rollback(repo, attrs)
        %Settings{} = settings -> update_settings_or_rollback(repo, settings, attrs)
      end
    end)
    |> case do
      {:ok, settings} -> {:ok, settings}
      {:error, error} -> {:error, error}
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp insert_settings_or_rollback(repo, attrs) do
    attrs
    |> Settings.create_changeset()
    |> repo.insert()
    |> case do
      {:ok, settings} -> settings
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp update_settings_or_rollback(repo, %Settings{} = settings, attrs) do
    settings
    |> Settings.update_changeset(attrs)
    |> repo.update()
    |> case do
      {:ok, settings} -> settings
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_operator_settings_id_unique_index"}) do
    {:error, :id_already_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    {:error, {:constraint_failed, constraint}}
  end

  defp normalize_exqlite_error(%Exqlite.Error{message: message}) do
    normalized = String.downcase(to_string(message))

    cond do
      String.contains?(normalized, "database is locked") -> {:error, :database_busy}
      String.contains?(normalized, "database table is locked") -> {:error, :database_busy}
      true -> {:error, {:storage_failed, to_string(message)}}
    end
  end
end
