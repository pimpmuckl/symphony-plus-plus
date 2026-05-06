Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.PhasesTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Service, as: PhaseService
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  defmodule PhaseBoardMaterializationRepo do
    alias SymphonyElixir.SymphonyPlusPlus.Repo
    alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

    @blocked_key :sympp_phase_board_blocked_card_id

    def block_materialization(work_package_id), do: Process.put(@blocked_key, work_package_id)
    def clear_materialization_block, do: Process.delete(@blocked_key)

    def get(WorkPackage, id) do
      if Process.get(@blocked_key) == id do
        raise "out-of-scope phase board card materialized: #{id}"
      else
        Repo.get(WorkPackage, id)
      end
    end

    def get(schema, id), do: Repo.get(schema, id)
    def all(query), do: Repo.all(query)
    def one(query), do: Repo.one(query)
    def transaction(fun), do: Repo.transaction(fun)
    def rollback(value), do: Repo.rollback(value)
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = PhaseRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    repo.delete_all(Phase)
    :ok
  end

  test "creates and reads a phase", %{repo: repo} do
    assert {:ok, %Phase{} = phase} =
             PhaseService.create(repo, %{
               id: "phase-p7",
               title: "Phase 7",
               description: "Delegated phase work"
             })

    assert phase.id == "phase-p7"
    assert phase.status == "active"
    assert phase.description == "Delegated phase work"

    assert {:ok, fetched} = PhaseService.get(repo, phase.id)
    assert fetched == phase
  end

  test "architect grant reads only its own phase board", %{repo: repo} do
    assert {:ok, own_phase} = PhaseService.create(repo, %{id: "phase-own", title: "Own phase"})
    assert {:ok, other_phase} = PhaseService.create(repo, %{id: "phase-other", title: "Other phase"})

    assert {:ok, own_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-P7-CHILD", kind: "phase_child", phase_id: own_phase.id, status: "planning")
             )

    assert {:ok, _other_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-P7-OTHER", kind: "phase_child", phase_id: other_phase.id, status: "planning")
             )

    assert {:ok, _standalone} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-STANDALONE", kind: "hotfix", parent_id: nil))

    assert {:ok, minted} = AccessGrantService.mint_architect_grant(repo, own_phase.id, work_package_id: own_child.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "architect-1")
    assert assignment.phase_id == own_phase.id
    assert assignment.work_package_id == own_child.id
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    own_response = read_phase_board(repo, session, own_phase.id)

    assert get_in(own_response, ["result", "structuredContent", "phase", "id"]) == own_phase.id
    assert get_in(own_response, ["result", "structuredContent", "total_count"]) == 1
    assert [%{"id" => child_id}] = get_in(own_response, ["result", "structuredContent", "groups", "planning"])
    assert child_id == own_child.id

    unrelated_response = read_phase_board(repo, session, other_phase.id)

    assert get_in(unrelated_response, ["error", "code"]) == -32_003
    assert get_in(unrelated_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "legacy null phase grant derives MCP scope only from its phased anchor", %{repo: repo} do
    assert {:ok, phase} = PhaseService.create(repo, %{id: "phase-legacy-anchor", title: "Legacy anchor"})
    assert {:ok, other_phase} = PhaseService.create(repo, %{id: "phase-legacy-anchor-other", title: "Legacy other"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-P7-LEGACY-ANCHOR", kind: "phase_child", phase_id: phase.id, status: "planning")
             )

    assert {:ok, sibling} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-P7-LEGACY-SIBLING", kind: "phase_child", phase_id: phase.id, status: "blocked")
             )

    assert {:ok, _other_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-P7-LEGACY-OTHER", kind: "phase_child", phase_id: other_phase.id, status: "planning")
             )

    session = legacy_phase_session(repo, anchor.id, "grant-p7-legacy-anchor")

    response = read_phase_board(repo, session, phase.id)
    anchor_id = anchor.id
    sibling_id = sibling.id

    assert get_in(response, ["result", "structuredContent", "phase", "id"]) == phase.id
    assert [%{"id" => ^anchor_id}] = get_in(response, ["result", "structuredContent", "groups", "planning"])
    assert [%{"id" => ^sibling_id}] = get_in(response, ["result", "structuredContent", "groups", "blocked"])

    unrelated_response = read_phase_board(repo, session, other_phase.id)

    assert get_in(unrelated_response, ["error", "code"]) == -32_003
    assert get_in(unrelated_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "explicit phase grant phase board filters to frozen repo and base branch", %{repo: repo} do
    assert {:ok, phase} = PhaseService.create(repo, %{id: "phase-board-scope", title: "Scoped board"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-BOARD-SCOPE-ANCHOR",
                 kind: "phase_child",
                 phase_id: phase.id,
                 repo: "nextide/symphony-plus-plus",
                 base_branch: "symphony-plus-plus/beta",
                 status: "planning"
               )
             )

    assert {:ok, in_scope_sibling} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-BOARD-SCOPE-SIBLING",
                 kind: "phase_child",
                 phase_id: phase.id,
                 repo: anchor.repo,
                 base_branch: anchor.base_branch,
                 status: "blocked"
               )
             )

    assert {:ok, other_repo} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-BOARD-OTHER-REPO",
                 kind: "phase_child",
                 phase_id: phase.id,
                 repo: "nextide/other",
                 base_branch: anchor.base_branch,
                 status: "planning"
               )
             )

    assert {:ok, other_base} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-P7-BOARD-OTHER-BASE",
                 kind: "phase_child",
                 phase_id: phase.id,
                 repo: anchor.repo,
                 base_branch: "main",
                 status: "planning"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_architect_grant(repo, phase.id, work_package_id: anchor.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "architect-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response = read_phase_board(repo, session, phase.id)
    encoded = Jason.encode!(get_in(response, ["result", "structuredContent"]))

    assert get_in(response, ["result", "structuredContent", "total_count"]) == 2
    assert encoded =~ anchor.id
    assert encoded =~ in_scope_sibling.id
    refute encoded =~ other_repo.id
    refute encoded =~ other_base.id

    PhaseBoardMaterializationRepo.block_materialization(other_repo.id)

    materialization_response =
      try do
        read_phase_board(PhaseBoardMaterializationRepo, session, phase.id)
      after
        PhaseBoardMaterializationRepo.clear_materialization_block()
      end

    assert get_in(materialization_response, ["result", "structuredContent", "total_count"]) == 2
  end

  test "explicit phase grant without frozen scope snapshot fails phase board closed", %{repo: repo} do
    assert {:ok, phase} = PhaseService.create(repo, %{id: "phase-board-missing-snapshot", title: "Missing board snapshot"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-P7-BOARD-MISSING-SNAPSHOT", kind: "phase_child", phase_id: phase.id)
             )

    assert {:ok, minted} = AccessGrantService.mint_architect_grant(repo, phase.id, work_package_id: anchor.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "architect-1")

    repo.query!(
      "UPDATE sympp_access_grants SET scope_repo = NULL, scope_base_branch = NULL WHERE id = ?",
      [assignment.grant_id]
    )

    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    response = read_phase_board(repo, session, phase.id)

    assert get_in(response, ["error", "code"]) == -32_003
    assert get_in(response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "legacy null phase grant with unphased anchor is denied MCP phase board", %{repo: repo} do
    assert {:ok, phase} = PhaseService.create(repo, %{id: "phase-legacy-unphased", title: "Legacy unphased"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-P7-LEGACY-UNPHASED", kind: "hotfix", parent_id: nil, phase_id: nil)
             )

    session = legacy_phase_session(repo, anchor.id, "grant-p7-legacy-unphased")
    response = read_phase_board(repo, session, phase.id)

    assert get_in(response, ["error", "code"]) == -32_003
    assert get_in(response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "architect grant is denied phase board after its anchor leaves the phase", %{repo: repo} do
    assert {:ok, phase} = PhaseService.create(repo, %{id: "phase-anchor-drift", title: "Anchor drift"})
    assert {:ok, other_phase} = PhaseService.create(repo, %{id: "phase-anchor-drift-other", title: "Other phase"})

    assert {:ok, anchor} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-P7-ANCHOR-DRIFT", kind: "phase_child", phase_id: phase.id, status: "planning")
             )

    assert {:ok, minted} = AccessGrantService.mint_architect_grant(repo, phase.id, work_package_id: anchor.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "architect-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    assert get_in(read_phase_board(repo, session, phase.id), ["result", "structuredContent", "phase", "id"]) == phase.id

    assert {:ok, _updated_anchor} = WorkPackageRepository.update(repo, anchor.id, %{phase_id: other_phase.id})

    drifted_response = read_phase_board(repo, session, phase.id)

    assert get_in(drifted_response, ["error", "code"]) == -32_003
    assert get_in(drifted_response, ["error", "data", "reason"]) == "outside_session_scope"

    other_phase_response = read_phase_board(repo, session, other_phase.id)

    assert get_in(other_phase_response, ["error", "code"]) == -32_003
    assert get_in(other_phase_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "worker grant is denied phase board access", %{repo: repo} do
    assert {:ok, phase} = PhaseService.create(repo, %{id: "phase-worker-denied", title: "Worker denied"})

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-P7-WORKER-DENIED", kind: "phase_child", phase_id: phase.id)
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response = read_phase_board(repo, session, phase.id)

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "architect_grant_required"
  end

  test "architect grant minting rejects anchor package outside phase", %{repo: repo} do
    assert {:ok, phase} = PhaseService.create(repo, %{id: "phase-anchor", title: "Anchor phase"})
    assert {:ok, other_phase} = PhaseService.create(repo, %{id: "phase-anchor-other", title: "Other anchor phase"})

    assert {:ok, other_child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-P7-ANCHOR-OTHER", kind: "phase_child", phase_id: other_phase.id)
             )

    assert {:error, :outside_phase_scope} =
             AccessGrantService.mint_architect_grant(repo, phase.id, work_package_id: other_child.id)
  end

  test "standalone packages do not require a phase and architect grants are not global board grants", %{repo: repo} do
    assert {:ok, phase} = PhaseService.create(repo, %{id: "phase-nonglobal", title: "Scoped phase"})

    assert {:ok, child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-P7-SCOPED", kind: "phase_child", phase_id: phase.id)
             )

    assert {:ok, standalone} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-HOTFIX-STANDALONE", kind: "hotfix", parent_id: nil))

    assert standalone.parent_id == nil

    assert {:ok, minted} = AccessGrantService.mint_architect_grant(repo, phase.id, work_package_id: child.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "architect-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    board_response = read_phase_board(repo, session, phase.id)
    encoded = Jason.encode!(get_in(board_response, ["result", "structuredContent"]))

    assert encoded =~ child.id
    refute encoded =~ standalone.id
  end

  test "phase board ignores generic parent ancestry that collides with a phase id", %{repo: repo} do
    assert {:ok, phase} = PhaseService.create(repo, %{id: "SYMPP-P7-COLLISION-PARENT", title: "Collision phase"})

    assert {:ok, child} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-P7-COLLISION-CHILD", kind: "phase_child", phase_id: phase.id, parent_id: "SYMPP-EPIC")
             )

    assert {:ok, unrelated} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-P7-COLLISION-UNRELATED", kind: "phase_child", parent_id: phase.id, phase_id: nil)
             )

    assert {:ok, minted} = AccessGrantService.mint_architect_grant(repo, phase.id, work_package_id: child.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "architect-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    board_response = read_phase_board(repo, session, phase.id)
    encoded = Jason.encode!(get_in(board_response, ["result", "structuredContent"]))

    assert encoded =~ child.id
    refute encoded =~ unrelated.id
  end

  defp read_phase_board(repo, session, phase_id) do
    MCPHarness.request(
      %{
        "jsonrpc" => "2.0",
        "id" => "read-phase-board",
        "method" => "tools/call",
        "params" => %{"name" => "read_phase_board", "arguments" => %{"phase_id" => phase_id}}
      },
      repo: repo,
      session: session
    )
  end

  defp legacy_phase_session(repo, work_package_id, grant_id) do
    now = DateTime.utc_now(:microsecond)
    work_key = WorkKey.generate()

    grant =
      repo.insert!(%AccessGrant{
        id: grant_id,
        work_package_id: work_package_id,
        phase_id: nil,
        display_key: work_key.display_key,
        secret_hash: WorkKey.secret_hash(work_key.secret),
        grant_role: "architect",
        capabilities: ["read:phase"],
        expires_at: DateTime.add(now, 3600, :second)
      })

    assert {:ok, assignment} = AccessGrantService.claim(repo, work_key.secret, claimed_by: "architect-legacy")
    assert assignment.phase_id == nil
    MCPHarness.session(assignment, proof_hash: grant.secret_hash)
  end
end
