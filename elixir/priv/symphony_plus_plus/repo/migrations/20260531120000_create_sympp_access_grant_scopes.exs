defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppAccessGrantScopes do
  use Ecto.Migration

  def up do
    create table(:sympp_access_grant_scopes, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:access_grant_id, references(:sympp_access_grants, type: :text, on_delete: :delete_all), null: false)
      add(:scope_type, :text, null: false)
      add(:scope_key, :text, null: false)
      add(:scope_id, :text)
      add(:repo, :text)
      add(:base_branch, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_access_grant_scopes, [:access_grant_id, :scope_key], name: :sympp_access_grant_scopes_grant_key_unique_index))

    create(index(:sympp_access_grant_scopes, [:access_grant_id]))
    create(index(:sympp_access_grant_scopes, [:scope_type, :scope_id]))
    create(index(:sympp_access_grant_scopes, [:repo, :base_branch]))

    backfill_scope_rows()
  end

  def down do
    drop(table(:sympp_access_grant_scopes))
  end

  defp backfill_scope_rows do
    execute("""
    INSERT OR IGNORE INTO sympp_access_grant_scopes (
      id,
      access_grant_id,
      scope_type,
      scope_key,
      scope_id,
      repo,
      base_branch,
      inserted_at,
      updated_at
    )
    SELECT
      'ags_' || id || '_work_package',
      id,
      'work_package',
      'work_package:' || work_package_id,
      work_package_id,
      NULL,
      NULL,
      inserted_at,
      updated_at
    FROM sympp_access_grants
    WHERE grant_role IN ('worker', 'architect')
      AND work_package_id IS NOT NULL
      AND trim(work_package_id) != ''
    """)

    execute("""
    INSERT OR IGNORE INTO sympp_access_grant_scopes (
      id,
      access_grant_id,
      scope_type,
      scope_key,
      scope_id,
      repo,
      base_branch,
      inserted_at,
      updated_at
    )
    SELECT
      'ags_' || id || '_repo',
      id,
      'repo',
      'repo:' || scope_repo || ':' || COALESCE(scope_base_branch, ''),
      NULL,
      scope_repo,
      scope_base_branch,
      inserted_at,
      updated_at
    FROM sympp_access_grants
    WHERE grant_role = 'architect'
      AND scope_repo IS NOT NULL
      AND trim(scope_repo) != ''
    """)

    execute("""
    INSERT OR IGNORE INTO sympp_access_grant_scopes (
      id,
      access_grant_id,
      scope_type,
      scope_key,
      scope_id,
      repo,
      base_branch,
      inserted_at,
      updated_at
    )
    SELECT
      'ags_' || grants.id || '_work_request_' || slices.work_request_id,
      grants.id,
      'work_request',
      'work_request:' || slices.work_request_id,
      slices.work_request_id,
      NULL,
      NULL,
      grants.inserted_at,
      grants.updated_at
    FROM sympp_access_grants AS grants
    JOIN sympp_work_request_planned_slices AS slices
      ON slices.work_package_id = grants.work_package_id
    WHERE grants.grant_role = 'architect'
      AND slices.work_request_id IS NOT NULL
      AND trim(slices.work_request_id) != ''
    """)
  end
end
