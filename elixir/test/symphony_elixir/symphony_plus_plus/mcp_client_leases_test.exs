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

  test "unmanaged stale leases do not trigger shutdown" do
    parent = self()
    ref = make_ref()

    server = start_lease_server("unmanaged", parent, ref)

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", server)
    Process.sleep(10)
    send(server, :sweep)
    refute_receive {:idle_shutdown, ^ref}, 20

    Process.sleep(10)
    send(server, :sweep)
    refute_receive {:idle_shutdown, ^ref}, 20
  end

  test "managed stale leases must stay empty through the idle grace before shutdown" do
    parent = self()
    ref = make_ref()

    server = start_lease_server("idle", parent, ref)

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", [shutdown_on_idle?: true], server)
    Process.sleep(10)
    send(server, :sweep)
    refute_receive {:idle_shutdown, ^ref}, 20

    assert {:ok, %{active_client_count: 1}} = ClientLeases.attach("client-a", [shutdown_on_idle?: true], server)
    Process.sleep(10)
    send(server, :sweep)
    refute_receive {:idle_shutdown, ^ref}, 20

    Process.sleep(10)
    send(server, :sweep)
    assert_receive {:idle_shutdown, ^ref}, 100
  end

  defp start_lease_server(name, parent, ref) do
    opts = [
      name: :"#{__MODULE__}.#{name}",
      ttl_ms: 5,
      idle_grace_ms: 5,
      sweep_ms: 60_000,
      shutdown: fn -> send(parent, {:idle_shutdown, ref}) end
    ]

    start_supervised!({ClientLeases, opts})
  end
end
