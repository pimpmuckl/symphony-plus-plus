defmodule Mix.Tasks.Sympp.CreateWorkTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Mix.Tasks.Sympp.CreateWork, as: CreateWorkTask
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkPackageFactory

  @windows match?({:win32, _}, :os.type())

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

  if @windows, do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "creates standalone work from a YAML file and stores the one-time secret outside stdout" do
    database_path = WorkPackageFactory.database_path()
    request_path = Path.join(System.tmp_dir!(), "sympp-create-work-#{System.unique_integer([:positive])}.yaml")
    secret_store_dir = Path.join(System.tmp_dir!(), "sympp-create-work-secrets-#{System.unique_integer([:positive])}")

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
        "--secret-handoff",
        "local-private-file",
        "--secret-store-dir",
        secret_store_dir,
        "--claimed-by",
        "worker-create-work-1"
      ])

      assert_received {:mix_shell, :info, [json]}
      payload = Jason.decode!(json)

      assert payload["work_package"]["title"] == "Fix bad status label"
      assert payload["work_package"]["parent_id"] == nil
      assert payload["work_package"]["status"] == "ready_for_worker"
      refute payload["worker_grant"]["secret"]
      assert payload["secret_returned_once"] == false
      assert payload["secret_not_persisted"] == false
      assert payload["secret_in_stdout"] == false
      assert payload["ledger_secret_not_persisted"] == true
      assert payload["virtual_files"]["task_plan.md"] =~ "Implement requested scope"

      handoff = payload["worker_secret_handoff"]
      assert handoff["mode"] == "local-private-file"
      assert handoff["status"] == "stored"
      assert handoff["secret_in_stdout"] == false
      assert handoff["claimed_by"] == "worker-create-work-1"
      assert payload["worker_grant"]["secret_handoff"]["target"] == handoff["target"]

      secret_path = handoff["path"]
      assert File.exists?(secret_path)
      secret = File.read!(secret_path)
      refute json =~ secret

      {:ok, pid} =
        Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

      Repo.put_dynamic_repo(pid)

      try do
        display_key = payload["worker_grant"]["display_key"]
        grant = Repo.one(from(grant in AccessGrant, where: grant.display_key == ^display_key))
        assert grant
        refute inspect(grant) =~ secret
      after
        GenServer.stop(pid)
      end
    after
      File.rm(request_path)
      File.rm(database_path)
      File.rm_rf(secret_store_dir)
    end
  end

  if @windows, do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "emits the resolved database path in worker handoff commands" do
    database_path = Path.join("tmp", "sympp-create-work-#{System.unique_integer([:positive])}.sqlite3")
    resolved_database_path = Path.expand(database_path)
    request_path = Path.join(System.tmp_dir!(), "sympp-create-work-#{System.unique_integer([:positive])}.yaml")
    secret_store_dir = Path.join(System.tmp_dir!(), "sympp-create-work-secrets-#{System.unique_integer([:positive])}")

    File.write!(request_path, valid_request_yaml())

    try do
      CreateWorkTask.run([
        "--database",
        database_path,
        "--file",
        request_path,
        "--secret-handoff",
        "local-private-file",
        "--secret-store-dir",
        secret_store_dir,
        "--claimed-by",
        "worker-create-work-relative-db"
      ])

      assert_received {:mix_shell, :info, [json]}
      payload = Jason.decode!(json)

      assert payload["worker_secret_handoff"]["run_mcp_command"] =~ resolved_database_path
    after
      File.rm(request_path)
      File.rm(resolved_database_path)
      File.rm_rf(secret_store_dir)
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

  test "fails when explicit secret handoff option is blank" do
    assert_raise Mix.Error, ~r/Usage: mix sympp.create_work/, fn ->
      CreateWorkTask.run(["--file", "request.yaml", "--secret-handoff", "   ", "--claimed-by", "worker-blank-handoff"])
    end
  end

  test "requires claimed-by before opening the ledger" do
    database_path = WorkPackageFactory.database_path()
    request_path = Path.join(System.tmp_dir!(), "sympp-create-work-#{System.unique_integer([:positive])}.yaml")

    File.write!(request_path, valid_request_yaml())

    try do
      assert_raise Mix.Error, ~r/Usage: mix sympp.create_work/, fn ->
        CreateWorkTask.run(["--database", database_path, "--file", request_path])
      end

      refute File.exists?(database_path)
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

  if @windows, do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "rolls back the work package when local secret handoff fails" do
    database_path = WorkPackageFactory.database_path()
    request_path = Path.join(System.tmp_dir!(), "sympp-create-work-#{System.unique_integer([:positive])}.yaml")
    blocking_store_path = Path.join(System.tmp_dir!(), "sympp-secret-store-blocker-#{System.unique_integer([:positive])}")

    File.write!(request_path, valid_request_yaml())
    File.write!(blocking_store_path, "not a directory")

    try do
      assert_raise Mix.Error, ~r/Failed to store worker secret handoff/, fn ->
        CreateWorkTask.run([
          "--database",
          database_path,
          "--file",
          request_path,
          "--secret-handoff",
          "local-private-file",
          "--secret-store-dir",
          blocking_store_path,
          "--claimed-by",
          "worker-create-work-rollback"
        ])
      end

      {:ok, pid} =
        Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

      Repo.put_dynamic_repo(pid)

      try do
        assert Repo.aggregate(WorkPackage, :count, :id) == 0
        assert Repo.aggregate(AccessGrant, :count, :id) == 0
      after
        GenServer.stop(pid)
      end
    after
      File.rm(request_path)
      File.rm(database_path)
      File.rm(blocking_store_path)
    end
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

  test "defaults to the Mix project workflow ledger when database is omitted" do
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
