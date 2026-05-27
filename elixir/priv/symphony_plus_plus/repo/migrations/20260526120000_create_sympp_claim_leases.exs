defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppClaimLeases do
  use Ecto.Migration

  def change do
    create table(:sympp_claim_leases, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_package_id, references(:sympp_work_packages, type: :text, on_delete: :delete_all), null: false)
      add(:access_grant_id, references(:sympp_access_grants, type: :text, on_delete: :nilify_all))
      add(:claim_group_id, :text, null: false)
      add(:previous_claim_id, references(:sympp_claim_leases, type: :text, on_delete: :nilify_all))
      add(:actor_kind, :text, null: false)
      add(:actor_id, :text, null: false)
      add(:actor_display_name, :text)
      add(:status, :text, null: false)
      add(:lease_started_at, :utc_datetime_usec, null: false)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:last_seen_at, :utc_datetime_usec, null: false)
      add(:stale_after_ms, :integer)
      add(:stale_checked_at, :utc_datetime_usec)
      add(:stale_at, :utc_datetime_usec)
      add(:stale_reason, :text)
      add(:paused_at, :utc_datetime_usec)
      add(:paused_by_actor_id, :text)
      add(:pause_reason, :text)
      add(:reclaimed_at, :utc_datetime_usec)
      add(:reclaimed_by_actor_id, :text)
      add(:reclaim_reason, :text)
      add(:released_at, :utc_datetime_usec)
      add(:release_reason, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_claim_leases, [:id], name: :sympp_claim_leases_id_unique_index))

    create(
      unique_index(:sympp_claim_leases, [:work_package_id],
        where: "status IN ('active', 'paused')",
        name: :sympp_claim_leases_one_current_per_work_package_index
      )
    )
  end
end
