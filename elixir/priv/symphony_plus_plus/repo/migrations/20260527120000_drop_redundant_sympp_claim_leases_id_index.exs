defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.DropRedundantSymppClaimLeasesIdIndex do
  use Ecto.Migration

  def up do
    drop_if_exists(unique_index(:sympp_claim_leases, [:id], name: :sympp_claim_leases_id_unique_index))
  end

  def down do
    create_if_not_exists(unique_index(:sympp_claim_leases, [:id], name: :sympp_claim_leases_id_unique_index))
  end
end
