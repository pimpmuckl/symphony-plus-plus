defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeTargetRoot do
  @moduledoc false

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreePath

  @spec git_metadata_present?(Path.t()) :: boolean()
  def git_metadata_present?(worktree_path) do
    dot_git = Path.join(worktree_path, ".git")

    cond do
      File.dir?(dot_git) ->
        File.regular?(Path.join(dot_git, "HEAD"))

      File.regular?(dot_git) ->
        usable_gitdir_file?(File.read(dot_git), worktree_path)

      true ->
        false
    end
  end

  @spec from_live_worktree(Path.t(), keyword()) :: {:ok, Path.t()} | {:error, :invalid_target_repo_root}
  def from_live_worktree(worktree_path, opts) do
    with {:ok, common_dir} <- git_common_dir(worktree_path, opts),
         {:ok, repo_root} <- repo_root_from_common_dir(common_dir),
         true <- File.dir?(repo_root) do
      {:ok, repo_root}
    else
      _result -> {:error, :invalid_target_repo_root}
    end
  end

  @spec from_package(WorkPackage.t(), Path.t()) :: {:ok, Path.t()} | :error
  def from_package(%WorkPackage{repo: repo}, worktree_path) do
    repo_name = repo_name_segment(repo)

    [
      repo,
      standard_code_checkout(repo_name),
      user_code_checkout(repo_name)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.find_value(fn candidate ->
      with {:ok, candidate} <- canonicalize(candidate),
           true <- File.dir?(candidate),
           true <- WorktreePath.managed_path_matches_repo_hash?(candidate, worktree_path) do
        {:ok, candidate}
      else
        _result -> nil
      end
    end)
    |> case do
      {:ok, _candidate} = result -> result
      nil -> :error
    end
  end

  defp usable_gitdir_file?({:ok, contents}, worktree_path) do
    case contents |> String.trim() |> String.split(":", parts: 2) do
      ["gitdir", git_dir] ->
        git_dir = Path.expand(String.trim(git_dir), worktree_path)
        File.dir?(git_dir) and File.regular?(Path.join(git_dir, "HEAD"))

      _contents ->
        false
    end
  end

  defp usable_gitdir_file?({:error, _reason}, _worktree_path), do: false

  defp git_common_dir(path, opts) do
    with {:ok, common_dir} <- git_output(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"], opts),
         common_dir <- common_dir |> String.trim() |> first_line() do
      canonicalize(common_dir)
    end
  end

  defp repo_root_from_common_dir(common_dir) do
    if Path.basename(common_dir) == ".git" do
      common_dir
      |> Path.dirname()
      |> canonicalize()
    else
      canonicalize(common_dir)
    end
  end

  defp repo_name_segment(repo) when is_binary(repo) do
    repo
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.trim_trailing("\\")
    |> Path.basename()
    |> String.replace_suffix(".git", "")
  end

  defp repo_name_segment(_repo), do: nil

  defp standard_code_checkout(repo_name) when is_binary(repo_name) and repo_name != "" do
    if match?({:win32, _name}, :os.type()), do: Path.join(["C:/Code", repo_name])
  end

  defp standard_code_checkout(_repo_name), do: nil

  defp user_code_checkout(repo_name) when is_binary(repo_name) and repo_name != "" do
    case System.user_home() do
      home when is_binary(home) and home != "" -> Path.join([home, "Code", repo_name])
      _home -> nil
    end
  end

  defp user_code_checkout(_repo_name), do: nil

  defp git_output(repo_root, args, opts) do
    with {:ok, git} <- git_executable(opts) do
      {output, status} = System.cmd(git, ["-C", repo_root | args], stderr_to_stdout: true)
      if status == 0, do: {:ok, output}, else: {:error, :invalid_target_repo_root}
    end
  end

  defp git_executable(opts) do
    cond do
      is_binary(opts[:git]) -> {:ok, opts[:git]}
      git = System.find_executable("git") -> {:ok, git}
      true -> {:error, :invalid_target_repo_root}
    end
  end

  defp first_line(value) do
    value
    |> String.split(~r/\R/, parts: 2)
    |> hd()
  end

  defp canonicalize(path), do: PathSafety.canonicalize(path)
end
