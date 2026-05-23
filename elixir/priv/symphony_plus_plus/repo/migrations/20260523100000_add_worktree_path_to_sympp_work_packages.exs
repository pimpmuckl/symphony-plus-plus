defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddWorktreePathToSymppWorkPackages do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_packages) do
      add(:worktree_path, :text)
    end
  end
end
