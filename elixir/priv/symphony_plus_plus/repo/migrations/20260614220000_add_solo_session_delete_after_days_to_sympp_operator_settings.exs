defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddSoloSessionDeleteAfterDaysToSymppOperatorSettings do
  use Ecto.Migration

  def change do
    alter table(:sympp_operator_settings) do
      add(:solo_session_delete_after_days, :integer, null: false, default: 30)
    end
  end
end
