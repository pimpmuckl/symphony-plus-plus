defmodule SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.StringList

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @derive {Inspect, except: [:secret_hash]}

  @roles ["worker", "architect"]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_package_id: String.t() | nil,
          display_key: String.t() | nil,
          secret_hash: String.t() | nil,
          grant_role: String.t() | nil,
          capabilities: [String.t()],
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          claimed_at: DateTime.t() | nil,
          claimed_by: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_access_grants" do
    field(:work_package_id, :string)
    field(:display_key, :string)
    field(:secret_hash, :string)
    field(:grant_role, :string)
    field(:capabilities, StringList, default: [])
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:claimed_at, :utc_datetime_usec)
    field(:claimed_by, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec roles() :: [String.t()]
  def roles, do: @roles

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("id", stable_id())
      |> put_new_value("grant_role", "worker")
      |> put_new_value("capabilities", [])

    %__MODULE__{}
    |> changeset(attrs)
    |> unique_constraint(:id, name: :sympp_access_grants_id_unique_index)
    |> unique_constraint(:secret_hash, name: :sympp_access_grants_secret_hash_unique_index)
  end

  @spec claim_changeset(t(), map()) :: Ecto.Changeset.t()
  def claim_changeset(%__MODULE__{} = access_grant, attrs) do
    access_grant
    |> cast(normalize_keys(attrs), [:claimed_at, :claimed_by])
    |> validate_required([:claimed_at, :claimed_by])
  end

  @spec revoke_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def revoke_changeset(%__MODULE__{} = access_grant, %DateTime{} = revoked_at) do
    access_grant
    |> change(revoked_at: DateTime.truncate(revoked_at, :microsecond))
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = access_grant, attrs) do
    access_grant
    |> cast(normalize_keys(attrs), [
      :id,
      :work_package_id,
      :display_key,
      :secret_hash,
      :grant_role,
      :capabilities,
      :expires_at,
      :revoked_at,
      :claimed_at,
      :claimed_by
    ])
    |> validate_required([
      :id,
      :work_package_id,
      :display_key,
      :secret_hash,
      :grant_role,
      :capabilities,
      :expires_at
    ])
    |> validate_length(:display_key, is: 4)
    |> validate_length(:secret_hash, is: 64)
    |> validate_inclusion(:grant_role, @roles)
    |> validate_worker_capabilities()
  end

  defp validate_worker_capabilities(changeset) do
    role = get_field(changeset, :grant_role)
    capabilities = get_field(changeset, :capabilities, [])

    if role == "worker" and Enum.any?(capabilities, &architect_capability?/1) do
      add_error(changeset, :capabilities, "worker grants cannot include architect capabilities")
    else
      changeset
    end
  end

  defp architect_capability?(capability) when is_binary(capability) do
    capability == "architect" or String.starts_with?(capability, ["architect:", "architect."])
  end

  defp architect_capability?(_capability), do: false

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp put_new_value(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""] do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp stable_id do
    "ag_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
