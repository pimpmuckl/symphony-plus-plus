defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.ScopeProjectionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixirWeb.SymppDashboardApi.ScopeProjection

  test "worker scoping filters runtime payloads and recomputes summaries" do
    grant = %AccessGrant{id: "grant-owned", grant_role: "worker", capabilities: []}
    stale_seen_at = DateTime.add(DateTime.utc_now(:microsecond), -600, :second)

    payload =
      ScopeProjection.scope_package_payload_for_grant(grant, %{
        active_agent_run: %{id: "run-other", access_grant_id: "grant-other", status: "running"},
        agent_runs: [
          %{id: "run-owned", access_grant_id: grant.id, status: "running", last_seen_at: stale_seen_at},
          %{id: "run-other", access_grant_id: "grant-other", status: "running"}
        ],
        runtime: %{
          stale_heartbeat_after_seconds: 300,
          active_count: 2,
          queued_count: 0,
          stopped_count: 0,
          failed_count: 0,
          completed_count: 0,
          terminal_count: 0,
          stale_count: 1
        },
        summary: %{runtime: %{stale_heartbeat_after_seconds: 300}},
        alert_indicators: [
          %{type: "stale_heartbeat", active: false, detail: "0 run(s) past 300s"},
          %{type: "failed_run", active: false, detail: "0 failed run(s)"}
        ]
      })

    alerts = Map.new(payload.alert_indicators, &{&1.type, &1})

    assert [%{id: "run-owned"}] = payload.agent_runs
    assert payload.active_agent_run.id == "run-owned"
    assert payload.summary.active_agent_run_count == 1
    assert payload.summary.stale_agent_run_count == 1
    assert payload.summary.runtime.active_count == 1
    assert payload.summary.runtime.stale_count == 1
    assert payload.runtime.active_count == 1
    assert payload.runtime.stale_count == 1
    assert alerts["stale_heartbeat"].active == true
    assert alerts["stale_heartbeat"].detail == "1 run(s) past 300s"
  end

  test "phase-capable worker grants keep the full payload" do
    grant = %AccessGrant{id: "grant-owned", grant_role: "worker", capabilities: ["read:phase"]}
    payload = %{grants: [%{id: "grant-owned"}, %{id: "grant-other"}], worker_secret_handoffs: [%{target: "handoff"}]}

    assert ScopeProjection.scope_package_payload_for_grant(grant, payload) == payload
  end
end
