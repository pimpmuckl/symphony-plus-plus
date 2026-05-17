defmodule Mix.Tasks.Sympp.Cockpit do
  @moduledoc false

  use Mix.Task

  alias SymphonyElixir.HttpServer
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixirWeb.Endpoint

  @shortdoc "Starts the local Symphony++ operator cockpit"
  @default_host "127.0.0.1"
  @default_port 4057
  @board_path "/sympp/board"
  @switches [
    database: :string,
    host: :string,
    port: :integer,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      :help ->
        Mix.shell().info(usage())

      {:ok, opts} ->
        run_cockpit(opts)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @spec usage() :: String.t()
  def usage do
    [
      "Usage: mix sympp.cockpit",
      "[--database <sqlite-path>]",
      "[--host <loopback-host>]",
      "[--port <port>]"
    ]
    |> Enum.join(" ")
  end

  @doc false
  @spec parse_args_for_test([String.t()]) :: :help | {:ok, keyword()} | {:error, String.t()}
  def parse_args_for_test(args), do: parse_args(args)

  @doc false
  @spec endpoint_config_for_test(keyword()) :: keyword()
  def endpoint_config_for_test(opts), do: endpoint_config(Keyword.get(opts, :endpoint_config, []), opts)

  @doc false
  @spec cockpit_url_for_test(keyword(), non_neg_integer()) :: String.t()
  def cockpit_url_for_test(opts, port), do: cockpit_url(opts, port)

  @doc false
  @spec run_cockpit_for_test(keyword(), (-> term())) :: term()
  def run_cockpit_for_test(opts, wait_fun) when is_function(wait_fun, 0) do
    run_cockpit(opts, wait_fun)
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> validate_opts(opts)
      {_opts, _argv, _invalid} -> {:error, usage()}
    end
  end

  defp validate_opts(opts) do
    cond do
      Keyword.get(opts, :help, false) ->
        :help

      has_blank_option?(opts, [:database, :host]) ->
        {:error, usage()}

      not loopback_host?(Keyword.get(opts, :host, @default_host)) ->
        {:error, "Symphony++ cockpit host must be loopback: #{@default_host}, localhost, ::1, or [::1]."}

      invalid_port?(Keyword.get(opts, :port, @default_port)) ->
        {:error, "Symphony++ cockpit port must be an integer from 0 to 65535."}

      true ->
        {:ok, normalize_opts(opts)}
    end
  end

  defp normalize_opts(opts) do
    opts
    |> Keyword.put_new(:host, @default_host)
    |> Keyword.put_new(:port, @default_port)
    |> maybe_resolve_database()
  end

  defp maybe_resolve_database(opts) do
    if Keyword.has_key?(opts, :database) do
      Keyword.update!(opts, :database, &resolved_database/1)
    else
      opts
    end
  end

  defp run_cockpit(opts), do: run_cockpit(opts, &wait_forever/0)

  defp run_cockpit(opts, wait_fun) when is_function(wait_fun, 0) do
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    original_endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    try do
      configure_cockpit(opts, original_endpoint_config)
      {:ok, _started} = ensure_runtime_started()
      :ok = start_http_server_or_raise(opts)
      port = wait_for_bound_port()

      Mix.shell().info("Symphony++ local operator cockpit: #{cockpit_url(opts, port)}")
      Mix.shell().info("Press Ctrl+C to stop.")

      wait_fun.()
    after
      restore_env(:sympp_repo_database, original_database)
      Application.put_env(:symphony_elixir, Endpoint, original_endpoint_config)
      stop_owned_endpoint(Process.delete(:sympp_cockpit_endpoint_pid))
      stop_owned_processes(Process.delete(:sympp_cockpit_pubsub_pids))
    end
  end

  defp start_http_server_or_raise(opts) do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      case HttpServer.start_link(host: server_host(Keyword.fetch!(opts, :host)), port: Keyword.fetch!(opts, :port)) do
        {:ok, pid} ->
          Process.put(:sympp_cockpit_endpoint_pid, pid)
          :ok

        {:error, reason} ->
          flush_exit_messages()
          Mix.raise(cockpit_bind_error(opts, reason))
      end
    catch
      :exit, reason ->
        flush_exit_messages()
        Mix.raise(cockpit_bind_error(opts, reason))
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp flush_exit_messages do
    receive do
      {:EXIT, _pid, _reason} -> flush_exit_messages()
    after
      0 -> :ok
    end
  end

  defp cockpit_bind_error(opts, reason) do
    host = opts |> Keyword.fetch!(:host) |> url_host()
    port = Keyword.fetch!(opts, :port)

    "Symphony++ cockpit could not bind http://#{host}:#{port}. " <>
      "Stop the existing local daemon or pass --port 0 / --port <port>. " <>
      "Reason: #{inspect(reason)}"
  end

  defp configure_cockpit(opts, original_endpoint_config) do
    if database = Keyword.get(opts, :database) do
      Application.put_env(:symphony_elixir, :sympp_repo_database, database)
    end

    Application.put_env(:symphony_elixir, Endpoint, endpoint_config(original_endpoint_config, opts))
  end

  defp endpoint_config(original_endpoint_config, opts) do
    original_endpoint_config
    |> Keyword.merge(server: false, sympp_local_operator: true)
    |> maybe_force_default_repo(opts)
  end

  defp maybe_force_default_repo(endpoint_config, opts) do
    if Keyword.has_key?(opts, :database) do
      Keyword.put(endpoint_config, :sympp_repo, Repo)
    else
      endpoint_config
    end
  end

  defp ensure_runtime_started do
    with {:ok, _started} <- Application.ensure_all_started(:phoenix),
         {:ok, _started} <- Application.ensure_all_started(:phoenix_live_view),
         {:ok, _started} <- Application.ensure_all_started(:bandit),
         {:ok, _started} <- Application.ensure_all_started(:ecto_sql),
         {:ok, _started} <- ensure_pubsub_started() do
      {:ok, []}
    end
  end

  defp ensure_pubsub_started do
    case Process.whereis(SymphonyElixir.PubSub) do
      pid when is_pid(pid) ->
        {:ok, []}

      nil ->
        case Phoenix.PubSub.Supervisor.start_link(name: SymphonyElixir.PubSub) do
          {:ok, pid} ->
            Process.put(:sympp_cockpit_pubsub_pids, [Process.whereis(SymphonyElixir.PubSub), pid])
            {:ok, [Phoenix.PubSub]}

          {:error, {:already_started, _pid}} ->
            {:ok, []}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp wait_for_bound_port do
    Enum.reduce_while(1..500, nil, fn _attempt, _port ->
      case HttpServer.bound_port() do
        port when is_integer(port) and port > 0 ->
          {:halt, port}

        _port ->
          Process.sleep(20)
          {:cont, nil}
      end
    end) || Mix.raise("Symphony++ cockpit started but no bound HTTP port was reported.")
  end

  defp cockpit_url(opts, port) do
    host = opts |> Keyword.fetch!(:host) |> url_host()
    "http://#{host}:#{port}#{@board_path}"
  end

  defp url_host("::1"), do: "[::1]"
  defp url_host(host), do: host

  defp stop_owned_endpoint(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp stop_owned_endpoint(_pid), do: :ok

  defp stop_owned_processes(pids) when is_list(pids) do
    pids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&stop_owned_process/1)
  end

  defp stop_owned_processes(_pids), do: :ok

  defp stop_owned_process(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      stop_otp_process(pid)
    else
      :ok
    end
  end

  defp stop_owned_process(_pid), do: :ok

  defp stop_otp_process(pid) do
    Supervisor.stop(pid, :shutdown, 1_000)
  catch
    :exit, _reason -> stop_gen_server(pid)
  end

  defp stop_gen_server(pid) do
    GenServer.stop(pid, :shutdown, 1_000)
  catch
    :exit, _reason -> :ok
  end

  defp wait_forever do
    Process.sleep(:infinity)
  end

  defp resolved_database(nil), do: nil

  defp resolved_database(database) when is_binary(database) do
    if Repo.filesystem_database_path?(database) do
      database = Path.expand(database)
      File.mkdir_p!(Path.dirname(database))
      database
    else
      database
    end
  end

  defp loopback_host?(host) when is_binary(host) do
    host |> String.downcase() |> then(&(&1 in ["127.0.0.1", "localhost", "::1", "[::1]"]))
  end

  defp loopback_host?({127, _second, _third, _fourth}), do: true
  defp loopback_host?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_host?(_host), do: false

  defp invalid_port?(port), do: not (is_integer(port) and port >= 0 and port <= 65_535)

  defp server_host("[::1]"), do: "::1"
  defp server_host(host), do: host

  defp has_blank_option?(opts, keys) do
    Enum.any?(keys, &(Keyword.has_key?(opts, &1) and blank?(Keyword.get(opts, &1))))
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
