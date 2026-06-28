defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClientLeases do
  @moduledoc """
  Tracks stdio bridge heartbeat freshness for `/mcp/client-lease`.

  Bridge lease files under `codex-plugin-leases` are the runtime liveness
  authority. This process never stops the BEAM; launcher cleanup uses bridge
  lease files so old managed runtimes can drain after plugin upgrades.
  """

  use GenServer

  @default_ttl_ms 10 * 60 * 1_000
  @default_sweep_ms 30 * 1_000
  @actions ["attach", "heartbeat", "detach"]

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

  @spec ensure_started() :: :ok | {:error, :client_lease_unavailable}
  def ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> :ok
      nil -> start_lease_store()
    end
  end

  @spec handle_payload(map()) :: {:ok, summary()} | {:error, atom()}
  def handle_payload(payload) when is_map(payload) do
    with {:ok, client_id} <- lease_id(payload),
         {:ok, action} <- lease_action(payload),
         :ok <- ensure_started() do
      apply_lease_action(action, client_id)
    end
  end

  def handle_payload(_payload), do: {:error, :invalid_request}

  @spec attach(binary()) :: {:ok, summary()} | {:error, :unavailable}
  def attach(client_id), do: attach(client_id, __MODULE__)

  @spec attach(binary(), GenServer.server()) :: {:ok, summary()} | {:error, :unavailable}
  def attach(client_id, server), do: lease_call(server, {:attach, client_id})

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
      sweep_ms: option(opts, :sweep_ms, :mcp_client_lease_sweep_ms, @default_sweep_ms)
    }

    schedule_sweep(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:attach, client_id}, _from, state) do
    state = upsert_lease(state, client_id)
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call({:heartbeat, client_id}, _from, state) do
    state = upsert_lease(state, client_id)
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call({:detach, client_id}, _from, state) do
    now = now_ms()

    state =
      state
      |> prune(now)
      |> Map.update!(:leases, &Map.delete(&1, client_id))

    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call(:active_count, _from, state) do
    state = prune(state, now_ms())
    {:reply, {:ok, summary(state)}, state}
  end

  defp upsert_lease(state, client_id) do
    now = now_ms()

    state
    |> prune(now)
    |> Map.update!(:leases, &Map.put(&1, client_id, %{last_seen_ms: now}))
  end

  @impl true
  def handle_info(:sweep, state) do
    state = prune(state, now_ms())

    schedule_sweep(state)
    {:noreply, state}
  end

  defp lease_call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp start_lease_store do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) -> start_supervised_lease_store()
      nil -> start_direct_lease_store()
    end
  end

  defp start_supervised_lease_store do
    case Supervisor.restart_child(SymphonyElixir.Supervisor, __MODULE__) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
      {:error, :not_found} -> add_supervised_lease_store()
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> {:error, :client_lease_unavailable}
    end
  catch
    :exit, _reason -> {:error, :client_lease_unavailable}
  end

  defp add_supervised_lease_store do
    case Supervisor.start_child(SymphonyElixir.Supervisor, __MODULE__) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> {:error, :client_lease_unavailable}
    end
  end

  defp start_direct_lease_store do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> {:error, :client_lease_unavailable}
    end
  end

  defp apply_lease_action("attach", client_id), do: normalize_lease_result(attach(client_id))
  defp apply_lease_action("heartbeat", client_id), do: normalize_lease_result(heartbeat(client_id))
  defp apply_lease_action("detach", client_id), do: normalize_lease_result(detach(client_id))

  defp normalize_lease_result({:ok, result}), do: {:ok, result}
  defp normalize_lease_result({:error, _reason}), do: {:error, :client_lease_unavailable}

  defp prune(%{leases: leases, ttl_ms: ttl_ms} = state, now) do
    %{state | leases: Map.filter(leases, fn {_id, lease} -> now - lease.last_seen_ms <= ttl_ms end)}
  end

  defp summary(%{leases: leases, ttl_ms: ttl_ms}) do
    %{active_client_count: map_size(leases), stale_after_ms: ttl_ms}
  end

  defp schedule_sweep(%{sweep_ms: sweep_ms}), do: Process.send_after(self(), :sweep, sweep_ms)

  defp lease_id(%{"client_id" => client_id}) when is_binary(client_id) do
    client_id = String.trim(client_id)

    if client_id != "" and byte_size(client_id) <= 160 and visible_ascii?(client_id),
      do: {:ok, client_id},
      else: {:error, :invalid_client_id}
  end

  defp lease_id(_payload), do: {:error, :invalid_client_id}

  defp lease_action(%{"action" => action}) when action in @actions, do: {:ok, action}
  defp lease_action(_payload), do: {:error, :invalid_action}

  defp visible_ascii?(<<>>), do: true
  defp visible_ascii?(<<byte, rest::binary>>) when byte >= 0x21 and byte <= 0x7E, do: visible_ascii?(rest)
  defp visible_ascii?(_value), do: false

  defp option(opts, option_key, env_key, default) do
    value = Keyword.get(opts, option_key, Application.get_env(:symphony_elixir, env_key, default))

    if is_integer(value) and value > 0, do: value, else: default
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
