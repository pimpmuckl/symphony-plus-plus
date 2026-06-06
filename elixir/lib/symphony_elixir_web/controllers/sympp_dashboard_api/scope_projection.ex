defmodule SymphonyElixirWeb.SymppDashboardApi.ScopeProjection do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun

  @spec scope_package_payload_for_grant(AccessGrant.t(), map()) :: map()
  def scope_package_payload_for_grant(%AccessGrant{} = grant, payload) when is_map(payload) do
    scoped_package_payload({:grant, grant}, payload)
  end

  @spec scoped_package_payload(term(), map()) :: map()
  def scoped_package_payload({:grant, %AccessGrant{grant_role: "worker", capabilities: capabilities} = grant}, payload)
      when is_map(payload) do
    if has_capability?(capabilities, "read:phase") do
      payload
    else
      scope_worker_package_payload(payload, grant)
    end
  end

  def scoped_package_payload(_auth_context, payload), do: payload

  defp scope_worker_package_payload(payload, grant) do
    payload
    |> scope_grants(grant)
    |> scope_agent_runs(grant)
    |> redact_worker_activity_identifiers()
    |> redact_worker_metadata_identifiers()
  end

  defp scope_grants(payload, %AccessGrant{id: grant_id}) do
    case fetch_payload_field(payload, :grants) do
      {:ok, grants_key, grants} when is_list(grants) ->
        grants = Enum.filter(grants, &(Map.get(&1, :id) == grant_id or Map.get(&1, "id") == grant_id))

        payload
        |> Map.put(grants_key, grants)
        |> put_summary_count(:grant_count, length(grants))
        |> put_summary_count(:active_grant_count, Enum.count(grants, &grant_active?/1))

      _missing ->
        payload
    end
  end

  defp scope_agent_runs(payload, %AccessGrant{id: grant_id}) do
    case fetch_payload_field(payload, :agent_runs) do
      {:ok, runs_key, runs} when is_list(runs) ->
        runs = Enum.filter(runs, &(Map.get(&1, :access_grant_id) == grant_id or Map.get(&1, "access_grant_id") == grant_id))

        payload
        |> Map.put(runs_key, runs)
        |> put_active_agent_run(runs)
        |> put_summary_count(:agent_run_count, length(runs))
        |> put_summary_count(:active_agent_run_count, Enum.count(runs, &agent_run_in_flight?/1))
        |> put_summary_count(:queued_agent_run_count, Enum.count(runs, &(runtime_state(&1) == "queued")))
        |> put_summary_count(:stopped_agent_run_count, Enum.count(runs, &(runtime_state(&1) == "stopped")))
        |> put_summary_count(:failed_agent_run_count, Enum.count(runs, &agent_run_failed?/1))
        |> put_summary_count(:stale_agent_run_count, Enum.count(runs, &agent_run_stale?/1))
        |> put_runtime_summary(runs)
        |> put_top_level_runtime_summary(runs)
        |> scope_run_alerts(runs)

      _missing ->
        payload
    end
  end

  defp fetch_payload_field(payload, key) when is_atom(key) do
    cond do
      Map.has_key?(payload, key) -> {:ok, key, Map.fetch!(payload, key)}
      Map.has_key?(payload, Atom.to_string(key)) -> {:ok, Atom.to_string(key), Map.fetch!(payload, Atom.to_string(key))}
      true -> :error
    end
  end

  defp put_summary_count(%{"summary" => summary} = payload, key, count) when is_map(summary) and is_atom(key) do
    put_in(payload, ["summary", Atom.to_string(key)], count)
  end

  defp put_summary_count(%{summary: summary} = payload, key, count) when is_map(summary) and is_atom(key) do
    Map.update!(payload, :summary, &Map.put(&1, key, count))
  end

  defp put_summary_count(payload, _key, _count), do: payload

  defp put_active_agent_run(payload, runs) do
    active_agent_run = runs |> Enum.filter(&(runtime_state(&1) in ["active", "queued"])) |> List.last()

    case fetch_payload_field(payload, :active_agent_run) do
      {:ok, key, _run} -> Map.put(payload, key, active_agent_run)
      _missing -> Map.put(payload, :active_agent_run, active_agent_run)
    end
  end

  defp put_runtime_summary(%{"summary" => summary} = payload, runs) when is_map(summary) do
    runtime = runtime_summary(runs, Map.get(summary, "runtime"))
    put_in(payload, ["summary", "runtime"], runtime)
  end

  defp put_runtime_summary(%{summary: summary} = payload, runs) when is_map(summary) do
    runtime = runtime_summary(runs, Map.get(summary, :runtime))
    Map.update!(payload, :summary, &Map.put(&1, :runtime, runtime))
  end

  defp put_runtime_summary(payload, _runs), do: payload

  defp put_top_level_runtime_summary(%{"runtime" => runtime} = payload, runs) when is_map(runtime) do
    Map.put(payload, "runtime", runtime_summary(runs, runtime))
  end

  defp put_top_level_runtime_summary(%{runtime: runtime} = payload, runs) when is_map(runtime) do
    Map.put(payload, :runtime, runtime_summary(runs, runtime))
  end

  defp put_top_level_runtime_summary(payload, _runs), do: payload

  defp runtime_summary(runs, existing_runtime) do
    threshold =
      case existing_runtime do
        %{} -> Map.get(existing_runtime, :stale_heartbeat_after_seconds) || Map.get(existing_runtime, "stale_heartbeat_after_seconds") || 300
        _runtime -> 300
      end

    %{
      stale_heartbeat_after_seconds: threshold,
      active_count: Enum.count(runs, &(runtime_state(&1) == "active")),
      queued_count: Enum.count(runs, &(runtime_state(&1) == "queued")),
      stopped_count: Enum.count(runs, &(runtime_state(&1) == "stopped")),
      failed_count: Enum.count(runs, &agent_run_failed?/1),
      completed_count: Enum.count(runs, &agent_run_completed?/1),
      terminal_count: Enum.count(runs, &(runtime_state(&1) in ["stopped", "terminal"])),
      stale_count: Enum.count(runs, &agent_run_stale?(&1, threshold))
    }
  end

  defp scope_run_alerts(payload, runs) do
    stale_threshold = runtime_stale_threshold(payload)

    payload
    |> update_alert_indicator(
      "stale_heartbeat",
      Enum.count(runs, &agent_run_stale?(&1, stale_threshold)),
      &"#{&1} run(s) past #{stale_threshold}s"
    )
    |> update_alert_indicator("failed_run", Enum.count(runs, &agent_run_failed?/1), &"#{&1} failed run(s)")
  end

  defp runtime_stale_threshold(payload) do
    case fetch_payload_field(payload, :summary) do
      {:ok, _key, summary} when is_map(summary) ->
        case fetch_payload_field(summary, :runtime) do
          {:ok, _key, runtime} when is_map(runtime) ->
            Map.get(runtime, :stale_heartbeat_after_seconds) || Map.get(runtime, "stale_heartbeat_after_seconds") || 300

          _missing ->
            300
        end

      _missing ->
        300
    end
  end

  defp update_alert_indicator(payload, type, count, detail_fun) do
    case fetch_payload_field(payload, :alert_indicators) do
      {:ok, key, alerts} when is_list(alerts) ->
        Map.put(payload, key, Enum.map(alerts, &update_run_alert(&1, type, count, detail_fun)))

      _missing ->
        payload
    end
  end

  defp update_run_alert(alert, type, count, detail_fun) when is_map(alert) do
    if Map.get(alert, :type) == type or Map.get(alert, "type") == type do
      alert
      |> put_alert_field(:active, count > 0)
      |> put_alert_field(:detail, detail_fun.(count))
    else
      alert
    end
  end

  defp put_alert_field(alert, field, value) do
    cond do
      Map.has_key?(alert, field) -> Map.put(alert, field, value)
      Map.has_key?(alert, Atom.to_string(field)) -> Map.put(alert, Atom.to_string(field), value)
      true -> Map.put(alert, field, value)
    end
  end

  defp grant_active?(grant), do: Map.get(grant, :status) == "active" or Map.get(grant, "status") == "active"

  defp agent_run_in_flight?(run) do
    status = Map.get(run, :status) || Map.get(run, "status")
    status in AgentRun.active_statuses() or runtime_state(run) in ["active", "queued"]
  end

  defp agent_run_failed?(run), do: (Map.get(run, :status) || Map.get(run, "status")) == "failed"
  defp agent_run_completed?(run), do: (Map.get(run, :status) || Map.get(run, "status")) == "completed"
  defp agent_run_stale?(run), do: agent_run_stale?(run, 300)

  defp agent_run_stale?(run, threshold_seconds) do
    cond do
      Map.get(run, :stale) == true or Map.get(run, "stale") == true ->
        true

      runtime_state(run) in ["active", "queued"] ->
        stale_last_seen?(Map.get(run, :last_seen_at) || Map.get(run, "last_seen_at"), threshold_seconds)

      true ->
        false
    end
  end

  defp stale_last_seen?(%DateTime{} = last_seen_at, threshold_seconds) do
    DateTime.diff(DateTime.utc_now(:microsecond), last_seen_at, :second) >= threshold_seconds
  end

  defp stale_last_seen?(last_seen_at, threshold_seconds) when is_binary(last_seen_at) do
    case DateTime.from_iso8601(last_seen_at) do
      {:ok, datetime, _offset} -> stale_last_seen?(datetime, threshold_seconds)
      {:error, _reason} -> false
    end
  end

  defp stale_last_seen?(_last_seen_at, _threshold_seconds), do: false

  defp runtime_state(run) do
    Map.get(run, :runtime_state) || Map.get(run, "runtime_state") || runtime_state_from_status(Map.get(run, :status) || Map.get(run, "status"))
  end

  defp runtime_state_from_status("starting"), do: "queued"
  defp runtime_state_from_status(status) when status in ["running", "retrying"], do: "active"
  defp runtime_state_from_status("stopped"), do: "stopped"
  defp runtime_state_from_status(status) when status in ["completed", "failed"], do: "terminal"
  defp runtime_state_from_status(_status), do: nil

  defp redact_worker_activity_identifiers(payload) do
    [:progress, :findings, :events, :blockers]
    |> Enum.reduce(payload, fn field, payload -> redact_worker_activity_field(payload, field) end)
  end

  defp redact_worker_activity_field(payload, field) do
    case fetch_payload_field(payload, field) do
      {:ok, field_key, values} when is_list(values) ->
        Map.put(payload, field_key, Enum.map(values, &redact_activity_identifier_fields/1))

      _missing_or_non_list ->
        payload
    end
  end

  defp redact_worker_metadata_identifiers(payload) do
    case fetch_payload_field(payload, :metadata) do
      {:ok, field_key, metadata} when is_map(metadata) ->
        Map.put(payload, field_key, redact_activity_identifier_fields(metadata))

      _missing_or_non_map ->
        payload
    end
  end

  defp redact_activity_identifier_fields(%{} = value) do
    Map.new(value, fn {key, field_value} ->
      cond do
        activity_identifier_key?(key) -> {key, redacted_identifier(field_value)}
        activity_actor_key?(key) -> {key, redact_activity_actor_identifier_fields(field_value)}
        true -> {key, redact_activity_identifier_fields(field_value)}
      end
    end)
  end

  defp redact_activity_identifier_fields(values) when is_list(values), do: Enum.map(values, &redact_activity_identifier_fields/1)
  defp redact_activity_identifier_fields(value), do: value

  defp activity_identifier_key?(key) when key in [:access_grant_id, :agent_run_id, "access_grant_id", "agent_run_id"], do: true
  defp activity_identifier_key?(_key), do: false

  defp activity_actor_key?(key) when key in [:actor, "actor"], do: true
  defp activity_actor_key?(_key), do: false

  defp redact_activity_actor_identifier_fields(%{} = actor) do
    actor
    |> redact_existing_identifier_key(:id)
    |> redact_existing_identifier_key("id")
    |> redact_activity_identifier_fields()
  end

  defp redact_activity_actor_identifier_fields(value), do: redact_activity_identifier_fields(value)

  defp redact_existing_identifier_key(map, key) do
    if Map.has_key?(map, key), do: Map.update!(map, key, &redacted_identifier/1), else: map
  end

  defp redacted_identifier(nil), do: nil
  defp redacted_identifier(""), do: ""
  defp redacted_identifier(_value), do: "[REDACTED]"

  @spec has_capability?(term(), String.t()) :: boolean()
  def has_capability?(capabilities, capability) when is_list(capabilities), do: capability in capabilities
  def has_capability?(_capabilities, _capability), do: false
end
