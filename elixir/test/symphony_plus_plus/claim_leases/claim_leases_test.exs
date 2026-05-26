defmodule SymphonyElixir.SymphonyPlusPlus.ClaimLeasesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Repository
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(ClaimLease)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "migration is idempotent and preserves existing package and grant rows", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-MIGRATION"))
    assert {:ok, %{grant: grant}} = AccessGrantService.mint_worker_grant(repo, work_package.id)

    assert :ok = Repository.migrate(repo)
    assert :ok = Repository.migrate(repo)

    assert {:ok, ^work_package} = WorkPackageRepository.get(repo, work_package.id)
    assert %AccessGrant{} = persisted_grant = repo.get!(AccessGrant, grant.id)
    assert persisted_grant.id == grant.id
    assert persisted_grant.work_package_id == work_package.id

    columns = column_names(repo, "sympp_claim_leases")

    for column <- ~w(id work_package_id access_grant_id claim_group_id previous_claim_id actor_kind actor_id status last_seen_at stale_after_ms stale_at paused_at reclaimed_at released_at) do
      assert column in columns
    end

    indexes = index_names(repo, "sympp_claim_leases")
    assert "sympp_claim_leases_one_current_per_work_package_index" in indexes
    assert "sympp_claim_leases_status_last_seen_index" in indexes
  end

  test "claim lease transitions preserve actor identity and continuity through stale reclaim", %{repo: repo} do
    now = ~U[2026-05-26 10:00:00Z]
    heartbeat_at = DateTime.add(now, 500, :millisecond)
    pause_at = DateTime.add(now, 600, :millisecond)
    reclaim_at = DateTime.add(now, 2_000, :millisecond)

    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-RECLAIM"))
    assert {:ok, %{grant: grant}} = AccessGrantService.mint_worker_grant(repo, work_package.id)

    assert {:ok, claim} =
             Service.claim(
               repo,
               work_package.id,
               %{actor_kind: "agent", actor_id: "agent-1", actor_display_name: "Agent One"},
               access_grant_id: grant.id,
               stale_after_ms: 1_000,
               now: now
             )

    assert claim.status == "active"
    assert claim.claim_group_id == claim.id
    assert claim.previous_claim_id == nil
    assert claim.actor_id == "agent-1"
    assert claim.access_grant_id == grant.id

    assert {:ok, claim} =
             Repository.heartbeat(
               repo,
               claim.id,
               %{
                 actor_kind: "human",
                 actor_id: "agent-9",
                 actor_display_name: "Wrong Actor",
                 access_grant_id: "grant_wrong",
                 status: "released",
                 released_at: heartbeat_at,
                 lease_expires_at: DateTime.add(now, 5, :second)
               },
               now: heartbeat_at
             )

    assert DateTime.compare(claim.last_seen_at, heartbeat_at) == :eq
    assert claim.actor_kind == "agent"
    assert claim.actor_id == "agent-1"
    assert claim.actor_display_name == "Agent One"
    assert claim.access_grant_id == grant.id
    assert claim.status == "active"
    assert claim.released_at == nil
    refute Service.stale?(claim, DateTime.add(now, 1_400, :millisecond))
    assert Service.stale?(claim, reclaim_at)

    assert {:ok, paused} = Service.pause(repo, claim.id, %{actor_id: "agent-1"}, now: pause_at, reason: "operator pause")
    assert paused.status == "paused"
    assert DateTime.compare(paused.paused_at, pause_at) == :eq
    assert paused.paused_by_actor_id == "agent-1"
    assert paused.pause_reason == "operator pause"

    assert {:ok, replacement} =
             Service.reclaim_stale(
               repo,
               work_package.id,
               %{actor_kind: "agent", actor_id: "agent-2", actor_display_name: "Agent Two"},
               now: reclaim_at,
               reason: "stale lease"
             )

    assert replacement.status == "active"
    assert replacement.actor_id == "agent-2"
    assert replacement.claim_group_id == claim.claim_group_id
    assert replacement.previous_claim_id == claim.id
    assert replacement.access_grant_id == grant.id
    assert replacement.stale_after_ms == 1_000
    assert DateTime.compare(replacement.lease_started_at, reclaim_at) == :eq
    assert Service.stale?(replacement, DateTime.add(reclaim_at, 1_001, :millisecond))

    assert {:ok, reclaimed} = Repository.get(repo, claim.id)
    assert reclaimed.status == "reclaimed"
    assert DateTime.compare(reclaimed.reclaimed_at, reclaim_at) == :eq
    assert reclaimed.reclaimed_by_actor_id == "agent-2"
    assert reclaimed.reclaim_reason == "stale lease"
    assert DateTime.compare(reclaimed.stale_at, reclaim_at) == :eq
    assert reclaimed.stale_reason == "stale lease"
  end

  test "only one current claim exists per package and release frees the package", %{repo: repo} do
    now = ~U[2026-05-26 11:00:00Z]
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CLAIM-UNIQUE"))

    assert {:ok, first} =
             Service.claim(repo, work_package.id, %{actor_kind: "agent", actor_id: "agent-1"}, stale_after_ms: 1_000, now: now)

    assert {:error, :active_claim_exists} =
             Service.claim(repo, work_package.id, %{actor_kind: "agent", actor_id: "agent-2"}, stale_after_ms: 1_000, now: now)

    assert {:ok, current} = Service.current_for_work_package(repo, work_package.id)
    assert current.id == first.id

    released_at = DateTime.add(now, 1, :second)
    assert {:ok, released} = Service.release(repo, first.id, now: released_at, reason: "worker finished")
    assert released.status == "released"
    assert released.release_reason == "worker finished"
    assert DateTime.compare(released.released_at, released_at) == :eq

    assert {:ok, second} =
             Service.claim(
               repo,
               work_package.id,
               %{
                 "work_package_id" => "SYMPP-WRONG",
                 "claim_group_id" => "claim_group_wrong",
                 "previous_claim_id" => "claim_wrong",
                 "actor_kind" => "agent",
                 "actor_id" => "agent-2"
               },
               stale_after_ms: 1_000,
               now: released_at
             )

    assert second.status == "active"
    assert second.id != first.id
    assert second.work_package_id == work_package.id
    assert second.claim_group_id == second.id
    assert second.previous_claim_id == nil
  end

  defp column_names(repo, table) do
    %{rows: rows} = SQL.query!(repo, "PRAGMA table_info(#{table})")
    Enum.map(rows, &Enum.at(&1, 1))
  end

  defp index_names(repo, table) do
    %{rows: rows} = SQL.query!(repo, "PRAGMA index_list(#{table})")
    Enum.map(rows, &Enum.at(&1, 1))
  end
end
