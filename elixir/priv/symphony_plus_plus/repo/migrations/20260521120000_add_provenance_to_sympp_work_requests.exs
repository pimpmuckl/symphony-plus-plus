defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.AddProvenanceToSymppWorkRequests do
  use Ecto.Migration

  def change do
    alter table(:sympp_work_requests) do
      add(:creator_kind, :text)
      add(:creator_name, :text)
      add(:created_via, :text)
    end

    create(index(:sympp_work_requests, [:creator_kind], name: :sympp_work_requests_creator_kind_index))
  end
end
