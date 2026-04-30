defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.StringList do
  @moduledoc false

  @behaviour Ecto.Type

  @spec type() :: :string
  def type, do: :string

  @spec embed_as(term()) :: :self
  def embed_as(_format), do: :self

  @spec equal?(term(), term()) :: boolean()
  def equal?(left, right), do: left == right

  @spec cast(term()) :: {:ok, [String.t()]} | :error
  def cast(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: :error
  end

  def cast(_values), do: :error

  @spec load(term()) :: {:ok, [String.t()]} | :error
  def load(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, values} when is_list(values) -> cast(values)
      _result -> :error
    end
  end

  def load(_value), do: :error

  @spec dump(term()) :: {:ok, String.t()} | :error
  def dump(values) when is_list(values) do
    if Enum.all?(values, &is_binary/1), do: Jason.encode(values), else: :error
  end

  def dump(_values), do: :error
end
