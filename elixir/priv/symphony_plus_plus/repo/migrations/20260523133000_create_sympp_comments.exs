defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppComments do
  use Ecto.Migration

  def change do
    create table(:sympp_comments, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:target_kind, :text, null: false)
      add(:target_id, :text, null: false)
      add(:body, :text, null: false)
      add(:source_type, :text, null: false)
      add(:author_name, :text, null: false)
      add(:status, :text, null: false, default: "open")
      add(:resolved_by, :text)
      add(:resolved_source_type, :text)
      add(:resolved_at, :utc_datetime_usec)
      add(:resolution_note, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_comments, [:id], name: :sympp_comments_id_unique_index))
    create(index(:sympp_comments, [:target_kind, :target_id, :status], name: :sympp_comments_target_status_index))
    create(index(:sympp_comments, [:target_kind, :target_id, :inserted_at], name: :sympp_comments_target_inserted_at_index))
    create(index(:sympp_comments, [:status, :inserted_at], name: :sympp_comments_status_inserted_at_index))
  end
end
