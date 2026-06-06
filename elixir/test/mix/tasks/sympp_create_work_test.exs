defmodule Mix.Tasks.Sympp.CreateWorkTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Mix.Tasks.Sympp.CreateWork, as: CreateWorkTask
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkPackageFactory

  setup do
    Mix.Task.reenable("sympp.create_work")
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    :ok
  end

  test "prints help" do
    CreateWorkTask.run(["--help"])
    assert_received {:mix_shell, :info, [message]}
    assert message =~ "mix sympp.create_work --file"
  end

  test "creates standalone work from a YAML file and prints a ledger claim bootstrap" do
    database_path = WorkPackageFactory.database_path()
    request_path = Path.join(System.tmp_dir!(), "sympp-create-work-#{System.unique_integer([:positive])}.yaml")

    File.write!(request_path, """
    kind: quick_fix
    repo: kraken
    base_branch: beta
    title: Fix bad status label
    product_description: Operators see stale status text.
    engineering_scope: Update the status label copy.
    acceptance_criteria:
      - Status text is correct.
    policy_template: quick_fix
    """)

    try do
      CreateWorkTask.run([
        "--database",
        database_path,
        "--file",
        request_path,
        "--claimed-by",
        "worker-create-work-1"
      ])

      assert_received {:mix_shell, :info, [json]}
      payload = Jason.decode!(json)

      assert payload["work_package"]["title"] == "Fix bad status label"
      assert payload["work_package"]["parent_id"] == nil
      assert payload["work_package"]["status"] == "ready_for_worker"
      refute payload["worker_grant"]["secret"]
      refute payload["worker_grant"]["display_key"]
      assert payload["worker_grant"]["secret_in_response"] == false
      assert payload["virtual_files"]["task_plan.md"] =~ "Implement requested scope"

      bootstrap = payload["worker_bootstrap"]
      assert bootstrap["type"] == "ledger_claim"
      assert bootstrap["mode"] == "local_assignment"
      assert_same_database_path(bootstrap["ledger"]["database"], database_path)
      assert bootstrap["claim"]["tool"] == "claim_local_assignment"

      assert bootstrap["claim"]["arguments"] == %{
               "work_package_id" => payload["work_package"]["id"],
               "claimed_by" => "worker-create-work-1"
             }

      assert bootstrap["claim"]["required_runtime_arguments"] == []

      refute json =~ "local-private-file"
      refute json =~ "worker_secret_handoff"
      refute json =~ "secret_handoff"

      {:ok, pid} =
        Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

      Repo.put_dynamic_repo(pid)

      try do
        grant_id = payload["worker_grant"]["id"]
        grant = Repo.one(from(grant in AccessGrant, where: grant.id == ^grant_id))
        assert grant
      after
        GenServer.stop(pid)
      end
    after
      File.rm(request_path)
      File.rm(database_path)
    end
  end

  test "emits the resolved database path in the worker bootstrap" do
    database_path = Path.join("tmp", "sympp-create-work-#{System.unique_integer([:positive])}.sqlite3")
    resolved_database_path = Path.expand(database_path)
    request_path = Path.join(System.tmp_dir!(), "sympp-create-work-#{System.unique_integer([:positive])}.yaml")

    File.write!(request_path, valid_request_yaml())

    try do
      CreateWorkTask.run([
        "--database",
        database_path,
        "--file",
        request_path,
        "--claimed-by",
        "worker-create-work-relative-db"
      ])

      assert_received {:mix_shell, :info, [json]}
      payload = Jason.decode!(json)

      assert_same_database_path(payload["worker_bootstrap"]["ledger"]["database"], resolved_database_path)
    after
      File.rm(request_path)
      File.rm(resolved_database_path)
    end
  end

  test "fails when required file option is missing" do
    assert_raise Mix.Error, ~r/Usage: mix sympp.create_work/, fn ->
      CreateWorkTask.run([])
    end
  end

  test "fails when explicit database option is blank" do
    assert_raise Mix.Error, ~r/Usage: mix sympp.create_work/, fn ->
      CreateWorkTask.run(["--file", "request.yaml", "--database", "   ", "--claimed-by", "worker-blank-database"])
    end
  end

  test "rejects removed secret handoff flags before opening the ledger" do
    database_path = WorkPackageFactory.database_path()

    assert_raise Mix.Error, ~r/Usage: mix sympp.create_work/, fn ->
      CreateWorkTask.run([
        "--database",
        database_path,
        "--file",
        "request.yaml",
        "--secret-handoff",
        "local-private-file",
        "--claimed-by",
        "worker-removed-handoff"
      ])
    end

    refute File.exists?(database_path)
  end

  test "claimed-by is optional and no runtime arguments are required" do
    database_path = WorkPackageFactory.database_path()
    request_path = Path.join(System.tmp_dir!(), "sympp-create-work-#{System.unique_integer([:positive])}.yaml")

    File.write!(request_path, valid_request_yaml())

    try do
      CreateWorkTask.run(["--database", database_path, "--file", request_path])

      assert_received {:mix_shell, :info, [json]}
      payload = Jason.decode!(json)

      assert payload["worker_bootstrap"]["claim"]["arguments"] == %{
               "work_package_id" => payload["work_package"]["id"]
             }

      assert payload["worker_bootstrap"]["claim"]["required_runtime_arguments"] == []
    after
      File.rm(request_path)
      File.rm(database_path)
    end
  end

  test "does not create the ledger when the request file is invalid" do
    database_path = WorkPackageFactory.database_path()
    request_path = Path.join(System.tmp_dir!(), "missing-sympp-create-work-#{System.unique_integer([:positive])}.yaml")

    assert_raise Mix.Error, ~r/Failed to read create-work request/, fn ->
      CreateWorkTask.run(["--database", database_path, "--file", request_path, "--claimed-by", "worker-invalid-file"])
    end

    refute File.exists?(database_path)
  end

  test "preserves SQLite special database names" do
    file_uri = "file:sympp-create-work-#{System.unique_integer([:positive])}.sqlite3?mode=memory&cache=shared"
    filesystem_path = Path.join(System.tmp_dir!(), "sympp-create-work-#{System.unique_integer([:positive])}.sqlite3")
    relative_path = "tmp/sympp create work #{System.unique_integer([:positive])}.sqlite3"
    relative_file_uri = "file:#{URI.encode(relative_path, &sqlite_file_uri_path_char?/1)}?mode=rwc"

    assert CreateWorkTask.database_path_for_test(":memory:") == ":memory:"
    assert CreateWorkTask.database_path_for_test(file_uri) == file_uri
    assert CreateWorkTask.database_path_for_test(filesystem_path) == Path.expand(filesystem_path)

    assert CreateWorkTask.database_path_for_test(relative_file_uri) ==
             "file:" <> encoded_expanded_uri_path(relative_path) <> "?mode=rwc"
  end

  test "defaults to the shared local Repo ledger when database is omitted" do
    previous_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    unrelated_workflow = Path.join(System.tmp_dir!(), "unrelated-WORKFLOW.md")
    unrelated_database = Path.join(System.tmp_dir!(), "unrelated-sympp.sqlite3")
    project_workflow = Path.expand("../../../WORKFLOW.md", __DIR__)

    Application.put_env(:symphony_elixir, :workflow_file_path, project_workflow)
    Application.delete_env(:symphony_elixir, :sympp_repo_database)
    expected_database_path = Repo.database_path()

    Application.put_env(:symphony_elixir, :workflow_file_path, unrelated_workflow)
    Application.put_env(:symphony_elixir, :sympp_repo_database, unrelated_database)

    try do
      database_path = CreateWorkTask.database_path_for_test(nil)

      assert Workflow.workflow_file_path() == unrelated_workflow
      assert Application.get_env(:symphony_elixir, :sympp_repo_database) == unrelated_database

      assert Repo.same_database_path?(database_path, expected_database_path)
      assert Path.split(database_path) |> Enum.take(-3) == [".agents", "splusplus", "symphony_plus_plus.sqlite3"]
      assert Path.basename(database_path) == "symphony_plus_plus.sqlite3"
    after
      if previous_workflow do
        Application.put_env(:symphony_elixir, :workflow_file_path, previous_workflow)
      else
        Application.delete_env(:symphony_elixir, :workflow_file_path)
      end

      if previous_database do
        Application.put_env(:symphony_elixir, :sympp_repo_database, previous_database)
      else
        Application.delete_env(:symphony_elixir, :sympp_repo_database)
      end
    end
  end

  defp encoded_expanded_uri_path(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> URI.encode(&sqlite_file_uri_path_char?/1)
  end

  defp sqlite_file_uri_path_char?(char), do: URI.char_unreserved?(char) or char in [?/, ?:]

  defp assert_same_database_path(actual_path, expected_path) do
    assert is_binary(actual_path)
    assert Repo.same_database_path?(actual_path, expected_path)
  end

  defp valid_request_yaml do
    """
    kind: quick_fix
    repo: kraken
    base_branch: beta
    title: Fix bad status label
    product_description: Operators see stale status text.
    engineering_scope: Update the status label copy.
    acceptance_criteria:
      - Status text is correct.
    policy_template: quick_fix
    """
  end
end
