defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddAuditFieldsToSymppProgressEvents do
  use Ecto.Migration

  def change do
    alter table(:sympp_progress_events) do
      add(:idempotency_key, :text)
      add(:idempotency_scope, :text, null: false, default: "direct")
      add(:actor_id, :text)
      add(:actor_type, :text)
      add(:access_grant_id, :text)
      add(:agent_run_id, :text)
      add(:payload, :map)
    end

    create(
      unique_index(:sympp_progress_events, [:work_package_id, :idempotency_scope, :idempotency_key],
        name: :sympp_progress_events_scoped_idempotency_key_unique_index,
        where: "idempotency_key IS NOT NULL"
      )
    )

    create(index(:sympp_progress_events, [:work_package_id, :actor_id]))
    create(index(:sympp_progress_events, [:work_package_id, :agent_run_id]))
  end
end
