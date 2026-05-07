defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppWorkPackages do
  use Ecto.Migration

  def change do
    create table(:sympp_work_packages, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:kind, :text, null: false)
      add(:title, :text, null: false)
      add(:repo, :text, null: false)
      add(:base_branch, :text, null: false)
      add(:branch_pattern, :text)
      add(:product_description, :text)
      add(:engineering_scope, :text)
      add(:acceptance_criteria, :text, null: false, default: "[]")
      add(:status, :text, null: false)
      add(:parent_id, :text)
      add(:owner_id, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_work_packages, [:id], name: :sympp_work_packages_id_unique_index))
    create(index(:sympp_work_packages, [:status]))
    create(index(:sympp_work_packages, [:kind]))
    create(index(:sympp_work_packages, [:parent_id]))
  end
end
