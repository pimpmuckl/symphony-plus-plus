defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddWorktreeTargetRepoRootToSymppWorkPackages do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_packages) do
      add(:worktree_target_repo_root, :text)
    end
  end
end
