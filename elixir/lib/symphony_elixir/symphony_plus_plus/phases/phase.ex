defmodule SymphonyElixir.SymphonyPlusPlus.Phases.Phase do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @statuses ["active", "closed"]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          status: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_phases" do
    field(:title, :string)
    field(:description, :string)
    field(:status, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("id", stable_id())
      |> put_new_value("status", "active")

    %__MODULE__{}
    |> changeset(attrs)
    |> unique_constraint(:id, name: :sympp_phases_id_unique_index)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = phase, attrs) do
    phase
    |> cast(normalize_keys(attrs), [:id, :title, :description, :status])
    |> validate_required([:id, :title, :status])
    |> validate_inclusion(:status, @statuses)
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

  defp stable_id do
    "phase_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
