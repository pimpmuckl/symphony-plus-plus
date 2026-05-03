defmodule Mix.Tasks.Sympp.CreateWorkTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Mix.Tasks.Sympp.CreateWork, as: CreateWorkTask
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Repo
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

  test "creates standalone work from a YAML file and prints the one-time secret" do
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
      CreateWorkTask.run(["--database", database_path, "--file", request_path])

      assert_received {:mix_shell, :info, [json]}
      payload = Jason.decode!(json)

      assert payload["work_package"]["title"] == "Fix bad status label"
      assert payload["work_package"]["parent_id"] == nil
      assert payload["work_package"]["status"] == "ready_for_worker"
      assert payload["worker_grant"]["secret"]
      assert payload["secret_returned_once"] == true
      assert payload["secret_not_persisted"] == true
      assert payload["virtual_files"]["task_plan.md"] =~ "Implement requested scope"

      {:ok, pid} =
        Repo.start_link(database: database_path, name: Repo.process_name(database_path), pool_size: 1, log: false)

      Repo.put_dynamic_repo(pid)

      try do
        display_key = payload["worker_grant"]["display_key"]
        grant = Repo.one(from(grant in AccessGrant, where: grant.display_key == ^display_key))
        assert grant
        refute inspect(grant) =~ payload["worker_grant"]["secret"]
      after
        GenServer.stop(pid)
      end
    after
      File.rm(request_path)
      File.rm(database_path)
    end
  end

  test "fails when required file option is missing" do
    assert_raise Mix.Error, ~r/Usage: mix sympp.create_work/, fn ->
      CreateWorkTask.run([])
    end
  end

  test "preserves SQLite special database names" do
    file_uri = "file:sympp-create-work-#{System.unique_integer([:positive])}.sqlite3?mode=memory&cache=shared"
    filesystem_path = Path.join(System.tmp_dir!(), "sympp-create-work-#{System.unique_integer([:positive])}.sqlite3")

    assert CreateWorkTask.database_path_for_test(":memory:") == ":memory:"
    assert CreateWorkTask.database_path_for_test(file_uri) == file_uri
    assert CreateWorkTask.database_path_for_test(filesystem_path) == Path.expand(filesystem_path)
  end
end
