defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddDeliveryRepoToSymppWorkRequestPlannedSlices do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_request_planned_slices) do
      add(:delivery_repo, :text)
    end
  end
end
