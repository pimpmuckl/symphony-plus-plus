defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppGuidanceRequests do
  use Ecto.Migration

  def change do
    create table(:sympp_guidance_requests, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_package_id, references(:sympp_work_packages, type: :text, on_delete: :delete_all), null: false)
      add(:requester_grant_id, references(:sympp_access_grants, type: :text), null: false)
      add(:requested_by, :text, null: false)
      add(:idempotency_key, :text, null: false)
      add(:summary, :text, null: false)
      add(:question, :text, null: false)
      add(:context, :text, null: false)
      add(:status, :text, null: false, default: "open")
      add(:answer, :text)
      add(:answered_by, :text)
      add(:answered_at, :utc_datetime_usec)
      add(:human_info_reason, :text)
      add(:recommended_language, :text)
      add(:blocker_id, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_guidance_requests, [:id], name: :sympp_guidance_requests_id_unique_index))

    create(
      unique_index(:sympp_guidance_requests, [:work_package_id, :requester_grant_id, :idempotency_key],
        name: :sympp_guidance_requests_worker_idempotency_key_unique_index
      )
    )

    create(index(:sympp_guidance_requests, [:work_package_id, :status], name: :sympp_guidance_requests_work_package_status_index))
    create(index(:sympp_guidance_requests, [:requester_grant_id], name: :sympp_guidance_requests_requester_grant_index))
    create(index(:sympp_guidance_requests, [:status, :inserted_at], name: :sympp_guidance_requests_status_inserted_at_index))
  end
end
