defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddDispatchFieldsToSymppWorkRequestPlannedSlices do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_request_planned_slices) do
      add(:work_package_id, references(:sympp_work_packages, type: :text))
      add(:dispatched_at, :utc_datetime_usec)
    end

    create(
      unique_index(:sympp_work_request_planned_slices, [:work_package_id],
        name: :sympp_work_request_planned_slices_work_package_id_unique_index,
        where: "work_package_id IS NOT NULL"
      )
    )
  end
end
