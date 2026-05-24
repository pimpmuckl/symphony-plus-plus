defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddCompletionSourceToSymppWorkRequests do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_requests) do
      add(:completion_source, :string)
    end
  end
end
