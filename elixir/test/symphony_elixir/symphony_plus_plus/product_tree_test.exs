defmodule SymphonyElixir.SymphonyPlusPlus.ProductTreeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.{DependencyEdge, Node, Revision, SliceLink}
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkRequestRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(Revision)
    repo.delete_all(DependencyEdge)
    repo.delete_all(SliceLink)
    repo.delete_all(Node)
    repo.delete_all(PlannedSlice)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "projects optional nested product nodes with linked and direct slices", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-V3-PRODUCT-TREE", title: "VOD Intelligence Upgrade")
    backend = create_node!(repo, work_request, id: "ptn_backend", title: "Backend", position: 1)

    kraken =
      create_node!(repo, work_request,
        id: "ptn_kraken",
        parent_id: backend.id,
        title: "Kraken P1.1 contract alignment",
        completion_mark: "partial",
        position: 1
      )

    serving =
      create_node!(repo, work_request,
        id: "ptn_serving",
        parent_id: backend.id,
        title: "VOD Intelligence serving substrate",
        completion_mark: "unknown",
        position: 2
      )

    contract_slice = add_slice!(repo, work_request, id: "wrs_contract", title: "Canonical /streams metadata")
    serving_slice = add_slice!(repo, work_request, id: "wrs_serving", title: "stream_score_rollups substrate")
    direct_slice = add_slice!(repo, work_request, id: "wrs_cutover", title: "No pre-P1.1 compatibility")

    assert {:ok, _link} =
             ProductTree.create_slice_link(repo, %{
               work_request_id: work_request.id,
               product_tree_node_id: kraken.id,
               planned_slice_id: contract_slice.id,
               position: 1
             })

    assert {:ok, _link} =
             ProductTree.create_slice_link(repo, %{
               work_request_id: work_request.id,
               product_tree_node_id: serving.id,
               planned_slice_id: serving_slice.id,
               position: 1
             })

    assert {:ok, detail} = Dashboard.work_request_detail(repo, work_request.id)

    assert detail.product_tree.mode == "product_tree"
    assert detail.product_tree.root_node_ids == [backend.id]
    assert detail.product_tree.root_slice_ids == [direct_slice.id]
    assert detail.product_tree.summary.node_count == 3
    assert detail.product_tree.summary.slice_count == 3
    assert detail.product_tree.summary.linked_slice_count == 2

    nodes_by_id = Map.new(detail.product_tree.nodes, &{&1.id, &1})
    assert nodes_by_id[backend.id].child_node_count == 2
    assert nodes_by_id[backend.id].computed_completion_mark == "partial"
    assert nodes_by_id[kraken.id].slice_ids == [contract_slice.id]
    assert nodes_by_id[kraken.id].computed_completion_mark == "partial"
    assert nodes_by_id[serving.id].slice_ids == [serving_slice.id]

    override_node = create_node!(repo, work_request, id: "ptn_override", title: "Manual done with planned slice", completion_mark: "done")
    override_slice = add_slice!(repo, work_request, id: "wrs_override", title: "Still planned execution")

    assert {:ok, _link} =
             ProductTree.create_slice_link(repo, %{
               work_request_id: work_request.id,
               product_tree_node_id: override_node.id,
               planned_slice_id: override_slice.id,
               position: 1
             })

    assert %{nodes: override_nodes} = ProductTree.project(repo, work_request.id, [%{"id" => override_slice.id, "operational_state" => %{"key" => "planned"}}])
    assert Map.new(override_nodes, &{&1.id, &1})[override_node.id].computed_completion_mark == "partial"

    projected =
      ProductTree.project(repo, work_request.id, [
        %{"id" => contract_slice.id, "operational_state" => %{"key" => "blocked"}},
        %{"id" => serving_slice.id, "operational_state" => %{"key" => "active"}},
        %{"id" => direct_slice.id, "operational_state" => %{"key" => "needs_attention"}}
      ])

    projected_nodes_by_id = Map.new(projected.nodes, &{&1.id, &1})
    assert projected_nodes_by_id[kraken.id].attention_count == 1
    assert projected_nodes_by_id[backend.id].attention_count == 1
    assert projected_nodes_by_id[kraken.id].blocker_count == 1
    assert projected_nodes_by_id[backend.id].blocker_count == 1
    assert projected.summary.attention_count == 2
    assert projected.summary.blocker_count == 1
  end

  test "rejects cross-WorkRequest product tree relationships", %{repo: repo} do
    left = create_work_request!(repo, id: "WR-V3-SCOPE-LEFT", title: "Left")
    right = create_work_request!(repo, id: "WR-V3-SCOPE-RIGHT", title: "Right")
    left_node = create_node!(repo, left, id: "ptn_left", title: "Left node")
    right_node = create_node!(repo, right, id: "ptn_right", title: "Right node")
    left_slice = add_slice!(repo, left, id: "wrs_left", title: "Left slice")
    right_slice = add_slice!(repo, right, id: "wrs_right", title: "Right slice")

    assert {:error, {:constraint_failed, "product_tree_node_parent_scope"}} =
             ProductTree.create_node(repo, %{work_request_id: right.id, parent_id: left_node.id, title: "Cross parent"})

    assert {:error, {:constraint_failed, "product_tree_slice_link_node_scope"}} =
             ProductTree.create_slice_link(repo, %{
               work_request_id: right.id,
               product_tree_node_id: left_node.id,
               planned_slice_id: right_slice.id
             })

    assert {:error, {:constraint_failed, "product_tree_slice_link_slice_scope"}} =
             ProductTree.create_slice_link(repo, %{
               work_request_id: left.id,
               product_tree_node_id: left_node.id,
               planned_slice_id: right_slice.id
             })

    assert {:error, {:constraint_failed, "product_tree_dependency_source_scope"}} =
             ProductTree.create_dependency_edge(repo, %{
               work_request_id: right.id,
               source_kind: "product_node",
               source_id: left_node.id,
               target_kind: "planned_slice",
               target_id: right_slice.id,
               kind: "depends_on",
               reason: "Cross-request node should not scope."
             })

    assert {:ok, _edge} =
             ProductTree.create_dependency_edge(repo, %{
               work_request_id: right.id,
               source_kind: "product_node",
               source_id: right_node.id,
               target_kind: "planned_slice",
               target_id: right_slice.id,
               kind: "depends_on",
               reason: "Same-request relationships remain valid."
             })

    assert {:ok, _edge} =
             ProductTree.create_dependency_edge(repo, %{
               work_request_id: left.id,
               source_kind: "planned_slice",
               source_id: left_slice.id,
               target_kind: "product_node",
               target_id: left_node.id,
               kind: "validates",
               reason: "Same-request reverse relationships remain valid."
             })
  end

  test "projects simple WorkRequests as direct slices without requiring product nodes", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-V3-HOTFIX", title: "Fix cockpit typo")
    slice = add_slice!(repo, work_request, id: "wrs_hotfix", title: "Patch typo")

    assert {:ok, detail} = Dashboard.work_request_detail(repo, work_request.id)

    assert detail.product_tree.mode == "direct_slices"
    assert detail.product_tree.nodes == []
    assert detail.product_tree.root_node_ids == []
    assert detail.product_tree.root_slice_ids == [slice.id]
    assert detail.product_tree.summary.node_count == 0
    assert detail.product_tree.summary.slice_count == 1
  end

  defp create_work_request!(repo, overrides) do
    attrs =
      %{
        id: "WR-V3-#{System.unique_integer([:positive])}",
        title: "Improve product tree",
        repo: "symphony-plus-plus",
        base_branch: "v3",
        work_type: "feature",
        human_description: "Make WorkRequest progress product-readable.",
        constraints: %{},
        desired_dispatch_shape: "architect_led_feature_branch"
      }
      |> Map.merge(Map.new(overrides))

    assert {:ok, work_request} = WorkRequestRepository.create(repo, attrs)
    work_request
  end

  defp create_node!(repo, work_request, overrides) do
    attrs =
      %{
        work_request_id: work_request.id,
        title: "Product node"
      }
      |> Map.merge(Map.new(overrides))

    assert {:ok, node} = ProductTree.create_node(repo, attrs)
    node
  end

  defp add_slice!(repo, work_request, overrides) do
    attrs =
      %{
        title: "Implement slice",
        goal: "Deliver one product tree slice.",
        work_package_kind: "mcp",
        target_base_branch: work_request.base_branch,
        branch_pattern: "feat/v3-product-tree",
        owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/product_tree/*.ex"],
        forbidden_file_globs: [],
        acceptance_criteria: ["Slice is represented in the product tree."],
        validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/product_tree_test.exs"],
        review_lanes: ["normal"],
        stop_conditions: ["Stop on schema mismatch."]
      }
      |> Map.merge(Map.new(overrides))

    assert {:ok, slice} = WorkRequestRepository.add_planned_slice(repo, work_request.id, attrs)
    slice
  end
end
