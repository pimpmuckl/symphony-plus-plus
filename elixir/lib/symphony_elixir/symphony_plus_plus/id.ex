defmodule SymphonyElixir.SymphonyPlusPlus.Id do
  @moduledoc false

  @default_random_bytes 10

  @spec random(String.t(), pos_integer()) :: String.t()
  def random(prefix, byte_count \\ @default_random_bytes)
      when is_binary(prefix) and is_integer(byte_count) and byte_count > 0 do
    prefix <> "_" <> random_token(byte_count)
  end

  defp random_token(byte_count) do
    byte_count
    |> :crypto.strong_rand_bytes()
    |> Base.encode32(case: :lower, padding: false)
  end
end
