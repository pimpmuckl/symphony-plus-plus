defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppAccessGrants do
  use Ecto.Migration

  def change do
    create table(:sympp_access_grants, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_package_id, references(:sympp_work_packages, type: :text, on_delete: :delete_all), null: false)
      add(:display_key, :text, null: false)
      add(:secret_hash, :text, null: false)
      add(:grant_role, :text, null: false)
      add(:capabilities, :text, null: false, default: "[]")
      add(:expires_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      add(:claimed_at, :utc_datetime_usec)
      add(:claimed_by, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_access_grants, [:id], name: :sympp_access_grants_id_unique_index))
    create(unique_index(:sympp_access_grants, [:secret_hash], name: :sympp_access_grants_secret_hash_unique_index))
    create(index(:sympp_access_grants, [:work_package_id]))
    create(index(:sympp_access_grants, [:display_key]))
    create(index(:sympp_access_grants, [:grant_role]))
  end
end
