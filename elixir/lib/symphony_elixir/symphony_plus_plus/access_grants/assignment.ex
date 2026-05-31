defmodule SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment do
  @moduledoc false

  @enforce_keys [:grant_id, :work_package_id, :display_key, :grant_role, :capabilities, :claimed_at, :claimed_by]
  defstruct [
    :grant_id,
    :work_package_id,
    :phase_id,
    :display_key,
    :grant_role,
    :capabilities,
    :claimed_at,
    :claimed_by,
    scopes: []
  ]

  @type t :: %__MODULE__{
          grant_id: String.t(),
          work_package_id: String.t() | nil,
          phase_id: String.t() | nil,
          display_key: String.t(),
          grant_role: String.t(),
          capabilities: [String.t()] | nil,
          claimed_at: DateTime.t(),
          claimed_by: String.t(),
          scopes: [SymphonyElixir.SymphonyPlusPlus.Authorization.Scope.t()]
        }
end
