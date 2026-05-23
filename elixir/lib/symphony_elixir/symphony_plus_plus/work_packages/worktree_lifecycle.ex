defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeLifecycle do
  @moduledoc false

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type repo :: module()
  @type lifecycle_result :: %{
          work_package: WorkPackage.t(),
          status: String.t(),
          worktree_path: String.t() | nil,
          branch: String.t() | nil,
          base_branch: String.t() | nil,
          repo_root: String.t() | nil
        }
  @type error ::
          Repository.error()
          | :dirty_worktree
          | :git_not_found
          | :invalid_base_branch
          | :invalid_branch
          | :invalid_repo_root
          | :invalid_worktree_path
          | :recorded_worktree_missing
          | :unsafe_worktree_path
          | :worktree_path_exists
          | :worktree_path_missing_on_disk
          | {:git_failed, [String.t()], non_neg_integer(), String.t()}
          | {:path_canonicalize_failed, Path.t(), term()}
          | {:worktree_path_already_recorded, Path.t()}
          | {:worktree_record_failed, term()}

  @spec prepare(repo(), String.t(), map()) :: {:ok, lifecycle_result()} | {:error, error()}
  @spec prepare(repo(), String.t(), map(), keyword()) :: {:ok, lifecycle_result()} | {:error, error()}
  def prepare(repo, work_package_id, attrs, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_map(attrs) and is_list(opts) do
    with {:ok, %WorkPackage{} = work_package} <- Repository.get(repo, work_package_id),
         {:ok, repo_root} <- repo_root(attrs),
         {:ok, base_branch} <- ref_name(attrs, "base_branch", :invalid_base_branch, repo_root, opts),
         :ok <- require_base_branch(work_package, base_branch),
         {:ok, branch} <- ref_name(attrs, "branch", :invalid_branch, repo_root, opts),
         {:ok, worktree_path} <- worktree_path(repo_root, branch, opts),
         :ok <- validate_recorded_prepare_path(work_package, worktree_path),
         {:ok, result} <- maybe_replay_prepared(repo, work_package, repo_root, base_branch, branch, worktree_path, opts) do
      {:ok, result}
    end
  end

  @spec cleanup(repo(), String.t()) :: {:ok, lifecycle_result()} | {:error, error()}
  @spec cleanup(repo(), String.t(), keyword()) :: {:ok, lifecycle_result()} | {:error, error()}
  def cleanup(repo, work_package_id, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_list(opts) do
    with {:ok, %WorkPackage{} = work_package} <- Repository.get(repo, work_package_id) do
      cleanup_recorded_worktree(repo, work_package, opts)
    end
  end

  @spec worktree_root(keyword()) :: {:ok, Path.t()} | {:error, error()}
  def worktree_root(opts \\ []) when is_list(opts) do
    opts
    |> codex_home()
    |> then(&Path.join([&1, "worktrees", "spp_worktrees"]))
    |> canonicalize()
  end

  defp repo_root(attrs) do
    with {:ok, repo_root} <- required_string(attrs, "repo_root"),
         {:ok, repo_root} <- canonicalize(repo_root),
         true <- File.dir?(repo_root) do
      {:ok, repo_root}
    else
      false -> {:error, :invalid_repo_root}
      {:error, _reason} = error -> error
      :error -> {:error, :invalid_repo_root}
    end
  end

  defp ref_name(attrs, key, error, repo_root, opts) do
    with {:ok, ref_name} <- required_string(attrs, key),
         :ok <- git(repo_root, ["check-ref-format", "--branch", ref_name], opts) do
      {:ok, ref_name}
    else
      :error -> {:error, error}
      {:error, {:git_failed, _args, _status, _output}} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_base_branch(%WorkPackage{base_branch: base_branch}, base_branch), do: :ok
  defp require_base_branch(%WorkPackage{}, _base_branch), do: {:error, :invalid_base_branch}

  defp worktree_path(repo_root, branch, opts) do
    with {:ok, root} <- worktree_root(opts),
         {:ok, safe_branch} <- safe_segment(branch),
         {:ok, repo_name} <- safe_segment(Path.basename(repo_root)),
         candidate <- Path.join([root, repo_name, safe_branch]),
         {:ok, candidate} <- canonicalize(candidate),
         :ok <- require_inside_root(candidate, root) do
      {:ok, candidate}
    end
  end

  defp validate_recorded_prepare_path(%WorkPackage{worktree_path: nil}, _worktree_path), do: :ok

  defp validate_recorded_prepare_path(%WorkPackage{worktree_path: recorded_path}, worktree_path) do
    with {:ok, recorded_path} <- canonicalize(recorded_path) do
      if same_path?(recorded_path, worktree_path) do
        :ok
      else
        {:error, {:worktree_path_already_recorded, recorded_path}}
      end
    end
  end

  defp maybe_replay_prepared(_repo, %WorkPackage{worktree_path: recorded_path} = work_package, repo_root, base_branch, branch, worktree_path, _opts)
       when is_binary(recorded_path) do
    if File.dir?(worktree_path) do
      {:ok, result(work_package, "already_prepared", worktree_path, branch, base_branch, repo_root)}
    else
      {:error, :recorded_worktree_missing}
    end
  end

  defp maybe_replay_prepared(repo, %WorkPackage{} = work_package, repo_root, base_branch, branch, worktree_path, opts) do
    if File.exists?(worktree_path) do
      {:error, :worktree_path_exists}
    else
      create_worktree(repo, work_package, repo_root, base_branch, branch, worktree_path, opts)
    end
  end

  defp create_worktree(repo, %WorkPackage{} = work_package, repo_root, base_branch, branch, worktree_path, opts) do
    with :ok <- File.mkdir_p(Path.dirname(worktree_path)),
         :ok <- git(repo_root, ["fetch", "origin", base_branch], opts),
         :ok <- git(repo_root, ["worktree", "add", "-b", branch, worktree_path, "origin/#{base_branch}"], opts) do
      record_prepared_worktree(repo, work_package, repo_root, base_branch, branch, worktree_path, opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_prepared_worktree(repo, %WorkPackage{} = work_package, repo_root, base_branch, branch, worktree_path, opts) do
    case Repository.update(repo, work_package.id, %{worktree_path: worktree_path}) do
      {:ok, updated_work_package} ->
        {:ok, result(updated_work_package, "prepared", worktree_path, branch, base_branch, repo_root)}

      {:error, reason} ->
        _ = git(repo_root, ["worktree", "remove", worktree_path], opts)
        _ = git(repo_root, ["worktree", "prune"], opts)
        {:error, {:worktree_record_failed, reason}}
    end
  end

  defp cleanup_recorded_worktree(_repo, %WorkPackage{worktree_path: nil} = work_package, _opts) do
    {:ok, result(work_package, "already_clean", nil, nil, nil, nil)}
  end

  defp cleanup_recorded_worktree(repo, %WorkPackage{} = work_package, opts) do
    with {:ok, root} <- worktree_root(opts),
         {:ok, worktree_path} <- canonicalize(work_package.worktree_path),
         :ok <- require_inside_root(worktree_path, root),
         true <- File.dir?(worktree_path),
         {:ok, status_output} <- git_output(worktree_path, ["status", "--porcelain"], opts),
         :ok <- require_clean(status_output),
         {:ok, repo_root} <- repo_root_from_worktree(worktree_path, opts),
         :ok <- git(repo_root, ["worktree", "remove", worktree_path], opts),
         :ok <- git(repo_root, ["worktree", "prune"], opts),
         {:ok, updated_work_package} <- Repository.update(repo, work_package.id, %{worktree_path: nil}) do
      {:ok, result(updated_work_package, "cleaned", worktree_path, nil, nil, repo_root)}
    else
      false -> {:error, :worktree_path_missing_on_disk}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo_root_from_worktree(worktree_path, opts) do
    with {:ok, common_dir} <- git_output(worktree_path, ["rev-parse", "--path-format=absolute", "--git-common-dir"], opts),
         common_dir <- common_dir |> String.trim() |> first_line(),
         {:ok, common_dir} <- canonicalize(common_dir),
         repo_root <- repo_root_from_common_dir(common_dir),
         {:ok, repo_root} <- canonicalize(repo_root),
         true <- File.dir?(repo_root) do
      {:ok, repo_root}
    else
      false -> {:error, :invalid_repo_root}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo_root_from_common_dir(common_dir) do
    if Path.basename(common_dir) == ".git" do
      Path.dirname(common_dir)
    else
      common_dir
    end
  end

  defp require_clean(""), do: :ok
  defp require_clean(_status_output), do: {:error, :dirty_worktree}

  defp required_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: :error, else: {:ok, value}

      _other ->
        :error
    end
  end

  defp safe_segment(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")

    if value in ["", ".", ".."] do
      {:error, :invalid_worktree_path}
    else
      {:ok, value}
    end
  end

  defp require_inside_root(path, root) do
    if inside_root?(path, root), do: :ok, else: {:error, :unsafe_worktree_path}
  end

  defp inside_root?(path, root) do
    path = comparable_path(path)
    root = comparable_path(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp same_path?(left, right), do: comparable_path(left) == comparable_path(right)

  defp comparable_path(path) do
    path =
      path
      |> Path.expand()
      |> String.replace("\\", "/")
      |> String.trim_trailing("/")

    if match?({:win32, _name}, :os.type()), do: String.downcase(path), else: path
  end

  defp codex_home(opts) do
    opts[:codex_home] || System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex")
  end

  defp canonicalize(path), do: PathSafety.canonicalize(path)

  defp git(repo_root, args, opts) do
    case git_output(repo_root, args, opts) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_output(repo_root, args, opts) do
    with {:ok, git} <- git_executable(opts) do
      {output, status} = System.cmd(git, ["-C", repo_root | args], stderr_to_stdout: true)
      if status == 0, do: {:ok, output}, else: {:error, {:git_failed, args, status, output}}
    end
  end

  defp git_executable(opts) do
    cond do
      is_binary(opts[:git]) -> {:ok, opts[:git]}
      git = System.find_executable("git") -> {:ok, git}
      true -> {:error, :git_not_found}
    end
  end

  defp first_line(value) do
    value
    |> String.split(~r/\R/, parts: 2)
    |> hd()
  end

  defp result(work_package, status, worktree_path, branch, base_branch, repo_root) do
    %{
      work_package: work_package,
      status: status,
      worktree_path: worktree_path,
      branch: branch,
      base_branch: base_branch,
      repo_root: repo_root
    }
  end
end
