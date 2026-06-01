Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkRequestTools02Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "WorkRequest MCP read tools for handoff phases include same repo/base siblings", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-SIBLING",
        repo: handoff_work_request.repo,
        base_branch: handoff_work_request.base_branch,
        status: "ready_for_slicing"
      )

    _other_repo =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-OTHER-REPO",
        repo: "nextide/other",
        base_branch: handoff_work_request.base_branch,
        status: "ready_for_slicing"
      )

    other_base =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-OTHER-BASE",
        repo: handoff_work_request.repo,
        base_branch: "release/handoff-sibling",
        status: "ready_for_slicing"
      )

    assert {:ok, sibling_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               sibling.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-WR-HANDOFF-SIBLING", target_base_branch: sibling.base_branch)
             )

    {anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request",
        "write:work_request",
        "dispatch:work_request"
      ])

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    list_payload = get_in(list_response, ["result", "structuredContent"])

    assert list_payload["scope"] == %{
             "repo" => anchor.repo,
             "base_branch" => anchor.base_branch
           }

    assert Enum.map(list_payload["work_requests"], & &1["id"]) == [handoff_work_request.id, sibling.id]
    refute inspect(list_response) =~ "WR-MCP-WR-HANDOFF-OTHER-REPO"
    refute inspect(list_response) =~ other_base.id

    sibling_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => sibling.id})
    assert get_in(sibling_read_response, ["result", "structuredContent", "work_request", "id"]) == sibling.id

    sibling_board_response = mcp_tool(repo, session, "read_work_request_delivery_board", %{"work_request_id" => sibling.id})
    assert get_in(sibling_board_response, ["result", "structuredContent", "work_request", "id"]) == sibling.id

    other_base_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => other_base.id})
    assert get_in(other_base_read_response, ["error", "code"]) == -32_004
    assert get_in(other_base_read_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(other_base_read_response) =~ other_base.id

    sibling_status_response =
      mcp_tool(repo, session, "set_work_request_status", %{
        "work_request_id" => sibling.id,
        "current_status" => "ready_for_slicing",
        "next_status" => "sliced"
      })

    assert get_in(sibling_status_response, ["error", "code"]) == -32_004
    assert get_in(sibling_status_response, ["error", "data", "reason"]) == "not_found"
    refute inspect(sibling_status_response) =~ sibling.id

    sibling_question_response =
      mcp_tool(repo, session, "ask_work_request_question", %{
        "work_request_id" => sibling.id,
        "category" => "scope",
        "question" => "Can the sibling be mutated?",
        "why_needed" => "Mutation must stay pinned to the claimed WorkRequest."
      })

    assert get_in(sibling_question_response, ["error", "code"]) == -32_004
    assert get_in(sibling_question_response, ["error", "data", "reason"]) == "not_found"

    sibling_decision_response =
      mcp_tool(repo, session, "record_work_request_decision", %{
        "work_request_id" => sibling.id,
        "source_type" => "architect",
        "decision" => "Mutate sibling",
        "rationale" => "This should be denied.",
        "scope_impact" => "No sibling state should change.",
        "created_by" => "architect-1"
      })

    assert get_in(sibling_decision_response, ["error", "code"]) == -32_004
    assert get_in(sibling_decision_response, ["error", "data", "reason"]) == "not_found"

    sibling_add_slice_response =
      mcp_tool(repo, session, "add_work_request_planned_slice", %{
        "work_request_id" => sibling.id,
        "title" => "Sibling mutation",
        "goal" => "This should be denied.",
        "work_package_kind" => "mcp",
        "target_base_branch" => sibling.base_branch,
        "owned_file_globs" => ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"],
        "forbidden_file_globs" => [],
        "acceptance_criteria" => ["Sibling mutation remains denied."],
        "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
        "review_lanes" => ["normal"],
        "stop_conditions" => ["Stop before mutating siblings."]
      })

    assert get_in(sibling_add_slice_response, ["error", "code"]) == -32_004
    assert get_in(sibling_add_slice_response, ["error", "data", "reason"]) == "not_found"

    sibling_approve_response =
      mcp_tool(repo, session, "approve_work_request_planned_slice", %{
        "work_request_id" => sibling.id,
        "planned_slice_id" => sibling_slice.id,
        "current_status" => "planned"
      })

    assert get_in(sibling_approve_response, ["error", "code"]) == -32_004
    assert get_in(sibling_approve_response, ["error", "data", "reason"]) == "not_found"

    sibling_skip_response =
      mcp_tool(repo, session, "skip_work_request_planned_slice", %{
        "work_request_id" => sibling.id,
        "planned_slice_id" => sibling_slice.id,
        "current_status" => "planned"
      })

    assert get_in(sibling_skip_response, ["error", "code"]) == -32_004
    assert get_in(sibling_skip_response, ["error", "data", "reason"]) == "not_found"

    sibling_dispatch_response =
      mcp_tool(repo, session, "dispatch_work_request_planned_slice", %{
        "work_request_id" => sibling.id,
        "planned_slice_id" => sibling_slice.id,
        "claimed_by" => "sibling-worker"
      })

    assert get_in(sibling_dispatch_response, ["error", "code"]) == -32_004
    assert get_in(sibling_dispatch_response, ["error", "data", "reason"]) == "not_found"

    sibling_delivery_response =
      mcp_tool(repo, session, "record_planned_slice_delivery", %{
        "work_request_id" => sibling.id,
        "planned_slice_id" => sibling_slice.id,
        "outcome" => "completed_no_pr",
        "no_pr_evidence" => "Sibling delivery mutation should be denied.",
        "idempotency_key" => "sibling-delivery-denied"
      })

    assert get_in(sibling_delivery_response, ["error", "code"]) == -32_004
    assert get_in(sibling_delivery_response, ["error", "data", "reason"]) == "not_found"

    assert {:ok, persisted_sibling} = WorkRequestRepository.get(repo, sibling.id)
    assert persisted_sibling.status == "ready_for_slicing"
    assert {:ok, []} = WorkRequestRepository.list_questions(repo, sibling.id)
    assert {:ok, []} = WorkRequestRepository.list_decisions(repo, sibling.id)
    assert {:ok, [persisted_sibling_slice]} = WorkRequestRepository.list_planned_slices(repo, sibling.id)
    assert persisted_sibling_slice.id == sibling_slice.id
    assert persisted_sibling_slice.status == "planned"
    assert is_nil(persisted_sibling_slice.work_package_id)

    target_read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => handoff_work_request.id})
    assert get_in(target_read_response, ["result", "structuredContent", "work_request", "id"]) == handoff_work_request.id
  end

  test "WorkRequest MCP scope is not pinned for normal non-handoff phases", %{repo: repo} do
    first =
      create_work_request!(repo,
        id: "WR-MCP-WR-PREFIX-FIRST",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    second =
      create_work_request!(repo,
        id: "WR-MCP-WR-PREFIX-SECOND",
        repo: first.repo,
        base_branch: first.base_branch,
        status: "ready_for_slicing"
      )

    phase_id = "phase-manual-work-request-scope"
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Manual WorkRequest phase"})

    {_anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-PREFIX-NON-HANDOFF", ["read:work_request"],
        phase_id: phase_id,
        repo: first.repo,
        base_branch: first.base_branch
      )

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    list_payload = get_in(list_response, ["result", "structuredContent"])

    assert list_payload["scope"] == %{"repo" => first.repo, "base_branch" => first.base_branch}
    assert Enum.map(list_payload["work_requests"], & &1["id"]) == [first.id, second.id]
  end

  test "WorkRequest MCP tools fail closed for partial handoff provenance", %{repo: repo} do
    first =
      create_work_request!(repo,
        id: "WR-MCP-WR-PARTIAL-HANDOFF-FIRST",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-PARTIAL-HANDOFF-SIBLING",
        repo: first.repo,
        base_branch: first.base_branch,
        status: "ready_for_slicing"
      )

    phase_id = "phase-wr-architect-partial-provenance"
    assert {:ok, _phase} = PhaseRepository.create(repo, %{id: phase_id, title: "Partial handoff phase"})

    {_anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-PARTIAL-HANDOFF", ["read:work_request"],
        phase_id: phase_id,
        repo: first.repo,
        base_branch: first.base_branch
      )

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    assert get_in(list_response, ["error", "code"]) == -32_003
    assert get_in(list_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(list_response) =~ sibling.id
  end

  test "WorkRequest MCP tools fail closed when handoff provenance no longer matches a WorkRequest", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-DRIFTED",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-DRIFTED-SIBLING",
        repo: handoff_work_request.repo,
        base_branch: handoff_work_request.base_branch,
        status: "ready_for_slicing"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request"
      ])

    assert {:ok, _drifted} =
             WorkRequestRepository.update(repo, handoff_work_request.id, %{"repo" => "nextide/drifted"})

    list_response = mcp_tool(repo, session, "list_work_requests", %{"status" => "ready_for_slicing"})
    assert get_in(list_response, ["error", "code"]) == -32_003
    assert get_in(list_response, ["error", "data", "reason"]) == "outside_session_scope"
    refute inspect(list_response) =~ sibling.id
  end

  test "WorkRequest MCP tools fail closed when handoff WorkRequest leaves eligible status", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-INELIGIBLE",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request"
      ])

    assert {:ok, _draft} = WorkRequestRepository.update_status(repo, handoff_work_request.id, "ready_for_slicing", "draft")

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => handoff_work_request.id})
    assert get_in(read_response, ["error", "code"]) == -32_003
    assert get_in(read_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "WorkRequest MCP tools fail closed when handoff WorkRequest file scope changes", %{repo: repo} do
    handoff_work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-HANDOFF-FILE-SCOPE",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    {_anchor, session, _grant} =
      create_work_request_handoff_architect_session(repo, handoff_work_request, [
        "read:work_request"
      ])

    assert {:ok, _narrowed} =
             WorkRequestRepository.update(repo, handoff_work_request.id, %{
               "constraints" => %{"allowed_paths" => ["docs"], "requires_secret" => false}
             })

    read_response = mcp_tool(repo, session, "read_work_request", %{"work_request_id" => handoff_work_request.id})
    assert get_in(read_response, ["error", "code"]) == -32_003
    assert get_in(read_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "architect WorkRequest mutation tools update scoped clarification state and redact responses", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-MUTATE", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-MUTATE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_clarification"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    status_response =
      mcp_tool(repo, session, "set_work_request_status", %{
        "work_request_id" => work_request.id,
        "current_status" => "ready_for_clarification",
        "next_status" => "clarifying"
      })

    status_payload = get_in(status_response, ["result", "structuredContent"])
    assert status_payload["work_request"]["status"] == "clarifying"
    assert MapSet.new(Map.keys(status_payload["work_request"])) == MapSet.new(["id", "status", "updated_at"])
    assert status_payload["status"] == %{"previous_status" => "ready_for_clarification", "current_status" => "clarifying"}
    assert status_payload["scope"] == %{"repo" => anchor.repo, "base_branch" => anchor.base_branch}

    assert {:ok, persisted_work_request} = WorkRequestRepository.get(repo, work_request.id)
    assert persisted_work_request.status == "clarifying"

    ask_response =
      mcp_tool(repo, session, "ask_work_request_question", %{
        "work_request_id" => work_request.id,
        "category" => "scope",
        "question" => "Can the implementation use Bearer raw_secret_value?",
        "why_needed" => "The architect needs to avoid raw_secret_value leakage.",
        "decision_prompt" => %{
          "tl_dr" => "Choose whether to continue.",
          "details" => "The architect needs a human-readable option picker.",
          "options" => [
            %{
              "id" => "continue",
              "label" => "Continue",
              "description" => "Proceed with the safe path.",
              "pros" => ["Fastest path"],
              "cons" => ["Leaves polish for later"],
              "answer" => "Continue without raw_secret_value."
            }
          ],
          "custom_redirect_label" => "No, and tell the agent what to do differently"
        },
        "asked_by_agent_run_id" => "raw_secret_value"
      })

    ask_payload = get_in(ask_response, ["result", "structuredContent"])
    question_id = get_in(ask_payload, ["clarification_question", "id"])
    assert is_binary(question_id)
    assert get_in(ask_payload, ["clarification_question", "status"]) == "open"
    assert get_in(ask_payload, ["clarification_question", "asked_by_agent_run_id"]) == "[REDACTED]"
    assert get_in(ask_payload, ["clarification_question", "decision_prompt", "tl_dr"]) == "Choose whether to continue."
    assert get_in(ask_payload, ["clarification_question", "decision_prompt", "options", Access.at(0), "answer"]) == "Continue without [REDACTED]."
    assert MapSet.new(Map.keys(ask_payload["work_request"])) == MapSet.new(["id", "status", "updated_at"])
    refute inspect(ask_response) =~ "raw_secret_value"

    wrong_status_response =
      mcp_tool(repo, session, "answer_work_request_question", %{
        "work_request_id" => work_request.id,
        "question_id" => question_id,
        "expected_question_status" => "ready_for_slicing",
        "answer" => "Wrong status domain."
      })

    assert get_in(wrong_status_response, ["error", "data", "reason"]) == "invalid_question_status"
    assert get_in(wrong_status_response, ["error", "data", "status_domain"]) == "clarification_question"
    assert get_in(wrong_status_response, ["error", "data", "expected_statuses"]) == ["open"]
    assert get_in(wrong_status_response, ["error", "data", "got"]) == "ready_for_slicing"

    malformed_status_response =
      mcp_tool(repo, session, "answer_work_request_question", %{
        "work_request_id" => work_request.id,
        "question_id" => question_id,
        "expected_question_status" => 123,
        "answer" => "Malformed status guard."
      })

    assert get_in(malformed_status_response, ["error", "data", "reason"]) == "invalid_question_status"
    assert get_in(malformed_status_response, ["error", "data", "got"]) == "non_string"

    answer_response =
      mcp_tool(repo, session, "answer_work_request_question", %{
        "work_request_id" => work_request.id,
        "question_id" => question_id,
        "answer" => "Use signed URL https://example.test/path?sig=raw_secret_value instead."
      })

    answer_payload = get_in(answer_response, ["result", "structuredContent"])
    assert get_in(answer_payload, ["clarification_question", "status"]) == "answered"
    assert get_in(answer_payload, ["clarification_question", "answered_by"]) == "architect-1"
    refute inspect(answer_response) =~ "raw_secret_value"

    close_ask_response =
      mcp_tool(repo, session, "ask_work_request_question", %{
        "work_request_id" => work_request.id,
        "category" => "acceptance",
        "question" => "Can the stale branch be ignored?",
        "why_needed" => "The architect needs an explicit closure reason."
      })

    close_question_id = get_in(close_ask_response, ["result", "structuredContent", "clarification_question", "id"])

    close_response =
      mcp_tool(repo, session, "close_work_request_question", %{
        "work_request_id" => work_request.id,
        "question_id" => close_question_id,
        "current_status" => "open"
      })

    assert get_in(close_response, ["result", "structuredContent", "clarification_question", "status"]) == "closed"

    combined_ask_response =
      mcp_tool(repo, session, "ask_work_request_question", %{
        "work_request_id" => work_request.id,
        "category" => "product",
        "question" => "Should we keep this backend-only?",
        "why_needed" => "The answer should become decision-log truth."
      })

    combined_question_id = get_in(combined_ask_response, ["result", "structuredContent", "clarification_question", "id"])

    combined_response =
      mcp_tool(repo, session, "answer_work_request_question_and_record_decision", %{
        "work_request_id" => work_request.id,
        "question_id" => combined_question_id,
        "answer" => "Keep it backend-only.",
        "source_type" => "architect",
        "decision" => "Keep the WorkRequest backend-only.",
        "rationale" => "The UI is out of scope.",
        "scope_impact" => "No dashboard changes."
      })

    combined_payload = get_in(combined_response, ["result", "structuredContent"])
    assert get_in(combined_payload, ["clarification_question", "status"]) == "answered"
    assert get_in(combined_payload, ["decision_log_entry", "source_id"]) == combined_question_id
    assert get_in(combined_payload, ["decision_log_entry", "created_by"]) == "architect-1"

    decision_response =
      mcp_tool(repo, session, "record_work_request_decision", %{
        "work_request_id" => work_request.id,
        "source_type" => "architect",
        "source_id" => "comment-1",
        "decision" => "Keep this WorkRequest backend-only with token raw_secret_value excluded.",
        "rationale" => "Dashboard work is out of scope.",
        "scope_impact" => "No dashboard changes.",
        "created_by" => "architect-1"
      })

    decision_payload = get_in(decision_response, ["result", "structuredContent"])
    assert get_in(decision_payload, ["decision_log_entry", "source_id"]) == "comment-1"
    assert decision_payload["status"] == %{"work_request_status" => "clarifying"}
    refute inspect(decision_response) =~ "raw_secret_value"

    assert {:ok, questions} = WorkRequestRepository.list_questions(repo, work_request.id)
    assert Enum.map(questions, & &1.status) == ["answered", "closed", "answered"]
    assert {:ok, decisions} = WorkRequestRepository.list_decisions(repo, work_request.id)
    assert Enum.map(decisions, & &1.source_id) == [combined_question_id, "comment-1"]
  end

  test "ask_work_request_question rejects malformed decision prompts without echoing nested input", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-BAD-PROMPT", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-BAD-DECISION-PROMPT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "clarifying"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    response =
      mcp_tool(repo, session, "ask_work_request_question", %{
        "work_request_id" => work_request.id,
        "category" => "scope",
        "question" => "Can the implementation continue?",
        "why_needed" => "The architect needs a human answer.",
        "decision_prompt" => %{
          "tl_dr" => "Do not leak raw_secret_value.",
          "details" => "This malformed prompt is missing options."
        }
      })

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "reason"]) == "decision_prompt must contain 1 to 4 options"
    refute inspect(response) =~ "raw_secret_value"
  end

  test "WorkRequest MCP question mutations leave parent status explicit", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-STATUS-EXPLICIT", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-STATUS-EXPLICIT",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_clarification"
      )

    grant_work_request_scope!(repo, session, work_request.id)

    response =
      mcp_tool(repo, session, "ask_work_request_question", %{
        "work_request_id" => work_request.id,
        "category" => "scope",
        "question" => "Should this move status automatically?",
        "why_needed" => "MCP uses explicit status mutation."
      })

    payload = get_in(response, ["result", "structuredContent"])
    assert payload["work_request"]["status"] == "ready_for_clarification"

    assert payload["status"] == %{
             "work_request_status" => "ready_for_clarification",
             "question_status" => "open"
           }

    assert {:ok, persisted_work_request} = WorkRequestRepository.get(repo, work_request.id)
    assert persisted_work_request.status == "ready_for_clarification"
  end

  test "architect WorkRequest planned-slice mutation tools update scoped slices and mark sliced", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-MUTATE", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-MUTATE",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing",
        human_description: "Do not return raw_secret_value."
      )

    grant_work_request_scope!(repo, session, work_request.id)

    counts_before = {
      repo.aggregate(WorkPackage, :count),
      repo.aggregate(AccessGrant, :count),
      repo.aggregate(ProgressEvent, :count),
      repo.aggregate(Artifact, :count)
    }

    add_args = %{
      "work_request_id" => work_request.id,
      "title" => "Planned raw_secret_value slice",
      "goal" => "Persist a planned slice without leaking raw_secret_value.",
      "work_package_kind" => "mcp",
      "target_base_branch" => anchor.base_branch,
      "owned_file_globs" => [" elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex "],
      "forbidden_file_globs" => [],
      "acceptance_criteria" => ["MCP planned-slice mutation succeeds."],
      "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
      "review_lanes" => ["brief", "raw_secret_review_lane", "normal"],
      "stop_conditions" => ["Stop before dispatch."]
    }

    out_of_scope_response =
      mcp_tool(
        repo,
        session,
        "add_work_request_planned_slice",
        Map.put(add_args, "target_base_branch", "feature/out-of-scope")
      )

    assert get_in(out_of_scope_response, ["error", "code"]) == -32_602
    assert get_in(out_of_scope_response, ["error", "data", "reason"]) == "target_base_branch_scope_mismatch"
    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    changeset_error_response =
      mcp_tool(
        repo,
        session,
        "add_work_request_planned_slice",
        Map.merge(add_args, %{
          "title" => "Invalid raw_secret_value slice",
          "goal" => "Do not echo raw_secret_value in changeset errors.",
          "work_package_kind" => "side_quest",
          "review_lanes" => ["raw_secret_value"]
        })
      )

    assert get_in(changeset_error_response, ["error", "code"]) == -32_602
    assert get_in(changeset_error_response, ["error", "data", "reason"]) == "invalid_planned_slice"
    refute inspect(changeset_error_response) =~ "raw_secret_value"
    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    invalid_docs_scope_response =
      mcp_tool(
        repo,
        session,
        "add_work_request_planned_slice",
        Map.merge(add_args, %{
          "title" => "Invalid docs scope",
          "goal" => "Docs kind cannot own code paths.",
          "work_package_kind" => "docs",
          "owned_file_globs" => ["elixir/lib/**"]
        })
      )

    assert get_in(invalid_docs_scope_response, ["error", "code"]) == -32_602
    assert get_in(invalid_docs_scope_response, ["error", "data", "reason"]) == "planned_slice_scope_violation"

    assert [
             %{
               "field" => "owned_file_globs",
               "value" => "elixir/lib/**",
               "reason" => "non_documentation_owned_glob"
             }
           ] = get_in(invalid_docs_scope_response, ["error", "data", "validation_errors"])

    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    invalid_branch_response =
      mcp_tool(
        repo,
        session,
        "add_work_request_planned_slice",
        Map.put(add_args, "branch_pattern", "feat/live-triggers-v1-native-audio-evidence-*")
      )

    assert get_in(invalid_branch_response, ["error", "data", "reason"]) == "unsupported_branch_pattern_wildcard"

    assert [
             %{
               "field" => "branch_pattern",
               "value" => "feat/live-triggers-v1-native-audio-evidence-*",
               "reason" => "unsupported_branch_pattern_wildcard"
             }
             | _
           ] = get_in(invalid_branch_response, ["error", "data", "validation_errors"])

    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    add_response = mcp_tool(repo, session, "add_work_request_planned_slice", add_args)
    add_payload = get_in(add_response, ["result", "structuredContent"])
    planned_slice_id = get_in(add_payload, ["planned_slice", "id"])

    assert is_binary(planned_slice_id)
    assert add_payload["scope"] == %{"repo" => anchor.repo, "base_branch" => anchor.base_branch}
    assert add_payload["work_request"]["status"] == "ready_for_slicing"
    assert get_in(add_payload, ["planned_slice", "status"]) == "planned"
    assert get_in(add_payload, ["planned_slice", "owned_file_globs"]) == ["elixir/lib/symphony_elixir/symphony_plus_plus/mcp/server.ex"]
    assert get_in(add_payload, ["planned_slice", "forbidden_file_globs"]) == []
    assert get_in(add_payload, ["planned_slice", "branch_pattern"]) == nil
    assert get_in(add_payload, ["planned_slice", "review_lanes"]) == ["brief", "[REDACTED]", "normal"]
    assert add_payload["status"] == %{"work_request_status" => "ready_for_slicing", "planned_slice_status" => "planned"}
    refute inspect(add_response) =~ "raw_secret_value"

    skip_add_response =
      mcp_tool(
        repo,
        session,
        "add_work_request_planned_slice",
        Map.merge(add_args, %{
          "title" => "Skipped follow-up",
          "goal" => "Record a slice that can be skipped.",
          "branch_pattern" => "agent/SYMPP-V2-WR-015/skipped"
        })
      )

    skip_slice_id = get_in(skip_add_response, ["result", "structuredContent", "planned_slice", "id"])

    approve_response =
      mcp_tool(repo, session, "approve_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice_id,
        "current_status" => "planned"
      })

    approve_payload = get_in(approve_response, ["result", "structuredContent"])
    assert get_in(approve_payload, ["planned_slice", "status"]) == "approved"

    assert approve_payload["status"] == %{
             "work_request_status" => "ready_for_slicing",
             "previous_planned_slice_status" => "planned",
             "planned_slice_status" => "approved"
           }

    skip_response =
      mcp_tool(repo, session, "skip_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => skip_slice_id,
        "current_status" => "planned"
      })

    skip_payload = get_in(skip_response, ["result", "structuredContent"])
    assert get_in(skip_payload, ["planned_slice", "status"]) == "skipped"
    assert get_in(skip_payload, ["planned_slice", "branch_pattern"]) == "agent/SYMPP-V2-WR-015/skipped"

    mark_response =
      mcp_tool(repo, session, "mark_work_request_sliced", %{
        "work_request_id" => work_request.id,
        "current_status" => "ready_for_slicing"
      })

    mark_payload = get_in(mark_response, ["result", "structuredContent"])
    assert mark_payload["work_request"]["status"] == "sliced"
    assert mark_payload["status"] == %{"previous_status" => "ready_for_slicing", "current_status" => "sliced"}

    assert {:ok, planned_slices} = WorkRequestRepository.list_planned_slices(repo, work_request.id)
    assert Enum.map(planned_slices, & &1.status) == ["approved", "skipped"]
    assert {:ok, persisted_work_request} = WorkRequestRepository.get(repo, work_request.id)
    assert persisted_work_request.status == "sliced"

    assert {
             repo.aggregate(WorkPackage, :count),
             repo.aggregate(AccessGrant, :count),
             repo.aggregate(ProgressEvent, :count),
             repo.aggregate(Artifact, :count)
           } == counts_before
  end

  test "WorkRequest MCP planned-slice validation rejects unsupported globstar at add and approve", %{repo: repo} do
    {anchor, session, _grant} =
      create_phase_architect_session(repo, "SYMPP-ARCHITECT-WR-SLICE-GLOBSTAR", [
        "write:work_request"
      ])

    work_request =
      create_work_request!(repo,
        id: "WR-MCP-WR-SLICE-GLOBSTAR",
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: "ready_for_slicing",
        constraints: %{"allowed_paths" => ["scripts", "elixir/lib"], "requires_secret" => false}
      )

    grant_work_request_scope!(repo, session, work_request.id)

    add_args = %{
      "work_request_id" => work_request.id,
      "title" => "Invalid globstar slice",
      "goal" => "Reject invalid globstar placement before dispatch.",
      "work_package_kind" => "mcp",
      "target_base_branch" => anchor.base_branch,
      "owned_file_globs" => ["scripts/**deploy**"],
      "forbidden_file_globs" => [],
      "acceptance_criteria" => ["Invalid globstar placement is rejected early."],
      "validation_steps" => ["mix test test/symphony_elixir/symphony_plus_plus/mcp"],
      "review_lanes" => ["normal"],
      "stop_conditions" => ["Stop before dispatch."]
    }

    add_response = mcp_tool(repo, session, "add_work_request_planned_slice", add_args)

    assert get_in(add_response, ["error", "code"]) == -32_602
    assert get_in(add_response, ["error", "data", "reason"]) == "planned_slice_scope_violation"

    assert get_in(add_response, ["error", "data", "validation_errors"]) == [
             %{"field" => "owned_file_globs", "value" => "scripts/**deploy**", "reason" => "unsupported_globstar"}
           ]

    assert {:ok, []} = WorkRequestRepository.list_planned_slices(repo, work_request.id)

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(repo, work_request.id, Map.delete(add_args, "work_request_id"))

    approve_response =
      mcp_tool(repo, session, "approve_work_request_planned_slice", %{
        "work_request_id" => work_request.id,
        "planned_slice_id" => planned_slice.id,
        "current_status" => "planned"
      })

    assert get_in(approve_response, ["error", "code"]) == -32_602
    assert get_in(approve_response, ["error", "data", "reason"]) == "planned_slice_scope_violation"

    assert get_in(approve_response, ["error", "data", "validation_errors"]) == [
             %{"field" => "owned_file_globs", "value" => "scripts/**deploy**", "reason" => "unsupported_globstar"}
           ]

    assert {:ok, persisted_slice} = WorkRequestRepository.get_planned_slice(repo, work_request.id, planned_slice.id)
    assert persisted_slice.status == "planned"
  end
end
