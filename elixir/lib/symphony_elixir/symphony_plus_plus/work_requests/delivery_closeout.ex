defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryCloseout do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @type error ::
          Repository.error()
          | WorkPackageRepository.error()
          | PlanningRepository.error()
          | :idempotency_key_conflict
          | :missing_strong_pr_evidence

  @spec record(Repository.repo(), String.t(), String.t(), map()) ::
          {:ok, PlannedSliceDelivery.t()} | {:error, error()}
  def record(repo, work_request_id, planned_slice_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(planned_slice_id) and is_map(attrs) do
    repo.transaction(fn -> record_in_transaction(repo, work_request_id, planned_slice_id, attrs) end)
    |> normalize_transaction_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp record_in_transaction(repo, work_request_id, planned_slice_id, attrs) do
    with {:ok, work_request} <- Repository.get(repo, work_request_id),
         {:ok, planned_slice} <- Repository.get_planned_slice(repo, work_request_id, planned_slice_id),
         {:ok, delivery} <-
           Repository.record_planned_slice_delivery_in_transaction(
             repo,
             work_request_id,
             planned_slice_id,
             attrs
           ),
         {:ok, delivery} <- complete_closeout(repo, work_request, planned_slice, delivery) do
      delivery
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp validate_terminal_evidence(%PlannedSlice{work_package_id: work_package_id}, %PlannedSliceDelivery{outcome: "pr_merged"} = delivery) do
    if filled_string?(work_package_id) and not strong_pr_evidence?(delivery) do
      {:error, :missing_strong_pr_evidence}
    else
      :ok
    end
  end

  defp validate_terminal_evidence(%PlannedSlice{}, %PlannedSliceDelivery{}), do: :ok

  defp complete_closeout(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, %PlannedSliceDelivery{} = delivery) do
    case closeout_progress_replay?(repo, planned_slice, delivery) do
      true ->
        refresh_replayed_closeout(repo, work_request, delivery)

      false ->
        with :ok <- validate_terminal_evidence(planned_slice, delivery) do
          perform_closeout(repo, work_request, planned_slice, delivery)
        end
    end
  end

  defp refresh_replayed_closeout(repo, %WorkRequest{} = work_request, %PlannedSliceDelivery{} = delivery) do
    with {:ok, _refreshed} <- Completion.refresh_in_transaction(repo, work_request.id) do
      {:ok, delivery}
    end
  end

  defp perform_closeout(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, %PlannedSliceDelivery{} = delivery) do
    with :ok <- reject_active_linked_closeout_context(repo, planned_slice),
         {:ok, closeout} <- close_linked_work_package(repo, work_request, planned_slice, delivery),
         {:ok, _event} <- append_closeout_progress(repo, work_request, planned_slice, delivery, closeout),
         {:ok, _refreshed} <- Completion.refresh_in_transaction(repo, work_request.id) do
      {:ok, delivery}
    end
  end

  defp close_linked_work_package(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, %PlannedSliceDelivery{} = delivery) do
    WorkPackageRepository.close_compatible_linked_delivery_package(
      repo,
      work_request,
      planned_slice,
      terminal_status_for_outcome(delivery.outcome)
    )
  end

  defp append_closeout_progress(_repo, %WorkRequest{}, %PlannedSlice{}, %PlannedSliceDelivery{}, nil), do: {:ok, nil}

  defp append_closeout_progress(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, %PlannedSliceDelivery{} = delivery, closeout)
       when is_map(closeout) do
    with {:ok, event} <-
           PlanningRepository.append_progress_event(repo, %{
             work_package_id: closeout.work_package.id,
             summary: "Recorded WorkRequest delivery closeout: #{delivery.outcome}",
             status: closeout.next_status,
             idempotency_key: closeout_idempotency_key(delivery),
             payload: %{
               type: "work_request_delivery_closeout",
               source_tool: "record_planned_slice_delivery",
               work_request_id: work_request.id,
               planned_slice_id: planned_slice.id,
               delivery_id: delivery.id,
               outcome: delivery.outcome,
               previous_status: closeout.previous_status,
               next_status: closeout.next_status,
               status_changed: closeout.changed?,
               pr_url: delivery.pr_url,
               pr_number: delivery.pr_number,
               pr_repository: delivery.pr_repository,
               pr_merged_at: delivery.pr_merged_at,
               merge_commit_sha: delivery.merge_commit_sha,
               successor_planned_slice_id: delivery.successor_planned_slice_id,
               successor_work_package_id: delivery.successor_work_package_id
             }
           }),
         true <- closeout_progress_event_matches?(event, planned_slice, delivery, closeout.next_status) do
      {:ok, event}
    else
      false -> {:error, :idempotency_key_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp terminal_status_for_outcome(outcome), do: PlannedSliceDelivery.terminal_status_for_outcome(outcome)

  defp reject_active_linked_closeout_context(repo, %PlannedSlice{work_package_id: work_package_id}) do
    if filled_string?(work_package_id) do
      context = WorkPackageActivity.context(repo, work_package_id)

      cond do
        get_in(context, [:blocker_state, :active?]) == true -> {:error, :active_blocker}
        get_in(context, [:runtime_state, :active?]) == true -> {:error, :active_runtime}
        active_linked_worker_grant?(repo, work_package_id) -> {:error, :active_runtime}
        true -> :ok
      end
    else
      :ok
    end
  end

  defp active_linked_worker_grant?(repo, work_package_id) do
    now = DateTime.utc_now(:microsecond)

    repo.one(
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        select: grant.id,
        limit: 1
      )
    )
    |> is_binary()
  end

  defp closeout_progress_replay?(repo, %PlannedSlice{work_package_id: work_package_id}, %PlannedSliceDelivery{} = delivery) do
    with true <- filled_string?(work_package_id),
         {:ok, event} <-
           PlanningRepository.get_progress_event_by_idempotency_key(
             repo,
             work_package_id,
             closeout_idempotency_key(delivery)
           ),
         {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         true <- PlannedSliceDelivery.terminal_status_matches_outcome?(work_package.status, delivery.outcome),
         true <- closeout_progress_event_matches?(event, delivery, work_package.status) do
      true
    else
      _result -> false
    end
  end

  defp closeout_progress_event_matches?(event, %PlannedSlice{work_package_id: work_package_id}, %PlannedSliceDelivery{} = delivery, next_status) do
    event.work_package_id == work_package_id and closeout_progress_event_matches?(event, delivery, next_status)
  end

  defp closeout_progress_event_matches?(event, %PlannedSliceDelivery{} = delivery, next_status) do
    event.idempotency_key == closeout_idempotency_key(delivery) and
      event.status == next_status and
      closeout_progress_payload_matches?(event.payload || %{}, delivery, next_status)
  end

  defp closeout_progress_payload_matches?(payload, %PlannedSliceDelivery{} = delivery, next_status) do
    closeout_progress_payload_identity_matches?(payload, delivery) and map_value(payload, :next_status) == next_status
  end

  defp closeout_progress_payload_identity_matches?(payload, %PlannedSliceDelivery{} = delivery) do
    map_value(payload, :type) == "work_request_delivery_closeout" and
      map_value(payload, :source_tool) == "record_planned_slice_delivery" and
      map_value(payload, :work_request_id) == delivery.work_request_id and
      map_value(payload, :planned_slice_id) == delivery.planned_slice_id and
      map_value(payload, :delivery_id) == delivery.id and
      map_value(payload, :outcome) == delivery.outcome
  end

  defp strong_pr_evidence?(%PlannedSliceDelivery{} = delivery) do
    filled_string?(delivery.pr_url) and
      match?(%DateTime{}, delivery.pr_merged_at) and
      filled_string?(delivery.merge_commit_sha)
  end

  defp closeout_idempotency_key(%PlannedSliceDelivery{} = delivery) do
    Enum.join(
      [
        "work_request_delivery_closeout",
        delivery.work_request_id,
        delivery.planned_slice_id,
        delivery.idempotency_key
      ],
      ":"
    )
  end

  defp filled_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp filled_string?(_value), do: false

  defp map_value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize_transaction_result({:ok, delivery}), do: {:ok, delivery}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    {:error, {:constraint_failed, constraint}}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    if String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end
end
