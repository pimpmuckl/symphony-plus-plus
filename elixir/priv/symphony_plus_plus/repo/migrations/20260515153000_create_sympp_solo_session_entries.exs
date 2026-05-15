defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppSoloSessionEntries do
  use Ecto.Migration

  def change do
    create table(:sympp_solo_session_entries, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:solo_session_id, references(:sympp_solo_sessions, type: :text, on_delete: :delete_all), null: false)
      add(:entry_kind, :text, null: false)
      add(:title, :text, null: false)
      add(:body, :text)
      add(:status, :text, null: false, default: "recorded")
      add(:sequence, :integer, null: false)
      add(:idempotency_key, :text)
      add(:payload, :map)

      timestamps(inserted_at: :created_at, type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_solo_session_entries, [:id], name: :sympp_solo_session_entries_id_unique_index))

    create(unique_index(:sympp_solo_session_entries, [:solo_session_id, :sequence], name: :sympp_solo_session_entries_session_sequence_unique_index))

    create(
      unique_index(:sympp_solo_session_entries, [:solo_session_id, :idempotency_key],
        name: :sympp_solo_session_entries_session_idempotency_key_unique_index,
        where: "idempotency_key IS NOT NULL"
      )
    )

    create(index(:sympp_solo_session_entries, [:solo_session_id], name: :sympp_solo_session_entries_session_index))
    create(index(:sympp_solo_session_entries, [:solo_session_id, :entry_kind, :sequence], name: :sympp_solo_session_entries_kind_sequence_index))
  end
end
