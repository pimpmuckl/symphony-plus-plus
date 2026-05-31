defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppWorkRequestRepoScopes do
  use Ecto.Migration

  def up do
    create table(:sympp_work_request_repo_scopes, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_request_id, references(:sympp_work_requests, type: :text, on_delete: :delete_all), null: false)
      add(:repo, :text, null: false)
      add(:base_branch, :text)
      add(:scope_key, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:sympp_work_request_repo_scopes, [:work_request_id, :scope_key],
        name: :sympp_work_request_repo_scopes_work_request_scope_key_unique_index
      )
    )

    create(index(:sympp_work_request_repo_scopes, [:work_request_id]))
    create(index(:sympp_work_request_repo_scopes, [:repo, :base_branch]))

    backfill_primary_repo_scopes()
  end

  def down do
    drop(table(:sympp_work_request_repo_scopes))
  end

  defp backfill_primary_repo_scopes do
    execute("""
    INSERT OR IGNORE INTO sympp_work_request_repo_scopes (
      id,
      work_request_id,
      repo,
      base_branch,
      scope_key,
      inserted_at,
      updated_at
    )
    SELECT
      'wrrs_' || id || '_primary',
      id,
      trim(repo),
      NULLIF(trim(base_branch), ''),
      'repo:' || trim(repo) || ':' || COALESCE(NULLIF(trim(base_branch), ''), ''),
      inserted_at,
      updated_at
    FROM sympp_work_requests
    WHERE repo IS NOT NULL
      AND trim(repo) != ''
    """)
  end
end
