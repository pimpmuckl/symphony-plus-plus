Code.require_file("../../support/mcp_harness.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCPDeliveryToolsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.MCPHarness
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
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
    for schema <- [ProgressEvent, PlannedSliceDelivery, PlannedSlice, AccessGrant, WorkRequest, WorkPackage, Phase] do
      repo.delete_all(schema)
    end

    :ok
  end

  test "WR architect reads delivery board and records idempotent closeout without child-status capability", %{repo: repo} do
    {work_request, planned_slice, linked_package} = linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-READ-CLOSE")
    session = create_work_request_architect_session(repo, work_request, ["read:work_request", "write:work_request"])

    read_child_response = mcp_tool(repo, session, "read_child_status", %{"work_package_id" => linked_package.id})
    assert get_in(read_child_response, ["error", "data", "reason"]) == "insufficient_capability"

    board_response = mcp_tool(repo, session, "read_work_request_delivery_board", %{"work_request_id" => work_request.id})
    board_payload = get_in(board_response, ["result", "structuredContent"])
    assert get_in(board_payload, ["delivery_board", "slices", Access.at(0), "work_package", "id"]) == linked_package.id

    evidence_url = "https://example.invalid/delivery?token=placeholder"
    evidence_query_value = "placeholder"

    closeout_args = no_pr_args(work_request, planned_slice, "delivery-mcp-no-pr", "Operator confirmed #{evidence_url} completed without a PR.")

    closeout_response = record_delivery(repo, session, closeout_args)
    closeout_payload = get_in(closeout_response, ["result", "structuredContent"])

    assert closeout_payload["planned_slice_delivery"]["outcome"] == "completed_no_pr"
    assert closeout_payload["planned_slice_delivery"]["no_pr_evidence"] =~ "[REDACTED]"
    refute closeout_payload["planned_slice_delivery"]["no_pr_evidence"] =~ evidence_query_value
    assert get_in(closeout_payload, ["delivery_board", "counts", "completed_no_pr"]) == 1
    assert get_in(closeout_payload, ["delivery_board", "slices", Access.at(0), "operational_state", "key"]) == "completed_no_pr"
    delivery_evidence_path = ["delivery_board", "slices", Access.at(0), "delivery", "no_pr_evidence"]
    assert get_in(closeout_payload, delivery_evidence_path) =~ "[REDACTED]"
    refute get_in(closeout_payload, delivery_evidence_path) =~ evidence_query_value
    assert repo.get!(WorkPackage, linked_package.id).status == "closed"

    replay_response = record_delivery(repo, session, closeout_args)

    assert get_in(replay_response, ["result", "structuredContent", "planned_slice_delivery", "id"]) ==
             closeout_payload["planned_slice_delivery"]["id"]

    read_after_closeout = mcp_tool(repo, session, "read_work_request_delivery_board", %{"work_request_id" => work_request.id})
    refute get_in(read_after_closeout, ["result", "structuredContent" | delivery_evidence_path]) =~ evidence_query_value

    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 1
  end

  test "WR architect can revoke a completed planned-slice worker grant before closeout", %{repo: repo} do
    {work_request, planned_slice, linked_package} =
      linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-GRANT-CLOSEOUT", work_package_status: "ready_for_human_merge")

    session = create_work_request_architect_session(repo, work_request, ["write:work_request"])

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)
    assert {:ok, _assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    assert {:ok, _closed_package} = WorkPackageRepository.update(repo, linked_package.id, %{status: "closed"})

    closeout_args = no_pr_args(work_request, planned_slice, "delivery-mcp-after-revoke", "Worker reported completion; architect is closing the stale grant first.")

    active_response = record_delivery(repo, session, closeout_args)
    assert get_in(active_response, ["error", "data", "reason"]) == "active_runtime"

    revoke_response =
      revoke_worker_key(
        repo,
        session,
        revoke_args(work_request, planned_slice, minted.grant.id, "Worker is complete and delivery closeout needs the active runtime guard cleared.")
      )

    revoke_payload = get_in(revoke_response, ["result", "structuredContent"])
    assert revoke_payload["work_package"]["id"] == linked_package.id
    assert revoke_payload["revoked_worker_grant"]["id"] == minted.grant.id
    assert revoke_payload["revoked_worker_grant"]["secret_in_response"] == false
    assert repo.get!(AccessGrant, minted.grant.id).revoked_at

    closeout_response = record_delivery(repo, session, closeout_args)

    assert get_in(closeout_response, ["result", "structuredContent", "planned_slice_delivery", "outcome"]) == "completed_no_pr"
    assert repo.get!(WorkPackage, linked_package.id).status == "closed"
  end

  test "workers and out-of-scope WR architects cannot record or revoke delivery", %{repo: repo} do
    {work_request, planned_slice, linked_package} = linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-SCOPED")
    worker_session = create_worker_session(repo, linked_package)

    args = no_pr_args(work_request, planned_slice, "delivery-mcp-denied", "Denied closeout should not be recorded.")

    worker_response = record_delivery(repo, worker_session, args)
    assert get_in(worker_response, ["error", "data", "reason"]) == "architect_grant_required"

    worker_revoke_response =
      revoke_worker_key(repo, worker_session, revoke_args(work_request, planned_slice, "grant-denied", "Denied"))

    assert get_in(worker_revoke_response, ["error", "data", "reason"]) == "architect_grant_required"

    sibling_request = sibling_work_request!(repo, work_request, "WR-MCP-DELIVERY-SIBLING")

    sibling_session = create_work_request_architect_session(repo, sibling_request, ["write:work_request"])

    sibling_response = record_delivery(repo, sibling_session, args)
    assert get_in(sibling_response, ["error", "code"]) == -32_004
    assert get_in(sibling_response, ["error", "data", "reason"]) == "not_found"

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, linked_package.id)

    sibling_revoke_response =
      revoke_worker_key(repo, sibling_session, revoke_args(work_request, planned_slice, minted.grant.id, "Denied"))

    assert get_in(sibling_revoke_response, ["error", "code"]) == -32_004
    assert get_in(sibling_revoke_response, ["error", "data", "reason"]) == "not_found"
    refute repo.get!(AccessGrant, minted.grant.id).revoked_at

    assert repo.aggregate(PlannedSliceDelivery, :count, :id) == 0
  end

  test "delivery closeout refuses out-of-scope or mismatched successors", %{repo: repo} do
    {work_request, planned_slice, _linked_package} = linked_slice!(repo, work_request_id: "WR-MCP-DELIVERY-SUCCESSOR-SCOPE")
    successor_slice = create_planned_slice!(repo, work_request, id: "WRS-MCP-DELIVERY-SUCCESSOR")
    session = create_work_request_architect_session(repo, work_request, ["write:work_request"])

    assert {:ok, approved_successor} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, successor_slice.id, "planned")
    successor_package = create_matching_work_package!(repo, work_request, approved_successor, id: "WP-MCP-DELIVERY-SUCCESSOR", status: "reviewing")
    assert {:ok, successor_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_successor.id, "approved", successor_package.id)

    sibling_request = sibling_work_request!(repo, work_request, "WR-MCP-DELIVERY-SUCCESSOR-SIBLING")

    sibling_successor_slice = create_planned_slice!(repo, sibling_request, id: "WRS-MCP-DELIVERY-SUCCESSOR-SIBLING")

    sibling_response =
      record_delivery(
        repo,
        session,
        superseded_args(work_request, planned_slice, "delivery-mcp-successor-slice-out-of-scope", sibling_successor_slice.id, "Recut to a sibling request.")
      )

    assert get_in(sibling_response, ["error", "data", "reason"]) == "successor_planned_slice_out_of_scope"

    other_successor_slice = create_planned_slice!(repo, work_request, id: "WRS-MCP-DELIVERY-SUCCESSOR-OTHER")
    assert {:ok, approved_other_successor} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, other_successor_slice.id, "planned")

    other_successor_package =
      create_matching_work_package!(repo, work_request, approved_other_successor, id: "WP-MCP-DELIVERY-SUCCESSOR-OTHER", status: "reviewing")

    assert {:ok, _dispatched_other_successor} =
             WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_other_successor.id, "approved", other_successor_package.id)

    response =
      record_delivery(
        repo,
        session,
        superseded_args(
          work_request,
          planned_slice,
          "delivery-mcp-successor-out-of-scope",
          successor_slice.id,
          "Recut to a narrower package.",
          other_successor_package.id
        )
      )

    assert get_in(response, ["error", "data", "reason"]) == "successor_work_package_slice_mismatch"

    success_response =
      record_delivery(
        repo,
        session,
        superseded_args(
          work_request,
          planned_slice,
          "delivery-mcp-successor-visible",
          successor_slice.id,
          "Recut to a narrower package.",
          successor_package.id
        )
      )

    assert get_in(success_response, ["result", "structuredContent", "delivery_board", "slices", Access.at(0), "successor", "work_package", "id"]) ==
             successor_package.id
  end

  defp linked_slice!(repo, overrides) do
    request_id = Keyword.fetch!(overrides, :work_request_id)
    work_package_status = Keyword.get(overrides, :work_package_status, "reviewing")
    work_request = create_work_request!(repo, id: request_id, status: "ready_for_slicing")
    planned_slice = create_planned_slice!(repo, work_request, id: "WRS-#{request_id}")
    assert {:ok, approved_slice} = WorkRequestRepository.approve_planned_slice(repo, work_request.id, planned_slice.id, "planned")

    linked_package =
      create_matching_work_package!(repo, work_request, approved_slice,
        id: "WP-#{request_id}",
        status: work_package_status
      )

    assert {:ok, dispatched_slice} = WorkRequestRepository.dispatch_planned_slice(repo, work_request.id, approved_slice.id, "approved", linked_package.id)

    {work_request, dispatched_slice, linked_package}
  end

  defp create_work_request!(repo, overrides) do
    assert {:ok, work_request} = WorkRequestRepository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp sibling_work_request!(repo, work_request, id) do
    create_work_request!(repo, id: id, repo: work_request.repo, base_branch: work_request.base_branch, status: "ready_for_slicing")
  end

  defp create_planned_slice!(repo, work_request, overrides) do
    assert {:ok, planned_slice} = WorkRequestRepository.add_planned_slice(repo, work_request.id, planned_slice_attrs(overrides))
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

  defp create_work_request_architect_session(repo, %WorkRequest{} = work_request, capabilities) do
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
               capabilities: capabilities
             )

    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "architect-1")

    MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
  end

  defp create_worker_session(repo, %WorkPackage{} = work_package) do
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
  end

  defp no_pr_args(work_request, planned_slice, idempotency_key, evidence) do
    %{
      "work_request_id" => work_request.id,
      "planned_slice_id" => planned_slice.id,
      "outcome" => "completed_no_pr",
      "idempotency_key" => idempotency_key,
      "no_pr_evidence" => evidence
    }
  end

  defp revoke_args(work_request, planned_slice, grant_id, reason) do
    %{
      "work_request_id" => work_request.id,
      "planned_slice_id" => planned_slice.id,
      "grant_id" => grant_id,
      "reason" => reason
    }
  end

  defp superseded_args(work_request, planned_slice, idempotency_key, successor_planned_slice_id, reason, successor_work_package_id \\ nil) do
    %{
      "work_request_id" => work_request.id,
      "planned_slice_id" => planned_slice.id,
      "outcome" => "superseded",
      "idempotency_key" => idempotency_key,
      "superseded_reason" => reason,
      "successor_planned_slice_id" => successor_planned_slice_id
    }
    |> optional_arg("successor_work_package_id", successor_work_package_id)
  end

  defp optional_arg(attrs, _key, nil), do: attrs
  defp optional_arg(attrs, key, value), do: Map.put(attrs, key, value)

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-MCP-DELIVERY-#{System.unique_integer([:positive])}",
      title: "Expose delivery MCP tools",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Expose delivery-board and closeout through MCP.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "architect_led_feature_branch"
    }

    Enum.into(overrides, defaults)
  end

  defp planned_slice_attrs(overrides) do
    defaults = %{
      id: "WRS-MCP-DELIVERY-#{System.unique_integer([:positive])}",
      title: "Delivery MCP slice",
      goal: "Close delivered planned slices through MCP.",
      work_package_kind: "mcp",
      target_base_branch: "main",
      branch_pattern: "feat/mcp-delivery",
      owned_file_globs: ["elixir/lib/symphony_elixir/symphony_plus_plus/work_requests/**"],
      forbidden_file_globs: ["elixir/assets/**"],
      acceptance_criteria: ["Delivery MCP tools are scoped."],
      validation_steps: ["mix test test/symphony_elixir/symphony_plus_plus/mcp_delivery_tools_test.exs"],
      review_lanes: ["normal"],
      stop_conditions: ["Do not expose broad package visibility."]
    }

    Enum.into(overrides, defaults)
  end

  defp record_delivery(repo, session, arguments), do: mcp_tool(repo, session, "record_planned_slice_delivery", arguments)
  defp revoke_worker_key(repo, session, arguments), do: mcp_tool(repo, session, "revoke_planned_slice_worker_key", arguments)

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
