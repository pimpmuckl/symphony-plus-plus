defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkPackageActivity do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  import Ecto.Query, only: [from: 2]

  @active_grant_roles ["worker", "architect"]
  @current_claim_lease_statuses ["active", "paused"]
  @terminal_package_statuses ["merged", "merged_into_phase", "closed", "abandoned"]
  @recycle_source_tools ["claim_local_assignment", "revoke_child_worker_key", "revoke_planned_slice_worker_key"]
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
    claim_leases_by_id = grouped_claim_leases(repo, work_package_ids)
    work_packages_by_id = grouped_work_packages(repo, work_package_ids)

    Map.new(work_package_ids, fn work_package_id ->
      progress_events = Map.get(progress_events_by_id, work_package_id, [])
      work_package = Map.get(work_packages_by_id, work_package_id)

      {work_package_id,
       %{
         blocker_state: blocker_state(progress_events),
         runtime_state:
           runtime_state(
             Map.get(grants_by_id, work_package_id, []),
             Map.get(agent_runs_by_id, work_package_id, []),
             Map.get(claim_leases_by_id, work_package_id, []),
             progress_events,
             work_package
           )
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
      blocker_state: %{active?: false, active_ids: [], latest_gate_at: nil, reason_codes: []},
      runtime_state: %{
        active?: false,
        paused?: false,
        stale?: false,
        recycled?: false,
        terminal?: false,
        lifecycle_state: "idle",
        latest_gate_at: nil,
        reason_codes: []
      }
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

  defp grouped_claim_leases(repo, work_package_ids) do
    repo.all(
      from(claim_lease in ClaimLease,
        where: claim_lease.work_package_id in ^work_package_ids,
        order_by: [asc: claim_lease.work_package_id, asc: claim_lease.inserted_at, asc: claim_lease.id]
      )
    )
    |> Enum.group_by(& &1.work_package_id)
  end

  defp grouped_work_packages(repo, work_package_ids) do
    repo.all(from(work_package in WorkPackage, where: work_package.id in ^work_package_ids))
    |> Map.new(&{&1.id, &1})
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

    active_ids =
      active_by_id
      |> Enum.filter(fn {_id, active?} -> active? end)
      |> Enum.map(fn {id, _active?} -> id end)
      |> Enum.sort()

    %{
      active?: active_ids != [],
      active_ids: active_ids,
      latest_gate_at: latest_timestamp(Enum.map(blocker_events, & &1.created_at)),
      reason_codes: blocker_reason_codes(active_ids, blocker_events)
    }
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

  defp runtime_state(grants, agent_runs, claim_leases, progress_events, work_package) do
    now = DateTime.utc_now(:microsecond)
    current_claim_leases = Enum.filter(claim_leases, &current_claim_lease?/1)
    paused? = Enum.any?(current_claim_leases, &paused_claim_lease?/1)
    stale_claim_leases = Enum.filter(current_claim_leases, &stale_claim_lease?(&1, now))
    active_claim_leases = Enum.filter(current_claim_leases, &active_claim_lease?(&1, now))
    stale_agent_runs = if paused?, do: [], else: Enum.filter(agent_runs, &stale_agent_run?(&1, now))
    active_agent_runs = if paused?, do: [], else: Enum.filter(agent_runs, &active_agent_run?(&1, now))
    active_grants = active_grants(grants, current_claim_leases, paused?, now)
    recycled? = recycled_runtime?(claim_leases, progress_events)
    terminal? = terminal_package?(work_package)
    active_runtime_evidence? = active_claim_leases != [] or active_agent_runs != [] or active_grants != []
    active? = not paused? and stale_claim_leases == [] and active_runtime_evidence?
    stale? = not paused? and (stale_claim_leases != [] or stale_agent_runs != [])

    reason_codes =
      runtime_reason_codes(
        active_grants,
        active_agent_runs,
        active_claim_leases,
        stale_agent_runs,
        stale_claim_leases,
        paused?,
        recycled?,
        terminal?
      )

    %{
      active?: active?,
      paused?: paused?,
      stale?: stale?,
      recycled?: recycled?,
      terminal?: terminal?,
      lifecycle_state: runtime_lifecycle_state(active?, paused?, stale?, recycled?, terminal?),
      latest_gate_at: latest_runtime_gate_at(grants, agent_runs, claim_leases, progress_events, work_package, now),
      reason_codes: reason_codes
    }
  end

  defp active_grant?(%AccessGrant{grant_role: role, claimed_at: %DateTime{}, revoked_at: nil, expires_at: expires_at}, %DateTime{} = now)
       when role in @active_grant_roles do
    is_nil(expires_at) or DateTime.compare(expires_at, now) == :gt
  end

  defp active_grant?(%AccessGrant{}, %DateTime{}), do: false

  defp active_agent_run?(%AgentRun{status: status} = run, %DateTime{} = now) do
    status in AgentRun.active_statuses() and not stale_agent_run?(run, now)
  end

  defp stale_agent_run?(%AgentRun{status: status, last_seen_at: %DateTime{} = last_seen_at}, %DateTime{} = now)
       when status in ["starting", "running", "retrying"] do
    DateTime.diff(now, last_seen_at, :second) >= @stale_heartbeat_after_seconds
  end

  defp stale_agent_run?(%AgentRun{}, %DateTime{}), do: false

  defp current_claim_lease?(%ClaimLease{status: status}), do: status in @current_claim_lease_statuses

  defp paused_claim_lease?(%ClaimLease{status: "paused"}), do: true
  defp paused_claim_lease?(%ClaimLease{}), do: false

  defp active_claim_lease?(%ClaimLease{status: "active"} = claim_lease, %DateTime{} = now), do: not stale_claim_lease?(claim_lease, now)
  defp active_claim_lease?(%ClaimLease{}, %DateTime{}), do: false

  defp stale_claim_lease?(%ClaimLease{status: "paused"}, %DateTime{}), do: false

  defp stale_claim_lease?(%ClaimLease{} = claim_lease, %DateTime{} = now) do
    claim_lease_expired?(claim_lease, now) or claim_lease_heartbeat_stale?(claim_lease, now)
  end

  defp active_grants(_grants, _current_claim_leases, true = _paused?, _now), do: []
  defp active_grants(_grants, current_claim_leases, _paused?, _now) when current_claim_leases != [], do: []
  defp active_grants(grants, [], false, %DateTime{} = now), do: Enum.filter(grants, &active_grant?(&1, now))

  defp recycled_runtime?(claim_leases, progress_events) do
    Enum.any?(claim_leases, &reclaimed_claim_lease?/1) or Enum.any?(progress_events, &recycle_event?/1)
  end

  defp reclaimed_claim_lease?(%ClaimLease{status: "reclaimed"}), do: true

  defp reclaimed_claim_lease?(%ClaimLease{previous_claim_id: previous_claim_id}) when is_binary(previous_claim_id) do
    String.trim(previous_claim_id) != ""
  end

  defp reclaimed_claim_lease?(%ClaimLease{}), do: false

  defp recycle_event?(%ProgressEvent{payload: payload}) when is_map(payload) do
    map_value(payload, :source_tool) in @recycle_source_tools
  end

  defp recycle_event?(%ProgressEvent{}), do: false

  defp terminal_package?(%WorkPackage{status: status}), do: status in @terminal_package_statuses
  defp terminal_package?(_work_package), do: false

  defp latest_runtime_gate_at(grants, agent_runs, claim_leases, progress_events, work_package, %DateTime{} = now) do
    grant_timestamps =
      grants
      |> Enum.reject(&active_grant?(&1, now))
      |> Enum.map(fn %AccessGrant{} = grant -> grant.revoked_at || expired_at(grant, now) || grant.updated_at end)

    run_timestamps =
      agent_runs
      |> Enum.reject(&active_agent_run?(&1, now))
      |> Enum.map(&agent_run_gate_at/1)

    claim_timestamps =
      claim_leases
      |> Enum.reject(&active_claim_lease?(&1, now))
      |> Enum.map(&claim_lease_gate_at/1)

    recycle_timestamps =
      progress_events
      |> Enum.filter(&recycle_event?/1)
      |> Enum.map(& &1.created_at)

    terminal_timestamps =
      case work_package do
        %WorkPackage{} ->
          if(terminal_package?(work_package), do: [work_package.updated_at], else: [])

        _work_package ->
          []
      end

    timestamps = grant_timestamps ++ run_timestamps ++ claim_timestamps ++ recycle_timestamps ++ terminal_timestamps

    latest_timestamp(timestamps)
  end

  defp agent_run_gate_at(%AgentRun{finished_at: %DateTime{} = finished_at}), do: finished_at

  defp agent_run_gate_at(%AgentRun{status: status, last_seen_at: %DateTime{} = last_seen_at}) when status in ["starting", "running", "retrying"] do
    DateTime.add(last_seen_at, @stale_heartbeat_after_seconds, :second)
  end

  defp agent_run_gate_at(%AgentRun{} = run), do: run.updated_at

  defp expired_at(%AccessGrant{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    if DateTime.compare(expires_at, now) in [:lt, :eq], do: expires_at
  end

  defp expired_at(%AccessGrant{}, %DateTime{}), do: nil

  defp blocker_reason_codes([], []), do: []
  defp blocker_reason_codes([], _blocker_events), do: ["blocker_resolved"]
  defp blocker_reason_codes(_active_ids, _blocker_events), do: ["active_blocker"]

  defp runtime_reason_codes(active_grants, active_agent_runs, active_claim_leases, stale_agent_runs, stale_claim_leases, paused?, recycled?, terminal?) do
    [
      if(terminal?, do: "package_terminal"),
      if(paused?, do: "claim_lease_paused"),
      if(stale_claim_leases != [], do: "claim_lease_stale"),
      if(stale_agent_runs != [], do: "agent_run_stale"),
      if(active_claim_leases != [], do: "claim_lease_active"),
      if(active_agent_runs != [], do: "agent_run_active"),
      active_grant_reason_code(active_grants),
      if(recycled?, do: "worker_recycled")
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp active_grant_reason_code([]), do: nil

  defp active_grant_reason_code(grants) do
    grants
    |> Enum.map(fn %AccessGrant{grant_role: role} -> "#{role}_grant_active" end)
    |> Enum.uniq()
  end

  defp runtime_lifecycle_state(_active?, true = _paused?, _stale?, _recycled?, _terminal?), do: "paused"
  defp runtime_lifecycle_state(_active?, _paused?, true = _stale?, _recycled?, _terminal?), do: "stale"
  defp runtime_lifecycle_state(true = _active?, _paused?, _stale?, _recycled?, _terminal?), do: "active"
  defp runtime_lifecycle_state(_active?, _paused?, _stale?, _recycled?, true = _terminal?), do: "terminal"
  defp runtime_lifecycle_state(_active?, _paused?, _stale?, true = _recycled?, _terminal?), do: "recycled"
  defp runtime_lifecycle_state(_active?, _paused?, _stale?, _recycled?, _terminal?), do: "idle"

  defp claim_lease_gate_at(%ClaimLease{status: "paused"} = claim_lease) do
    latest_timestamp([claim_lease.paused_at, claim_lease.updated_at])
  end

  defp claim_lease_gate_at(%ClaimLease{status: "active"} = claim_lease),
    do: latest_timestamp([claim_lease.lease_expires_at, claim_lease_stale_at(claim_lease)])

  defp claim_lease_gate_at(%ClaimLease{status: "reclaimed"} = claim_lease),
    do: latest_timestamp([claim_lease.reclaimed_at, claim_lease.updated_at])

  defp claim_lease_gate_at(%ClaimLease{status: "released"} = claim_lease),
    do: latest_timestamp([claim_lease.released_at, claim_lease.updated_at])

  defp claim_lease_gate_at(%ClaimLease{} = claim_lease) do
    latest_timestamp([claim_lease.reclaimed_at, claim_lease.released_at, claim_lease.paused_at, claim_lease.updated_at])
  end

  defp claim_lease_stale_at(%ClaimLease{last_seen_at: %DateTime{} = last_seen_at, stale_after_ms: stale_after_ms})
       when is_integer(stale_after_ms) and stale_after_ms > 0 do
    DateTime.add(last_seen_at, stale_after_ms, :millisecond)
  end

  defp claim_lease_stale_at(%ClaimLease{}), do: nil

  defp claim_lease_expired?(%ClaimLease{lease_expires_at: %DateTime{} = expires_at}, %DateTime{} = now), do: DateTime.compare(expires_at, now) != :gt
  defp claim_lease_expired?(%ClaimLease{}, %DateTime{}), do: false

  defp claim_lease_heartbeat_stale?(%ClaimLease{} = claim_lease, %DateTime{} = now) do
    case claim_lease_stale_at(claim_lease) do
      %DateTime{} = stale_at -> DateTime.compare(stale_at, now) != :gt
      nil -> false
    end
  end

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
