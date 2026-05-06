defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddScopeSnapshotToSymppAccessGrants do
  use Ecto.Migration

  def up do
    alter table(:sympp_access_grants) do
      add(:scope_repo, :text)
      add(:scope_base_branch, :text)
    end

    execute("""
    UPDATE sympp_access_grants
    SET scope_repo = (
      SELECT sympp_work_packages.repo
      FROM sympp_work_packages
      WHERE sympp_work_packages.id = sympp_access_grants.work_package_id
    ),
    scope_base_branch = (
      SELECT sympp_work_packages.base_branch
      FROM sympp_work_packages
      WHERE sympp_work_packages.id = sympp_access_grants.work_package_id
    )
    WHERE grant_role = 'architect'
      AND phase_id IS NOT NULL
    """)
  end

  def down do
    alter table(:sympp_access_grants) do
      remove(:scope_base_branch)
      remove(:scope_repo)
    end
  end
end
