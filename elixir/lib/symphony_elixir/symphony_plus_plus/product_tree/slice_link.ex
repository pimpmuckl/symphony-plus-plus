defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree.SliceLink do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Attrs

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @roles ["implementation_slice", "evidence", "oracle", "successor"]

  schema "sympp_product_tree_slice_links" do
    field(:work_request_id, :string)
    field(:product_tree_node_id, :string)
    field(:planned_slice_id, :string)
    field(:role, :string)
    field(:position, :integer)
    field(:created_by, :string)
    field(:created_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec roles() :: [String.t()]
  def roles, do: @roles

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> Attrs.normalize_keys()
      |> Map.update("created_by", nil, &Redactor.redact_text/1)
      |> Attrs.put_new_value("id", Attrs.stable_id("ptsl"))
      |> Attrs.put_new_value("role", "implementation_slice")
      |> Attrs.put_new_value("position", 0)
      |> Attrs.put_new_value("created_at", DateTime.utc_now(:microsecond))

    %__MODULE__{}
    |> cast(attrs, [:id, :work_request_id, :product_tree_node_id, :planned_slice_id, :role, :position, :created_by, :created_at])
    |> validate_required([:id, :work_request_id, :product_tree_node_id, :planned_slice_id, :role, :position, :created_at])
    |> validate_inclusion(:role, @roles)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint(:id, name: :sympp_product_tree_slice_links_id_unique_index)
    |> unique_constraint(:planned_slice_id, name: :sympp_product_tree_slice_links_planned_slice_unique_index)
    |> foreign_key_constraint(:work_request_id)
    |> foreign_key_constraint(:product_tree_node_id)
    |> foreign_key_constraint(:planned_slice_id)
  end
end
