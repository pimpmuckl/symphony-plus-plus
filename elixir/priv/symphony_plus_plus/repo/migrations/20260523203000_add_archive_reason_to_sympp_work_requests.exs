defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddArchiveReasonToSymppWorkRequests do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_requests) do
      add(:archive_reason, :string)
    end
  end
end
