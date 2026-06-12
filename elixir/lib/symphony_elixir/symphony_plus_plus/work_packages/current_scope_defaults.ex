defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.CurrentScopeDefaults do
  @moduledoc false

  @minimum_sha_prefix_length 7

  @type arguments :: %{optional(String.t()) => term()}
  @type tool_result(value) :: {:ok, value} | {:tool_error, String.t()}

  @spec idempotency_key(arguments(), String.t(), String.t()) :: tool_result(String.t())
  def idempotency_key(arguments, tool, work_package_id) do
    case Map.get(arguments, "idempotency_key") do
      nil -> {:ok, generated_idempotency_key(tool, work_package_id, arguments)}
      value when is_binary(value) -> trim_required(value, "idempotency_key")
      _value -> {:tool_error, "invalid_idempotency_key"}
    end
  end

  @spec comment_target(arguments(), String.t(), boolean()) ::
          {:ok, String.t(), String.t()} | {:tool_error, String.t()}
  def comment_target(arguments, work_package_id, true) do
    case {Map.get(arguments, "target_kind"), Map.get(arguments, "target_id")} do
      {nil, nil} -> {:ok, "work_package", work_package_id}
      _provided -> explicit_comment_target(arguments)
    end
  end

  def comment_target(arguments, _work_package_id, false), do: explicit_comment_target(arguments)

  @spec metadata_with_head(arguments(), map(), String.t() | nil) :: tool_result(map())
  def metadata_with_head(arguments, metadata, current_head_sha) do
    with {:ok, head_sha} <- head_sha_argument(arguments, current_head_sha),
         :ok <- require_metadata_head_matches(metadata, head_sha) do
      {:ok, Map.put(metadata, "head_sha", head_sha)}
    end
  end

  @spec head_sha_argument(arguments(), String.t() | nil) :: tool_result(String.t())
  def head_sha_argument(arguments, current_head_sha) do
    case Map.fetch(arguments, "head_sha") do
      :error -> current_head_sha_argument(current_head_sha)
      {:ok, nil} -> current_head_sha_argument(current_head_sha)
      {:ok, head_sha} when is_binary(head_sha) -> trim_required(head_sha, "head_sha")
      {:ok, _head_sha} -> {:tool_error, "invalid_head_sha"}
    end
  end

  defp explicit_comment_target(arguments) do
    with {:ok, target_kind} <- trim_required(Map.get(arguments, "target_kind"), "target_kind"),
         {:ok, target_id} <- trim_required(Map.get(arguments, "target_id"), "target_id") do
      {:ok, target_kind, target_id}
    end
  end

  defp current_head_sha_argument(head_sha) when is_binary(head_sha), do: trim_required(head_sha, "current_head_sha")
  defp current_head_sha_argument(_head_sha), do: {:tool_error, "missing_current_head_sha"}

  defp generated_idempotency_key(tool, _work_package_id, _arguments) do
    "generated:" <> tool <> ":" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp require_metadata_head_matches(metadata, head_sha) do
    case metadata_head_sha(metadata) do
      nil -> :ok
      metadata_head_sha -> if head_sha_matches?(head_sha, metadata_head_sha), do: :ok, else: {:tool_error, "head_sha_mismatch"}
    end
  end

  defp metadata_head_sha(metadata), do: clean_string(Map.get(metadata, "head_sha") || get_in(metadata, ["head", "sha"]))

  defp head_sha_matches?(left, right) when is_binary(left) and is_binary(right) do
    left = String.trim(left)
    right = String.trim(right)
    left != "" and right != "" and (left == right or sha_prefix_match?(left, right))
  end

  defp sha_prefix_match?(left, right) do
    sha_abbreviation?(left) and sha_abbreviation?(right) and (String.starts_with?(left, right) or String.starts_with?(right, left))
  end

  defp sha_abbreviation?(value), do: String.length(value) >= @minimum_sha_prefix_length and String.match?(value, ~r/\A[0-9a-fA-F]+\z/)

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp trim_required(value, key) when is_binary(value) do
    case String.trim(value) do
      "" -> {:tool_error, "missing_#{key}"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp trim_required(_value, key), do: {:tool_error, "missing_#{key}"}
end
