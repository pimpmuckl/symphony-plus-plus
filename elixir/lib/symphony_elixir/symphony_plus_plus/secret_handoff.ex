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
          | {:handoff_metadata_delete_failed, term()}
          | {:handoff_metadata_failed, term()}
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
    with {:ok, _identity} <- fetch_grant_identity(worker_grant),
         {:ok, opts} <- require_handoff_opts(opts),
         metadata_plan = handoff_metadata_write_plan(work_package, worker_grant, opts),
         metadata_paths = Enum.map(metadata_plan, & &1.path),
         {:ok, metadata} <- encode_handoff_metadata(handoff, metadata_paths) do
      store_handoff_metadata(metadata_plan, metadata, opts)
    end
  end

  def store_worker_secret_metadata(%WorkPackage{}, _worker_grant, _handoff, _opts),
    do: {:error, :missing_worker_grant}

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

  @spec delete_worker_secret_for_grant(WorkPackage.t(), map(), keyword()) :: :ok | {:error, term()}
  def delete_worker_secret_for_grant(%WorkPackage{} = work_package, worker_grant, opts)
      when is_map(worker_grant) and is_list(opts) do
    with {:ok, _identity} <- fetch_grant_identity(worker_grant),
         {:ok, mode} <- normalize_mode(Keyword.get(opts, :mode, "auto")),
         {:ok, handoff, metadata_path} <- handoff_for_delete(mode, work_package, worker_grant, opts) do
      metadata_paths = handoff_metadata_paths(work_package, worker_grant, opts, metadata_path, handoff)

      case delete_worker_secret(handoff, opts) do
        :ok -> delete_handoff_metadata(metadata_paths)
        {:error, _reason} = error -> error
      end
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

  def error_message({:handoff_metadata_failed, reason}),
    do: "secret handoff metadata write failed: #{inspect(reason)}"

  def error_message({:handoff_metadata_delete_failed, reason}),
    do: "secret handoff metadata cleanup failed: #{inspect(reason)}"

  defp fetch_secret(%{secret: secret}) when is_binary(secret) and secret != "", do: {:ok, secret}
  defp fetch_secret(%{"secret" => secret}) when is_binary(secret) and secret != "", do: {:ok, secret}
  defp fetch_secret(_worker_grant), do: {:error, :missing_secret}

  defp fetch_grant_identity(worker_grant) do
    case handoff_value(worker_grant, :id) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :missing_worker_grant_identity}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, :missing_worker_grant_identity}
    end
  end

  defp grant_identity!(worker_grant) do
    {:ok, identity} = fetch_grant_identity(worker_grant)
    identity
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
      display_key: Map.fetch!(worker_grant, :display_key),
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
    identity = grant_identity!(worker_grant)

    "SymphonyPlusPlus:worker:#{work_package_id}:#{identity}"
  end

  defp worker_grant_user(%{display_key: display_key}), do: "sympp-worker-#{display_key}"

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

  defp handoff_for_delete(mode, work_package, worker_grant, opts) do
    case read_handoff_metadata(work_package, worker_grant, opts) do
      {:ok, handoff, metadata_path} ->
        {:ok, handoff, metadata_path}

      :missing ->
        fallback_handoff_for_delete(mode, work_package, worker_grant, opts)

      {:error, reason} ->
        if Keyword.get(opts, :require_metadata, false) do
          {:error, reason}
        else
          fallback_handoff_for_delete(mode, work_package, worker_grant, opts)
        end
    end
  end

  defp fallback_handoff_for_delete(:windows_credential_manager, work_package, worker_grant, opts) do
    if Keyword.get(opts, :require_metadata, false) do
      {:error, {:handoff_metadata_failed, :missing_metadata}}
    else
      {:ok, %{mode: "windows-credential-manager", target: credential_target(work_package, worker_grant)}, nil}
    end
  end

  defp fallback_handoff_for_delete(:local_private_file, work_package, worker_grant, opts) do
    if Keyword.get(opts, :require_metadata, false) do
      {:error, {:handoff_metadata_failed, :missing_metadata}}
    else
      {:ok, %{mode: "local-private-file", path: local_private_file_path(work_package, worker_grant, opts)}, nil}
    end
  end

  defp encode_handoff_metadata(handoff, metadata_paths) do
    metadata =
      [:mode, :path, :target]
      |> Enum.reduce(%{}, fn key, acc ->
        case handoff_value(handoff, key) do
          value when is_binary(value) -> Map.put(acc, Atom.to_string(key), value)
          _value -> acc
        end
      end)
      |> Map.put("published_at_unix_ms", System.os_time(:millisecond))
      |> put_metadata_mirrors(metadata_paths)

    case Jason.encode(metadata) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:handoff_metadata_failed, {:encode, reason}}}
    end
  end

  defp put_metadata_mirrors(metadata, paths) do
    mirrors =
      paths
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()

    Map.put(metadata, "metadata_mirrors", mirrors)
  end

  defp store_handoff_metadata(plan, metadata, opts) do
    plan
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, written_paths} ->
      case write_handoff_metadata(path.path, metadata, opts) do
        :ok ->
          {:cont, {:ok, [path.path | written_paths]}}

        {:error, _reason} = error when path.required? ->
          _cleanup_result = delete_handoff_metadata(written_paths)
          {:halt, error}

        {:error, _reason} ->
          {:cont, {:ok, written_paths}}
      end
    end)
    |> case do
      {:ok, _written_paths} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp write_handoff_metadata(path, metadata, opts) do
    directory = Path.dirname(path)

    try do
      File.mkdir_p!(directory)

      with :ok <- prepare_private_store_dir(directory, opts),
           :ok <- write_private_file(path, metadata, opts) do
        :ok
      else
        {:error, reason} -> {:error, {:handoff_metadata_failed, reason}}
      end
    rescue
      error -> {:error, {:handoff_metadata_failed, error.__struct__}}
    end
  end

  defp read_handoff_metadata(work_package, worker_grant, opts) do
    {candidates, fallback} =
      work_package
      |> handoff_metadata_read_paths(worker_grant, opts)
      |> Enum.reduce({[], :missing}, &collect_handoff_metadata_candidate(&1, &2, work_package, worker_grant))

    case select_handoff_metadata_candidate(Enum.reverse(candidates), work_package, worker_grant) do
      {path, handoff} -> {:ok, handoff, path}
      nil -> fallback
    end
  end

  defp collect_handoff_metadata_candidate(path, {candidates, fallback}, work_package, worker_grant) do
    case read_handoff_metadata_path(path) do
      {:ok, handoff} ->
        collect_valid_handoff_metadata_candidate(path, handoff, candidates, fallback, work_package, worker_grant)

      :missing ->
        {candidates, fallback}

      {:error, _reason} = error ->
        {candidates, metadata_read_fallback(fallback, error)}
    end
  end

  defp collect_valid_handoff_metadata_candidate(path, handoff, candidates, fallback, work_package, worker_grant) do
    if handoff_metadata_candidate_valid?(path, handoff, work_package, worker_grant) do
      {[{path, handoff} | candidates], fallback}
    else
      {candidates, metadata_read_fallback(fallback, {:error, {:handoff_metadata_failed, :invalid_metadata}})}
    end
  end

  defp metadata_read_fallback(:missing, {:error, _reason} = error), do: error
  defp metadata_read_fallback({:error, _reason} = error, {:error, _next_reason}), do: error

  defp read_handoff_metadata_path(path) do
    with {:ok, content} <- File.read(path),
         {:ok, handoff} <- Jason.decode(content) do
      if is_map(handoff) do
        {:ok, handoff}
      else
        {:error, {:handoff_metadata_failed, :invalid_metadata}}
      end
    else
      {:error, :enoent} -> :missing
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:handoff_metadata_failed, {:decode, reason}}}
      {:error, reason} -> {:error, {:handoff_metadata_failed, {:read, reason}}}
    end
  end

  defp select_handoff_metadata_candidate([], _work_package, _worker_grant), do: nil

  defp select_handoff_metadata_candidate(candidates, work_package, worker_grant) do
    Enum.max_by(candidates, &handoff_metadata_candidate_rank(&1, work_package, worker_grant))
  end

  defp handoff_metadata_candidate_rank({path, handoff}, work_package, worker_grant) do
    {
      equivalent_metadata_mirror_count(handoff, work_package, worker_grant),
      handoff_metadata_published_at(handoff),
      metadata_file_mtime(path)
    }
  end

  defp handoff_metadata_published_at(handoff) do
    case handoff_value(handoff, :published_at_unix_ms) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _value -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp metadata_file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _reason} -> 0
    end
  end

  defp equivalent_metadata_mirror_count(handoff, work_package, worker_grant) do
    handoff
    |> handoff_metadata_mirror_paths(work_package, worker_grant)
    |> Enum.count(fn path ->
      case read_handoff_metadata_path(path) do
        {:ok, mirror} ->
          handoff_metadata_content_valid?(path, mirror, work_package, worker_grant) and
            handoff_metadata_equivalent?(mirror, handoff)

        _missing_or_error ->
          false
      end
    end)
  end

  defp delete_handoff_metadata(paths) do
    paths
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:handoff_metadata_delete_failed, reason}}}
      end
    end)
  end

  defp handoff_metadata_paths(work_package, worker_grant, opts, extra_path, handoff) do
    read_paths = handoff_metadata_read_paths(work_package, worker_grant, opts)
    owned_paths = [extra_path | read_paths] |> Enum.reject(&is_nil/1) |> Enum.map(&Path.expand/1)

    ([extra_path] ++ read_paths ++ recorded_handoff_metadata_paths(handoff, work_package, worker_grant, owned_paths))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp recorded_handoff_metadata_paths(handoff, work_package, worker_grant, owned_paths) when is_map(handoff) do
    handoff
    |> handoff_metadata_mirror_paths(work_package, worker_grant)
    |> Enum.filter(&owned_or_verified_handoff_metadata_path?(&1, owned_paths, handoff))
  end

  defp recorded_handoff_metadata_paths(_handoff, _work_package, _worker_grant, _owned_paths), do: []

  defp handoff_metadata_mirror_paths(handoff, work_package, worker_grant) when is_map(handoff) do
    filename = handoff_metadata_filename(work_package, worker_grant)

    handoff
    |> handoff_value(:metadata_mirrors)
    |> case do
      paths when is_list(paths) -> paths
      _paths -> []
    end
    |> Enum.filter(&safe_recorded_handoff_metadata_path?(&1, filename))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp handoff_metadata_mirror_paths(_handoff, _work_package, _worker_grant), do: []

  defp safe_recorded_handoff_metadata_path?(path, filename) when is_binary(path) do
    expanded = Path.expand(path)

    Path.type(path) == :absolute and
      Path.basename(expanded) == filename and
      Path.extname(expanded) == ".json"
  end

  defp safe_recorded_handoff_metadata_path?(_path, _filename), do: false

  defp owned_or_verified_handoff_metadata_path?(path, owned_paths, handoff) do
    path in owned_paths or verified_handoff_metadata_mirror?(path, handoff)
  end

  defp verified_handoff_metadata_mirror?(path, expected_handoff) do
    case read_handoff_metadata_path(path) do
      {:ok, handoff} ->
        handoff_metadata_equivalent?(handoff, expected_handoff) and metadata_mirror_self_listed?(handoff, path)

      _missing_or_error ->
        false
    end
  end

  defp handoff_metadata_candidate_valid?(path, handoff, work_package, worker_grant) do
    handoff_metadata_content_valid?(path, handoff, work_package, worker_grant) and
      not conflicting_current_metadata_mirror?(path, handoff, work_package, worker_grant)
  end

  defp handoff_metadata_content_valid?(path, handoff, work_package, worker_grant) do
    safe_recorded_handoff_metadata_path?(path, handoff_metadata_filename(work_package, worker_grant)) and
      metadata_mirror_self_listed?(handoff, path) and
      handoff_delete_target_valid?(handoff, work_package, worker_grant)
  end

  defp conflicting_current_metadata_mirror?(path, handoff, work_package, worker_grant) do
    expanded_path = Path.expand(path)

    handoff
    |> handoff_metadata_mirror_paths(work_package, worker_grant)
    |> Enum.reject(&(&1 == expanded_path))
    |> Enum.any?(fn mirror_path ->
      case read_handoff_metadata_path(mirror_path) do
        {:ok, mirror} ->
          handoff_metadata_content_valid?(mirror_path, mirror, work_package, worker_grant) and
            not handoff_metadata_equivalent?(mirror, handoff)

        _missing_or_error ->
          false
      end
    end)
  end

  defp handoff_metadata_equivalent?(handoff, expected_handoff) do
    Enum.all?([:mode, :path, :target], fn key ->
      handoff_value(handoff, key) == handoff_value(expected_handoff, key)
    end)
  end

  defp handoff_delete_target_valid?(handoff, work_package, worker_grant) do
    case handoff_value(handoff, :mode) do
      "local-private-file" ->
        case handoff_value(handoff, :path) do
          path when is_binary(path) -> Path.basename(Path.expand(path)) == local_private_file_filename(work_package, worker_grant)
          _path -> false
        end

      "windows-credential-manager" ->
        handoff_value(handoff, :target) == credential_target(work_package, worker_grant)

      _mode ->
        false
    end
  end

  defp metadata_mirror_self_listed?(handoff, path) do
    expanded_path = Path.expand(path)

    case handoff_value(handoff, :metadata_mirrors) do
      paths when is_list(paths) ->
        expanded_path in (paths |> Enum.filter(&is_binary/1) |> Enum.map(&Path.expand/1))

      _paths ->
        false
    end
  end

  defp handoff_metadata_read_paths(work_package, worker_grant, opts) do
    handoff_metadata_dirs(opts)
    |> Enum.map(&handoff_metadata_path(work_package, worker_grant, &1))
  end

  defp handoff_metadata_write_plan(work_package, worker_grant, opts) do
    opts
    |> handoff_metadata_dir_plan()
    |> Enum.map(fn metadata_dir ->
      metadata_dir
      |> Map.update!(:path, &handoff_metadata_path(work_package, worker_grant, &1))
    end)
    |> Enum.uniq_by(& &1.path)
  end

  defp handoff_metadata_dirs(opts) do
    opts
    |> handoff_metadata_dir_plan()
    |> Enum.map(& &1.path)
    |> Enum.uniq()
  end

  defp handoff_metadata_dir_plan(opts) do
    cond do
      metadata_dir = Keyword.get(opts, :metadata_dir) ->
        [
          %{path: metadata_dir, required?: true},
          %{path: default_handoff_metadata_dir(), required?: false}
        ]

      store_dir = Keyword.get(opts, :store_dir) ->
        [
          %{path: Path.join(store_dir, "metadata"), required?: true},
          %{path: default_handoff_metadata_dir(), required?: false}
        ]

      true ->
        [%{path: default_handoff_metadata_dir(), required?: true}]
    end
    |> Enum.map(&Map.update!(&1, :path, fn path -> Path.expand(path) end))
    |> Enum.uniq()
  end

  defp handoff_metadata_path(%WorkPackage{} = work_package, worker_grant, metadata_dir) do
    Path.join(Path.expand(metadata_dir), handoff_metadata_filename(work_package, worker_grant))
  end

  defp handoff_metadata_filename(%WorkPackage{} = work_package, worker_grant) do
    identity = grant_identity!(worker_grant)

    "#{safe_filename(work_package.id)}-#{safe_filename(identity)}-#{stable_identity_hash(work_package.id, identity)}.json"
  end

  defp default_handoff_metadata_dir do
    Path.join(default_local_private_store_dir(), "metadata")
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

    Path.join(Path.expand(store_dir), local_private_file_filename(work_package, worker_grant))
  end

  defp local_private_file_filename(%WorkPackage{} = work_package, worker_grant) do
    identity = grant_identity!(worker_grant)

    "#{safe_filename(work_package.id)}-#{safe_filename(identity)}-#{stable_identity_hash(work_package.id, identity)}.secret"
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

  defp stable_identity_hash(work_package_id, identity) do
    hash_source = [work_package_id, 0, identity]

    :sha256
    |> :crypto.hash(hash_source)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
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
