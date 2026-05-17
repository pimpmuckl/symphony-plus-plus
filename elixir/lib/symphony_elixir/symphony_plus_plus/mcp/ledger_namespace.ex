defmodule SymphonyElixir.SymphonyPlusPlus.MCP.LedgerNamespace do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Config

  @spec key(Config.t()) :: term()
  def key(%Config{repo: repo, database: database}) do
    if configured_database?(database),
      do: {:configured_database, repo_database_key(repo, database)},
      else: live_or_configured_key(repo, database)
  end

  defp configured_database?(database), do: is_binary(database) and String.trim(database) != ""

  defp live_or_configured_key(repo, database) do
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
    case dynamic_repo_identity(repo) do
      pid when is_pid(pid) -> SQL.query(pid, sql, params, opts)
      dynamic_repo when is_atom(dynamic_repo) and dynamic_repo != repo -> SQL.query(dynamic_repo, sql, params, opts)
      _repo -> SQL.query(repo, sql, params, opts)
    end
  end

  defp repo_query(repo, sql, params, opts), do: SQL.query(repo, sql, params, opts)

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
end
