Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools03Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "mark_ready enforces worker readiness gates", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-GATES", kind: "mcp", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(missing_response, ["error", "data", "reason"]) == "readiness_failed"
    assert "pr_attached" in get_in(missing_response, ["error", "data", "missing"])
    assert Enum.any?(get_in(missing_response, ["error", "data", "reasons"]), &(&1["gate"] == "plan_complete"))

    bypass_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "ready-bypass",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"status" => "ready_for_human_merge", "expected_status" => "ci_waiting"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(bypass_response, ["error", "data", "reason"]) == "use_mark_ready"
    assert {:ok, unchanged_package} = WorkPackageRepository.get(repo, package.id)
    assert unchanged_package.status == "ci_waiting"

    attach_tool(repo, session, "append_progress", %{"summary" => "Shared key baseline", "idempotency_key" => "shared-metadata-key"})

    missing_head_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "missing-pr-head",
          "method" => "tools/call",
          "params" => %{"name" => "attach_pr", "arguments" => %{"url" => "https://github.com/example/repo/pull/123"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_head_response, ["error", "data", "reason"]) == "missing_head_sha"

    pre_metadata_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pre-metadata-headless-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Headless review before metadata",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(pre_metadata_review_response, ["error", "data", "reason"]) == "missing_head_sha"

    pre_branch_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pre-branch-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Review before branch head",
              "tests" => ["mix test"],
              "artifacts" => ["pre-branch-review-log.txt"],
              "head_sha" => "abc123",
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(pre_branch_review_response, ["error", "data", "reason"]) == "missing_current_head_sha"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-GATES/worker", "head_sha" => " abc123 ", "idempotency_key" => "shared-metadata-key"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/123", "head_sha" => " abc123 "})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/123", "abc123")

    headless_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "headless-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Headless review",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(headless_review_response, ["error", "data", "reason"]) == "missing_head_sha"

    missing_acceptance_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-acceptance", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "acceptance_criteria_met" in get_in(missing_acceptance_response, ["error", "data", "missing"])

    trimmed_review_response =
      attach_tool(repo, session, "submit_review_package", %{
        "summary" => "Trimmed review values",
        "tests" => [" mix test "],
        "artifacts" => [" review-log.txt "],
        "head_sha" => " abc123 ",
        "reviews" => []
      })

    assert get_in(trimmed_review_response, ["result", "structuredContent", "progress_event", "payload", "tests"]) == ["mix test"]
    assert get_in(trimmed_review_response, ["result", "structuredContent", "progress_event", "payload", "artifacts"]) == ["review-log.txt"]

    assert {:ok, trimmed_artifacts} = PlanningRepository.list_artifacts(repo, package.id)
    assert Enum.any?(trimmed_artifacts, &(&1.path == "review-log.txt"))

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test", "brief green"],
      "artifacts" => ["review-brief-log.txt"],
      "head_sha" => "abc123",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
    })

    repo.delete_all(Artifact)

    missing_review_lanes_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-missing-review-lanes", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(missing_review_lanes_response, ["error", "data", "missing"])

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready after normal",
      "tests" => ["mix test", "normal green"],
      "artifacts" => ["review-normal-log.txt"],
      "head_sha" => "abc123",
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    incremental_review_lanes_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-incremental-review-lanes", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    incremental_missing = get_in(incremental_review_lanes_response, ["error", "data", "missing"])
    refute "review_lanes_complete" in incremental_missing
    assert "acceptance_criteria_met" in incremental_missing
    refute "review_artifacts_attached" in incremental_missing
    assert "plan_complete" in incremental_missing

    malformed_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "malformed-review-entries",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Malformed review",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [%{"lane" => 1, "verdict" => "green"}, %{"lane" => "normal", "verdict" => nil}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(malformed_review_response, ["error", "data", "reason"]) == "invalid_reviews"

    extra_review_key_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "extra-review-key",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Extra review key",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [%{"lane" => "brief", "verdict" => "green", "note" => "typo"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(extra_review_key_response, ["error", "data", "reason"]) == "invalid_reviews"

    duplicate_review_lane_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "duplicate-review-lane",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Duplicate review lane",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [
                %{"lane" => " brief ", "verdict" => "red"},
                %{"lane" => "brief", "verdict" => "green"}
              ]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(duplicate_review_lane_response, ["error", "data", "reason"]) == "invalid_reviews"

    missing_artifacts_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "ready-missing-artifacts",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Ready without artifacts",
              "tests" => ["mix test"],
              "artifacts" => [],
              "head_sha" => "abc123",
              "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_artifacts_response, ["error", "data", "reason"]) == "missing_artifacts"

    blank_artifact_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "blank-artifact",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Blank artifact",
              "tests" => ["mix test"],
              "artifacts" => [" "],
              "head_sha" => "abc123",
              "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(blank_artifact_response, ["error", "data", "reason"]) == "invalid_artifacts"

    malformed_reviews_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "malformed-reviews",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Malformed reviews",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => %{"lane" => "brief", "verdict" => "green"}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(malformed_reviews_response, ["error", "data", "reason"]) == "invalid_reviews"

    invalid_acceptance_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-acceptance",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Invalid acceptance",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => "true",
              "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_acceptance_response, ["error", "data", "reason"]) == "invalid_acceptance_criteria_met"

    invalid_tests_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-tests",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Invalid tests",
              "tests" => [" "],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_tests_response, ["error", "data", "reason"]) == "invalid_tests"

    invalid_head_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "invalid-head-sha",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Invalid head",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => 123,
              "reviews" => []
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(invalid_head_response, ["error", "data", "reason"]) == "invalid_head_sha"

    sibling_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sibling-review-package",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "work_package_id" => "SYMPP-OTHER",
              "summary" => "Wrong package",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(sibling_review_response, ["error", "data", "reason"]) == "outside_session_scope"

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc123",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    handoff_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "handoff-with-review-artifact",
          "method" => "resources/read",
          "params" => %{"uri" => "sympp://work-packages/SYMPP-READY-GATES/handoff.md"}
        },
        repo: repo,
        session: session
      )

    assert get_in(handoff_response, ["result", "contents", Access.at(0), "text"]) =~ "review-log.txt"

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Latest review has findings",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc123",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
    })

    latest_missing_lane_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-latest-missing-lane", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    latest_missing_lane_missing = get_in(latest_missing_lane_response, ["error", "data", "missing"])
    assert "review_lanes_complete" in latest_missing_lane_missing
    assert "plan_complete" in latest_missing_lane_missing

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Latest review has findings",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "abc123",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "findings"}]
    })

    latest_findings_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-latest-findings", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_lanes_complete" in get_in(latest_findings_response, ["error", "data", "missing"])

    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/123", "head_sha" => "def456"})
    sync_pr_state(repo, session, "https://github.com/example/repo/pull/123", "def456")
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-READY-GATES/worker", "head_sha" => "def456"})

    stale_submit_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-review-submit",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Stale review",
              "tests" => ["mix test"],
              "artifacts" => ["review-log.txt"],
              "head_sha" => "abc123",
              "acceptance_criteria_met" => true,
              "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_submit_response, ["error", "data", "reason"]) == "stale_head_sha"

    stale_review_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-stale-review", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    stale_review_missing = get_in(stale_review_response, ["error", "data", "missing"])
    assert "review_package_submitted" in stale_review_missing
    assert "review_lanes_complete" in stale_review_missing

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready",
      "tests" => ["mix test"],
      "artifacts" => ["review-log.txt"],
      "head_sha" => "def456",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => " review_t2 ", "verdict" => " green "}]
    })

    empty_plan_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-empty-plan", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "plan_complete" in get_in(empty_plan_response, ["error", "data", "missing"])
    append_done_plan(repo, package.id)

    pre_ready_finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pre-ready-finding",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Finding before ready", "body" => "Recorded before ready", "idempotency_key" => "pre-ready-finding"}
          }
        },
        repo: repo,
        session: session
      )

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_human_merge"

    post_ready_branch_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-branch",
          "method" => "tools/call",
          "params" => %{"name" => "attach_branch", "arguments" => %{"branch" => "agent/SYMPP-READY-GATES/worker", "head_sha" => "new-ready-head"}}
        },
        repo: repo,
        session: session
      )

    post_ready_review_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Red after ready",
              "tests" => ["mix test"],
              "artifacts" => ["red-after-ready.txt"],
              "head_sha" => "def456",
              "acceptance_criteria_met" => false,
              "reviews" => [%{"lane" => "brief", "verdict" => "red"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    post_ready_blocker_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-blocker",
          "method" => "tools/call",
          "params" => %{
            "name" => "report_blocker",
            "arguments" => %{"summary" => "Blocked after ready", "idempotency_key" => "post-ready-blocker"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_progress_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-progress",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_progress",
            "arguments" => %{"summary" => "Progress after ready", "idempotency_key" => "post-ready-progress"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_finding_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-finding",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Finding after ready", "body" => "Too late", "idempotency_key" => "post-ready-finding"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_finding_replay_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pre-ready-finding-replay",
          "method" => "tools/call",
          "params" => %{
            "name" => "append_finding",
            "arguments" => %{"title" => "Finding before ready", "body" => "Recorded before ready", "idempotency_key" => "pre-ready-finding"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_scope_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-scope",
          "method" => "tools/call",
          "params" => %{
            "name" => "request_scope_expansion",
            "arguments" => %{"summary" => "Scope after ready", "idempotency_key" => "post-ready-scope"}
          }
        },
        repo: repo,
        session: session
      )

    post_ready_plan_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "post-ready-plan",
          "method" => "tools/call",
          "params" => %{
            "name" => "update_task_plan",
            "arguments" => %{"expected_version" => 1, "title" => "Plan after ready"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(post_ready_branch_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_review_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_blocker_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_progress_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_finding_response, ["error", "data", "reason"]) == "already_ready"

    assert get_in(pre_ready_finding_response, ["result", "structuredContent", "finding", "id"]) ==
             get_in(post_ready_finding_replay_response, ["result", "structuredContent", "finding", "id"])

    assert get_in(post_ready_scope_response, ["error", "data", "reason"]) == "already_ready"
    assert get_in(post_ready_plan_response, ["error", "data", "reason"]) == "already_ready"
    assert {:ok, ready_package} = WorkPackageRepository.get(repo, package.id)
    assert ready_package.status == "ready_for_human_merge"
  end

  test "mark_ready does not require ci_waiting when package policy omits CI", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-READY-NO-CI", kind: "mcp", status: "reviewing"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-no-ci-missing", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(missing_response, ["error", "data", "missing"])
    refute "status_ci_waiting" in missing
    assert "plan_complete" in missing
    assert "acceptance_criteria_met" in missing
    assert "tests_passed" in missing
    assert "pr_attached" in missing
    assert "review_package_submitted" in missing
    assert "review_lanes_complete" in missing

    append_merge_ready_evidence(repo, session, package.id, "head-no-ci")

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-no-ci", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_human_merge"
  end

  test "mark_ready still requires ci_waiting when package policy requires CI", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-CI-REQUIRED", kind: "mcp", status: "reviewing", policy_template: "mcp_ci_required")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    append_merge_ready_evidence(repo, session, package.id, "head-ci-required")

    reviewing_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-ci-required-reviewing", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(reviewing_response, ["error", "data", "reason"]) == "readiness_failed"
    assert get_in(reviewing_response, ["error", "data", "missing"]) == ["status_ci_waiting"]

    transition_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "ci-required-transition",
          "method" => "tools/call",
          "params" => %{"name" => "set_status", "arguments" => %{"expected_status" => "reviewing", "status" => "ci_waiting"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(transition_response, ["result", "structuredContent", "work_package", "status"]) == "ci_waiting"

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-ci-required", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
    assert get_in(ready_response, ["result", "structuredContent", "work_package", "status"]) == "ready_for_human_merge"
  end

  test "state machine blocks ready transitions from reviewing when package policy requires CI", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-READY-CI-STATE-MACHINE", kind: "mcp", status: "reviewing", policy_template: "mcp_ci_required")
             )

    actor = %{grant_role: "worker", capabilities: ["worker:lifecycle.transition"], work_package_id: package.id}

    assert {:error, :invalid_transition} =
             StateMachine.validate_ready_transition(package, "ready_for_human_merge", actor)

    ci_waiting_package = %{package | status: "ci_waiting"}
    assert :ok = StateMachine.validate_ready_transition(ci_waiting_package, "ready_for_human_merge", actor)
  end
end
