defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreePath do
  @moduledoc false

  @compact_segment_length 8
  @collision_segment_lengths [8, 12, 16]
  @previous_compact_segment_length 16
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
  @spec previous_compact_unique_segment(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_worktree_path}
  def previous_compact_unique_segment(display_value, fingerprint_value) do
    with {:ok, _safe_value} <- safe_segment(display_value) do
      {:ok, compact_hash(fingerprint_value, @previous_compact_segment_length)}
    end
  end

  @doc false
  @spec worktree_leaf(Path.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_worktree_path}
  def worktree_leaf(repo_root, package_id, branch) do
    worktree_leaf(repo_root, package_id, branch, @compact_segment_length)
  end

  @doc false
  @spec collision_worktree_leaves(Path.t(), String.t(), String.t()) ::
          {:ok, [{String.t(), pos_integer()}]} | {:error, :invalid_worktree_path}
  def collision_worktree_leaves(repo_root, package_id, branch) do
    Enum.reduce_while(@collision_segment_lengths, {:ok, []}, fn length, {:ok, leaves} ->
      case worktree_leaf(repo_root, package_id, branch, length) do
        {:ok, leaf} -> {:cont, {:ok, [{leaf, length} | leaves]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, leaves} -> {:ok, Enum.reverse(leaves)}
      {:error, reason} -> {:error, reason}
    end)
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
         {:ok, previous_compact_repo_segment} <- previous_compact_unique_segment(Path.basename(repo_root), repo_root),
         {:ok, legacy_repo_segment} <- legacy_unique_segment(Path.basename(repo_root), repo_root),
         {:ok, previous_repo_segment} <- previous_unique_segment(Path.basename(repo_root), repo_root),
         {:ok, worktree_path} <- canonicalize(worktree_path) do
      parent = worktree_path |> Path.dirname() |> Path.basename()

      parent in [repo_segment, previous_compact_repo_segment, legacy_repo_segment, previous_repo_segment]
    else
      _result -> false
    end
  end

  @spec current_worktree_path?(Path.t(), String.t(), String.t(), Path.t()) :: boolean()
  def current_worktree_path?(repo_root, package_id, branch, worktree_path)
      when is_binary(repo_root) and is_binary(package_id) and is_binary(branch) and is_binary(worktree_path) do
    with {:ok, leaves} <- collision_worktree_leaves(repo_root, package_id, branch),
         leaf <- Path.basename(worktree_path) do
      Enum.any?(leaves, fn {candidate, _length} -> candidate == leaf end)
    else
      _result -> false
    end
  end

  def current_worktree_path?(_repo_root, _package_id, _branch, _worktree_path), do: false

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
    compact_hash(value, @compact_segment_length)
  end

  defp compact_hash(value, length) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode32(case: :lower, padding: false)
    |> binary_part(0, length)
  end

  defp worktree_leaf(repo_root, package_id, branch, length) do
    with {:ok, repo_root} <- canonicalize(repo_root),
         {:ok, _package_segment} <- safe_segment(package_id),
         {:ok, _branch_segment} <- safe_segment(branch) do
      material = Enum.join([repo_root, package_id, branch], <<0>>)
      {:ok, material |> long_hash() |> binary_part(0, length)}
    end
  end

  defp long_hash(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode32(case: :lower, padding: false)
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
