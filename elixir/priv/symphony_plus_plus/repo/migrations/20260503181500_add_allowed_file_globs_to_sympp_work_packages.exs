defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddAllowedFileGlobsToSymppWorkPackages do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_packages) do
      add(:allowed_file_globs, :text, null: false, default: "[]")
    end
  end
end
