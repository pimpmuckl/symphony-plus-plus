defmodule Mix.Tasks.Sympp.Solo do
  @moduledoc false

  use Mix.Task

  alias Ecto.Adapters.SQL
  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.Workflow

  @shortdoc "Manages local Symphony++ Solo Sessions"

  @commands ["attach", "append", "show", "list", "pause", "resume", "complete", "archive"]
  @lifecycle_commands ["pause", "resume", "complete", "archive"]
  @durable_database_error_message "mix sympp.solo requires a durable file-backed SQLite database; in-memory databases are not supported because Solo Sessions must persist across CLI invocations."
  @sqlite_file_uri_error_message "mix sympp.solo supports --database as a durable local filesystem path only; SQLite file: URIs are not supported in Solo Session CLI v1."
  @unsupported_database_error_message "mix sympp.solo supports --database as a durable local filesystem path only; URI/DSN database targets are not supported in Solo Session CLI v1."
  @existing_database_commands ["append", "show", "list", "pause", "resume", "complete", "archive"]
  @switches [
    database: :string,
    repo: :string,
    base_branch: :string,
    workspace_path: :string,
    caller_id: :string,
    title: :string,
    session_id: :string,
    entry_kind: :string,
    body: :string,
    status: :string,
    idempotency_key: :string,
    payload_json: :string,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      :help ->
        Mix.shell().info(usage())

      {:ok, command, opts} ->
        run_command(command, opts)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @spec usage() :: String.t()
  def usage do
    [
      "Usage: mix sympp.solo <command> [options]",
      "  mix sympp.solo attach --repo <repo> --base-branch <branch> --workspace-path <abs-path> --caller-id <id> [--title <title>] [--database <sqlite-path>]",
      "  mix sympp.solo append --session-id <id> --entry-kind <kind> --title <title> [--body <text>] [--status <status>] [--idempotency-key <key>] [--payload-json <json-object>] [--database <sqlite-path>]",
      "  mix sympp.solo show --session-id <id> [--database <sqlite-path>]",
      "  mix sympp.solo list [--repo <repo>] [--base-branch <branch>] [--workspace-path <abs-path>] [--caller-id <id>] [--status <status>] [--database <sqlite-path>]",
      "  mix sympp.solo pause|resume|complete|archive --session-id <id> [--database <sqlite-path>]"
    ]
    |> Enum.join("\n")
  end

  @doc false
  @spec database_path_for_test(String.t() | nil) :: String.t()
  def database_path_for_test(database), do: resolved_database(database)

  @doc false
  @spec database_path_for_test(String.t() | nil, (-> String.t() | nil)) :: String.t()
  def database_path_for_test(database, mix_project_workflow_fun), do: resolved_database(database, mix_project_workflow_fun)

  @doc false
  @spec database_path_for_test(String.t() | nil, (-> String.t() | nil), boolean()) :: String.t() | nil
  def database_path_for_test(database, mix_project_workflow_fun, create_directories),
    do: resolved_database(database, mix_project_workflow_fun, create_directories)

  @doc false
  @spec parse_args_for_test([String.t()]) :: :help | {:ok, String.t(), keyword()} | {:error, String.t()}
  def parse_args_for_test(args), do: parse_args(args)

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        if Keyword.get(opts, :help, false), do: :help, else: {:error, usage()}

      {opts, [command], []} when command in @commands ->
        validate_opts(command, opts)

      {_opts, _argv, _invalid} ->
        {:error, usage()}
    end
  end

  defp validate_opts(command, opts) do
    cond do
      Keyword.get(opts, :help, false) ->
        :help

      has_blank_option?(opts, Keyword.keys(@switches) -- [:help]) ->
        {:error, usage()}

      true ->
        validate_command_opts(command, opts)
    end
  end

  defp validate_command_opts("attach", opts) do
    required = [:repo, :base_branch, :workspace_path, :caller_id]
    if missing_required?(opts, required), do: {:error, usage()}, else: {:ok, "attach", opts}
  end

  defp validate_command_opts("append", opts) do
    with :ok <- require_options(opts, [:session_id, :entry_kind, :title]),
         {:ok, opts} <- decode_payload_json(opts) do
      {:ok, "append", opts}
    else
      {:error, message} -> {:error, message}
    end
  end

  defp validate_command_opts("show", opts) do
    if missing_required?(opts, [:session_id]), do: {:error, usage()}, else: {:ok, "show", opts}
  end

  defp validate_command_opts("list", opts), do: {:ok, "list", opts}

  defp validate_command_opts(command, opts) when command in @lifecycle_commands do
    if missing_required?(opts, [:session_id]), do: {:error, usage()}, else: {:ok, command, opts}
  end

  defp run_command(command, opts) do
    original_repo = Repo.get_dynamic_repo()

    case start_repo(command, Keyword.get(opts, :database)) do
      {:ok, repo_pid} ->
        try do
          with :ok <- prepare_repository(command),
               {:ok, payload} <- execute(command, opts) do
            payload
            |> Jason.encode!(pretty: true)
            |> Mix.shell().info()
          else
            {:error, reason} -> Mix.raise(error_message(reason))
          end
        after
          stop_repo(repo_pid)
          Repo.put_dynamic_repo(original_repo)
        end

      {:error, reason} ->
        Repo.put_dynamic_repo(original_repo)
        Mix.raise(error_message(reason))
    end
  end

  defp execute("attach", opts) do
    attrs = %{
      repo: Keyword.fetch!(opts, :repo),
      base_branch: Keyword.fetch!(opts, :base_branch),
      workspace_path: Keyword.fetch!(opts, :workspace_path),
      caller_id: Keyword.fetch!(opts, :caller_id),
      title: Keyword.get(opts, :title)
    }

    with {:ok, session} <- Service.create_or_attach_current(Repo, attrs) do
      {:ok, %{"action" => "attach", "solo_session" => session_payload(session)}}
    end
  end

  defp execute("append", opts) do
    attrs =
      %{
        entry_kind: Keyword.fetch!(opts, :entry_kind),
        title: Keyword.fetch!(opts, :title),
        body: Keyword.get(opts, :body),
        status: Keyword.get(opts, :status),
        idempotency_key: Keyword.get(opts, :idempotency_key),
        payload: Keyword.get(opts, :payload_json, %{})
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    with {:ok, entry} <- Service.append_entry(Repo, Keyword.fetch!(opts, :session_id), attrs) do
      {:ok, %{"action" => "append", "entry" => entry_payload(entry)}}
    end
  end

  defp execute("show", opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    with {:ok, session} <- Service.get(Repo, session_id),
         {:ok, entries} <- Service.list_entries(Repo, session_id) do
      {:ok,
       %{
         "action" => "show",
         "solo_session" => session_payload(session),
         "entries" => Enum.map(entries, &entry_payload/1)
       }}
    end
  end

  defp execute("list", opts) do
    filters =
      opts
      |> Keyword.take([:repo, :base_branch, :workspace_path, :caller_id, :status])
      |> Map.new()

    with {:ok, sessions} <- Service.list(Repo, filters) do
      {:ok, %{"action" => "list", "solo_sessions" => Enum.map(sessions, &session_payload/1)}}
    end
  end

  defp execute(command, opts) when command in @lifecycle_commands do
    session_id = Keyword.fetch!(opts, :session_id)

    with {:ok, session} <- Service.get(Repo, session_id),
         {:ok, updated} <- Service.update_status(Repo, session_id, session.status, lifecycle_status(command)) do
      {:ok, %{"action" => command, "solo_session" => session_payload(updated)}}
    end
  end

  defp session_payload(%SoloSession{} = session) do
    %{
      "id" => session.id,
      "repo" => session.repo,
      "base_branch" => session.base_branch,
      "workspace_path" => session.workspace_path,
      "caller_id" => session.caller_id,
      "session_key" => session.session_key,
      "title" => session.title,
      "status" => session.status,
      "last_activity_at" => iso8601(session.last_activity_at),
      "archived_at" => iso8601(session.archived_at),
      "created_at" => iso8601(session.inserted_at),
      "updated_at" => iso8601(session.updated_at)
    }
  end

  defp entry_payload(%SoloSessionEntry{} = entry) do
    %{
      "id" => entry.id,
      "solo_session_id" => entry.solo_session_id,
      "entry_kind" => entry.entry_kind,
      "title" => entry.title,
      "body" => entry.body,
      "status" => entry.status,
      "sequence" => entry.sequence,
      "idempotency_key" => entry.idempotency_key,
      "payload" => entry.payload || %{},
      "created_at" => iso8601(entry.created_at),
      "updated_at" => iso8601(entry.updated_at)
    }
  end

  defp lifecycle_status("pause"), do: "paused"
  defp lifecycle_status("resume"), do: "active"
  defp lifecycle_status("complete"), do: "completed"
  defp lifecycle_status("archive"), do: "archived"

  defp decode_payload_json(opts) do
    case Keyword.fetch(opts, :payload_json) do
      {:ok, value} ->
        case Jason.decode(value) do
          {:ok, payload} when is_map(payload) -> {:ok, Keyword.put(opts, :payload_json, payload)}
          {:ok, _payload} -> {:error, "--payload-json must decode to a JSON object."}
          {:error, _error} -> {:error, "--payload-json must be valid JSON."}
        end

      :error ->
        {:ok, opts}
    end
  end

  defp require_options(opts, keys) do
    if missing_required?(opts, keys), do: {:error, usage()}, else: :ok
  end

  defp start_repo(command, database) do
    with :ok <- ensure_repo_dependencies_started() do
      database = resolved_database(database, &mix_project_workflow/0, command == "attach")
      ensure_existing_database!(command, database)

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

  defp resolved_database(database, mix_project_workflow_fun \\ &mix_project_workflow/0, create_directories \\ true)

  defp resolved_database(nil, mix_project_workflow_fun, create_directories) do
    original_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    try do
      workflow_path = set_mix_project_workflow!(mix_project_workflow_fun)
      Application.delete_env(:symphony_elixir, :sympp_repo_database)

      default_database_path(create_directories, workflow_path)
      |> reject_unsupported_database!()
      |> maybe_create_database_parent_directories(create_directories)
    after
      restore_sympp_repo_database(original_database)
      restore_workflow(original_workflow)
    end
  end

  defp resolved_database(database, _mix_project_workflow_fun, create_directories) when is_binary(database) do
    cond do
      sqlite_file_uri?(database) ->
        Mix.raise(@sqlite_file_uri_error_message)

      Repo.memory_database?(database) ->
        Mix.raise(@durable_database_error_message)

      unsupported_database_target?(database) ->
        Mix.raise(@unsupported_database_error_message)

      Repo.filesystem_database_path?(database) ->
        database = Path.expand(database)
        maybe_create_database_parent_directories(database, create_directories)
        database

      true ->
        database
    end
  end

  defp sqlite_file_uri?(database) when is_binary(database), do: String.starts_with?(String.downcase(database), "file:")
  defp sqlite_file_uri?(_database), do: false

  defp default_database_path(true, workflow_path) do
    case configured_repo_database() do
      database when is_binary(database) and database != "" ->
        resolve_configured_database(database, workflow_path, true)

      _database ->
        Repo.database_path()
    end
  end

  defp default_database_path(false, workflow_path) do
    case configured_repo_database() do
      database when is_binary(database) and database != "" ->
        resolve_configured_database(database, workflow_path, false)

      database ->
        default_database_path_without_side_effects(database)
    end
  end

  defp default_database_path_without_side_effects(database) when is_binary(database) do
    if String.trim(database) == "" do
      Repo.database_path_if_present()
    else
      resolved_database(database, fn -> nil end, false)
    end
  end

  defp default_database_path_without_side_effects(nil), do: Repo.database_path_if_present()
  defp default_database_path_without_side_effects(database), do: database

  defp configured_repo_database do
    case Application.get_env(:symphony_elixir, Repo, []) do
      config when is_list(config) -> Keyword.get(config, :database)
      _config -> nil
    end
  end

  defp resolve_configured_database(database, workflow_path, create_directories) do
    database
    |> resolve_workflow_relative_database(workflow_path)
    |> resolved_database(fn -> nil end, create_directories)
  end

  defp resolve_workflow_relative_database(database, workflow_path) when is_binary(database) do
    cond do
      sqlite_file_uri?(database) ->
        database

      Repo.memory_database?(database) ->
        database

      Path.type(database) == :relative ->
        workflow_path
        |> Path.dirname()
        |> Path.join(database)

      true ->
        database
    end
  end

  defp reject_unsupported_database!(database) do
    cond do
      sqlite_file_uri?(database) ->
        Mix.raise(@sqlite_file_uri_error_message)

      Repo.memory_database?(database) ->
        Mix.raise(@durable_database_error_message)

      unsupported_database_target?(database) ->
        Mix.raise(@unsupported_database_error_message)

      true ->
        database
    end
  end

  defp unsupported_database_target?(database) when is_binary(database) do
    scheme_like_database?(database) and not windows_absolute_path?(database)
  end

  defp unsupported_database_target?(_database), do: false

  defp scheme_like_database?(database), do: Regex.match?(~r/^[A-Za-z][A-Za-z0-9+.-]*:/, database)

  defp windows_absolute_path?(<<drive, ?:, separator, _rest::binary>>)
       when (drive in ?A..?Z or drive in ?a..?z) and separator in [?/, ?\\],
       do: true

  defp windows_absolute_path?(_database), do: false

  defp ensure_existing_database!(command, database) when command in @existing_database_commands do
    if local_database_exists?(database) == false do
      Mix.raise("mix sympp.solo #{command} requires an existing Solo Session database; run attach first or pass the correct --database path.")
    end

    :ok
  end

  defp ensure_existing_database!(_command, _database), do: :ok

  defp prepare_repository("attach"), do: Repository.migrate(Repo)

  defp prepare_repository(_command) do
    with :ok <- ensure_solo_ledger!() do
      Repository.migrate(Repo)
    end
  end

  defp ensure_solo_ledger! do
    repo = Repo.get_dynamic_repo()

    case SQL.query(repo, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", ["sympp_solo_sessions"]) do
      {:ok, %{rows: [_ | _]}} ->
        :ok

      {:ok, %{rows: []}} ->
        {:error, :missing_solo_ledger}

      {:error, reason} ->
        {:error, {:solo_ledger_check_failed, reason}}
    end
  end

  defp local_database_exists?(nil), do: false

  defp local_database_exists?(database) do
    if Repo.filesystem_database_path?(database), do: File.exists?(database), else: :unknown
  end

  defp maybe_create_database_parent_directories(database, true) when is_binary(database) do
    if Repo.filesystem_database_path?(database) do
      File.mkdir_p!(Path.dirname(database))
    end

    database
  end

  defp maybe_create_database_parent_directories(database, _create_directories), do: database

  defp set_mix_project_workflow!(mix_project_workflow_fun) do
    case mix_project_workflow_fun.() do
      path when is_binary(path) ->
        Workflow.set_workflow_file_path(path)
        path

      nil ->
        Mix.raise("mix sympp.solo requires --database or a WORKFLOW.md file in the Mix project root.")
    end
  end

  defp restore_workflow(nil), do: Workflow.clear_workflow_file_path()
  defp restore_workflow(path) when is_binary(path), do: Workflow.set_workflow_file_path(path)

  defp restore_sympp_repo_database(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_database)
  defp restore_sympp_repo_database(database), do: Application.put_env(:symphony_elixir, :sympp_repo_database, database)

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

  defp error_message(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
    |> then(&("Solo Session validation failed: " <> &1))
  end

  defp error_message(:not_found), do: "Solo Session record was not found."

  defp error_message(:missing_solo_ledger),
    do: "mix sympp.solo requires an existing Solo Session database; run attach first or pass the correct --database path."

  defp error_message(:invalid_workspace_path), do: "Solo Session workspace_path must be an absolute path."
  defp error_message(:invalid_transition), do: "Solo Session lifecycle transition is invalid."
  defp error_message(:invalid_status), do: "Solo Session status is invalid."
  defp error_message(:session_not_mutable), do: "Solo Session does not accept new entries in its current status."
  defp error_message(:invalid_entry_idempotency_key), do: "Solo Session entry idempotency key is invalid or secret-like."
  defp error_message(:invalid_stale_after_days), do: "Solo Session stale-after-days value is invalid."
  defp error_message({:repo_start_failed, reason}), do: "Failed to start Symphony++ repository: #{inspect(reason)}"
  defp error_message({:ecto_start_failed, reason}), do: "Failed to start Ecto SQL: #{inspect(reason)}"
  defp error_message({:solo_ledger_check_failed, reason}), do: "Failed to inspect Solo Session database: #{inspect(reason)}"
  defp error_message(reason), do: "Solo Session command failed: #{inspect(reason)}"

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp missing_required?(opts, keys), do: Enum.any?(keys, &blank?(Keyword.get(opts, &1)))

  defp has_blank_option?(opts, keys) do
    Enum.any?(keys, &(Keyword.has_key?(opts, &1) and blank?(Keyword.get(opts, &1))))
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
