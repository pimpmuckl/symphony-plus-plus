defmodule SymphonyElixir.SymphonyPlusPlus.SecretHandoff do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @default_env_var "SYMPP_WORK_KEY_SECRET"
  @valid_modes ["auto", "windows-credential-manager", "local-private-file"]

  @type error ::
          :missing_secret
          | :missing_claimed_by
          | :missing_repo_root
          | :missing_worker_grant_identity
          | :missing_worker_grant
          | :missing_work_package
          | :unsupported_secret_handoff_mode
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
  def error_message(:missing_worker_grant_identity), do: "worker grant did not include a stable non-secret id"
  def error_message(:missing_worker_grant), do: "create-work result did not include a worker grant"
  def error_message(:missing_work_package), do: "create-work result did not include a work package"
  def error_message(:unsupported_secret_handoff_mode), do: "secret handoff mode must be one of: #{Enum.join(@valid_modes, ", ")}"

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
