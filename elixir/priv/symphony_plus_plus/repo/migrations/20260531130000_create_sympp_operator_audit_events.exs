defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppOperatorAuditEvents do
  use Ecto.Migration

  def change do
    create table(:sympp_operator_audit_events, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:actor_id, :text, null: false)
      add(:actor_role, :text, null: false)
      add(:actor_source, :text)
      add(:action, :text, null: false)
      add(:target_type, :text, null: false)
      add(:target_id, :text)
      add(:target_work_request_id, :text)
      add(:target_work_package_id, :text)
      add(:decision, :text, null: false)
      add(:reason, :text, null: false)
      add(:request_metadata, :map, null: false, default: %{})
      add(:tool_metadata, :map, null: false, default: %{})
      add(:created_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:sympp_operator_audit_events, [:action, :created_at]))
    create(index(:sympp_operator_audit_events, [:target_type, :target_id]))
  end
end
