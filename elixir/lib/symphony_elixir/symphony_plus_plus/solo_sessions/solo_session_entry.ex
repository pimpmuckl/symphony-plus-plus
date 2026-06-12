defmodule SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.Id
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor

  @entry_kinds ["task_plan", "finding", "progress", "blocker", "decision", "validation_note"]
  @statuses ["recorded", "pending", "in_progress", "completed", "blocked", "open", "resolved"]

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{
          id: String.t() | nil,
          solo_session_id: String.t() | nil,
          entry_kind: String.t() | nil,
          title: String.t() | nil,
          body: String.t() | nil,
          status: String.t() | nil,
          sequence: non_neg_integer() | nil,
          idempotency_key: String.t() | nil,
          payload: map() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_solo_session_entries" do
    field(:solo_session_id, :string)
    field(:entry_kind, :string)
    field(:title, :string)
    field(:body, :string)
    field(:status, :string)
    field(:sequence, :integer)
    field(:idempotency_key, :string)
    field(:payload, :map, default: %{})

    timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
  end

  @spec entry_kinds() :: [String.t()]
  def entry_kinds, do: @entry_kinds

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec create_changeset(map(), keyword()) :: Ecto.Changeset.t()
  def create_changeset(attrs, opts) when is_map(attrs) and is_list(opts) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.drop(["id", "solo_session_id", "sequence", "created_at", "inserted_at", "updated_at"])
      |> trim_text_fields(["entry_kind", "title", "body", "status", "idempotency_key"])
      |> normalize_idempotency_key()
      |> put_default("status", "recorded")
      |> put_default("payload", %{})
      |> redact_entry_text()
      |> redact_payload()
      |> Map.put("id", stable_id())
      |> Map.put("solo_session_id", Keyword.fetch!(opts, :solo_session_id))
      |> Map.put("sequence", Keyword.fetch!(opts, :sequence))

    %__MODULE__{}
    |> cast(attrs, [:id, :solo_session_id, :entry_kind, :title, :body, :status, :sequence, :idempotency_key, :payload])
    |> validate_required([:id, :solo_session_id, :entry_kind, :title, :status, :sequence])
    |> validate_inclusion(:entry_kind, @entry_kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:sequence, greater_than_or_equal_to: 1)
    |> validate_nonblank_optional(:idempotency_key)
    |> unique_constraint(:id, name: :sympp_solo_session_entries_id_unique_index)
    |> unique_constraint(:sequence, name: :sympp_solo_session_entries_session_sequence_unique_index)
    |> unique_constraint(:idempotency_key, name: :sympp_solo_session_entries_session_idempotency_key_unique_index)
    |> foreign_key_constraint(:solo_session_id)
  end

  defp redact_entry_text(attrs) do
    attrs
    |> Map.update("title", nil, &Redactor.redact_text/1)
    |> Map.update("body", nil, &Redactor.redact_text/1)
  end

  defp redact_payload(attrs) do
    Map.update(attrs, "payload", %{}, fn
      nil ->
        %{}

      payload ->
        payload
        |> Redactor.json_safe()
        |> Redactor.redact_output()
    end)
  end

  defp normalize_idempotency_key(attrs) do
    Map.update(attrs, "idempotency_key", nil, fn
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end)
  end

  defp put_default(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""] do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp trim_text_fields(attrs, fields) do
    Enum.reduce(fields, attrs, fn field, acc ->
      Map.update(acc, field, nil, &trim_text/1)
    end)
  end

  defp trim_text(value) when is_binary(value), do: String.trim(value)
  defp trim_text(value), do: value

  defp validate_nonblank_optional(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and String.trim(value) == "" do
        [{field, "cannot be blank"}]
      else
        []
      end
    end)
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp stable_id do
    Id.random("solo_entry")
  end
end
