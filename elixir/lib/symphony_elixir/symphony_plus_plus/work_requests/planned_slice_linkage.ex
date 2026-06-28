defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceLinkage do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type error ::
          :not_found
          | :ambiguous_planned_slice_link
          | :planned_slice_not_dispatched
          | :work_package_not_found
          | {:storage_failed, String.t()}

  @spec linked_slice_for_work_package(module(), String.t()) :: {:ok, PlannedSlice.t()} | {:error, error()}
  def linked_slice_for_work_package(repo, work_package_id) when is_atom(repo) do
    linked_slice_for_work_package(repo, nil, work_package_id)
  end

  @spec linked_slice_for_work_package(module(), String.t() | nil, String.t()) ::
          {:ok, PlannedSlice.t()} | {:error, error()}
  def linked_slice_for_work_package(repo, work_request_id, work_package_id) when is_atom(repo) do
    with {:ok, work_package_id} <- nonblank(work_package_id) do
      planned_slices =
        repo.all(
          work_package_id
          |> linked_slice_query()
          |> maybe_scoped_to_work_request(work_request_id)
        )

      case planned_slices do
        [planned_slice] -> {:ok, planned_slice}
        [] -> {:error, :not_found}
        _multiple -> {:error, :ambiguous_planned_slice_link}
      end
    end
  rescue
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  @spec linked_work_request_for_work_package(module(), String.t()) ::
          {:ok, {PlannedSlice.t(), WorkRequest.t()}} | {:error, error()}
  def linked_work_request_for_work_package(repo, work_package_id) when is_atom(repo) do
    case linked_work_requests_for_work_package(repo, work_package_id) do
      {:ok, [{%PlannedSlice{}, %WorkRequest{}} = link]} -> {:ok, link}
      {:ok, []} -> {:error, :not_found}
      {:ok, [_first | _rest]} -> {:error, :ambiguous_planned_slice_link}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec linked_work_requests_for_work_package(module(), String.t()) ::
          {:ok, [{PlannedSlice.t(), WorkRequest.t()}]} | {:error, error()}
  def linked_work_requests_for_work_package(repo, work_package_id) when is_atom(repo) do
    with {:ok, work_package_id} <- nonblank(work_package_id) do
      links =
        repo.all(
          from(planned_slice in PlannedSlice,
            join: work_request in WorkRequest,
            on: work_request.id == planned_slice.work_request_id,
            where: planned_slice.work_package_id == ^work_package_id,
            order_by: [asc: planned_slice.work_request_id, asc: planned_slice.sequence, asc: planned_slice.id],
            select: {planned_slice, work_request}
          )
        )

      {:ok, links}
    end
  rescue
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  @spec linked_work_package_for_planned_slice(module(), String.t(), String.t()) ::
          {:ok, {PlannedSlice.t(), WorkPackage.t()}} | {:error, error()}
  def linked_work_package_for_planned_slice(repo, work_request_id, planned_slice_id)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(planned_slice_id) do
    with {:ok, planned_slice} <- scoped_planned_slice(repo, work_request_id, planned_slice_id),
         {:ok, work_package_id} <- nonblank(planned_slice.work_package_id, :planned_slice_not_dispatched) do
      case repo.get(WorkPackage, work_package_id) do
        %WorkPackage{} = work_package -> {:ok, {planned_slice, work_package}}
        nil -> {:error, :work_package_not_found}
      end
    end
  rescue
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  def linked_work_package_for_planned_slice(_repo, _work_request_id, _planned_slice_id), do: {:error, :not_found}

  defp linked_slice_query(work_package_id) do
    from(planned_slice in PlannedSlice,
      where: planned_slice.work_package_id == ^work_package_id,
      order_by: [asc: planned_slice.work_request_id, asc: planned_slice.sequence, asc: planned_slice.id],
      limit: 2
    )
  end

  defp maybe_scoped_to_work_request(query, work_request_id) when is_binary(work_request_id) do
    case String.trim(work_request_id) do
      "" -> query
      scoped_id -> from(planned_slice in query, where: planned_slice.work_request_id == ^scoped_id)
    end
  end

  defp maybe_scoped_to_work_request(query, _work_request_id), do: query

  defp scoped_planned_slice(repo, work_request_id, planned_slice_id) do
    case repo.get(PlannedSlice, planned_slice_id) do
      %PlannedSlice{work_request_id: ^work_request_id} = planned_slice -> {:ok, planned_slice}
      %PlannedSlice{} -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  defp nonblank(value, error \\ :not_found)
  defp nonblank(value, error) when is_binary(value), do: value |> String.trim() |> nonblank_trimmed(error)
  defp nonblank(_value, error), do: {:error, error}

  defp nonblank_trimmed("", error), do: {:error, error}
  defp nonblank_trimmed(value, _error), do: {:ok, value}
end
