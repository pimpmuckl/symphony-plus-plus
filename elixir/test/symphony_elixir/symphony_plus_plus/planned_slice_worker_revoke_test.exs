Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.PlannedSliceWorkerRevokeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.GrantScope
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, Session}
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{ArchitectHandoff, PlannedSlice, PlannedSliceDelivery, WorkRequest}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.WorkPackageFactory

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = WorkPackageRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    schemas =
      [
        ProgressEvent,
        PlannedSliceDelivery,
        PlannedSlice,
        ClaimLease,
        GrantScope,
        AccessGrant,
        WorkRequest,
        WorkPackage,
        Phase
      ]

    for schema <- schemas do
      repo.delete_all(schema)
    end

    :ok
  end

  test "architect recycles in-progress planned-slice worker authority before superseded closeout", %{repo: repo} do
    {work_request, planned_slice, linked_package} = linked_slice!(repo, "implementing")
    successor_slice = create_planned_slice!(repo, work_request, "WRS-MCP-DELIVERY-IN-PROGRESS-SUCCESSOR")
    session = create_work_request_architect_session(repo, work_request)

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "active-worker")

    closeout_args = superseded_args(work_request, planned_slice, successor_slice.id)

    active_response = mcp_tool(repo, session, "record_planned_slice_delivery", closeout_args)
    assert get_in(active_response, ["error", "data", "reason"]) == "active_runtime"

    revoke_response =
      mcp_tool(repo, session, "revoke_planned_slice_worker_key", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "grant_id" => minted.grant.id,
        "reason" => "Worker is being recut and the old runtime authority must be recycled."
      })

    revoke_payload = get_in(revoke_response, ["result", "structuredContent"])
    assert revoke_payload["work_package"]["id"] == linked_package.id
    assert revoke_payload["work_package"]["status"] == "blocked"
    assert revoke_payload["revoked_worker_grant"]["id"] == minted.grant.id

    assert revoke_payload["closeout_affordance"]["reason_codes"] == [
             "worker_recycled",
             "planned_slice_worker_key_revoked",
             "work_package_blocked_for_recycle"
           ]

    assert revoke_payload["closeout_affordance"]["previous_work_package_status"] == "implementing"
    assert revoke_payload["closeout_affordance"]["work_package_status"] == "blocked"
    assert get_in(revoke_payload, ["revocation_event", "payload", "previous_work_package_status"]) == "implementing"
    assert get_in(revoke_payload, ["revocation_event", "payload", "work_package_status"]) == "blocked"
    assert repo.get!(AccessGrant, minted.grant.id).revoked_at
    assert repo.get!(WorkPackage, linked_package.id).status == "blocked"

    closeout_response = mcp_tool(repo, session, "record_planned_slice_delivery", closeout_args)

    assert get_in(closeout_response, ["result", "structuredContent", "planned_slice_delivery", "outcome"]) == "superseded"
    assert repo.get!(WorkPackage, linked_package.id).status == "closed"
  end

  defp linked_slice!(repo, status) do
    work_request = create_work_request!(repo)
    planned_slice = create_planned_slice!(repo, work_request, "WRS-MCP-DELIVERY-IN-PROGRESS-RECYCLE")
    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    linked_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "WP-MCP-DELIVERY-IN-PROGRESS-RECYCLE",
        status: status
      )

    assert {:ok, dispatched_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", linked_package.id)

    {work_request, dispatched_slice, linked_package}
  end

  defp create_work_request!(repo) do
    attrs = %{
      id: "WR-MCP-DELIVERY-IN-PROGRESS-RECYCLE",
      title: "Recycle planned-slice workers",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Recycle runtime authority before superseded closeout.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "architect_led_feature_branch",
      status: "ready_for_slicing"
    }

    assert {:ok, work_request} = WorkRequestRepository.create(repo, attrs)
    work_request
  end

  defp create_planned_slice!(repo, work_request, id) do
    attrs = %{
      id: id,
      title: "Delivery MCP slice",
      goal: "Close delivered planned slices through MCP.",
      work_package_kind: "mcp",
      target_base_branch: "main",
      branch_pattern: "feat/mcp-delivery",
      owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery MCP tools are scoped."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/planned_slice_worker_revoke_test.exs"],
      review_lanes: ["normal"],
      stop_conditions: ["Do not expose broad package visibility."]
    }

    assert {:ok, planned_slice} = WorkRequestRepository.add_planned_slice(repo, work_request.id, attrs)
    planned_slice
  end

  defp create_matching_work_package!(repo, work_request, planned_slice, overrides) do
    attrs =
      [
        kind: planned_slice.work_package_kind,
        title: planned_slice.title,
        repo: work_request.repo,
        base_branch: planned_slice.target_base_branch,
        branch_pattern: planned_slice.branch_pattern,
        product_description: work_request.human_description,
        allowed_file_globs: planned_slice.owned_file_globs,
        acceptance_criteria: planned_slice.acceptance_criteria
      ]
      |> Keyword.merge(overrides)
      |> WorkPackageFactory.attrs()

    assert {:ok, work_package} = WorkPackageRepository.create(repo, attrs)
    work_package
  end

  defp create_work_request_architect_session(repo, %WorkRequest{} = work_request) do
    phase_id = ArchitectHandoff.phase_id_for_work_request(work_request)

    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Architect handoff for #{work_request.id}"})

    anchor_attrs =
      [
        id: ArchitectHandoff.anchor_id_for_work_request(work_request),
        kind: "delegation",
        title: "Architect handoff: #{work_request.title}",
        repo: work_request.repo,
        base_branch: work_request.base_branch,
        phase_id: phase_id,
        status: "planning",
        allowed_file_globs: ["elixir/lib", "elixir/lib/**"],
        acceptance_criteria: ["Own the WorkRequest architecture."]
      ]
      |> WorkPackageFactory.attrs()

    assert {:ok, anchor} = WorkPackageRepository.create(repo, anchor_attrs)

    assert {:ok, minted} =
             AccessGrantService.mint_architect_grant(repo, phase_id,
               work_package_id: anchor.id,
               capabilities: ["write:work_request"]
             )

    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "architect-1")

    MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
  end

  defp superseded_args(work_request, planned_slice, successor_planned_slice_id) do
    %{
      "work_request_id" => work_request.id,
      "planned_slice_id" => planned_slice.id,
      "outcome" => "superseded",
      "idempotency_key" => "delivery-mcp-in-progress-recut-after-recycle",
      "superseded_reason" => "Recut after the old worker authority was explicitly recycled.",
      "successor_planned_slice_id" => successor_planned_slice_id
    }
  end

  defp mcp_tool(repo, %Session{} = session, name, arguments) do
    MCPHarness.request(
      %{
        "jsonrpc" => "2.0",
        "id" => name,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      },
      config: Config.default(repo: repo, repo_root: test_repo_root()),
      session: session
    )
  end

  defp test_repo_root do
    Path.expand("../../../..", __DIR__)
  end
end
