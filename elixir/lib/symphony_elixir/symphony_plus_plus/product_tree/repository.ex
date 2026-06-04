defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.{Attrs, DependencyEdge, Node, Revision, SliceLink}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice

  @type repo :: module()
  @type error ::
          :not_found
          | :database_busy
          | :id_already_exists
          | {:constraint_failed, String.t()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec tree_for_work_request(repo(), String.t()) ::
          {:ok, %{nodes: [Node.t()], slice_links: [SliceLink.t()], dependency_edges: [DependencyEdge.t()], latest_revision: Revision.t() | nil}}
          | {:error, error()}
  def tree_for_work_request(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    {:ok,
     %{
       nodes: list_nodes!(repo, work_request_id),
       slice_links: list_slice_links!(repo, work_request_id),
       dependency_edges: list_dependency_edges!(repo, work_request_id),
       latest_revision: latest_revision!(repo, work_request_id)
     }}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec create_node(repo(), map()) :: {:ok, Node.t()} | {:error, error()}
  def create_node(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs = Attrs.normalize_keys(attrs)

    with :ok <- validate_parent_scope(repo, attrs) do
      attrs
      |> Node.create_changeset()
      |> repo.insert()
      |> normalize_insert_result()
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec create_slice_link(repo(), map()) :: {:ok, SliceLink.t()} | {:error, error()}
  def create_slice_link(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs = Attrs.normalize_keys(attrs)

    with :ok <- validate_slice_link_scope(repo, attrs) do
      attrs
      |> SliceLink.create_changeset()
      |> repo.insert()
      |> normalize_insert_result()
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec create_dependency_edge(repo(), map()) :: {:ok, DependencyEdge.t()} | {:error, error()}
  def create_dependency_edge(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs = Attrs.normalize_keys(attrs)

    with :ok <- validate_dependency_edge_scope(repo, attrs) do
      attrs
      |> DependencyEdge.create_changeset()
      |> repo.insert()
      |> normalize_insert_result()
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec record_revision(repo(), String.t(), map()) :: {:ok, Revision.t()} | {:error, error()}
  def record_revision(repo, work_request_id, attrs) when is_atom(repo) and is_binary(work_request_id) and is_map(attrs) do
    attrs =
      attrs
      |> Attrs.normalize_keys()
      |> Map.put("work_request_id", work_request_id)
      |> Map.put("revision_number", next_revision_number(repo, work_request_id))

    attrs
    |> Revision.create_changeset()
    |> repo.insert()
    |> normalize_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp list_nodes!(repo, work_request_id) do
    repo.all(
      from(node in Node,
        where: node.work_request_id == ^work_request_id,
        order_by: [asc: node.parent_id, asc: node.position, asc: node.created_at, asc: node.id]
      )
    )
  end

  defp list_slice_links!(repo, work_request_id) do
    repo.all(
      from(link in SliceLink,
        where: link.work_request_id == ^work_request_id,
        order_by: [asc: link.product_tree_node_id, asc: link.position, asc: link.created_at, asc: link.id]
      )
    )
  end

  defp list_dependency_edges!(repo, work_request_id) do
    repo.all(
      from(edge in DependencyEdge,
        where: edge.work_request_id == ^work_request_id,
        order_by: [asc: edge.kind, asc: edge.created_at, asc: edge.id]
      )
    )
  end

  defp latest_revision!(repo, work_request_id) do
    repo.one(
      from(revision in Revision,
        where: revision.work_request_id == ^work_request_id,
        order_by: [desc: revision.revision_number],
        limit: 1
      )
    )
  end

  defp validate_parent_scope(_repo, %{"parent_id" => parent_id}) when parent_id in [nil, ""], do: :ok
  defp validate_parent_scope(_repo, %{"work_request_id" => work_request_id}) when work_request_id in [nil, ""], do: :ok

  defp validate_parent_scope(repo, %{"work_request_id" => work_request_id, "parent_id" => parent_id}) do
    validate_record_scope(repo, Node, parent_id, work_request_id, "product_tree_node_parent_scope")
  end

  defp validate_parent_scope(_repo, _attrs), do: :ok

  defp validate_slice_link_scope(repo, %{"work_request_id" => work_request_id} = attrs) when is_binary(work_request_id) and work_request_id != "" do
    with :ok <- validate_record_scope(repo, Node, Map.get(attrs, "product_tree_node_id"), work_request_id, "product_tree_slice_link_node_scope") do
      validate_record_scope(repo, PlannedSlice, Map.get(attrs, "planned_slice_id"), work_request_id, "product_tree_slice_link_slice_scope")
    end
  end

  defp validate_slice_link_scope(_repo, _attrs), do: :ok

  defp validate_dependency_edge_scope(repo, %{"work_request_id" => work_request_id} = attrs) when is_binary(work_request_id) and work_request_id != "" do
    with :ok <- validate_dependency_endpoint_scope(repo, work_request_id, Map.get(attrs, "source_kind"), Map.get(attrs, "source_id"), "source") do
      validate_dependency_endpoint_scope(repo, work_request_id, Map.get(attrs, "target_kind"), Map.get(attrs, "target_id"), "target")
    end
  end

  defp validate_dependency_edge_scope(_repo, _attrs), do: :ok

  defp validate_dependency_endpoint_scope(repo, work_request_id, "product_node", id, label) do
    validate_record_scope(repo, Node, id, work_request_id, "product_tree_dependency_#{label}_scope")
  end

  defp validate_dependency_endpoint_scope(repo, work_request_id, "planned_slice", id, label) do
    validate_record_scope(repo, PlannedSlice, id, work_request_id, "product_tree_dependency_#{label}_scope")
  end

  defp validate_dependency_endpoint_scope(_repo, _work_request_id, _kind, _id, _label), do: :ok

  defp validate_record_scope(_repo, _schema, id, _work_request_id, _constraint) when id in [nil, ""], do: :ok

  defp validate_record_scope(repo, schema, id, work_request_id, constraint) do
    case repo.get(schema, id) do
      nil -> {:error, {:constraint_failed, constraint}}
      %{work_request_id: ^work_request_id} -> :ok
      _record -> {:error, {:constraint_failed, constraint}}
    end
  end

  defp next_revision_number(repo, work_request_id) do
    repo.one(
      from(revision in Revision,
        where: revision.work_request_id == ^work_request_id,
        select: max(revision.revision_number)
      )
    )
    |> case do
      number when is_integer(number) -> number + 1
      _number -> 1
    end
  end

  defp normalize_insert_result({:ok, record}), do: {:ok, record}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    if duplicate_id?(changeset), do: {:error, :id_already_exists}, else: {:error, changeset}
  end

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    cond do
      String.contains?(constraint, "_id_unique_index") -> {:error, :id_already_exists}
      true -> {:error, {:constraint_failed, constraint}}
    end
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}), do: {:error, {:constraint_failed, Atom.to_string(type)}}

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    cond do
      String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") -> {:error, :database_busy}
      true -> {:error, {:storage_failed, message}}
    end
  end
end
