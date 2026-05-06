defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddProvenanceToSymppAccessGrants do
  use Ecto.Migration

  def change do
    alter table(:sympp_access_grants) do
      add(:provenance, :text)
    end
  end
end
