defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddHiddenWorkPackageIdsToSymppOperatorSettings do
  use Ecto.Migration

  def change do
    alter table(:sympp_operator_settings) do
      add(:hidden_work_package_ids, :text, null: false, default: "[]")
    end
  end
end
