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
  @terminal_work_package_statuses ["merged", "merged_into_phase", "closed", "abandoned"]
  @completion_blocking_work_request_statuses ["human_info_needed"]
  @operator_completion_source "operator"
  @restorable_archive_reasons ["age"]
  @active_grant_roles ["worker", "architect"]
  @stale_heartbeat_after_seconds 300
  @default_archive_after_days 14
  @completed_visible_limit 10

  @type context :: %{optional(:work_package) => WorkPackage.t(), optional(:card) => map()}
  @type state :: %{completed?: boolean(), completed_at: DateTime.t() | nil, archived_at: DateTime.t() | nil}
  @type retention_summary :: %{
          refreshed_count: non_neg_integer(),
          archived_count: non_neg_integer(),
          archived_ids: [String.t()]
        }

  @spec default_archive_after_days() :: pos_integer()
  def default_archive_after_days, do: @default_archive_after_days

  @spec blocker_event_payload?(map()) :: boolean()
  def blocker_event_payload?(payload) when is_map(payload) do
    map_value(payload, :type) == "blocker" and map_value(payload, :source_tool) in ["report_blocker", "resolve_blocker"]
  end

  @spec state(WorkRequest.t(), map(), [PlannedSlice.t()], %{optional(String.t()) => context()}) :: state()
  def state(%WorkRequest{} = work_request, question_state, planned_slices, work_package_contexts)
      when is_map(question_state) and is_list(planned_slices) and is_map(work_package_contexts) do
    if operator_completed?(work_request) do
      %{
        completed?: true,
        completed_at: work_request.completed_at,
        archived_at: work_request.archived_at
      }
    else
      derived_state(work_request, question_state, planned_slices, work_package_contexts)
    end
  end

  defp derived_state(%WorkRequest{} = work_request, question_state, planned_slices, work_package_contexts)
       when is_map(question_state) and is_list(planned_slices) and is_map(work_package_contexts) do
    open_question_count = Map.get(question_state, :open_count, 0)

    completed? =
      completion_status_allowed?(work_request) and open_question_count == 0 and planned_slices != [] and
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

  @spec visible_state(WorkRequest.t(), map(), [PlannedSlice.t()], %{optional(String.t()) => context()}) :: state()
  def visible_state(%WorkRequest{} = work_request, question_state, planned_slices, work_package_contexts)
      when is_map(question_state) and is_list(planned_slices) and is_map(work_package_contexts) do
    work_request
    |> state(question_state, planned_slices, work_package_contexts)
    |> preserve_persisted_visible_state(work_request, question_state, planned_slices, work_package_contexts)
  end

  @spec refresh(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error()}
  def refresh(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    repo.transaction(fn ->
      case refresh_in_transaction(repo, work_request_id) do
        {:ok, work_request} -> work_request
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp refresh_in_transaction(repo, work_request_id) do
    with {:ok, work_request} <- Repository.get(repo, work_request_id),
         {:ok, question_state} <- question_state(repo, work_request_id),
         {:ok, planned_slices} <- Repository.list_planned_slices(repo, work_request_id),
         {:ok, contexts} <- linked_work_package_contexts(repo, planned_slices) do
      state = state(work_request, question_state, planned_slices, contexts)
      persist_state(repo, work_request, state)
    end
  end

  @spec force_complete(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error()}
  def force_complete(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    repo.transaction(fn ->
      with {:ok, %WorkRequest{} = work_request} <- Repository.get(repo, work_request_id),
           {:ok, updated} <- force_complete_work_request(repo, work_request) do
        updated
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec archive(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error() | :not_completed}
  def archive(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    with {:ok, %WorkRequest{} = work_request} <- refresh(repo, work_request_id) do
      if is_nil(work_request.completed_at) do
        {:error, :not_completed}
      else
        archive_completed(repo, work_request, "manual")
      end
    end
  end

  @spec restore(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, Repository.error()}
  def restore(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    with {:ok, %WorkRequest{} = work_request} <- refresh(repo, work_request_id) do
      restore_completed(repo, work_request)
    end
  end

  @spec retention_pass(Repository.repo()) ::
          {:ok, retention_summary()} | {:error, Repository.error() | :invalid_archive_after_days | :not_completed}
  @spec retention_pass(Repository.repo(), keyword()) ::
          {:ok, retention_summary()} | {:error, Repository.error() | :invalid_archive_after_days | :not_completed}
  def retention_pass(repo, opts \\ []) when is_atom(repo) and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, fn -> DateTime.utc_now(:microsecond) end)

    with {:ok, archive_after_days} <- archive_after_days(opts),
         {:ok, refreshed} <- refresh_all(repo),
         {:ok, _restored_for_age} <- restore_unexpired(repo, refreshed, now, archive_after_days),
         {:ok, archived_for_age} <- archive_expired(repo, refreshed, now, archive_after_days),
         {:ok, visible_completed} <- completed_unarchived(repo),
         {:ok, archived_for_limit} <- archive_overflow(repo, visible_completed) do
      archived_ids = archived_for_age ++ archived_for_limit

      {:ok,
       %{
         refreshed_count: length(refreshed),
         archived_count: length(archived_ids),
         archived_ids: archived_ids
       }}
    end
  end

  defp persist_state(repo, %WorkRequest{} = work_request, %{completed?: true} = state) do
    attrs = %{
      completed_at: state.completed_at || DateTime.utc_now(:microsecond),
      completion_source: work_request.completion_source,
      archived_at: state.archived_at,
      archive_reason: if(state.archived_at, do: work_request.archive_reason)
    }

    unchanged? =
      work_request.completed_at == attrs.completed_at and work_request.archived_at == attrs.archived_at and
        work_request.archive_reason == attrs.archive_reason and
        work_request.completion_source == attrs.completion_source

    if unchanged? do
      {:ok, work_request}
    else
      work_request
      |> Ecto.Changeset.change(attrs)
      |> update_work_request(repo)
    end
  end

  defp persist_state(repo, %WorkRequest{} = work_request, %{completed?: false}) do
    attrs = %{completed_at: nil, completion_source: nil, archived_at: nil, archive_reason: nil}

    if is_nil(work_request.completed_at) and is_nil(work_request.archived_at) and
         is_nil(work_request.completion_source) do
      {:ok, work_request}
    else
      work_request
      |> Ecto.Changeset.change(attrs)
      |> update_work_request(repo)
    end
  end

  defp preserve_persisted_visible_state(
         %{completed?: false} = state,
         %WorkRequest{completed_at: %DateTime{} = completed_at} = work_request,
         question_state,
         planned_slices,
         work_package_contexts
       ) do
    if completion_status_allowed?(work_request) and
         filtered_completion_context?(question_state, planned_slices, work_package_contexts) do
      %{state | completed?: true, completed_at: completed_at, archived_at: work_request.archived_at}
    else
      state
    end
  end

  defp preserve_persisted_visible_state(state, %WorkRequest{}, _question_state, _planned_slices, _work_package_contexts), do: state

  defp force_complete_work_request(repo, %WorkRequest{} = work_request) do
    attrs = %{
      completed_at: work_request.completed_at || DateTime.utc_now(:microsecond),
      completion_source: @operator_completion_source,
      archived_at: nil,
      archive_reason: nil
    }

    work_request
    |> Ecto.Changeset.change(attrs)
    |> update_work_request(repo)
  end

  defp operator_completed?(%WorkRequest{completed_at: %DateTime{}, completion_source: @operator_completion_source}), do: true
  defp operator_completed?(%WorkRequest{}), do: false

  defp filtered_completion_context?(question_state, planned_slices, work_package_contexts) do
    Map.get(question_state, :open_count, 0) == 0 and planned_slices != [] and
      Enum.all?(planned_slices, &terminal_or_filtered_slice?(&1, work_package_contexts))
  end

  defp terminal_or_filtered_slice?(%PlannedSlice{status: status}, _work_package_contexts) when status in @terminal_planned_slice_statuses, do: true

  defp terminal_or_filtered_slice?(%PlannedSlice{status: "dispatched", work_package_id: work_package_id}, work_package_contexts) do
    context = Map.get(work_package_contexts, work_package_id)
    is_nil(context) or terminal_slice?(%PlannedSlice{status: "dispatched"}, context)
  end

  defp terminal_or_filtered_slice?(%PlannedSlice{}, _work_package_contexts), do: false

  defp completion_status_allowed?(%WorkRequest{status: status}), do: status not in @completion_blocking_work_request_statuses

  defp refresh_all(repo) do
    with {:ok, work_requests} <- all_work_requests(repo) do
      work_requests
      |> Enum.map(&refresh(repo, &1.id))
      |> collect_or_error()
    end
  end

  defp archive_after_days(opts) do
    case Keyword.get(opts, :archive_after_days, @default_archive_after_days) do
      days when is_integer(days) and days >= 1 -> {:ok, days}
      _days -> {:error, :invalid_archive_after_days}
    end
  end

  defp archive_expired(repo, work_requests, now, archive_after_days) do
    cutoff = DateTime.add(now, -archive_after_days * 24 * 60 * 60, :second)

    work_requests
    |> Enum.filter(&archive_expired?(&1, cutoff))
    |> archive_all(repo)
  end

  defp archive_expired?(%WorkRequest{completed_at: %DateTime{} = completed_at, archived_at: nil}, cutoff) do
    DateTime.compare(completed_at, cutoff) in [:lt, :eq]
  end

  defp archive_expired?(%WorkRequest{}, _cutoff), do: false

  defp restore_unexpired(repo, work_requests, now, archive_after_days) do
    cutoff = DateTime.add(now, -archive_after_days * 24 * 60 * 60, :second)

    work_requests
    |> Enum.filter(&restore_unexpired?(&1, cutoff))
    |> restore_all(repo)
  end

  defp restore_unexpired?(
         %WorkRequest{
           completed_at: %DateTime{} = completed_at,
           archived_at: %DateTime{},
           archive_reason: archive_reason
         },
         cutoff
       ) do
    archive_reason in @restorable_archive_reasons and DateTime.compare(completed_at, cutoff) == :gt
  end

  defp restore_unexpired?(%WorkRequest{}, _cutoff), do: false

  defp archive_overflow(repo, work_requests) do
    work_requests
    |> Enum.group_by(&{&1.repo, &1.base_branch})
    |> Enum.flat_map(fn {_scope, scoped_work_requests} ->
      scoped_work_requests
      |> Enum.sort_by(&completed_sort_key/1)
      |> Enum.drop(-@completed_visible_limit)
    end)
    |> archive_all(repo, "limit")
  end

  defp archive_all(work_requests, repo, archive_reason \\ "age") do
    work_requests
    |> Enum.reduce_while({:ok, []}, fn work_request, {:ok, archived_ids} ->
      case archive_completed(repo, work_request, archive_reason) do
        {:ok, %WorkRequest{id: id}} -> {:cont, {:ok, [id | archived_ids]}}
        {:error, :not_completed} -> {:cont, {:ok, archived_ids}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, archived_ids} -> {:ok, Enum.reverse(archived_ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_all(work_requests, repo) do
    work_requests
    |> Enum.map(&restore_completed(repo, &1, reset_completed_at?: false))
    |> collect_or_error()
    |> case do
      {:ok, restored} -> {:ok, Enum.map(restored, & &1.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp all_work_requests(repo) do
    work_requests =
      repo.all(
        from(work_request in WorkRequest,
          order_by: [asc: work_request.inserted_at, asc: work_request.id]
        )
      )

    {:ok, work_requests}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp completed_unarchived(repo) do
    work_requests =
      repo.all(
        from(work_request in WorkRequest,
          where: is_nil(work_request.archived_at),
          where: not is_nil(work_request.completed_at),
          order_by: [asc: work_request.completed_at, asc: work_request.inserted_at, asc: work_request.id]
        )
      )

    {:ok, work_requests}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp completed_sort_key(%WorkRequest{} = work_request) do
    {timestamp_sort_value(work_request.completed_at), timestamp_sort_value(work_request.inserted_at), work_request.id || ""}
  end

  defp collect_or_error(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, item}, {:ok, items} -> {:cont, {:ok, [item | items]}}
      {:error, reason}, {:ok, _items} -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp archive_completed(_repo, %WorkRequest{archived_at: %DateTime{}} = work_request, _archive_reason), do: {:ok, work_request}

  defp archive_completed(repo, %WorkRequest{id: id}, archive_reason) when is_binary(id) do
    now = DateTime.utc_now(:microsecond)

    repo.update_all(
      from(work_request in WorkRequest,
        where: work_request.id == ^id,
        where: not is_nil(work_request.completed_at),
        where: is_nil(work_request.archived_at)
      ),
      set: [archived_at: now, archive_reason: archive_reason, updated_at: now]
    )
    |> archive_update_result(repo, id)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp archive_update_result({1, _rows}, repo, id), do: Repository.get(repo, id)

  defp archive_update_result({0, _rows}, repo, id) do
    with {:ok, %WorkRequest{} = current} <- Repository.get(repo, id) do
      if current.archived_at do
        {:ok, current}
      else
        {:error, :not_completed}
      end
    end
  end

  defp archive_update_result({_count, _rows}, _repo, _id), do: {:error, {:constraint_failed, "multiple_work_request_archives"}}

  defp restore_completed(repo, %WorkRequest{} = work_request), do: restore_completed(repo, work_request, reset_completed_at?: true)

  defp restore_completed(_repo, %WorkRequest{archived_at: nil, archive_reason: nil} = work_request, _opts), do: {:ok, work_request}

  defp restore_completed(repo, %WorkRequest{} = work_request, opts) do
    reset_completed_at? = Keyword.get(opts, :reset_completed_at?, true)
    attrs = %{archived_at: nil, archive_reason: nil}
    attrs = if reset_completed_at?, do: Map.put(attrs, :completed_at, DateTime.utc_now(:microsecond)), else: attrs

    work_request
    |> Ecto.Changeset.change(attrs)
    |> update_work_request(repo)
  end

  defp update_work_request(changeset, repo) do
    repo.update(changeset)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
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

  defp terminal_work_package?(%{card: card}) when is_map(card) do
    status = map_value(card, :status)
    operational_state = map_value(card, :operational_state)
    key = if is_map(operational_state), do: map_value(operational_state, :key)

    status in @terminal_work_package_statuses or key in @terminal_work_package_statuses
  end

  defp terminal_work_package?(_context), do: false

  defp active_blocker_context?(%{active_blocker?: true}), do: true
  defp active_blocker_context?(%{blocker_state: %{active?: true}}), do: true

  defp active_blocker_context?(%{card: %{operational_state: operational_state}}) when is_map(operational_state) do
    map_value(operational_state, :key) == "blocked" or
      operational_state
      |> map_value(:attention_items)
      |> List.wrap()
      |> Enum.any?(&(is_map(&1) and map_value(&1, :key) == "active_blocker"))
  end

  defp active_blocker_context?(_context), do: false

  defp active_runtime_context?(%{active_runtime?: true}), do: true
  defp active_runtime_context?(%{runtime_state: %{active?: true}}), do: true

  defp active_runtime_context?(%{card: %{operational_state: operational_state}}) when is_map(operational_state) do
    map_value(operational_state, :has_active_worker) == true
  end

  defp active_runtime_context?(_context), do: false

  defp map_value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

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
        Map.put(active_by_id, blocker_id(event), map_value(event.payload || %{}, :active) == true)
      end)

    %{active?: Enum.any?(Map.values(active_by_id), & &1), latest_gate_at: latest_timestamp(Enum.map(blocker_events, & &1.created_at))}
  end

  defp blocker_event?(%ProgressEvent{payload: payload}) when is_map(payload) do
    blocker_event_payload?(payload)
  end

  defp blocker_event?(%ProgressEvent{}), do: false

  defp blocker_id(%ProgressEvent{payload: payload, idempotency_key: idempotency_key, id: id}) do
    payload = payload || %{}

    map_value(payload, :blocker_id)
    |> Kernel.||(idempotency_key)
    |> Kernel.||(id)
    |> normalize_blocker_id()
  end

  defp progress_event_order(%ProgressEvent{} = event) do
    {event.sequence || 0, timestamp_sort_value(event.created_at), event.id || ""}
  end

  defp runtime_state(grants, agent_runs) do
    %{active?: Enum.any?(grants, &active_grant?/1) or Enum.any?(agent_runs, &active_agent_run?/1), latest_gate_at: latest_runtime_gate_at(grants, agent_runs)}
  end

  defp active_grant?(%AccessGrant{grant_role: role, claimed_at: %DateTime{}, revoked_at: nil, expires_at: expires_at})
       when role in @active_grant_roles do
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
      |> Enum.map(&agent_run_gate_at/1)

    latest_timestamp(grant_timestamps ++ run_timestamps)
  end

  defp agent_run_gate_at(%AgentRun{finished_at: %DateTime{} = finished_at}), do: finished_at

  defp agent_run_gate_at(%AgentRun{status: status, last_seen_at: %DateTime{} = last_seen_at}) when status in ["starting", "running", "retrying"] do
    DateTime.add(last_seen_at, @stale_heartbeat_after_seconds, :second)
  end

  defp agent_run_gate_at(%AgentRun{} = run), do: run.updated_at

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
