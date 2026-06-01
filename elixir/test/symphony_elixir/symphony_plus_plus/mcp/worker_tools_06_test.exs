Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools06Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "scope guard uses current-head changed-file paths from sync_pr when a later sync omits file paths", %{repo: repo} do
    changed_paths = [
      "implementation_docs_symphplusplus/README.md",
      "implementation_docs_symphplusplus/docs/01_IMPLEMENTATION_GUIDE.md",
      "implementation_docs_symphplusplus/docs/02_SYSTEM_SPEC.md",
      "implementation_docs_symphplusplus/docs/07_DASHBOARD_SPEC.md",
      "implementation_docs_symphplusplus/docs/09_OPERATIONAL_RUNBOOK.md",
      "implementation_docs_symphplusplus/docs/12_OPERATOR_TRAINING.md",
      "implementation_docs_symphplusplus/docs/13_WORKREQUEST_CONTRACT.md"
    ]

    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-GUARD-SYNC-PR",
                 kind: "mcp",
                 repo: "Pimpmuckl/symphony-plus-plus",
                 base_branch: "main",
                 status: "ci_waiting",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: changed_paths
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    head_sha = "scope-docs-head-a"
    pr_url = "https://github.com/Pimpmuckl/symphony-plus-plus/pull/61"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-V2-PRODUCT-001/workrequest-contract", "head_sha" => head_sha})
    attach_tool(repo, session, "attach_pr", %{"url" => pr_url, "head_sha" => head_sha})

    path_sync_response =
      attach_tool(repo, session, "sync_pr", %{
        "url" => pr_url,
        "metadata" => %{
          "head_sha" => head_sha,
          "base" => %{"ref" => "main", "sha" => "base-pr61"},
          "changed_files" => Enum.map(changed_paths, &%{"filename" => &1, "status" => "modified"}),
          "changed_files_count" => length(changed_paths),
          "check_summary" => %{"conclusion" => "success"},
          "review_state" => %{"state" => "approved"},
          "merge_state" => %{"state" => "clean"}
        }
      })

    path_sync_payload = get_in(path_sync_response, ["result", "structuredContent", "progress_event", "payload"])
    assert path_sync_payload["changed_files_available"] == true
    assert path_sync_payload["changed_files_count"] == 7
    assert length(path_sync_payload["changed_files"]) == 7

    count_only_sync_response =
      attach_tool(repo, session, "sync_pr", %{
        "url" => pr_url,
        "metadata" => %{
          "head_sha" => head_sha,
          "base" => %{"ref" => "main", "sha" => "base-pr61"},
          "changed_files" => 7,
          "check_summary" => %{"conclusion" => "success"},
          "review_state" => %{"state" => "approved"},
          "merge_state" => %{"state" => "clean"}
        }
      })

    count_only_payload = get_in(count_only_sync_response, ["result", "structuredContent", "progress_event", "payload"])
    assert count_only_payload["changed_files_available"] == false
    assert count_only_payload["changed_files_count"] == 7

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    attach_tool(repo, session, "attach_review_suite_result", %{
      "work_package_id" => package.id,
      "head_sha" => head_sha,
      "suite" => "review-suite",
      "anchor" => "phase_gate-scope-docs-head-a",
      "summary" => "normal is green",
      "status" => "passed",
      "verdict" => "green"
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-doc-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "architect approval repairs overbroad existing scope constraints", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-GUARD-REPAIR",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_changed_file_scope_guard",
                 allowed_file_globs: ["**"]
               )
             )

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    approval_response =
      attach_tool(repo, architect_session, "approve_scope_expansion", %{
        "work_package_id" => package.id,
        "allowed_file_globs" => ["docs/**"],
        "rationale" => "Replace invalid catch-all with scoped package docs."
      })

    assert get_in(approval_response, ["result", "structuredContent", "allowed_file_globs"]) == ["docs/**"]
    payload = get_in(approval_response, ["result", "structuredContent", "progress_event", "payload"])
    assert payload["previous_allowed_file_globs"] == ["**"]
    assert payload["allowed_file_globs"] == ["docs/**"]

    assert {:ok, repaired_package} = WorkPackageRepository.get(repo, package.id)
    assert repaired_package.allowed_file_globs == ["docs/**"]
  end

  test "scope expansion approval rejects packages without scope guard", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-SCOPE-GUARD-NOT-REQUIRED",
                 kind: "quick_fix",
                 status: "ci_waiting",
                 policy_template: "quick_fix",
                 allowed_file_globs: []
               )
             )

    assert {:ok, architect_work_key} = create_architect_work_key(repo, package.id, ["approve:scope_expansion"])

    assert {:ok, architect_assignment} =
             AccessGrantRepository.claim(repo, architect_work_key.secret, %{claimed_by: "architect-1"}, DateTime.utc_now(:microsecond))

    architect_session = MCPHarness.session(architect_assignment, proof_hash: WorkKey.secret_hash(architect_work_key.secret))

    approval_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "unguarded-scope-approval",
          "method" => "tools/call",
          "params" => %{
            "name" => "approve_scope_expansion",
            "arguments" => %{
              "work_package_id" => package.id,
              "allowed_file_globs" => ["docs/**"],
              "rationale" => "Unguarded packages must not record scope approvals."
            }
          }
        },
        repo: repo,
        session: architect_session
      )

    assert get_in(approval_response, ["error", "data", "reason"]) == "scope_guard_not_required"

    assert {:ok, unchanged_package} = WorkPackageRepository.get(repo, package.id)
    assert unchanged_package.allowed_file_globs == []
  end

  test "review-suite result rejects missing head, wrong package, stale head, non-passing verdicts, and failed-result override", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-REVIEW-SUITE-INVALID",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_review_suite_artifact"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    base_args = %{
      "work_package_id" => package.id,
      "head_sha" => "head-a",
      "suite" => "review-suite",
      "anchor" => "phase_gate-head-a",
      "summary" => "Review suite result",
      "status" => "passed",
      "verdict" => "green"
    }

    missing_head_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "missing-head",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => Map.delete(base_args, "head_sha")}
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_head_response, ["error", "data", "reason"]) == "missing_head_sha"

    wrong_package_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "wrong-package",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => Map.put(base_args, "work_package_id", "SYMPP-OTHER")}
        },
        repo: repo,
        session: session
      )

    assert get_in(wrong_package_response, ["error", "data", "reason"]) == "outside_session_scope"

    non_passing_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "non-passing",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => %{base_args | "status" => "failed", "verdict" => "red"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(non_passing_response, ["error", "data", "reason"]) == "non_passing_review_suite_result"
    assert get_in(non_passing_response, ["error", "data", "expected_verdicts"]) == ["green", "clean", "passed", "pass", "success", "approved"]

    arbitrary_payload_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "arbitrary-review-suite-payload",
          "method" => "tools/call",
          "params" => %{
            "name" => "attach_review_suite_result",
            "arguments" => Map.put(base_args, "payload", %{"raw_prompt" => "do not expose", "reviewer_internal" => %{"trace" => "hidden"}})
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(arbitrary_payload_response, ["error", "data", "reason"]) == "unexpected_argument"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-INVALID/worker", "head_sha" => "head-a"})

    assert {:ok, _failed_event} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               idempotency_key: "attach_review_suite_result:#{package.id}:failed-review-suite-head-a",
               summary: "Failed review-suite result",
               status: "review_suite_failed",
               payload: %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => "head-a",
                 "suite" => "review-suite",
                 "anchor" => "phase_gate-head-a-failed",
                 "summary" => "Review suite failed",
                 "status" => "failed",
                 "verdict" => "red"
               }
             })

    failed_override_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "failed-override",
          "method" => "tools/call",
          "params" => %{
            "name" => "attach_review_suite_result",
            "arguments" => Map.put(base_args, "idempotency_key", "failed-override-green")
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(failed_override_response, ["error", "data", "reason"]) == "failed_review_suite_result_exists"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-INVALID/worker", "head_sha" => "head-b"})

    stale_head_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-head",
          "method" => "tools/call",
          "params" => %{"name" => "attach_review_suite_result", "arguments" => base_args}
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_head_response, ["error", "data", "reason"]) == "stale_head_sha"
  end

  test "review evidence accepts clean vocabulary and promotes stale package status to reviewing", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-PROMOTE", kind: "mcp", status: "ready_for_worker")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-PROMOTE/worker", "head_sha" => "review-head-a"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Review package is ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "review-head-a",
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    assert {:ok, promoted_after_review_package} = WorkPackageRepository.get(repo, package.id)
    assert promoted_after_review_package.status == "reviewing"

    assert {:ok, suite_package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-CLEAN", kind: "mcp", status: "ready_for_worker")
             )

    assert {:ok, suite_minted} = AccessGrantService.mint_worker_grant(repo, suite_package.id)
    assert {:ok, suite_assignment} = AccessGrantService.claim(repo, suite_minted.work_key.secret, claimed_by: "worker-2")
    suite_session = MCPHarness.session(suite_assignment, proof_hash: suite_minted.grant.secret_hash)

    attach_tool(repo, suite_session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-CLEAN/worker", "head_sha" => "suite-head-clean"})

    suite_response =
      attach_tool(repo, suite_session, "attach_review_suite_result", %{
        "work_package_id" => suite_package.id,
        "head_sha" => "suite-head-clean",
        "suite" => "review-suite",
        "anchor" => "review-suite-clean",
        "summary" => "Review completed cleanly",
        "status" => "completed",
        "verdict" => "clean"
      })

    assert get_in(suite_response, ["result", "structuredContent", "progress_event", "payload", "status"]) == "completed"
    assert get_in(suite_response, ["result", "structuredContent", "progress_event", "payload", "verdict"]) == "clean"

    assert {:ok, promoted_after_suite} = WorkPackageRepository.get(repo, suite_package.id)
    assert promoted_after_suite.status == "reviewing"
  end

  test "review-suite result idempotent retry replays after current head advances", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-REPLAY", kind: "mcp", status: "ci_waiting", policy_template: "mcp_review_suite_artifact")
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    args = %{
      "work_package_id" => package.id,
      "head_sha" => "head-a",
      "suite" => "review-suite",
      "anchor" => "phase_gate-head-a",
      "summary" => "Review suite result",
      "status" => "passed",
      "verdict" => "green",
      "lane" => "normal",
      "reviewer" => "review-suite",
      "round_id" => "phase_gate-head-a",
      "idempotency_key" => "review-suite-head-a"
    }

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-REPLAY/worker", "head_sha" => "head-a"})
    first_response = attach_tool(repo, session, "attach_review_suite_result", args)
    first_event_id = get_in(first_response, ["result", "structuredContent", "progress_event", "id"])

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-REPLAY/worker", "head_sha" => "head-b"})

    replay_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "review-suite-replay", "method" => "tools/call", "params" => %{"name" => "attach_review_suite_result", "arguments" => args}},
        repo: repo,
        session: session
      )

    assert get_in(replay_response, ["result", "structuredContent", "progress_event", "id"]) == first_event_id

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, minted.grant.id)

    revoked_replay_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "review-suite-revoked-replay", "method" => "tools/call", "params" => %{"name" => "attach_review_suite_result", "arguments" => args}},
        repo: repo,
        session: session
      )

    assert get_in(revoked_replay_response, ["error", "data", "reason"]) == "revoked"
  end

  test "review-suite readiness uses chronological latest result for the current head", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-REVIEW-SUITE-ORDER", kind: "mcp", status: "ci_waiting", policy_template: "mcp_review_suite_artifact")
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-ORDER/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/901", "head_sha" => "head-a"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    assert {:ok, _artifact} =
             PlanningRepository.append_artifact(repo, %{
               "id" => review_suite_artifact_id(package.id, "head-a"),
               "work_package_id" => package.id,
               "path" => "review-suite-result.json",
               "title" => "Review-suite result",
               "kind" => "review_suite"
             })

    assert {:ok, _newer_passed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:chronological-pass",
               "summary" => "Newer review-suite result passed",
               "status" => "review_suite_passed",
               "created_at" => ~U[2026-05-05 00:00:10Z],
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => "head-a",
                 "suite" => "review-suite",
                 "anchor" => "phase_gate-head-a-pass",
                 "summary" => "Newer review suite passed",
                 "status" => "passed",
                 "verdict" => "green"
               }
             })

    assert {:ok, _older_failed_event} =
             PlanningRepository.append_progress_event(repo, %{
               "work_package_id" => package.id,
               "idempotency_key" => "attach_review_suite_result:#{package.id}:chronological-fail",
               "summary" => "Older review-suite result failed",
               "status" => "review_suite_failed",
               "created_at" => ~U[2026-05-05 00:00:00Z],
               "payload" => %{
                 "type" => "review_suite_result",
                 "source_tool" => "attach_review_suite_result",
                 "work_package_id" => package.id,
                 "head_sha" => "head-a",
                 "suite" => "review-suite",
                 "anchor" => "phase_gate-head-a-fail",
                 "summary" => "Older review suite failed",
                 "status" => "failed",
                 "verdict" => "red"
               }
             })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-review-suite-order", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "stale and spoofed review-suite evidence cannot satisfy required readiness", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-REVIEW-SUITE-SPOOF",
                 kind: "mcp",
                 status: "ci_waiting",
                 policy_template: "mcp_review_suite_artifact"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-SPOOF/worker", "head_sha" => "head-a"})

    attach_tool(repo, session, "attach_review_suite_result", %{
      "work_package_id" => package.id,
      "head_sha" => "head-a",
      "suite" => "review-suite",
      "anchor" => "phase_gate-head-a",
      "summary" => "Old head review suite",
      "status" => "passed",
      "verdict" => "green"
    })

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-SUITE-SPOOF/worker", "head_sha" => "head-b"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/901", "head_sha" => "head-b"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review package",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => "head-b",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Spoofed review-suite JSON",
      "idempotency_key" => "spoof-review-suite-json",
      "payload" => %{
        "type" => "review_suite_result",
        "source_tool" => "attach_review_suite_result",
        "work_package_id" => package.id,
        "head_sha" => "head-b",
        "suite" => "review-suite",
        "anchor" => "phase_gate-head-b",
        "status" => "passed",
        "verdict" => "green"
      }
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-spoofed-review-suite", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(ready_response, ["error", "data", "missing"])
    assert "review_suite_result" in missing
    refute "review_package_submitted" in missing
  end

  test "mark_ready rejects empty review packages and allows resolved blockers", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-BLOCKER", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    empty_review_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "empty-review", "method" => "tools/call", "params" => %{"name" => "submit_review_package", "arguments" => %{}}},
        repo: repo,
        session: session
      )

    assert get_in(empty_review_response, ["error", "data", "reason"]) == "missing_summary"

    invalid_blocker_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "report_blocker",
            "arguments" => %{"summary" => "Invalid blocker", "idempotency_key" => "invalid-blocker", "blocker_id" => 1}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_blocker_response, ["error", "data", "reason"]) == "invalid_blocker_id"

    attach_tool(repo, session, "append_progress", %{"summary" => "Progress with shared retry key", "idempotency_key" => "blocker-1"})

    blocker_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "report_blocker",
            "arguments" => %{"summary" => "Temporarily blocked", "idempotency_key" => "blocker-1", "blocker_id" => "blocker-1 "}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(blocker_response, ["result", "structuredContent", "progress_event", "payload", "active"]) == true
    assert get_in(blocker_response, ["result", "structuredContent", "progress_event", "payload", "blocker_id"]) == "blocker-1"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-BLOCKER/worker", "head_sha" => "abc125"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/125", "head_sha" => "abc125"})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/125", "abc125")

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc125",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    blocked_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-blocked", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "no_active_blockers" in get_in(blocked_response, ["error", "data", "missing"])
    assert Enum.any?(get_in(blocked_response, ["error", "data", "reasons"]), &(&1["gate"] == "no_active_blockers"))

    resolved_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "resolve",
          "method" => "tools/call",
          "params" => %{
            "name" => "resolve_blocker",
            "arguments" => %{"blocker_id" => "blocker-1", "resolution" => "Unblocked", "summary" => "Resolved", "idempotency_key" => "resolve-1"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(resolved_response, ["result", "structuredContent", "progress_event", "payload", "active"]) == false

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-resolved", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "mark_ready does not require review-package metadata for non-merge-gated policies", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-QUICK-FIX", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(response, ["error", "data", "missing"])
    assert get_in(response, ["error", "data", "reason"]) == "readiness_failed"
    refute "plan_complete" in missing
    refute "branch_attached" in missing
    refute "pr_attached" in missing
    refute "review_package_submitted" in missing
    assert "tests_passed" in missing
    assert "review_lanes_complete" in missing

    attach_tool(repo, session, "request_scope_expansion", %{
      "summary" => "Unrelated scope request",
      "status" => "tests_passed",
      "payload" => %{"lane" => "brief", "verdict" => "green"},
      "idempotency_key" => "quick-fix-unrelated-status"
    })

    unrelated_status_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix-unrelated-status", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    unrelated_missing = get_in(unrelated_status_response, ["error", "data", "missing"])
    assert "tests_passed" in unrelated_missing
    assert "review_lanes_complete" in unrelated_missing

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed",
      "status" => "tests_passed",
      "idempotency_key" => "quick-fix-tests"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "brief review green",
      "status" => "review_brief_green",
      "idempotency_key" => "quick-fix-review-brief"
    })

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-QUICK-FIX/worker", "head_sha" => "quick-fix-head-b"})

    stale_progress_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix-stale-progress", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    stale_progress_missing = get_in(stale_progress_response, ["error", "data", "missing"])
    assert "tests_passed" in stale_progress_missing
    assert "review_lanes_complete" in stale_progress_missing

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed for latest head",
      "status" => "tests_passed",
      "idempotency_key" => "quick-fix-tests-head-b"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "brief review green for latest head",
      "status" => "review_brief_green",
      "idempotency_key" => "quick-fix-review-brief-head-b"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests failed after latest pass",
      "status" => "tests_failed",
      "idempotency_key" => "quick-fix-tests-head-b-failed"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "brief review red after latest green",
      "status" => "review_brief_red",
      "idempotency_key" => "quick-fix-review-brief-head-b-red"
    })

    stale_green_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix-stale-green", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    stale_green_missing = get_in(stale_green_response, ["error", "data", "missing"])
    assert "tests_passed" in stale_green_missing
    assert "review_lanes_complete" in stale_green_missing

    attach_tool(repo, session, "append_progress", %{
      "summary" => "Focused tests passed after failure",
      "status" => "tests_passed",
      "idempotency_key" => "quick-fix-tests-head-b-repassed"
    })

    attach_tool(repo, session, "append_progress", %{
      "summary" => "brief review green after red",
      "status" => "review_brief_green",
      "idempotency_key" => "quick-fix-review-brief-head-b-regreen"
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-quick-fix-after-progress", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_human_merge"
  end
end
