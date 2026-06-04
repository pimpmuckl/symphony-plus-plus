defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree.Node do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Attrs

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @completion_marks ["done", "partial", "not_done", "deferred", "unknown"]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_request_id: String.t() | nil,
          parent_id: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          node_kind: String.t() | nil,
          completion_mark: String.t() | nil,
          metadata: map() | nil,
          position: non_neg_integer() | nil,
          created_by: String.t() | nil,
          created_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_product_tree_nodes" do
    field(:work_request_id, :string)
    field(:parent_id, :string)
    field(:title, :string)
    field(:description, :string)
    field(:node_kind, :string)
    field(:completion_mark, :string)
    field(:metadata, :map, default: %{})
    field(:position, :integer)
    field(:created_by, :string)
    field(:created_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec completion_marks() :: [String.t()]
  def completion_marks, do: @completion_marks

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> Attrs.normalize_keys()
      |> redact_attrs()
      |> Attrs.put_new_value("id", Attrs.stable_id("ptn"))
      |> Attrs.put_new_value("completion_mark", "unknown")
      |> Attrs.put_new_value("metadata", %{})
      |> Attrs.put_new_value("position", 0)
      |> Attrs.put_new_value("created_at", DateTime.utc_now(:microsecond))

    %__MODULE__{}
    |> changeset(attrs)
    |> unique_constraint(:id, name: :sympp_product_tree_nodes_id_unique_index)
    |> foreign_key_constraint(:work_request_id)
    |> foreign_key_constraint(:parent_id)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = node, attrs) do
    node
    |> cast(Attrs.normalize_keys(attrs), [
      :id,
      :work_request_id,
      :parent_id,
      :title,
      :description,
      :node_kind,
      :completion_mark,
      :metadata,
      :position,
      :created_by,
      :created_at
    ])
    |> validate_required([:id, :work_request_id, :title, :completion_mark, :metadata, :position, :created_at])
    |> validate_nonblank(:title)
    |> validate_inclusion(:completion_mark, @completion_marks)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_parent_not_self()
    |> validate_json_safe(:metadata)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = node, attrs) do
    node
    |> changeset(redact_present_attrs(attrs))
    |> foreign_key_constraint(:work_request_id)
    |> foreign_key_constraint(:parent_id)
  end

  defp redact_attrs(attrs) do
    attrs
    |> redact_text_field("title")
    |> redact_text_field("description")
    |> redact_text_field("node_kind")
    |> redact_text_field("created_by")
    |> Map.update("metadata", %{}, &(Redactor.redact(&1) |> Redactor.json_safe()))
  end

  defp redact_text_field(attrs, key), do: Map.update(attrs, key, nil, &Redactor.redact_text/1)

  defp redact_present_attrs(attrs) do
    attrs
    |> Attrs.normalize_keys()
    |> redact_present_text_field("title")
    |> redact_present_text_field("description")
    |> redact_present_text_field("node_kind")
    |> redact_present_text_field("created_by")
    |> redact_present_json_field("metadata")
  end

  defp redact_present_text_field(attrs, key) do
    if Map.has_key?(attrs, key), do: Map.update!(attrs, key, &Redactor.redact_text/1), else: attrs
  end

  defp redact_present_json_field(attrs, key) do
    if Map.has_key?(attrs, key), do: Map.update!(attrs, key, &(Redactor.redact(&1) |> Redactor.json_safe())), else: attrs
  end

  defp validate_parent_not_self(changeset) do
    validate_change(changeset, :parent_id, fn :parent_id, parent_id ->
      id = get_field(changeset, :id)
      if is_binary(id) and id == parent_id, do: [parent_id: "cannot point at itself"], else: []
    end)
  end

  defp validate_nonblank(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and String.trim(value) == "", do: [{field, "cannot be blank"}], else: []
    end)
  end

  defp validate_json_safe(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if json_safe_value?(value), do: [], else: [{field, "must be JSON-safe"}]
    end)
  end

  defp json_safe_value?(%{__struct__: _}), do: false
  defp json_safe_value?(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp json_safe_value?(value) when is_list(value), do: Enum.all?(value, &json_safe_value?/1)

  defp json_safe_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_safe_value?(nested) end)
  end

  defp json_safe_value?(_value), do: false
end
