defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddProgressEventsCreatedAtIndex do
  use Ecto.Migration

  def change do
    create(index(:sympp_progress_events, [:work_package_id, :created_at], name: :sympp_progress_events_work_package_created_at_index))
  end
end
