defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppSoloSessions do
  use Ecto.Migration

  def change do
    create table(:sympp_solo_sessions, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:repo, :text, null: false)
      add(:base_branch, :text, null: false)
      add(:workspace_path, :text, null: false)
      add(:caller_id, :text, null: false)
      add(:session_key, :text, null: false)
      add(:title, :text)
      add(:status, :text, null: false, default: "active")
      add(:last_activity_at, :utc_datetime_usec, null: false)
      add(:archived_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_solo_sessions, [:id], name: :sympp_solo_sessions_id_unique_index))

    create(
      unique_index(:sympp_solo_sessions, [:repo, :base_branch, :workspace_path, :caller_id],
        name: :sympp_solo_sessions_current_scope_unique_index,
        where: "status IN ('active', 'paused')"
      )
    )

    create(index(:sympp_solo_sessions, [:status, :last_activity_at], name: :sympp_solo_sessions_status_activity_index))
    create(index(:sympp_solo_sessions, [:repo, :base_branch, :workspace_path, :caller_id], name: :sympp_solo_sessions_scope_index))
  end
end
