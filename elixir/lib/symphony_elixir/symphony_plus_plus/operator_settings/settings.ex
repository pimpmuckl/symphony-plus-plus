defmodule SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @settings_id "local_operator"
  @default_work_request_archive_after_days 14
  @max_work_request_archive_after_days 3650

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{
          id: String.t(),
          work_request_archive_after_days: pos_integer(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_operator_settings" do
    field(:work_request_archive_after_days, :integer, default: @default_work_request_archive_after_days)

    timestamps(type: :utc_datetime_usec)
  end

  @spec settings_id() :: String.t()
  def settings_id, do: @settings_id

  @spec default_work_request_archive_after_days() :: pos_integer()
  def default_work_request_archive_after_days, do: @default_work_request_archive_after_days

  @spec default() :: t()
  def default do
    %__MODULE__{
      id: @settings_id,
      work_request_archive_after_days: @default_work_request_archive_after_days
    }
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(attrs |> normalize_keys() |> Map.put_new("id", @settings_id))
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = settings, attrs) when is_map(attrs) do
    settings
    |> changeset(attrs |> normalize_keys() |> Map.drop(["id", "inserted_at", "updated_at"]))
  end

  defp changeset(settings, attrs) do
    settings
    |> cast(attrs, [:id, :work_request_archive_after_days])
    |> validate_required([:id, :work_request_archive_after_days])
    |> validate_number(:work_request_archive_after_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_work_request_archive_after_days
    )
    |> unique_constraint(:id, name: :sympp_operator_settings_id_unique_index)
  end

  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
