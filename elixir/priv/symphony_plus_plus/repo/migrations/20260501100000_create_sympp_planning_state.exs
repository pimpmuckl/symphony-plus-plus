defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppPlanningState do
  use Ecto.Migration

  def change do
    create table(:sympp_plan_nodes, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_package_id, references(:sympp_work_packages, type: :text, on_delete: :delete_all), null: false)
      add(:title, :text, null: false)
      add(:body, :text)
      add(:status, :text, null: false)
      add(:position, :integer, null: false, default: 0)
      add(:created_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_plan_nodes, [:id], name: :sympp_plan_nodes_id_unique_index))
    create(
      unique_index(:sympp_plan_nodes, [:work_package_id, :position],
        name: :sympp_plan_nodes_work_package_position_unique_index
      )
    )

    create(index(:sympp_plan_nodes, [:work_package_id]))
    create(index(:sympp_plan_nodes, [:work_package_id, :position, :created_at]))

    create table(:sympp_findings, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_package_id, references(:sympp_work_packages, type: :text, on_delete: :delete_all), null: false)
      add(:title, :text, null: false)
      add(:body, :text, null: false)
      add(:severity, :text, null: false)
      add(:sequence, :integer, null: false)
      add(:idempotency_key, :text)
      add(:access_grant_id, :text)
      add(:created_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_findings, [:id], name: :sympp_findings_id_unique_index))
    create(
      unique_index(:sympp_findings, [:work_package_id, :sequence],
        name: :sympp_findings_work_package_sequence_unique_index
      )
    )

    create(index(:sympp_findings, [:work_package_id]))
    create(index(:sympp_findings, [:work_package_id, :sequence, :created_at]))
    create(
      unique_index(:sympp_findings, [:work_package_id, :access_grant_id, :idempotency_key],
        name: :sympp_findings_scoped_idempotency_key_unique_index
      )
    )

    create table(:sympp_progress_events, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_package_id, references(:sympp_work_packages, type: :text, on_delete: :delete_all), null: false)
      add(:summary, :text, null: false)
      add(:body, :text)
      add(:status, :text, null: false)
      add(:sequence, :integer, null: false)
      add(:created_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_progress_events, [:id], name: :sympp_progress_events_id_unique_index))
    create(
      unique_index(:sympp_progress_events, [:work_package_id, :sequence],
        name: :sympp_progress_events_work_package_sequence_unique_index
      )
    )

    create(index(:sympp_progress_events, [:work_package_id]))
    create(index(:sympp_progress_events, [:work_package_id, :sequence, :created_at]))

    create table(:sympp_artifacts, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_package_id, references(:sympp_work_packages, type: :text, on_delete: :delete_all), null: false)
      add(:path, :text, null: false)
      add(:title, :text, null: false)
      add(:kind, :text, null: false)
      add(:uri, :text)
      add(:sequence, :integer, null: false)
      add(:created_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_artifacts, [:id], name: :sympp_artifacts_id_unique_index))
    create(
      unique_index(:sympp_artifacts, [:work_package_id, :sequence],
        name: :sympp_artifacts_work_package_sequence_unique_index
      )
    )

    create(index(:sympp_artifacts, [:work_package_id]))
    create(index(:sympp_artifacts, [:work_package_id, :sequence]))
  end
end
