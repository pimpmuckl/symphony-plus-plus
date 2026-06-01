Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.CommentsGuidanceTest do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "worker comment tools create list and resolve exact package comments only", %{repo: repo} do
    assert {:ok, work_package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-MCP-COMMENTS", kind: "mcp", repo: "nextide/symphony-plus-plus", base_branch: "main"))

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    work_request =
      create_work_request!(
        repo,
        id: "WR-MCP-COMMENTS",
        repo: work_package.repo,
        base_branch: work_package.base_branch
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-COMMENTS", target_base_branch: work_package.base_branch)
             )

    repo.update!(Ecto.Changeset.change(planned_slice, status: "dispatched", work_package_id: work_package.id))

    work_request_comment_response =
      mcp_tool(repo, session, "add_comment", %{
        "work_package_id" => work_package.id,
        "target_kind" => "work_request",
        "target_id" => work_request.id,
        "body" => "This must stay architect-owned"
      })

    assert get_in(work_request_comment_response, ["error", "code"]) == -32_003
    assert get_in(work_request_comment_response, ["error", "data", "reason"]) == "outside_session_scope"

    planned_slice_comment_response =
      mcp_tool(repo, session, "add_comment", %{
        "work_package_id" => work_package.id,
        "target_kind" => "planned_slice",
        "target_id" => planned_slice.id,
        "body" => "This must stay architect-owned"
      })

    assert get_in(planned_slice_comment_response, ["error", "code"]) == -32_003
    assert get_in(planned_slice_comment_response, ["error", "data", "reason"]) == "outside_session_scope"

    overlong_response =
      mcp_tool(repo, session, "add_comment", %{
        "work_package_id" => work_package.id,
        "target_kind" => "work_package",
        "target_id" => work_package.id,
        "body" => String.duplicate("x", Comment.max_body_length() + 1)
      })

    assert get_in(overlong_response, ["error", "data", "reason"]) =~ "body"

    add_response =
      mcp_tool(repo, session, "add_comment", %{
        "work_package_id" => work_package.id,
        "target_kind" => "work_package",
        "target_id" => work_package.id,
        "body" => "Check sk-secret123 before merge"
      })

    assert comment_id = get_in(add_response, ["result", "structuredContent", "comment", "id"])
    assert get_in(add_response, ["result", "structuredContent", "comment", "body"]) == "Check [REDACTED] before merge"

    list_response =
      mcp_tool(repo, session, "list_comments", %{
        "work_package_id" => work_package.id,
        "target_kind" => "work_package",
        "target_id" => work_package.id
      })

    assert [%{"id" => ^comment_id, "status" => "open"}] = get_in(list_response, ["result", "structuredContent", "comments"])

    resolve_response =
      mcp_tool(repo, session, "resolve_comment", %{
        "comment_id" => comment_id,
        "resolution_note" => "Handled"
      })

    assert get_in(resolve_response, ["result", "structuredContent", "comment", "status"]) == "resolved"
    assert {:ok, %Comment{status: "resolved", source_type: "worker", author_name: "worker-1", resolved_by: "worker-1", resolved_source_type: "worker"}} = CommentService.get(repo, comment_id)

    assert {:ok, other_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-MCP-COMMENTS-OTHER", kind: "mcp"))

    assert {:ok, foreign_comment} =
             CommentService.create(repo, %{
               target_kind: "work_package",
               target_id: other_package.id,
               body: "Foreign",
               source_type: "worker",
               author_name: "other-worker"
             })

    out_of_scope_response =
      mcp_tool(repo, session, "list_comments", %{
        "work_package_id" => work_package.id,
        "target_kind" => "work_package",
        "target_id" => other_package.id
      })

    assert get_in(out_of_scope_response, ["error", "data", "reason"]) == "outside_session_scope"

    out_of_scope_resolve_response =
      mcp_tool(repo, session, "resolve_comment", %{
        "work_package_id" => work_package.id,
        "comment_id" => foreign_comment.id
      })

    assert get_in(out_of_scope_resolve_response, ["error", "data", "reason"]) == "not_found"
  end

  test "architect comment and blocker tools distinguish external WR notes from claimed descendants", %{repo: repo} do
    work_request =
      create_work_request!(
        repo,
        id: "WR-MCP-ARCH-PACKAGE-SURFACES",
        repo: "nextide/symphony-plus-plus",
        base_branch: "main",
        status: "ready_for_slicing"
      )

    sibling =
      create_work_request!(
        repo,
        id: "WR-MCP-ARCH-PACKAGE-SURFACES-SIBLING",
        repo: work_request.repo,
        base_branch: work_request.base_branch,
        status: "ready_for_slicing"
      )

    assert {:ok, planned_slice} =
             WorkRequestRepository.add_planned_slice(
               repo,
               work_request.id,
               work_request_planned_slice_attrs(id: "WRS-MCP-ARCH-PACKAGE-SURFACES", target_base_branch: work_request.base_branch)
             )

    assert {:ok, work_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-MCP-ARCH-PACKAGE-SURFACES",
                 kind: "mcp",
                 repo: work_request.repo,
                 base_branch: work_request.base_branch,
                 status: "implementing"
               )
             )

    repo.update!(Ecto.Changeset.change(planned_slice, status: "dispatched", work_package_id: work_package.id))

    {_phase_anchor, phase_session, _phase_grant} =
      create_phase_architect_session(
        repo,
        "SYMPP-MCP-ARCH-PHASE-COMMENTS",
        [
          "read:work_request",
          "write:work_request"
        ],
        repo: work_request.repo,
        base_branch: work_request.base_branch
      )

    work_package =
      repo.update!(Ecto.Changeset.change(work_package, phase_id: phase_session.assignment.phase_id))

    external_response =
      mcp_tool(repo, phase_session, "add_comment", %{
        "target_kind" => "work_request",
        "target_id" => sibling.id,
        "body" => "External note without claiming lifecycle authority"
      })

    assert external_comment_id = get_in(external_response, ["result", "structuredContent", "comment", "id"])
    assert get_in(external_response, ["result", "structuredContent", "comment", "source_type"]) == "architect"

    external_resolve_response =
      mcp_tool(repo, phase_session, "resolve_comment", %{
        "comment_id" => external_comment_id,
        "resolution_note" => "Trying to close an external note"
      })

    assert get_in(external_resolve_response, ["error", "data", "reason"]) == "not_found"

    descendant_write_denied =
      mcp_tool(repo, phase_session, "add_comment", %{
        "target_kind" => "work_package",
        "target_id" => work_package.id,
        "body" => "Phase read scope is not descendant write authority"
      })

    assert get_in(descendant_write_denied, ["error", "code"]) == -32_003
    assert get_in(descendant_write_denied, ["error", "data", "reason"]) == "outside_session_scope"

    {_handoff_anchor, handoff_session, _handoff_grant} =
      create_work_request_handoff_architect_session(repo, work_request, [
        "read:work_request",
        "write:work_request"
      ])

    descendant_comment_response =
      mcp_tool(repo, handoff_session, "add_comment", %{
        "target_kind" => "work_package",
        "target_id" => work_package.id,
        "body" => "Descendant package guidance"
      })

    assert get_in(descendant_comment_response, ["result", "structuredContent", "comment", "target_id"]) == work_package.id

    phase_read_response =
      mcp_tool(repo, phase_session, "list_comments", %{
        "target_kind" => "work_package",
        "target_id" => work_package.id
      })

    assert get_in(phase_read_response, ["result", "structuredContent", "comments"])
           |> Enum.any?(&(&1["target_id"] == work_package.id))

    assert {:ok, _blocker_event} =
             PlanningRepository.append_audit_progress_event_for_work_package(repo, handoff_session.assignment, work_package.id, %{
               "summary" => "Waiting for architect",
               "idempotency_key" => "arch-policy-blocker",
               "payload" => %{
                 "type" => "blocker",
                 "source_tool" => "report_blocker",
                 "blocker_id" => "arch-policy-blocker",
                 "active" => true
               }
             })

    resolve_blocker_response =
      mcp_tool(repo, handoff_session, "resolve_blocker", %{
        "work_package_id" => work_package.id,
        "blocker_id" => "arch-policy-blocker",
        "resolution" => "Architect supplied the missing decision.",
        "summary" => "Cleared architect blocker",
        "idempotency_key" => "arch-policy-blocker-resolved"
      })

    assert get_in(resolve_blocker_response, ["result", "structuredContent", "progress_event", "payload", "active"]) == false

    anchor_blocker_id = "arch-policy-anchor-blocker"

    assert {:ok, _anchor_blocker_event} =
             PlanningRepository.append_audit_progress_event_for_work_package(
               repo,
               handoff_session.assignment,
               handoff_session.assignment.work_package_id,
               %{
                 "summary" => "Waiting for anchor decision",
                 "idempotency_key" => anchor_blocker_id,
                 "payload" => %{
                   "type" => "blocker",
                   "source_tool" => "report_blocker",
                   "blocker_id" => anchor_blocker_id,
                   "active" => true
                 }
               }
             )

    default_scope_response =
      mcp_tool(repo, handoff_session, "resolve_blocker", %{
        "blocker_id" => anchor_blocker_id,
        "resolution" => "Architect supplied the anchor decision.",
        "summary" => "Cleared anchor blocker",
        "idempotency_key" => "arch-policy-anchor-blocker-resolved"
      })

    assert get_in(default_scope_response, ["result", "structuredContent", "progress_event", "idempotency_key"]) ==
             ["resolve_blocker", handoff_session.assignment.work_package_id, "arch-policy-anchor-blocker-resolved"] |> Enum.join(":")

    assert get_in(default_scope_response, ["result", "structuredContent", "progress_event", "payload", "active"]) == false
  end

  test "local operator WorkRequest note tools append comments and decisions with redacted provenance", %{repo: repo} do
    work_request =
      create_work_request!(
        repo,
        id: "WR-MCP-LOCAL-OPERATOR-NOTES",
        repo: "nextide/symphony-plus-plus",
        base_branch: "feature/sympp-v21-ledger-claims"
      )

    local_server = local_mcp_server(local_mcp_config(repo), "local-operator-notes-state")
    tools_by_name = tools_for_server(local_server) |> Map.new(&{&1["name"], &1})

    assert get_in(tools_by_name, ["claim_local_architect_assignment", "inputSchema", "required"]) == [
             "work_request_id",
             "architect_anchor_work_package_id",
             "repo",
             "base_branch",
             "caller_id",
             "claimed_by"
           ]

    assert get_in(tools_by_name, ["add_work_request_comment", "inputSchema", "required"]) == ["work_request_id", "body", "created_by"]

    assert get_in(tools_by_name, ["record_work_request_operator_decision", "inputSchema", "required"]) == [
             "work_request_id",
             "decision",
             "rationale",
             "scope_impact",
             "created_by"
           ]

    {comment_response, note_server} =
      Server.handle_state(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-comment",
          "method" => "tools/call",
          "params" => %{
            "name" => "add_work_request_comment",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "body" => "Coordinate with ghp_localoperatorcomment before slicing",
              "created_by" => "operator sk-localoperatorauthor"
            }
          }
        },
        local_server
      )

    assert note_server.session == nil
    assert comment_id = get_in(comment_response, ["result", "structuredContent", "comment", "id"])
    assert get_in(comment_response, ["result", "structuredContent", "comment", "body"]) == "Coordinate with [REDACTED] before slicing"
    assert get_in(comment_response, ["result", "structuredContent", "comment", "source_type"]) == "operator"
    assert get_in(comment_response, ["result", "structuredContent", "comment", "author_name"]) == "operator [REDACTED]"
    assert get_in(comment_response, ["result", "structuredContent", "provenance", "created_by"]) == "operator [REDACTED]"

    assert {:ok, %Comment{body: "Coordinate with [REDACTED] before slicing", source_type: "operator", author_name: "operator [REDACTED]"}} =
             CommentService.get(repo, comment_id)

    decision_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-decision",
          "method" => "tools/call",
          "params" => %{
            "name" => "record_work_request_operator_decision",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "decision" => "Mirror result from ghp_localoperatordecision",
              "rationale" => "Related WR needs context from sk-localoperatorrationale",
              "scope_impact" => "Comment-only, no dispatch using bearer localoperatorbearer",
              "created_by" => "operator sk-localoperatordecisionauthor",
              "source_id" => "ghp_localoperatorsource"
            }
          }
        },
        note_server
      )

    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "source_type"]) == "operator"
    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "source_id"]) == "[REDACTED]"
    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "decision"]) == "Mirror result from [REDACTED]"
    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "rationale"]) == "Related WR needs context from [REDACTED]"
    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "scope_impact"]) == "Comment-only, no dispatch using [REDACTED]"
    assert get_in(decision_response, ["result", "structuredContent", "decision_log_entry", "created_by"]) == "operator [REDACTED]"

    assert {:ok, [decision]} = WorkRequestRepository.list_decisions(repo, work_request.id)
    assert decision.source_type == "operator"
    assert decision.source_id == "[REDACTED]"
    assert decision.decision == "Mirror result from [REDACTED]"
    assert decision.created_by == "operator [REDACTED]"

    dispatch_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-dispatch-denied",
          "method" => "tools/call",
          "params" => %{"name" => "dispatch_work_request_planned_slice", "arguments" => %{}}
        },
        note_server
      )

    assert get_in(dispatch_response, ["error", "data", "reason"]) == "claim_required"

    status_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-status-denied",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{}}
        },
        note_server
      )

    assert get_in(status_response, ["error", "data", "reason"]) == "claim_required"
  end

  test "unclaimed WorkRequest reads require trusted local HTTP with explicit state", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-READ-DENIED")
    arguments = %{"work_request_id" => work_request.id}

    stdio_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "stdio-work-request-read-denied",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => arguments}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(stdio_response, ["error", "code"]) == -32_001
    assert get_in(stdio_response, ["error", "data", "reason"]) == "local_mcp_required"

    stdio_list_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "stdio-work-request-list-denied",
          "method" => "tools/call",
          "params" => %{"name" => "list_work_requests", "arguments" => %{}}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(stdio_list_response, ["error", "code"]) == -32_001
    assert get_in(stdio_list_response, ["error", "data", "reason"]) == "local_mcp_required"

    implicit_state_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "implicit-state-work-request-read-denied",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request", "arguments" => arguments}
        },
        Server.new(local_mcp_config(repo), initialized: true, local_daemon_trusted: true)
      )

    assert get_in(implicit_state_response, ["error", "code"]) == -32_001
    assert get_in(implicit_state_response, ["error", "data", "reason"]) == "local_mcp_session_required"

    remote_config = %{local_mcp_config(repo) | database: "https://ledger.example.test/mcp?token=ghp_localreadsecret"}

    remote_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "remote-work-request-read-denied",
          "method" => "tools/call",
          "params" => %{"name" => "read_work_request_delivery_board", "arguments" => arguments}
        },
        local_mcp_server(remote_config, "remote-work-request-read-state")
      )

    assert get_in(remote_response, ["error", "code"]) == -32_001
    assert get_in(remote_response, ["error", "data", "reason"]) == "local_database_required"
    refute inspect(remote_response) =~ "ghp_localreadsecret"

    remote_list_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "remote-work-request-list-denied",
          "method" => "tools/call",
          "params" => %{"name" => "list_work_requests", "arguments" => %{}}
        },
        local_mcp_server(remote_config, "remote-work-request-list-state")
      )

    assert get_in(remote_list_response, ["error", "code"]) == -32_001
    assert get_in(remote_list_response, ["error", "data", "reason"]) == "local_database_required"
    refute inspect(remote_list_response) =~ "ghp_localreadsecret"
  end

  test "local operator WorkRequest note tools reject nonlocal and remote database modes", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-OPERATOR-NOTES-DENIED")
    arguments = %{"work_request_id" => work_request.id, "body" => "safe note", "created_by" => "operator"}

    stdio_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "stdio-local-operator-denied",
          "method" => "tools/call",
          "params" => %{"name" => "add_work_request_comment", "arguments" => arguments}
        },
        Server.new(Config.default(repo: repo), initialized: true)
      )

    assert get_in(stdio_response, ["error", "code"]) == -32_001
    assert get_in(stdio_response, ["error", "data", "reason"]) == "local_mcp_required"

    remote_config = %{local_mcp_config(repo) | database: "https://ledger.example.test/mcp?token=ghp_remoteoperatorsecret"}

    implicit_state_tools =
      local_mcp_config(repo)
      |> Server.new(initialized: true, local_daemon_trusted: true)
      |> tools_for_server()
      |> Map.new(&{&1["name"], &1})

    remote_tools =
      remote_config
      |> local_mcp_server("remote-local-operator-list-state")
      |> tools_for_server()
      |> Map.new(&{&1["name"], &1})

    refute Map.has_key?(implicit_state_tools, "add_work_request_comment")
    refute Map.has_key?(implicit_state_tools, "record_work_request_operator_decision")
    refute Map.has_key?(remote_tools, "add_work_request_comment")
    refute Map.has_key?(remote_tools, "record_work_request_operator_decision")

    remote_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "remote-local-operator-denied",
          "method" => "tools/call",
          "params" => %{"name" => "add_work_request_comment", "arguments" => arguments}
        },
        local_mcp_server(remote_config, "remote-local-operator-denied-state")
      )

    assert get_in(remote_response, ["error", "code"]) == -32_001
    assert get_in(remote_response, ["error", "data", "reason"]) == "local_database_required"
    refute inspect(remote_response) =~ "ghp_remoteoperatorsecret"

    memory_configs = [
      %{local_mcp_config(repo) | database: ":memory:"},
      %{local_mcp_config(repo) | database: "file:sympp_local_operator_notes?mode=memory&cache=shared"}
    ]

    Enum.with_index(memory_configs, fn memory_config, index ->
      memory_tools =
        memory_config
        |> local_mcp_server("memory-local-operator-list-state-#{index}")
        |> tools_for_server()
        |> Map.new(&{&1["name"], &1})

      refute Map.has_key?(memory_tools, "add_work_request_comment")
      refute Map.has_key?(memory_tools, "record_work_request_operator_decision")

      memory_response =
        Server.handle(
          %{
            "jsonrpc" => "2.0",
            "id" => "memory-local-operator-denied-#{index}",
            "method" => "tools/call",
            "params" => %{"name" => "add_work_request_comment", "arguments" => arguments}
          },
          local_mcp_server(memory_config, "memory-local-operator-denied-state-#{index}")
        )

      assert get_in(memory_response, ["error", "code"]) == -32_001
      assert get_in(memory_response, ["error", "data", "reason"]) == "file_backed_database_required"
    end)
  end

  test "local operator WorkRequest note tools reject bound worker sessions", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-OPERATOR-BOUND-DENIED")

    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-LOCAL-OPERATOR-BOUND", kind: "mcp"))

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, worker_assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    worker_server = %{
      local_mcp_server(local_mcp_config(repo), "local-operator-worker-bound-state")
      | session: MCPHarness.session(worker_assignment, proof_hash: minted.grant.secret_hash)
    }

    worker_tools =
      worker_server
      |> tools_for_server()
      |> Map.new(&{&1["name"], &1})

    refute Map.has_key?(worker_tools, "add_work_request_comment")
    refute Map.has_key?(worker_tools, "record_work_request_operator_decision")

    response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-bound-denied",
          "method" => "tools/call",
          "params" => %{
            "name" => "add_work_request_comment",
            "arguments" => %{"work_request_id" => work_request.id, "body" => "safe note", "created_by" => "operator"}
          }
        },
        worker_server
      )

    assert get_in(response, ["error", "code"]) == -32_001
    assert get_in(response, ["error", "data", "reason"]) == "local_operator_unbound_session_required"
  end

  test "local operator WorkRequest note tools require initialized current sessions", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-OPERATOR-SESSION-DENIED")

    arguments = %{
      "work_request_id" => work_request.id,
      "body" => "safe note",
      "created_by" => "operator"
    }

    pre_initialize_server =
      Server.new(local_mcp_config(repo), local_daemon_trusted: true, state_key: "local-operator-pre-init-state")

    pre_initialize_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-pre-init-denied",
          "method" => "tools/call",
          "params" => %{"name" => "add_work_request_comment", "arguments" => arguments}
        },
        pre_initialize_server
      )

    assert get_in(pre_initialize_response, ["error", "code"]) == -32_000
    assert get_in(pre_initialize_response, ["error", "data", "reason"]) == "server_not_initialized"

    refresh_required_server = %{local_mcp_server(local_mcp_config(repo), "local-operator-refresh-state") | session_refresh_required: true}

    refresh_required_tools =
      refresh_required_server
      |> tools_for_server()
      |> Map.new(&{&1["name"], &1})

    refute Map.has_key?(refresh_required_tools, "add_work_request_comment")
    refute Map.has_key?(refresh_required_tools, "record_work_request_operator_decision")

    refresh_required_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-refresh-denied",
          "method" => "tools/call",
          "params" => %{"name" => "add_work_request_comment", "arguments" => arguments}
        },
        refresh_required_server
      )

    assert get_in(refresh_required_response, ["error", "code"]) == -32_001
    assert get_in(refresh_required_response, ["error", "data", "reason"]) == "claim_required"
    assert get_in(refresh_required_response, ["error", "data", "action"]) == "claim_private_handoff"
  end

  test "local operator WorkRequest note tools reject invalid local payload fields", %{repo: repo} do
    work_request = create_work_request!(repo, id: "WR-MCP-LOCAL-OPERATOR-PAYLOAD-DENIED")
    local_server = local_mcp_server(local_mcp_config(repo), "local-operator-invalid-payload-state")

    invalid_creator_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-invalid-creator",
          "method" => "tools/call",
          "params" => %{
            "name" => "add_work_request_comment",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "body" => "safe note",
              "created_by" => %{"name" => "operator"}
            }
          }
        },
        local_server
      )

    assert get_in(invalid_creator_response, ["error", "code"]) == -32_602
    assert get_in(invalid_creator_response, ["error", "data", "reason"]) == "invalid_created_by"

    long_decision_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-long-decision",
          "method" => "tools/call",
          "params" => %{
            "name" => "record_work_request_operator_decision",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "decision" => String.duplicate("x", Comment.max_body_length() + 1),
              "rationale" => "safe rationale",
              "scope_impact" => "safe scope",
              "created_by" => "operator"
            }
          }
        },
        local_server
      )

    assert get_in(long_decision_response, ["error", "code"]) == -32_602
    assert get_in(long_decision_response, ["error", "data", "reason"]) == "decision_too_long"

    null_source_response =
      Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => "local-operator-null-source",
          "method" => "tools/call",
          "params" => %{
            "name" => "record_work_request_operator_decision",
            "arguments" => %{
              "work_request_id" => work_request.id,
              "decision" => "safe decision",
              "rationale" => "safe rationale",
              "scope_impact" => "safe scope",
              "created_by" => "operator",
              "source_id" => nil
            }
          }
        },
        local_server
      )

    assert get_in(null_source_response, ["error", "code"]) == -32_602
    assert get_in(null_source_response, ["error", "data", "reason"]) == "invalid_source_id"
  end
end
