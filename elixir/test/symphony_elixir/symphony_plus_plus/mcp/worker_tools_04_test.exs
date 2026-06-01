Code.require_file("../../../support/symphony_plus_plus/mcp_case.exs", __DIR__)

defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools04Test do
  use SymphonyElixir.SymphonyPlusPlus.MCPCase

  test "review package submitted before PR attach does not satisfy later PR readiness", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PRE-PR-REVIEW", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PRE-PR-REVIEW/worker", "head_sha" => "pre-pr-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Pre-PR review",
      "tests" => ["mix test"],
      "artifacts" => ["pre-pr-review.txt"],
      "head_sha" => "pre-pr-head",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/456", "head_sha" => "later-head"})

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-pr-attach", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(ready_response, ["error", "data", "missing"])
    assert "pr_attached" in missing
    refute "review_lanes_complete" in missing
    refute "review_artifacts_attached" in missing
  end

  test "branch-only readiness rejects review evidence from an older branch head", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-BRANCH-HEAD-REVIEW", kind: "quick_fix", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-BRANCH-HEAD-REVIEW/worker", "head_sha" => "old-head"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Old head review",
      "tests" => ["mix test"],
      "artifacts" => ["old-head-review.txt"],
      "head_sha" => "old-head",
      "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
    })

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-BRANCH-HEAD-REVIEW/worker", "head_sha" => "new-head"})

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(ready_response, ["error", "data", "missing"])
    assert "review_lanes_complete" in missing
  end

  test "submit_review_package replay remains idempotent after branch head changes", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REVIEW-REPLAY", kind: "mcp", status: "ci_waiting"))

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-REPLAY/worker", "head_sha" => "head-a"})

    review_arguments = %{
      "summary" => "Review head A",
      "tests" => ["mix test"],
      "artifacts" => ["review-head-a.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    }

    first_response = attach_tool(repo, session, "submit_review_package", review_arguments)
    first_event_id = get_in(first_response, ["result", "structuredContent", "progress_event", "id"])

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-REPLAY/worker", "head_sha" => "head-b"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/791", "head_sha" => "head-b"})

    retry_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "retry-review-head-a",
          "method" => "tools/call",
          "params" => %{"name" => "submit_review_package", "arguments" => review_arguments}
        },
        repo: repo,
        session: session
      )

    assert get_in(retry_response, ["result", "structuredContent", "progress_event", "id"]) == first_event_id

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-replay", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "review_package_submitted" in get_in(ready_response, ["error", "data", "missing"])
  end

  test "submit_review_package exact replay survives worker grant renewal", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-REVIEW-REGRANT", kind: "mcp", status: "ci_waiting"))

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-REVIEW-REGRANT/worker", "head_sha" => "head-a"})

    review_arguments = %{
      "summary" => "Review head A",
      "tests" => ["mix test"],
      "artifacts" => ["review-head-a.txt"],
      "head_sha" => "head-a",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    }

    first_response = attach_tool(repo, session, "submit_review_package", review_arguments)
    first_event_id = get_in(first_response, ["result", "structuredContent", "progress_event", "id"])

    assert {:ok, second_minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, second_assignment} = AccessGrantService.claim(repo, second_minted.work_key.secret, claimed_by: "worker-2")
    second_session = MCPHarness.session(second_assignment, proof_hash: second_minted.grant.secret_hash)

    retry_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "retry-review-regrant",
          "method" => "tools/call",
          "params" => %{"name" => "submit_review_package", "arguments" => review_arguments}
        },
        repo: repo,
        session: second_session
      )

    assert get_in(retry_response, ["result", "structuredContent", "progress_event", "id"]) == first_event_id

    assert {:ok, progress_events} = PlanningRepository.list_progress_events(repo, package.id)

    assert 1 ==
             Enum.count(progress_events, fn event ->
               event.status == "review_package_submitted" and event.payload["head_sha"] == "head-a"
             end)
  end

  test "metadata attachments require a scoped live session", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-METADATA-SCOPE", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, sibling_package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-METADATA-SIBLING", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_session_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "branch-missing-session",
          "method" => "tools/call",
          "params" => %{"name" => "attach_branch", "arguments" => %{"branch" => "agent/SYMPP-METADATA-SCOPE/worker", "head_sha" => "head-a"}}
        },
        repo: repo
      )

    assert get_in(missing_session_response, ["error", "data", "reason"]) == "claim_required"

    stale_scope_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "pr-wrong-package",
          "method" => "tools/call",
          "params" => %{
            "name" => "attach_pr",
            "arguments" => %{"work_package_id" => sibling_package.id, "url" => "https://github.com/example/repo/pull/792", "head_sha" => "head-a"}
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_scope_response, ["error", "data", "reason"]) == "outside_session_scope"
  end

  test "metadata tools honor caller idempotency keys for repeated matching payloads", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-METADATA-IDEMPOTENCY", kind: "quick_fix", status: "ci_waiting"))
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-METADATA-IDEMPOTENCY/worker", "head_sha" => "same-head", "idempotency_key" => "branch-key-1"})
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-METADATA-IDEMPOTENCY/worker", "head_sha" => "same-head", "idempotency_key" => "branch-key-2"})

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)

    assert events
           |> Enum.filter(&(get_in(&1.payload, ["type"]) == "branch" and get_in(&1.payload, ["head_sha"]) == "same-head"))
           |> length() == 2
  end

  test "sync_pr stores dry GitHub metadata and deterministic artifact", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-SYNC",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 status: "ci_waiting"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_pr", %{"number" => 42, "head_sha" => "sync-head"})

    sync_request = %{
      "jsonrpc" => "2.0",
      "id" => "sync-pr-replay-mismatch",
      "method" => "tools/call",
      "params" => %{
        "name" => "sync_pr",
        "arguments" => %{
          "number" => 42,
          "metadata" => %{
            "head_sha" => "sync-head",
            "branch" => "agent/SYMPP-P6-001/github-pr-attachment-sync",
            "changed_files" => [%{"filename" => "elixir/lib/symphony_elixir/symphony_plus_plus/github/client.ex", "status" => "added"}],
            "check_summary" => %{"conclusion" => "success", "token" => "ghp_should_not_surface_nested"},
            "review_state" => %{"state" => "approved"},
            "merge_state" => %{"state" => "clean"},
            "token" => "ghp_should_not_surface"
          }
        }
      }
    }

    response = MCPHarness.request(sync_request, repo: repo, session: session)

    payload = get_in(response, ["result", "structuredContent", "progress_event", "payload"])

    assert payload["repository"] == "nextide/symphony-plus-plus"
    assert payload["number"] == 42
    assert payload["url"] == "https://github.com/nextide/symphony-plus-plus/pull/42"
    assert payload["head_sha"] == "sync-head"

    assert payload["changed_files"] == [
             %{"path" => "elixir/lib/symphony_elixir/symphony_plus_plus/github/client.ex", "status" => "added"}
           ]

    assert payload["changed_files_count"] == 1
    refute inspect(payload) =~ "ghp_should_not_surface"
    idempotency_key = get_in(response, ["result", "structuredContent", "progress_event", "idempotency_key"])
    refute idempotency_key =~ "ghp_should_not_surface"

    [_prefix, encoded_key_payload] = String.split(idempotency_key, "mcp:pr:", parts: 2)
    decoded_key_payload = encoded_key_payload |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term()

    refute inspect(decoded_key_payload) =~ "ghp_should_not_surface"
    assert payload["check_summary"]["token"] == "[REDACTED]"
    event_id = get_in(response, ["result", "structuredContent", "progress_event", "id"])

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)
    assert Enum.any?(artifacts, &(&1.kind == "github_pr" and &1.path == "github-pr.json" and &1.uri == payload["url"]))

    attach_tool(repo, session, "attach_pr", %{"number" => 43, "head_sha" => "sync-head"})

    replay_response = MCPHarness.request(sync_request, repo: repo, session: session)

    assert get_in(replay_response, ["result", "structuredContent", "progress_event", "id"]) == event_id

    assert {:ok, artifacts} = PlanningRepository.list_artifacts(repo, package.id)
    pr_artifacts = Enum.filter(artifacts, &(&1.kind == "github_pr" and &1.path == "github-pr.json"))

    assert length(pr_artifacts) == 1
    assert [%{uri: "https://github.com/nextide/symphony-plus-plus/pull/43"}] = pr_artifacts
  end

  test "sync_pr replay after different attach is cached but not current readiness evidence", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-SYNC-REPLAY-CURRENT",
                 kind: "mcp",
                 repo: "nextide/symphony-plus-plus",
                 status: "ci_waiting",
                 policy_template: "mcp_current_pr_state"
               )
             )

    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    head_sha = "abcdef1234567890abcdef1234567890abcdef12"

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-SYNC-REPLAY-CURRENT/worker", "head_sha" => head_sha})
    attach_tool(repo, session, "attach_pr", %{"number" => 42, "head_sha" => head_sha})

    sync_request = %{
      "jsonrpc" => "2.0",
      "id" => "sync-pr-replay-current",
      "method" => "tools/call",
      "params" => %{
        "name" => "sync_pr",
        "arguments" => %{
          "number" => 42,
          "metadata" => %{"head_sha" => head_sha, "check_summary" => %{"conclusion" => "success"}}
        }
      }
    }

    sync_response = MCPHarness.request(sync_request, repo: repo, session: session)
    event_id = get_in(sync_response, ["result", "structuredContent", "progress_event", "id"])

    attach_tool(repo, session, "attach_pr", %{"number" => 43, "head_sha" => head_sha})

    replay_response = MCPHarness.request(sync_request, repo: repo, session: session)
    assert get_in(replay_response, ["result", "structuredContent", "progress_event", "id"]) == event_id

    new_old_sync_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync-pr-old-new-request",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{
              "number" => 42,
              "metadata" => %{"head_sha" => head_sha, "check_summary" => %{"conclusion" => "success"}},
              "idempotency_key" => "new-old-sync"
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(new_old_sync_response, ["error", "data", "reason"]) == "pr_mismatch"

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Ready review",
      "tests" => ["mix test"],
      "artifacts" => ["review.txt"],
      "head_sha" => head_sha,
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-replayed-old-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert "current_pr_state" in get_in(ready_response, ["error", "data", "missing"])

    attach_tool(repo, session, "sync_pr", %{
      "number" => 43,
      "metadata" => %{"head_sha" => head_sha, "check_summary" => %{"conclusion" => "success"}}
    })

    ready_after_current_sync =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready-after-current-sync", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_after_current_sync, ["result", "structuredContent", "ready"]) == true
  end

  test "attach_pr number requires unambiguous repository context for short package repos", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(
                 id: "SYMPP-PR-NUMBER-SHORT-REPO",
                 kind: "mcp",
                 repo: "symphony-plus-plus",
                 status: "ci_waiting"
               )
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_context =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "attach_pr",
          "method" => "tools/call",
          "params" => %{"name" => "attach_pr", "arguments" => %{"number" => 42, "head_sha" => "head-a"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_context, ["error", "data", "reason"]) == "missing_repository_use_url_or_owner_repo"

    explicit_repository =
      attach_tool(repo, session, "attach_pr", %{"number" => "42", "repository" => "nextide/symphony-plus-plus", "head_sha" => "head-a"})

    assert get_in(explicit_repository, ["result", "structuredContent", "progress_event", "payload", "url"]) ==
             "https://github.com/nextide/symphony-plus-plus/pull/42"

    url_package =
      WorkPackageFactory.attrs(
        id: "SYMPP-PR-URL-SHORT-REPO",
        kind: "mcp",
        repo: "symphony-plus-plus",
        status: "ci_waiting"
      )

    assert {:ok, url_package} = WorkPackageRepository.create(repo, url_package)
    assert {:ok, url_minted} = AccessGrantService.mint_worker_grant(repo, url_package.id)
    assert {:ok, url_assignment} = AccessGrantService.claim(repo, url_minted.work_key.secret, claimed_by: "worker-1")
    url_session = MCPHarness.session(url_assignment, proof_hash: url_minted.grant.secret_hash)

    url_response =
      attach_tool(repo, url_session, "attach_pr", %{"url" => "https://github.com/nextide/symphony-plus-plus/pull/43", "head_sha" => "head-a"})

    assert get_in(url_response, ["result", "structuredContent", "progress_event", "payload", "number"]) == 43
  end

  test "attach_pr idempotency replay accepts legacy URL-only payload shape", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-LEGACY-REPLAY", kind: "standard_pr", repo: "nextide/symphony-plus-plus", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)
    idempotency_key = "attach_pr:#{package.id}:legacy-pr-key"

    assert {:ok, legacy_event} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "pr_attached",
               status: "pr_attached",
               idempotency_key: idempotency_key,
               payload: %{
                 type: "pr",
                 source_tool: "attach_pr",
                 url: "https://github.com/nextide/symphony-plus-plus/pull/42",
                 head_sha: "legacy-head"
               }
             })

    response =
      attach_tool(repo, session, "attach_pr", %{
        "number" => 42,
        "head_sha" => "legacy-head",
        "idempotency_key" => "legacy-pr-key"
      })

    assert get_in(response, ["result", "structuredContent", "progress_event", "id"]) == legacy_event.id

    assert {:ok, events} = PlanningRepository.list_progress_events(repo, package.id)
    assert Enum.count(events, &(&1.idempotency_key == idempotency_key)) == 1
  end

  test "sync_pr malformed metadata returns structured MCP error", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-METADATA-ERROR", kind: "standard_pr", repo: "nextide/symphony-plus-plus", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync_pr",
          "method" => "tools/call",
          "params" => %{"name" => "sync_pr", "arguments" => %{"number" => 42, "metadata" => "bad"}}
        },
        repo: repo,
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_602
    assert get_in(response, ["error", "data", "tool"]) == "sync_pr"
    assert get_in(response, ["error", "data", "reason"]) == "missing_metadata"
  end

  test "sync_pr preserves service error shape for PR metadata lookup failures" do
    session =
      Session.new(
        %Assignment{
          grant_id: "grant-pr-sync-service",
          work_package_id: "SYMPP-PR-SERVICE-ERROR",
          display_key: "ABCD",
          grant_role: "worker",
          capabilities: ["read:own", "write:own"],
          claimed_at: ~U[2026-05-05 00:00:00Z],
          claimed_by: "worker-1"
        },
        proof_hash: "proof"
      )

    response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync-pr-service-error",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{"number" => 42, "metadata" => %{"head_sha" => "head-a"}}
          }
        },
        repo: BusyPrSyncRepo,
        session: session
      )

    assert get_in(response, ["error", "code"]) == -32_000
    assert get_in(response, ["error", "data", "resource"]) == "sync_pr"
    assert get_in(response, ["error", "data", "reason"]) == "ledger_unavailable"
  end

  test "sync_pr requires an attached matching PR and metadata head", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-SYNC-BOUNDARY", kind: "standard_pr", repo: "nextide/symphony-plus-plus", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    missing_attach =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync_pr",
          "method" => "tools/call",
          "params" => %{"name" => "sync_pr", "arguments" => %{"number" => 42, "metadata" => %{"head_sha" => "abc123"}}}
        },
        repo: repo,
        session: session
      )

    assert get_in(missing_attach, ["error", "data", "reason"]) == "missing_attached_pr"

    attach_tool(repo, session, "attach_pr", %{"number" => 42, "head_sha" => "abc123"})

    cased_ref =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync_pr_cased_ref",
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_pr",
            "arguments" => %{
              "url" => "https://github.com/NextIDE/Symphony-Plus-Plus/pull/42",
              "metadata" => %{"head_sha" => "abc123"}
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(cased_ref, ["result", "structuredContent", "progress_event", "payload", "repository"]) == "NextIDE/Symphony-Plus-Plus"

    mismatch =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync_pr",
          "method" => "tools/call",
          "params" => %{"name" => "sync_pr", "arguments" => %{"number" => 43, "metadata" => %{"head_sha" => "abc123"}}}
        },
        repo: repo,
        session: session
      )

    assert get_in(mismatch, ["error", "data", "reason"]) == "pr_mismatch"

    top_level_head =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "sync_pr",
          "method" => "tools/call",
          "params" => %{"name" => "sync_pr", "arguments" => %{"number" => 42, "head_sha" => "abc123", "metadata" => %{}}}
        },
        repo: repo,
        session: session
      )

    assert get_in(top_level_head, ["result", "structuredContent", "progress_event", "payload", "head_sha"]) == "abc123"
  end

  test "sync_pr resolves URL-only attached PRs by chronology", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-SYNC-CHRONOLOGY", kind: "standard_pr", repo: "nextide/symphony-plus-plus", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    assert {:ok, _current_attach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Current PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/symphony-plus-plus/pull/43", head_sha: "head-a"},
               created_at: ~U[2026-05-05 00:00:02Z]
             })

    assert {:ok, _backfilled_old_attach} =
             PlanningRepository.append_progress_event(repo, %{
               work_package_id: package.id,
               summary: "Backfilled old PR attached",
               status: "pr_attached",
               payload: %{type: "pr", source_tool: "attach_pr", url: "https://github.com/nextide/symphony-plus-plus/pull/42", head_sha: "head-a"},
               created_at: ~U[2026-05-05 00:00:01Z]
             })

    response =
      attach_tool(repo, session, "sync_pr", %{
        "number" => 43,
        "metadata" => %{"head_sha" => "head-a", "branch" => "agent/SYMPP-P6-001/github-pr-attachment-sync"}
      })

    assert get_in(response, ["result", "structuredContent", "progress_event", "payload", "number"]) == 43
  end

  test "sync_pr resolves PR numbers from standard metadata when package repo is short", %{repo: repo} do
    assert {:ok, package} =
             WorkPackageRepository.create(
               repo,
               WorkPackageFactory.attrs(id: "SYMPP-PR-SYNC-SHORT-REPO", kind: "mcp", repo: "symphony-plus-plus", status: "ci_waiting")
             )

    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/nextide/symphony-plus-plus/pull/43", "head_sha" => "head-a"})

    response =
      attach_tool(repo, session, "sync_pr", %{
        "number" => 43,
        "metadata" => %{
          "head" => %{"sha" => "head-a", "ref" => "agent/SYMPP-P6-001/github-pr-attachment-sync"},
          "base" => %{"repo" => %{"full_name" => "nextide/symphony-plus-plus"}},
          "state" => "open",
          "mergeable_state" => "clean"
        }
      })

    payload = get_in(response, ["result", "structuredContent", "progress_event", "payload"])

    assert payload["repository"] == "nextide/symphony-plus-plus"
    assert payload["number"] == 43
    assert payload["merge_state"] == %{"mergeable_state" => "clean", "state" => "open"}

    attached_ref_response =
      attach_tool(repo, session, "sync_pr", %{
        "number" => 43,
        "metadata" => %{
          "head_sha" => "head-a",
          "check_summary" => %{"conclusion" => "success"}
        },
        "idempotency_key" => "number-only-from-attach"
      })

    assert get_in(attached_ref_response, ["result", "structuredContent", "progress_event", "payload", "repository"]) ==
             "nextide/symphony-plus-plus"
  end

  test "latest branch head supersedes earlier PR head for review evidence", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-PR-BRANCH-HEAD", kind: "quick_fix", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-BRANCH-HEAD/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/789", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-PR-BRANCH-HEAD/worker", "head_sha" => "head-b"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/789", "head_sha" => "head-a"})

    stale_response =
      MCPHarness.request(
        %{
          "jsonrpc" => "2.0",
          "id" => "stale-review",
          "method" => "tools/call",
          "params" => %{
            "name" => "submit_review_package",
            "arguments" => %{
              "summary" => "Old PR head review",
              "tests" => ["mix test"],
              "artifacts" => ["old-pr-head-review.txt"],
              "head_sha" => "head-a",
              "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
            }
          }
        },
        repo: repo,
        session: session
      )

    assert get_in(stale_response, ["error", "data", "reason"]) == "stale_head_sha"

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Latest branch head review",
      "tests" => ["mix test"],
      "artifacts" => ["latest-branch-head-review.txt"],
      "head_sha" => "head-b",
      "reviews" => [%{"lane" => "brief", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    assert get_in(ready_response, ["result", "structuredContent", "ready"]) == true
  end

  test "latest branch head requires matching PR metadata for merge-gated readiness", %{repo: repo} do
    assert {:ok, package} = WorkPackageRepository.create(repo, WorkPackageFactory.attrs(id: "SYMPP-CURRENT-HEAD-PR", kind: "mcp", status: "ci_waiting"))
    append_done_plan(repo, package.id)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, package.id)
    assert {:ok, assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")
    session = MCPHarness.session(assignment, proof_hash: minted.grant.secret_hash)

    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-CURRENT-HEAD-PR/worker", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_pr", %{"url" => "https://github.com/example/repo/pull/790", "head_sha" => "head-a"})
    attach_tool(repo, session, "attach_branch", %{"branch" => "agent/SYMPP-CURRENT-HEAD-PR/worker", "head_sha" => "head-b"})

    attach_tool(repo, session, "submit_review_package", %{
      "summary" => "Latest branch head review",
      "tests" => ["mix test"],
      "artifacts" => ["latest-branch-head-review.txt"],
      "head_sha" => "head-b",
      "acceptance_criteria_met" => true,
      "reviews" => [%{"lane" => "normal", "verdict" => "green"}]
    })

    ready_response =
      MCPHarness.request(
        %{"jsonrpc" => "2.0", "id" => "ready", "method" => "tools/call", "params" => %{"name" => "mark_ready"}},
        repo: repo,
        session: session
      )

    missing = get_in(ready_response, ["error", "data", "missing"])
    assert "pr_attached" in missing
  end
end
