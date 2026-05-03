defmodule Mix.Tasks.Sympp.CreateWork do
  @moduledoc false

  use Mix.Task

  alias SymphonyElixir.SymphonyPlusPlus.CreateWork
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository

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
    database = database_path(database)

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

  defp stop_repo(pid) when is_pid(pid), do: GenServer.stop(pid)
  defp stop_repo(_pid), do: :ok

  defp database_path(nil), do: Repo.database_path()

  defp database_path(path) when is_binary(path) do
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))
    path
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
