Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestTools03Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "mark WorkRequest sliced MCP tool preserves approved-slice requirement", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-GUARD", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-GUARD",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    response =
      mcp_tool(repo, session, "mark_work_request_sliced", %{
        "work_request_id" => work_request.id,
        "current_status" => "ready_for_slicing"
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "no_approved_slices"

    assert {:ok, persisted_work_request} = WorkRequestRepository.get(repo, work_request.id)
    assert persisted_work_request.status == "ready_for_slicing"
  end

  test "WorkRequest MCP planned-slice mutations require slice authoring status", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-STATUS", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-STATUS",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "draft"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    add_args = %{
      "work_request_id" => work_request.id,
      "title" => "Draft-state slice",
      "goal" => "Should wait until slicing is open.",
      "work_package_kind" => "mcp",
      "target_base_branch" => anchor.base_branch,
      "owned_file_globs" => ["elixir/lib/**"],
      "forbidden_file_globs" => [],
      "acceptance_criteria" => ["WorkRequest is sliceable."],
      "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
      "review_lanes" => ["normal"],
      "stop_conditions" => ["Stop before dispatch."]
    }

    add_response = mcp_tool(repo, session, "add_work_request_planned_slice", add_args)
    assert get_in(add_response, ["error", "code"]) == -32_602
    assert get_in(add_response, ["error", "data", "reason"]) == "invalid_status"
    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, Map.delete(add_args, "work_request_id"))

    for tool <- ["approve_work_request_planned_slice", "skip_work_request_planned_slice"] do
      response =
        mcp_tool(repo, session, tool, %{
          "work_request_id" => work_request.id,
          "planned_slice_id" => planned_slice.id,
          "current_status" => "planned"
        })

      assert get_in(response, ["error", "code"]) == -32_602
      assert get_in(response, ["error", "data", "reason"]) == "invalid_status"
    end

    assert {:ok, [persisted_slice]} = WorkRequestRepository.list_planned_slices(repo, work_request.id)
    assert persisted_slice.status == "planned"
  end

  test "WorkRequest MCP planned-slice writes honor planned-slice scope without parent WorkRequest scope", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-EXPLICIT", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-EXPLICIT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-SLICE-EXPLICIT",
                 target_base_branch: anchor.base_branch
               )
             )

    grant_planned_slice_scope!(repo, session, planned_slice.id)
    remove_grant_scope_type!(repo, session, "repo")

    response =
      mcp_tool(repo, session, "approve_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "current_status" => "planned"
      })

    assert get_in(response, ["result", "structuredContent", "planned_slice", "status"]) == "approved"
    assert get_in(response, ["result", "structuredContent", "work_request", "id"]) == work_request.id
    text = assert_toon_tool_text!(response)
    assert text =~ "planned_slice:"
    assert text =~ "planned_slice_status: approved"

    assert {:ok, persisted_slice} = WorkRequestRepository.get_planned_slice(repo, work_request.id, planned_slice.id)
    assert persisted_slice.status == "approved"
  end

  test "WorkRequest MCP mutations require write capability and explicit live phase scope", %{repo: repo} do
    {read_anchor, read_session, _read_grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-READONLY", [
        "read:work_request"
      ])

    read_only_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-READONLY",
        repo: read_anchor.repo,
        base_branch: read_anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, read_only_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               read_only_work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-MUTATE-READONLY",
                 target_base_branch: read_anchor.base_branch
               )
             )

    read_only_response =
      mcp_tool(repo, read_session, "ask_work_request_question", %{
        "work_request_id" => read_only_work_request.id,
        "category" => "scope",
        "question" => "Question?",
        "why_needed" => "Capability check."
      })

    assert get_in(read_only_response, ["error", "code"]) == -32_003
    assert get_in(read_only_response, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(read_only_response, ["error", "data", "reason_code"]) == "insufficient_capability"

    read_only_slice_response =
      mcp_tool(repo, read_session, "add_work_request_planned_slice", %{
        "work_request_id" => read_only_work_request.id,
        "title" => "Denied slice",
        "goal" => "Capability check.",
        "work_package_kind" => "mcp",
        "target_base_branch" => read_anchor.base_branch,
        "owned_file_globs" => [],
        "forbidden_file_globs" => [],
        "acceptance_criteria" => [],
        "validation_steps" => [],
        "review_lanes" => [],
        "stop_conditions" => []
      })

    assert get_in(read_only_slice_response, ["error", "code"]) == -32_003
    assert get_in(read_only_slice_response, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(read_only_slice_response, ["error", "data", "reason_code"]) == "insufficient_capability"

    read_only_dispatch_response =
      mcp_tool(repo, read_session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => read_only_work_request.id,
        "planned_slice_id" => read_only_slice.id,
        "claimed_by" => "worker-1"
      })

    assert get_in(read_only_dispatch_response, ["error", "code"]) == -32_003
    assert get_in(read_only_dispatch_response, ["error", "data", "reason"]) == "insufficient_capability"
    assert get_in(read_only_dispatch_response, ["error", "data", "reason_code"]) == "insufficient_capability"

    read_only_prepare_response =
      mcp_tool(repo, read_session, "prepare_work_package_worktree", %{
        "work_package_id" => "wp-missing"
      })

    assert get_in(read_only_prepare_response, ["error", "code"]) == -32_001
    assert get_in(read_only_prepare_response, ["error", "data", "reason"]) == "insufficient_capability"

    read_only_tools =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "read-only-tools", "method" => "tools/list", "params" => %{}},
        repo: repo,
        session: read_session
      )
      |> get_in(["result", "tools"])
      |> Map.new(&{&1["name"], &1})

    for tool <- @architect_tool_names do
      assert Map.has_key?(read_only_tools, tool)
    end

    assert {:ok, legacy_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-ARCHITECT-WR-MUTATE-LEGACY", kind: "mcp"))

    assert {:error, %Ecto.Changeset{} = legacy_changeset} =
             create_architect_work_key(repo, legacy_package.id, ["write:work_request"])

    assert {"architect phase-scoped grants require phase scope", []} in Keyword.get_values(legacy_changeset.errors, :phase_id)

    {drift_anchor, drift_session, _drift_grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-DRIFT", [
        "write:work_request",
        "dispatch:work_request"
      ])

    drift_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-DRIFT",
        repo: drift_anchor.repo,
        base_branch: drift_anchor.base_branch,
        status: "draft"
      )

    grant_work_request_scope!(repo, drift_session, drift_work_request.id)

    assert {:ok, drift_planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               drift_work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-MUTATE-DRIFT",
                 target_base_branch: drift_anchor.base_branch
               )
             )

    assert {:ok, _drifted_anchor} = WorkPackageRepository.update(repo, drift_anchor.id, %{repo: "nextide/other"})

    drift_response =
      mcp_tool(repo, drift_session, "set_work_request_status", %{
        "work_request_id" => drift_work_request.id,
        "current_status" => "draft",
        "next_status" => "ready_for_clarification"
      })

    assert get_in(drift_response, ["error", "code"]) == -32_003
    assert get_in(drift_response, ["error", "data", "reason"]) == "outside_session_scope"

    drift_slice_response =
      mcp_tool(repo, drift_session, "mark_work_request_sliced", %{
        "work_request_id" => drift_work_request.id,
        "current_status" => "ready_for_slicing"
      })

    assert get_in(drift_slice_response, ["error", "code"]) == -32_003
    assert get_in(drift_slice_response, ["error", "data", "reason"]) == "outside_session_scope"

    drift_dispatch_response =
      mcp_tool(repo, drift_session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => drift_work_request.id,
        "planned_slice_id" => drift_planned_slice.id,
        "claimed_by" => "worker-1"
      })

    assert get_in(drift_dispatch_response, ["error", "code"]) == -32_003
    assert get_in(drift_dispatch_response, ["error", "data", "reason"]) == "outside_session_scope"

    {revoked_anchor, revoked_session, revoked_grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-REVOKED", [
        "write:work_request",
        "dispatch:work_request"
      ])

    revoked_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-REVOKED",
        repo: revoked_anchor.repo,
        base_branch: revoked_anchor.base_branch,
        status: "draft"
      )

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, revoked_grant.id)

    revoked_response =
      mcp_tool(repo, revoked_session, "set_work_request_status", %{
        "work_request_id" => revoked_work_request.id,
        "current_status" => "draft",
        "next_status" => "ready_for_clarification"
      })

    assert get_in(revoked_response, ["error", "code"]) == -32_001
    assert get_in(revoked_response, ["error", "data", "reason"]) == "revoked"

    revoked_slice_response =
      mcp_tool(repo, revoked_session, "mark_work_request_sliced", %{
        "work_request_id" => revoked_work_request.id,
        "current_status" => "ready_for_slicing"
      })

    assert get_in(revoked_slice_response, ["error", "code"]) == -32_001
    assert get_in(revoked_slice_response, ["error", "data", "reason"]) == "revoked"

    revoked_dispatch_response =
      mcp_tool(repo, revoked_session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => revoked_work_request.id,
        "planned_slice_id" => "WRS-MCP-WR-MUTATE-REVOKED",
        "claimed_by" => "worker-1"
      })

    assert get_in(revoked_dispatch_response, ["error", "code"]) == -32_001
    assert get_in(revoked_dispatch_response, ["error", "data", "reason"]) == "revoked"

    assert {:ok, worker_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-WR-MUTATE-WORKER", kind: "mcp"))
    assert {:ok, worker_minted} = AccessGrantService.mint_worker_grant(repo, worker_package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, worker_minted.work_key.secret, claimed_by: "worker-1")
    worker_session = MCPHarness.session(worker_assignment, proof_hash: worker_minted.grant.secret_hash)

    worker_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-WORKER",
        repo: "nextide/symphony-plus-plus",
        base_branch: "symphony-plus-plus/beta",
        status: "ready_for_slicing"
      )

    assert {:ok, worker_planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               worker_work_request.id,
               work_request_planned_slice_attrs(
                 id: "WRS-MCP-WR-MUTATE-WORKER",
                 target_base_branch: "symphony-plus-plus/beta"
               )
             )

    worker_response =
      mcp_tool(repo, worker_session, "set_work_request_status", %{
        "work_request_id" => worker_work_request.id,
        "current_status" => "draft",
        "next_status" => "ready_for_clarification"
      })

    assert get_in(worker_response, ["error", "code"]) == -32_003
    assert get_in(worker_response, ["error", "data", "reason_code"]) == "insufficient_role"

    worker_slice_response =
      mcp_tool(repo, worker_session, "mark_work_request_sliced", %{
        "work_request_id" => worker_work_request.id,
        "current_status" => "ready_for_slicing"
      })

    assert get_in(worker_slice_response, ["error", "code"]) == -32_003
    assert get_in(worker_slice_response, ["error", "data", "reason_code"]) == "insufficient_role"

    worker_dispatch_response =
      mcp_tool(repo, worker_session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => worker_work_request.id,
        "planned_slice_id" => worker_planned_slice.id,
        "claimed_by" => "worker-1"
      })

    assert get_in(worker_dispatch_response, ["error", "code"]) == -32_003
    assert get_in(worker_dispatch_response, ["error", "data", "reason_code"]) == "insufficient_role"

    anonymous_response =
      mcp_tool(repo, nil, "set_work_request_status", %{
        "work_request_id" => "WR-MCP-WR-MISSING",
        "current_status" => "draft",
        "next_status" => "ready_for_clarification"
      })

    assert get_in(anonymous_response, ["error", "code"]) == -32_001
    assert get_in(anonymous_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(anonymous_response, ["error", "data", "action"]) == "claim_local_architect_assignment"

    anonymous_slice_response =
      mcp_tool(repo, nil, "mark_work_request_sliced", %{
        "work_request_id" => "WR-MCP-WR-MISSING",
        "current_status" => "ready_for_slicing"
      })

    assert get_in(anonymous_slice_response, ["error", "code"]) == -32_001
    assert get_in(anonymous_slice_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(anonymous_slice_response, ["error", "data", "action"]) == "claim_local_architect_assignment"

    anonymous_dispatch_response =
      mcp_tool(repo, nil, "dispatch_work_request_planned_slice", %{
        "work_request_id" => "WR-MCP-WR-MISSING",
        "planned_slice_id" => "WRS-MCP-WR-MISSING",
        "claimed_by" => "worker-1"
      })

    assert get_in(anonymous_dispatch_response, ["error", "code"]) == -32_001
    assert get_in(anonymous_dispatch_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(anonymous_dispatch_response, ["error", "data", "action"]) == "claim_local_architect_assignment"
  end

  test "WorkRequest MCP question mutations fail closed for sibling question ids", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-SIBLING-QUESTION", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-QUESTION-OWNER",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "clarifying"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-QUESTION-SIBLING",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "clarifying"
      )

    assert {:ok, sibling_question} =
             WorkRequestRepository.ask_question(
               repo,
               sibling.id,
               work_request_question_attrs(id: "WRQ-MCP-WR-SIBLING-QUESTION")
             )

    answer_response =
      mcp_tool(repo, session, "answer_work_request_question", %{
        "work_request_id" => work_request.id,
        "question_id" => sibling_question.id,
        "current_status" => "open",
        "answer" => "Do not answer a sibling question.",
        "answered_by" => "architect-1"
      })

    assert get_in(answer_response, ["error", "code"]) == -32_004
    assert get_in(answer_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(answer_response) =~ sibling.id

    close_response =
      mcp_tool(repo, session, "close_work_request_question", %{
        "work_request_id" => work_request.id,
        "question_id" => sibling_question.id,
        "current_status" => "open"
      })

    assert get_in(close_response, ["error", "code"]) == -32_004
    assert get_in(close_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(close_response) =~ sibling.id

    assert {:ok, [persisted_sibling_question]} = WorkRequestRepository.list_questions(repo, sibling.id)
    assert persisted_sibling_question.status == "open"
    assert persisted_sibling_question.answer == nil
  end

  test "WorkRequest MCP planned-slice status mutations fail closed for sibling slice ids", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE-SIBLING-SLICE", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-SLICE-OWNER",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE-SLICE-SIBLING",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, sibling_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               sibling.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-WR-SIBLING-SLICE")
             )

    approve_response =
      mcp_tool(repo, session, "approve_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => sibling_slice.id,
        "current_status" => "planned"
      })

    assert get_in(approve_response, ["error", "code"]) == -32_004
    assert get_in(approve_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(approve_response) =~ sibling.id

    skip_response =
      mcp_tool(repo, session, "skip_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => sibling_slice.id,
        "current_status" => "planned"
      })

    assert get_in(skip_response, ["error", "code"]) == -32_004
    assert get_in(skip_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(skip_response) =~ sibling.id

    assert {:ok, [persisted_sibling_slice]} = WorkRequestRepository.list_planned_slices(repo, sibling.id)
    assert persisted_sibling_slice.status == "planned"
    assert persisted_sibling_slice.work_package_id == nil
  end
end
