defmodule SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @active_statuses ["active", "paused"]
  @statuses @active_statuses ++ ["released", "reclaimed"]
  @actor_kinds ["agent", "human", "operator", "system"]
  @immutable_fields ~w(id work_package_id access_grant_id claim_group_id previous_claim_id actor_kind actor_id actor_display_name lease_started_at)a

  @type t :: %__MODULE__{}

  schema "sympp_claim_leases" do
    field(:work_package_id, :string)
    field(:access_grant_id, :string)
    field(:claim_group_id, :string)
    field(:previous_claim_id, :string)
    field(:actor_kind, :string)
    field(:actor_id, :string)
    field(:actor_display_name, :string)
    field(:status, :string)
    field(:lease_started_at, :utc_datetime_usec)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:stale_after_ms, :integer)
    field(:stale_checked_at, :utc_datetime_usec)
    field(:stale_at, :utc_datetime_usec)
    field(:stale_reason, :string)
    field(:paused_at, :utc_datetime_usec)
    field(:paused_by_actor_id, :string)
    field(:pause_reason, :string)
    field(:reclaimed_at, :utc_datetime_usec)
    field(:reclaimed_by_actor_id, :string)
    field(:reclaim_reason, :string)
    field(:released_at, :utc_datetime_usec)
    field(:release_reason, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec active_statuses() :: [String.t()]
  def active_statuses, do: @active_statuses

  @spec create_changeset(map(), keyword()) :: Ecto.Changeset.t()
  def create_changeset(attrs, opts \\ []) do
    now = opts |> Keyword.get(:now, DateTime.utc_now(:microsecond)) |> utc_datetime_usec()
    attrs = normalize_keys(attrs)
    id = normalized_string(Map.get(attrs, "id")) || stable_id()

    attrs =
      attrs
      |> Map.put("id", id)
      |> put_new_value("claim_group_id", id)
      |> put_new_value("status", "active")
      |> put_new_value("actor_kind", "agent")
      |> put_new_value("lease_started_at", now)
      |> put_new_value("last_seen_at", now)

    %__MODULE__{}
    |> cast(attrs, fields())
    |> validate_required([
      :id,
      :work_package_id,
      :claim_group_id,
      :actor_kind,
      :actor_id,
      :status,
      :lease_started_at,
      :last_seen_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:actor_kind, @actor_kinds)
    |> validate_number(:stale_after_ms, greater_than: 0)
    |> validate_nonblank_optional(:actor_display_name)
    |> validate_nonblank_optional(:paused_by_actor_id)
    |> validate_nonblank_optional(:reclaimed_by_actor_id)
    |> unique_constraint(:id, name: :sympp_claim_leases_id_unique_index)
    |> unique_constraint(:work_package_id, name: :sympp_claim_leases_one_current_per_work_package_index)
    |> foreign_key_constraint(:work_package_id)
    |> foreign_key_constraint(:access_grant_id)
    |> foreign_key_constraint(:previous_claim_id)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = claim_lease, attrs) do
    claim_lease
    |> cast(normalize_keys(attrs), fields() -- @immutable_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:actor_kind, @actor_kinds)
    |> validate_number(:stale_after_ms, greater_than: 0)
    |> validate_nonblank_optional(:actor_display_name)
    |> validate_nonblank_optional(:paused_by_actor_id)
    |> validate_nonblank_optional(:reclaimed_by_actor_id)
  end

  defp fields do
    [
      :id,
      :work_package_id,
      :access_grant_id,
      :claim_group_id,
      :previous_claim_id,
      :actor_kind,
      :actor_id,
      :actor_display_name,
      :status,
      :lease_started_at,
      :lease_expires_at,
      :last_seen_at,
      :stale_after_ms,
      :stale_checked_at,
      :stale_at,
      :stale_reason,
      :paused_at,
      :paused_by_actor_id,
      :pause_reason,
      :reclaimed_at,
      :reclaimed_by_actor_id,
      :reclaim_reason,
      :released_at,
      :release_reason
    ]
  end

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

  defp validate_nonblank_optional(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and String.trim(value) == "" do
        [{field, "cannot be blank"}]
      else
        []
      end
    end)
  end

  defp normalized_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalized_string(_value), do: nil

  defp stable_id do
    "claim_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp utc_datetime_usec(%DateTime{} = datetime) do
    datetime = DateTime.truncate(datetime, :microsecond)
    %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}
  end
end
