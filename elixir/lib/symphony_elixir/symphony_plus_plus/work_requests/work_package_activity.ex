defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkPackageActivity do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent

  import Ecto.Query, only: [from: 2]

  @active_grant_roles ["worker", "architect"]
  @stale_heartbeat_after_seconds 300

  @spec blocker_event_payload?(map()) :: boolean()
  def blocker_event_payload?(payload) when is_map(payload) do
    map_value(payload, :type) == "blocker" and map_value(payload, :source_tool) in ["report_blocker", "resolve_blocker"]
  end

  @spec contexts(module(), [String.t()]) :: %{optional(String.t()) => map()}
  def contexts(_repo, []), do: %{}

  def contexts(repo, work_package_ids) when is_atom(repo) and is_list(work_package_ids) do
    work_package_ids =
      work_package_ids
      |> Enum.filter(&filled_string?/1)
      |> Enum.uniq()

    progress_events_by_id = grouped_progress_events(repo, work_package_ids)
    grants_by_id = grouped_access_grants(repo, work_package_ids)
    agent_runs_by_id = grouped_agent_runs(repo, work_package_ids)

    Map.new(work_package_ids, fn work_package_id ->
      {work_package_id,
       %{
         blocker_state: blocker_state(Map.get(progress_events_by_id, work_package_id, [])),
         runtime_state: runtime_state(Map.get(grants_by_id, work_package_id, []), Map.get(agent_runs_by_id, work_package_id, []))
       }}
    end)
  end

  @spec context(module(), String.t()) :: map()
  def context(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    repo
    |> contexts([work_package_id])
    |> Map.get(work_package_id, empty_context())
  end

  @spec empty_context() :: map()
  def empty_context do
    %{
      blocker_state: %{active?: false, latest_gate_at: nil},
      runtime_state: %{active?: false, latest_gate_at: nil}
    }
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

  defp blocker_event?(%ProgressEvent{payload: payload}) when is_map(payload), do: blocker_event_payload?(payload)
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

  defp map_value(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

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
end
