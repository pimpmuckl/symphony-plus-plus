defmodule SymphonyElixir.SymphonyPlusPlus.AgentRunsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Service
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
    repo.delete_all(AgentRun)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "starts an AgentRun bound to its work package and claimed worker grant", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-CREATE", status: "ready_for_worker"))

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "agent-1")

    assert {:ok, %AgentRun{} = run} =
             Service.start_dispatch(repo, issue(work_package.id), attempt: 2, worker_host: "worker-a")

    assert run.work_package_id == work_package.id
    assert run.access_grant_id == assignment.grant_id
    assert run.actor_id == "agent-1"
    assert run.status == "running"
    assert run.attempt == 2
    assert run.worker_host == "worker-a"
    assert %DateTime{} = run.started_at
    assert %DateTime{} = run.last_seen_at
    assert run.finished_at == nil
  end

  test "binds AgentRun to the grant for the issue assignee when multiple worker grants are claimed", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-ASSIGNEE", status: "ready_for_worker"))

    assert {:ok, other_grant} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, _other_assignment} = AccessGrantService.claim(repo, other_grant.work_key.secret, claimed_by: "agent-2")

    assert {:ok, assigned_grant} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, assigned_grant.work_key.secret, claimed_by: "agent-1")

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))

    assert run.access_grant_id == assignment.grant_id
    assert run.actor_id == "agent-1"
  end

  test "heartbeat updates last seen and runtime binding fields", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-HEARTBEAT", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))

    assert {:ok, updated} =
             Service.heartbeat(repo, run.id, %{
               session_id: "thread-1-turn-1",
               workspace_path: "C:/tmp/workspace",
               worker_host: "worker-a"
             })

    assert updated.id == run.id
    assert updated.session_id == "thread-1-turn-1"
    assert updated.workspace_path == "C:/tmp/workspace"
    assert updated.worker_host == "worker-a"
    assert DateTime.compare(updated.last_seen_at, run.last_seen_at) in [:gt, :eq]
  end

  test "prevents duplicate active runs for the same work package", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-DUPLICATE", status: "ready_for_worker"))

    assert {:ok, first} = Service.start_dispatch(repo, issue(work_package.id))
    assert first.status == "running"

    assert {:error, :active_run_exists} = Service.start_dispatch(repo, issue(work_package.id), attempt: 1)
  end

  test "retry and stop reconciliation update AgentRun status", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-RETRY-STOP", status: "ready_for_worker"))

    assert {:ok, run} = Service.start_dispatch(repo, issue(work_package.id))

    assert {:ok, retrying} = Service.mark_retrying(repo, run.id, "worker exited")
    assert retrying.status == "retrying"
    assert retrying.reason == "worker exited"
    assert retrying.finished_at == nil

    assert {:ok, stopped} = Service.mark_stopped(repo, run.id, "package left active state")
    assert stopped.status == "stopped"
    assert stopped.reason == "package left active state"
    assert %DateTime{} = stopped.finished_at
  end

  test "failed start does not orphan an active AgentRun", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-RUN-FAILED-START", status: "ready_for_worker"))

    assert {:ok, failed_run} = Service.start_dispatch(repo, issue(work_package.id))
    assert {:ok, failed_run} = Service.mark_failed(repo, failed_run.id, "failed to spawn agent")
    assert failed_run.status == "failed"

    assert {:ok, replacement} = Service.start_dispatch(repo, issue(work_package.id), attempt: 1)
    assert replacement.id != failed_run.id
    assert replacement.status == "running"
    assert replacement.attempt == 1
  end

  defp issue(id) do
    %Issue{
      id: id,
      identifier: id,
      title: "Run package",
      description: "Dispatch package",
      state: "ready_for_worker",
      assignee_id: "agent-1",
      assigned_to_worker: true
    }
  end
end
