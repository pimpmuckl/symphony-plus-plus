defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Repository do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.TrackerAdapter

  @cache_table __MODULE__

  @type error :: :database_busy | {:migration_failed, term()}

  @spec ensure_migrated(module()) :: :ok | {:error, error()}
  def ensure_migrated(repo) when is_atom(repo) do
    if ecto_repo?(repo) do
      database_path = main_database_path(repo)
      cache_key = migration_cache_key(repo, database_path)

      if migrated?(cache_key) do
        :ok
      else
        migrate_once(repo, database_path, cache_key)
      end
    else
      :ok
    end
  end

  defp ecto_repo?(repo), do: function_exported?(repo, :__adapter__, 0)

  defp migrate_once(repo, database_path, cache_key) do
    result =
      with_migration_lock(database_path, fn ->
        if migrated?(cache_key), do: :ok, else: migrate(repo)
      end)

    if result == :ok, do: mark_migrated(cache_key)
    result
  end

  defp with_migration_lock(database_path, fun) when is_binary(database_path) and database_path != "" do
    database_path
    |> TrackerAdapter.run_with_migration_file_lock(fun)
    |> normalize_lock_result()
  end

  defp with_migration_lock(_database_path, fun), do: fun.()

  defp normalize_lock_result(:ok), do: :ok

  defp normalize_lock_result({:error, {:repo_migration_file_lock_failed, _reason}}) do
    {:error, {:migration_failed, :migration_lock_failed}}
  end

  defp normalize_lock_result(result), do: result

  defp migrated?(cache_key) do
    ensure_cache_table()

    case :ets.lookup(@cache_table, cache_key) do
      [{^cache_key, true}] -> true
      _entries -> false
    end
  end

  defp mark_migrated(cache_key) do
    ensure_cache_table()
    :ets.insert(@cache_table, {cache_key, true})
  end

  defp ensure_cache_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        else
          _table -> :ok
        end

      _table ->
        :ok
    end
  end

  defp migrate(repo) do
    Ecto.Migrator.run(repo, Migrations.all(), :up, migration_opts(repo))
    :ok
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
    error -> {:error, {:migration_failed, error.__struct__}}
  catch
    kind, _reason -> {:error, {:migration_failed, kind}}
  end

  defp migration_opts(repo) do
    opts = [all: true, log: false]

    case dynamic_repo(repo) do
      nil -> opts
      ^repo -> opts
      dynamic_repo -> Keyword.put(opts, :dynamic_repo, dynamic_repo)
    end
  end

  defp main_database_path(repo) do
    case SQL.query(query_target(repo), "PRAGMA database_list", [], log: false) do
      {:ok, %{rows: rows}} -> Enum.find_value(rows, &main_database_path_from_row/1)
      {:error, _reason} -> nil
    end
  rescue
    _error -> nil
  end

  defp main_database_path_from_row([_seq, "main", path]) when is_binary(path), do: path
  defp main_database_path_from_row(_row), do: nil

  defp migration_cache_key(repo, database_path) do
    {repo, database_identity(repo, database_path), migration_signature()}
  end

  defp database_identity(_repo, path) when is_binary(path) and path != "", do: {:file, path}
  defp database_identity(repo, _path), do: {:dynamic_repo, dynamic_repo(repo) || repo}

  defp migration_signature do
    Migrations.signature()
  end

  defp query_target(repo) do
    case dynamic_repo(repo) do
      nil -> repo
      dynamic_repo -> dynamic_repo
    end
  end

  defp dynamic_repo(repo) when is_atom(repo) do
    if function_exported?(repo, :get_dynamic_repo, 0), do: repo.get_dynamic_repo()
  end

  defp normalize_exqlite_error(error) do
    error
    |> Exception.message()
    |> String.downcase()
    |> case do
      message when is_binary(message) ->
        if String.contains?(message, "busy") or String.contains?(message, "locked") do
          {:error, :database_busy}
        else
          {:error, {:migration_failed, :storage_failed}}
        end
    end
  end
end
