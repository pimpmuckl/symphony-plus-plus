defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt
  alias SymphonyElixir.SymphonyPlusPlus.Id

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @statuses ["open", "answered", "closed"]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_request_id: String.t() | nil,
          sequence: integer() | nil,
          category: String.t() | nil,
          question: String.t() | nil,
          why_needed: String.t() | nil,
          decision_prompt: map() | nil,
          status: String.t() | nil,
          asked_by_agent_run_id: String.t() | nil,
          answer: String.t() | nil,
          answered_by: String.t() | nil,
          answered_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_work_request_clarification_questions" do
    field(:work_request_id, :string)
    field(:sequence, :integer)
    field(:category, :string)
    field(:question, :string)
    field(:why_needed, :string)
    field(:decision_prompt, :map)
    field(:status, :string)
    field(:asked_by_agent_run_id, :string)
    field(:answer, :string)
    field(:answered_by, :string)
    field(:answered_at, :utc_datetime_usec)

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
      |> put_new_value("status", "open")

    %__MODULE__{}
    |> changeset(attrs)
    |> unique_constraint(:id, name: :sympp_work_request_questions_id_unique_index)
  end

  @spec answer_changeset(map()) :: Ecto.Changeset.t()
  def answer_changeset(attrs) do
    %__MODULE__{}
    |> cast(normalize_keys(attrs), [:answer, :answered_by, :answered_at])
    |> validate_required([:answer, :answered_by, :answered_at])
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = question, attrs) do
    question
    |> cast(normalize_keys(attrs), [
      :id,
      :work_request_id,
      :sequence,
      :category,
      :question,
      :why_needed,
      :decision_prompt,
      :status,
      :asked_by_agent_run_id,
      :answer,
      :answered_by,
      :answered_at
    ])
    |> validate_required([
      :id,
      :work_request_id,
      :sequence,
      :category,
      :question,
      :why_needed,
      :status
    ])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> normalize_decision_prompt()
    |> validate_decision_prompt()
  end

  defp normalize_decision_prompt(changeset) do
    case get_change(changeset, :decision_prompt) do
      nil ->
        changeset

      prompt ->
        case HumanDecisionPrompt.normalize(prompt) do
          {:ok, normalized} -> put_change(changeset, :decision_prompt, normalized)
          {:error, _reason} -> changeset
        end
    end
  end

  defp validate_decision_prompt(changeset) do
    validate_change(changeset, :decision_prompt, fn :decision_prompt, prompt ->
      case HumanDecisionPrompt.normalize(prompt) do
        {:ok, _normalized} -> []
        {:error, reason} -> [decision_prompt: HumanDecisionPrompt.error_message(reason)]
      end
    end)
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
    Id.random("wrq")
  end
end
