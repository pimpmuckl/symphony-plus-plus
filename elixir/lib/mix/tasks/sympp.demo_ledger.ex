defmodule Mix.Tasks.Sympp.DemoLedger do
  @moduledoc false

  use Mix.Task

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository, as: SoloRepository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
  alias SymphonyElixir.Workflow

  @shortdoc "Creates a deterministic local Symphony++ operator demo ledger"
  @board_path "/sympp/board"
  @demo_repo "nextide/demo-operator"
  @demo_base_branch "main"
  @demo_now ~U[2026-01-02 03:04:05.000000Z]
  @switches [
    database: :string,
    force: :boolean,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      :help ->
        Mix.shell().info(usage())

      {:ok, opts} ->
        run_demo_ledger(opts)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @spec usage() :: String.t()
  def usage do
    [
      "Usage: mix sympp.demo_ledger --database <sqlite-path> [--force]",
      "",
      "Creates a deterministic, synthetic local operator ledger for cockpit visual QA.",
      "Fails when the database already exists unless --force is provided."
    ]
    |> Enum.join("\n")
  end

  @doc false
  @spec parse_args_for_test([String.t()]) :: :help | {:ok, keyword()} | {:error, String.t()}
  def parse_args_for_test(args), do: parse_args(args)

  @doc false
  @spec database_path_for_test(String.t()) :: String.t()
  def database_path_for_test(database), do: resolved_database(database)

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> validate_opts(opts)
      {_opts, _argv, _invalid} -> {:error, usage()}
    end
  end

  defp validate_opts(opts) do
    cond do
      Keyword.get(opts, :help, false) ->
        :help

      blank?(Keyword.get(opts, :database)) ->
        {:error, usage()}

      has_blank_option?(opts, [:database]) ->
        {:error, usage()}

      true ->
        {:ok, Keyword.put_new(opts, :force, false)}
    end
  end

  defp run_demo_ledger(opts) do
    database = resolved_database(Keyword.fetch!(opts, :database))
    force? = Keyword.get(opts, :force, false)

    with :ok <- prepare_database(database, force?),
         {:ok, payload} <- seed_database(database) do
      payload
      |> Jason.encode!(pretty: true)
      |> Mix.shell().info()
    else
      {:error, reason} -> Mix.raise(error_message(reason))
    end
  end

  defp prepare_database(database, force?) do
    cond do
      not Repo.filesystem_database_path?(database) ->
        {:error, :unsupported_database}

      File.exists?(database) and not force? ->
        {:error, {:database_exists, database}}

      File.exists?(database) ->
        remove_existing_database(database)

      true ->
        :ok
    end
  end

  defp remove_existing_database(database) do
    [database, database <> "-shm", database <> "-wal", database <> "-journal"]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case remove_existing_file(path, 10) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp remove_existing_file(path, attempts_left) do
    cond do
      not File.exists?(path) ->
        :ok

      attempts_left <= 0 ->
        remove_file_once(path)

      true ->
        case File.rm(path) do
          :ok ->
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} when reason in [:eacces, :eperm] ->
            Process.sleep(50)
            remove_existing_file(path, attempts_left - 1)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp remove_file_once(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp seed_database(database) do
    original_repo = Repo.get_dynamic_repo()

    case start_repo(database) do
      {:ok, repo_pid} ->
        try do
          case migrate_repositories() do
            :ok -> seed_demo_records(database)
            {:error, reason} -> {:error, reason}
          end
        after
          stop_repo(repo_pid)
          Repo.put_dynamic_repo(original_repo)
        end

      {:error, reason} ->
        Repo.put_dynamic_repo(original_repo)
        {:error, reason}
    end
  end

  defp migrate_repositories do
    case WorkPackageRepository.migrate(Repo) do
      :ok -> SoloRepository.migrate(Repo)
      {:error, reason} -> {:error, reason}
    end
  end

  defp seed_demo_records(database) do
    Repo.transaction(fn ->
      with {:ok, work_requests} <- seed_work_requests(),
           {:ok, work_packages} <- seed_work_packages(),
           {:ok, planned_slices} <- seed_planned_slices(),
           {:ok, _evidence} <- seed_work_package_evidence(),
           {:ok, solo_sessions} <- seed_solo_sessions(),
           {_, nil} <- normalize_demo_timestamps() do
        %{
          "database" => database,
          "cockpit_hint" => "mix sympp.cockpit --database #{quote_cli_arg(database)}",
          "cockpit_path" => @board_path,
          "seed" => %{
            "work_requests" => Enum.map(work_requests, & &1.id),
            "planned_slices" => Enum.map(planned_slices, & &1.id),
            "work_packages" => Enum.map(work_packages, & &1.id),
            "solo_sessions" => Enum.map(solo_sessions, & &1.id)
          }
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp seed_work_requests do
    [
      work_request_attrs("SYMPP-DEMO-WR-CLARIFY", "Clarify cockpit onboarding copy", "clarifying", "docs", "single_package"),
      work_request_attrs("SYMPP-DEMO-WR-HUMAN", "Resolve package ownership question", "human_info_needed", "feature", "architect_led_feature_branch"),
      work_request_attrs("SYMPP-DEMO-WR-SLICING", "Plan dashboard visual QA sweep", "ready_for_slicing", "investigation", "investigation_first"),
      work_request_attrs("SYMPP-DEMO-WR-SLICED", "Ship operator cockpit polish", "ready_for_slicing", "feature", "architect_led_feature_branch")
    ]
    |> insert_all(&WorkRequestRepository.create(Repo, &1))
  end

  defp work_request_attrs(id, title, status, work_type, dispatch_shape) do
    %{
      id: id,
      title: title,
      repo: @demo_repo,
      base_branch: @demo_base_branch,
      work_type: work_type,
      human_description: "#{title}. Synthetic local demo data only.",
      constraints: %{
        "allowed_paths" => ["elixir/lib/**", "implementation_docs_symphplusplus/**"],
        "forbidden_paths" => [".env", "secrets/**"],
        "compatibility_stance" => "Clarify before assuming backward compatibility.",
        "synthetic_demo" => true
      },
      desired_dispatch_shape: dispatch_shape,
      status: status
    }
  end

  defp seed_work_packages do
    [
      work_package_attrs("SYMPP-DEMO-WP-ACTIVE", "Implement cockpit status filters", "implementing", "dashboard"),
      work_package_attrs("SYMPP-DEMO-WP-REVIEW", "Review local operator handoff copy", "reviewing", "docs"),
      work_package_attrs("SYMPP-DEMO-WP-READY", "Ready merge evidence package", "ready_for_human_merge", "standard_pr"),
      work_package_attrs("SYMPP-DEMO-WP-BLOCKED", "Blocked product decision package", "blocked", "product"),
      work_package_attrs("SYMPP-DEMO-WP-MERGED", "Merged demo cleanup package", "merged", "hardening")
    ]
    |> insert_all(&WorkPackageRepository.create(Repo, &1))
  end

  defp work_package_attrs(id, title, status, kind) do
    %{
      id: id,
      kind: kind,
      title: title,
      repo: @demo_repo,
      base_branch: @demo_base_branch,
      branch_pattern: "feat/#{String.downcase(id)}/demo",
      product_description: product_description(id),
      engineering_scope: "Exercise board/detail rendering with deterministic non-secret data.",
      allowed_file_globs: allowed_file_globs(id),
      acceptance_criteria: acceptance_criteria(title),
      status: status,
      parent_id: nil,
      phase_id: nil,
      owner_id: "local-demo-worker"
    }
  end

  defp product_description("SYMPP-DEMO-WP-ACTIVE"), do: "Ship operator cockpit polish. Synthetic local demo data only."
  defp product_description(_id), do: "Synthetic package for local cockpit visual QA."

  defp allowed_file_globs(_id), do: ["elixir/lib/**", "implementation_docs_symphplusplus/**"]

  defp acceptance_criteria(title), do: ["Cockpit displays #{title}.", "Evidence remains synthetic and redacted."]

  defp seed_planned_slices do
    with {:ok, planned} <- add_slice("SYMPP-DEMO-WR-SLICING", planned_slice_attrs("SYMPP-DEMO-SLICE-APPROVED", 1, "Approved cockpit filter slice")),
         {:ok, approved} <- WorkRequestRepository.approve_planned_slice(Repo, "SYMPP-DEMO-WR-SLICING", planned.id, "planned"),
         {:ok, skipped} <- add_skipped_slice(),
         {:ok, dispatched} <- add_dispatched_slice(),
         {:ok, _sliced_wr} <- WorkRequestRepository.mark_sliced(Repo, "SYMPP-DEMO-WR-SLICED", "ready_for_slicing") do
      {:ok, [approved, skipped, dispatched]}
    end
  end

  defp add_skipped_slice do
    with {:ok, planned} <- add_slice("SYMPP-DEMO-WR-SLICING", planned_slice_attrs("SYMPP-DEMO-SLICE-SKIPPED", 2, "Skipped broad redesign slice")) do
      WorkRequestRepository.skip_planned_slice(Repo, "SYMPP-DEMO-WR-SLICING", planned.id, "planned")
    end
  end

  defp add_dispatched_slice do
    with {:ok, planned} <-
           add_slice(
             "SYMPP-DEMO-WR-SLICED",
             planned_slice_attrs("SYMPP-DEMO-SLICE-DISPATCHED", 1, "Implement cockpit status filters")
             |> Map.merge(%{
               branch_pattern: "feat/sympp-demo-wp-active/demo",
               owned_file_globs: allowed_file_globs("SYMPP-DEMO-WP-ACTIVE"),
               acceptance_criteria: acceptance_criteria("Implement cockpit status filters")
             })
           ),
         {:ok, approved} <- WorkRequestRepository.approve_planned_slice(Repo, "SYMPP-DEMO-WR-SLICED", planned.id, "planned") do
      WorkRequestRepository.dispatch_planned_slice(Repo, "SYMPP-DEMO-WR-SLICED", approved.id, "approved", "SYMPP-DEMO-WP-ACTIVE")
    end
  end

  defp add_slice(work_request_id, attrs), do: WorkRequestRepository.add_planned_slice(Repo, work_request_id, attrs)

  defp planned_slice_attrs(id, sequence_hint, title) do
    %{
      id: id,
      title: title,
      goal: "#{title}. Synthetic planned slice for demo ledger visual QA.",
      work_package_kind: "dashboard",
      target_base_branch: @demo_base_branch,
      branch_pattern: "feat/#{String.downcase(id)}/demo",
      owned_file_globs: ["elixir/lib/symphony_elixir_web/live/sympp_*"],
      forbidden_file_globs: ["config/runtime.exs", ".env"],
      acceptance_criteria: ["Slice #{sequence_hint} is visible with deterministic content."],
      validation_steps: ["mix test test/mix/tasks/sympp_demo_ledger_test.exs"],
      review_lanes: ["review_t1", "review_t2"],
      stop_conditions: ["Stop before runtime defaults or auth changes."]
    }
  end

  defp seed_work_package_evidence do
    work_package_evidence()
    |> Enum.reduce_while({:ok, []}, fn {work_package_id, evidence}, {:ok, acc} ->
      case append_evidence(work_package_id, evidence) do
        {:ok, rows} -> {:cont, {:ok, rows ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp work_package_evidence do
    [
      {"SYMPP-DEMO-WP-ACTIVE",
       %{
         plan: [{"Verify board filters", "done"}, {"Capture detail screenshot", "pending"}],
         progress: [{"Implementation started", "running", %{"synthetic_demo" => true}}],
         findings: [{"No secret material required", "info"}],
         artifacts: [{"Visual QA target", "/sympp/work-packages/SYMPP-DEMO-WP-ACTIVE"}]
       }},
      {"SYMPP-DEMO-WP-REVIEW",
       %{
         plan: [{"Review prompt copy", "done"}, {"Run local signoff", "pending"}],
         progress: [{"Review lane opened", "reviewing", %{"review_lanes" => ["T1", "T2"]}}],
         findings: [{"Copy needs operator confirmation", "medium"}],
         artifacts: [{"Review notes", "implementation_docs_symphplusplus/runbooks/LOCAL_OPERATOR_GOLDEN_PATH.md"}]
       }},
      {"SYMPP-DEMO-WP-READY",
       %{
         plan: [{"Acceptance complete", "done"}, {"Attach final PR evidence", "done"}],
         progress: [{"Ready for human merge", "ready", %{"head_sha" => "0000000000000000000000000000000000000000"}}],
         findings: [{"Validation is synthetic", "info"}],
         artifacts: [{"PR preview", "https://example.invalid/symphony-plus-plus/pull/101"}]
       }},
      {"SYMPP-DEMO-WP-BLOCKED",
       %{
         plan: [{"Wait for product answer", "pending"}],
         progress: [
           {"Product decision required", "blocked",
            %{
              "type" => "blocker",
              "source_tool" => "report_blocker",
              "blocker_id" => "demo-product-guidance",
              "active" => true,
              "summary" => "Choose the cockpit default grouping before implementation continues."
            }}
         ],
         findings: [{"Default grouping remains undecided", "high"}],
         artifacts: [{"Guidance placeholder", "sympp://demo/product-guidance"}]
       }},
      {"SYMPP-DEMO-WP-MERGED",
       %{
         plan: [{"Cleanup merged", "done"}],
         progress: [{"Merged into main", "completed", %{"merged" => true}}],
         findings: [{"No follow-up required", "info"}],
         artifacts: [{"Merge evidence", "https://example.invalid/symphony-plus-plus/pull/102"}]
       }}
    ]
  end

  defp append_evidence(work_package_id, evidence) do
    with {:ok, plan_nodes} <- append_plan_nodes(work_package_id, Map.fetch!(evidence, :plan)),
         {:ok, progress_events} <- append_progress_events(work_package_id, Map.fetch!(evidence, :progress)),
         {:ok, findings} <- append_findings(work_package_id, Map.fetch!(evidence, :findings)),
         {:ok, artifacts} <- append_artifacts(work_package_id, Map.fetch!(evidence, :artifacts)) do
      {:ok, plan_nodes ++ progress_events ++ findings ++ artifacts}
    end
  end

  defp append_plan_nodes(work_package_id, entries) do
    entries
    |> Enum.with_index(1)
    |> insert_all(fn {{title, status}, sequence} ->
      PlanningRepository.append_plan_node(Repo, %{
        id: evidence_id(work_package_id, "plan", sequence),
        work_package_id: work_package_id,
        title: title,
        body: "Synthetic demo plan node.",
        status: status
      })
    end)
  end

  defp append_progress_events(work_package_id, entries) do
    entries
    |> Enum.with_index(1)
    |> insert_all(fn {{summary, status, payload}, sequence} ->
      PlanningRepository.append_progress_event(Repo, %{
        id: evidence_id(work_package_id, "progress", sequence),
        work_package_id: work_package_id,
        summary: summary,
        body: "Synthetic demo progress event.",
        status: status,
        idempotency_key: "#{work_package_id}:#{summary}",
        payload: payload
      })
    end)
  end

  defp append_findings(work_package_id, entries) do
    entries
    |> Enum.with_index(1)
    |> insert_all(fn {{title, severity}, sequence} ->
      PlanningRepository.append_finding(Repo, %{
        id: evidence_id(work_package_id, "finding", sequence),
        work_package_id: work_package_id,
        title: title,
        body: "Synthetic demo finding.",
        severity: severity,
        idempotency_key: "#{work_package_id}:#{title}"
      })
    end)
  end

  defp append_artifacts(work_package_id, entries) do
    entries
    |> Enum.with_index(1)
    |> insert_all(fn {{title, path}, sequence} ->
      PlanningRepository.append_artifact(Repo, %{
        id: evidence_id(work_package_id, "artifact", sequence),
        work_package_id: work_package_id,
        title: title,
        path: path,
        kind: "reference",
        metadata: %{"synthetic_demo" => true}
      })
    end)
  end

  defp evidence_id(work_package_id, kind, sequence) do
    work_package_id
    |> String.replace("SYMPP-DEMO-WP-", "SYMPP-DEMO-#{String.upcase(kind)}-")
    |> Kernel.<>("-#{sequence}")
  end

  defp seed_solo_sessions do
    now = @demo_now

    sessions = [
      solo_session("SYMPP-DEMO-SOLO-ACTIVE", "active", "Active cockpit smoke test", now),
      solo_session("SYMPP-DEMO-SOLO-PAUSED", "paused", "Paused documentation review", now),
      solo_session("SYMPP-DEMO-SOLO-COMPLETED", "completed", "Completed validation pass", now),
      solo_session("SYMPP-DEMO-SOLO-ARCHIVED", "archived", "Archived exploratory spike", now)
    ]

    entries =
      Enum.flat_map(sessions, fn session ->
        [
          solo_entry(session.id, 1, "task_plan", "Plan #{session.title}", "pending", now),
          solo_entry(session.id, 2, "finding", "Finding #{session.title}", nil, now),
          solo_entry(session.id, 3, "progress", "Progress #{session.title}", "recorded", now),
          solo_entry(session.id, 4, "decision", "Decision #{session.title}", nil, now),
          solo_entry(session.id, 5, "validation_note", "Validation #{session.title}", "completed", now)
        ]
      end)

    Repo.insert_all(SoloSession, sessions, on_conflict: :raise)
    Repo.insert_all(SoloSessionEntry, entries, on_conflict: :raise)

    {:ok, sessions}
  rescue
    error in Ecto.ConstraintError -> {:error, {:constraint_failed, error.constraint}}
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  defp normalize_demo_timestamps do
    Enum.each([WorkRequest, WorkPackage, PlannedSlice, SoloSession], fn schema ->
      Repo.update_all(schema, set: [inserted_at: @demo_now, updated_at: @demo_now])
    end)

    Enum.each([PlanNode, ProgressEvent, Finding, Artifact], &normalize_ordered_timestamps/1)

    Repo.update_all(SoloSessionEntry, set: [created_at: @demo_now, updated_at: @demo_now])
    Repo.update_all(from(slice in PlannedSlice, where: slice.status == "dispatched"), set: [dispatched_at: @demo_now])
  end

  defp normalize_ordered_timestamps(schema) do
    from(row in schema, order_by: [asc: row.id])
    |> Repo.all()
    |> Enum.with_index()
    |> Enum.each(fn {%{id: id}, index} ->
      timestamp = DateTime.add(@demo_now, index, :microsecond)

      Repo.update_all(
        from(row in schema, where: row.id == ^id),
        set: [created_at: timestamp, inserted_at: timestamp, updated_at: timestamp]
      )
    end)
  end

  defp solo_session(id, status, title, now) do
    %{
      id: id,
      repo: @demo_repo,
      base_branch: @demo_base_branch,
      workspace_path: demo_workspace_path(id),
      caller_id: "local-demo-operator",
      session_key: "solo_key_#{String.downcase(id)}",
      title: title,
      status: status,
      last_activity_at: now,
      archived_at: if(status == "archived", do: now),
      inserted_at: now,
      updated_at: now
    }
  end

  defp demo_workspace_path(id) do
    case :os.type() do
      {:win32, _name} -> "c:/demo/#{String.downcase(id)}"
      _type -> "/demo/#{String.downcase(id)}"
    end
  end

  defp solo_entry(solo_session_id, sequence, kind, title, status, now) do
    %{
      id: "#{solo_session_id}-ENTRY-#{sequence}",
      solo_session_id: solo_session_id,
      entry_kind: kind,
      title: title,
      body: "Synthetic demo Solo Session #{kind}.",
      status: status || "recorded",
      sequence: sequence,
      idempotency_key: "#{solo_session_id}:#{kind}",
      payload: %{"synthetic_demo" => true},
      created_at: now,
      updated_at: now
    }
  end

  defp insert_all(items, insert_fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case insert_fun.(item) do
        {:ok, row} -> {:cont, {:ok, acc ++ [row]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp start_repo(database) do
    with :ok <- ensure_repo_dependencies_started() do
      case Repo.start_link(database: database, name: Repo.process_name(database), pool_size: 1, log: false) do
        {:ok, pid} ->
          Repo.put_dynamic_repo(pid)
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          Repo.put_dynamic_repo(pid)
          {:ok, nil}

        {:error, reason} ->
          {:error, {:repo_start_failed, reason}}
      end
    end
  end

  defp stop_repo(pid) when is_pid(pid), do: GenServer.stop(pid)
  defp stop_repo(_pid), do: :ok

  defp ensure_repo_dependencies_started do
    case Application.ensure_all_started(:ecto_sql) do
      {:ok, _started} -> :ok
      {:error, reason} -> {:error, {:ecto_start_failed, reason}}
    end
  end

  defp resolved_database(database) when is_binary(database) do
    if Repo.filesystem_database_path?(database) do
      database = Path.expand(database)
      File.mkdir_p!(Path.dirname(database))
      database
    else
      database
    end
  end

  defp resolved_database(_database) do
    original_workflow = Application.get_env(:symphony_elixir, :workflow_file_path)
    original_database = Application.get_env(:symphony_elixir, :sympp_repo_database)

    try do
      use_mix_project_workflow()
      Application.delete_env(:symphony_elixir, :sympp_repo_database)
      Repo.database_path()
    after
      restore_sympp_repo_database(original_database)
      restore_workflow(original_workflow)
    end
  end

  defp use_mix_project_workflow do
    mix_project_workflow()
    |> case do
      path when is_binary(path) -> Workflow.set_workflow_file_path(path)
      nil -> :ok
    end
  end

  defp restore_workflow(nil), do: Workflow.clear_workflow_file_path()
  defp restore_workflow(path) when is_binary(path), do: Workflow.set_workflow_file_path(path)

  defp restore_sympp_repo_database(nil), do: Application.delete_env(:symphony_elixir, :sympp_repo_database)
  defp restore_sympp_repo_database(database), do: Application.put_env(:symphony_elixir, :sympp_repo_database, database)

  defp mix_project_workflow do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.expand()
    |> Path.join("WORKFLOW.md")
    |> existing_file()
  end

  defp existing_file(path) do
    if File.exists?(path), do: path
  end

  defp quote_cli_arg(path), do: "'#{String.replace(path, "'", "''")}'"

  defp error_message(:unsupported_database), do: "mix sympp.demo_ledger requires --database to be a durable local SQLite filesystem path."
  defp error_message({:database_exists, path}), do: "Demo ledger already exists at #{path}. Pass --force to overwrite it."
  defp error_message({:repo_start_failed, reason}), do: "Failed to start Symphony++ demo ledger repository: #{inspect(reason)}"
  defp error_message({:ecto_start_failed, reason}), do: "Failed to start Ecto for Symphony++ demo ledger: #{inspect(reason)}"
  defp error_message({:constraint_failed, constraint}), do: "Failed to seed Symphony++ demo ledger due to constraint #{constraint}."
  defp error_message({:storage_failed, message}), do: "Failed to seed Symphony++ demo ledger: #{message}"
  defp error_message(reason), do: "Failed to seed Symphony++ demo ledger: #{inspect(reason)}"

  defp has_blank_option?(opts, keys) do
    Enum.any?(keys, &(Keyword.has_key?(opts, &1) and blank?(Keyword.get(opts, &1))))
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
