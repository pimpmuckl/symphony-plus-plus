defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppWorkRequestClarificationDecisions do
  use Ecto.Migration

  def change do
    create table(:sympp_work_request_clarification_questions, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_request_id, references(:sympp_work_requests, type: :text, on_delete: :delete_all), null: false)
      add(:sequence, :integer, null: false)
      add(:category, :text, null: false)
      add(:question, :text, null: false)
      add(:why_needed, :text, null: false)
      add(:status, :text, null: false, default: "open")
      add(:asked_by_agent_run_id, :text)
      add(:answer, :text)
      add(:answered_by, :text)
      add(:answered_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_work_request_clarification_questions, [:id], name: :sympp_work_request_questions_id_unique_index))

    create(unique_index(:sympp_work_request_clarification_questions, [:work_request_id, :sequence], name: :sympp_work_request_questions_work_request_sequence_unique_index))

    create(index(:sympp_work_request_clarification_questions, [:work_request_id, :status, :sequence], name: :sympp_work_request_questions_work_request_status_index))

    create table(:sympp_work_request_decision_logs, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_request_id, references(:sympp_work_requests, type: :text, on_delete: :delete_all), null: false)
      add(:sequence, :integer, null: false)
      add(:source_type, :text, null: false)
      add(:source_id, :text)
      add(:decision, :text, null: false)
      add(:rationale, :text, null: false)
      add(:scope_impact, :text, null: false)
      add(:created_by, :text, null: false)
      add(:created_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_work_request_decision_logs, [:id], name: :sympp_work_request_decision_logs_id_unique_index))

    create(unique_index(:sympp_work_request_decision_logs, [:work_request_id, :sequence], name: :sympp_work_request_decision_logs_work_request_sequence_unique_index))

    create(index(:sympp_work_request_decision_logs, [:work_request_id, :source_type, :sequence], name: :sympp_work_request_decision_logs_work_request_source_index))
  end
end
