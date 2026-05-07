defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppPhasesAndPhaseGrants do
  use Ecto.Migration

  def change do
    create table(:sympp_phases, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:title, :text, null: false)
      add(:description, :text)
      add(:status, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_phases, [:id], name: :sympp_phases_id_unique_index))
    create(index(:sympp_phases, [:status]))

    alter table(:sympp_work_packages) do
      add(:phase_id, references(:sympp_phases, type: :text, on_delete: :nilify_all))
    end

    alter table(:sympp_access_grants) do
      add(:phase_id, references(:sympp_phases, type: :text, on_delete: :delete_all))
    end

    create(index(:sympp_work_packages, [:phase_id]))
    create(index(:sympp_access_grants, [:phase_id]))
  end
end
