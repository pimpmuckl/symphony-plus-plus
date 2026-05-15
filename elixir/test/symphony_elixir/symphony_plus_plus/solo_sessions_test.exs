defmodule SymphonyElixir.SymphonyPlusPlus.SoloSessionsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.WorkPackageFactory

  defmodule BusyOnceRepo do
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def transaction(fun) do
      if Process.get(:sympp_solo_busy_once) do
        Repo.transaction(fun)
      else
        Process.put(:sympp_solo_busy_once, true)
        raise %Exqlite.Error{message: "database is locked"}
      end
    end

    def rollback(reason), do: Repo.rollback(reason)
    def one(query), do: Repo.one(query)
    def all(query), do: Repo.all(query)
    def get(schema, id), do: Repo.get(schema, id)
    def get!(schema, id), do: Repo.get!(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def update_all(query, updates), do: Repo.update_all(query, updates)
  end

  defmodule StaleCurrentReadRepo do
    alias SymphonyElixir.SymphonyPlusPlus.Repo

    def transaction(fun), do: Repo.transaction(fun)
    def rollback(reason), do: Repo.rollback(reason)

    def one(query) do
      if Process.get(:sympp_solo_stale_current_read) do
        Repo.one(query)
      else
        Process.put(:sympp_solo_stale_current_read, true)
        nil
      end
    end

    def all(query), do: Repo.all(query)
    def get(schema, id), do: Repo.get(schema, id)
    def get!(schema, id), do: Repo.get!(schema, id)
    def insert(changeset), do: Repo.insert(changeset)
    def update_all(query, updates), do: Repo.update_all(query, updates)
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(SoloSession)
    Process.delete(:sympp_solo_busy_once)
    Process.delete(:sympp_solo_stale_current_read)
    :ok
  end

  test "creates and reattaches the active current session by lookup scope", %{repo: repo} do
    attrs = session_attrs()
    before_create = DateTime.utc_now(:microsecond)

    assert {:ok, %SoloSession{} = first} = Service.create_or_attach_current(repo, attrs)
    assert first.id =~ "solo_"
    assert first.session_key =~ "solo_key_"
    assert first.status == "active"
    assert DateTime.compare(first.last_activity_at, before_create) in [:eq, :gt]
    assert %DateTime{} = first.inserted_at
    assert %DateTime{} = first.updated_at

    Process.sleep(5)

    assert {:ok, second} =
             Service.create_or_attach_current(
               repo,
               Map.merge(attrs, %{id: "caller-id", session_key: "caller-key", status: "archived", title: "Replay"})
             )

    assert second.id == first.id
    assert second.session_key == first.session_key
    assert second.title == first.title
    assert DateTime.compare(second.last_activity_at, first.last_activity_at) == :gt

    assert {:ok, [listed]} = Service.list(repo)
    assert listed.id == first.id
  end

  test "reattaches paused sessions and does not attach completed or archived sessions", %{repo: repo} do
    attrs = session_attrs()

    assert {:ok, active} = Service.create_or_attach_current(repo, attrs)
    assert {:ok, paused} = Service.pause(repo, active.id, "active")
    Process.sleep(5)

    assert {:ok, attached_paused} = Service.create_or_attach_current(repo, attrs)
    assert attached_paused.id == paused.id
    assert attached_paused.status == "paused"
    assert DateTime.compare(attached_paused.last_activity_at, paused.last_activity_at) == :gt

    assert {:ok, completed} = Service.complete(repo, attached_paused.id, "paused")
    assert {:ok, new_after_completed} = Service.create_or_attach_current(repo, attrs)

    assert completed.status == "completed"
    assert new_after_completed.id != completed.id
    assert new_after_completed.status == "active"

    assert {:ok, archived} = Service.archive(repo, new_after_completed.id, "active")
    assert {:ok, new_after_archived} = Service.create_or_attach_current(repo, attrs)

    assert archived.status == "archived"
    refute new_after_archived.id in [completed.id, archived.id]
    assert new_after_archived.status == "active"
  end

  test "active and paused uniqueness is enforced at the SQLite index", %{repo: repo} do
    attrs = session_attrs()
    assert {:ok, current} = Service.create_or_attach_current(repo, attrs)

    duplicate_attrs = %{
      repo: current.repo,
      base_branch: current.base_branch,
      workspace_path: current.workspace_path,
      caller_id: current.caller_id,
      title: "Duplicate current"
    }

    assert {:error, %Changeset{} = changeset} = Repo.insert(SoloSession.create_changeset(duplicate_attrs))
    assert "has already been taken" in errors_on(changeset).repo
  end

  test "caller-owned identifiers status and timestamps are ignored on create attach", %{repo: repo} do
    caller_time = ~U[2001-01-01 00:00:00.000000Z]
    before_create = DateTime.utc_now(:microsecond)

    attrs =
      session_attrs(
        id: "caller-session-id",
        session_key: "caller-session-key",
        status: "archived",
        last_activity_at: caller_time,
        archived_at: caller_time,
        inserted_at: caller_time,
        updated_at: caller_time,
        created_at: caller_time
      )

    assert {:ok, session} = Service.create_or_attach_current(repo, attrs)

    refute session.id == "caller-session-id"
    refute session.session_key == "caller-session-key"
    assert session.status == "active"
    assert is_nil(session.archived_at)
    assert DateTime.compare(session.last_activity_at, before_create) in [:eq, :gt]
    refute session.inserted_at == caller_time
    refute session.updated_at == caller_time
  end

  test "lifecycle transitions match the Solo Session contract", %{repo: repo} do
    valid_transitions = [
      {"active", "paused"},
      {"active", "completed"},
      {"active", "archived"},
      {"paused", "active"},
      {"paused", "completed"},
      {"paused", "archived"},
      {"completed", "archived"}
    ]

    for {current_status, next_status} <- valid_transitions do
      assert {:ok, session} = session_in_status(repo, current_status, "#{current_status}-#{next_status}")
      Process.sleep(5)

      assert {:ok, updated} = Service.update_status(repo, session.id, current_status, next_status)
      assert updated.status == next_status
      assert DateTime.compare(updated.last_activity_at, session.last_activity_at) == :gt

      if next_status == "archived" do
        assert %DateTime{} = updated.archived_at
      end
    end

    assert {:ok, completed} = session_in_status(repo, "completed", "completed-active")
    assert {:error, :invalid_transition} = Service.update_status(repo, completed.id, "completed", "active")

    assert {:ok, archived} = session_in_status(repo, "archived", "archived-active")
    assert {:error, :invalid_transition} = Service.update_status(repo, archived.id, "archived", "active")
    assert {:error, :invalid_status} = Service.update_status(repo, archived.id, "archived", "claimed")
  end

  test "same-status active and paused no-ops are rejected without mutating timestamps", %{repo: repo} do
    assert {:ok, active} = Service.create_or_attach_current(repo, session_attrs(caller_id: "active-no-op"))
    Process.sleep(5)

    assert {:error, :invalid_transition} = Service.update_status(repo, active.id, "active", "active")
    assert {:ok, active_after_noop} = Service.get(repo, active.id)
    assert active_after_noop.last_activity_at == active.last_activity_at
    assert active_after_noop.updated_at == active.updated_at
    assert active_after_noop.archived_at == active.archived_at

    assert {:ok, paused} = Service.pause(repo, active.id, "active")
    Process.sleep(5)

    assert {:error, :invalid_transition} = Service.update_status(repo, paused.id, "paused", "paused")
    assert {:ok, paused_after_noop} = Service.get(repo, paused.id)
    assert paused_after_noop.last_activity_at == paused.last_activity_at
    assert paused_after_noop.updated_at == paused.updated_at
    assert paused_after_noop.archived_at == paused.archived_at
  end

  test "archive_stale archives only active or paused sessions strictly older than threshold", %{repo: repo} do
    now = ~U[2026-05-15 12:00:00.000000Z]
    cutoff = DateTime.add(now, -30 * 24 * 60 * 60, :second)
    older = DateTime.add(cutoff, -1, :second)
    fresh = DateTime.add(cutoff, 1, :second)

    assert {:ok, old_active} = Service.create_or_attach_current(repo, session_attrs(caller_id: "old-active"))
    old_active = set_last_activity!(repo, old_active, older)

    assert {:ok, old_paused} = Service.create_or_attach_current(repo, session_attrs(caller_id: "old-paused"))
    assert {:ok, old_paused} = Service.pause(repo, old_paused.id, "active")
    old_paused = set_last_activity!(repo, old_paused, older)

    assert {:ok, boundary} = Service.create_or_attach_current(repo, session_attrs(caller_id: "boundary"))
    boundary = set_last_activity!(repo, boundary, cutoff)

    assert {:ok, fresh_session} = Service.create_or_attach_current(repo, session_attrs(caller_id: "fresh"))
    fresh_session = set_last_activity!(repo, fresh_session, fresh)

    assert {:ok, completed} = Service.create_or_attach_current(repo, session_attrs(caller_id: "completed-old"))
    assert {:ok, completed} = Service.complete(repo, completed.id, "active")
    completed = set_last_activity!(repo, completed, older)

    assert {:ok, 2} = Service.archive_stale(repo, now, 30)
    assert {:error, :invalid_stale_after_days} = Service.archive_stale(repo, now, 0)

    assert {:ok, old_active} = Service.get(repo, old_active.id)
    assert {:ok, old_paused} = Service.get(repo, old_paused.id)
    assert {:ok, boundary} = Service.get(repo, boundary.id)
    assert {:ok, fresh_session} = Service.get(repo, fresh_session.id)
    assert {:ok, completed} = Service.get(repo, completed.id)

    assert old_active.status == "archived"
    assert old_active.last_activity_at == older
    assert old_active.archived_at == now
    assert old_paused.status == "archived"
    assert old_paused.archived_at == now
    assert boundary.status == "active"
    assert fresh_session.status == "active"
    assert completed.status == "completed"
  end

  test "read and list do not advance activity", %{repo: repo} do
    assert {:ok, session} = Service.create_or_attach_current(repo, session_attrs())
    Process.sleep(5)

    assert {:ok, read} = Service.get(repo, session.id)
    assert read.last_activity_at == session.last_activity_at

    assert {:ok, [listed]} = Service.list(repo, %{repo: session.repo})
    assert listed.id == session.id
    assert listed.last_activity_at == session.last_activity_at
  end

  test "create attach and list filters trim and canonicalize lookup fields", %{repo: repo} do
    workspace_path = workspace_path("trimmed-filters")
    dotted_workspace = Path.join(workspace_path, ".")

    assert {:ok, session} =
             Service.create_or_attach_current(repo, %{
               repo: " nextide/example ",
               base_branch: " main ",
               workspace_path: " #{dotted_workspace} ",
               caller_id: " codex-local ",
               title: " Trimmed title "
             })

    assert session.repo == "nextide/example"
    assert session.base_branch == "main"
    assert session.caller_id == "codex-local"
    assert session.title == "Trimmed title"

    assert {:ok, [listed]} =
             Service.list(repo, %{
               repo: " nextide/example ",
               base_branch: " main ",
               workspace_path: " #{workspace_path} ",
               caller_id: " codex-local ",
               status: " active "
             })

    assert listed.id == session.id

    Process.sleep(5)

    assert {:ok, attached} =
             Service.create_or_attach_current(repo, %{
               repo: "nextide/example",
               base_branch: "main",
               workspace_path: workspace_path,
               caller_id: "codex-local"
             })

    assert attached.id == session.id
    assert DateTime.compare(attached.last_activity_at, session.last_activity_at) == :gt
  end

  test "relative workspace paths are rejected instead of using service cwd", %{repo: repo} do
    assert {:error, :invalid_workspace_path} =
             Service.create_or_attach_current(repo, session_attrs(workspace_path: "."))

    assert {:error, :invalid_workspace_path} = Service.list(repo, %{workspace_path: Path.join("relative", "workspace")})
    assert {:ok, []} = Service.list(repo)
  end

  test "concurrent first attaches converge on one active session", %{repo: repo} do
    attrs = session_attrs(workspace_path: workspace_path("concurrent"))

    results =
      1..20
      |> Task.async_stream(fn _index -> Service.create_or_attach_current(repo, attrs) end,
        max_concurrency: 20,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, {:ok, %SoloSession{}}} -> true
             _result -> false
           end)

    sessions = Enum.map(results, fn {:ok, {:ok, session}} -> session end)
    assert sessions |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 1

    assert {:ok, [current]} =
             Service.list(repo, %{
               repo: attrs.repo,
               base_branch: attrs.base_branch,
               workspace_path: attrs.workspace_path,
               caller_id: attrs.caller_id,
               status: "active"
             })

    assert current.id == hd(sessions).id
  end

  test "insert conflicts replay by reading the current session in a fresh transaction", %{repo: repo} do
    attrs = session_attrs(workspace_path: workspace_path("insert-conflict"))
    assert {:ok, existing} = Service.create_or_attach_current(repo, attrs)
    Process.sleep(5)

    assert {:ok, attached} = Service.create_or_attach_current(StaleCurrentReadRepo, attrs)

    assert attached.id == existing.id
    assert DateTime.compare(attached.last_activity_at, existing.last_activity_at) == :gt
  end

  test "database busy during create attach is retried", %{repo: repo} do
    attrs = session_attrs(workspace_path: workspace_path("busy-retry"))

    assert {:ok, session} = Service.create_or_attach_current(BusyOnceRepo, attrs)
    assert {:ok, [listed]} = Service.list(repo, %{workspace_path: attrs.workspace_path})
    assert listed.id == session.id
  end

  test "migration is idempotent and sessions-only", %{repo: repo} do
    assert :ok = Repository.migrate(repo)

    %{rows: rows} = SQL.query!(repo, "PRAGMA table_info(sympp_solo_sessions)")
    assert [_cid, "id", _type, _not_null, _default, 1] = Enum.find(rows, &(Enum.at(&1, 1) == "id"))
    assert Enum.any?(rows, &(Enum.at(&1, 1) == "workspace_path"))

    %{rows: []} =
      SQL.query!(repo, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sympp_solo_session_entries'")

    refute table_exists?(repo, "sympp_work_packages")
    refute table_exists?(repo, "sympp_work_requests")
    refute table_exists?(repo, "sympp_access_grants")
  end

  defp session_in_status(repo, "active", caller_id) do
    attrs = session_attrs(caller_id: caller_id, workspace_path: workspace_path(caller_id))
    Service.create_or_attach_current(repo, attrs)
  end

  defp session_in_status(repo, "paused", caller_id) do
    with {:ok, session} <- session_in_status(repo, "active", caller_id) do
      Service.pause(repo, session.id, "active")
    end
  end

  defp session_in_status(repo, "completed", caller_id) do
    with {:ok, session} <- session_in_status(repo, "active", caller_id) do
      Service.complete(repo, session.id, "active")
    end
  end

  defp session_in_status(repo, "archived", caller_id) do
    with {:ok, session} <- session_in_status(repo, "active", caller_id) do
      Service.archive(repo, session.id, "active")
    end
  end

  defp set_last_activity!(repo, %SoloSession{} = session, timestamp) do
    session
    |> Changeset.change(last_activity_at: timestamp, updated_at: timestamp)
    |> repo.update!()
  end

  defp session_attrs(overrides \\ []) do
    defaults = %{
      repo: "nextide/example",
      base_branch: "main",
      workspace_path: workspace_path("default"),
      caller_id: "codex-local",
      title: "Local planning"
    }

    Enum.into(overrides, defaults)
  end

  defp workspace_path(name) do
    path = Path.join(System.tmp_dir!(), "sympp-solo-session-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
  end

  defp table_exists?(repo, table_name) do
    %{rows: rows} =
      SQL.query!(repo, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [table_name])

    rows != []
  end
end
