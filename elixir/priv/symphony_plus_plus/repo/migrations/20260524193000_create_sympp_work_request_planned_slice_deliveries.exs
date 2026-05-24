defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppWorkRequestPlannedSliceDeliveries do
  use Ecto.Migration

  def change do
    create table(:sympp_work_request_planned_slice_deliveries, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_request_id, references(:sympp_work_requests, type: :text, on_delete: :delete_all), null: false)

      add(:planned_slice_id, references(:sympp_work_request_planned_slices, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:outcome, :text, null: false)
      add(:idempotency_key, :text, null: false)
      add(:recorded_by, :text)
      add(:recorded_at, :utc_datetime_usec, null: false)
      add(:pr_url, :text)
      add(:pr_number, :integer)
      add(:pr_repository, :text)
      add(:pr_merged_at, :utc_datetime_usec)
      add(:merge_commit_sha, :text)
      add(:no_pr_evidence, :text)
      add(:successor_planned_slice_id, references(:sympp_work_request_planned_slices, type: :text))
      add(:successor_work_package_id, references(:sympp_work_packages, type: :text))
      add(:superseded_reason, :text)
      add(:abandoned_rationale, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:sympp_work_request_planned_slice_deliveries, [:id],
        name: :sympp_work_request_planned_slice_deliveries_id_unique_index
      )
    )

    create(
      unique_index(:sympp_work_request_planned_slice_deliveries, [:planned_slice_id],
        name: :sympp_work_request_planned_slice_deliveries_planned_slice_id_unique_index
      )
    )

  end
end
