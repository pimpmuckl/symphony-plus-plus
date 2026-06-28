defmodule SymphonyElixir.SymphonyPlusPlus.MCPClientLeasesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.MCP.ClientLeases

  test "tracks clients by lease id" do
    server = start_supervised!({ClientLeases, name: :"#{__MODULE__}.tracks"})

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    assert {:ok, %{active_client_count: 1}} = ClientLeases.heartbeat("client-a", server)
    assert {:ok, %{active_client_count: 2}} = ClientLeases.attach("client-b", server)
    assert {:ok, %{active_client_count: 1}} = ClientLeases.detach("client-a", server)
    assert ClientLeases.active_count(server) == 1
  end

  test "stale leases are pruned without runtime shutdown authority" do
    server = start_lease_server("stale-prune")

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    Process.sleep(10)
    send(server, :sweep)

    assert ClientLeases.active_count(server) == 0
  end

  test "heartbeats remain telemetry only" do
    server = start_lease_server("telemetry")

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    Process.sleep(10)
    send(server, :sweep)

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    Process.sleep(10)
    send(server, :sweep)

    Process.sleep(10)
    send(server, :sweep)
    assert ClientLeases.active_count(server) == 0
  end

  defp start_lease_server(name) do
    opts = [
      name: :"#{__MODULE__}.#{name}",
      ttl_ms: 5,
      sweep_ms: 60_000
    ]

    start_supervised!({ClientLeases, opts})
  end
end
