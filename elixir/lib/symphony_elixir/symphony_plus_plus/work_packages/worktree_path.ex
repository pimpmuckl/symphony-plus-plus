defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreePath do
  @moduledoc false

  @worktree_segment_prefix_length 12

  alias SymphonyElixir.PathSafety

  @spec repo_segment(Path.t()) :: {:ok, String.t()} | {:error, :invalid_worktree_path}
  def repo_segment(repo_root), do: unique_segment(Path.basename(repo_root), repo_root, @worktree_segment_prefix_length)

  @spec unique_segment(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_worktree_path}
  def unique_segment(display_value, fingerprint_value), do: unique_segment(display_value, fingerprint_value, :full)

  @spec unique_segment(String.t(), String.t(), :full | pos_integer()) ::
          {:ok, String.t()} | {:error, :invalid_worktree_path}
  def unique_segment(display_value, fingerprint_value, prefix_length) do
    with {:ok, safe_value} <- safe_segment(display_value) do
      {:ok, "#{segment_prefix(safe_value, prefix_length)}-#{short_hash(fingerprint_value)}"}
    end
  end

  @spec safe_segment(String.t()) :: {:ok, String.t()} | {:error, :invalid_worktree_path}
  def safe_segment(value) when is_binary(value) do
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

  @spec managed_path_matches_repo_hash?(Path.t(), Path.t()) :: boolean()
  def managed_path_matches_repo_hash?(repo_root, worktree_path) do
    with {:ok, repo_segment} <- repo_segment(repo_root),
         {:ok, legacy_repo_segment} <- unique_segment(Path.basename(repo_root), repo_root),
         {:ok, worktree_path} <- canonicalize(worktree_path) do
      worktree_path
      |> Path.dirname()
      |> Path.basename()
      |> then(&(&1 in [repo_segment, legacy_repo_segment]))
    else
      _result -> false
    end
  end

  @spec same_existing_path?(Path.t(), Path.t()) :: boolean()
  def same_existing_path?(left, right) do
    with {:ok, left} <- canonicalize(String.trim(left)),
         {:ok, right} <- canonicalize(String.trim(right)) do
      same_path?(left, right)
    else
      _result -> false
    end
  end

  defp segment_prefix(value, :full), do: value
  defp segment_prefix(value, prefix_length), do: String.slice(value, 0, prefix_length)

  defp short_hash(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 10)
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

  defp canonicalize(path), do: PathSafety.canonicalize(path)
end
