defmodule Mix.Tasks.Sympp.SoloTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Mix.Tasks.Sympp.Solo, as: SoloTask
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkPackageFactory

  setup do
    Mix.Task.reenable("sympp.solo")
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    :ok
  end

  test "prints help" do
    SoloTask.run(["--help"])
    assert_received {:mix_shell, :info, [message]}
    assert message =~ "mix sympp.solo attach"
    assert message =~ "mix sympp.solo plan|progress|finding"
    assert message =~ "mix sympp.solo blocker"
  end

  test "attaches records progress and shows ordered redacted entries as JSON" do
    database_path = WorkPackageFactory.database_path()
    workspace_path = workspace_path("happy")

    try do
      attach =
        run_json([
          "attach",
          "--database",
          database_path,
          "--repo",
          "nextide/example",
          "--base-branch",
          "main",
          "--workspace-path",
          workspace_path,
          "--caller-id",
          "codex-local",
          "--title",
          "Plan bearer abcdefghijkl"
        ])

      assert attach["action"] == "attach"
      session = attach["solo_session"]
      assert session["id"] =~ "solo_"
      assert session["session_key"] =~ "solo_key_"
      assert session["status"] == "active"
      assert session["title"] == "Plan [REDACTED]"

      progress =
        run_json([
          "progress",
          "--database",
          database_path,
          "--session-id",
          session["id"],
          "--summary",
          "Use ghp_abcdefgh",
          "--body",
          "Body bearer abcdefghijkl",
          "--status",
          "active",
          "--idempotency-key",
          "entry-1",
          "--payload-json",
          ~s({"token":"ghp_abcdefgh","nested":{"url":"https://example.test/?token=ghp_abcdefgh"}})
        ])

      assert progress["action"] == "progress"
      entry = progress["entry"]
      assert entry["entry_kind"] == "progress"
      assert entry["title"] == "Use [REDACTED]"
      assert entry["body"] == "Body [REDACTED]"
      assert entry["status"] == "in_progress"
      assert entry["sequence"] == 1
      assert entry["idempotency_key"] == "entry-1"
      assert entry["payload"]["token"] == "[REDACTED]"
      assert entry["payload"]["nested"]["url"] == "https://example.test/?token=[REDACTED]"

      show = run_json(["show", "--database", database_path, "--session-id", session["id"]])
      assert show["action"] == "show"
      assert show["solo_session"]["id"] == session["id"]
      assert [shown_entry] = show["entries"]
      assert shown_entry["id"] == entry["id"]
    after
      File.rm(database_path)
    end
  end

  test "reattaches current scope and lists with filters" do
    database_path = WorkPackageFactory.database_path()
    workspace_path = workspace_path("list")

    try do
      first =
        run_json([
          "attach",
          "--database",
          database_path,
          "--repo",
          "nextide/example",
          "--base-branch",
          "main",
          "--workspace-path",
          workspace_path,
          "--caller-id",
          "codex-local"
        ])

      second =
        run_json([
          "attach",
          "--database",
          database_path,
          "--repo",
          "nextide/example",
          "--base-branch",
          "main",
          "--workspace-path",
          workspace_path,
          "--caller-id",
          "codex-local",
          "--title",
          "Replay title"
        ])

      assert second["solo_session"]["id"] == first["solo_session"]["id"]

      listed =
        run_json([
          "list",
          "--database",
          database_path,
          "--repo",
          " nextide/example ",
          "--base-branch",
          "main",
          "--workspace-path",
          workspace_path,
          "--caller-id",
          "codex-local",
          "--status",
          "active"
        ])

      assert listed["action"] == "list"
      assert Enum.map(listed["solo_sessions"], & &1["id"]) == [first["solo_session"]["id"]]
    after
      File.rm(database_path)
    end
  end

  test "idempotent decision replays the original entry" do
    database_path = WorkPackageFactory.database_path()

    try do
      session = create_session(database_path, "idempotent")

      first =
        run_json([
          "decision",
          "--database",
          database_path,
          "--session-id",
          session["id"],
          "--decision",
          "Use entries",
          "--idempotency-key",
          "same-key"
        ])

      replay =
        run_json([
          "decision",
          "--database",
          database_path,
          "--session-id",
          session["id"],
          "--decision",
          "Changed retry",
          "--idempotency-key",
          " same-key "
        ])

      assert replay["entry"]["id"] == first["entry"]["id"]
      assert replay["entry"]["title"] == first["entry"]["title"]

      show = run_json(["show", "--database", database_path, "--session-id", session["id"]])
      assert length(show["entries"]) == 1
    after
      File.rm(database_path)
    end
  end

  test "lifecycle aliases transition sessions" do
    database_path = WorkPackageFactory.database_path()

    try do
      session = create_session(database_path, "lifecycle")

      paused = run_json(["pause", "--database", database_path, "--session-id", session["id"]])
      assert paused["solo_session"]["status"] == "paused"

      resumed = run_json(["resume", "--database", database_path, "--session-id", session["id"]])
      assert resumed["solo_session"]["status"] == "active"

      completed = run_json(["complete", "--database", database_path, "--session-id", session["id"]])
      assert completed["solo_session"]["status"] == "completed"

      archived = run_json(["archive", "--database", database_path, "--session-id", session["id"]])
      assert archived["solo_session"]["status"] == "archived"
      assert archived["solo_session"]["archived_at"]
    after
      File.rm(database_path)
    end
  end

  test "validates required options and payload JSON before creating a database" do
    database_path = WorkPackageFactory.database_path()

    assert_raise Mix.Error, ~r/Usage: mix sympp.solo/, fn ->
      SoloTask.run(["attach", "--database", database_path, "--repo", "nextide/example"])
    end

    refute File.exists?(database_path)

    assert_raise Mix.Error, ~r/--payload-json must be valid JSON/, fn ->
      SoloTask.run([
        "progress",
        "--database",
        database_path,
        "--session-id",
        "solo_missing",
        "--summary",
        "Bad payload",
        "--payload-json",
        "{"
      ])
    end

    refute File.exists?(database_path)

    assert_raise Mix.Error, ~r/--payload-json must decode to a JSON object/, fn ->
      SoloTask.run([
        "progress",
        "--database",
        database_path,
        "--session-id",
        "solo_missing",
        "--summary",
        "Bad payload",
        "--payload-json",
        ~s(["not","object"])
      ])
    end

    refute File.exists?(database_path)
  end

  test "non-attach commands require an existing filesystem database" do
    database_path = WorkPackageFactory.database_path()

    commands = [
      ["plan", "--session-id", "solo_missing", "--summary", "Missing"],
      ["progress", "--session-id", "solo_missing", "--summary", "Missing"],
      ["finding", "--session-id", "solo_missing", "--summary", "Missing"],
      ["decision", "--session-id", "solo_missing", "--decision", "Missing"],
      ["blocker", "--session-id", "solo_missing", "--summary", "Missing"],
      ["resolve-blocker", "--session-id", "solo_missing", "--blocker-id", "blocker-1", "--resolution", "Done"],
      ["validation", "--session-id", "solo_missing", "--summary", "Missing", "--result", "not_run"],
      ["show", "--session-id", "solo_missing"],
      ["list"],
      ["pause", "--session-id", "solo_missing"],
      ["resume", "--session-id", "solo_missing"],
      ["complete", "--session-id", "solo_missing"],
      ["archive", "--session-id", "solo_missing"]
    ]

    for command_args <- commands do
      [command | _rest] = command_args

      assert_raise Mix.Error, ~r/mix sympp\.solo #{command} requires an existing Solo Session database/, fn ->
        SoloTask.run(command_args ++ ["--database", database_path])
      end

      refute File.exists?(database_path)
    end
  end

  test "non-attach commands do not migrate existing non-solo databases" do
    database_path = WorkPackageFactory.database_path()

    try do
      create_unrelated_sqlite_database(database_path)

      assert_raise Mix.Error, ~r/requires an existing Solo Session database/, fn ->
        SoloTask.run(["show", "--database", database_path, "--session-id", "solo_missing"])
      end

      refute sqlite_table_exists?(database_path, "sympp_solo_sessions")
      assert sqlite_table_exists?(database_path, "unrelated_table")
    after
      File.rm(database_path)
    end
  end

  test "surfaces service validation errors without creating entries" do
    database_path = WorkPackageFactory.database_path()

    try do
      session = create_session(database_path, "validation")

      assert_raise Mix.Error, ~r/entry status "ready_for_merge" is invalid/, fn ->
        SoloTask.run([
          "progress",
          "--database",
          database_path,
          "--session-id",
          session["id"],
          "--summary",
          "Bad status",
          "--status",
          "ready_for_merge"
        ])
      end

      assert_raise Mix.Error, ~r/validation result "maybe" is invalid/, fn ->
        SoloTask.run([
          "validation",
          "--database",
          database_path,
          "--session-id",
          session["id"],
          "--summary",
          "Bad result",
          "--result",
          "maybe"
        ])
      end

      assert_raise Mix.Error, ~r/does not support --status/, fn ->
        SoloTask.run([
          "blocker",
          "--database",
          database_path,
          "--session-id",
          session["id"],
          "--summary",
          "Bad blocker status",
          "--status",
          "resolved"
        ])
      end

      assert_raise Mix.Error, ~r/idempotency key is invalid or secret-like/, fn ->
        SoloTask.run([
          "progress",
          "--database",
          database_path,
          "--session-id",
          session["id"],
          "--summary",
          "Bad key",
          "--idempotency-key",
          "wk_" <> String.duplicate("A", 43)
        ])
      end

      show = run_json(["show", "--database", database_path, "--session-id", session["id"]])
      assert show["entries"] == []
    after
      File.rm(database_path)
    end
  end

  test "normalizes durable local filesystem database paths" do
    filesystem_path = Path.join(System.tmp_dir!(), "sympp-solo-#{System.unique_integer([:positive])}.sqlite3")

    assert SoloTask.database_path_for_test(filesystem_path) == Path.expand(filesystem_path)
  end

  test "normalizes relative database paths against the Mix project root" do
    relative_dir = Path.join(["tmp", "sympp-solo-cwd-#{System.unique_integer([:positive])}"])
    relative_database = Path.join(relative_dir, "ledger.sqlite3")
    outside_project = Path.join(System.tmp_dir!(), "sympp-solo-cwd-#{System.unique_integer([:positive])}")
    expected_database = Path.expand(relative_database, mix_project_root())

    try do
      File.mkdir_p!(outside_project)

      File.cd!(outside_project, fn ->
        assert SoloTask.database_path_for_test(relative_database) == expected_database
      end)
    after
      File.rm_rf(outside_project)
      File.rm_rf(Path.join(mix_project_root(), relative_dir))
    end
  end

  test "rejects in-memory database targets" do
    assert_raise Mix.Error, ~r/requires a durable file-backed SQLite database/, fn ->
      SoloTask.database_path_for_test(":memory:")
    end
  end

  test "rejects SQLite file URI database targets" do
    uri_targets = [
      "file:sympp-solo-#{System.unique_integer([:positive])}.sqlite3?mode=rwc",
      "file:sympp-solo-#{System.unique_integer([:positive])}.sqlite3?mode=memory&cache=shared",
      "file:sympp-solo-#{System.unique_integer([:positive])}.sqlite3?mode=ro",
      "file::memory:?cache=shared",
      "FILE::memory:?cache=shared",
      "File:sympp-solo-#{System.unique_integer([:positive])}.sqlite3?mode=ro",
      "file:?mode=rwc",
      "file:"
    ]

    for database <- uri_targets do
      assert_raise Mix.Error, ~r/SQLite file: URIs are not supported/, fn ->
        SoloTask.database_path_for_test(database)
      end
    end
  end

  test "rejects URI and DSN database targets" do
    database_targets = [
      "https://example.test/sympp-solo.sqlite3",
      "sqlite://example.test/sympp-solo.sqlite3",
      "postgres://example.test/sympp-solo"
    ]

    for database <- database_targets do
      assert_raise Mix.Error, ~r/URI\/DSN database targets are not supported/, fn ->
        SoloTask.database_path_for_test(database)
      end
    end
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
      database_path = SoloTask.database_path_for_test(nil)

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

  test "default database resolution restores caller workflow override" do
    previous_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    manual_workflow = Path.join(System.tmp_dir!(), "sympp-solo-manual-#{System.unique_integer([:positive])}.md")

    File.write!(manual_workflow, "---\n---\n")
    Workflow.set_workflow_file_path(manual_workflow)
    Application.delete_env(:symphony_elixir, :sympp_repo_database)

    try do
      _database_path = SoloTask.database_path_for_test(nil)

      assert Workflow.workflow_file_path() == manual_workflow
    after
      File.rm(manual_workflow)

      if previous_workflow do
        Workflow.set_workflow_file_path(previous_workflow)
      else
        Workflow.clear_workflow_file_path()
      end

      if previous_database do
        Application.put_env(:symphony_elixir, :sympp_repo_database, previous_database)
      else
        Application.delete_env(:symphony_elixir, :sympp_repo_database)
      end
    end
  end

  test "default database resolution creates configured parent directories for attach" do
    previous_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    previous_repo_config = Application.get_env(:symphony_elixir, Repo)
    project_workflow = Path.expand("../../../WORKFLOW.md", __DIR__)
    database_path = Path.join(System.tmp_dir!(), "sympp-solo-default/#{System.unique_integer([:positive])}/ledger.sqlite3")

    try do
      Application.delete_env(:symphony_elixir, :sympp_repo_database)
      Application.put_env(:symphony_elixir, Repo, database: database_path)

      assert SoloTask.database_path_for_test(nil, fn -> project_workflow end) == Path.expand(database_path)
      assert File.dir?(Path.dirname(database_path))
    after
      File.rm(database_path)
      File.rm_rf(Path.dirname(Path.dirname(database_path)))

      if previous_workflow do
        Workflow.set_workflow_file_path(previous_workflow)
      else
        Workflow.clear_workflow_file_path()
      end

      if previous_database do
        Application.put_env(:symphony_elixir, :sympp_repo_database, previous_database)
      else
        Application.delete_env(:symphony_elixir, :sympp_repo_database)
      end

      if previous_repo_config do
        Application.put_env(:symphony_elixir, Repo, previous_repo_config)
      else
        Application.delete_env(:symphony_elixir, Repo)
      end
    end
  end

  test "default database resolution avoids parent directory creation for non-attach commands" do
    previous_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    previous_repo_config = Application.get_env(:symphony_elixir, Repo)
    project_workflow = Path.expand("../../../WORKFLOW.md", __DIR__)
    database_path = Path.join(System.tmp_dir!(), "sympp-solo-default/#{System.unique_integer([:positive])}/ledger.sqlite3")

    try do
      Application.delete_env(:symphony_elixir, :sympp_repo_database)
      Application.put_env(:symphony_elixir, Repo, database: database_path)

      refute File.exists?(Path.dirname(database_path))

      assert SoloTask.database_path_for_test(nil, fn -> project_workflow end, false) == Path.expand(database_path)
      refute File.exists?(Path.dirname(database_path))
    after
      File.rm_rf(Path.dirname(Path.dirname(database_path)))

      if previous_workflow do
        Workflow.set_workflow_file_path(previous_workflow)
      else
        Workflow.clear_workflow_file_path()
      end

      if previous_database do
        Application.put_env(:symphony_elixir, :sympp_repo_database, previous_database)
      else
        Application.delete_env(:symphony_elixir, :sympp_repo_database)
      end

      if previous_repo_config do
        Application.put_env(:symphony_elixir, Repo, previous_repo_config)
      else
        Application.delete_env(:symphony_elixir, Repo)
      end
    end
  end

  test "omitted database resolves configured relative paths against the project workflow" do
    previous_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    previous_repo_config = Application.get_env(:symphony_elixir, Repo)
    workflow_dir = Path.join(System.tmp_dir!(), "sympp-solo-workflow-#{System.unique_integer([:positive])}")
    project_workflow = Path.join(workflow_dir, "WORKFLOW.md")
    relative_database = Path.join(["nested", "ledger.sqlite3"])
    expected_database = Path.join(workflow_dir, relative_database) |> Path.expand()

    try do
      File.mkdir_p!(workflow_dir)
      File.write!(project_workflow, "---\n---\n")
      Application.delete_env(:symphony_elixir, :sympp_repo_database)
      Application.put_env(:symphony_elixir, Repo, database: relative_database)

      assert SoloTask.database_path_for_test(nil, fn -> project_workflow end, false) == expected_database
      refute File.exists?(Path.dirname(expected_database))

      assert SoloTask.database_path_for_test(nil, fn -> project_workflow end, true) == expected_database
      assert File.dir?(Path.dirname(expected_database))
    after
      File.rm_rf(workflow_dir)

      if previous_workflow do
        Workflow.set_workflow_file_path(previous_workflow)
      else
        Workflow.clear_workflow_file_path()
      end

      if previous_database do
        Application.put_env(:symphony_elixir, :sympp_repo_database, previous_database)
      else
        Application.delete_env(:symphony_elixir, :sympp_repo_database)
      end

      if previous_repo_config do
        Application.put_env(:symphony_elixir, Repo, previous_repo_config)
      else
        Application.delete_env(:symphony_elixir, Repo)
      end
    end
  end

  test "omitted database resolves configured relative paths against the Mix project root when workflow is missing" do
    previous_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    previous_repo_config = Application.get_env(:symphony_elixir, Repo)
    outside_project = Path.join(System.tmp_dir!(), "sympp-solo-config-cwd-#{System.unique_integer([:positive])}")
    relative_dir = Path.join(["tmp", "sympp-solo-config-#{System.unique_integer([:positive])}"])
    relative_database = Path.join(relative_dir, "ledger.sqlite3")
    expected_database = Path.expand(relative_database, mix_project_root())

    try do
      File.mkdir_p!(outside_project)
      Application.delete_env(:symphony_elixir, :sympp_repo_database)
      Application.put_env(:symphony_elixir, Repo, database: relative_database)

      File.cd!(outside_project, fn ->
        assert SoloTask.database_path_for_test(nil, fn -> nil end, false) == expected_database
        refute File.exists?(Path.dirname(expected_database))

        assert SoloTask.database_path_for_test(nil, fn -> nil end, true) == expected_database
        assert File.dir?(Path.dirname(expected_database))
      end)
    after
      File.rm_rf(outside_project)
      File.rm_rf(Path.join(mix_project_root(), relative_dir))

      if previous_workflow do
        Workflow.set_workflow_file_path(previous_workflow)
      else
        Workflow.clear_workflow_file_path()
      end

      if previous_database do
        Application.put_env(:symphony_elixir, :sympp_repo_database, previous_database)
      else
        Application.delete_env(:symphony_elixir, :sympp_repo_database)
      end

      if previous_repo_config do
        Application.put_env(:symphony_elixir, Repo, previous_repo_config)
      else
        Application.delete_env(:symphony_elixir, Repo)
      end
    end
  end

  test "omitted database can use the shared local default when the project workflow is missing" do
    previous_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    manual_workflow = Path.join(System.tmp_dir!(), "sympp-solo-manual-#{System.unique_integer([:positive])}.md")

    File.write!(manual_workflow, "---\n---\n")
    Workflow.set_workflow_file_path(manual_workflow)
    Application.put_env(:symphony_elixir, :sympp_repo_database, WorkPackageFactory.database_path())

    try do
      database_path = SoloTask.database_path_for_test(nil, fn -> nil end)

      assert Path.split(database_path) |> Enum.take(-3) == [".agents", "splusplus", "symphony_plus_plus.sqlite3"]
      assert Path.basename(database_path) == "symphony_plus_plus.sqlite3"
      assert Workflow.workflow_file_path() == manual_workflow
      assert is_binary(Application.get_env(:symphony_elixir, :sympp_repo_database))
    after
      File.rm(manual_workflow)

      if previous_workflow do
        Workflow.set_workflow_file_path(previous_workflow)
      else
        Workflow.clear_workflow_file_path()
      end

      if previous_database do
        Application.put_env(:symphony_elixir, :sympp_repo_database, previous_database)
      else
        Application.delete_env(:symphony_elixir, :sympp_repo_database)
      end
    end
  end

  test "omitted database rejects an in-memory default ledger" do
    previous_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    previous_repo_config = Application.get_env(:symphony_elixir, Repo)
    project_workflow = Path.expand("../../../WORKFLOW.md", __DIR__)

    try do
      Application.delete_env(:symphony_elixir, :sympp_repo_database)
      Application.put_env(:symphony_elixir, Repo, database: ":memory:")

      assert_raise Mix.Error, ~r/requires a durable file-backed SQLite database/, fn ->
        SoloTask.database_path_for_test(nil, fn -> project_workflow end)
      end
    after
      if previous_workflow do
        Workflow.set_workflow_file_path(previous_workflow)
      else
        Workflow.clear_workflow_file_path()
      end

      if previous_database do
        Application.put_env(:symphony_elixir, :sympp_repo_database, previous_database)
      else
        Application.delete_env(:symphony_elixir, :sympp_repo_database)
      end

      if previous_repo_config do
        Application.put_env(:symphony_elixir, Repo, previous_repo_config)
      else
        Application.delete_env(:symphony_elixir, Repo)
      end
    end
  end

  test "omitted database rejects a SQLite file URI default ledger" do
    previous_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    previous_database = Application.get_env(:symphony_elixir, :sympp_repo_database)
    previous_repo_config = Application.get_env(:symphony_elixir, Repo)
    project_workflow = Path.expand("../../../WORKFLOW.md", __DIR__)

    try do
      Application.delete_env(:symphony_elixir, :sympp_repo_database)
      Application.put_env(:symphony_elixir, Repo, database: "file:sympp-solo.sqlite3?mode=rwc")

      assert_raise Mix.Error, ~r/SQLite file: URIs are not supported/, fn ->
        SoloTask.database_path_for_test(nil, fn -> project_workflow end)
      end
    after
      if previous_workflow do
        Workflow.set_workflow_file_path(previous_workflow)
      else
        Workflow.clear_workflow_file_path()
      end

      if previous_database do
        Application.put_env(:symphony_elixir, :sympp_repo_database, previous_database)
      else
        Application.delete_env(:symphony_elixir, :sympp_repo_database)
      end

      if previous_repo_config do
        Application.put_env(:symphony_elixir, Repo, previous_repo_config)
      else
        Application.delete_env(:symphony_elixir, Repo)
      end
    end
  end

  defp create_session(database_path, name) do
    run_json([
      "attach",
      "--database",
      database_path,
      "--repo",
      "nextide/example",
      "--base-branch",
      "main",
      "--workspace-path",
      workspace_path(name),
      "--caller-id",
      "codex-local"
    ])["solo_session"]
  end

  defp run_json(args) do
    SoloTask.run(args)
    assert_received {:mix_shell, :info, [json]}
    Jason.decode!(json)
  end

  defp workspace_path(name) do
    path = Path.join(System.tmp_dir!(), "sympp-solo-cli-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp create_unrelated_sqlite_database(database_path) do
    {:ok, pid} =
      Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

    original_repo = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(pid)

    try do
      SQL.query!(pid, "CREATE TABLE unrelated_table (id INTEGER PRIMARY KEY)", [])
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
    end
  end

  defp sqlite_table_exists?(database_path, table_name) do
    {:ok, pid} =
      Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

    original_repo = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(pid)

    try do
      %{rows: rows} =
        SQL.query!(pid, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [table_name])

      rows != []
    after
      Repo.put_dynamic_repo(original_repo)
      GenServer.stop(pid)
    end
  end

  defp mix_project_root do
    Path.expand("../../..", __DIR__)
  end
end
