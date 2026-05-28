defmodule SymphonyElixir.SymphonyPlusPlus.BranchPattern do
  @moduledoc false

  @unsupported_wildcard_reason :unsupported_branch_pattern_wildcard
  @unsupported_wildcard_message "must be an exact branch or a {{placeholder}} template; '*' wildcards are not supported"

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(value) when value in [nil, ""], do: :ok

  def validate(value) when is_binary(value) do
    if String.contains?(value, "*") do
      {:error, @unsupported_wildcard_reason}
    else
      :ok
    end
  end

  def validate(_value), do: :ok

  @spec error_message(atom()) :: String.t()
  def error_message(@unsupported_wildcard_reason), do: @unsupported_wildcard_message
  def error_message(reason), do: "is invalid: #{reason}"
end
