defmodule Mix.Tasks.Sympp.CreateWork do
  @moduledoc false

  use Mix.Task

  alias SymphonyElixir.SymphonyPlusPlus.CreateWork
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.Workflow

  @shortdoc "Creates one standalone Symphony++ WorkPackage and worker grant"
  @switches [file: :string, database: :string, help: :boolean]

  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      :help ->
        Mix.shell().info(usage())

      {:ok, opts} ->
        run_create_work(opts)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @spec usage() :: String.t()
  def usage do
    "Usage: mix sympp.create_work --file <request.json|request.yaml> [--database <sqlite-path>]"
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        cond do
          Keyword.get(opts, :help, false) -> :help
          blank?(Keyword.get(opts, :file)) -> {:error, usage()}
          true -> {:ok, opts}
        end

      {_opts, _argv, _invalid} ->
        {:error, usage()}
    end
  end

  defp run_create_work(opts) do
    original_repo = Repo.get_dynamic_repo()

    case start_repo(Keyword.get(opts, :database)) do
      {:ok, repo_pid} ->
        try do
          with :ok <- WorkPackageRepository.migrate(Repo),
               {:ok, request} <- CreateWork.parse_file(Keyword.fetch!(opts, :file)),
               {:ok, creation} <- CreateWork.create(Repo, request) do
            creation
            |> CreateWork.response_payload()
            |> Jason.encode!(pretty: true)
            |> Mix.shell().info()
          else
            {:error, reason} -> Mix.raise(CreateWork.error_message(reason))
          end
        after
          stop_repo(repo_pid)
          Repo.put_dynamic_repo(original_repo)
        end

      {:error, reason} ->
        Repo.put_dynamic_repo(original_repo)
        Mix.raise(CreateWork.error_message(reason))
    end
  end

  defp start_repo(database) do
    with :ok <- ensure_repo_dependencies_started() do
      database = resolved_database(database)

      case Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 1, log: false) do
        {:ok, pid} ->
          Repo.put_dynamic_repo(pid)
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          Repo.put_dynamic_repo(pid)
          {:ok, nil}

        {:error, reason} ->
          {:error, {:repo_start_failed, reason}}
      end
    end
  end

  defp stop_repo(pid) when is_pid(pid), do: GenServer.stop(pid)
  defp stop_repo(_pid), do: :ok

  defp ensure_repo_dependencies_started do
    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _started} -> :ok
      {:error, reason} -> {:error, {:ecto_start_failed, reason}}
    end
  end

  @doc false
  @spec database_path_for_test(String.t() | nil) :: String.t()
  def database_path_for_test(database), do: resolved_database(database)

  defp resolved_database(nil) do
    maybe_use_repo_root_workflow()
    Repo.database_path()
  end

  defp resolved_database(database) when is_binary(database) do
    cond do
      Repo.filesystem_database_path?(database) ->
        database = Path.expand(database)
        File.mkdir_p!(Path.dirname(database))
        database

      sqlite_file_uri?(database) and not Repo.memory_database?(database) ->
        prepare_sqlite_file_uri(database)
        database

      true ->
        database
    end
  end

  defp sqlite_file_uri?("file:" <> _uri), do: true
  defp sqlite_file_uri?(_database), do: false

  defp prepare_sqlite_file_uri(database) do
    case Repo.sqlite_file_uri_path(database) do
      uri_path when is_binary(uri_path) and uri_path != "" ->
        uri_path
        |> Path.expand()
        |> Path.dirname()
        |> File.mkdir_p!()

      _path ->
        :ok
    end
  end

  defp maybe_use_repo_root_workflow do
    if Application.get_env(:symphony_elixir, :workflow_file_path) == nil do
      mix_project_workflow()
      |> case do
        path when is_binary(path) -> Workflow.set_workflow_file_path(path)
        nil -> :ok
      end
    else
      :ok
    end
  end

  defp mix_project_workflow do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.expand()
    |> Path.join("WORKFLOW.md")
    |> existing_file()
  end

  defp existing_file(path) do
    if File.exists?(path), do: path
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
