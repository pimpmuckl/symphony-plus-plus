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

    start_supervised!({Repo, database: database_path, pool_size: 1})
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

  test "claiming a valid secret returns a scoped assignment without returning the raw secret", %{repo: repo} do
    assert {:ok, work_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-P1-002"))
    assert {:ok, minted} = Service.mint_worker_grant(repo, work_package.id)

    assert {:ok, %Assignment{} = assignment} =
             Service.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    assert assignment.grant_id == minted.grant.id
    assert assignment.work_package_id == work_package.id
    assert assignment.display_key == minted.work_key.display_key
    assert assignment.grant_role == "worker"
    assert assignment.capabilities == ["worker:claim"]
    assert assignment.claimed_by == "worker-1"
    refute inspect(assignment) =~ minted.work_key.secret
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
