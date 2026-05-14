defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestArchitectHandoffTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SecretHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = WorkRequestRepository.migrate(Repo)
    Application.put_env(:symphony_elixir, :sympp_repo_database, database_path)

    on_exit(fn ->
      restore_database_env(original_database)
      File.rm(database_path)
    end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)
    repo.delete_all(WorkRequest)

    store_dir = Path.join(System.tmp_dir!(), "sympp-architect-handoff-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(store_dir) end)

    {:ok, handoff_opts: handoff_opts(store_dir)}
  end

  test "creates a scoped phase anchor grant and redacted handoff", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_clarification")

    assert {:ok, handoff} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert handoff.status == :created

    assert handoff.work_request == %{
             id: work_request.id,
             repo: work_request.repo,
             base_branch: work_request.base_branch,
             status: work_request.status
           }

    assert handoff.phase.id =~ "phase-wr-architect-"
    assert handoff.anchor_package.id =~ "SYMPP-WR-ARCH-"
    assert handoff.anchor_package.repo == work_request.repo
    assert handoff.anchor_package.base_branch == work_request.base_branch
    assert handoff.grant.grant_role == "architect"
    assert handoff.grant.capabilities == ArchitectHandoff.capabilities()
    assert handoff.grant.scope_repo == work_request.repo
    assert handoff.grant.scope_base_branch == work_request.base_branch
    assert handoff.grant.secret_in_response == false
    refute Map.has_key?(handoff.grant, :secret_hash)
    refute Map.has_key?(handoff.grant, :secret)

    assert handoff.secret_handoff.mode in ["local-private-file", "windows-credential-manager"]
    assert handoff.secret_handoff.secret_in_stdout == false
    assert handoff.secret_handoff.database == Application.fetch_env!(:symphony_elixir, :sympp_repo_database)
    refute Map.has_key?(handoff.secret_handoff, :secret)
    refute Map.has_key?(handoff.secret_handoff, "secret")
    assert handoff.prompt =~ "symphony-plus-plus:symphony-architect"
    assert handoff.prompt =~ "Use ledger database"
    refute inspect(handoff) =~ "wk_"
    refute inspect(handoff) =~ "secret_hash"

    assert {:ok, phase} = PhaseRepository.get(repo, handoff.phase.id)
    assert phase.status == "active"
    assert {:ok, anchor} = WorkPackageRepository.get(repo, handoff.anchor_package.id)
    assert anchor.phase_id == phase.id
    assert anchor.kind == "delegation"
    assert anchor.repo == work_request.repo
    assert anchor.base_branch == work_request.base_branch
    assert anchor.allowed_file_globs == ["elixir/lib", "elixir/lib/**"]
    assert ScopeGuard.glob_match?("elixir/lib/**", "elixir/lib/symphony_elixir/work_requests.ex")
    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert grant.phase_id == phase.id
    assert grant.scope_repo == work_request.repo
    assert grant.scope_base_branch == work_request.base_branch

    cleanup_handoff(anchor, grant, handoff_opts)
  end

  test "WorkRequest scope edits do not mint a second handoff identity", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    assert {:ok, _updated_work_request} =
             WorkRequestRepository.update(repo, work_request.id, %{"repo" => "nextide/renamed-symphony"})

    assert {:error, :handoff_anchor_scope_conflict} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, phases} = PhaseRepository.list(repo)
    assert Enum.map(phases, & &1.id) == [first.phase.id]
    assert {:ok, anchors} = WorkPackageRepository.list(repo)
    assert Enum.map(anchors, & &1.id) == [first.anchor_package.id]
    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert Enum.map(grants, & &1.id) == [first.grant.id]

    cleanup_handoff(anchor, grant, handoff_opts)
  end

  test "repeated clicks replay the existing unclaimed active handoff", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, replayed} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert first.status == :created
    assert replayed.status == :replayed
    assert replayed.phase.id == first.phase.id
    assert replayed.anchor_package.id == first.anchor_package.id
    assert replayed.grant.id == first.grant.id

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    cleanup_handoff(anchor, grant, handoff_opts)
  end

  test "concurrent local operator handoffs converge on one active grant", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    results =
      1..5
      |> Task.async_stream(
        fn _index ->
          ArchitectHandoff.create_or_replay(repo, work_request.id,
            local_operator?: true,
            secret_handoff_opts: handoff_opts
          )
        end,
        max_concurrency: 5,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _handoff}, &1))

    handoffs = Enum.map(results, fn {:ok, handoff} -> handoff end)
    assert handoffs |> Enum.map(& &1.grant.id) |> Enum.uniq() |> length() == 1
    assert Enum.count(handoffs, &(&1.status == :created)) == 1
    assert Enum.count(handoffs, &(&1.status == :replayed)) == 4

    [handoff | _rest] = handoffs
    assert {:ok, anchor} = WorkPackageRepository.get(repo, handoff.anchor_package.id)
    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    cleanup_handoff(anchor, grant, handoff_opts)
  end

  test "missing active handoff metadata fails closed without renewing", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [first_grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    SecretHandoff.delete_worker_secret_by_grant(anchor, first_grant, handoff_opts)

    assert {:error, :handoff_secret_unavailable} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, preserved} = AccessGrantRepository.get(repo, first.grant.id)
    assert is_nil(preserved.revoked_at)

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    active_unclaimed_grants =
      Enum.filter(grants, &(is_nil(&1.revoked_at) and is_nil(&1.claimed_at)))

    assert Enum.map(active_unclaimed_grants, & &1.id) == [first.grant.id]

    Enum.each(grants, &cleanup_handoff(anchor, &1, handoff_opts))
  end

  if match?({:win32, _os_name}, :os.type()), do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "changed handoff settings do not revoke and orphan the old local private file", %{
    repo: repo,
    handoff_opts: handoff_opts
  } do
    handoff_opts = Keyword.put(handoff_opts, :mode, "local-private-file")
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [first_grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    old_secret_path = first.secret_handoff.path
    assert is_binary(old_secret_path)
    assert File.regular?(old_secret_path)

    changed_handoff_opts =
      Keyword.put(
        handoff_opts,
        :store_dir,
        Path.join(System.tmp_dir!(), "sympp-architect-handoff-changed-store-#{System.unique_integer([:positive])}")
      )

    assert {:error, :handoff_secret_unavailable} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: changed_handoff_opts
             )

    assert File.regular?(old_secret_path)
    assert {:ok, preserved} = AccessGrantRepository.get(repo, first.grant.id)
    assert is_nil(preserved.revoked_at)

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert Enum.map(grants, & &1.id) == [first.grant.id]

    cleanup_handoff(anchor, first_grant, handoff_opts)
    File.rm_rf!(Keyword.fetch!(changed_handoff_opts, :store_dir))
  end

  if match?({:win32, _os_name}, :os.type()), do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "older active grant with missing metadata aborts replay of a newer handoff", %{
    repo: repo,
    handoff_opts: handoff_opts
  } do
    handoff_opts = Keyword.put(handoff_opts, :mode, "local-private-file")
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [first_grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    changed_handoff_opts =
      Keyword.put(
        handoff_opts,
        :store_dir,
        Path.join(System.tmp_dir!(), "sympp-architect-handoff-newer-store-#{System.unique_integer([:positive])}")
      )

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, anchor.phase_id,
               work_package_id: anchor.id,
               capabilities: ArchitectHandoff.capabilities()
             )

    secret_grant = %{id: minted.grant.id, display_key: minted.grant.display_key, secret: minted.work_key.secret}
    metadata_grant = Map.delete(secret_grant, :secret)

    assert {:ok, raw_handoff} =
             SecretHandoff.store_worker_secret(
               %{work_package: anchor, worker_grant: secret_grant},
               changed_handoff_opts
             )

    assert :ok = SecretHandoff.store_worker_secret_metadata(anchor, metadata_grant, raw_handoff, changed_handoff_opts)

    assert {:error, {:handoff_metadata_read_failed, :enoent}} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: changed_handoff_opts
             )

    assert File.regular?(first.secret_handoff.path)
    assert {:ok, preserved} = AccessGrantRepository.get(repo, first.grant.id)
    assert is_nil(preserved.revoked_at)

    cleanup_handoff(anchor, first_grant, handoff_opts)
    cleanup_handoff(anchor, minted.grant, changed_handoff_opts)
    File.rm_rf!(Keyword.fetch!(changed_handoff_opts, :store_dir))
  end

  test "unverifiable active handoff metadata fails closed without minting a duplicate grant", %{
    repo: repo,
    handoff_opts: handoff_opts
  } do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [first_grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    assert {:ok, %{grant: duplicate_grant}} =
             AccessGrantService.mint_architect_grant(repo, anchor.phase_id,
               work_package_id: anchor.id,
               capabilities: ArchitectHandoff.capabilities()
             )

    unverifiable_handoff_opts =
      Keyword.put(handoff_opts, :metadata_dir, Path.join(System.tmp_dir!(), "sympp-unmanaged-metadata"))

    assert {:error, :unsupported_handoff_metadata_location} =
             SecretHandoff.read_worker_secret_metadata(anchor, first_grant, unverifiable_handoff_opts)

    assert {:error, :handoff_secret_unavailable} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: unverifiable_handoff_opts
             )

    assert {:ok, preserved} = AccessGrantRepository.get(repo, first.grant.id)
    assert is_nil(preserved.revoked_at)
    assert {:ok, duplicate} = AccessGrantRepository.get(repo, duplicate_grant.id)
    assert is_nil(duplicate.revoked_at)

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert grants |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([first.grant.id, duplicate_grant.id])

    cleanup_handoff(anchor, first_grant, handoff_opts)
  end

  test "corrupt active handoff metadata fails closed without renewing", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [first_grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    stale_metadata_path = only_metadata_file!(handoff_opts)
    File.write!(stale_metadata_path, "{not valid json")

    assert {:error, {:handoff_metadata_read_failed, :invalid_json}} =
             SecretHandoff.read_worker_secret_metadata(anchor, first_grant, handoff_opts)

    assert {:error, {:handoff_metadata_read_failed, :invalid_json}} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert File.exists?(stale_metadata_path)
    assert SecretHandoff.worker_secret_available?(first.secret_handoff, handoff_opts)

    assert {:ok, preserved} = AccessGrantRepository.get(repo, first.grant.id)
    assert is_nil(preserved.revoked_at)

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert Enum.map(grants, & &1.id) == [first.grant.id]

    assert :ok = SecretHandoff.delete_worker_secret(first.secret_handoff, handoff_opts)
    assert :ok = File.rm(stale_metadata_path)
  end

  test "semantically invalid active handoff metadata fails closed without renewing", %{
    repo: repo,
    handoff_opts: handoff_opts
  } do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [first_grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    invalid_metadata_path = only_metadata_file!(handoff_opts)

    invalid_metadata = %{
      "version" => 1,
      "work_package_id" => anchor.id,
      "worker_grant_display_key" => first_grant.display_key,
      "worker_grant_id" => first_grant.id,
      "mode" => first.secret_handoff.mode
    }

    File.write!(invalid_metadata_path, Jason.encode!(invalid_metadata))

    assert {:error, {:handoff_metadata_invalid, _reason}} =
             SecretHandoff.read_worker_secret_metadata(anchor, first_grant, handoff_opts)

    assert {:error, {:handoff_metadata_invalid, _reason}} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert File.exists?(invalid_metadata_path)

    assert {:ok, preserved} = AccessGrantRepository.get(repo, first.grant.id)
    assert is_nil(preserved.revoked_at)

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert Enum.map(grants, & &1.id) == [first.grant.id]

    assert :ok = SecretHandoff.delete_worker_secret(first.secret_handoff, handoff_opts)
    assert :ok = File.rm(invalid_metadata_path)
  end

  test "non-replayable active handoff grant is cleaned up before renewing", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [first_grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    first_grant
    |> Ecto.Changeset.change(capabilities: ["read:phase"])
    |> repo.update!()

    assert {:ok, renewed} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert renewed.status == :renewed
    assert renewed.grant.id != first.grant.id
    refute SecretHandoff.worker_secret_available?(first.secret_handoff, handoff_opts)

    assert {:ok, revoked} = AccessGrantRepository.get(repo, first.grant.id)
    assert %DateTime{} = revoked.revoked_at

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    active_unclaimed_grants =
      Enum.filter(grants, &(is_nil(&1.revoked_at) and is_nil(&1.claimed_at)))

    assert Enum.map(active_unclaimed_grants, & &1.id) == [renewed.grant.id]

    Enum.each(grants, &cleanup_handoff(anchor, &1, handoff_opts))
  end

  test "stale grant cleanup failure aborts renewal instead of reporting success", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [_first_grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert :ok = SecretHandoff.delete_worker_secret(first.secret_handoff, handoff_opts)
    assert SecretHandoff.worker_secret_availability(first.secret_handoff, handoff_opts) == :missing

    failing_handoff_opts =
      Keyword.put(handoff_opts, :delete_worker_secret_by_grant, fn _anchor, _grant, _opts ->
        {:error, :cleanup_failed}
      end)

    assert {:error, :cleanup_failed} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: failing_handoff_opts
             )

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert Enum.map(grants, & &1.id) == [first.grant.id]

    assert Enum.any?(grants, &(is_nil(&1.revoked_at) and is_nil(&1.claimed_at)))
  end

  if match?({:win32, _os_name}, :os.type()), do: @tag(skip: "local-private-file handoff is non-Windows only")

  test "corrupted local private file secrets are renewed instead of replayed", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert first.secret_handoff.mode == "local-private-file"
    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [_first_grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    File.write!(first.secret_handoff.path, "corrupted-local-secret")

    assert {:ok, renewed} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert renewed.status == :renewed
    assert renewed.grant.id != first.grant.id

    assert {:ok, revoked} = AccessGrantRepository.get(repo, first.grant.id)
    assert %DateTime{} = revoked.revoked_at
    refute File.exists?(first.secret_handoff.path)

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    active_unclaimed_grants =
      Enum.filter(grants, &(is_nil(&1.revoked_at) and is_nil(&1.claimed_at)))

    assert Enum.map(active_unclaimed_grants, & &1.id) == [renewed.grant.id]

    Enum.each(grants, &cleanup_handoff(anchor, &1, handoff_opts))
  end

  test "metadata write rollback reports secret cleanup failures", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")
    parent = self()

    failing_handoff_opts =
      handoff_opts
      |> Keyword.put(:store_worker_secret, fn %{work_package: anchor, worker_grant: worker_grant}, opts ->
        raw_handoff = fake_local_private_handoff(anchor, worker_grant, opts)
        File.mkdir_p!(Path.dirname(raw_handoff.path))
        File.write!(raw_handoff.path, "synthetic handoff fixture")
        send(parent, {:stored_handoff_path, raw_handoff.path})
        {:ok, raw_handoff}
      end)
      |> Keyword.put(:metadata_rename_fun, fn _temp_path, _metadata_path ->
        {:error, :synthetic_metadata_failure}
      end)
      |> Keyword.put(:delete_worker_secret, fn handoff, _opts ->
        send(parent, {:delete_worker_secret_called, handoff.path})
        {:error, :synthetic_secret_cleanup_failed}
      end)

    result =
      ArchitectHandoff.create_or_replay(repo, work_request.id,
        local_operator?: true,
        secret_handoff_opts: failing_handoff_opts
      )

    assert {:error, {:handoff_setup_rollback_failed, reason, failures}} = result
    assert reason == {:handoff_metadata_write_failed, {:rename, :synthetic_metadata_failure}}
    assert {:worker_secret, :synthetic_secret_cleanup_failed} in failures
    assert_receive {:stored_handoff_path, secret_path}
    assert_receive {:delete_worker_secret_called, ^secret_path}
    assert File.regular?(secret_path)
    File.rm(secret_path)

    assert {:ok, anchor} =
             WorkPackageRepository.get(repo, ArchitectHandoff.anchor_id_for_work_request(work_request))

    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert %DateTime{} = grant.revoked_at
  end

  test "metadata read-back rollback reports both cleanup failures", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")
    parent = self()

    failing_handoff_opts =
      handoff_opts
      |> Keyword.put(:store_worker_secret, fn %{work_package: anchor, worker_grant: worker_grant}, opts ->
        raw_handoff = fake_local_private_handoff(anchor, worker_grant, opts)
        File.mkdir_p!(Path.dirname(raw_handoff.path))
        File.write!(raw_handoff.path, "synthetic handoff fixture")
        send(parent, {:stored_handoff_path, raw_handoff.path})
        {:ok, raw_handoff}
      end)
      |> Keyword.put(:metadata_rename_fun, fn temp_path, metadata_path ->
        :ok = File.rename(temp_path, metadata_path)
        File.write!(metadata_path, "not json")
      end)
      |> Keyword.put(:delete_worker_secret_by_grant, fn _anchor, _grant, _opts ->
        {:error, :synthetic_metadata_cleanup_failed}
      end)
      |> Keyword.put(:delete_worker_secret, fn handoff, _opts ->
        send(parent, {:delete_worker_secret_called, handoff.path})
        {:error, :synthetic_secret_cleanup_failed}
      end)

    result =
      ArchitectHandoff.create_or_replay(repo, work_request.id,
        local_operator?: true,
        secret_handoff_opts: failing_handoff_opts
      )

    assert {:error, {:handoff_setup_rollback_failed, {:handoff_metadata_read_failed, :invalid_json}, failures}} =
             result

    assert {:worker_secret_by_grant, :synthetic_metadata_cleanup_failed} in failures
    assert {:worker_secret, :synthetic_secret_cleanup_failed} in failures
    assert_receive {:stored_handoff_path, secret_path}
    assert_receive {:delete_worker_secret_called, ^secret_path}
    assert File.regular?(secret_path)
    File.rm(secret_path)

    assert {:ok, anchor} =
             WorkPackageRepository.get(repo, ArchitectHandoff.anchor_id_for_work_request(work_request))

    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert %DateTime{} = grant.revoked_at
  end

  test "setup rollback reports architect grant revoke failures", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    failing_handoff_opts =
      handoff_opts
      |> Keyword.put(:mode, "unsupported")
      |> Keyword.put(:revoke_grant, fn _repo, _grant, _opts -> {:error, :synthetic_revoke_failed} end)

    result =
      ArchitectHandoff.create_or_replay(repo, work_request.id,
        local_operator?: true,
        secret_handoff_opts: failing_handoff_opts
      )

    assert {:error, {:handoff_setup_rollback_failed, :unsupported_secret_handoff_mode, failures}} = result
    assert failures == [{:architect_grant, :synthetic_revoke_failed}]

    assert {:ok, anchor} =
             WorkPackageRepository.get(repo, ArchitectHandoff.anchor_id_for_work_request(work_request))

    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert is_nil(grant.revoked_at)

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, grant.id)
  end

  test "stale local private file metadata is renewed instead of replayed", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [first_grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert :ok = SecretHandoff.delete_worker_secret_by_grant(anchor, first_grant, handoff_opts)

    metadata_grant = %{id: first_grant.id, display_key: first_grant.display_key}
    stale_path = local_private_file_path(anchor, metadata_grant, handoff_opts)
    File.mkdir_p!(Path.dirname(stale_path))
    File.write!(stale_path, "stale local handoff fixture")

    assert :ok =
             SecretHandoff.store_worker_secret_metadata(
               anchor,
               metadata_grant,
               %{"mode" => "local-private-file", "path" => stale_path},
               handoff_opts
             )

    File.rm!(stale_path)
    assert {:ok, stale_display} = SecretHandoff.read_worker_secret_metadata(anchor, first_grant, handoff_opts)
    assert stale_display.mode == "local-private-file"
    refute File.regular?(stale_display.path)

    assert {:ok, renewed} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert renewed.status == :renewed
    assert renewed.grant.id != first.grant.id

    assert {:ok, revoked} = AccessGrantRepository.get(repo, first.grant.id)
    assert %DateTime{} = revoked.revoked_at

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    active_unclaimed_grants =
      Enum.filter(grants, &(is_nil(&1.revoked_at) and is_nil(&1.claimed_at)))

    assert Enum.map(active_unclaimed_grants, & &1.id) == [renewed.grant.id]

    Enum.each(grants, &cleanup_handoff(anchor, &1, handoff_opts))
  end

  test "stale Windows Credential Manager metadata is renewed instead of replayed", %{repo: repo, handoff_opts: handoff_opts} do
    if windows?() and powershell_executable() do
      windows_handoff_opts = Keyword.put(handoff_opts, :mode, "windows-credential-manager")
      work_request = create_work_request!(repo, status: "ready_for_slicing")

      assert {:ok, first} =
               ArchitectHandoff.create_or_replay(repo, work_request.id,
                 local_operator?: true,
                 secret_handoff_opts: windows_handoff_opts
               )

      assert first.secret_handoff.mode == "windows-credential-manager"
      assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
      assert {:ok, [_first_grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

      assert :ok = SecretHandoff.delete_worker_secret(first.secret_handoff, windows_handoff_opts)
      refute SecretHandoff.worker_secret_available?(first.secret_handoff, windows_handoff_opts)

      assert {:ok, renewed} =
               ArchitectHandoff.create_or_replay(repo, work_request.id,
                 local_operator?: true,
                 secret_handoff_opts: windows_handoff_opts
               )

      assert renewed.status == :renewed
      assert renewed.grant.id != first.grant.id

      assert {:ok, revoked} = AccessGrantRepository.get(repo, first.grant.id)
      assert %DateTime{} = revoked.revoked_at

      assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

      active_unclaimed_grants =
        Enum.filter(grants, &(is_nil(&1.revoked_at) and is_nil(&1.claimed_at)))

      assert Enum.map(active_unclaimed_grants, & &1.id) == [renewed.grant.id]

      Enum.each(grants, &cleanup_handoff(anchor, &1, windows_handoff_opts))
    end
  end

  if match?({:win32, _os_name}, :os.type()), do: @tag(skip: "POSIX file permissions required")

  test "unreadable local private file secrets fail closed without renewing", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_slicing")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [first_grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert :ok = SecretHandoff.delete_worker_secret_by_grant(anchor, first_grant, handoff_opts)

    metadata_grant = %{id: first_grant.id, display_key: first_grant.display_key}
    unreadable_path = local_private_file_path(anchor, metadata_grant, handoff_opts)
    File.mkdir_p!(Path.dirname(unreadable_path))
    File.write!(unreadable_path, "unreadable local handoff fixture")

    assert :ok =
             SecretHandoff.store_worker_secret_metadata(
               anchor,
               metadata_grant,
               %{"mode" => "local-private-file", "path" => unreadable_path},
               handoff_opts
             )

    File.chmod!(unreadable_path, 0o000)

    assert {:error, _reason} = File.open(unreadable_path, [:read], fn _io_device -> :ok end)

    assert {:error, :handoff_secret_unavailable} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    File.chmod(unreadable_path, 0o600)

    assert {:ok, preserved} = AccessGrantRepository.get(repo, first.grant.id)
    assert is_nil(preserved.revoked_at)

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert Enum.map(grants, & &1.id) == [first.grant.id]

    Enum.each(grants, &cleanup_handoff(anchor, &1, handoff_opts))
  end

  test "claimed handoffs are renewed without returning secrets", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "human_info_needed")

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert {:ok, [first_grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    first_grant
    |> Ecto.Changeset.change(claimed_at: DateTime.utc_now(:microsecond), claimed_by: "architect-agent")
    |> repo.update!()

    assert {:ok, renewed} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert renewed.status == :renewed
    assert renewed.grant.id != first.grant.id
    refute inspect(renewed) =~ "wk_"

    assert {:ok, grants} = AccessGrantRepository.list_for_work_package(repo, anchor.id)
    assert length(grants) == 2

    Enum.each(grants, &cleanup_handoff(anchor, &1, handoff_opts))
  end

  test "service requires explicit local operator mode", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "ready_for_clarification")

    assert {:error, :forbidden} =
             ArchitectHandoff.create_or_replay(repo, work_request.id, secret_handoff_opts: handoff_opts)

    assert {:ok, []} = PhaseRepository.list(repo)
    assert {:ok, []} = WorkPackageRepository.list(repo)
  end

  test "WorkRequests without frozen repo scope cannot mint handoffs", %{repo: repo, handoff_opts: handoff_opts} do
    work_request =
      repo.insert!(%WorkRequest{
        id: "WR-ARCH-HANDOFF-BLANK-SCOPE",
        title: "Blank scope",
        repo: "",
        base_branch: "main",
        work_type: "feature",
        human_description: "Stored row without a repo should fail closed.",
        constraints: %{},
        desired_dispatch_shape: "architect_led_feature_branch",
        status: "ready_for_slicing"
      })

    assert {:error, :invalid_scope} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, []} = PhaseRepository.list(repo)
    assert {:ok, []} = WorkPackageRepository.list(repo)
  end

  test "WorkRequests with invalid file scope fail before creating handoff state", %{repo: repo, handoff_opts: handoff_opts} do
    work_request =
      repo.insert!(%WorkRequest{
        id: "WR-ARCH-HANDOFF-INVALID-FILE-SCOPE",
        title: "Invalid file scope",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        work_type: "feature",
        human_description: "Stored row with malformed allowed paths should fail closed.",
        constraints: %{"allowed_paths" => "elixir/lib"},
        desired_dispatch_shape: "architect_led_feature_branch",
        status: "ready_for_slicing"
      })

    assert {:error, :invalid_scope} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, []} = PhaseRepository.list(repo)
    assert {:ok, []} = WorkPackageRepository.list(repo)
  end

  test "WorkRequests with overlapping forbidden scope fail before creating handoff state", %{repo: repo, handoff_opts: handoff_opts} do
    work_request =
      repo.insert!(%WorkRequest{
        id: "WR-ARCH-HANDOFF-FORBIDDEN-FILE-SCOPE",
        title: "Forbidden file scope",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        work_type: "feature",
        human_description: "Stored row with forbidden paths must fail closed.",
        constraints: %{"allowed_paths" => ["elixir"], "forbidden_paths" => ["elixir/secrets/**"]},
        desired_dispatch_shape: "architect_led_feature_branch",
        status: "ready_for_slicing"
      })

    assert {:error, :invalid_scope} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, []} = PhaseRepository.list(repo)
    assert {:ok, []} = WorkPackageRepository.list(repo)
  end

  test "existing architect anchor must match the WorkRequest file scope", %{repo: repo, handoff_opts: handoff_opts} do
    work_request =
      create_work_request!(repo,
        status: "ready_for_slicing",
        constraints: %{"allowed_paths" => ["elixir/lib", "docs"], "requires_secret" => false}
      )

    assert {:ok, first} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, anchor} = WorkPackageRepository.get(repo, first.anchor_package.id)
    assert anchor.kind == "delegation"
    assert anchor.allowed_file_globs == ["docs", "docs/**", "elixir/lib", "elixir/lib/**"]
    assert ScopeGuard.glob_match?("docs/**", "docs/operator/handoff.md")
    assert ScopeGuard.glob_match?("elixir/lib/**", "elixir/lib/symphony_elixir/work_requests.ex")
    assert {:ok, [grant]} = AccessGrantRepository.list_for_work_package(repo, anchor.id)

    assert {:ok, _updated_work_request} =
             WorkRequestRepository.update(repo, work_request.id, %{
               constraints: %{"allowed_paths" => ["docs", "elixir/lib"], "requires_secret" => false}
             })

    assert {:ok, replayed} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert replayed.status == :replayed
    assert replayed.grant.id == first.grant.id

    anchor
    |> Ecto.Changeset.change(kind: "phase_child")
    |> repo.update!()

    assert {:error, :handoff_anchor_scope_conflict} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    anchor =
      anchor
      |> Ecto.Changeset.change(kind: "delegation")
      |> repo.update!()

    anchor
    |> Ecto.Changeset.change(allowed_file_globs: [])
    |> repo.update!()

    assert {:error, :handoff_anchor_scope_conflict} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    cleanup_handoff(anchor, grant, handoff_opts)
  end

  test "draft WorkRequests cannot mint handoffs", %{repo: repo, handoff_opts: handoff_opts} do
    work_request = create_work_request!(repo, status: "draft")

    assert {:error, :invalid_status} =
             ArchitectHandoff.create_or_replay(repo, work_request.id,
               local_operator?: true,
               secret_handoff_opts: handoff_opts
             )

    assert {:ok, []} = PhaseRepository.list(repo)
    assert {:ok, []} = WorkPackageRepository.list(repo)
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-ARCH-HANDOFF-#{System.unique_integer([:positive])}",
      title: "Start architect handoff",
      repo: "nextide/symphony-plus-plus",
      base_branch: "main",
      work_type: "feature",
      human_description: "Let an architect clarify and slice the request.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "requires_secret" => false},
      desired_dispatch_shape: "architect_led_feature_branch",
      status: "ready_for_clarification"
    }

    Enum.into(overrides, defaults)
  end

  defp handoff_opts(store_dir) do
    [
      mode: default_handoff_mode(),
      repo_root: repo_root(),
      store_dir: store_dir,
      claimed_by: ArchitectHandoff.claimed_by(),
      database: Application.fetch_env!(:symphony_elixir, :sympp_repo_database)
    ]
  end

  defp default_handoff_mode do
    if windows?(), do: "windows-credential-manager", else: "local-private-file"
  end

  defp cleanup_handoff(%WorkPackage{} = anchor, %AccessGrant{} = grant, handoff_opts) do
    SecretHandoff.delete_worker_secret_by_grant(anchor, grant, handoff_opts)
  end

  defp fake_local_private_handoff(%WorkPackage{} = anchor, worker_grant, opts) do
    %{
      mode: "local-private-file",
      status: "stored",
      work_package_id: anchor.id,
      display_key: Map.fetch!(worker_grant, :display_key),
      target: "synthetic-target",
      env_var: "SYMPP_WORK_KEY_SECRET",
      claimed_by: Keyword.fetch!(opts, :claimed_by),
      claimed_by_required: true,
      secret_in_stdout: false,
      path: local_private_file_path(anchor, worker_grant, opts),
      store: "test local private file"
    }
  end

  defp only_metadata_file!(opts) do
    metadata_dir = Path.join(Path.expand(Keyword.fetch!(opts, :store_dir)), "metadata")
    assert [metadata_path] = Path.wildcard(Path.join(metadata_dir, "*.json"))
    metadata_path
  end

  defp local_private_file_path(%WorkPackage{} = work_package, worker_grant, opts) do
    store_dir = Keyword.fetch!(opts, :store_dir)
    display_key = Map.get(worker_grant, :display_key) || Map.get(worker_grant, "display_key")
    grant_identity = worker_grant |> Map.get(:id, Map.get(worker_grant, "id")) |> String.trim()

    filename =
      "#{safe_filename(work_package.id)}-#{safe_filename(display_key)}-#{safe_filename(grant_identity)}-#{handoff_filename_hash(work_package, display_key, grant_identity, opts)}.secret"

    Path.join(Path.expand(store_dir), filename)
  end

  defp handoff_filename_hash(%WorkPackage{} = work_package, display_key, grant_identity, opts) do
    hash_source = [
      opts |> Keyword.get(:repo_root, "") |> to_string() |> Path.expand(),
      0,
      database_hash_value(opts),
      0,
      work_package.id,
      0,
      display_key,
      0,
      grant_identity
    ]

    :sha256
    |> :crypto.hash(hash_source)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  defp database_hash_value(opts) do
    case Keyword.get(opts, :database) do
      database when is_binary(database) ->
        database
        |> String.trim()
        |> database_hash_value(database)

      nil ->
        ""

      database ->
        :erlang.term_to_binary(database)
    end
  end

  defp database_hash_value("", _database), do: ""
  defp database_hash_value(_trimmed, database), do: database |> Repo.database_key() |> :erlang.term_to_binary()

  defp safe_filename(value) when is_binary(value) do
    Regex.replace(~r/[^A-Za-z0-9._-]+/, value, "_")
  end

  defp repo_root do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.join("..")
    |> Path.expand()
  end

  defp powershell_executable do
    System.find_executable("powershell.exe") ||
      System.find_executable("pwsh") ||
      System.find_executable("powershell")
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  defp restore_database_env(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_database)
  defp restore_database_env(database), do: Application.put_env(:symphony_elixir, :sympp_repo_database, database)
end
