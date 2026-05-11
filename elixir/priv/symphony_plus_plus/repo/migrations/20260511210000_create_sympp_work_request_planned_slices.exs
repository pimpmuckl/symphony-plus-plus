defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppWorkRequestPlannedSlices do
  use Ecto.Migration

  def change do
    create table(:sympp_work_request_planned_slices, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_request_id, references(:sympp_work_requests, type: :text, on_delete: :delete_all), null: false)
      add(:sequence, :integer, null: false)
      add(:title, :text, null: false)
      add(:goal, :text, null: false)
      add(:work_package_kind, :text, null: false)
      add(:target_base_branch, :text, null: false)
      add(:branch_pattern, :text)
      add(:owned_file_globs, :text, null: false, default: "[]")
      add(:forbidden_file_globs, :text, null: false, default: "[]")
      add(:acceptance_criteria, :text, null: false, default: "[]")
      add(:validation_steps, :text, null: false, default: "[]")
      add(:review_lanes, :text, null: false, default: "[]")
      add(:stop_conditions, :text, null: false, default: "[]")
      add(:status, :text, null: false, default: "planned")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_work_request_planned_slices, [:id], name: :sympp_work_request_planned_slices_id_unique_index))

    create(
      unique_index(:sympp_work_request_planned_slices, [:work_request_id, :sequence],
        name: :sympp_work_request_planned_slices_work_request_sequence_unique_index
      )
    )

    create(
      index(:sympp_work_request_planned_slices, [:work_request_id, :status, :sequence],
        name: :sympp_work_request_planned_slices_work_request_status_index
      )
    )
  end
end
