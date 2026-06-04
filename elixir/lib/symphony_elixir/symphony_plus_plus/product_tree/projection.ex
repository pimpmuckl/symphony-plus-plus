defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree.Projection do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.Sanitizer
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.{DependencyEdge, Node, Revision}

  @terminal_completion_keys ["merged", "merged_into_phase", "delivered", "completed_no_pr", "closed", "completed"]
  @not_started_completion_keys ["approved", "planned", "planning", "ready_for_worker"]
  @partial_completion_keys [
    "active",
    "blocked",
    "ci_waiting",
    "claimed",
    "dispatched",
    "implementing",
    "in_progress",
    "merge_ready",
    "merging",
    "needs_attention",
    "needs_closeout",
    "ready_for_architect_merge",
    "ready_for_human_merge",
    "reviewing",
    "started_paused"
  ]

  @spec project(module(), String.t(), [map()]) :: map()
  def project(repo, work_request_id, planned_slice_payloads)
      when is_atom(repo) and is_binary(work_request_id) and is_list(planned_slice_payloads) do
    case ProductTree.tree_for_work_request(repo, work_request_id) do
      {:ok, tree} -> project_tree(tree, planned_slice_payloads)
      {:error, reason} -> unavailable_projection(reason, planned_slice_payloads)
    end
  end

  defp project_tree(%{nodes: nodes, slice_links: slice_links, dependency_edges: dependency_edges, latest_revision: latest_revision}, planned_slice_payloads) do
    planned_slice_ids = Enum.map(planned_slice_payloads, &map_value(&1, "id"))
    linked_slice_ids = slice_links |> Enum.map(& &1.planned_slice_id) |> MapSet.new()
    slices_by_id = Map.new(planned_slice_payloads, &{map_value(&1, "id"), &1})

    projected_nodes =
      nodes
      |> Enum.map(&node_payload(&1, slice_links, slices_by_id))
      |> rollup_node_completion()
      |> Enum.map(&put_child_counts(&1, nodes))

    root_slice_ids =
      planned_slice_ids
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&MapSet.member?(linked_slice_ids, &1))

    %{
      available: true,
      schema_version: "product_tree.v3",
      mode: if(nodes == [], do: "direct_slices", else: "product_tree"),
      root_node_ids: root_node_ids(projected_nodes),
      root_slice_ids: root_slice_ids,
      nodes: projected_nodes,
      dependency_edges: Enum.map(dependency_edges, &dependency_edge_payload/1),
      summary: summary(projected_nodes, root_slice_ids, planned_slice_payloads),
      latest_revision: revision_payload(latest_revision)
    }
  end

  defp node_payload(%Node{} = node, slice_links, slices_by_id) do
    links =
      slice_links
      |> Enum.filter(&(&1.product_tree_node_id == node.id))
      |> Enum.sort_by(&{&1.position || 0, timestamp_sort(&1.created_at), &1.id || ""})

    slice_ids = Enum.map(links, & &1.planned_slice_id)
    linked_slices = slice_ids |> Enum.map(&Map.get(slices_by_id, &1)) |> Enum.reject(&is_nil/1)
    computed_mark = computed_completion_mark(node.completion_mark, linked_slices)

    %{
      id: node.id,
      parent_id: node.parent_id,
      title: Sanitizer.redacted_text(node.title),
      description: Sanitizer.redacted_text(node.description),
      node_kind: Sanitizer.redacted_text(node.node_kind),
      completion_mark: node.completion_mark,
      computed_completion_mark: computed_mark,
      completion_label: completion_label(computed_mark),
      slice_ids: slice_ids,
      child_node_count: 0,
      slice_count: length(slice_ids),
      attention_count: attention_count(linked_slices),
      blocker_count: blocker_count(linked_slices),
      position: node.position || 0,
      metadata: Sanitizer.redacted_json(node.metadata || %{}),
      created_by: Sanitizer.redacted_text(node.created_by),
      created_at: timestamp(node.created_at),
      updated_at: timestamp(node.updated_at)
    }
  end

  defp rollup_node_completion(nodes) do
    children_by_parent_id = Enum.group_by(nodes, & &1.parent_id)

    Enum.map(nodes, &rollup_node(&1, children_by_parent_id, MapSet.new()))
  end

  defp rollup_node(%{id: id} = node, children_by_parent_id, ancestors) when is_binary(id) do
    if MapSet.member?(ancestors, id) do
      node
    else
      children = children_by_parent_id |> Map.get(id, []) |> Enum.map(&rollup_node(&1, children_by_parent_id, MapSet.put(ancestors, id)))
      child_marks = Enum.map(children, & &1.computed_completion_mark)
      mark = rollup_completion_mark(node, child_marks)

      node
      |> Map.put(:computed_completion_mark, mark)
      |> Map.put(:completion_label, completion_label(mark))
      |> Map.put(:attention_count, (node.attention_count || 0) + Enum.sum(Enum.map(children, &(&1.attention_count || 0))))
      |> Map.put(:blocker_count, (node.blocker_count || 0) + Enum.sum(Enum.map(children, &(&1.blocker_count || 0))))
    end
  end

  defp rollup_node(node, _children_by_parent_id, _ancestors), do: node

  defp rollup_completion_mark(node, child_marks) do
    self_marks =
      cond do
        (node.slice_count || 0) > 0 -> [node.computed_completion_mark]
        node.completion_mark in ["done", "partial", "not_done", "deferred"] -> [node.completion_mark]
        true -> []
      end

    case self_marks ++ child_marks do
      [] -> node.computed_completion_mark
      marks -> aggregate_completion_marks(marks)
    end
  end

  defp aggregate_completion_marks(marks) do
    marks = Enum.reject(marks, &is_nil/1)

    cond do
      marks == [] -> "unknown"
      Enum.all?(marks, &(&1 == "done")) -> "done"
      Enum.all?(marks, &(&1 == "deferred")) -> "deferred"
      Enum.all?(marks, &(&1 == "not_done")) -> "not_done"
      Enum.all?(marks, &(&1 in ["done", "deferred"])) -> "done"
      Enum.any?(marks, &(&1 in ["done", "partial", "deferred"])) -> "partial"
      Enum.any?(marks, &(&1 == "not_done")) -> "not_done"
      true -> "unknown"
    end
  end

  defp put_child_counts(node, nodes) do
    Map.put(node, :child_node_count, Enum.count(nodes, &(&1.parent_id == node.id)))
  end

  defp computed_completion_mark("deferred", []), do: "deferred"
  defp computed_completion_mark("done", []), do: "done"
  defp computed_completion_mark("not_done", []), do: "not_done"
  defp computed_completion_mark("partial", []), do: "partial"
  defp computed_completion_mark(_mark, []), do: "unknown"

  defp computed_completion_mark(_mark, linked_slices) do
    states = Enum.map(linked_slices, &slice_state/1)

    cond do
      Enum.all?(states, &terminal_completion_state?/1) -> "done"
      Enum.any?(states, &partial_completion_state?/1) -> "partial"
      Enum.any?(states, &terminal_completion_state?/1) and Enum.any?(states, &not_started_completion_state?/1) -> "partial"
      Enum.any?(states, &not_started_completion_state?/1) -> "not_done"
      true -> "unknown"
    end
  end

  defp terminal_completion_state?(state), do: state in @terminal_completion_keys or state == "skipped"
  defp partial_completion_state?(state), do: state in @partial_completion_keys
  defp not_started_completion_state?(state), do: state in @not_started_completion_keys

  defp dependency_edge_payload(%DependencyEdge{} = edge) do
    %{
      id: edge.id,
      source: %{kind: edge.source_kind, id: edge.source_id},
      target: %{kind: edge.target_kind, id: edge.target_id},
      kind: edge.kind,
      reason: Sanitizer.redacted_text(edge.reason),
      decision_ref: Sanitizer.redacted_json(edge.decision_ref),
      created_by: Sanitizer.redacted_text(edge.created_by),
      created_at: timestamp(edge.created_at)
    }
  end

  defp revision_payload(nil), do: nil

  defp revision_payload(%Revision{} = revision) do
    %{
      id: revision.id,
      revision_number: revision.revision_number,
      reason: Sanitizer.redacted_text(revision.reason),
      decision_ref: Sanitizer.redacted_json(revision.decision_ref),
      created_by: Sanitizer.redacted_text(revision.created_by),
      created_at: timestamp(revision.created_at)
    }
  end

  defp summary(nodes, root_slice_ids, planned_slice_payloads) do
    marks = Enum.map(nodes, & &1.computed_completion_mark)

    %{
      node_count: length(nodes),
      root_node_count: length(root_node_ids(nodes)),
      root_slice_count: length(root_slice_ids),
      slice_count: length(planned_slice_payloads),
      linked_slice_count: Enum.sum(Enum.map(nodes, & &1.slice_count)),
      done_count: Enum.count(marks, &(&1 == "done")),
      partial_count: Enum.count(marks, &(&1 == "partial")),
      not_done_count: Enum.count(marks, &(&1 == "not_done")),
      deferred_count: Enum.count(marks, &(&1 == "deferred")),
      unknown_count: Enum.count(marks, &(&1 == "unknown")),
      attention_count: Enum.count(planned_slice_payloads, &slice_attention?/1),
      blocker_count: Enum.count(planned_slice_payloads, &slice_blocker?/1)
    }
  end

  defp unavailable_projection(reason, planned_slice_payloads) do
    %{
      available: false,
      schema_version: "product_tree.v3",
      mode: "unavailable",
      root_node_ids: [],
      root_slice_ids: planned_slice_payloads |> Enum.map(&map_value(&1, "id")) |> Enum.reject(&is_nil/1),
      nodes: [],
      dependency_edges: [],
      summary: %{
        node_count: 0,
        root_node_count: 0,
        root_slice_count: length(planned_slice_payloads),
        slice_count: length(planned_slice_payloads),
        linked_slice_count: 0,
        done_count: 0,
        partial_count: 0,
        not_done_count: 0,
        deferred_count: 0,
        unknown_count: 0,
        attention_count: 0,
        blocker_count: 0
      },
      attention_items: [
        %{
          key: "product_tree_unavailable",
          label: "Product tree unavailable",
          tone: "warning",
          reason: inspect(reason)
        }
      ]
    }
  end

  defp root_node_ids(nodes) do
    nodes
    |> Enum.filter(&(Map.get(&1, :parent_id) in [nil, ""]))
    |> Enum.sort_by(&{Map.get(&1, :position) || 0, Map.get(&1, :title) || "", Map.get(&1, :id) || ""})
    |> Enum.map(& &1.id)
  end

  defp attention_count(slices), do: Enum.count(slices, &slice_attention?/1)
  defp blocker_count(slices), do: Enum.count(slices, &slice_blocker?/1)

  defp slice_attention?(slice) do
    state = map_value(slice, "operational_state") || %{}

    map_value(state, "key") in ["blocked", "needs_attention"] or
      (map_value(state, "attention_items") || []) != [] or
      (map_value(slice, "attention_reason_codes") || []) != []
  end

  defp slice_blocker?(slice) do
    state = map_value(slice, "operational_state") || %{}

    map_value(state, "key") == "blocked" or
      Enum.any?(map_value(state, "attention_items") || [], &attention_item_blocker?/1)
  end

  defp attention_item_blocker?(item) do
    key = item |> map_value("key") |> downcased()
    label = item |> map_value("label") |> downcased()
    tone = item |> map_value("tone") |> downcased()

    String.contains?(key, "blocker") or String.contains?(label, "blocker") or tone in ["critical", "danger", "destructive"]
  end

  defp downcased(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp downcased(_value), do: ""

  defp slice_state(slice) do
    state = map_value(slice, "operational_state") || %{}

    map_value(state, "key") ||
      map_value(slice, "work_package_status") ||
      map_value(slice, "status")
  end

  defp completion_label("done"), do: "Done"
  defp completion_label("partial"), do: "Partial"
  defp completion_label("not_done"), do: "Not done"
  defp completion_label("deferred"), do: "Deferred"
  defp completion_label(_mark), do: "Unknown"

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, maybe_atom(key))
  defp map_value(_map, _key), do: nil

  defp maybe_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end

  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp(_datetime), do: nil

  defp timestamp_sort(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp_sort(_datetime), do: ""
end
