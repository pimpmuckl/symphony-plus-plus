defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppOperatorSettings do
  use Ecto.Migration

  def change do
    create table(:sympp_operator_settings, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_request_archive_after_days, :integer, null: false, default: 14)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_operator_settings, [:id], name: :sympp_operator_settings_id_unique_index))
  end
end
