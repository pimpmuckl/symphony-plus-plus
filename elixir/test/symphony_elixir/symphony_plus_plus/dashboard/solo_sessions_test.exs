defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.SoloSessionsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.WorkPackageFactory

  @repo_root Path.expand("../../../../../", __DIR__)

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = Repository.migrate(Repo)
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(SoloSessionEntry)
    repo.delete_all(SoloSession)
    :ok
  end

  test "cards report active blockers separately from historical blocker entries", %{repo: repo} do
    assert {:ok, session} =
             Service.create_or_attach_current(repo, %{
               repo: "nextide/demo-operator",
               base_branch: "main",
               workspace_path: @repo_root,
               caller_id: "solo-active-blockers",
               title: "Track blocker state"
             })

    assert {:ok, _blocker} =
             Service.report_blocker(repo, session.id, %{
               summary: "Review needs scope approval",
               blocker_id: "scope-review"
             })

    assert {:ok, _resolved} =
             Service.resolve_blocker(repo, session.id, %{
               blocker_id: "scope-review",
               resolution: "Architect approved the extra file",
               idempotency_key: "dashboard-solo-resolve-scope-review"
             })

    assert {:ok, payload} = Dashboard.solo_sessions(repo)
    assert [card] = payload.solo_sessions
    assert card.active_blocker_count == 0
    assert [%{kind: "blocker", count: 2}] = Enum.filter(card.entry_counts, &(&1.kind == "blocker"))
  end
end
