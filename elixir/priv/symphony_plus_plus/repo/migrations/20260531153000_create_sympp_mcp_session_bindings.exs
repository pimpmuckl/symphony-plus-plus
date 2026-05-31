defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppMcpSessionBindings do
  use Ecto.Migration

  def change do
    create table(:sympp_mcp_session_bindings, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:client_key_hash, :text, null: false)
      add(:initialized, :boolean, null: false, default: false)
      add(:recoverable, :boolean, null: false, default: false)
      add(:recovery_kind, :text)
      add(:access_grant_id, references(:sympp_access_grants, type: :text, on_delete: :nilify_all))
      add(:claim_lease_id, references(:sympp_claim_leases, type: :text, on_delete: :nilify_all))
      add(:work_package_id, :text)
      add(:phase_id, :text)
      add(:grant_role, :text)
      add(:claimed_by, :text)
      add(:actor_kind, :text)
      add(:actor_id, :text)
      add(:actor_display_name, :text)
      add(:last_seen_at, :utc_datetime_usec, null: false)
      add(:last_rehydrated_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:sympp_mcp_session_bindings, [:client_key_hash], name: :sympp_mcp_session_bindings_client_key_hash_index))
    create(index(:sympp_mcp_session_bindings, [:access_grant_id], name: :sympp_mcp_session_bindings_access_grant_index))
    create(index(:sympp_mcp_session_bindings, [:claim_lease_id], name: :sympp_mcp_session_bindings_claim_lease_index))
    create(index(:sympp_mcp_session_bindings, [:work_package_id], name: :sympp_mcp_session_bindings_work_package_index))
    create(index(:sympp_mcp_session_bindings, [:last_seen_at], name: :sympp_mcp_session_bindings_last_seen_at_index))
  end
end
