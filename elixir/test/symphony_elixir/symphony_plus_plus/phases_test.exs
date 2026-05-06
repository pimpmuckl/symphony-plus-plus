Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.PhasesTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Service, as: PhaseService
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

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
end
