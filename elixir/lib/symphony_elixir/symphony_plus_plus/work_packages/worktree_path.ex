defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreePath do
  @moduledoc false

  @compact_segment_length 16
  @previous_segment_prefix_length 12

  alias SymphonyElixir.PathSafety

  @spec repo_segment(Path.t()) :: {:ok, String.t()} | {:error, :invalid_worktree_path}
  def repo_segment(repo_root), do: unique_segment(Path.basename(repo_root), repo_root)

  @spec unique_segment(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_worktree_path}
  def unique_segment(display_value, fingerprint_value) do
    with {:ok, _safe_value} <- safe_segment(display_value) do
      {:ok, short_hash(fingerprint_value)}
    end
  end

  @doc false
  @spec legacy_unique_segment(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_worktree_path}
  def legacy_unique_segment(display_value, fingerprint_value) do
    with {:ok, safe_value} <- safe_segment(display_value) do
      {:ok, "#{safe_value}-#{legacy_short_hash(fingerprint_value)}"}
    end
  end

  @doc false
  @spec previous_unique_segment(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_worktree_path}
  def previous_unique_segment(display_value, fingerprint_value) do
    with {:ok, safe_value} <- safe_segment(display_value) do
      {:ok, "#{String.slice(safe_value, 0, @previous_segment_prefix_length)}-#{legacy_short_hash(fingerprint_value)}"}
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
         {:ok, legacy_repo_segment} <- legacy_unique_segment(Path.basename(repo_root), repo_root),
         {:ok, previous_repo_segment} <- previous_unique_segment(Path.basename(repo_root), repo_root),
         {:ok, worktree_path} <- canonicalize(worktree_path) do
      worktree_path
      |> Path.dirname()
      |> Path.basename()
      |> then(&(&1 in [repo_segment, legacy_repo_segment, previous_repo_segment]))
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

  defp short_hash(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, @compact_segment_length)
  end

  defp legacy_short_hash(value) when is_binary(value) do
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
