defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree.Revision do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Attrs

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_request_id: String.t() | nil,
          revision_number: pos_integer() | nil,
          tree_snapshot: map() | nil,
          reason: String.t() | nil,
          decision_ref: map() | nil,
          created_by: String.t() | nil,
          created_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_product_tree_revisions" do
    field(:work_request_id, :string)
    field(:revision_number, :integer)
    field(:tree_snapshot, :map, default: %{})
    field(:reason, :string)
    field(:decision_ref, :map)
    field(:created_by, :string)
    field(:created_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> Attrs.normalize_keys()
      |> redact_attrs()
      |> Attrs.put_new_value("id", Attrs.stable_id("ptr"))
      |> Attrs.put_new_value("tree_snapshot", %{})
      |> Attrs.put_new_value("created_at", DateTime.utc_now(:microsecond))

    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :work_request_id,
      :revision_number,
      :tree_snapshot,
      :reason,
      :decision_ref,
      :created_by,
      :created_at
    ])
    |> validate_required([:id, :work_request_id, :revision_number, :tree_snapshot, :reason, :created_at])
    |> validate_number(:revision_number, greater_than: 0)
    |> unique_constraint(:id, name: :sympp_product_tree_revisions_id_unique_index)
    |> unique_constraint([:work_request_id, :revision_number],
      name: :sympp_product_tree_revisions_work_request_revision_unique_index
    )
    |> foreign_key_constraint(:work_request_id)
  end

  defp redact_attrs(attrs) do
    attrs
    |> Map.update("reason", nil, &Redactor.redact_text/1)
    |> Map.update("created_by", nil, &Redactor.redact_text/1)
    |> Map.update("decision_ref", nil, &(Redactor.redact(&1) |> Redactor.json_safe()))
    |> Map.update("tree_snapshot", %{}, &(Redactor.redact(&1) |> Redactor.json_safe()))
  end
end
