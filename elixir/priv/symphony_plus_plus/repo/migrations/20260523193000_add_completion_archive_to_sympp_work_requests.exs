defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddCompletionArchiveToSymppWorkRequests do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_requests) do
      add(:completed_at, :utc_datetime_usec)
      add(:archived_at, :utc_datetime_usec)
    end
  end
end
