defmodule SymphonyElixir.SymphonyPlusPlus.AuditEventTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.WorkPackageFactory

  defmodule SecretPayload do
    defstruct [:access_token, :large_blob, :safe]
  end

  setup_all do
    database_path = WorkPackageFactory.database_path()

    start_supervised!({Repo, database: database_path, pool_size: 5})
    assert :ok = PlanningRepository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(ProgressEvent)
    repo.delete_all(AccessGrant)
    repo.delete_all(WorkPackage)
    :ok
  end

  test "idempotent authenticated append returns one event for the same key", %{repo: repo} do
    assert {:ok, assignment} = claimed_assignment(repo)

    attrs = %{
      idempotency_key: "progress:one",
      summary: "Worker update",
      body: "First body",
      status: "working"
    }

    assert {:ok, first} = PlanningService.append_authenticated_progress_event(repo, assignment, attrs)
    assert {:ok, second} = PlanningService.append_authenticated_progress_event(repo, assignment, %{attrs | body: "Second body"})

    assert second.id == first.id
    assert second.body == "First body"
    assert repo.aggregate(ProgressEvent, :count) == 1
  end

  test "direct progress append with atom-key idempotency replays the stored event", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    attrs = %{
      work_package_id: work_package.id,
      idempotency_key: "progress:direct",
      summary: "Direct append",
      payload: %{accessToken: "raw-token"}
    }

    assert {:ok, first} = PlanningService.append_progress_event(repo, attrs)

    assert {:ok, second} =
             PlanningService.append_progress_event(repo, %{
               attrs
               | idempotency_key: " progress:direct ",
                 summary: "Duplicate append"
             })

    assert second.id == first.id
    assert second.summary == "Direct append"
    assert second.idempotency_key == "progress:direct"
    assert second.payload == %{"accessToken" => "[REDACTED]"}
    assert repo.aggregate(ProgressEvent, :count) == 1
  end

  test "direct progress append rejects conflicting atom and string keys", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:error, :conflicting_key_forms} =
             PlanningService.append_progress_event(repo, %{
               :work_package_id => work_package.id,
               "work_package_id" => "other-package",
               :idempotency_key => "progress:conflict",
               :summary => "Conflicting work package"
             })

    assert {:error, :conflicting_key_forms} =
             PlanningService.append_progress_event(repo, %{
               :work_package_id => work_package.id,
               :idempotency_key => "progress:conflict",
               "idempotency_key" => "progress:other-conflict",
               :summary => "Conflicting idempotency"
             })

    assert {:error, :conflicting_key_forms} =
             PlanningService.append_progress_event(repo, %{
               :work_package_id => work_package.id,
               :idempotency_key => "progress:summary-conflict",
               :summary => "Atom summary",
               "summary" => "String summary"
             })

    assert {:error, :conflicting_key_forms} =
             PlanningService.append_progress_event(repo, %{
               :work_package_id => work_package.id,
               :idempotency_key => "progress:payload-conflict",
               :summary => "Payload conflict",
               :payload => %{safe: "atom"},
               "payload" => %{"safe" => "string"}
             })
  end

  test "different idempotency keys append separate events", %{repo: repo} do
    assert {:ok, assignment} = claimed_assignment(repo)

    assert {:ok, first} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               idempotency_key: "progress:first",
               summary: "First update"
             })

    assert {:ok, second} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               idempotency_key: "progress:second",
               summary: "Second update"
             })

    assert first.id != second.id
    assert first.sequence == 1
    assert second.sequence == 2
    assert repo.aggregate(ProgressEvent, :count) == 2
  end

  test "actor grant and trusted agent run are recorded and exposed in the timeline", %{repo: repo} do
    assert {:ok, assignment} = claimed_assignment(repo, claimed_by: "agent-worker-1")

    assert {:ok, event} =
             PlanningService.append_authenticated_progress_event(
               repo,
               assignment,
               %{
                 idempotency_key: "progress:actor",
                 summary: "Actor update",
                 agent_run_id: "forged-run-123",
                 payload: %{phase: "implementation"}
               },
               agent_run_id: "trusted-run-123"
             )

    assert event.actor_id == "agent-worker-1"
    assert event.actor_type == "worker"
    assert event.access_grant_id == assignment.grant_id
    assert event.agent_run_id == "trusted-run-123"

    assert {:ok, [timeline_item]} = PlanningService.fetch_timeline(repo, assignment)
    assert timeline_item.actor == %{id: "agent-worker-1", type: "worker", access_grant_id: assignment.grant_id}
    assert timeline_item.agent_run_id == "trusted-run-123"
    assert timeline_item.payload == %{"phase" => "implementation"}
  end

  test "timeline fetch requires a valid assignment", %{repo: repo} do
    assert {:ok, assignment} = claimed_assignment(repo)

    assert {:error, :unauthenticated} = PlanningService.fetch_timeline(repo, assignment.work_package_id)

    assert {:error, :assignment_mismatch} =
             PlanningService.fetch_timeline(repo, %{assignment | display_key: "forged-display-key"})

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, assignment.grant_id)
    assert {:error, :assignment_revoked} = PlanningService.fetch_timeline(repo, assignment)
  end

  test "redaction helper removes known secret fields recursively" do
    assert PlanningService.redact_payload(%{
             :claim_secret => "raw-claim",
             :accessToken => "raw-access-token",
             :secretKey => "raw-secret-key",
             :JWTToken => "raw-jwt-token",
             "x-api-key" => "raw-prefixed-api-key",
             :dbPassword => "raw-db-password",
             "Proxy-Authorization" => "raw-proxy-authorization",
             :created_at => ~U[2026-05-01 10:00:00Z],
             {:tuple, :key} => %{token: "raw-tuple-token"},
             :headers => [{"authorization", "raw-header-token"}],
             :oauth => %SecretPayload{access_token: "raw-struct-token", safe: "struct-visible"},
             :nested => %{api_key: "raw-api-key", safe: "visible"},
             :events => [%{refresh_token: "raw-token", workKeySecret: "raw-work-key"}]
           }) == %{
             "claim_secret" => "[REDACTED]",
             "accessToken" => "[REDACTED]",
             "secretKey" => "[REDACTED]",
             "JWTToken" => "[REDACTED]",
             "x-api-key" => "[REDACTED]",
             "dbPassword" => "[REDACTED]",
             "Proxy-Authorization" => "[REDACTED]",
             "created_at" => ~U[2026-05-01 10:00:00Z],
             "{:tuple, :key}" => %{"token" => "[REDACTED]"},
             "headers" => [{"authorization", "[REDACTED]"}],
             "oauth" => %{"access_token" => "[REDACTED]", "large_blob" => nil, "safe" => "struct-visible"},
             "nested" => %{"api_key" => "[REDACTED]", "safe" => "visible"},
             "events" => [%{"refresh_token" => "[REDACTED]", "workKeySecret" => "[REDACTED]"}]
           }
  end

  test "claim grant append with idempotency renders one redacted progress event", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)
    assert {:ok, minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, %Assignment{} = assignment} = AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: "worker-1")

    attrs = %{
      idempotency_key: "progress:claim-grant",
      summary: "Claimed worker wrote progress",
      body: "Append completed.",
      payload: %{
        safe: "visible",
        claim_secret: minted.work_key.secret,
        nested: %{authorization: "Bearer raw"}
      }
    }

    assert {:ok, first} = PlanningService.append_authenticated_progress_event(repo, assignment, attrs)
    assert {:ok, second} = PlanningService.append_authenticated_progress_event(repo, assignment, attrs)
    assert first.id == second.id
    assert repo.aggregate(ProgressEvent, :count) == 1

    assert first.payload == %{
             "safe" => "visible",
             "claim_secret" => "[REDACTED]",
             "nested" => %{"authorization" => "[REDACTED]"}
           }

    assert {:ok, progress_markdown} = Renderer.render(repo, work_package.id, "progress.md")
    assert progress_markdown =~ "Claimed worker wrote progress"
    assert progress_markdown =~ "worker-1"
    refute progress_markdown =~ "[REDACTED]"
    refute progress_markdown =~ minted.work_key.secret
    refute inspect(first.payload) =~ minted.work_key.secret
  end

  test "authenticated append bounds payload before timeline persistence", %{repo: repo} do
    assert {:ok, assignment} = claimed_assignment(repo)

    assert {:ok, event} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               idempotency_key: "progress:bounded-payload",
               summary: "Bounded payload",
               payload: %{
                 long_text: String.duplicate("a", 5_000),
                 long_list: Enum.to_list(1..120)
               }
             })

    assert String.length(event.payload["long_text"]) < 4_100
    assert event.payload["long_text"] =~ "[truncated]"
    assert length(event.payload["long_list"]) == 101
    assert List.last(event.payload["long_list"]) == "[truncated]"

    assert {:ok, [timeline_item]} = PlanningService.fetch_timeline(repo, assignment)
    assert timeline_item.payload == event.payload
  end

  test "progress rendering keeps stored payload out of markdown", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, event} =
             PlanningService.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "progress:raw-render",
               summary: "Raw append",
               payload: %{clientSecret: "raw-client-secret", safe: "visible"}
             })

    assert event.payload == %{"clientSecret" => "[REDACTED]", "safe" => "visible"}

    assert {:ok, progress_markdown} = Renderer.render(repo, work_package.id, "progress.md")

    refute progress_markdown =~ "Payload"
    refute progress_markdown =~ "[REDACTED]"
    refute progress_markdown =~ "visible"
    refute progress_markdown =~ "raw-client-secret"
  end

  test "progress rendering redacts secret-shaped source text", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)
    secret = WorkKey.generate().secret

    assert {:ok, _event} =
             PlanningService.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "progress:secret-shaped-source",
               summary: "Worker pasted #{secret} then kept going",
               body: "See https://example.test/download?sig=#{secret}&page=1 then https://example.test/issues/1?w=1",
               status: "working"
             })

    assert {:ok, progress_markdown} = Renderer.render(repo, work_package.id, "progress.md")

    assert progress_markdown =~ "[REDACTED]"
    assert progress_markdown =~ "Worker pasted [REDACTED] then kept going"
    assert progress_markdown =~ "See https://example.test/download?sig=[REDACTED]&page=1 then https://example.test/issues/1?w=1"
    refute progress_markdown =~ secret
  end

  test "direct progress append also bounds stored payloads", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, event} =
             PlanningService.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "progress:direct-bounded-payload",
               summary: "Direct bounded payload",
               payload: %{
                 long_text: String.duplicate("b", 5_000),
                 long_list: Enum.to_list(1..120),
                 struct_payload: %SecretPayload{large_blob: String.duplicate("c", 5_000), safe: "visible"}
               }
             })

    assert String.length(event.payload["long_text"]) < 4_100
    assert event.payload["long_text"] =~ "[truncated]"
    assert length(event.payload["long_list"]) == 101
    assert List.last(event.payload["long_list"]) == "[truncated]"
    assert event.payload["struct_payload"]["large_blob"] =~ "[truncated]"
    assert event.payload["struct_payload"]["safe"] == "visible"
  end

  test "progress payload storage and rendering are JSON-safe without dropping colliding keys", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, event} =
             PlanningService.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "progress:json-safe",
               summary: "JSON-safe payload",
               payload: %{
                 :secret => "raw-atom-secret",
                 "secret" => "raw-string-secret",
                 :Secret => "raw-capital-atom-secret",
                 "Secret" => "raw-capital-string-secret",
                 "x-api-key" => "raw-hyphen-api-key",
                 "x_api_key" => "raw-underscore-api-key",
                 {:tuple, :key} => "tuple-value",
                 "{:tuple, :key}" => "string-tuple-value",
                 1 => "integer-value",
                 "1" => "string-integer-value",
                 :created_at => ~U[2026-05-01 10:00:00Z],
                 :date => ~D[2026-05-01],
                 :naive_datetime => ~N[2026-05-01 10:01:02],
                 :time => ~T[10:01:02],
                 :headers => [{"authorization", "raw-header-token"}]
               }
             })

    assert event.payload ==
             %{
               ":secret" => "[REDACTED]",
               "secret" => "[REDACTED]",
               ":Secret" => "[REDACTED]",
               "Secret" => "[REDACTED]",
               "x-api-key" => "[REDACTED]",
               "x_api_key" => "[REDACTED]",
               "created_at" => "2026-05-01T10:00:00Z",
               "date" => "2026-05-01",
               "naive_datetime" => "2026-05-01T10:01:02",
               "time" => "10:01:02",
               "headers" => [["authorization", "[REDACTED]"]]
             }
             |> Map.merge(Map.take(event.payload, ["{:tuple, :key}", "\"{:tuple, :key}\"", "{:tuple, :key}#2", "1", "\"1\"", "1#2"]))

    assert map_size(event.payload) == 15
    assert Enum.count(Map.values(event.payload), &(&1 == "tuple-value")) == 1
    assert Enum.count(Map.values(event.payload), &(&1 == "string-tuple-value")) == 1
    assert Enum.count(Map.values(event.payload), &(&1 == "integer-value")) == 1
    assert Enum.count(Map.values(event.payload), &(&1 == "string-integer-value")) == 1

    assert {:ok, progress_markdown} = Renderer.render(repo, work_package.id, "progress.md")

    refute progress_markdown =~ "\"created_at\": \"2026-05-01T10:00:00Z\""
    refute progress_markdown =~ "\":secret\": \"[REDACTED]\""
    refute progress_markdown =~ "raw-atom-secret"
    refute progress_markdown =~ "raw-string-secret"
    refute progress_markdown =~ "raw-capital-atom-secret"
    refute progress_markdown =~ "raw-capital-string-secret"
    refute progress_markdown =~ "raw-hyphen-api-key"
    refute progress_markdown =~ "raw-underscore-api-key"
    refute progress_markdown =~ "raw-header-token"
  end

  test "explicit nil progress payload persists as an empty map", %{repo: repo} do
    assert {:ok, assignment} = claimed_assignment(repo)

    assert {:ok, event} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               idempotency_key: "progress:nil-payload",
               summary: "Nil payload",
               payload: nil
             })

    assert event.payload == %{}

    assert {:ok, [timeline_item]} = PlanningService.fetch_timeline(repo, assignment)
    assert timeline_item.payload == %{}
  end

  test "progress rendering escapes audit metadata" do
    state = %State{
      progress_events: [
        %ProgressEvent{
          id: "progress-render",
          work_package_id: "SYMPP-P1-005",
          summary: "Raw append",
          status: "recorded",
          sequence: 1,
          actor_id: "worker-render",
          actor_type: "`worker`\n# actor",
          access_grant_id: "`grant`\n# grant",
          agent_run_id: "`run`\n# injected",
          payload: %{},
          created_at: ~U[2026-05-01 10:00:00Z]
        }
      ],
      progress_events_omitted_count: 0
    }

    assert {:ok, progress_markdown} = Renderer.render_state(state, "progress.md")

    assert progress_markdown =~ "Actor: source:"
    assert progress_markdown =~ "`` `worker` # actor ``"
    refute progress_markdown =~ "Agent run:"
    refute progress_markdown =~ "Grant:"
    refute progress_markdown =~ "`` `grant` # grant ``"
    refute progress_markdown =~ "`` `run` # injected ``"
    refute progress_markdown =~ "\n# injected"
    refute progress_markdown =~ "\n# actor"
    refute progress_markdown =~ "\n# grant"
  end

  test "authenticated append rejects missing assignment and package forgery", %{repo: repo} do
    assert {:ok, assignment} = claimed_assignment(repo)

    attrs = %{idempotency_key: "progress:blocked", summary: "Blocked"}

    assert {:error, :unauthenticated} = PlanningService.append_authenticated_progress_event(repo, nil, attrs)

    assert {:error, :work_package_scope_mismatch} =
             PlanningService.append_authenticated_progress_event(repo, assignment, Map.put(attrs, :work_package_id, "other-package"))

    assert repo.aggregate(ProgressEvent, :count) == 0
  end

  test "authenticated append validates assignment against stored grant state", %{repo: repo} do
    assert {:ok, %Assignment{} = assignment} = claimed_assignment(repo)

    forged = %Assignment{
      assignment
      | grant_id: "ag_forged",
        work_package_id: assignment.work_package_id,
        claimed_by: "worker-forged"
    }

    assert {:error, :assignment_mismatch} =
             PlanningService.append_authenticated_progress_event(repo, forged, %{
               idempotency_key: "progress:forged-assignment",
               summary: "Forged"
             })

    mismatched = %{assignment | claimed_by: "worker-forged"}

    assert {:error, :assignment_mismatch} =
             PlanningService.append_authenticated_progress_event(repo, mismatched, %{
               idempotency_key: "progress:mismatched-assignment",
               summary: "Mismatched"
             })

    unclaimed = %{assignment | claimed_at: nil, claimed_by: nil}

    assert {:error, :assignment_mismatch} =
             PlanningService.append_authenticated_progress_event(repo, unclaimed, %{
               idempotency_key: "progress:unclaimed-assignment",
               summary: "Unclaimed"
             })

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, assignment.grant_id)

    assert {:error, :assignment_revoked} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               idempotency_key: "progress:revoked-assignment",
               summary: "Revoked"
             })
  end

  test "authenticated append derives protected audit fields from assignment", %{repo: repo} do
    assert {:ok, assignment} = claimed_assignment(repo, claimed_by: "worker-source")

    assert {:error, :work_package_scope_mismatch} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               :work_package_id => assignment.work_package_id,
               "work_package_id" => "forged-package",
               :idempotency_key => "progress:scope-forgery",
               :summary => "Blocked"
             })

    assert {:ok, event} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               :idempotency_key => "progress:actor-forgery",
               :summary => "Protected fields",
               "actor_id" => "forged-worker",
               "actor_type" => "architect",
               "access_grant_id" => "forged-grant"
             })

    assert event.work_package_id == assignment.work_package_id
    assert event.actor_id == "worker-source"
    assert event.actor_type == "worker"
    assert event.access_grant_id == assignment.grant_id
  end

  test "authenticated append rejects conflicting caller-owned key forms", %{repo: repo} do
    assert {:ok, assignment} = claimed_assignment(repo, claimed_by: "worker-source")

    assert {:error, :conflicting_key_forms} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               :idempotency_key => "progress:summary-conflict",
               :summary => "Atom summary",
               "summary" => "String summary"
             })

    assert {:error, :conflicting_key_forms} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               :idempotency_key => "progress:payload-conflict",
               :summary => "Payload conflict",
               :payload => %{safe: "atom"},
               "payload" => %{"safe" => "string"}
             })
  end

  test "authenticated append owns id created_at and canonical idempotency", %{repo: repo} do
    assert {:ok, assignment} = claimed_assignment(repo, claimed_by: "worker-source")

    assert {:error, :idempotency_key_conflict} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               :idempotency_key => "progress:owned-fields",
               "idempotency_key" => "progress:other-key",
               :summary => "Conflicting keys"
             })

    assert {:ok, event} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               id: "caller-id",
               idempotency_key: " progress:owned-fields ",
               summary: "Owned fields",
               created_at: ~U[2000-01-01 00:00:00Z]
             })

    assert event.id != "caller-id"
    assert event.idempotency_key == "progress:owned-fields"
    assert DateTime.compare(event.created_at, ~U[2026-01-01 00:00:00Z]) == :gt
  end

  test "authenticated idempotency keys are scoped to each claimed grant", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)
    assert {:ok, first_minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, second_minted} = AccessGrantService.mint_worker_grant(repo, work_package.id)
    assert {:ok, first_assignment} = AccessGrantService.claim(repo, first_minted.work_key.secret, claimed_by: "worker-1")
    assert {:ok, second_assignment} = AccessGrantService.claim(repo, second_minted.work_key.secret, claimed_by: "worker-2")

    assert {:ok, first_event} =
             PlanningService.append_authenticated_progress_event(repo, first_assignment, %{
               idempotency_key: "progress:grant-scoped",
               summary: "Grant scoped",
               payload: %{worker: "one"}
             })

    assert {:ok, second_event} =
             PlanningService.append_authenticated_progress_event(repo, second_assignment, %{
               idempotency_key: "progress:grant-scoped",
               summary: "Other grant",
               status: "blocked",
               payload: %{worker: "two"}
             })

    assert repo.aggregate(ProgressEvent, :count) == 2
    assert first_event.access_grant_id == first_assignment.grant_id
    assert second_event.access_grant_id == second_assignment.grant_id

    assert {:ok, first_timeline} = PlanningService.fetch_timeline(repo, first_assignment)
    assert Enum.map(first_timeline, & &1.id) == [first_event.id, second_event.id]
    assert Enum.find(first_timeline, &(&1.id == first_event.id)).payload == %{"worker" => "one"}
    foreign_first_view = Enum.find(first_timeline, &(&1.id == second_event.id))
    assert foreign_first_view.payload == %{}
    assert foreign_first_view.idempotency_key == nil
    assert foreign_first_view.actor == %{id: nil, type: nil, access_grant_id: nil}
    assert foreign_first_view.status == "[redacted]"
    assert foreign_first_view.summary == "[redacted]"
    assert foreign_first_view.body == nil

    assert {:ok, second_timeline} = PlanningService.fetch_timeline(repo, second_assignment)
    assert Enum.map(second_timeline, & &1.id) == [first_event.id, second_event.id]
    foreign_second_view = Enum.find(second_timeline, &(&1.id == first_event.id))
    assert foreign_second_view.payload == %{}
    assert foreign_second_view.idempotency_key == nil
    assert foreign_second_view.actor == %{id: nil, type: nil, access_grant_id: nil}
    assert foreign_second_view.status == "[redacted]"
    assert foreign_second_view.summary == "[redacted]"
    assert foreign_second_view.body == nil
    assert Enum.find(second_timeline, &(&1.id == second_event.id)).payload == %{"worker" => "two"}
  end

  test "direct and authenticated idempotency keys have separate scopes", %{repo: repo} do
    assert {:ok, assignment} = claimed_assignment(repo)

    assert {:ok, audit_event} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               idempotency_key: "progress:shared-key",
               summary: "Authenticated"
             })

    assert {:ok, direct_event} =
             PlanningService.append_progress_event(repo, %{
               work_package_id: assignment.work_package_id,
               idempotency_key: "progress:shared-key",
               summary: "Direct",
               payload: %{system: "visible"}
             })

    assert audit_event.id != direct_event.id
    assert audit_event.access_grant_id == assignment.grant_id
    assert direct_event.access_grant_id == nil

    assert {:ok, replayed_audit_event} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               idempotency_key: "progress:shared-key",
               summary: "Authenticated replay"
             })

    assert replayed_audit_event.id == audit_event.id
    assert repo.aggregate(ProgressEvent, :count) == 2

    assert {:ok, timeline} = PlanningService.fetch_timeline(repo, assignment)
    assert Enum.find(timeline, &(&1.id == direct_event.id)).payload == %{"system" => "visible"}
  end

  test "authenticated idempotency replay validates stored grant state", %{repo: repo} do
    assert {:ok, assignment} = claimed_assignment(repo)

    assert {:ok, _first_event} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               idempotency_key: "progress:revoked-replay",
               summary: "Before revoke"
             })

    forged_assignment = %{assignment | display_key: "forged-display-key"}

    assert {:error, :assignment_mismatch} =
             PlanningService.append_authenticated_progress_event(repo, forged_assignment, %{
               idempotency_key: "progress:revoked-replay",
               summary: "Forged replay"
             })

    assert {:ok, _revoked} = AccessGrantService.revoke(repo, assignment.grant_id)

    assert {:error, :assignment_revoked} =
             PlanningService.append_authenticated_progress_event(repo, assignment, %{
               idempotency_key: "progress:revoked-replay",
               summary: "After revoke"
             })

    assert repo.aggregate(ProgressEvent, :count) == 1
  end

  test "direct progress append does not persist caller supplied provenance", %{repo: repo} do
    assert {:ok, work_package} = create_work_package(repo)

    assert {:ok, event} =
             PlanningService.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "progress:direct-provenance",
               summary: "Direct provenance",
               actor_id: "forged-worker",
               actor_type: "architect",
               access_grant_id: "forged-grant",
               agent_run_id: "forged-run"
             })

    assert event.actor_id == nil
    assert event.actor_type == nil
    assert event.access_grant_id == nil
    assert event.agent_run_id == nil

    assert {:ok, replayed_event} =
             PlanningService.append_progress_event(repo, %{
               work_package_id: work_package.id,
               idempotency_key: "progress:direct-provenance",
               summary: "Direct provenance replay",
               access_grant_id: "forged-grant"
             })

    assert replayed_event.id == event.id
    assert repo.aggregate(ProgressEvent, :count) == 1
  end

  defp claimed_assignment(repo, opts \\ []) do
    claimed_by = Keyword.get(opts, :claimed_by, "worker-1")

    with {:ok, work_package} <- create_work_package(repo, id: Keyword.get(opts, :work_package_id, "SYMPP-P1-005")),
         {:ok, minted} <- AccessGrantService.mint_worker_grant(repo, work_package.id) do
      AccessGrantService.claim(repo, minted.work_key.secret, claimed_by: claimed_by)
    end
  end

  defp create_work_package(repo, overrides \\ []) do
    attrs =
      Keyword.merge([id: "SYMPP-P1-005", kind: "standard_pr"], overrides)
      |> WorkPackageFactory.attrs()

    WorkPackageRepository.create(repo, attrs)
  end
end
