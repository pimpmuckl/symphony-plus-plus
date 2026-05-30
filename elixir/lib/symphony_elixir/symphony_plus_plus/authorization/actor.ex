defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.Actor do
  @moduledoc false

  @enforce_keys [:role]
  defstruct [:id, :role, scopes: [], capabilities: [], source: nil, metadata: %{}]

  @type role :: :worker | :architect | :operator | :unknown

  @type t :: %__MODULE__{
          id: String.t() | nil,
          role: role(),
          scopes: [SymphonyElixir.SymphonyPlusPlus.Authorization.Scope.t()],
          capabilities: [String.t()],
          source: atom() | nil,
          metadata: map()
        }

  @spec new(role() | String.t(), keyword()) :: t()
  def new(role, opts \\ []) do
    %__MODULE__{
      id: Keyword.get(opts, :id),
      role: normalize_role(role),
      scopes: Keyword.get(opts, :scopes, []),
      capabilities: Keyword.get(opts, :capabilities, []),
      source: Keyword.get(opts, :source),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec normalize_role(role() | String.t() | nil) :: role()
  def normalize_role(:worker), do: :worker
  def normalize_role("worker"), do: :worker
  def normalize_role(:architect), do: :architect
  def normalize_role("architect"), do: :architect
  def normalize_role(:operator), do: :operator
  def normalize_role(:human), do: :operator
  def normalize_role("operator"), do: :operator
  def normalize_role("human"), do: :operator
  def normalize_role(_role), do: :unknown
end
