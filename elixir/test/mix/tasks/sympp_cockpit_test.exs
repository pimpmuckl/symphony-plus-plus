defmodule Mix.Tasks.Sympp.CockpitTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Sympp.Cockpit, as: CockpitTask
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.WorkPackageFactory
  alias SymphonyElixirWeb.Endpoint

  setup do
    Mix.Task.reenable("sympp.cockpit")
    previous_shell = Mix.shell()
    previous_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    previous_endpoint_config = Application.get_env(:symphony_elixir, Endpoint, [])

    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
      restore_env(:sympp_repo_database, previous_database)
      Application.put_env(:symphony_elixir, Endpoint, previous_endpoint_config)
      stop_endpoint()
    end)

    :ok
  end

  test "prints help" do
    CockpitTask.run(["--help"])
    assert_received {:mix_shell, :info, [message]}
    assert message =~ "mix sympp.cockpit"
    assert message =~ "--database <sqlite-path>"
  end

  test "parses safe defaults and explicit options" do
    relative_database = Path.join("tmp", "sympp-cockpit-#{System.unique_integer([:positive])}.sqlite3")

    try do
      assert {:ok, default_opts} = CockpitTask.parse_args_for_test([])
      assert Keyword.fetch!(default_opts, :host) == "127.0.0.1"
      assert Keyword.fetch!(default_opts, :port) == 4057
      assert Keyword.fetch!(default_opts, :dashboard_origin) == "http://127.0.0.1:5173"
      assert CockpitTask.cockpit_url_for_test(default_opts, 4057) == "http://127.0.0.1:5173/sympp/board"

      assert {:ok, opts} =
               CockpitTask.parse_args_for_test([
                 "--database",
                 relative_database,
                 "--host",
                 "localhost",
                 "--port",
                 "0",
                 "--dashboard-origin",
                 "http://127.0.0.1:5174"
               ])

      assert Keyword.fetch!(opts, :host) == "localhost"
      assert Keyword.fetch!(opts, :port) == 0
      assert Keyword.fetch!(opts, :dashboard_origin) == "http://127.0.0.1:5174"
      assert Repo.same_database_path?(Keyword.fetch!(opts, :database), Path.expand(relative_database))

      endpoint_config = CockpitTask.endpoint_config_for_test(opts)
      assert endpoint_config[:sympp_local_operator] == true
      assert endpoint_config[:sympp_repo] == Repo
      assert endpoint_config[:server] == false
      assert endpoint_config[:sympp_dashboard_origin] == "http://127.0.0.1:5174"

      assert CockpitTask.cockpit_url_for_test(opts, 4567) == "http://127.0.0.1:5174/sympp/board"

      assert {:ok, ipv6_opts} = CockpitTask.parse_args_for_test(["--host", "[::1]"])
      assert CockpitTask.cockpit_url_for_test(ipv6_opts, 4567) == "http://127.0.0.1:5173/sympp/board"
    after
      File.rm(Path.expand(relative_database))
    end
  end

  test "preserves configured custom repo unless database is explicit" do
    custom_repo = Module.concat(__MODULE__, CustomRepo)
    original_config = [sympp_repo: custom_repo, other: :kept]

    no_database_config = CockpitTask.endpoint_config_for_test(endpoint_config: original_config)

    assert no_database_config[:sympp_local_operator] == true
    assert no_database_config[:sympp_repo] == custom_repo
    assert no_database_config[:other] == :kept

    database_config = CockpitTask.endpoint_config_for_test(endpoint_config: original_config, database: ":memory:")

    assert database_config[:sympp_local_operator] == true
    assert database_config[:sympp_repo] == Repo
    assert database_config[:other] == :kept
  end

  test "rejects blank options, non-loopback hosts, and invalid ports" do
    assert {:error, usage} = CockpitTask.parse_args_for_test(["--database", " "])
    assert usage =~ "mix sympp.cockpit"

    assert {:error, host_error} = CockpitTask.parse_args_for_test(["--host", "0.0.0.0"])
    assert host_error =~ "host must be loopback"

    assert {:error, dashboard_origin_usage} = CockpitTask.parse_args_for_test(["--dashboard-origin", " "])
    assert dashboard_origin_usage =~ "mix sympp.cockpit"

    assert {:error, port_error} = CockpitTask.parse_args_for_test(["--port", "65536"])
    assert port_error =~ "port must be an integer"
  end

  test "starts a local operator cockpit, prints bridge URLs, and serves an empty ledger API" do
    database_path = WorkPackageFactory.database_path()

    try do
      assert {:ok, opts} = CockpitTask.parse_args_for_test(["--database", database_path, "--port", "0"])

      CockpitTask.run_cockpit_for_test(opts, fn ->
        port = wait_for_bound_port()

        response =
          Req.get!("http://127.0.0.1:#{port}/sympp/board",
            headers: [{"sec-fetch-site", "none"}],
            redirect: false
          )

        api_response =
          Req.get!("http://127.0.0.1:#{port}/api/v1/sympp/operator/dashboard",
            headers: [{"sec-fetch-site", "none"}]
          )

        send(self(), {:cockpit_response, response.status, response.headers["location"], api_response.status, api_response.body})
      end)

      assert_received {:mix_shell, :info, [url]}
      assert url == "Symphony++ local operator dashboard: http://127.0.0.1:5173/sympp/board"
      assert_received {:mix_shell, :info, [bridge]}
      assert bridge =~ ~r{Symphony\+\+ API bridge: http://127\.0\.0\.1:\d+}
      assert_received {:mix_shell, :info, ["Press Ctrl+C to stop."]}
      assert_received {:cockpit_response, 302, ["http://127.0.0.1:5173/sympp/board"], 200, payload}
      assert payload["board"]["total_count"] == 0
      assert File.exists?(database_path)
    after
      File.rm(database_path)
    end
  end

  test "reports an actionable error when the configured port is already occupied" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    database_path = WorkPackageFactory.database_path()

    try do
      assert {:ok, opts} = CockpitTask.parse_args_for_test(["--database", database_path, "--port", Integer.to_string(port)])

      assert_raise Mix.Error, ~r/could not bind http:\/\/127\.0\.0\.1:#{port}/, fn ->
        CockpitTask.run_cockpit_for_test(opts, fn -> :ok end)
      end
    after
      :gen_tcp.close(socket)
      File.rm(database_path)
    end
  end

  test "cleans up the owned endpoint so the cockpit can restart in the same runtime" do
    database_path = WorkPackageFactory.database_path()

    try do
      assert {:ok, opts} = CockpitTask.parse_args_for_test(["--database", database_path, "--port", "0"])

      CockpitTask.run_cockpit_for_test(opts, fn ->
        assert is_integer(wait_for_bound_port())
      end)

      CockpitTask.run_cockpit_for_test(opts, fn ->
        assert is_integer(wait_for_bound_port())
      end)
    after
      File.rm(database_path)
    end
  end

  defp wait_for_bound_port do
    Enum.reduce_while(1..500, nil, fn _attempt, _port ->
      case SymphonyElixir.HttpServer.bound_port() do
        port when is_integer(port) and port > 0 ->
          {:halt, port}

        _port ->
          Process.sleep(20)
          {:cont, nil}
      end
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp stop_endpoint do
    case Process.whereis(Endpoint) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      nil -> :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
