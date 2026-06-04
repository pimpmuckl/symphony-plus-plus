defmodule SymphonyElixir.SymphonyPlusPlus.Repo.Migrations.CreateSymppProductTree do
  use Ecto.Migration

  def change do
    create table(:sympp_product_tree_nodes, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_request_id, references(:sympp_work_requests, type: :text, on_delete: :delete_all), null: false)
      add(:parent_id, references(:sympp_product_tree_nodes, type: :text, on_delete: :delete_all))
      add(:title, :text, null: false)
      add(:description, :text)
      add(:node_kind, :text)
      add(:completion_mark, :text, null: false, default: "unknown")
      add(:metadata, :map, null: false, default: %{})
      add(:position, :integer, null: false, default: 0)
      add(:created_by, :text)
      add(:created_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:sympp_product_tree_nodes, [:work_request_id, :parent_id, :position], name: :sympp_product_tree_nodes_parent_order_index))
    create(index(:sympp_product_tree_nodes, [:work_request_id], name: :sympp_product_tree_nodes_work_request_index))

    create table(:sympp_product_tree_slice_links, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_request_id, references(:sympp_work_requests, type: :text, on_delete: :delete_all), null: false)
      add(:product_tree_node_id, references(:sympp_product_tree_nodes, type: :text, on_delete: :delete_all), null: false)
      add(:planned_slice_id, references(:sympp_work_request_planned_slices, type: :text, on_delete: :delete_all), null: false)
      add(:role, :text, null: false, default: "implementation_slice")
      add(:position, :integer, null: false, default: 0)
      add(:created_by, :text)
      add(:created_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_product_tree_slice_links, [:planned_slice_id], name: :sympp_product_tree_slice_links_planned_slice_unique_index))
    create(index(:sympp_product_tree_slice_links, [:work_request_id, :product_tree_node_id, :position], name: :sympp_product_tree_slice_links_node_order_index))

    create table(:sympp_product_tree_dependency_edges, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_request_id, references(:sympp_work_requests, type: :text, on_delete: :delete_all), null: false)
      add(:source_kind, :text, null: false)
      add(:source_id, :text, null: false)
      add(:target_kind, :text, null: false)
      add(:target_id, :text, null: false)
      add(:kind, :text, null: false)
      add(:reason, :text)
      add(:decision_ref, :map)
      add(:created_by, :text)
      add(:created_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:sympp_product_tree_dependency_edges, [:work_request_id, :source_kind, :source_id], name: :sympp_product_tree_dependency_edges_source_index))
    create(index(:sympp_product_tree_dependency_edges, [:work_request_id, :target_kind, :target_id], name: :sympp_product_tree_dependency_edges_target_index))

    create table(:sympp_product_tree_revisions, primary_key: false) do
      add(:id, :text, primary_key: true, null: false)
      add(:work_request_id, references(:sympp_work_requests, type: :text, on_delete: :delete_all), null: false)
      add(:revision_number, :integer, null: false)
      add(:tree_snapshot, :map, null: false, default: %{})
      add(:reason, :text, null: false)
      add(:decision_ref, :map)
      add(:created_by, :text)
      add(:created_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:sympp_product_tree_revisions, [:work_request_id, :revision_number], name: :sympp_product_tree_revisions_work_request_revision_unique_index))
    create(index(:sympp_product_tree_revisions, [:work_request_id, :revision_number], name: :sympp_product_tree_revisions_work_request_index))
  end
end
