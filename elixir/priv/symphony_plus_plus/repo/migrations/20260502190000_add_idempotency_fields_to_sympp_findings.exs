defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddIdempotencyFieldsToSymppFindings do
  use Ecto.Migration

  def change do
    alter table(:sympp_findings) do
      add(:idempotency_key, :text)
      add(:access_grant_id, :text)
    end

    execute(
      """
      DELETE FROM sympp_findings
      WHERE idempotency_key IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM sympp_findings AS kept
          WHERE kept.work_package_id = sympp_findings.work_package_id
            AND kept.idempotency_key = sympp_findings.idempotency_key
            AND (
              kept.sequence < sympp_findings.sequence
              OR (kept.sequence = sympp_findings.sequence AND kept.id < sympp_findings.id)
            )
        )
      """,
      ""
    )

    create(
      unique_index(:sympp_findings, [:work_package_id, :idempotency_key],
        name: :sympp_findings_scoped_idempotency_key_unique_index
      )
    )
  end
end
