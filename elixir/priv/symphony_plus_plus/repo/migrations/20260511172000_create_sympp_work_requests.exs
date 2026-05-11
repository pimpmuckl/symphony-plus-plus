defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppWorkRequests do
  use Ecto.Migration

  def change do
    create table(:sympp_work_requests, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:title, :text, null: false)
      add(:repo, :text, null: false)
      add(:base_branch, :text, null: false)
      add(:work_type, :text, null: false)
      add(:human_description, :text, null: false)
      add(:constraints, :map, null: false, default: %{})
      add(:desired_dispatch_shape, :text, null: false)
      add(:status, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_work_requests, [:id], name: :sympp_work_requests_id_unique_index))
    create(index(:sympp_work_requests, [:status], name: :sympp_work_requests_status_index))
    create(index(:sympp_work_requests, [:repo, :base_branch], name: :sympp_work_requests_repo_base_branch_index))

    create(index(:sympp_work_requests, [:status, :repo, :base_branch], name: :sympp_work_requests_status_repo_base_branch_index))
  end
end
