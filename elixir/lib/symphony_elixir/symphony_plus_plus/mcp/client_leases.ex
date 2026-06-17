defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClientLeases do
  @moduledoc false

  use GenServer

  @default_ttl_ms 10 * 60 * 1_000
  @default_idle_grace_ms 30 * 1_000
  @default_sweep_ms 30 * 1_000

  @type summary :: %{active_client_count: non_neg_integer(), stale_after_ms: pos_integer()}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.delete(opts, :name), name: name)
  end

  @spec attach(binary()) :: {:ok, summary()} | {:error, :unavailable}
  def attach(client_id), do: attach(client_id, [], __MODULE__)

  @spec attach(binary(), keyword() | GenServer.server()) :: {:ok, summary()} | {:error, :unavailable}
  def attach(client_id, opts) when is_list(opts), do: attach(client_id, opts, __MODULE__)
  def attach(client_id, server), do: attach(client_id, [], server)

  @spec attach(binary(), keyword(), GenServer.server()) :: {:ok, summary()} | {:error, :unavailable}
  def attach(client_id, opts, server), do: lease_call(server, {:attach, client_id, opts})

  @spec heartbeat(binary(), GenServer.server()) :: {:ok, summary()} | {:error, :unavailable}
  def heartbeat(client_id, server \\ __MODULE__), do: lease_call(server, {:heartbeat, client_id})

  @spec detach(binary(), GenServer.server()) :: {:ok, summary()} | {:error, :unavailable}
  def detach(client_id, server \\ __MODULE__), do: lease_call(server, {:detach, client_id})

  @spec active_count(GenServer.server()) :: non_neg_integer()
  def active_count(server \\ __MODULE__) do
    case lease_call(server, :active_count) do
      {:ok, %{active_client_count: count}} -> count
      {:error, _reason} -> 0
    end
  end

  @impl true
  def init(opts) do
    state = %{
      leases: %{},
      ttl_ms: option(opts, :ttl_ms, :mcp_client_lease_ttl_ms, @default_ttl_ms),
      idle_grace_ms: option(opts, :idle_grace_ms, :mcp_client_lease_idle_grace_ms, @default_idle_grace_ms),
      sweep_ms: option(opts, :sweep_ms, :mcp_client_lease_sweep_ms, @default_sweep_ms),
      shutdown: Keyword.get(opts, :shutdown, Application.get_env(:symphony_elixir, :mcp_client_lease_shutdown)),
      ever_attached?: false,
      shutdown_on_idle?: false,
      idle_since_ms: nil
    }

    schedule_sweep(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:attach, client_id, opts}, _from, state) do
    state = upsert_lease(state, client_id, opts)
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call({:heartbeat, client_id}, _from, state) do
    state = upsert_lease(state, client_id, [])
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call({:detach, client_id}, _from, state) do
    now = now_ms()

    state =
      state
      |> prune(now)
      |> Map.update!(:leases, &Map.delete(&1, client_id))
      |> mark_idle(now)

    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call(:active_count, _from, state) do
    state = prune(state, now_ms())
    {:reply, {:ok, summary(state)}, state}
  end

  defp upsert_lease(state, client_id, opts) do
    now = now_ms()
    shutdown_on_idle? = Keyword.get(opts, :shutdown_on_idle?, false)

    state
    |> prune(now)
    |> Map.update!(:leases, &Map.put(&1, client_id, %{last_seen_ms: now, shutdown_on_idle?: shutdown_on_idle?}))
    |> Map.merge(%{ever_attached?: true, shutdown_on_idle?: state.shutdown_on_idle? or shutdown_on_idle?, idle_since_ms: nil})
  end

  @impl true
  def handle_info(:sweep, state) do
    state =
      state
      |> prune(now_ms())
      |> maybe_stop_idle()

    schedule_sweep(state)
    {:noreply, state}
  end

  defp lease_call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp prune(%{leases: leases, ttl_ms: ttl_ms} = state, now) do
    %{state | leases: Map.filter(leases, fn {_id, lease} -> now - lease.last_seen_ms <= ttl_ms end)}
  end

  defp mark_idle(%{ever_attached?: true, leases: leases, idle_since_ms: nil} = state, now) when map_size(leases) == 0,
    do: %{state | idle_since_ms: now}

  defp mark_idle(state, _now), do: state

  defp maybe_stop_idle(%{ever_attached?: false} = state), do: state
  defp maybe_stop_idle(%{shutdown_on_idle?: false} = state), do: state
  defp maybe_stop_idle(%{leases: leases} = state) when map_size(leases) > 0, do: %{state | idle_since_ms: nil}
  defp maybe_stop_idle(%{idle_since_ms: nil} = state), do: %{state | idle_since_ms: now_ms()}

  defp maybe_stop_idle(%{idle_since_ms: idle_since, idle_grace_ms: idle_grace_ms} = state) do
    if now_ms() - idle_since >= idle_grace_ms do
      shutdown(state.shutdown)
    end

    state
  end

  defp shutdown(fun) when is_function(fun, 0), do: fun.()
  defp shutdown(_missing), do: System.stop(0)

  defp summary(%{leases: leases, ttl_ms: ttl_ms}) do
    %{active_client_count: map_size(leases), stale_after_ms: ttl_ms}
  end

  defp schedule_sweep(%{sweep_ms: sweep_ms}), do: Process.send_after(self(), :sweep, sweep_ms)

  defp option(opts, option_key, env_key, default) do
    value = Keyword.get(opts, option_key, Application.get_env(:symphony_elixir, env_key, default))

    if is_integer(value) and value > 0, do: value, else: default
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
