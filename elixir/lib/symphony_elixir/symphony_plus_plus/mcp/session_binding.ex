defmodule SymphonyElixir.SymphonyPlusPlus.MCP.SessionBinding do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @fields ~w(
    id client_key_hash initialized recoverable recovery_kind access_grant_id
    claim_lease_id work_package_id phase_id grant_role claimed_by actor_kind
    actor_id actor_display_name last_seen_at last_rehydrated_at
  )a

  schema "sympp_mcp_session_bindings" do
    field(:client_key_hash, :string)
    field(:initialized, :boolean, default: false)
    field(:recoverable, :boolean, default: false)
    field(:recovery_kind, :string)
    field(:access_grant_id, :string)
    field(:claim_lease_id, :string)
    field(:work_package_id, :string)
    field(:phase_id, :string)
    field(:grant_role, :string)
    field(:claimed_by, :string)
    field(:actor_kind, :string)
    field(:actor_id, :string)
    field(:actor_display_name, :string)
    field(:last_seen_at, :utc_datetime_usec)
    field(:last_rehydrated_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec binding_id(String.t(), String.t()) :: String.t()
  def binding_id(client_key, state_key) when is_binary(client_key) and is_binary(state_key) do
    "mcp_http_" <> hash([client_key, <<0>>, state_key])
  end

  @spec client_key_hash(String.t()) :: String.t()
  def client_key_hash(client_key) when is_binary(client_key), do: hash(client_key)

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = binding, attrs) when is_map(attrs) do
    binding
    |> cast(attrs, @fields)
    |> validate_required([:id, :client_key_hash, :initialized, :recoverable, :last_seen_at])
    |> validate_nonblank_optional(:recovery_kind)
    |> validate_nonblank_optional(:access_grant_id)
    |> validate_nonblank_optional(:claim_lease_id)
    |> validate_nonblank_optional(:work_package_id)
    |> validate_nonblank_optional(:phase_id)
    |> validate_nonblank_optional(:grant_role)
    |> validate_nonblank_optional(:claimed_by)
    |> validate_nonblank_optional(:actor_kind)
    |> validate_nonblank_optional(:actor_id)
    |> validate_nonblank_optional(:actor_display_name)
  end

  defp hash(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.url_encode64(padding: false)
  end

  defp validate_nonblank_optional(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and String.trim(value) == "", do: [{field, "cannot be blank"}], else: []
    end)
  end
end
