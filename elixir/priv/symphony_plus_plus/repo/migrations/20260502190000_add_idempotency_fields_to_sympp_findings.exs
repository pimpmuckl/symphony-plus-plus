defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddIdempotencyFieldsToSymppFindings do
  use Ecto.Migration

  def change do
    alter table(:sympp_findings) do
      add(:idempotency_key, :text)
      add(:access_grant_id, :text)
    end

    create(
      unique_index(:sympp_findings, [:work_package_id, :access_grant_id, :idempotency_key],
        name: :sympp_findings_scoped_idempotency_key_unique_index
      )
    )
  end
end
