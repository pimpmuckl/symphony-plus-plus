defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.StringList
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @statuses ["planned", "approved", "dispatched", "skipped"]

  @list_fields [
    :owned_file_globs,
    :forbidden_file_globs,
    :acceptance_criteria,
    :validation_steps,
    :review_lanes,
    :stop_conditions
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_request_id: String.t() | nil,
          sequence: integer() | nil,
          title: String.t() | nil,
          goal: String.t() | nil,
          work_package_kind: String.t() | nil,
          target_base_branch: String.t() | nil,
          branch_pattern: String.t() | nil,
          owned_file_globs: [String.t()] | nil,
          forbidden_file_globs: [String.t()] | nil,
          acceptance_criteria: [String.t()] | nil,
          validation_steps: [String.t()] | nil,
          review_lanes: [String.t()] | nil,
          stop_conditions: [String.t()] | nil,
          status: String.t() | nil,
          work_package_id: String.t() | nil,
          dispatched_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_work_request_planned_slices" do
    field(:work_request_id, :string)
    field(:sequence, :integer)
    field(:title, :string)
    field(:goal, :string)
    field(:work_package_kind, :string)
    field(:target_base_branch, :string)
    field(:branch_pattern, :string)
    field(:owned_file_globs, StringList, default: [])
    field(:forbidden_file_globs, StringList, default: [])
    field(:acceptance_criteria, StringList, default: [])
    field(:validation_steps, StringList, default: [])
    field(:review_lanes, StringList, default: [])
    field(:stop_conditions, StringList, default: [])
    field(:status, :string)
    field(:work_package_id, :string)
    field(:dispatched_at, :utc_datetime_usec)

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
      |> put_new_value("status", "planned")
      |> put_new_list_values()

    %__MODULE__{}
    |> changeset(attrs)
    |> validate_create_status()
    |> unique_constraint(:id, name: :sympp_work_request_planned_slices_id_unique_index)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = planned_slice, attrs) do
    planned_slice
    |> cast(normalize_keys(attrs), [
      :id,
      :work_request_id,
      :sequence,
      :title,
      :goal,
      :work_package_kind,
      :target_base_branch,
      :branch_pattern,
      :owned_file_globs,
      :forbidden_file_globs,
      :acceptance_criteria,
      :validation_steps,
      :review_lanes,
      :stop_conditions,
      :status
    ])
    |> validate_required([
      :id,
      :work_request_id,
      :sequence,
      :title,
      :goal,
      :work_package_kind,
      :target_base_branch,
      :owned_file_globs,
      :forbidden_file_globs,
      :acceptance_criteria,
      :validation_steps,
      :review_lanes,
      :stop_conditions,
      :status
    ])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_inclusion(:work_package_kind, WorkPackage.kinds())
    |> validate_inclusion(:status, @statuses)
  end

  defp validate_create_status(changeset) do
    validate_change(changeset, :status, fn
      :status, "planned" -> []
      :status, _status -> [status: "must be planned on create"]
    end)
  end

  defp put_new_list_values(attrs) do
    Enum.reduce(@list_fields, attrs, fn field, acc -> put_new_value(acc, Atom.to_string(field), []) end)
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
    "wrs_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end
end
