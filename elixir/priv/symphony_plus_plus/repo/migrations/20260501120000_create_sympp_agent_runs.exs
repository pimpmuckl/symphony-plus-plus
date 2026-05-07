defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppAgentRuns do
  use Ecto.Migration

  def change do
    create table(:sympp_agent_runs, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_package_id, references(:sympp_work_packages, type: :text, on_delete: :delete_all), null: false)
      add(:access_grant_id, references(:sympp_access_grants, type: :text, on_delete: :nilify_all))
      add(:actor_id, :text)
      add(:status, :text, null: false)
      add(:attempt, :integer, null: false, default: 0)
      add(:worker_host, :text)
      add(:worker_task_handle, :text)
      add(:workspace_path, :text)
      add(:session_id, :text)
      add(:codex_input_tokens, :integer, null: false, default: 0)
      add(:codex_output_tokens, :integer, null: false, default: 0)
      add(:codex_total_tokens, :integer, null: false, default: 0)
      add(:turn_count, :integer, null: false, default: 0)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:last_seen_at, :utc_datetime_usec, null: false)
      add(:finished_at, :utc_datetime_usec)
      add(:reason, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_agent_runs, [:id], name: :sympp_agent_runs_id_unique_index))
    create(index(:sympp_agent_runs, [:work_package_id]))
    create(index(:sympp_agent_runs, [:access_grant_id]))

    create(
      unique_index(:sympp_agent_runs, [:work_package_id],
        where: "status IN ('starting', 'running', 'retrying')",
        name: :sympp_agent_runs_one_active_per_work_package_index
      )
    )
  end
end
