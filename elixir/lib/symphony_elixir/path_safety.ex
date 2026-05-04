defmodule SymphonyElixir.PathSafety do
  @moduledoc false

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  defp resolve_segments(root, resolved_segments, []), do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest]) do
    case segment_status(segment) do
      :too_long -> {:error, :enametoolong}
      :ok -> resolve_segment(root, resolved_segments, segment, rest)
    end
  end

  defp resolve_segment(root, resolved_segments, segment, rest) do
    candidate_path = join_path(root, resolved_segments ++ [segment])

    case File.lstat(candidate_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        resolve_symlink(root, resolved_segments, candidate_path, rest)

      {:ok, _stat} ->
        resolve_segments(root, resolved_segments ++ [segment], rest)

      {:error, :enoent} ->
        {:ok, join_path(root, resolved_segments ++ [segment | rest])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_symlink(root, resolved_segments, candidate_path, rest) do
    with {:ok, target} <- :file.read_link_all(String.to_charlist(candidate_path)) do
      resolved_target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved_segments))
      {target_root, target_segments} = split_absolute_path(resolved_target)
      resolve_segments(target_root, [], target_segments ++ rest)
    end
  end

  defp segment_status(segment) do
    if segment_length(segment) > 255, do: :too_long, else: :ok
  end

  defp segment_length(segment) do
    case :os.type() do
      {:win32, _name} -> utf16_code_units(segment)
      _type -> byte_size(segment)
    end
  end

  defp utf16_code_units(segment) do
    segment
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> byte_size()
    |> div(2)
  end

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end
end
