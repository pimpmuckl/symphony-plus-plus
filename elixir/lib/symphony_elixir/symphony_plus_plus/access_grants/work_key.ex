defmodule SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey do
  @moduledoc false

  @enforce_keys [:display_key, :secret]
  defstruct [:display_key, :secret]

  @secret_bytes 32
  @secret_prefix "wk_"
  @display_key_bytes 2

  @type t :: %__MODULE__{
          display_key: String.t(),
          secret: String.t()
        }

  @spec generate() :: t()
  def generate do
    %__MODULE__{
      display_key: display_key(),
      secret: @secret_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@secret_bytes), padding: false)
    }
  end

  @spec secret_hash(String.t()) :: String.t()
  def secret_hash(secret) when is_binary(secret) do
    :sha256
    |> :crypto.hash(secret)
    |> Base.encode16(case: :lower)
  end

  @spec secret_shape?(String.t()) :: boolean()
  def secret_shape?(@secret_prefix <> encoded_secret) do
    String.length(encoded_secret) >= 43
  end

  def secret_shape?(_secret), do: false

  defp display_key do
    @display_key_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :upper)
  end
end

defimpl Inspect, for: SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey do
  import Inspect.Algebra

  def inspect(work_key, opts) do
    concat(["#WorkKey<", to_doc(%{display_key: work_key.display_key, secret: "[REDACTED]"}, opts), ">"])
  end
end
