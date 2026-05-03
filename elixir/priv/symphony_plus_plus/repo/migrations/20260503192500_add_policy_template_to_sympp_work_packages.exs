defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddPolicyTemplateToSymppWorkPackages do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_packages) do
      add(:policy_template, :text)
    end
  end
end
