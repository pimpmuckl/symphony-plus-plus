defmodule SymphonyElixir.SymphonyPlusPlus.SecretHandoff do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @default_env_var "SYMPP_WORK_KEY_SECRET"
  @metadata_version 1
  @metadata_lock_stale_seconds 300
  @valid_modes ["auto", "windows-credential-manager", "local-private-file"]

  @type error ::
          :missing_secret
          | :missing_claimed_by
          | :missing_repo_root
          | :missing_worker_grant_display_key
          | :missing_worker_grant_identity
          | :missing_worker_grant
          | :missing_work_package
          | :unsupported_handoff_metadata_location
          | :unsupported_secret_handoff_mode
          | :handoff_metadata_conflict
          | {:handoff_metadata_invalid, term()}
          | {:handoff_metadata_read_failed, term()}
          | {:handoff_metadata_write_failed, term()}
          | :local_private_file_unavailable_on_windows
          | :windows_credential_manager_unavailable
          | {:local_private_file_failed, term()}
          | {:local_private_file_delete_failed, term()}
          | {:windows_credential_manager_delete_failed, term()}
          | {:windows_credential_manager_failed, integer()}

  @spec valid_modes() :: [String.t()]
  def valid_modes, do: @valid_modes

  @spec store_worker_secret(map(), keyword()) :: {:ok, map()} | {:error, error()}
  def store_worker_secret(%{work_package: %WorkPackage{} = work_package, worker_grant: worker_grant}, opts)
      when is_map(worker_grant) and is_list(opts) do
    with {:ok, secret} <- fetch_secret(worker_grant),
         {:ok, _identity} <- fetch_grant_identity(worker_grant),
         {:ok, mode} <- normalize_mode(Keyword.get(opts, :mode, "auto")),
         {:ok, opts} <- require_handoff_opts(opts) do
      store_secret(mode, secret, work_package, worker_grant, opts)
    end
  end

  def store_worker_secret(%{work_package: %WorkPackage{}}, _opts), do: {:error, :missing_worker_grant}
  def store_worker_secret(%{}, _opts), do: {:error, :missing_work_package}

  @spec store_worker_secret_metadata(WorkPackage.t(), map(), map(), keyword()) :: :ok | {:error, error()}
  def store_worker_secret_metadata(%WorkPackage{} = work_package, worker_grant, handoff, opts)
      when is_map(worker_grant) and is_map(handoff) and is_list(opts) do
    with {:ok, opts} <- require_handoff_opts(opts),
         :ok <- reject_metadata_location_overrides(opts),
         {:ok, context} <- handoff_metadata_context(work_package, worker_grant, opts),
         {:ok, metadata} <- handoff_metadata_record(context, handoff),
         {:ok, encoded} <- encode_handoff_metadata(metadata) do
      write_handoff_metadata(context.metadata_path, encoded, opts)
    end
  end

  def store_worker_secret_metadata(%WorkPackage{}, worker_grant, _handoff, _opts) when not is_map(worker_grant),
    do: {:error, :missing_worker_grant}

  def store_worker_secret_metadata(%WorkPackage{}, _worker_grant, _handoff, _opts),
    do: {:error, {:handoff_metadata_invalid, :missing_handoff}}

  def store_worker_secret_metadata(%{}, _worker_grant, _handoff, _opts), do: {:error, :missing_work_package}

  @spec redacted_worker_grant(map(), map()) :: map()
  def redacted_worker_grant(worker_grant, handoff) when is_map(worker_grant) and is_map(handoff) do
    worker_grant
    |> Map.delete(:secret)
    |> Map.delete("secret")
    |> Map.put(:secret_handoff, handoff)
  end

  @spec delete_worker_secret(map(), keyword()) :: :ok | {:error, term()}
  def delete_worker_secret(handoff, opts \\ []) when is_map(handoff) and is_list(opts) do
    case handoff_value(handoff, :mode) do
      "local-private-file" -> delete_local_private_file(handoff)
      "windows-credential-manager" -> delete_windows_credential(handoff, opts)
      _mode -> :ok
    end
  end

  @spec error_message(error()) :: String.t()
  def error_message(:missing_secret), do: "worker grant did not include a one-time secret"
  def error_message(:missing_claimed_by), do: "secret handoff requires a nonblank claimed_by worker identity"
  def error_message(:missing_repo_root), do: "secret handoff requires the repository root for MCP bootstrap metadata"
  def error_message(:missing_worker_grant_display_key), do: "worker grant did not include a nonblank display key"
  def error_message(:missing_worker_grant_identity), do: "worker grant did not include a stable non-secret id"
  def error_message(:missing_worker_grant), do: "create-work result did not include a worker grant"
  def error_message(:missing_work_package), do: "create-work result did not include a work package"
  def error_message(:unsupported_handoff_metadata_location), do: "secret handoff metadata must use the managed metadata location"
  def error_message(:unsupported_secret_handoff_mode), do: "secret handoff mode must be one of: #{Enum.join(@valid_modes, ", ")}"
  def error_message(:handoff_metadata_conflict), do: "secret handoff metadata already exists with different coordinates"

  def error_message(:local_private_file_unavailable_on_windows),
    do: "local-private-file handoff is only available on non-Windows hosts; use windows-credential-manager on Windows"

  def error_message(:windows_credential_manager_unavailable),
    do: "Windows Credential Manager handoff requires powershell.exe or pwsh"

  def error_message({:local_private_file_failed, reason}),
    do: "local private file handoff failed: #{inspect(reason)}"

  def error_message({:local_private_file_delete_failed, reason}),
    do: "local private file handoff cleanup failed: #{inspect(reason)}"

  def error_message({:windows_credential_manager_delete_failed, reason}),
    do: "Windows Credential Manager handoff cleanup failed: #{inspect(reason)}"

  def error_message({:windows_credential_manager_failed, status}),
    do: "Windows Credential Manager handoff command failed with exit status #{status}"

  def error_message({:handoff_metadata_invalid, reason}),
    do: "secret handoff metadata is invalid: #{inspect(reason)}"

  def error_message({:handoff_metadata_read_failed, reason}),
    do: "secret handoff metadata read failed: #{inspect(reason)}"

  def error_message({:handoff_metadata_write_failed, reason}),
    do: "secret handoff metadata write failed: #{inspect(reason)}"

  defp fetch_secret(%{secret: secret}) when is_binary(secret) and secret != "", do: {:ok, secret}
  defp fetch_secret(%{"secret" => secret}) when is_binary(secret) and secret != "", do: {:ok, secret}
  defp fetch_secret(_worker_grant), do: {:error, :missing_secret}

  defp fetch_grant_identity(worker_grant) do
    case handoff_value(worker_grant, :id) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_worker_grant_identity}, else: {:ok, value}

      _value ->
        {:error, :missing_worker_grant_identity}
    end
  end

  defp fetch_grant_display_key(worker_grant) do
    case handoff_value(worker_grant, :display_key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, :missing_worker_grant_display_key}, else: {:ok, value}

      _value ->
        {:error, :missing_worker_grant_display_key}
    end
  end

  defp grant_identity!(worker_grant) do
    {:ok, identity} = fetch_grant_identity(worker_grant)
    identity
  end

  defp grant_display_key!(worker_grant) do
    case handoff_value(worker_grant, :display_key) do
      value when is_binary(value) -> value
    end
  end

  defp normalize_mode(mode) when is_binary(mode) do
    case String.downcase(String.trim(mode)) do
      "auto" -> {:ok, auto_mode()}
      "windows-credential-manager" -> {:ok, :windows_credential_manager}
      "local-private-file" -> {:ok, :local_private_file}
      _mode -> {:error, :unsupported_secret_handoff_mode}
    end
  end

  defp normalize_mode(_mode), do: {:error, :unsupported_secret_handoff_mode}

  defp require_handoff_opts(opts) do
    with {:ok, claimed_by} <- nonblank_opt(opts, :claimed_by, :missing_claimed_by),
         {:ok, repo_root} <- nonblank_opt(opts, :repo_root, :missing_repo_root) do
      {:ok, Keyword.merge(opts, claimed_by: claimed_by, repo_root: Path.expand(repo_root))}
    end
  end

  defp nonblank_opt(opts, key, error) do
    case Keyword.get(opts, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, error}, else: {:ok, value}

      _value ->
        {:error, error}
    end
  end

  defp auto_mode do
    if windows?(), do: :windows_credential_manager, else: :local_private_file
  end

  defp store_secret(:windows_credential_manager, secret, work_package, worker_grant, opts) do
    target = credential_target(work_package, worker_grant)
    repo_root = Keyword.fetch!(opts, :repo_root)
    script_path = Path.join(repo_root, "scripts/sympp-worker-secret.ps1")

    case powershell_executable() do
      {:ok, powershell} ->
        powershell
        |> run_windows_credential_store(script_path, target, worker_grant_user(worker_grant), secret)
        |> case do
          :ok ->
            {:ok,
             base_handoff(:windows_credential_manager, target, work_package, worker_grant, opts)
             |> Map.put(:target, target)
             |> Map.put(:store, "Windows Credential Manager")
             |> Map.put(:run_mcp_command, windows_credential_run_mcp_command(powershell, script_path, target, opts))}

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:error, :windows_credential_manager_unavailable}
    end
  end

  defp store_secret(:local_private_file, secret, work_package, worker_grant, opts) do
    if windows?() do
      {:error, :local_private_file_unavailable_on_windows}
    else
      store_local_private_file(secret, work_package, worker_grant, opts)
    end
  end

  defp store_local_private_file(secret, work_package, worker_grant, opts) do
    path = local_private_file_path(work_package, worker_grant, opts)

    with {:ok, run_mcp_command} <- local_file_run_mcp_command(path, opts) do
      try do
        directory = Path.dirname(path)

        File.mkdir_p!(directory)

        case prepare_private_store_dir(directory, opts) do
          :ok ->
            case write_private_file(path, secret, opts) do
              :ok ->
                handoff =
                  base_handoff(
                    :local_private_file,
                    credential_target(work_package, worker_grant),
                    work_package,
                    worker_grant,
                    opts
                  )

                {:ok,
                 handoff
                 |> Map.put(:path, path)
                 |> Map.put(:store, "user-local private file")
                 |> Map.put(:run_mcp_command, run_mcp_command)
                 |> Map.put(
                   :tradeoff,
                   "File ACL strength depends on the local OS/user profile. Prefer Windows Credential Manager on Windows."
                 )}

              {:error, reason} ->
                {:error, {:local_private_file_failed, reason}}
            end

          {:error, reason} ->
            {:error, {:local_private_file_failed, reason}}
        end
      rescue
        error ->
          {:error, {:local_private_file_failed, error.__struct__}}
      end
    end
  end

  defp run_windows_credential_store(powershell, script_path, target, user_name, secret) do
    case System.cmd(
           powershell,
           [
             "-NoProfile",
             "-ExecutionPolicy",
             "Bypass",
             "-File",
             script_path,
             "store",
             "-Target",
             target,
             "-UserName",
             user_name
           ],
           env: [{@default_env_var, secret}],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {_output, status} when is_integer(status) ->
        {:error, {:windows_credential_manager_failed, status}}
    end
  end

  defp base_handoff(mode, target, %WorkPackage{} = work_package, worker_grant, opts) do
    %{
      mode: mode_name(mode),
      status: "stored",
      work_package_id: work_package.id,
      display_key: grant_display_key!(worker_grant),
      target: target,
      env_var: Keyword.get(opts, :env_var, @default_env_var),
      claimed_by: Keyword.fetch!(opts, :claimed_by),
      claimed_by_required: true,
      secret_in_stdout: false
    }
  end

  defp mode_name(:windows_credential_manager), do: "windows-credential-manager"
  defp mode_name(:local_private_file), do: "local-private-file"

  defp credential_target(%WorkPackage{id: work_package_id}, worker_grant) do
    "SymphonyPlusPlus:worker:#{work_package_id}:#{grant_display_key!(worker_grant)}:#{grant_identity!(worker_grant)}"
  end

  defp worker_grant_user(worker_grant), do: "sympp-worker-#{grant_display_key!(worker_grant)}"

  defp windows_credential_run_mcp_command(powershell, script_path, target, opts) do
    claimed_by = Keyword.fetch!(opts, :claimed_by)

    [
      ~s(& #{powershell_literal(powershell)} -NoProfile -ExecutionPolicy Bypass -File #{powershell_literal(script_path)} run-mcp),
      ~s(-Target #{powershell_literal(target)}),
      maybe_powershell_arg("-Database", Keyword.get(opts, :database)),
      ~s(-ClaimedBy #{powershell_literal(claimed_by)})
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp local_file_run_mcp_command(secret_path, opts) do
    {:ok, shell_local_file_run_mcp_command(secret_path, opts)}
  end

  defp shell_local_file_run_mcp_command(secret_path, opts) do
    repo_root = Keyword.fetch!(opts, :repo_root)
    script_path = Path.join(repo_root, "scripts/sympp-worker-secret.sh")
    claimed_by = Keyword.fetch!(opts, :claimed_by)

    [
      ~s(sh #{shell_literal(script_path)} run-mcp-local-file),
      ~s(--path #{shell_literal(secret_path)}),
      maybe_shell_arg("--database", Keyword.get(opts, :database)),
      ~s(--claimed-by #{shell_literal(claimed_by)})
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp maybe_powershell_arg(_flag, nil), do: nil
  defp maybe_powershell_arg(flag, value), do: "#{flag} #{powershell_literal(value)}"

  defp maybe_shell_arg(_flag, nil), do: nil
  defp maybe_shell_arg(flag, value), do: "#{flag} #{shell_literal(value)}"

  defp powershell_literal(value) do
    "'#{String.replace(to_string(value), "'", "''")}'"
  end

  defp shell_literal(value) do
    "'#{String.replace(to_string(value), "'", "'\"'\"'")}'"
  end

  defp prepare_private_store_dir(directory, opts) do
    if windows?(), do: :ok, else: chmod_private_path(directory, 0o700, opts)
  end

  defp chmod_private_file(path, opts) do
    chmod_private_path(path, 0o600, opts)
  end

  defp write_private_file(path, secret, opts) do
    temp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    try do
      case write_private_temp_secret_file(temp_path, secret, opts) do
        :ok ->
          publish_private_file(temp_path, path, opts)

        {:error, reason} ->
          {:error, reason}
      end
    after
      File.rm(temp_path)
    end
  end

  defp write_private_temp_secret_file(path, secret, opts) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        try do
          case chmod_private_file(path, opts) do
            :ok -> write_temp_secret_file(file, secret)
            {:error, _reason} = error -> error
          end
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, {:write, reason}}
    end
  end

  defp write_temp_secret_file(file, secret) do
    case :file.write(file, secret) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write, reason}}
    end
  end

  defp publish_private_file(temp_path, path, opts) do
    case rename_private_file(temp_path, path, opts) do
      :ok -> :ok
      {:error, reason} -> replace_existing_private_file(temp_path, path, opts, reason)
    end
  end

  defp rename_private_file(temp_path, path, opts) do
    rename_fun = Keyword.get(opts, :private_file_rename_fun, &File.rename/2)

    case rename_fun.(temp_path, path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rename, reason}}
    end
  end

  defp replace_existing_private_file(temp_path, path, opts, rename_reason) do
    if windows?() and File.exists?(path) do
      replace_fun = Keyword.get(opts, :private_file_replace_fun, &windows_replace_existing_private_file/2)

      case replace_fun.(temp_path, path) do
        :ok -> :ok
        {:error, reason} -> {:error, {:replace_existing, reason}}
      end
    else
      {:error, rename_reason}
    end
  end

  defp windows_replace_existing_private_file(temp_path, path) do
    case powershell_executable() do
      {:ok, powershell} ->
        command =
          "$ErrorActionPreference = 'Stop'; " <>
            "[System.IO.File]::Replace($env:SYMPP_PRIVATE_FILE_SOURCE, " <>
            "$env:SYMPP_PRIVATE_FILE_DESTINATION, [NullString]::Value, $true)"

        case System.cmd(
               powershell,
               ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
               env: [{"SYMPP_PRIVATE_FILE_SOURCE", temp_path}, {"SYMPP_PRIVATE_FILE_DESTINATION", path}],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {_output, status} -> {:error, {:exit_status, status}}
        end

      :error ->
        {:error, :powershell_unavailable}
    end
  end

  defp chmod_private_path(path, mode, opts) do
    chmod_fun = Keyword.get(opts, :chmod_fun, &File.chmod/2)

    case chmod_fun.(path, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, {:chmod, reason}}
      other -> {:error, {:unexpected_chmod_result, other}}
    end
  end

  defp local_private_file_path(%WorkPackage{} = work_package, worker_grant, opts) do
    store_dir = Keyword.get(opts, :store_dir) || default_local_private_store_dir()
    display_key = grant_display_key!(worker_grant)
    grant_identity = grant_identity!(worker_grant)

    filename =
      "#{safe_filename(work_package.id)}-#{safe_filename(display_key)}-#{safe_filename(grant_identity)}-#{handoff_filename_hash(work_package, display_key, grant_identity, opts)}.secret"

    Path.join(Path.expand(store_dir), filename)
  end

  defp handoff_filename_hash(%WorkPackage{} = work_package, display_key, grant_identity, opts) do
    hash_source = [
      to_string(Keyword.get(opts, :repo_root, "")),
      0,
      to_string(Keyword.get(opts, :database, "")),
      0,
      work_package.id,
      0,
      display_key,
      0,
      grant_identity
    ]

    :sha256
    |> :crypto.hash(hash_source)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  defp handoff_metadata_context(%WorkPackage{} = work_package, worker_grant, opts) do
    with {:ok, display_key} <- fetch_grant_display_key(worker_grant),
         {:ok, grant_identity} <- fetch_grant_identity(worker_grant) do
      metadata_path = handoff_metadata_path(work_package.id, display_key, grant_identity, opts)
      expected_local_path = local_private_file_path(work_package, %{display_key: display_key, id: grant_identity}, opts)

      {:ok,
       %{
         work_package: work_package,
         work_package_id: work_package.id,
         display_key: display_key,
         grant_identity: grant_identity,
         metadata_path: metadata_path,
         expected_local_private_file_path: expected_local_path
       }}
    end
  end

  defp reject_metadata_location_overrides(opts) do
    if Keyword.has_key?(opts, :metadata_dir) or Keyword.has_key?(opts, :metadata_path),
      do: {:error, :unsupported_handoff_metadata_location},
      else: :ok
  end

  defp handoff_metadata_path(work_package_id, display_key, grant_identity, opts) do
    store_dir = local_private_store_dir(opts)
    filename = "handoff-#{handoff_metadata_hash(work_package_id, display_key, grant_identity, store_dir, opts)}.json"

    Path.join([store_dir, "metadata", filename])
  end

  defp handoff_metadata_hash(work_package_id, display_key, grant_identity, store_dir, opts) do
    hash_source = [
      "v1",
      0,
      opts |> Keyword.fetch!(:repo_root) |> Path.expand(),
      0,
      to_string(Keyword.get(opts, :database, "")),
      0,
      store_dir,
      0,
      work_package_id,
      0,
      display_key,
      0,
      grant_identity
    ]

    :sha256
    |> :crypto.hash(hash_source)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 32)
  end

  defp handoff_metadata_record(context, handoff) do
    with {:ok, mode} <- handoff_metadata_mode(handoff),
         {:ok, coordinates} <- handoff_metadata_coordinates(mode, context, handoff) do
      metadata =
        %{
          "version" => @metadata_version,
          "work_package_id" => context.work_package_id,
          "worker_grant_display_key" => context.display_key,
          "worker_grant_id" => context.grant_identity,
          "mode" => mode
        }
        |> Map.merge(coordinates)

      {:ok, metadata}
    end
  end

  defp handoff_metadata_mode(handoff) do
    case handoff_value(handoff, :mode) do
      mode when mode in ["local-private-file", "windows-credential-manager"] -> {:ok, mode}
      mode when is_binary(mode) -> {:error, {:handoff_metadata_invalid, {:unsupported_mode, mode}}}
      _mode -> {:error, {:handoff_metadata_invalid, :missing_mode}}
    end
  end

  defp handoff_metadata_coordinates("local-private-file", context, handoff) do
    case handoff_value(handoff, :path) do
      path when is_binary(path) -> validate_handoff_metadata_local_path(path, context)
      _path -> {:error, {:handoff_metadata_invalid, :missing_local_path}}
    end
  end

  defp handoff_metadata_coordinates("windows-credential-manager", context, handoff) do
    expected_target =
      credential_target(context.work_package, %{display_key: context.display_key, id: context.grant_identity})

    case handoff_value(handoff, :target) do
      ^expected_target -> {:ok, %{"target" => expected_target}}
      target when is_binary(target) -> {:error, {:handoff_metadata_invalid, :credential_target_mismatch}}
      _target -> {:error, {:handoff_metadata_invalid, :missing_credential_target}}
    end
  end

  defp validate_handoff_metadata_local_path(path, context) do
    expanded_path = Path.expand(path)

    cond do
      String.trim(path) == "" ->
        {:error, {:handoff_metadata_invalid, :missing_local_path}}

      expanded_path != context.expected_local_private_file_path ->
        {:error, {:handoff_metadata_invalid, :local_path_mismatch}}

      File.regular?(expanded_path) ->
        {:ok, %{"path" => expanded_path}}

      true ->
        {:error, {:handoff_metadata_invalid, :missing_local_file}}
    end
  end

  defp encode_handoff_metadata(metadata) do
    case Jason.encode(metadata) do
      {:ok, encoded} -> {:ok, encoded <> "\n"}
      {:error, reason} -> {:error, {:handoff_metadata_write_failed, {:encode, reason}}}
    end
  end

  defp write_handoff_metadata(path, encoded, opts) do
    directory = Path.dirname(path)

    with :ok <- File.mkdir_p(directory),
         :ok <- prepare_private_store_dir(directory, opts),
         :ok <- with_handoff_metadata_lock(path, opts, fn -> write_handoff_metadata_file(path, encoded, opts) end) do
      :ok
    else
      {:error, :handoff_metadata_conflict} -> {:error, :handoff_metadata_conflict}
      {:error, {:handoff_metadata_write_failed, _reason} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:handoff_metadata_write_failed, reason}}
    end
  rescue
    error -> {:error, {:handoff_metadata_write_failed, error.__struct__}}
  end

  defp with_handoff_metadata_lock(path, opts, fun) do
    lock_path = "#{path}.lock"

    with {:ok, lock_file} <- acquire_handoff_metadata_lock(lock_path, opts) do
      try do
        fun.()
      after
        File.close(lock_file)
        File.rm(lock_path)
      end
    end
  end

  defp acquire_handoff_metadata_lock(path, opts) do
    attempts = Keyword.get(opts, :metadata_lock_attempts, 100)
    sleep_ms = Keyword.get(opts, :metadata_lock_sleep_ms, 5)
    stale_seconds = metadata_lock_stale_seconds(opts)

    do_acquire_handoff_metadata_lock(path, attempts, sleep_ms, stale_seconds)
  end

  defp metadata_lock_stale_seconds(opts) do
    case Keyword.get(opts, :metadata_lock_stale_seconds, @metadata_lock_stale_seconds) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds
      _other -> @metadata_lock_stale_seconds
    end
  end

  defp do_acquire_handoff_metadata_lock(_path, 0, _sleep_ms, _stale_seconds),
    do: {:error, {:handoff_metadata_write_failed, {:lock, :timeout}}}

  defp do_acquire_handoff_metadata_lock(path, attempts, sleep_ms, stale_seconds) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        {:ok, file}

      {:error, :eexist} ->
        maybe_remove_stale_handoff_metadata_lock(path, stale_seconds)
        Process.sleep(sleep_ms)
        do_acquire_handoff_metadata_lock(path, attempts - 1, sleep_ms, stale_seconds)

      {:error, reason} ->
        {:error, {:handoff_metadata_write_failed, {:lock, reason}}}
    end
  end

  defp maybe_remove_stale_handoff_metadata_lock(path, stale_seconds) do
    if handoff_metadata_lock_stale?(path, stale_seconds), do: File.rm(path), else: :ok
  end

  defp handoff_metadata_lock_stale?(path, stale_seconds) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} when is_integer(mtime) ->
        System.os_time(:second) - mtime >= stale_seconds

      _other ->
        false
    end
  end

  defp write_handoff_metadata_file(path, encoded, opts) do
    case existing_handoff_metadata(path, encoded) do
      :missing -> write_new_handoff_metadata_file(path, encoded, opts)
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp write_new_handoff_metadata_file(path, encoded, opts) do
    temp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    try do
      with :ok <- write_handoff_metadata_temp_file(temp_path, encoded, opts) do
        publish_handoff_metadata_file(temp_path, path, encoded, opts)
      end
    after
      File.rm(temp_path)
    end
  end

  defp write_handoff_metadata_temp_file(path, encoded, opts) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        try do
          with :ok <- maybe_chmod_private_file(path, opts) do
            write_temp_secret_file(file, encoded)
          end
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, {:write, reason}}
    end
  end

  defp maybe_chmod_private_file(path, opts) do
    if windows?(), do: :ok, else: chmod_private_file(path, opts)
  end

  defp publish_handoff_metadata_file(temp_path, path, encoded, opts) do
    rename_fun = Keyword.get(opts, :metadata_rename_fun, &File.rename/2)

    case rename_fun.(temp_path, path) do
      :ok -> :ok
      {:error, :eexist} -> existing_handoff_metadata(path, encoded)
      {:error, reason} -> {:error, {:handoff_metadata_write_failed, {:rename, reason}}}
    end
  end

  defp existing_handoff_metadata(path, encoded) do
    case File.read(path) do
      {:ok, existing} ->
        compare_handoff_metadata(existing, encoded)

      {:error, reason} ->
        if reason == :enoent,
          do: :missing,
          else: {:error, {:handoff_metadata_write_failed, {:existing_metadata_unreadable, reason}}}
    end
  end

  defp compare_handoff_metadata(existing, encoded) do
    with {:ok, existing_metadata} <- decode_handoff_metadata(existing),
         {:ok, new_metadata} <- decode_handoff_metadata(encoded) do
      if existing_metadata == new_metadata, do: :ok, else: {:error, :handoff_metadata_conflict}
    else
      {:error, {:handoff_metadata_read_failed, _reason} = reason} ->
        {:error, {:handoff_metadata_write_failed, {:existing_metadata_invalid, reason}}}
    end
  end

  defp decode_handoff_metadata(content) do
    case Jason.decode(content) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      {:ok, _metadata} -> {:error, {:handoff_metadata_read_failed, :not_a_map}}
      {:error, _reason} -> {:error, {:handoff_metadata_read_failed, :invalid_json}}
    end
  end

  defp delete_local_private_file(handoff) do
    case handoff_value(handoff, :path) do
      path when is_binary(path) ->
        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, {:local_private_file_delete_failed, reason}}
        end

      _path ->
        :ok
    end
  end

  defp delete_windows_credential(handoff, opts) do
    with target when is_binary(target) <- handoff_value(handoff, :target),
         {:ok, repo_root} <-
           nonblank_opt(opts, :repo_root, {:windows_credential_manager_delete_failed, :missing_repo_root}),
         {:ok, powershell} <- powershell_executable_for_delete() do
      script_path = Path.join(repo_root, "scripts/sympp-worker-secret.ps1")

      case System.cmd(
             powershell,
             ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path, "remove", "-Target", target],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {_output, status} -> {:error, {:windows_credential_manager_delete_failed, {:exit_status, status}}}
      end
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
      _target -> :ok
    end
  end

  defp powershell_executable_for_delete do
    case powershell_executable() do
      {:ok, powershell} -> {:ok, powershell}
      :error -> {:error, {:windows_credential_manager_delete_failed, :powershell_unavailable}}
    end
  end

  defp handoff_value(handoff, key) do
    Map.get(handoff, key) || Map.get(handoff, Atom.to_string(key))
  end

  defp default_local_private_store_dir do
    if windows?() do
      local_app_data = System.get_env("LOCALAPPDATA") || Path.join(System.user_home!(), "AppData/Local")
      Path.join([local_app_data, "SymphonyPlusPlus", "worker-secrets"])
    else
      Path.join([System.user_home!(), ".local", "share", "symphony-plus-plus", "worker-secrets"])
    end
  end

  defp local_private_store_dir(opts) do
    store_dir = Keyword.get(opts, :store_dir) || default_local_private_store_dir()
    Path.expand(store_dir)
  end

  defp safe_filename(value) when is_binary(value) do
    Regex.replace(~r/[^A-Za-z0-9._-]+/, value, "_")
  end

  defp powershell_executable do
    cond do
      executable = System.find_executable("powershell.exe") -> {:ok, executable}
      executable = System.find_executable("powershell") -> {:ok, executable}
      executable = System.find_executable("pwsh") -> {:ok, executable}
      true -> :error
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())
end
