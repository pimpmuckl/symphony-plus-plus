defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @terminal_planned_slice_statuses ["skipped"]
  @terminal_work_package_statuses ["merged", "merged_into_phase", "closed", "abandoned", "skipped", "superseded", "oracle"]
  @active_grant_roles ["worker", "architect"]
  @stale_heartbeat_after_seconds 300

  @type context :: %{optional(:work_package) => WorkPackage.t(), optional(:card) => map()}
  @type state :: %{completed?: boolean(), completed_at: DateTime.t() | nil, archived_at: DateTime.t() | nil}

  @spec state(WorkRequest.t(), non_neg_integer() | map(), [PlannedSlice.t()], %{optional(String.t()) => context()}) :: state()
  def state(%WorkRequest{} = work_request, question_state, planned_slices, work_package_contexts)
      when is_integer(question_state) and is_list(planned_slices) and is_map(work_package_contexts) do
    state(work_request, %{open_count: question_state, latest_gate_at: nil}, planned_slices, work_package_contexts)
  end

  def state(%WorkRequest{} = work_request, question_state, planned_slices, work_package_contexts)
      when is_map(question_state) and is_list(planned_slices) and is_map(work_package_contexts) do
    open_question_count = Map.get(question_state, :open_count, 0)

    completed? =
      open_question_count == 0 and planned_slices != [] and
        Enum.all?(planned_slices, &terminal_slice?(&1, Map.get(work_package_contexts, &1.work_package_id)))

    completed_at =
      if completed? do
        work_request.completed_at ||
          derived_completed_at(work_request, planned_slices, work_package_contexts, Map.get(question_state, :latest_gate_at))
      end

    %{
      completed?: completed?,
      completed_at: completed_at,
      archived_at: if(completed?, do: work_request.archived_at)
    }
  end

  @spec refresh(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error()}
  def refresh(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    with {:ok, work_request} <- Repository.get(repo, work_request_id),
         {:ok, question_state} <- question_state(repo, work_request_id),
         {:ok, planned_slices} <- Repository.list_planned_slices(repo, work_request_id),
         {:ok, contexts} <- linked_work_package_contexts(repo, planned_slices) do
      state = state(work_request, question_state, planned_slices, contexts)
      persist_state(repo, work_request, state)
    end
  end

  @spec archive(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error() | :not_completed}
  def archive(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    with {:ok, %WorkRequest{} = work_request} <- refresh(repo, work_request_id) do
      if is_nil(work_request.completed_at) do
        {:error, :not_completed}
      else
        archive_completed(repo, work_request)
      end
    end
  end

  defp persist_state(repo, %WorkRequest{} = work_request, %{completed?: true} = state) do
    attrs = %{completed_at: state.completed_at || DateTime.utc_now(:microsecond), archived_at: state.archived_at}

    if work_request.completed_at == attrs.completed_at and work_request.archived_at == attrs.archived_at do
      {:ok, work_request}
    else
      work_request
      |> Ecto.Changeset.change(attrs)
      |> repo.update()
    end
  end

  defp persist_state(repo, %WorkRequest{} = work_request, %{completed?: false}) do
    attrs = %{completed_at: nil, archived_at: nil}

    if is_nil(work_request.completed_at) and is_nil(work_request.archived_at) do
      {:ok, work_request}
    else
      work_request
      |> Ecto.Changeset.change(attrs)
      |> repo.update()
    end
  end

  defp archive_completed(_repo, %WorkRequest{archived_at: %DateTime{}} = work_request), do: {:ok, work_request}

  defp archive_completed(repo, %WorkRequest{} = work_request) do
    work_request
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:microsecond))
    |> repo.update()
  end

  defp question_state(repo, work_request_id) do
    questions =
      repo.all(
        from(question in ClarificationQuestion,
          where: question.work_request_id == ^work_request_id,
          select: %{status: question.status, updated_at: question.updated_at}
        )
      )

    {:ok,
     %{
       open_count: Enum.count(questions, &(&1.status == "open")),
       latest_gate_at: latest_timestamp(Enum.map(questions, & &1.updated_at))
     }}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp linked_work_package_contexts(_repo, []), do: {:ok, %{}}

  defp linked_work_package_contexts(repo, planned_slices) do
    work_package_ids =
      planned_slices
      |> Enum.map(& &1.work_package_id)
      |> Enum.filter(&filled_string?/1)
      |> Enum.uniq()

    work_packages =
      repo.all(from(work_package in WorkPackage, where: work_package.id in ^work_package_ids))

    progress_events_by_id = grouped_progress_events(repo, work_package_ids)
    grants_by_id = grouped_access_grants(repo, work_package_ids)
    agent_runs_by_id = grouped_agent_runs(repo, work_package_ids)

    contexts =
      Map.new(work_packages, fn %WorkPackage{} = work_package ->
        progress_events = Map.get(progress_events_by_id, work_package.id, [])
        grants = Map.get(grants_by_id, work_package.id, [])
        agent_runs = Map.get(agent_runs_by_id, work_package.id, [])

        {work_package.id,
         %{
           work_package: work_package,
           blocker_state: blocker_state(progress_events),
           runtime_state: runtime_state(grants, agent_runs)
         }}
      end)

    {:ok, contexts}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp grouped_progress_events(repo, work_package_ids) do
    repo.all(
      from(progress_event in ProgressEvent,
        where: progress_event.work_package_id in ^work_package_ids,
        order_by: [asc: progress_event.work_package_id, asc: progress_event.sequence, asc: progress_event.created_at]
      )
    )
    |> Enum.group_by(& &1.work_package_id)
  end

  defp grouped_access_grants(repo, work_package_ids) do
    repo.all(
      from(access_grant in AccessGrant,
        where: access_grant.work_package_id in ^work_package_ids
      )
    )
    |> Enum.group_by(& &1.work_package_id)
  end

  defp grouped_agent_runs(repo, work_package_ids) do
    repo.all(
      from(agent_run in AgentRun,
        where: agent_run.work_package_id in ^work_package_ids
      )
    )
    |> Enum.group_by(& &1.work_package_id)
  end

  defp terminal_slice?(%PlannedSlice{status: status}, _context) when status in @terminal_planned_slice_statuses, do: true

  defp terminal_slice?(%PlannedSlice{status: "dispatched"}, context) when is_map(context) do
    terminal_work_package?(context) and not active_blocker_context?(context) and not active_runtime_context?(context)
  end

  defp terminal_slice?(%PlannedSlice{}, _context), do: false

  defp terminal_work_package?(%{work_package: %WorkPackage{status: status}}), do: status in @terminal_work_package_statuses
  defp terminal_work_package?(_context), do: false

  defp active_blocker_context?(%{active_blocker?: true}), do: true
  defp active_blocker_context?(%{blocker_state: %{active?: true}}), do: true

  defp active_blocker_context?(%{card: %{operational_state: operational_state}}) when is_map(operational_state) do
    Map.get(operational_state, :key) == "blocked" or
      operational_state
      |> Map.get(:attention_items, [])
      |> Enum.any?(&(Map.get(&1, :key) == "active_blocker"))
  end

  defp active_blocker_context?(_context), do: false

  defp active_runtime_context?(%{active_runtime?: true}), do: true
  defp active_runtime_context?(%{runtime_state: %{active?: true}}), do: true
  defp active_runtime_context?(%{card: %{operational_state: %{has_active_worker: true}}}), do: true
  defp active_runtime_context?(_context), do: false

  defp derived_completed_at(%WorkRequest{} = work_request, planned_slices, work_package_contexts, question_gate_at) do
    work_package_timestamps =
      work_package_contexts
      |> Map.values()
      |> Enum.map(fn
        %{work_package: %WorkPackage{} = work_package} -> work_package.updated_at
        _context -> nil
      end)

    gate_timestamps =
      work_package_contexts
      |> Map.values()
      |> Enum.flat_map(fn context ->
        [
          get_in(context, [:blocker_state, :latest_gate_at]),
          get_in(context, [:runtime_state, :latest_gate_at])
        ]
      end)

    latest_timestamp([work_request.updated_at, question_gate_at] ++ Enum.map(planned_slices, & &1.updated_at) ++ work_package_timestamps ++ gate_timestamps) ||
      DateTime.utc_now(:microsecond)
  end

  defp blocker_state(progress_events) do
    blocker_events =
      progress_events
      |> Enum.filter(&blocker_event?/1)
      |> Enum.sort_by(&progress_event_order/1)

    active_by_id =
      Enum.reduce(blocker_events, %{}, fn %ProgressEvent{} = event, active_by_id ->
        Map.put(active_by_id, blocker_id(event), Map.get(event.payload || %{}, "active") == true)
      end)

    %{active?: Enum.any?(Map.values(active_by_id), & &1), latest_gate_at: latest_timestamp(Enum.map(blocker_events, & &1.created_at))}
  end

  defp blocker_event?(%ProgressEvent{payload: payload}) when is_map(payload) do
    Map.get(payload, "type") == "blocker" and Map.get(payload, "source_tool") in ["report_blocker", "resolve_blocker"]
  end

  defp blocker_event?(%ProgressEvent{}), do: false

  defp blocker_id(%ProgressEvent{payload: payload, idempotency_key: idempotency_key, id: id}) do
    payload = payload || %{}

    Map.get(payload, "blocker_id")
    |> Kernel.||(idempotency_key)
    |> Kernel.||(id)
    |> normalize_blocker_id()
  end

  defp progress_event_order(%ProgressEvent{} = event) do
    {timestamp_sort_value(event.created_at), event.sequence || 0, event.id || ""}
  end

  defp runtime_state(grants, agent_runs) do
    %{active?: Enum.any?(grants, &active_grant?/1) or Enum.any?(agent_runs, &active_agent_run?/1), latest_gate_at: latest_runtime_gate_at(grants, agent_runs)}
  end

  defp active_grant?(%AccessGrant{grant_role: role, claimed_at: %DateTime{}, claimed_by: claimed_by, revoked_at: nil, expires_at: expires_at})
       when role in @active_grant_roles and is_binary(claimed_by) do
    is_nil(expires_at) or DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) == :gt
  end

  defp active_grant?(%AccessGrant{}), do: false

  defp active_agent_run?(%AgentRun{status: status} = run), do: status in AgentRun.active_statuses() and not stale_agent_run?(run)

  defp stale_agent_run?(%AgentRun{status: status, last_seen_at: %DateTime{} = last_seen_at}) when status in ["starting", "running", "retrying"] do
    DateTime.diff(DateTime.utc_now(:microsecond), last_seen_at, :second) >= @stale_heartbeat_after_seconds
  end

  defp stale_agent_run?(%AgentRun{}), do: false

  defp latest_runtime_gate_at(grants, agent_runs) do
    grant_timestamps =
      grants
      |> Enum.reject(&active_grant?/1)
      |> Enum.map(fn %AccessGrant{} = grant -> grant.revoked_at || expired_at(grant) || grant.updated_at end)

    run_timestamps =
      agent_runs
      |> Enum.reject(&active_agent_run?/1)
      |> Enum.map(fn %AgentRun{} = run -> run.finished_at || run.updated_at end)

    latest_timestamp(grant_timestamps ++ run_timestamps)
  end

  defp expired_at(%AccessGrant{expires_at: %DateTime{} = expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) in [:lt, :eq], do: expires_at
  end

  defp expired_at(%AccessGrant{}), do: nil

  defp latest_timestamp(timestamps) do
    timestamps
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp timestamp_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp timestamp_sort_value(_timestamp), do: -1

  defp normalize_blocker_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_blocker_id(value), do: to_string(value)

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)

    if String.contains?(String.downcase(message), "busy") or String.contains?(String.downcase(message), "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end
end
