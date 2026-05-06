defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddMetadataToSymppArtifacts do
  use Ecto.Migration

  def change do
    alter table(:sympp_artifacts) do
      add(:metadata, :map)
    end
  end
end
