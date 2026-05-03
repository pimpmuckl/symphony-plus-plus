defmodule SymphonyElixir.SymphonyPlusPlus.AccessGrantsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
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
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "generates high-entropy work keys with four-character display keys" do
    first = WorkKey.generate()
    second = WorkKey.generate()

    assert String.length(first.display_key) == 4
    assert first.display_key =~ ~r/\A[0-9A-F]{4}\z/
    assert WorkKey.secret_shape?(first.secret)
    assert String.length(first.secret) >= 46
    assert first.secret != second.secret
    assert WorkKey.secret_hash(first.secret) != WorkKey.secret_hash(second.secret)
  end

  test "mints a worker grant for one work package and stores only a secret hash", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-002"))

    assert {:ok, %{grant: grant, work_key: work_key}} =
             Service.mint_worker_grant(repo, work_package.id, capabilities: ["worker:claim"])

    assert %AccessGrant{} = grant
    assert grant.work_package_id == work_package.id
    assert grant.grant_role == "worker"
    assert grant.display_key == work_key.display_key
    assert grant.secret_hash == WorkKey.secret_hash(work_key.secret)
    refute grant.secret_hash == work_key.secret

    assert {:ok, persisted} = Repository.get(repo, grant.id)
    refute Map.has_key?(Map.from_struct(persisted), :secret)
    refute Map.has_key?(Map.from_struct(persisted), :raw_secret)
    refute inspect(persisted) =~ persisted.secret_hash
    refute inspect(work_key) =~ work_key.secret
  end

  test "create ignores terminal lifecycle fields", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    work_key = WorkKey.generate()
    timestamp = ~U[2026-04-30 10:00:00Z]

    assert {:ok, grant} =
             Repository.create(repo, %{
               work_package_id: work_package.id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "worker",
               capabilities: ["worker:claim"],
               expires_at: DateTime.add(timestamp, 60, :second),
               claimed_at: timestamp,
               claimed_by: "worker-1",
               revoked_at: timestamp
             })

    assert grant.claimed_at == nil
    assert grant.claimed_by == nil
    assert grant.revoked_at == nil
  end

  test "claiming a valid secret returns a scoped assignment without returning the raw secret", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-002"))
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:ok, %Assignment{} = assignment} =
             Service.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    assert assignment.grant_id == minted.grant.id
    assert assignment.work_package_id == work_package.id
    assert assignment.display_key == minted.work_key.display_key
    assert assignment.grant_role == "worker"
    assert assignment.capabilities == ["worker:claim", "worker:lifecycle.transition"]
    assert assignment.claimed_by == "worker-1"
    refute inspect(assignment) =~ minted.work_key.secret
  end

  test "repository claims require a nonblank worker identity", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:error, :missing_claim_identity} =
             Repository.claim(repo, minted.work_key.secret, %{}, DateTime.utc_now(:microsecond))

    assert {:error, :missing_claim_identity} =
             Repository.claim(repo, minted.work_key.secret, %{claimed_by: "   "}, DateTime.utc_now(:microsecond))

    assert {:ok, persisted} = Repository.get(repo, minted.grant.id)
    assert persisted.claimed_at == nil
    assert persisted.claimed_by == nil
  end

  test "service claims do not invent a worker identity", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:error, :missing_claim_identity} = Service.claim(repo, minted.work_key.secret)

    assert {:ok, persisted} = Repository.get(repo, minted.grant.id)
    assert persisted.claimed_at == nil
    assert persisted.claimed_by == nil
  end

  test "expired grants reject claims", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    now = ~U[2026-04-30 10:00:00Z]

    assert {:ok, minted} =
             Service.mint_worker_grant(repo, work_package.id,
               now: now,
               expires_at: DateTime.add(now, -1, :second)
             )

    assert {:error, :expired} = Service.claim(repo, minted.work_key.secret, now: now, claimed_by: "worker-1")
  end

  test "revoked grants reject claims", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)
    assert {:ok, %AccessGrant{revoked_at: %DateTime{}}} = Service.revoke(repo, minted.grant.id)

    assert {:error, :revoked} = Service.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
  end

  test "revoke is idempotent and preserves the first revocation timestamp", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)
    first_revoked_at = ~U[2026-04-30 10:00:00Z]
    later_revoked_at = ~U[2026-04-30 11:00:00Z]

    assert {:ok, first_revoke} = Service.revoke(repo, minted.grant.id, now: first_revoked_at)
    assert {:ok, second_revoke} = Service.revoke(repo, minted.grant.id, now: later_revoked_at)

    assert DateTime.compare(first_revoke.revoked_at, first_revoked_at) == :eq
    assert second_revoke.revoked_at == first_revoke.revoked_at
  end

  test "invalid secrets reject claims", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, _minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:error, :invalid_secret} = Service.claim(repo, "wk_not-the-secret", claimed_by: "worker-1")
  end

  test "double claim is explicitly rejected after the first valid claim", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:ok, %Assignment{}} = Service.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    assert {:error, :already_claimed} = Service.claim(repo, minted.work_key.secret, claimed_by: "worker-2")
  end

  test "concurrent claims allow only one worker to claim the grant", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    results =
      1..8
      |> Task.async_stream(
        fn index ->
          Service.claim(repo, minted.work_key.secret, claimed_by: "worker-#{index}")
        end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert 1 == Enum.count(results, &match?({:ok, %Assignment{}}, &1))
    assert 7 == Enum.count(results, &match?({:error, :already_claimed}, &1))
  end

  test "four-character display key alone cannot authenticate", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:error, :display_key_only} = Service.claim(repo, minted.work_key.display_key, claimed_by: "worker-1")
  end

  test "worker grant cannot include architect capabilities", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())

    assert {:error, %Ecto.Changeset{} = changeset} =
             Service.mint_worker_grant(repo, work_package.id, capabilities: ["worker:claim", "architect:merge"])

    assert "worker grants cannot include architect capabilities" in errors_on(changeset).capabilities
  end

  test "worker grant cannot include architect MCP tool capabilities", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())

    for capability <- [
          "read:phase",
          "read:child_progress",
          "read:child_findings",
          "mint:child_worker_key",
          "approve:child_ready_state",
          "split:child_work_package",
          "write:phase_plan",
          "update:child_work_package"
        ] do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Service.mint_worker_grant(repo, work_package.id, capabilities: ["worker:claim", capability])

      assert "worker grants cannot include architect capabilities" in errors_on(changeset).capabilities
    end
  end

  test "non-id constraint failures are not reported as duplicate ids", %{repo: repo} do
    work_key = WorkKey.generate()

    assert {:error, {:constraint_failed, "foreign_key"}} =
             Repository.create(repo, %{
               work_package_id: "missing-work-package",
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "worker",
               capabilities: ["worker:claim"],
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
             })
  end

  test "raw secret is returned only at mint time and not emitted in logs", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs())

    {minted, log} =
      capture_secret_log(fn ->
        assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)
        assert {:ok, %Assignment{} = assignment} = Service.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
        refute Map.has_key?(Map.from_struct(assignment), :secret)
        minted
      end)

    refute log =~ minted.work_key.secret
  end

  defp capture_secret_log(fun) do
    ref = make_ref()
    parent = self()

    log =
      capture_log(fn ->
        send(parent, {ref, fun.()})
      end)

    receive do
      {^ref, result} -> {result, log}
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
  end
end
