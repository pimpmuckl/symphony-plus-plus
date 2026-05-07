defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddScopeSnapshotToSymppAccessGrants do
  use Ecto.Migration

  def up do
    alter table(:sympp_access_grants) do
      add(:scope_repo, :text)
      add(:scope_base_branch, :text)
    end
  end

  def down do
    alter table(:sympp_access_grants) do
      remove(:scope_base_branch)
      remove(:scope_repo)
    end
  end
end
