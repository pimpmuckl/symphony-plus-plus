defmodule SymphonyElixir.SymphonyPlusPlus.SecretHandoff do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @default_env_var "SYMPP_WORK_KEY_SECRET"
  @default_repo_root __DIR__ |> Path.join("../../../..") |> Path.expand()
  @metadata_version 1
  @metadata_lock_stale_seconds 300
  @max_handoff_metadata_bytes 16_384
  @max_handoff_metadata_scan_files 512
  @max_local_private_secret_bytes 16_384
  @valid_modes ["auto", "windows-credential-manager", "local-private-file"]

  @type error ::
          :missing_secret
          | :missing_claimed_by
          | :missing_repo_root
          | :invalid_repo_root
          | :missing_worker_grant_display_key
          | :missing_worker_grant_identity
          | :missing_worker_grant
          | :missing_work_package
          | :unsupported_handoff_metadata_location
          | :unsupported_secret_handoff_mode
          | :handoff_metadata_conflict
          | {:handoff_metadata_invalid, term()}
          | {:handoff_metadata_delete_failed, term()}
          | {:handoff_metadata_read_failed, term()}
          | {:handoff_metadata_write_failed, term()}
          | :local_private_file_unavailable_on_windows
          | :windows_credential_manager_unavailable
          | {:local_private_file_failed, term()}
          | {:local_private_file_delete_failed, term()}
          | :private_handoff_metadata_mismatch
          | :private_handoff_missing_file
          | :private_handoff_not_regular_file
          | :private_handoff_path_mismatch
          | :private_handoff_path_traversal
          | :private_handoff_secret_mismatch
          | :private_handoff_secret_too_large
          | {:private_handoff_read_failed, term()}
          | {:windows_credential_manager_delete_failed, term()}
          | {:windows_credential_manager_failed, integer()}

  @spec valid_modes() :: [String.t()]
  def valid_modes, do: @valid_modes

  @spec local_operator_repo_root() :: Path.t() | nil
  def local_operator_repo_root do
    case configured_local_operator_repo_root() do
      {:ok, repo_root} -> repo_root
      :invalid -> nil
      :not_configured -> cwd_local_operator_repo_root() || default_local_operator_repo_root()
    end
  end

  @spec local_operator_namespace_repo_roots() :: [Path.t()]
  def local_operator_namespace_repo_roots do
    case configured_local_operator_namespace_repo_root() do
      nil -> unique_repo_roots(cwd_local_operator_namespace_repo_roots() ++ [@default_repo_root])
      repo_root -> [repo_root]
    end
  end

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

  @spec delete_worker_secret_by_grant(WorkPackage.t(), map(), keyword()) :: :ok | {:error, error()}
  def delete_worker_secret_by_grant(%WorkPackage{} = work_package, worker_grant, opts)
      when is_map(worker_grant) and is_list(opts) do
    with {:ok, opts} <- require_handoff_namespace_opts(opts),
         :ok <- reject_metadata_location_overrides(opts),
         {:ok, context} <- handoff_metadata_context(work_package, worker_grant, opts) do
      delete_worker_secret_from_metadata(context, opts)
    end
  end

  def delete_worker_secret_by_grant(%WorkPackage{}, worker_grant, _opts) when not is_map(worker_grant),
    do: {:error, :missing_worker_grant}

  def delete_worker_secret_by_grant(%{}, _worker_grant, _opts), do: {:error, :missing_work_package}

  @spec read_worker_secret_metadata(WorkPackage.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def read_worker_secret_metadata(%WorkPackage{} = work_package, worker_grant, opts)
      when is_map(worker_grant) and is_list(opts) do
    with {:ok, opts} <- require_handoff_namespace_opts(opts),
         :ok <- reject_metadata_location_overrides(opts),
         {:ok, context} <- handoff_metadata_context(work_package, worker_grant, opts),
         {:ok, metadata} <- read_handoff_metadata(context.metadata_path) do
      handoff_from_metadata_for_display(metadata, context, worker_grant, opts)
    end
  end

  def read_worker_secret_metadata(%WorkPackage{}, worker_grant, _opts) when not is_map(worker_grant),
    do: {:error, :missing_worker_grant}

  def read_worker_secret_metadata(%{}, _worker_grant, _opts), do: {:error, :missing_work_package}

  @spec read_local_private_file_secret(WorkPackage.t(), map(), map(), keyword()) ::
          {:ok, String.t()} | {:error, error()}
  def read_local_private_file_secret(%WorkPackage{} = work_package, grant, handoff, opts)
      when is_map(grant) and is_map(handoff) and is_list(opts) do
    with {:ok, opts} <- require_handoff_namespace_opts(opts),
         :ok <- reject_metadata_location_overrides(opts) do
      read_local_private_file_secret_from_metadata(work_package, grant, handoff, opts)
    end
  end

  def read_local_private_file_secret(%WorkPackage{}, grant, _handoff, _opts) when not is_map(grant),
    do: {:error, :missing_worker_grant}

  def read_local_private_file_secret(%WorkPackage{}, _grant, _handoff, _opts),
    do: {:error, {:handoff_metadata_invalid, :missing_handoff}}

  def read_local_private_file_secret(%{}, _grant, _handoff, _opts), do: {:error, :missing_work_package}

  @spec worker_secret_available?(map(), keyword()) :: boolean()
  def worker_secret_available?(handoff, opts \\ []) when is_map(handoff) and is_list(opts) do
    worker_secret_availability(handoff, opts) == :available
  end

  @spec worker_secret_availability(map(), keyword()) :: :available | :missing | :unknown
  def worker_secret_availability(handoff, opts \\ []) when is_map(handoff) and is_list(opts) do
    case handoff_value(handoff, :mode) do
      "local-private-file" -> local_private_file_availability(handoff)
      "windows-credential-manager" -> windows_credential_availability(handoff, opts)
      _mode -> :missing
    end
  end

  @spec worker_secret_integrity(map(), String.t() | nil, keyword()) :: :match | :mismatch | :unknown
  def worker_secret_integrity(handoff, secret_hash, opts \\ []) when is_map(handoff) and is_list(opts) do
    case {handoff_value(handoff, :mode), secret_hash} do
      {"local-private-file", hash} when is_binary(hash) -> local_private_file_integrity(handoff, hash)
      {"windows-credential-manager", hash} when is_binary(hash) -> windows_credential_integrity(handoff, hash, opts)
      {_mode, _hash} -> :unknown
    end
  end

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
  def error_message(:invalid_repo_root), do: "secret handoff repository root must contain a worker-secret helper script"
  def error_message(:missing_worker_grant_display_key), do: "worker grant did not include a nonblank display key"
  def error_message(:missing_worker_grant_identity), do: "worker grant did not include a stable non-secret id"
  def error_message(:missing_worker_grant), do: "create-work result did not include a worker grant"
  def error_message(:missing_work_package), do: "create-work result did not include a work package"
  def error_message(:unsupported_handoff_metadata_location), do: "secret handoff metadata must use the managed metadata location"
  def error_message(:unsupported_secret_handoff_mode), do: "secret handoff mode must be one of: #{Enum.join(@valid_modes, ", ")}"
  def error_message(:handoff_metadata_conflict), do: "secret handoff metadata already exists with different coordinates"

  def error_message(:local_private_file_unavailable_on_windows),
    do: "local-private-file handoff could not be prepared on this host"

  def error_message(:windows_credential_manager_unavailable),
    do: "Windows handoff helpers require powershell.exe or pwsh"

  def error_message({:local_private_file_failed, reason}),
    do: "local private file handoff failed: #{inspect(reason)}"

  def error_message({:local_private_file_delete_failed, reason}),
    do: "local private file handoff cleanup failed: #{inspect(reason)}"

  def error_message(:private_handoff_metadata_mismatch), do: "private handoff metadata does not match the grant"
  def error_message(:private_handoff_missing_file), do: "private handoff file was not found"
  def error_message(:private_handoff_not_regular_file), do: "private handoff path is not a regular file"
  def error_message(:private_handoff_path_mismatch), do: "private handoff path does not match the managed store"
  def error_message(:private_handoff_path_traversal), do: "private handoff path traversal is not allowed"
  def error_message(:private_handoff_secret_mismatch), do: "private handoff secret does not match the grant"
  def error_message(:private_handoff_secret_too_large), do: "private handoff file is too large"
  def error_message({:private_handoff_read_failed, reason}), do: "private handoff file could not be read: #{inspect(reason)}"

  def error_message({:windows_credential_manager_delete_failed, reason}),
    do: "Windows Credential Manager handoff cleanup failed: #{inspect(reason)}"

  def error_message({:windows_credential_manager_failed, status}),
    do: "Windows Credential Manager handoff command failed with exit status #{status}"

  def error_message({:handoff_metadata_delete_failed, reason}),
    do: "secret handoff metadata cleanup failed: #{inspect(reason)}"

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
    with {:ok, opts} <- require_handoff_namespace_opts(opts),
         {:ok, repo_root} <- nonblank_opt(opts, :repo_root, :missing_repo_root),
         {:ok, repo_root} <- validate_local_operator_repo_root(repo_root) do
      {:ok, opts |> Keyword.put(:repo_root, repo_root) |> Keyword.put(:namespace_repo_root, repo_root)}
    end
  end

  defp require_handoff_namespace_opts(opts) do
    with {:ok, claimed_by} <- nonblank_opt(opts, :claimed_by, :missing_claimed_by),
         {:ok, namespace_repo_root} <- namespace_repo_root_opt(opts) do
      {:ok,
       opts
       |> maybe_put_expanded_repo_root()
       |> Keyword.put(:claimed_by, claimed_by)
       |> Keyword.put(:namespace_repo_root, Path.expand(namespace_repo_root))}
    end
  end

  defp namespace_repo_root_opt(opts) do
    case Keyword.get(opts, :namespace_repo_root) || Keyword.get(opts, :repo_root) do
      repo_root when is_binary(repo_root) ->
        repo_root = String.trim(repo_root)
        if repo_root == "", do: {:error, :missing_repo_root}, else: {:ok, repo_root}

      _repo_root ->
        {:error, :missing_repo_root}
    end
  end

  defp maybe_put_expanded_repo_root(opts) do
    case Keyword.get(opts, :repo_root) do
      repo_root when is_binary(repo_root) ->
        case String.trim(repo_root) do
          "" -> Keyword.delete(opts, :repo_root)
          repo_root -> Keyword.put(opts, :repo_root, Path.expand(repo_root))
        end

      _repo_root ->
        Keyword.delete(opts, :repo_root)
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
    :local_private_file
  end

  defp store_secret(:windows_credential_manager, secret, work_package, worker_grant, opts) do
    target = credential_target(work_package, worker_grant)
    repo_root = Keyword.fetch!(opts, :repo_root)
    script_path = Path.join(repo_root, "scripts/sympp-worker-secret.ps1")

    case powershell_executable(opts) do
      {:ok, powershell} ->
        powershell
        |> run_windows_credential_store(script_path, target, worker_grant_user(worker_grant), secret, opts)
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
    store_local_private_file(secret, work_package, worker_grant, opts)
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
                   "Intended for local/private operator use. File ACL strength depends on the local OS/user profile."
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

  defp run_windows_credential_store(powershell, script_path, target, user_name, secret, opts) do
    case windows_credential_command(
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
           [env: [{@default_env_var, secret}], stderr_to_stdout: true],
           opts
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
    |> maybe_put_handoff_value(:namespace_repo_root, handoff_namespace_repo_root(opts))
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
    if windows?() do
      powershell_local_file_run_mcp_command(secret_path, opts)
    else
      shell_local_file_run_mcp_command(secret_path, opts)
    end
  end

  defp powershell_local_file_run_mcp_command(secret_path, opts) do
    with {:ok, script_path} <- worker_secret_script_path(opts, "sympp-worker-secret.ps1"),
         {:ok, powershell} <- powershell_executable(opts) do
      {:ok, powershell_local_file_run_mcp_command(secret_path, powershell, script_path, opts)}
    else
      :error -> {:error, :windows_credential_manager_unavailable}
      {:error, :invalid_repo_root} -> {:error, :invalid_repo_root}
    end
  end

  defp powershell_local_file_run_mcp_command(secret_path, powershell, script_path, opts) do
    claimed_by = Keyword.fetch!(opts, :claimed_by)

    [
      ~s(& #{powershell_literal(powershell)} -NoProfile -ExecutionPolicy Bypass -File #{powershell_literal(script_path)} run-mcp-local-file),
      ~s(-SecretFile #{powershell_literal(secret_path)}),
      maybe_powershell_arg("-Database", Keyword.get(opts, :database)),
      ~s(-ClaimedBy #{powershell_literal(claimed_by)}),
      maybe_powershell_arg("-RepoRoot", handoff_namespace_repo_root(opts)),
      ~s(-ElixirDir #{powershell_literal(mcp_elixir_dir(opts))})
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp shell_local_file_run_mcp_command(secret_path, opts) do
    case worker_secret_script_path(opts, "sympp-worker-secret.sh") do
      {:ok, script_path} -> {:ok, shell_local_file_run_mcp_command(secret_path, script_path, opts)}
      {:error, :invalid_repo_root} -> {:error, :invalid_repo_root}
    end
  end

  defp shell_local_file_run_mcp_command(secret_path, script_path, opts) do
    claimed_by = Keyword.fetch!(opts, :claimed_by)

    [
      ~s(sh #{shell_literal(script_path)} run-mcp-local-file),
      ~s(--path #{shell_literal(secret_path)}),
      maybe_shell_arg("--database", Keyword.get(opts, :database)),
      ~s(--claimed-by #{shell_literal(claimed_by)}),
      maybe_shell_arg("--repo-root", handoff_namespace_repo_root(opts)),
      ~s(--elixir-dir #{shell_literal(mcp_elixir_dir(opts))})
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp mcp_elixir_dir(opts) do
    case Keyword.get(opts, :elixir_dir) do
      elixir_dir when is_binary(elixir_dir) ->
        case String.trim(elixir_dir) do
          "" -> default_mcp_elixir_dir()
          elixir_dir -> Path.expand(elixir_dir)
        end

      _elixir_dir ->
        default_mcp_elixir_dir()
    end
  end

  defp default_mcp_elixir_dir, do: Path.join(@default_repo_root, "elixir")

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
      replace_result =
        case Keyword.fetch(opts, :private_file_replace_fun) do
          {:ok, replace_fun} -> replace_fun.(temp_path, path)
          :error -> windows_replace_existing_private_file(temp_path, path, opts)
        end

      case replace_result do
        :ok -> :ok
        {:error, reason} -> {:error, {:replace_existing, reason}}
      end
    else
      {:error, rename_reason}
    end
  end

  defp windows_replace_existing_private_file(temp_path, path, opts) do
    case powershell_executable(opts) do
      {:ok, powershell} ->
        command =
          "$ErrorActionPreference = 'Stop'; " <>
            "[System.IO.File]::Replace($env:SYMPP_PRIVATE_FILE_SOURCE, " <>
            "$env:SYMPP_PRIVATE_FILE_DESTINATION, [NullString]::Value, $true)"

        case windows_file_replace_command(
               powershell,
               ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
               [
                 env: [{"SYMPP_PRIVATE_FILE_SOURCE", temp_path}, {"SYMPP_PRIVATE_FILE_DESTINATION", path}],
                 stderr_to_stdout: true
               ],
               opts
             ) do
          {_, 0} -> :ok
          {_output, status} -> {:error, {:exit_status, status}}
        end

      :error ->
        {:error, :powershell_unavailable}
    end
  end

  defp windows_file_replace_command(powershell, args, cmd_opts, opts) do
    command_fun = Keyword.get(opts, :windows_file_replace_command, &System.cmd/3)
    command_fun.(powershell, args, cmd_opts)
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
      to_string(Keyword.get(opts, :namespace_repo_root, Keyword.get(opts, :repo_root, ""))),
      0,
      handoff_database_hash_value(opts),
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
      opts |> Keyword.fetch!(:namespace_repo_root) |> Path.expand(),
      0,
      handoff_database_hash_value(opts),
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

  defp delete_worker_secret_from_metadata(context, opts) do
    with :ok <- prepare_handoff_metadata_lock_dir(context.metadata_path) do
      with_handoff_metadata_lock(context.metadata_path, opts, fn ->
        delete_worker_secret_from_locked_metadata(context, opts)
      end)
    end
  end

  defp prepare_handoff_metadata_lock_dir(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:handoff_metadata_read_failed, {:mkdir, reason}}}
    end
  end

  defp delete_worker_secret_from_locked_metadata(context, opts) do
    case read_handoff_metadata(context.metadata_path) do
      {:ok, metadata} ->
        delete_worker_secret_from_validated_metadata(metadata, context, opts)

      {:error, {:handoff_metadata_read_failed, _reason} = reason} ->
        {:error, reason}
    end
  end

  defp delete_worker_secret_from_validated_metadata(metadata, context, opts) do
    case handoff_from_metadata_for_cleanup(metadata, context) do
      {:ok, handoff} ->
        with :ok <- delete_worker_secret(handoff, opts) do
          delete_handoff_metadata_file(context.metadata_path)
        end

      {:error, {:handoff_metadata_invalid, _reason} = error} ->
        {:error, error}
    end
  end

  defp handoff_from_metadata_for_cleanup(metadata, context) do
    with :ok <- validate_handoff_metadata_identity(metadata, context),
         {:ok, mode} <- handoff_metadata_mode(metadata),
         {:ok, coordinates} <- handoff_metadata_cleanup_coordinates(mode, metadata, context),
         :ok <- validate_handoff_metadata_keys(metadata, mode) do
      {:ok, Map.put(coordinates, "mode", mode)}
    end
  end

  defp handoff_from_metadata_for_display(metadata, context, worker_grant, opts) do
    with :ok <- validate_handoff_metadata_identity(metadata, context),
         {:ok, mode} <- handoff_metadata_mode(metadata),
         {:ok, coordinates} <- handoff_metadata_display_coordinates(mode, metadata, context),
         :ok <- validate_handoff_metadata_keys(metadata, mode) do
      {:ok, handoff_metadata_display(mode, coordinates, context, worker_grant, opts)}
    end
  end

  defp handoff_metadata_display(mode, coordinates, context, worker_grant, opts) do
    target = credential_target(context.work_package, %{display_key: context.display_key, id: context.grant_identity})
    claimed_by = claimed_by(worker_grant)
    suggested_claimed_by = Keyword.fetch!(opts, :claimed_by)
    command_opts = Keyword.put(opts, :claimed_by, claimed_by || suggested_claimed_by)

    %{
      mode: mode,
      status: "stored",
      work_package_id: context.work_package_id,
      grant_id: context.grant_identity,
      display_key: context.display_key,
      target: target,
      claimed_by: claimed_by,
      suggested_claimed_by: suggested_claimed_by,
      claimed_by_required: true,
      secret_in_stdout: false
    }
    |> maybe_put_handoff_value(:namespace_repo_root, handoff_namespace_repo_root(opts))
    |> maybe_put_handoff_value(:path, Map.get(coordinates, "path"))
    |> maybe_put_handoff_value(
      :run_mcp_command,
      handoff_metadata_run_mcp_command(mode, coordinates, target, command_opts)
    )
  end

  defp claimed_by(worker_grant) do
    case handoff_value(worker_grant, :claimed_by) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end
  end

  defp handoff_metadata_run_mcp_command("local-private-file", %{"path" => path}, _target, opts) when is_binary(path) do
    case local_file_run_mcp_command(path, opts) do
      {:ok, command} -> command
      {:error, _reason} -> nil
    end
  end

  defp handoff_metadata_run_mcp_command("windows-credential-manager", _coordinates, target, opts) do
    with {:ok, script_path} <- worker_secret_script_path(opts, "sympp-worker-secret.ps1"),
         {:ok, powershell} <- powershell_executable(opts) do
      windows_credential_run_mcp_command(powershell, script_path, target, opts)
    else
      :error -> nil
      {:error, :invalid_repo_root} -> nil
    end
  end

  defp handoff_metadata_run_mcp_command(_mode, _coordinates, _target, _opts), do: nil

  defp maybe_put_handoff_value(map, _key, nil), do: map
  defp maybe_put_handoff_value(map, key, value), do: Map.put(map, key, value)

  defp handoff_namespace_repo_root(opts) do
    Keyword.get(opts, :namespace_repo_root) || Keyword.get(opts, :repo_root)
  end

  defp read_local_private_file_secret_from_metadata(%WorkPackage{} = work_package, grant, handoff, opts) do
    case read_local_private_file_secret_from_namespaced_metadata(work_package, grant, handoff, opts) do
      {:error, {:handoff_metadata_read_failed, :enoent}} = missing_error ->
        if private_handoff_scan_allowed?(handoff, opts) do
          read_local_private_file_secret_from_scanned_metadata(work_package, grant, handoff, opts, missing_error)
        else
          missing_error
        end

      result ->
        result
    end
  end

  defp private_handoff_scan_allowed?(handoff, opts) do
    not private_handoff_optional_coordinate?(handoff, :namespace_repo_root) and
      (not private_handoff_optional_coordinate?(handoff, :database) or
         Keyword.get(opts, :allow_database_metadata_scan?, false))
  end

  defp private_handoff_optional_coordinate?(handoff, key) do
    case handoff_value(handoff, key) do
      value when is_binary(value) -> String.trim(value) != ""
      _value -> false
    end
  end

  defp read_local_private_file_secret_from_namespaced_metadata(%WorkPackage{} = work_package, grant, handoff, opts) do
    with {:ok, display_handoff} <- read_worker_secret_metadata(work_package, grant, opts),
         :ok <- validate_private_handoff_claim_display(handoff, display_handoff),
         {:ok, path} <- private_handoff_claim_path(handoff, display_handoff),
         {:ok, secret} <- read_private_handoff_secret(path),
         :ok <- validate_private_handoff_secret(secret, handoff_value(grant, :secret_hash)) do
      {:ok, secret}
    end
  end

  defp read_local_private_file_secret_from_scanned_metadata(
         %WorkPackage{} = work_package,
         grant,
         handoff,
         opts,
         missing_error
       ) do
    with {:ok, context} <- private_handoff_scan_context(work_package, grant, handoff, opts),
         :ok <- validate_private_handoff_claim_display(handoff, private_handoff_scan_display(context)),
         {:ok, metadata} <- matching_handoff_metadata(context, missing_error),
         :ok <- validate_scanned_handoff_metadata(metadata, context),
         {:ok, _path} <- private_handoff_claim_path(handoff, private_handoff_scan_display(context)),
         {:ok, secret} <- read_private_handoff_secret(context.claim_path),
         :ok <- validate_private_handoff_secret(secret, handoff_value(grant, :secret_hash)) do
      {:ok, secret}
    end
  end

  defp private_handoff_scan_context(%WorkPackage{} = work_package, grant, handoff, opts) do
    with {:ok, display_key} <- fetch_grant_display_key(grant),
         {:ok, grant_identity} <- fetch_grant_identity(grant),
         {:ok, claim_path} <-
           private_handoff_scan_claim_path(work_package, display_key, grant_identity, handoff, opts) do
      {:ok,
       %{
         work_package: work_package,
         work_package_id: work_package.id,
         display_key: display_key,
         grant_identity: grant_identity,
         expected_local_private_file_path: claim_path,
         claim_path: claim_path,
         metadata_dir: Path.join(local_private_store_dir(opts), "metadata")
       }}
    end
  end

  defp private_handoff_scan_claim_path(%WorkPackage{} = work_package, display_key, grant_identity, handoff, opts) do
    store_dir = local_private_store_dir(opts)

    with {:ok, path} <- private_handoff_input_path(handoff),
         :ok <- validate_private_handoff_path_in_store(path, store_dir),
         :ok <- validate_managed_private_handoff_filename(path, work_package, display_key, grant_identity) do
      {:ok, path}
    end
  end

  defp private_handoff_input_path(handoff) do
    case handoff_value(handoff, :path) do
      path when is_binary(path) ->
        cond do
          String.trim(path) == "" -> {:error, :private_handoff_path_mismatch}
          private_handoff_path_traversal?(path) -> {:error, :private_handoff_path_traversal}
          true -> {:ok, Path.expand(path)}
        end

      _path ->
        {:error, :private_handoff_path_mismatch}
    end
  end

  defp validate_private_handoff_path_in_store(path, store_dir) do
    if path_inside_directory?(path, store_dir), do: :ok, else: {:error, :private_handoff_path_mismatch}
  end

  defp validate_managed_private_handoff_filename(path, %WorkPackage{} = work_package, display_key, grant_identity) do
    prefix = "#{safe_filename(work_package.id)}-#{safe_filename(display_key)}-#{safe_filename(grant_identity)}-"
    pattern = ~r/\A#{Regex.escape(prefix)}[A-Za-z0-9_-]{16}\.secret\z/

    if Regex.match?(pattern, Path.basename(path)), do: :ok, else: {:error, :private_handoff_path_mismatch}
  end

  defp private_handoff_scan_display(context) do
    %{
      mode: "local-private-file",
      work_package_id: context.work_package_id,
      grant_id: context.grant_identity,
      display_key: context.display_key,
      target: credential_target(context.work_package, %{display_key: context.display_key, id: context.grant_identity}),
      path: context.claim_path
    }
  end

  defp matching_handoff_metadata(context, missing_error) do
    with {:ok, paths} <- handoff_metadata_scan_paths(context.metadata_dir, missing_error) do
      scan_handoff_metadata_paths(paths, context, missing_error)
    end
  end

  defp handoff_metadata_scan_paths(metadata_dir, missing_error) do
    case File.ls(metadata_dir) do
      {:ok, entries} ->
        paths =
          entries
          |> Enum.filter(&handoff_metadata_filename?/1)
          |> Enum.sort()

        cond do
          paths == [] ->
            missing_error

          length(paths) > @max_handoff_metadata_scan_files ->
            {:error, {:handoff_metadata_read_failed, :too_many_metadata_files}}

          true ->
            {:ok, Enum.map(paths, &Path.join(metadata_dir, &1))}
        end

      {:error, :enoent} ->
        missing_error

      {:error, reason} ->
        {:error, {:handoff_metadata_read_failed, reason}}
    end
  end

  defp handoff_metadata_filename?(filename) when is_binary(filename) do
    Regex.match?(~r/\Ahandoff-[A-Za-z0-9_-]+\.json\z/, filename)
  end

  defp handoff_metadata_filename?(_filename), do: false

  defp scan_handoff_metadata_paths(paths, context, missing_error) do
    Enum.reduce_while(paths, missing_error, fn path, last_error ->
      scan_handoff_metadata_path(path, context, last_error)
    end)
  end

  defp scan_handoff_metadata_path(path, context, last_error) do
    case read_handoff_metadata(path) do
      {:ok, metadata} -> scanned_handoff_metadata_result(metadata, context, last_error)
      {:error, reason} -> {:cont, {:error, reason}}
    end
  end

  defp scanned_handoff_metadata_result(metadata, context, last_error) do
    case scanned_handoff_metadata_candidate(metadata, context) do
      :skip -> {:cont, last_error}
      :match -> {:halt, {:ok, metadata}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp scanned_handoff_metadata_candidate(metadata, context) when is_map(metadata) do
    case Map.get(metadata, "path") do
      path when is_binary(path) ->
        cond do
          private_handoff_path_traversal?(path) and Path.expand(path) == context.claim_path ->
            {:error, {:handoff_metadata_invalid, :local_path_mismatch}}

          Path.expand(path) == context.claim_path ->
            :match

          true ->
            :skip
        end

      _path ->
        :skip
    end
  end

  defp validate_scanned_handoff_metadata(metadata, context) do
    with :ok <- validate_handoff_metadata_identity(metadata, context),
         {:ok, "local-private-file"} <- handoff_metadata_mode(metadata),
         :ok <- validate_handoff_metadata_keys(metadata, "local-private-file") do
      :ok
    else
      {:ok, _mode} -> {:error, {:handoff_metadata_invalid, :local_path_mismatch}}
      error -> error
    end
  end

  defp path_inside_directory?(path, directory) do
    path = comparable_path(path)
    directory = directory |> comparable_path() |> String.trim_trailing("/")

    String.starts_with?(path, directory <> "/")
  end

  defp comparable_path(path) do
    path =
      path
      |> Path.expand()
      |> String.replace("\\", "/")

    if windows?(), do: String.downcase(path), else: path
  end

  defp validate_private_handoff_claim_display(handoff, display_handoff) do
    with :ok <- expect_private_handoff_field(handoff, :mode, handoff_value(display_handoff, :mode)),
         :ok <-
           expect_private_handoff_field(
             handoff,
             :work_package_id,
             handoff_value(display_handoff, :work_package_id)
           ),
         :ok <- expect_private_handoff_field(handoff, :grant_id, handoff_value(display_handoff, :grant_id)),
         :ok <- expect_private_handoff_field(handoff, :display_key, handoff_value(display_handoff, :display_key)) do
      expect_private_handoff_field(handoff, :target, handoff_value(display_handoff, :target))
    end
  end

  defp expect_private_handoff_field(handoff, key, expected) when is_binary(expected) do
    case handoff_value(handoff, key) do
      ^expected -> :ok
      _value -> {:error, :private_handoff_metadata_mismatch}
    end
  end

  defp expect_private_handoff_field(_handoff, _key, _expected), do: {:error, :private_handoff_metadata_mismatch}

  defp private_handoff_claim_path(handoff, display_handoff) do
    expected_path = handoff_value(display_handoff, :path)

    with path when is_binary(path) <- handoff_value(handoff, :path),
         false <- private_handoff_path_traversal?(path),
         expanded_path = Path.expand(path),
         true <- is_binary(expected_path) and expanded_path == expected_path do
      validate_private_handoff_file(expected_path)
    else
      true -> {:error, :private_handoff_path_traversal}
      _value -> {:error, :private_handoff_path_mismatch}
    end
  end

  defp private_handoff_path_traversal?(path) when is_binary(path) do
    path
    |> String.split(["/", "\\"], trim: false)
    |> Enum.any?(&(&1 == ".."))
  end

  defp validate_private_handoff_file(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}}
      when is_integer(size) and size > 0 and size <= @max_local_private_secret_bytes ->
        {:ok, path}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :private_handoff_secret_too_large}

      {:ok, %File.Stat{}} ->
        {:error, :private_handoff_not_regular_file}

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:error, :private_handoff_missing_file}

      {:error, reason} ->
        {:error, {:private_handoff_read_failed, reason}}
    end
  end

  defp read_private_handoff_secret(path) when is_binary(path) do
    case File.read(path) do
      {:ok, secret} when byte_size(secret) > 0 and byte_size(secret) <= @max_local_private_secret_bytes ->
        {:ok, secret}

      {:ok, _secret} ->
        {:error, :private_handoff_secret_too_large}

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:error, :private_handoff_missing_file}

      {:error, reason} ->
        {:error, {:private_handoff_read_failed, reason}}
    end
  end

  defp validate_private_handoff_secret(secret, secret_hash) when is_binary(secret) and is_binary(secret_hash) do
    if WorkKey.secret_hash(secret) == secret_hash, do: :ok, else: {:error, :private_handoff_secret_mismatch}
  end

  defp validate_private_handoff_secret(_secret, _secret_hash), do: {:error, :private_handoff_secret_mismatch}

  defp validate_handoff_metadata_identity(metadata, context) do
    with :ok <- expect_handoff_metadata_field(metadata, "version", @metadata_version),
         :ok <- expect_handoff_metadata_field(metadata, "work_package_id", context.work_package_id),
         :ok <- expect_handoff_metadata_field(metadata, "worker_grant_display_key", context.display_key) do
      expect_handoff_metadata_field(metadata, "worker_grant_id", context.grant_identity)
    end
  end

  defp expect_handoff_metadata_field(metadata, key, expected) do
    case Map.fetch(metadata, key) do
      {:ok, ^expected} -> :ok
      {:ok, _value} -> {:error, {:handoff_metadata_invalid, {:metadata_mismatch, key}}}
      :error -> {:error, {:handoff_metadata_invalid, {:metadata_missing, key}}}
    end
  end

  defp handoff_metadata_cleanup_coordinates("local-private-file", metadata, context) do
    case Map.get(metadata, "path") do
      path when is_binary(path) -> validate_handoff_metadata_local_cleanup_path(path, context)
      _path -> {:error, {:handoff_metadata_invalid, :missing_local_path}}
    end
  end

  defp handoff_metadata_cleanup_coordinates("windows-credential-manager", metadata, context) do
    expected_target =
      credential_target(context.work_package, %{display_key: context.display_key, id: context.grant_identity})

    case Map.get(metadata, "target") do
      ^expected_target -> {:ok, %{"target" => expected_target}}
      target when is_binary(target) -> {:error, {:handoff_metadata_invalid, :credential_target_mismatch}}
      _target -> {:error, {:handoff_metadata_invalid, :missing_credential_target}}
    end
  end

  defp validate_handoff_metadata_keys(metadata, mode) do
    expected_keys = expected_handoff_metadata_keys(mode)
    actual_keys = Map.keys(metadata)
    missing_keys = expected_keys -- actual_keys
    unexpected_keys = actual_keys -- expected_keys

    cond do
      missing_keys != [] -> {:error, {:handoff_metadata_invalid, {:metadata_missing_keys, Enum.sort(missing_keys)}}}
      unexpected_keys != [] -> {:error, {:handoff_metadata_invalid, {:metadata_unexpected_keys, Enum.sort(unexpected_keys)}}}
      true -> :ok
    end
  end

  defp expected_handoff_metadata_keys("local-private-file") do
    ["version", "work_package_id", "worker_grant_display_key", "worker_grant_id", "mode", "path"]
  end

  defp expected_handoff_metadata_keys("windows-credential-manager") do
    ["version", "work_package_id", "worker_grant_display_key", "worker_grant_id", "mode", "target"]
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

  defp validate_handoff_metadata_local_cleanup_path(path, context) do
    expanded_path = Path.expand(path)

    cond do
      String.trim(path) == "" ->
        {:error, {:handoff_metadata_invalid, :missing_local_path}}

      expanded_path != context.expected_local_private_file_path ->
        {:error, {:handoff_metadata_invalid, :local_path_mismatch}}

      true ->
        {:ok, %{"path" => context.expected_local_private_file_path}}
    end
  end

  defp handoff_metadata_display_coordinates("local-private-file", metadata, context) do
    case Map.get(metadata, "path") do
      path when is_binary(path) -> validate_handoff_metadata_local_display_path(path, context)
      _path -> {:error, {:handoff_metadata_invalid, :missing_local_path}}
    end
  end

  defp handoff_metadata_display_coordinates("windows-credential-manager", metadata, context) do
    handoff_metadata_cleanup_coordinates("windows-credential-manager", metadata, context)
  end

  defp validate_handoff_metadata_local_display_path(path, context) do
    expanded_path = Path.expand(path)

    cond do
      String.trim(path) == "" ->
        {:error, {:handoff_metadata_invalid, :missing_local_path}}

      expanded_path != context.expected_local_private_file_path ->
        {:error, {:handoff_metadata_invalid, :local_path_mismatch}}

      true ->
        {:ok, %{"path" => context.expected_local_private_file_path}}
    end
  end

  defp handoff_database_hash_value(opts) do
    case Keyword.get(opts, :database) do
      database when is_binary(database) ->
        database
        |> String.trim()
        |> database_hash_value(database)

      nil ->
        ""

      database ->
        :erlang.term_to_binary(database)
    end
  end

  defp database_hash_value("", _database), do: ""
  defp database_hash_value(_trimmed, database), do: database |> Repo.database_key() |> :erlang.term_to_binary()

  defp configured_local_operator_repo_root do
    case Application.get_env(:symphony_elixir, :sympp_repo_root) do
      repo_root when is_binary(repo_root) -> configured_local_operator_repo_root(repo_root)
      _repo_root -> :not_configured
    end
  end

  defp configured_local_operator_repo_root(repo_root) do
    case String.trim(repo_root) do
      "" -> :not_configured
      repo_root -> configured_local_operator_repo_root_status(repo_root)
    end
  end

  defp configured_local_operator_repo_root_status(repo_root) do
    case validate_local_operator_repo_root(repo_root) do
      {:ok, repo_root} -> {:ok, repo_root}
      {:error, :invalid_repo_root} -> :invalid
    end
  end

  defp cwd_local_operator_repo_root do
    cwd = File.cwd!()

    [cwd, Path.expand("..", cwd)]
    |> Enum.find_value(fn repo_root ->
      case validate_local_operator_repo_root(repo_root) do
        {:ok, repo_root} -> repo_root
        {:error, :invalid_repo_root} -> nil
      end
    end)
  rescue
    _error -> nil
  end

  defp default_local_operator_repo_root do
    case validate_local_operator_repo_root(@default_repo_root) do
      {:ok, repo_root} -> repo_root
      {:error, :invalid_repo_root} -> nil
    end
  end

  defp worker_secret_script_path(opts, script) do
    with {:ok, repo_root} <- nonblank_opt(opts, :repo_root, :invalid_repo_root) do
      script_path = Path.join([repo_root, "scripts", script])

      if File.regular?(script_path), do: {:ok, script_path}, else: {:error, :invalid_repo_root}
    end
  end

  defp validate_local_operator_repo_root(repo_root) do
    repo_root = Path.expand(repo_root)

    if local_operator_repo_root?(repo_root), do: {:ok, repo_root}, else: {:error, :invalid_repo_root}
  end

  defp configured_local_operator_namespace_repo_root do
    case Application.get_env(:symphony_elixir, :sympp_repo_root) do
      repo_root when is_binary(repo_root) ->
        case String.trim(repo_root) do
          "" -> nil
          repo_root -> Path.expand(repo_root)
        end

      _repo_root ->
        nil
    end
  end

  defp cwd_local_operator_namespace_repo_roots do
    cwd = File.cwd!()
    [cwd, Path.expand("..", cwd)]
  rescue
    _error -> []
  end

  defp unique_repo_roots(repo_roots) do
    repo_roots
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp local_operator_repo_root?(repo_root) do
    Enum.any?(["sympp-worker-secret.sh", "sympp-worker-secret.ps1"], fn script ->
      File.regular?(Path.join([repo_root, "scripts", script]))
    end)
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

  defp read_handoff_metadata(path) do
    with :ok <- validate_handoff_metadata_file(path),
         {:ok, content} <- File.read(path) do
      decode_handoff_metadata(content)
    else
      {:error, {:handoff_metadata_read_failed, _reason} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:handoff_metadata_read_failed, reason}}
    end
  end

  defp validate_handoff_metadata_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_handoff_metadata_bytes ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        {:error, {:handoff_metadata_read_failed, :too_large}}

      {:ok, %File.Stat{}} ->
        {:error, {:handoff_metadata_read_failed, :not_regular_file}}

      {:error, reason} ->
        {:error, {:handoff_metadata_read_failed, reason}}
    end
  end

  defp decode_handoff_metadata(content) do
    case Jason.decode(content) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      {:ok, _metadata} -> {:error, {:handoff_metadata_read_failed, :not_a_map}}
      {:error, _reason} -> {:error, {:handoff_metadata_read_failed, :invalid_json}}
    end
  end

  defp delete_handoff_metadata_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:handoff_metadata_delete_failed, reason}}
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

  defp local_private_file_availability(handoff) do
    case handoff_value(handoff, :path) do
      path when is_binary(path) -> path |> Path.expand() |> local_private_file_path_availability()
      _path -> :missing
    end
  end

  defp local_private_file_path_availability(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> if file_readable?(path), do: :available, else: :unknown
      {:ok, %File.Stat{}} -> :unknown
      {:error, reason} when reason in [:enoent, :enotdir] -> :missing
      {:error, _reason} -> :unknown
    end
  end

  defp file_readable?(path) do
    case File.open(path, [:read], fn _io_device -> :ok end) do
      {:ok, :ok} -> true
      _error -> false
    end
  end

  defp local_private_file_integrity(handoff, secret_hash) do
    case handoff_value(handoff, :path) do
      path when is_binary(path) -> path |> Path.expand() |> local_private_file_path_integrity(secret_hash)
      _path -> :mismatch
    end
  end

  defp local_private_file_path_integrity(path, secret_hash) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> read_local_private_file_integrity(path, secret_hash)
      {:ok, %File.Stat{}} -> :unknown
      {:error, reason} when reason in [:enoent, :enotdir] -> :mismatch
      {:error, _reason} -> :unknown
    end
  end

  defp read_local_private_file_integrity(path, secret_hash) do
    case File.read(path) do
      {:ok, secret} -> secret_integrity(secret, secret_hash)
      {:error, :enoent} -> :mismatch
      {:error, _reason} -> :unknown
    end
  end

  defp secret_integrity(secret, secret_hash) when is_binary(secret) and is_binary(secret_hash) do
    if WorkKey.secret_hash(secret) == secret_hash, do: :match, else: :mismatch
  end

  defp delete_windows_credential(handoff, opts) do
    with target when is_binary(target) <- handoff_value(handoff, :target),
         {:ok, repo_root} <-
           nonblank_opt(opts, :repo_root, {:windows_credential_manager_delete_failed, :missing_repo_root}),
         {:ok, powershell} <- powershell_executable_for_delete(opts) do
      script_path = Path.join(repo_root, "scripts/sympp-worker-secret.ps1")

      case windows_credential_command(
             powershell,
             ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path, "remove", "-Target", target],
             [stderr_to_stdout: true],
             opts
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

  defp windows_credential_availability(handoff, opts) do
    with target when is_binary(target) <- handoff_value(handoff, :target),
         {:ok, repo_root} <- nonblank_opt(opts, :repo_root, :missing_repo_root),
         {:ok, powershell} <- powershell_executable_for_check(opts) do
      script_path = Path.join(repo_root, "scripts/sympp-worker-secret.ps1")
      windows_credential_availability(powershell, script_path, target, opts)
    else
      _missing_or_unavailable -> :unknown
    end
  end

  defp windows_credential_integrity(handoff, secret_hash, opts) do
    with target when is_binary(target) <- handoff_value(handoff, :target),
         {:ok, repo_root} <- nonblank_opt(opts, :repo_root, :missing_repo_root),
         {:ok, powershell} <- powershell_executable_for_check(opts) do
      script_path = Path.join(repo_root, "scripts/sympp-worker-secret.ps1")
      windows_credential_integrity(powershell, script_path, target, secret_hash, opts)
    else
      _missing_or_unavailable -> :unknown
    end
  end

  defp windows_credential_availability(powershell, script_path, target, opts) do
    if File.regular?(script_path) do
      run_windows_credential_exists(powershell, script_path, target, opts)
    else
      :unknown
    end
  end

  defp windows_credential_integrity(powershell, script_path, target, secret_hash, opts) do
    if File.regular?(script_path) do
      run_windows_credential_verify(powershell, script_path, target, secret_hash, opts)
    else
      :unknown
    end
  end

  defp run_windows_credential_exists(powershell, script_path, target, opts) do
    case windows_credential_command(
           powershell,
           ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path, "exists", "-Target", target],
           [stderr_to_stdout: true],
           opts
         ) do
      {_output, 0} -> :available
      {_output, 2} -> :missing
      {_output, _status} -> :unknown
    end
  end

  defp run_windows_credential_verify(powershell, script_path, target, secret_hash, opts) do
    case windows_credential_command(
           powershell,
           [
             "-NoProfile",
             "-ExecutionPolicy",
             "Bypass",
             "-File",
             script_path,
             "verify",
             "-Target",
             target,
             "-SecretSha256",
             secret_hash
           ],
           [stderr_to_stdout: true],
           opts
         ) do
      {_output, 0} -> :match
      {_output, status} when status in [2, 3] -> :mismatch
      {_output, _status} -> :unknown
    end
  end

  defp powershell_executable_for_check(opts) do
    case powershell_executable(opts) do
      {:ok, powershell} -> {:ok, powershell}
      :error -> {:error, :windows_credential_manager_unavailable}
    end
  end

  defp powershell_executable_for_delete(opts) do
    case powershell_executable(opts) do
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

  defp powershell_executable(opts) do
    case Keyword.get(opts, :powershell_executable) do
      executable when is_binary(executable) ->
        executable = String.trim(executable)
        if executable == "", do: :error, else: {:ok, executable}

      _other ->
        find_powershell_executable()
    end
  end

  defp find_powershell_executable do
    cond do
      executable = System.find_executable("powershell.exe") -> {:ok, executable}
      executable = System.find_executable("powershell") -> {:ok, executable}
      executable = System.find_executable("pwsh") -> {:ok, executable}
      true -> :error
    end
  end

  defp windows_credential_command(powershell, args, cmd_opts, opts) do
    command_fun = Keyword.get(opts, :windows_credential_command, &System.cmd/3)
    command_fun.(powershell, args, cmd_opts)
  end

  defp windows?, do: match?({:win32, _}, :os.type())
end
