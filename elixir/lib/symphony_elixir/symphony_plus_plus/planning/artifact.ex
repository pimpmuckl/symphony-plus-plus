defmodule SymphonyElixir.SymphonyPlusPlus.Planning.Artifact do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_package_id: String.t() | nil,
          path: String.t() | nil,
          title: String.t() | nil,
          kind: String.t() | nil,
          uri: String.t() | nil,
          metadata: map() | nil,
          sequence: non_neg_integer() | nil,
          created_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_artifacts" do
    field(:work_package_id, :string)
    field(:path, :string)
    field(:title, :string)
    field(:kind, :string)
    field(:uri, :string)
    field(:metadata, :map, default: %{})
    field(:sequence, :integer)
    field(:created_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("id", stable_id("artifact"))
      |> put_new_value("kind", "reference")
      |> put_new_value("created_at", DateTime.utc_now(:microsecond))

    %__MODULE__{}
    |> cast(attrs, [:id, :work_package_id, :path, :title, :kind, :uri, :metadata, :sequence, :created_at])
    |> validate_required([:id, :work_package_id, :path, :title, :kind, :sequence, :created_at])
    |> validate_number(:sequence, greater_than_or_equal_to: 1)
    |> unique_constraint(:id, name: :sympp_artifacts_id_unique_index)
    |> foreign_key_constraint(:work_package_id)
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

  defp stable_id(prefix) do
    prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
