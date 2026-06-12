defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree.Attrs do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Id

  @spec normalize_keys(map()) :: map()
  def normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  @spec put_new_value(map(), String.t(), term()) :: map()
  def put_new_value(attrs, key, value) when is_map(attrs) and is_binary(key) do
    if Map.get(attrs, key) in [nil, ""], do: Map.put(attrs, key, value), else: attrs
  end

  @spec stable_id(String.t()) :: String.t()
  def stable_id(prefix) when is_binary(prefix) do
    Id.random(prefix)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)
end
