defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Repository, as: GuidanceRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.ReviewProfiles
  alias SymphonyElixir.SymphonyPlusPlus.SecretHandoff
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service, as: SoloSessionsService
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @stale_heartbeat_after_seconds 300
  @ready_statuses ["ready_for_human_merge", "ready_for_architect_merge"]
  @complete_plan_statuses ["done", "completed", "skipped"]
  @merge_required_gates ["human_merge", "architect_merge"]
  @runtime_merge_required_kinds ["hotfix", "adapter", "mcp", "skill", "hooks", "phase_child"]
  @started_package_statuses ["claimed", "planning", "implementing"]
  @merged_package_statuses ["merged", "merged_into_phase"]
  @closed_package_statuses ["closed", "abandoned"]
  @scope_guard_gate "scope_guard"
  @local_operator_worker "local-operator-worker"
  @dropped_child_statuses ["abandoned"]
  @non_open_child_statuses ["merged_into_phase", "closed", "abandoned"]
  @work_request_count_chunk_size 500
  @solo_session_query_chunk_size 500
  @solo_session_snippet_limit 120

  @type repo :: module()
  @type dashboard_error :: :not_found | :forbidden | :database_busy | {:storage_failed, String.t()} | term()

  @spec board(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def board(repo) when is_atom(repo) do
    safe_read(fn -> build_board(repo) end)
  end

  @spec operator_board(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def operator_board(repo) when is_atom(repo) do
    safe_read(fn -> build_board(repo, active_blocking_edges?: true) end)
  end

  @spec phase_board(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def phase_board(repo, phase_id) when is_atom(repo) and is_binary(phase_id) do
    phase_board(repo, phase_id, [])
  end

  @spec phase_board(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def phase_board(repo, phase_id, filters) when is_atom(repo) and is_binary(phase_id) and is_list(filters) do
    safe_read(fn -> build_phase_board(repo, phase_id, filters) end)
  end

  @spec phase_board_for_grant(repo(), String.t(), AccessGrant.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def phase_board_for_grant(repo, phase_id, %AccessGrant{} = grant) when is_atom(repo) and is_binary(phase_id) do
    with {:ok, filters} <- phase_board_filters_for_grant(grant) do
      phase_board(repo, phase_id, filters)
    end
  end

  @spec work_requests_for_grant(repo(), AccessGrant.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_requests_for_grant(repo, %AccessGrant{} = grant) when is_atom(repo) do
    safe_read(fn ->
      with {:ok, filters} <- work_request_filters_for_grant(repo, grant),
           {:ok, work_requests} <- WorkRequestRepository.list(repo, Map.new(filters)),
           {:ok, cards} <- work_request_cards(repo, ordered_work_requests(work_requests)) do
        {:ok,
         %{
           work_requests: cards,
           total_count: length(cards)
         }}
      end
    end)
  end

  @spec work_requests(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_requests(repo) when is_atom(repo) do
    safe_read(fn ->
      with {:ok, work_requests} <- WorkRequestRepository.list(repo),
           {:ok, cards} <- work_request_cards(repo, ordered_work_requests(work_requests)) do
        {:ok,
         %{
           work_requests: cards,
           total_count: length(cards)
         }}
      end
    end)
  end

  @spec human_guidance_requests(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def human_guidance_requests(repo) when is_atom(repo) do
    safe_read(fn ->
      with {:ok, cards} <- human_guidance_request_cards(repo) do
        {:ok,
         %{
           guidance_requests: cards,
           total_count: length(cards)
         }}
      end
    end)
  end

  @spec solo_sessions(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  @spec solo_sessions(repo(), map()) :: {:ok, map()} | {:error, dashboard_error()}
  def solo_sessions(repo, filters \\ %{}) when is_atom(repo) and is_map(filters) do
    safe_read(fn ->
      with {:ok, sessions} <- SoloSessionsService.list(repo, filters),
           {:ok, cards} <- solo_session_cards(repo, sessions) do
        {:ok,
         %{
           solo_sessions: cards,
           total_count: length(cards)
         }}
      end
    end)
  end

  @spec solo_session_detail(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def solo_session_detail(repo, solo_session_id) when is_atom(repo) and is_binary(solo_session_id) do
    safe_read(fn ->
      with {:ok, session} <- SoloSessionsService.get(repo, solo_session_id),
           {:ok, entries} <- SoloSessionsService.list_entries(repo, solo_session_id) do
        {:ok,
         %{
           solo_session: solo_session_detail(session),
           entries: Enum.map(entries, &solo_session_detail_entry/1),
           entry_count: length(entries)
         }}
      end
    end)
  end

  @spec solo_session_repos(repo()) :: {:ok, [String.t()]} | {:error, dashboard_error()}
  def solo_session_repos(repo) when is_atom(repo) do
    safe_read(fn ->
      repos =
        repo.all(
          from(session in SoloSession,
            where: not is_nil(session.repo) and session.repo != "",
            distinct: true,
            order_by: [asc: session.repo],
            select: session.repo
          )
        )

      {:ok, repos}
    end)
  end

  @spec solo_session_streams(repo()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def solo_session_streams(repo) when is_atom(repo) do
    safe_read(fn ->
      streams =
        repo.all(
          from(session in SoloSession,
            where: not is_nil(session.repo) and session.repo != "",
            where: not is_nil(session.base_branch) and session.base_branch != "",
            group_by: [session.repo, session.base_branch],
            order_by: [asc: session.repo, asc: session.base_branch],
            select: %{
              repo: session.repo,
              base_branch: session.base_branch,
              solo_session_count: count(session.id)
            }
          )
        )

      {:ok, streams}
    end)
  end

  @spec solo_session_count(repo()) :: {:ok, non_neg_integer()} | {:error, dashboard_error()}
  def solo_session_count(repo) when is_atom(repo) do
    safe_read(fn ->
      count =
        repo.one(
          from(session in SoloSession,
            select: count(session.id)
          )
        )

      {:ok, count || 0}
    end)
  end

  @spec work_request_detail_for_grant(repo(), String.t(), AccessGrant.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_request_detail_for_grant(repo, work_request_id, %AccessGrant{} = grant)
      when is_atom(repo) and is_binary(work_request_id) do
    safe_read(fn ->
      with {:ok, work_request} <- WorkRequestRepository.get(repo, work_request_id),
           :ok <- require_visible_work_request_scope(repo, work_request, grant),
           {:ok, questions} <- WorkRequestRepository.list_questions(repo, work_request_id),
           {:ok, decisions} <- WorkRequestRepository.list_decisions(repo, work_request_id),
           {:ok, planned_slices} <- WorkRequestRepository.list_planned_slices(repo, work_request_id) do
        questions = ordered_sequence_records(questions)
        decisions = ordered_sequence_records(decisions)
        planned_slices = ordered_sequence_records(planned_slices)

        {:ok,
         %{
           work_request: work_request_detail(work_request),
           clarification_questions: Enum.map(questions, &clarification_question/1),
           decision_logs: Enum.map(decisions, &decision_log_entry/1),
           planned_slices: Enum.map(planned_slices, &planned_slice(&1, %{}, include_dispatch_linkage?: false)),
           summary: work_request_summary(questions, decisions, planned_slices)
         }}
      end
    end)
  end

  @spec work_request_detail(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_request_detail(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    safe_read(fn ->
      with {:ok, work_request} <- WorkRequestRepository.get(repo, work_request_id),
           {:ok, questions} <- WorkRequestRepository.list_questions(repo, work_request_id),
           {:ok, decisions} <- WorkRequestRepository.list_decisions(repo, work_request_id),
           {:ok, planned_slices} <- WorkRequestRepository.list_planned_slices(repo, work_request_id),
           {:ok, work_package_contexts} <- planned_slice_work_package_contexts(repo, planned_slices) do
        questions = ordered_sequence_records(questions)
        decisions = ordered_sequence_records(decisions)
        planned_slices = ordered_sequence_records(planned_slices)

        {:ok,
         %{
           work_request: work_request_detail(work_request),
           clarification_questions: Enum.map(questions, &clarification_question/1),
           decision_logs: Enum.map(decisions, &decision_log_entry/1),
           planned_slices: Enum.map(planned_slices, &planned_slice(&1, work_package_contexts, include_dispatch_linkage?: true)),
           summary: work_request_summary(questions, decisions, planned_slices)
         }}
      end
    end)
  end

  @spec work_request_filters_for_grant(repo(), AccessGrant.t()) :: {:ok, keyword()} | {:error, dashboard_error()}
  def work_request_filters_for_grant(repo, %AccessGrant{} = grant) when is_atom(repo) do
    case phase_board_filters_for_grant(grant) do
      {:ok, []} -> legacy_work_request_filters_for_grant(repo, grant)
      result -> result
    end
  end

  @spec phase_board_filters_for_grant(AccessGrant.t()) :: {:ok, keyword()} | {:error, :forbidden}
  def phase_board_filters_for_grant(%AccessGrant{} = grant) do
    if explicit_phase_architect_grant?(grant) do
      with {:ok, repo} <- frozen_scope_value(grant.scope_repo),
           {:ok, base_branch} <- frozen_scope_value(grant.scope_base_branch) do
        {:ok, repo: repo, base_branch: base_branch}
      else
        {:error, :forbidden} -> {:error, :forbidden}
      end
    else
      {:ok, []}
    end
  end

  @spec require_phase_board_anchor_scope(WorkPackage.t(), AccessGrant.t(), String.t()) :: :ok | {:error, :forbidden}
  def require_phase_board_anchor_scope(%WorkPackage{} = anchor, %AccessGrant{} = grant, phase_id) when is_binary(phase_id) do
    cond do
      anchor.phase_id != phase_id ->
        {:error, :forbidden}

      explicit_phase_architect_grant?(grant) ->
        require_frozen_scope_match(anchor, grant)

      true ->
        :ok
    end
  end

  @spec require_phase_board_work_package_scope(WorkPackage.t(), AccessGrant.t()) :: :ok | {:error, :forbidden}
  def require_phase_board_work_package_scope(%WorkPackage{} = work_package, %AccessGrant{} = grant) do
    with {:ok, filters} <- phase_board_filters_for_grant(grant) do
      if phase_work_package_matches_filters?(work_package, filters) do
        :ok
      else
        {:error, :forbidden}
      end
    end
  end

  @spec detail(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def detail(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    detail(repo, work_package_id, [])
  end

  @spec detail(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def detail(repo, work_package_id, opts) when is_atom(repo) and is_binary(work_package_id) and is_list(opts) do
    safe_read(fn ->
      with {:ok, state} <- planning_state(repo, work_package_id),
           {:ok, grants} <- AccessGrantRepository.list_for_work_package(repo, work_package_id),
           {:ok, agent_runs} <- AgentRunRepository.list_for_work_package(repo, work_package_id),
           {:ok, guidance_requests} <- GuidanceRequestRepository.list_for_work_package(repo, work_package_id) do
        blockers = blockers(state.progress_events)
        summary = summary(state, grants, agent_runs, blockers, guidance_requests)
        worker_secret_handoffs = worker_secret_handoffs(repo, state.work_package, grants, opts)

        {:ok,
         %{
           work_package: work_package_detail(state.work_package),
           summary: summary,
           plan: Enum.map(state.plan_nodes, &plan_node/1),
           findings: Enum.map(state.findings, &finding/1),
           progress: Enum.map(state.progress_events, &progress_event/1),
           artifacts: Enum.map(state.artifacts, &artifact/1),
           blockers: blockers,
           guidance_requests: Enum.map(guidance_requests, &guidance_request/1),
           grants: Enum.map(grants, &grant/1),
           worker_secret_handoffs: worker_secret_handoffs,
           agent_runs: Enum.map(agent_runs, &agent_run/1),
           metadata: metadata(state.progress_events, state.artifacts, state.work_package.id),
           alert_indicators: alert_indicators(state, summary.runtime)
         }}
      end
    end)
  end

  @spec timeline(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def timeline(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_read(fn ->
      with {:ok, state} <- planning_state(repo, work_package_id) do
        events =
          (Enum.map(state.progress_events, &timeline_progress_event/1) ++ Enum.map(state.findings, &timeline_finding/1))
          |> Enum.sort_by(&timeline_sort_key/1)

        {:ok, %{work_package_id: work_package_id, events: events}}
      end
    end)
  end

  @spec artifacts(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def artifacts(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_read(fn ->
      with {:ok, _work_package} <- WorkPackageRepository.get(repo, work_package_id),
           {:ok, artifacts} <- PlanningRepository.list_artifacts(repo, work_package_id) do
        {:ok, %{work_package_id: work_package_id, artifacts: Enum.map(artifacts, &artifact/1)}}
      end
    end)
  end

  @spec blockers(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def blockers(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_read(fn ->
      with {:ok, state} <- planning_state(repo, work_package_id) do
        {:ok, %{work_package_id: work_package_id, blockers: blockers(state.progress_events)}}
      end
    end)
  end

  @spec grants(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def grants(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_read(fn ->
      with {:ok, _work_package} <- WorkPackageRepository.get(repo, work_package_id),
           {:ok, grants} <- AccessGrantRepository.list_for_work_package(repo, work_package_id) do
        {:ok, %{work_package_id: work_package_id, grants: Enum.map(grants, &grant/1)}}
      end
    end)
  end

  @spec agent_runs(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def agent_runs(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_read(fn ->
      with {:ok, _work_package} <- WorkPackageRepository.get(repo, work_package_id),
           {:ok, agent_runs} <- AgentRunRepository.list_for_work_package(repo, work_package_id) do
        {:ok, %{work_package_id: work_package_id, agent_runs: Enum.map(agent_runs, &agent_run/1)}}
      end
    end)
  end

  @spec card(repo(), WorkPackage.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def card(repo, %WorkPackage{} = work_package) when is_atom(repo) do
    safe_read(fn ->
      with {:ok, context} <- card_context(repo, work_package) do
        {:ok, context.card}
      end
    end)
  end

  defp card_context(repo, %WorkPackage{} = work_package) do
    with {:ok, status_summary} <- PlanningRepository.get_status_summary(repo, work_package.id),
         {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package.id),
         {:ok, readiness_collections} <- readiness_collections(repo, work_package),
         {:ok, agent_runs} <- AgentRunRepository.list_for_work_package(repo, work_package.id),
         {:ok, grants} <- AccessGrantRepository.list_for_work_package(repo, work_package.id) do
      %{artifacts: artifacts, findings: findings} = readiness_collections
      blockers = blockers(progress_events)
      runtime = runtime_summary(agent_runs)

      readiness_context =
        readiness_context(
          work_package,
          status_summary.plan_nodes,
          progress_events,
          artifacts,
          findings
        )

      metadata = metadata(progress_events, artifacts, work_package.id)
      operational_state = work_package_operational_state(work_package, progress_events, blockers, runtime, metadata, readiness_context, grants)

      {:ok,
       %{
         work_package: work_package,
         blockers: blockers,
         card: %{
           id: work_package.id,
           title: redacted_text(work_package.title),
           kind: work_package.kind,
           status: work_package.status,
           repo: work_package.repo,
           base_branch: work_package.base_branch,
           parent_id: work_package.parent_id,
           phase_id: work_package.phase_id,
           owner_id: work_package.owner_id,
           active_agent_run: latest_active_agent_run(agent_runs),
           runtime: runtime,
           latest_progress_at: latest_progress_at(progress_events),
           active_blocker_count: Enum.count(blockers, & &1.active),
           artifact_count: status_summary.artifact_count,
           finding_count: status_summary.finding_count,
           plan: plan_summary(status_summary.plan_nodes),
           metadata: metadata,
           operational_state: operational_state,
           alert_indicators: alert_indicators(readiness_context, blockers, runtime),
           inserted_at: timestamp(work_package.inserted_at),
           updated_at: timestamp(work_package.updated_at)
         }
       }}
    end
  end

  defp readiness_collections(repo, %WorkPackage{} = work_package) do
    with {:ok, artifacts} <- readiness_artifacts(repo, work_package),
         {:ok, findings} <- readiness_findings(repo, work_package) do
      {:ok, %{artifacts: artifacts, findings: findings}}
    end
  end

  defp worker_secret_handoffs(_repo, %WorkPackage{}, [], _opts), do: []

  defp worker_secret_handoffs(repo, %WorkPackage{} = work_package, grants, opts) do
    handoff_opts = Keyword.get(opts, :secret_handoff_opts) || local_operator_handoff_opts(repo)
    now = DateTime.utc_now(:microsecond)

    grants
    |> Enum.filter(&live_worker_grant?(&1, now))
    |> Enum.flat_map(fn %AccessGrant{} = grant ->
      read_worker_secret_handoff(work_package, grant, handoff_opts)
    end)
  end

  defp read_worker_secret_handoff(%WorkPackage{} = work_package, %AccessGrant{} = grant, handoff_opts) do
    handoffs =
      handoff_opts
      |> namespace_handoff_opts()
      |> Enum.find_value(fn opts ->
        case SecretHandoff.read_worker_secret_metadata(work_package, grant, opts) do
          {:ok, handoff} -> [handoff]
          {:error, _reason} -> nil
        end
      end)

    case handoffs do
      [_handoff | _rest] -> handoffs
      nil -> []
    end
  end

  defp namespace_handoff_opts(opts) do
    case Keyword.get(opts, :namespace_repo_roots) do
      roots when is_list(roots) ->
        roots
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.map(fn root ->
          opts
          |> Keyword.delete(:namespace_repo_roots)
          |> Keyword.put(:namespace_repo_root, root)
        end)

      _roots ->
        [opts]
    end
  end

  defp live_worker_grant?(%AccessGrant{grant_role: "worker", revoked_at: nil, expires_at: %DateTime{} = expires_at}, now) do
    DateTime.compare(expires_at, now) == :gt
  end

  defp live_worker_grant?(%AccessGrant{grant_role: "worker", revoked_at: nil, expires_at: nil}, %DateTime{}), do: true

  defp live_worker_grant?(%AccessGrant{}, %DateTime{}), do: false

  defp local_operator_handoff_opts(repo) do
    [
      repo_root: SecretHandoff.local_operator_repo_root(),
      namespace_repo_roots: SecretHandoff.local_operator_namespace_repo_roots(),
      claimed_by: @local_operator_worker
    ]
    |> put_optional_handoff_opt(:database, dashboard_ledger_database(repo))
    |> put_optional_handoff_opt(:store_dir, Application.get_env(:symphony_elixir, :sympp_worker_secret_store_dir))
  end

  defp dashboard_ledger_database(repo) do
    configured_ledger_database() || live_ledger_database(repo)
  end

  defp live_ledger_database(repo) do
    case repo.query("PRAGMA database_list", []) do
      {:ok, %{rows: rows}} -> persistent_main_database_path(rows) || configured_ledger_database()
      {:error, _reason} -> configured_ledger_database()
      _result -> configured_ledger_database()
    end
  rescue
    _error in [Exqlite.Error, UndefinedFunctionError] -> configured_ledger_database()
  end

  defp persistent_main_database_path(rows) do
    Enum.find_value(rows, fn
      [_seq, "main", path] when is_binary(path) and path != "" -> path
      _row -> nil
    end)
  end

  defp configured_ledger_database do
    case Application.get_env(:symphony_elixir, :sympp_repo_database) do
      database when is_binary(database) ->
        configured_ledger_database_path(database)

      database ->
        database
    end
  end

  defp configured_ledger_database_path(database) do
    database = String.trim(database)

    cond do
      database == "" -> nil
      Repo.filesystem_database_path?(database) -> Path.expand(database)
      true -> database
    end
  end

  defp put_optional_handoff_opt(opts, _key, nil), do: opts
  defp put_optional_handoff_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp readiness_artifacts(repo, %WorkPackage{status: status} = work_package) when status in @ready_statuses do
    PlanningRepository.list_artifacts(repo, work_package.id)
  end

  defp readiness_artifacts(repo, %WorkPackage{} = work_package) do
    if artifact_backed_readiness_gate_required?(work_package) do
      PlanningRepository.list_artifacts(repo, work_package.id)
    else
      {:ok, []}
    end
  end

  defp artifact_backed_readiness_gate_required?(%WorkPackage{} = work_package) do
    Enum.any?(["recommendation_artifact_recorded", "review_artifacts_attached", "review_suite_result"], &required_gate?(work_package, &1))
  end

  defp readiness_findings(repo, %WorkPackage{status: status, id: work_package_id}) when status in @ready_statuses do
    PlanningRepository.list_findings(repo, work_package_id)
  end

  defp readiness_findings(_repo, %WorkPackage{}), do: {:ok, []}

  @spec work_package_detail(WorkPackage.t()) :: map()
  def work_package_detail(%WorkPackage{} = work_package) do
    %{
      id: work_package.id,
      kind: work_package.kind,
      title: redacted_text(work_package.title),
      repo: work_package.repo,
      base_branch: work_package.base_branch,
      branch_pattern: work_package.branch_pattern,
      product_description: redacted_text(work_package.product_description),
      engineering_scope: redacted_text(work_package.engineering_scope),
      allowed_file_globs: work_package.allowed_file_globs || [],
      policy_template: redacted_text(work_package.policy_template),
      acceptance_criteria: Enum.map(work_package.acceptance_criteria || [], &redacted_text/1),
      status: work_package.status,
      parent_id: work_package.parent_id,
      phase_id: work_package.phase_id,
      owner_id: work_package.owner_id,
      inserted_at: timestamp(work_package.inserted_at),
      updated_at: timestamp(work_package.updated_at)
    }
  end

  defp collect_or_error(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, item}, {:ok, items} -> {:cont, {:ok, [item | items]}}
      {:error, reason}, {:ok, _items} -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_board(repo, opts \\ []) do
    with {:ok, work_packages} <- WorkPackageRepository.list(repo),
         {:ok, contexts} <- card_contexts_for_packages(repo, work_packages) do
      cards = Enum.map(contexts, & &1.card)

      board = %{
        groups: group_cards(cards),
        statuses: WorkPackage.statuses(),
        total_count: length(cards)
      }

      maybe_put_active_blocking_edges(repo, board, contexts, opts)
    end
  end

  defp maybe_put_active_blocking_edges(repo, board, contexts, opts) do
    if Keyword.get(opts, :active_blocking_edges?, false) do
      put_active_blocking_edges(repo, board, contexts)
    else
      {:ok, board}
    end
  end

  defp put_active_blocking_edges(repo, board, contexts) do
    with {:ok, active_blocking_edges} <- active_blocking_edges_from_card_contexts(repo, contexts) do
      {:ok, Map.put(board, :active_blocking_edges, active_blocking_edges)}
    end
  end

  defp build_phase_board(repo, phase_id, filters) do
    with {:ok, phase} <- PhaseRepository.get(repo, phase_id),
         {:ok, work_packages} <- WorkPackageRepository.list_for_phase(repo, phase_id),
         summary_work_packages = filter_phase_work_packages(work_packages, phase_scope_filters(filters)),
         scoped_work_packages = filter_phase_work_packages(work_packages, filters),
         {:ok, cards} <- cards_for_packages(repo, scoped_work_packages) do
      {:ok,
       %{
         phase: phase(phase),
         groups: group_cards(cards),
         statuses: WorkPackage.statuses(),
         total_count: length(cards),
         summary: phase_progress_summary(summary_work_packages)
       }}
    end
  end

  defp phase_progress_summary(work_packages) do
    phase_children = Enum.filter(work_packages, &phase_child_package?/1)
    progress_children = Enum.reject(phase_children, &(&1.status in @dropped_child_statuses))

    %{
      child_count: length(progress_children),
      merged_child_count: Enum.count(progress_children, &(&1.status == "merged_into_phase")),
      ready_child_count: Enum.count(progress_children, &(&1.status == "ready_for_architect_merge")),
      merging_child_count: Enum.count(progress_children, &(&1.status == "merging_into_phase")),
      open_child_count: Enum.count(progress_children, &(&1.status not in @non_open_child_statuses))
    }
  end

  defp phase_child_package?(%WorkPackage{} = work_package) do
    work_package.kind == "phase_child" and filled_string?(work_package.parent_id)
  end

  defp filter_phase_work_packages(work_packages, filters) do
    Enum.filter(work_packages, &phase_work_package_matches_filters?(&1, filters))
  end

  defp phase_scope_filters(filters) do
    Enum.filter(filters, fn
      {:repo, repo} when is_binary(repo) -> true
      {:base_branch, base_branch} when is_binary(base_branch) -> true
      _filter -> false
    end)
  end

  defp phase_work_package_matches_filters?(%WorkPackage{} = work_package, filters) do
    Enum.all?(filters, fn
      {:repo, repo} when is_binary(repo) -> work_package.repo == repo
      {:base_branch, base_branch} when is_binary(base_branch) -> work_package.base_branch == base_branch
      _filter -> true
    end)
  end

  defp require_work_request_scope(repo, %WorkRequest{} = work_request, %AccessGrant{} = grant) do
    with {:ok, filters} <- work_request_filters_for_grant(repo, grant) do
      if work_request_matches_filters?(work_request, filters) do
        :ok
      else
        {:error, :forbidden}
      end
    end
  end

  defp require_visible_work_request_scope(repo, %WorkRequest{} = work_request, %AccessGrant{} = grant) do
    case require_work_request_scope(repo, work_request, grant) do
      :ok -> :ok
      {:error, :forbidden} -> {:error, :not_found}
      error -> error
    end
  end

  defp work_request_matches_filters?(%WorkRequest{} = work_request, filters) do
    Enum.all?(filters, fn
      {:repo, repo} when is_binary(repo) -> work_request.repo == repo
      {:base_branch, base_branch} when is_binary(base_branch) -> work_request.base_branch == base_branch
      _filter -> true
    end)
  end

  defp explicit_phase_architect_grant?(%AccessGrant{grant_role: "architect", phase_id: phase_id}) when is_binary(phase_id) do
    String.trim(phase_id) != ""
  end

  defp explicit_phase_architect_grant?(%AccessGrant{}), do: false

  defp legacy_work_request_filters_for_grant(repo, %AccessGrant{
         grant_role: "architect",
         work_package_id: work_package_id,
         phase_id: nil
       })
       when is_binary(work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %WorkPackage{} = anchor} -> repo_base_filters(anchor.repo, anchor.base_branch)
      {:error, :not_found} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_work_request_filters_for_grant(_repo, %AccessGrant{}), do: {:error, :forbidden}

  defp repo_base_filters(repo, base_branch) do
    with {:ok, repo} <- frozen_scope_value(repo),
         {:ok, base_branch} <- frozen_scope_value(base_branch) do
      {:ok, repo: repo, base_branch: base_branch}
    end
  end

  defp frozen_scope_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :forbidden}
      trimmed -> {:ok, trimmed}
    end
  end

  defp frozen_scope_value(_value), do: {:error, :forbidden}

  defp require_frozen_scope_match(%WorkPackage{} = anchor, %AccessGrant{} = grant) do
    if grant.scope_repo == anchor.repo and grant.scope_base_branch == anchor.base_branch do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp cards_for_packages(repo, work_packages) do
    with {:ok, contexts} <- card_contexts_for_packages(repo, work_packages) do
      {:ok, Enum.map(contexts, & &1.card)}
    end
  end

  defp card_contexts_for_packages(repo, work_packages) do
    work_packages
    |> Enum.map(&card_context(repo, &1))
    |> collect_or_error()
  end

  defp active_blocking_edges_from_card_contexts(_repo, []), do: {:ok, []}

  defp active_blocking_edges_from_card_contexts(repo, contexts) do
    work_package_ids = Enum.map(contexts, & &1.work_package.id)

    with {:ok, planned_slices_by_work_package_id} <- linked_planned_slices_by_work_package_id(repo, work_package_ids) do
      edges =
        contexts
        |> Enum.flat_map(fn %{work_package: work_package, blockers: blockers} ->
          linked_planned_slice = Map.get(planned_slices_by_work_package_id, work_package.id)

          blockers
          |> Enum.filter(& &1.active)
          |> Enum.map(&active_blocking_edge(&1, work_package, linked_planned_slice))
        end)
        |> sort_active_blocking_edges()

      {:ok, edges}
    end
  end

  defp linked_planned_slices_by_work_package_id(_repo, []), do: {:ok, %{}}

  defp linked_planned_slices_by_work_package_id(repo, work_package_ids) do
    planned_slices =
      repo.all(
        from(planned_slice in PlannedSlice,
          where: planned_slice.work_package_id in ^work_package_ids,
          order_by: [asc: planned_slice.work_package_id, asc: planned_slice.sequence, asc: planned_slice.id]
        )
      )

    planned_slices_by_work_package_id =
      planned_slices
      |> Enum.group_by(& &1.work_package_id)
      |> Map.new(fn
        {work_package_id, [planned_slice]} ->
          {work_package_id, planned_slice}

        {work_package_id, _duplicates} ->
          {work_package_id, nil}
      end)

    {:ok, planned_slices_by_work_package_id}
  end

  defp active_blocking_edge(blocker, %WorkPackage{} = work_package, %PlannedSlice{} = planned_slice) do
    fallback_from = %{kind: "slice", id: planned_slice.id}
    from = blocker.blocked_by || fallback_from
    to = blocker.blocked_item || %{kind: "work_package", id: work_package.id}

    blocker
    |> build_active_blocking_edge(work_package, from, to)
    |> Map.put(:work_request_id, planned_slice.work_request_id)
    |> Map.put(:planned_slice_id, planned_slice.id)
  end

  defp active_blocking_edge(blocker, %WorkPackage{} = work_package, _linked_planned_slice) do
    from = blocker.blocked_by || %{kind: "work_package", id: work_package.id}
    to = blocker.blocked_item || %{kind: "work_package", id: work_package.id}

    build_active_blocking_edge(blocker, work_package, from, to)
  end

  defp build_active_blocking_edge(blocker, %WorkPackage{} = work_package, from, to) do
    %{
      id: active_blocking_edge_id(blocker.id, from, to),
      blocker_id: blocker.id,
      from: from,
      to: to,
      summary: blocker.summary,
      body: blocker.body,
      updated_at: blocker.updated_at,
      work_package_id: work_package.id
    }
  end

  defp active_blocking_edge_id(blocker_id, from, to) do
    material = [blocker_id, from.kind, from.id, to.kind, to.id]

    "active_blocking_edge_" <> Base.url_encode64(:crypto.hash(:sha256, Enum.join(material, ":")), padding: false)
  end

  defp sort_active_blocking_edges(edges) do
    Enum.sort_by(edges, fn edge ->
      from = Map.fetch!(edge, :from)
      to = Map.fetch!(edge, :to)

      {
        edge.updated_at || "",
        edge.id || "",
        from.kind || "",
        from.id || "",
        to.kind || "",
        to.id || ""
      }
    end)
  end

  defp work_request_cards(repo, work_requests) do
    with {:ok, summaries} <- work_request_card_summaries(repo, work_requests) do
      {:ok, Enum.map(work_requests, &work_request_card(&1, summaries))}
    end
  end

  defp ordered_work_requests(work_requests) do
    Enum.sort_by(work_requests, fn %WorkRequest{} = work_request ->
      {sortable_timestamp(work_request.inserted_at), work_request.id || ""}
    end)
  end

  defp ordered_sequence_records(records) do
    Enum.sort_by(records, fn record ->
      {Map.get(record, :sequence) || 0, Map.get(record, :id) || ""}
    end)
  end

  defp sortable_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp sortable_timestamp(_timestamp), do: ""

  defp planning_state(repo, work_package_id) do
    case PlanningRepository.get_state(repo, work_package_id) do
      {:ok, %State{} = state} ->
        {:ok, state}

      {:error, :not_found} ->
        with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
          {:ok, %State{work_package: work_package}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_read(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)

    if message |> String.downcase() |> busy_message?() do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end

  defp busy_message?(message) do
    String.contains?(message, "busy") or String.contains?(message, "locked")
  end

  defp group_cards(cards) do
    by_status = Enum.group_by(cards, & &1.status)

    Map.new(WorkPackage.statuses(), fn status ->
      {status, Map.get(by_status, status, [])}
    end)
  end

  defp summary(%State{} = state, grants, agent_runs, blockers, guidance_requests) do
    runtime = runtime_summary(agent_runs)

    %{
      artifact_count: length(state.artifacts),
      finding_count: length(state.findings),
      progress_event_count: length(state.progress_events),
      active_blocker_count: Enum.count(blockers, & &1.active),
      guidance_request_count: length(guidance_requests),
      grant_count: length(grants),
      active_grant_count: Enum.count(grants, &active_grant?/1),
      agent_run_count: length(agent_runs),
      active_agent_run_count: Enum.count(agent_runs, &(&1.status in AgentRun.active_statuses())),
      queued_agent_run_count: runtime.queued_count,
      stopped_agent_run_count: runtime.stopped_count,
      failed_agent_run_count: runtime.failed_count,
      stale_agent_run_count: runtime.stale_count,
      runtime: runtime,
      latest_progress_at: latest_progress_at(state.progress_events),
      plan: plan_summary(state.plan_nodes)
    }
  end

  defp work_request_card_summaries(_repo, []), do: {:ok, %{}}

  defp work_request_card_summaries(repo, work_requests) do
    work_request_ids = Enum.map(work_requests, & &1.id)

    with {:ok, question_counts} <- work_request_question_counts(repo, work_request_ids),
         {:ok, decision_counts} <- work_request_decision_counts(repo, work_request_ids),
         {:ok, planned_slice_counts} <- work_request_planned_slice_counts(repo, work_request_ids) do
      summaries =
        Map.new(work_request_ids, fn work_request_id ->
          {work_request_id,
           %{
             open_question_count: status_count(question_counts, work_request_id, "open"),
             answered_question_count: status_count(question_counts, work_request_id, "answered"),
             closed_question_count: status_count(question_counts, work_request_id, "closed"),
             decision_count: Map.get(decision_counts, work_request_id, 0),
             planned_slice_count: status_count(planned_slice_counts, work_request_id, "planned"),
             approved_slice_count: status_count(planned_slice_counts, work_request_id, "approved"),
             dispatched_slice_count: status_count(planned_slice_counts, work_request_id, "dispatched"),
             skipped_slice_count: status_count(planned_slice_counts, work_request_id, "skipped")
           }}
        end)

      {:ok, summaries}
    end
  end

  defp work_request_question_counts(repo, work_request_ids) do
    rows =
      chunked_work_request_rows(work_request_ids, fn chunk ->
        from(question in ClarificationQuestion,
          where: question.work_request_id in ^chunk,
          select: {question.work_request_id, question.status}
        )
        |> repo.all()
      end)

    {:ok, status_counts(rows)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp work_request_decision_counts(repo, work_request_ids) do
    rows =
      chunked_work_request_rows(work_request_ids, fn chunk ->
        from(decision in DecisionLogEntry,
          where: decision.work_request_id in ^chunk,
          select: decision.work_request_id
        )
        |> repo.all()
      end)

    {:ok, Enum.frequencies(rows)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp work_request_planned_slice_counts(repo, work_request_ids) do
    rows =
      chunked_work_request_rows(work_request_ids, fn chunk ->
        from(planned_slice in PlannedSlice,
          where: planned_slice.work_request_id in ^chunk,
          select: {planned_slice.work_request_id, planned_slice.status}
        )
        |> repo.all()
      end)

    {:ok, status_counts(rows)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp chunked_work_request_rows(work_request_ids, fetch_chunk) do
    work_request_ids
    |> Enum.chunk_every(@work_request_count_chunk_size)
    |> Enum.flat_map(fetch_chunk)
  end

  defp status_counts(rows) do
    Enum.reduce(rows, %{}, fn {work_request_id, status}, counts ->
      Map.update(counts, work_request_id, %{status => 1}, &Map.update(&1, status, 1, fn count -> count + 1 end))
    end)
  end

  defp status_count(counts, work_request_id, status) do
    counts
    |> Map.get(work_request_id, %{})
    |> Map.get(status, 0)
  end

  defp work_request_card(%WorkRequest{} = work_request, summaries) do
    Map.merge(Map.fetch!(summaries, work_request.id), %{
      id: work_request.id,
      title: redacted_text(work_request.title),
      repo: work_request.repo,
      base_branch: work_request.base_branch,
      work_type: work_request.work_type,
      desired_dispatch_shape: work_request.desired_dispatch_shape,
      status: work_request.status,
      inserted_at: timestamp(work_request.inserted_at),
      updated_at: timestamp(work_request.updated_at)
    })
  end

  defp solo_session_cards(repo, sessions) do
    session_ids = Enum.map(sessions, & &1.id)

    with {:ok, entry_counts} <- solo_session_entry_counts(repo, session_ids),
         {:ok, latest_entries} <- latest_solo_session_entries(repo, session_ids) do
      cards =
        Enum.map(sessions, fn %SoloSession{} = session ->
          solo_session_card(session, Map.get(entry_counts, session.id, []), Map.get(latest_entries, session.id))
        end)

      {:ok, cards}
    end
  end

  defp solo_session_entry_counts(_repo, []), do: {:ok, %{}}

  defp solo_session_entry_counts(repo, session_ids) do
    rows =
      session_ids
      |> Enum.chunk_every(@solo_session_query_chunk_size)
      |> Enum.flat_map(fn chunk ->
        repo.all(
          from(entry in SoloSessionEntry,
            where: entry.solo_session_id in ^chunk,
            group_by: [entry.solo_session_id, entry.entry_kind],
            select: {entry.solo_session_id, entry.entry_kind, count(entry.id)}
          )
        )
      end)

    counts =
      Enum.reduce(rows, %{}, fn {session_id, kind, count}, acc ->
        entry_count = %{kind: kind || "unknown", label: status_label(kind || "unknown"), count: count}
        Map.update(acc, session_id, [entry_count], &[entry_count | &1])
      end)
      |> Map.new(fn {session_id, counts} ->
        {session_id, Enum.sort_by(counts, & &1.kind)}
      end)

    {:ok, counts}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp latest_solo_session_entries(_repo, []), do: {:ok, %{}}

  defp latest_solo_session_entries(repo, session_ids) do
    entries =
      session_ids
      |> Enum.chunk_every(@solo_session_query_chunk_size)
      |> Enum.flat_map(fn chunk -> repo.all(latest_solo_session_entries_query(chunk)) end)

    {:ok, Map.new(entries, &{&1.solo_session_id, solo_session_entry(&1)})}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp latest_solo_session_entries_query(session_ids) do
    from(entry in SoloSessionEntry,
      where: entry.solo_session_id in ^session_ids,
      where:
        entry.sequence ==
          fragment(
            """
            SELECT MAX(latest.sequence)
            FROM sympp_solo_session_entries AS latest
            WHERE latest.solo_session_id = ?
            """,
            entry.solo_session_id
          ),
      order_by: [asc: entry.solo_session_id, desc: entry.created_at, desc: entry.id],
      select: %{
        solo_session_id: entry.solo_session_id,
        entry_kind: entry.entry_kind,
        status: entry.status,
        title: entry.title,
        body: entry.body,
        created_at: entry.created_at
      }
    )
  end

  defp solo_session_card(%SoloSession{} = session, entry_counts, latest_entry) do
    %{
      id: session.id,
      title: solo_session_title(session),
      repo: session.repo,
      base_branch: session.base_branch,
      caller_id: redacted_text(session.caller_id),
      status: session.status,
      last_activity_at: timestamp(session.last_activity_at),
      inserted_at: timestamp(session.inserted_at),
      updated_at: timestamp(session.updated_at),
      entry_counts: entry_counts,
      latest_entry: latest_entry
    }
  end

  defp solo_session_detail(%SoloSession{} = session) do
    %{
      id: session.id,
      title: solo_session_title(session),
      repo: session.repo,
      base_branch: session.base_branch,
      workspace_path: redacted_text(session.workspace_path),
      caller_id: redacted_text(session.caller_id),
      status: session.status,
      last_activity_at: timestamp(session.last_activity_at),
      archived_at: timestamp(session.archived_at),
      inserted_at: timestamp(session.inserted_at),
      updated_at: timestamp(session.updated_at)
    }
  end

  defp solo_session_title(%SoloSession{title: title, id: id}) do
    title
    |> redacted_text()
    |> present_text()
    |> Kernel.||(id)
  end

  defp solo_session_entry(entry) when is_map(entry) do
    %{
      kind: Map.get(entry, :entry_kind),
      kind_label: status_label(Map.get(entry, :entry_kind)),
      status: Map.get(entry, :status),
      title: entry |> Map.get(:title) |> redacted_text() |> snippet(@solo_session_snippet_limit),
      body: entry |> Map.get(:body) |> redacted_text() |> snippet(@solo_session_snippet_limit),
      created_at: entry |> Map.get(:created_at) |> timestamp()
    }
  end

  defp solo_session_detail_entry(%SoloSessionEntry{} = entry) do
    %{
      id: entry.id,
      sequence: entry.sequence,
      kind: entry.entry_kind,
      kind_label: status_label(entry.entry_kind),
      status: entry.status,
      status_label: status_label(entry.status),
      title: entry.title |> redacted_text() |> present_text(),
      body: entry.body |> redacted_text() |> present_text(),
      created_at: timestamp(entry.created_at),
      updated_at: timestamp(entry.updated_at)
    }
  end

  defp present_text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_text(_value), do: nil

  defp snippet(nil, _limit), do: nil

  defp snippet(value, limit) when is_binary(value) do
    value =
      value
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      value == "" -> nil
      String.length(value) <= limit -> value
      true -> String.slice(value, 0, max(limit - 3, 0)) <> "..."
    end
  end

  defp status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_label(status), do: to_string(status)

  defp human_guidance_request_cards(repo) do
    rows =
      repo.all(
        from(guidance_request in GuidanceRequest,
          join: work_package in WorkPackage,
          on: work_package.id == guidance_request.work_package_id,
          where: guidance_request.status == "human_info_needed",
          order_by: [asc: guidance_request.inserted_at, asc: guidance_request.id],
          select: {guidance_request, work_package}
        )
      )

    {:ok, Enum.map(rows, fn {guidance_request, work_package} -> guidance_request_card(guidance_request, work_package) end)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp guidance_request_card(%GuidanceRequest{} = guidance_request, %WorkPackage{} = work_package) do
    guidance_request(guidance_request)
    |> Map.merge(%{
      work_package_title: redacted_text(work_package.title),
      package_kind: work_package.kind,
      repo: work_package.repo,
      base_branch: work_package.base_branch,
      phase_id: work_package.phase_id
    })
  end

  defp work_request_detail(%WorkRequest{} = work_request) do
    %{
      id: work_request.id,
      title: redacted_text(work_request.title),
      repo: work_request.repo,
      base_branch: work_request.base_branch,
      work_type: work_request.work_type,
      human_description: redacted_text(work_request.human_description),
      constraints: redacted_json(work_request.constraints || %{}),
      desired_dispatch_shape: work_request.desired_dispatch_shape,
      status: work_request.status,
      inserted_at: timestamp(work_request.inserted_at),
      updated_at: timestamp(work_request.updated_at)
    }
  end

  defp guidance_request(%GuidanceRequest{} = guidance_request) do
    %{
      id: guidance_request.id,
      work_package_id: guidance_request.work_package_id,
      summary: redacted_text(guidance_request.summary),
      question: redacted_text(guidance_request.question),
      context: redacted_text(guidance_request.context),
      status: guidance_request.status,
      requested_by: redacted_text(guidance_request.requested_by),
      answer: redacted_text(guidance_request.answer),
      answered_by: redacted_text(guidance_request.answered_by),
      answered_at: timestamp(guidance_request.answered_at),
      human_info_reason: redacted_text(guidance_request.human_info_reason),
      recommended_language: redacted_text(guidance_request.recommended_language),
      decision_prompt: redacted_json(guidance_request.decision_prompt),
      blocker_id: guidance_request.blocker_id,
      inserted_at: timestamp(guidance_request.inserted_at),
      updated_at: timestamp(guidance_request.updated_at)
    }
  end

  defp clarification_question(%ClarificationQuestion{} = question) do
    %{
      id: question.id,
      work_request_id: question.work_request_id,
      sequence: question.sequence,
      category: redacted_text(question.category),
      question: redacted_text(question.question),
      why_needed: redacted_text(question.why_needed),
      decision_prompt: redacted_json(question.decision_prompt),
      status: question.status,
      asked_by_agent_run_id: question.asked_by_agent_run_id,
      answer: redacted_text(question.answer),
      answered_by: redacted_text(question.answered_by),
      answered_at: timestamp(question.answered_at),
      inserted_at: timestamp(question.inserted_at),
      updated_at: timestamp(question.updated_at)
    }
  end

  defp decision_log_entry(%DecisionLogEntry{} = decision) do
    %{
      id: decision.id,
      work_request_id: decision.work_request_id,
      sequence: decision.sequence,
      source_type: decision.source_type,
      source_id: redacted_text(decision.source_id),
      decision: redacted_text(decision.decision),
      rationale: redacted_text(decision.rationale),
      scope_impact: redacted_text(decision.scope_impact),
      created_by: redacted_text(decision.created_by),
      created_at: timestamp(decision.created_at),
      inserted_at: timestamp(decision.inserted_at),
      updated_at: timestamp(decision.updated_at)
    }
  end

  defp planned_slice(%PlannedSlice{} = planned_slice, work_package_statuses, opts) do
    %{
      id: planned_slice.id,
      work_request_id: planned_slice.work_request_id,
      sequence: planned_slice.sequence,
      title: redacted_text(planned_slice.title),
      goal: redacted_text(planned_slice.goal),
      work_package_kind: planned_slice.work_package_kind,
      target_base_branch: planned_slice.target_base_branch,
      branch_pattern: redacted_text(planned_slice.branch_pattern),
      owned_file_globs: Enum.map(planned_slice.owned_file_globs || [], &redacted_text/1),
      forbidden_file_globs: Enum.map(planned_slice.forbidden_file_globs || [], &redacted_text/1),
      acceptance_criteria: Enum.map(planned_slice.acceptance_criteria || [], &redacted_text/1),
      validation_steps: Enum.map(planned_slice.validation_steps || [], &redacted_text/1),
      review_lanes: planned_slice.review_lanes || [],
      stop_conditions: Enum.map(planned_slice.stop_conditions || [], &redacted_text/1),
      status: planned_slice.status,
      inserted_at: timestamp(planned_slice.inserted_at),
      updated_at: timestamp(planned_slice.updated_at)
    }
    |> maybe_put_dispatch_linkage(planned_slice, work_package_statuses, opts)
  end

  defp maybe_put_dispatch_linkage(payload, %PlannedSlice{} = planned_slice, work_package_contexts, opts) do
    if Keyword.get(opts, :include_dispatch_linkage?, false) do
      work_package_context = Map.get(work_package_contexts, planned_slice.work_package_id)

      payload
      |> Map.put(:work_package_id, planned_slice.work_package_id)
      |> Map.put(:work_package_status, linked_work_package_status(work_package_context))
      |> Map.put(:dispatched_at, timestamp(planned_slice.dispatched_at))
      |> Map.put(:operational_state, planned_slice_operational_state(planned_slice, work_package_context))
    else
      payload
    end
  end

  defp planned_slice_work_package_contexts(repo, planned_slices) do
    work_package_ids =
      planned_slices
      |> Enum.map(& &1.work_package_id)
      |> Enum.filter(&filled_string?/1)
      |> Enum.uniq()

    if work_package_ids == [] do
      {:ok, %{}}
    else
      work_packages =
        repo.all(
          from(work_package in WorkPackage,
            where: work_package.id in ^work_package_ids
          )
        )

      {:ok, linked_work_package_contexts(repo, work_packages)}
    end
  end

  defp linked_work_package_contexts(_repo, []), do: %{}

  defp linked_work_package_contexts(repo, work_packages) do
    work_package_ids = Enum.map(work_packages, & &1.id)
    progress_events_by_id = grouped_progress_events(repo, work_package_ids)
    plan_nodes_by_id = grouped_plan_nodes(repo, work_package_ids)
    artifacts_by_id = grouped_artifacts(repo, work_package_ids)
    findings_by_id = grouped_findings(repo, work_package_ids)
    agent_runs_by_id = grouped_agent_runs(repo, work_package_ids)
    grants_by_id = grouped_access_grants(repo, work_package_ids)

    Map.new(work_packages, fn %WorkPackage{} = work_package ->
      progress_events = Map.get(progress_events_by_id, work_package.id, [])
      plan_nodes = Map.get(plan_nodes_by_id, work_package.id, [])
      artifacts = Map.get(artifacts_by_id, work_package.id, [])
      findings = Map.get(findings_by_id, work_package.id, [])
      agent_runs = Map.get(agent_runs_by_id, work_package.id, [])
      grants = Map.get(grants_by_id, work_package.id, [])
      blockers = blockers(progress_events)
      runtime = runtime_summary(agent_runs)
      metadata = metadata(progress_events, artifacts, work_package.id)
      readiness_context = readiness_context(work_package, plan_nodes, progress_events, artifacts, findings)
      operational_state = work_package_operational_state(work_package, progress_events, blockers, runtime, metadata, readiness_context, grants)

      {work_package.id, %{work_package: work_package, card: %{operational_state: operational_state}}}
    end)
  end

  defp grouped_progress_events(repo, work_package_ids) do
    repo.all(
      from(progress_event in ProgressEvent,
        where: progress_event.work_package_id in ^work_package_ids,
        order_by: [asc: progress_event.work_package_id, asc: progress_event.sequence, asc: progress_event.inserted_at]
      )
    )
    |> records_by_work_package_id()
  end

  defp grouped_plan_nodes(repo, work_package_ids) do
    repo.all(
      from(plan_node in PlanNode,
        where: plan_node.work_package_id in ^work_package_ids,
        order_by: [asc: plan_node.work_package_id, asc: plan_node.position, asc: plan_node.inserted_at]
      )
    )
    |> records_by_work_package_id()
  end

  defp grouped_artifacts(repo, work_package_ids) do
    repo.all(
      from(artifact in Artifact,
        where: artifact.work_package_id in ^work_package_ids,
        order_by: [asc: artifact.work_package_id, asc: artifact.sequence, asc: artifact.inserted_at]
      )
    )
    |> records_by_work_package_id()
  end

  defp grouped_findings(repo, work_package_ids) do
    repo.all(
      from(finding in Finding,
        where: finding.work_package_id in ^work_package_ids,
        order_by: [asc: finding.work_package_id, asc: finding.sequence, asc: finding.inserted_at]
      )
    )
    |> records_by_work_package_id()
  end

  defp grouped_agent_runs(repo, work_package_ids) do
    repo.all(
      from(agent_run in AgentRun,
        where: agent_run.work_package_id in ^work_package_ids,
        order_by: [asc: agent_run.work_package_id, asc: agent_run.started_at, asc: agent_run.inserted_at]
      )
    )
    |> records_by_work_package_id()
  end

  defp grouped_access_grants(repo, work_package_ids) do
    repo.all(
      from(access_grant in AccessGrant,
        where: access_grant.work_package_id in ^work_package_ids,
        order_by: [asc: access_grant.work_package_id, asc: access_grant.inserted_at]
      )
    )
    |> records_by_work_package_id()
  end

  defp records_by_work_package_id(records), do: Enum.group_by(records, & &1.work_package_id)

  defp work_request_summary(questions, decisions, planned_slices) do
    %{
      open_question_count: Enum.count(questions, &(&1.status == "open")),
      answered_question_count: Enum.count(questions, &(&1.status == "answered")),
      closed_question_count: Enum.count(questions, &(&1.status == "closed")),
      decision_count: length(decisions),
      planned_slice_count: Enum.count(planned_slices, &(&1.status == "planned")),
      approved_slice_count: Enum.count(planned_slices, &(&1.status == "approved")),
      dispatched_slice_count: Enum.count(planned_slices, &(&1.status == "dispatched")),
      skipped_slice_count: Enum.count(planned_slices, &(&1.status == "skipped"))
    }
  end

  defp plan_node(plan_node) do
    %{
      id: plan_node.id,
      title: redacted_text(plan_node.title),
      body: redacted_text(plan_node.body),
      status: plan_node.status,
      position: plan_node.position,
      created_at: timestamp(plan_node.created_at),
      updated_at: timestamp(plan_node.updated_at)
    }
  end

  defp finding(%Finding{} = finding) do
    %{
      id: finding.id,
      title: redacted_text(finding.title),
      body: redacted_text(finding.body),
      severity: finding.severity,
      sequence: finding.sequence,
      created_at: timestamp(finding.created_at),
      access_grant_id: finding.access_grant_id
    }
  end

  defp progress_event(%ProgressEvent{} = event) do
    %{
      id: event.id,
      summary: redacted_text(event.summary),
      body: redacted_text(event.body),
      status: event.status,
      sequence: event.sequence,
      actor: actor(event),
      agent_run_id: event.agent_run_id,
      payload: redacted_json(event.payload || %{}),
      created_at: timestamp(event.created_at)
    }
  end

  defp timeline_progress_event(%ProgressEvent{} = event) do
    event
    |> progress_event()
    |> Map.merge(%{type: "progress", timeline_order: event.sequence || 0})
  end

  defp timeline_finding(%Finding{} = finding) do
    finding
    |> finding()
    |> Map.merge(%{type: "finding", timeline_order: finding.sequence || 0})
  end

  defp timeline_sort_key(%{created_at: created_at, timeline_order: order, id: id}) do
    {timestamp_sort_value(created_at), order || 0, id || ""}
  end

  defp artifact(%Artifact{} = artifact) do
    %{
      id: artifact.id,
      path: redacted_text(artifact.path),
      title: redacted_text(artifact.title),
      kind: artifact.kind,
      uri: redacted_uri(artifact.uri),
      sequence: artifact.sequence,
      created_at: timestamp(artifact.created_at)
    }
  end

  defp grant(%AccessGrant{} = grant) do
    %{
      id: grant.id,
      work_package_id: grant.work_package_id,
      phase_id: grant.phase_id,
      display_key: grant.display_key,
      grant_role: grant.grant_role,
      capabilities: grant.capabilities || [],
      expires_at: timestamp(grant.expires_at),
      revoked_at: timestamp(grant.revoked_at),
      claimed_at: timestamp(grant.claimed_at),
      claimed_by: grant.claimed_by,
      status: grant_status(grant)
    }
  end

  defp phase(%Phase{} = phase) do
    %{
      id: phase.id,
      title: redacted_text(phase.title),
      description: redacted_text(phase.description),
      status: phase.status,
      inserted_at: timestamp(phase.inserted_at),
      updated_at: timestamp(phase.updated_at)
    }
  end

  defp agent_run(%AgentRun{} = run) do
    %{
      id: run.id,
      work_package_id: run.work_package_id,
      access_grant_id: run.access_grant_id,
      actor_id: run.actor_id,
      status: run.status,
      runtime_state: runtime_state(run),
      stale: stale_agent_run?(run),
      stale_after_seconds: @stale_heartbeat_after_seconds,
      attempt: run.attempt,
      worker_host: redacted_text(run.worker_host),
      worker_task_handle: redacted_text(run.worker_task_handle),
      workspace_path: redacted_text(run.workspace_path),
      session_id: redacted_text(run.session_id),
      codex_input_tokens: run.codex_input_tokens,
      codex_output_tokens: run.codex_output_tokens,
      codex_total_tokens: run.codex_total_tokens,
      turn_count: run.turn_count,
      started_at: timestamp(run.started_at),
      last_seen_at: timestamp(run.last_seen_at),
      finished_at: timestamp(run.finished_at),
      reason: redacted_text(run.reason)
    }
  end

  defp runtime_summary(agent_runs) do
    runs = Enum.map(agent_runs, &agent_run/1)

    %{
      stale_heartbeat_after_seconds: @stale_heartbeat_after_seconds,
      active_count: Enum.count(runs, &(&1.runtime_state == "active")),
      queued_count: Enum.count(runs, &(&1.runtime_state == "queued")),
      stopped_count: Enum.count(runs, &(&1.runtime_state == "stopped")),
      failed_count: Enum.count(runs, &(&1.status == "failed")),
      completed_count: Enum.count(runs, &(&1.status == "completed")),
      terminal_count: Enum.count(runs, &(&1.runtime_state in ["stopped", "terminal"])),
      stale_count: Enum.count(runs, & &1.stale)
    }
  end

  @spec stale_agent_run?(AgentRun.t()) :: boolean()
  def stale_agent_run?(%AgentRun{} = run) do
    stale_agent_run?(run, DateTime.utc_now(:microsecond), @stale_heartbeat_after_seconds)
  end

  @spec stale_agent_run?(AgentRun.t(), DateTime.t(), non_neg_integer()) :: boolean()
  def stale_agent_run?(%AgentRun{status: status, last_seen_at: %DateTime{} = last_seen_at}, %DateTime{} = now, threshold_seconds)
      when status in ["starting", "running", "retrying"] and is_integer(threshold_seconds) and threshold_seconds >= 0 do
    DateTime.diff(now, last_seen_at, :second) >= threshold_seconds
  end

  def stale_agent_run?(%AgentRun{}, %DateTime{}, _threshold_seconds), do: false

  defp runtime_state(%AgentRun{status: "starting"}), do: "queued"
  defp runtime_state(%AgentRun{status: status}) when status in ["running", "retrying"], do: "active"
  defp runtime_state(%AgentRun{status: "stopped"}), do: "stopped"
  defp runtime_state(%AgentRun{status: status}) when status in ["completed", "failed"], do: "terminal"
  defp runtime_state(%AgentRun{}), do: "unknown"

  defp latest_active_agent_run(agent_runs) do
    agent_runs
    |> latest_active_run()
    |> case do
      %AgentRun{} = run -> agent_run(run)
      nil -> nil
    end
  end

  defp latest_active_run(agent_runs) do
    agent_runs
    |> Enum.filter(&(runtime_state(&1) in ["active", "queued"]))
    |> List.last()
  end

  defp latest_progress_at(progress_events) do
    progress_events
    |> Enum.max_by(&timestamp_sort_value(&1.created_at), fn -> nil end)
    |> case do
      %ProgressEvent{created_at: created_at} -> timestamp(created_at)
      nil -> nil
    end
  end

  defp plan_summary(plan_nodes) do
    total = length(plan_nodes)
    completed = Enum.count(plan_nodes, &(&1.status in ["done", "completed", "skipped"]))

    %{
      total_count: total,
      completed_count: completed,
      open_count: max(total - completed, 0)
    }
  end

  defp work_package_operational_state(%WorkPackage{} = work_package, progress_events, blockers, runtime, metadata, readiness_context, grants) do
    missing_readiness = if work_package.status in @ready_statuses, do: missing_readiness_evidence(readiness_context), else: []
    delivery_started = delivery_started?(work_package, progress_events, runtime, metadata, grants)
    attention_items = work_package_attention_items(work_package, blockers, metadata, missing_readiness, delivery_started)

    work_package
    |> base_work_package_operational_state(blockers, metadata, missing_readiness, delivery_started)
    |> Map.put(:attention_items, attention_items)
  end

  defp base_work_package_operational_state(%WorkPackage{status: status}, blockers, metadata, missing_readiness, delivery_started) do
    active_blocker_count = blockers |> active_blockers() |> length()

    cond do
      active_blocker_count > 0 ->
        operational_state("blocked", "Blocked", "critical", blocker_detail(active_blocker_count), status)

      status == "blocked" ->
        operational_state("blocked", "Blocked", "critical", "Raw lifecycle status is blocked.", status)

      pr_merged?(metadata) and open_package_status?(status) ->
        operational_state("merged", "Merged", "success", "PR metadata reports a merged pull request while raw status is #{status}.", status)

      status in @merged_package_statuses ->
        operational_state("merged", "Merged", "success", "Raw lifecycle status indicates merged delivery.", status)

      status in @closed_package_statuses ->
        operational_state(status, status_label(status), "neutral", "Raw lifecycle status is #{status}.", status)

      status == "merging_into_phase" ->
        operational_state("merging", "Merging", "info", "Package is being merged into its phase.", status)

      status in @ready_statuses ->
        tone = if missing_readiness == [], do: "success", else: "warning"
        reason = if missing_readiness == [], do: "Package is marked ready with required evidence present.", else: "Package is marked ready but evidence is incomplete."
        operational_state("merge_ready", "Ready For Merge", tone, reason, status)

      status == "ci_waiting" ->
        operational_state("ci_waiting", "CI Waiting", "info", "Package is waiting on validation or CI evidence.", status)

      status == "reviewing" or review_activity?(metadata) ->
        operational_state("reviewing", "Reviewing", "info", "Review evidence or lifecycle status indicates review is active.", status)

      delivery_started ->
        operational_state("in_progress", "In Progress", "info", "Worker, runtime, progress, PR, review, or lifecycle evidence indicates work has started.", status)

      status == "ready_for_worker" ->
        operational_state("ready_for_worker", "Ready For Worker", "neutral", "No linked delivery, worker, runtime, progress, blocker, review, PR, or merge activity is recorded.", status)

      status == "created" ->
        operational_state("created", "Created", "neutral", "Package has been created but is not ready for worker pickup.", status)

      true ->
        operational_state(status || "unknown", status_label(status), "neutral", "Raw lifecycle status is #{status || "unknown"}.", status)
    end
  end

  defp planned_slice_operational_state(%PlannedSlice{} = planned_slice, nil) do
    planned_slice
    |> base_unlinked_planned_slice_operational_state()
    |> Map.put(:attention_items, planned_slice_attention_items(planned_slice, nil))
  end

  defp planned_slice_operational_state(%PlannedSlice{} = planned_slice, %{card: card, work_package: %WorkPackage{} = work_package}) do
    linked_state = Map.fetch!(card, :operational_state)
    attention_items = planned_slice_attention_items(planned_slice, work_package, linked_state)

    cond do
      promoted_linked_operational_state?(linked_state) ->
        operational_state(
          linked_state.key,
          linked_state.label,
          linked_state.tone,
          "Linked WorkPackage #{work_package.id} is #{linked_state.label}.",
          planned_slice.status,
          attention_items
        )

      true ->
        linked_idle_planned_slice_operational_state(planned_slice, work_package, attention_items)
    end
  end

  defp base_unlinked_planned_slice_operational_state(%PlannedSlice{status: "approved"} = planned_slice) do
    operational_state("ready_for_worker", "Ready For Worker", "neutral", "Approved slice has no linked WorkPackage or delivery activity.", planned_slice.status)
  end

  defp base_unlinked_planned_slice_operational_state(%PlannedSlice{status: "planned"} = planned_slice) do
    operational_state("planned", "Planned", "neutral", "Slice is planned and has no linked WorkPackage.", planned_slice.status)
  end

  defp base_unlinked_planned_slice_operational_state(%PlannedSlice{status: "skipped"} = planned_slice) do
    operational_state("skipped", "Skipped", "neutral", "Slice was skipped before dispatch.", planned_slice.status)
  end

  defp base_unlinked_planned_slice_operational_state(%PlannedSlice{} = planned_slice) do
    operational_state("dispatched", "Dispatched", "warning", "Slice is marked dispatched but no linked WorkPackage is available.", planned_slice.status)
  end

  defp linked_idle_planned_slice_operational_state(%PlannedSlice{status: "approved"} = planned_slice, %WorkPackage{} = work_package, attention_items) do
    operational_state(
      "ready_for_worker",
      "Ready For Worker",
      "neutral",
      "Approved slice is linked to WorkPackage #{work_package.id}, which has not started.",
      planned_slice.status,
      attention_items
    )
  end

  defp linked_idle_planned_slice_operational_state(%PlannedSlice{status: "planned"} = planned_slice, %WorkPackage{} = work_package, attention_items) do
    operational_state(
      "planned",
      "Planned",
      "neutral",
      "Slice is linked to WorkPackage #{work_package.id}, which has not started.",
      planned_slice.status,
      attention_items
    )
  end

  defp linked_idle_planned_slice_operational_state(%PlannedSlice{status: "skipped"} = planned_slice, %WorkPackage{} = work_package, attention_items) do
    operational_state(
      "skipped",
      "Skipped",
      "neutral",
      "Skipped slice is linked to WorkPackage #{work_package.id}.",
      planned_slice.status,
      attention_items
    )
  end

  defp linked_idle_planned_slice_operational_state(%PlannedSlice{} = planned_slice, %WorkPackage{} = work_package, attention_items) do
    operational_state(
      "dispatched",
      "Dispatched",
      "neutral",
      "Slice is linked to WorkPackage #{work_package.id}, which has not started.",
      planned_slice.status,
      attention_items
    )
  end

  defp planned_slice_attention_items(%PlannedSlice{} = planned_slice, nil) do
    if planned_slice.status == "dispatched" and not filled_string?(planned_slice.work_package_id) do
      [
        %{
          key: "missing_linked_work_package",
          label: "Missing Linked WorkPackage",
          tone: "warning",
          reason: "Slice is marked dispatched without a linked WorkPackage."
        }
      ]
    else
      []
    end
  end

  defp planned_slice_attention_items(%PlannedSlice{} = planned_slice, %WorkPackage{} = work_package, linked_state) do
    inherited_items = Map.get(linked_state, :attention_items, [])

    maybe_idle_slice_attention =
      if planned_slice.status in ["planned", "approved"] and promoted_linked_operational_state?(linked_state) do
        [
          %{
            key: "linked_package_started_while_slice_idle",
            label: "Linked Package Started",
            tone: "warning",
            reason: "Linked WorkPackage #{work_package.id} has operational state #{linked_state.key} while slice status is #{planned_slice.status}."
          }
        ]
      else
        []
      end

    inherited_items ++ maybe_idle_slice_attention
  end

  defp linked_work_package_status(%{work_package: %WorkPackage{status: status}}), do: status
  defp linked_work_package_status(_work_package_context), do: nil

  defp promoted_linked_operational_state?(%{key: key}) do
    key in ["blocked", "in_progress", "reviewing", "ci_waiting", "merge_ready", "merging", "merged", "closed", "abandoned"]
  end

  defp promoted_linked_operational_state?(_state), do: false

  defp work_package_attention_items(%WorkPackage{} = work_package, blockers, metadata, missing_readiness, delivery_started) do
    [
      active_blocker_attention_item(blockers),
      pr_merged_attention_item(work_package, metadata),
      missing_readiness_attention_item(work_package, missing_readiness),
      ready_status_with_activity_attention_item(work_package, delivery_started)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp active_blocker_attention_item(blockers) do
    case active_blockers(blockers) do
      [] ->
        nil

      active ->
        %{
          key: "active_blocker",
          label: "Active Blocker",
          tone: "critical",
          reason: blocker_detail(length(active)),
          blocker_ids: Enum.map(active, & &1.id)
        }
    end
  end

  defp pr_merged_attention_item(%WorkPackage{status: status}, metadata) do
    if pr_merged?(metadata) and open_package_status?(status) do
      %{
        key: "pr_merged_raw_status_open",
        label: "Merged PR With Open Status",
        tone: "warning",
        reason: "PR metadata reports merged while raw package status remains #{status}."
      }
    end
  end

  defp missing_readiness_attention_item(%WorkPackage{status: status}, missing_readiness) when status in @ready_statuses do
    case missing_readiness do
      [] ->
        nil

      missing ->
        %{
          key: "missing_readiness_evidence",
          label: "Missing Readiness Evidence",
          tone: "warning",
          reason: missing_detail(missing),
          missing: missing
        }
    end
  end

  defp missing_readiness_attention_item(%WorkPackage{}, _missing_readiness), do: nil

  defp ready_status_with_activity_attention_item(%WorkPackage{status: "ready_for_worker"}, delivery_started) do
    if delivery_started do
      %{
        key: "ready_for_worker_with_activity",
        label: "Ready Status With Activity",
        tone: "warning",
        reason: "Raw status is ready_for_worker but worker, runtime, progress, PR, review, or merge activity is recorded."
      }
    end
  end

  defp ready_status_with_activity_attention_item(%WorkPackage{}, _delivery_started), do: nil

  defp active_blockers(blockers), do: Enum.filter(blockers, & &1.active)

  defp delivery_started?(%WorkPackage{status: status}, progress_events, runtime, metadata, grants) do
    status in @started_package_statuses or
      active_worker_grant?(grants) or
      runtime_activity?(runtime) or
      progress_events != [] or
      metadata_activity?(metadata)
  end

  defp active_worker_grant?(grants) do
    Enum.any?(grants, fn
      %AccessGrant{grant_role: "worker"} = grant -> active_grant?(grant)
      _grant -> false
    end)
  end

  defp runtime_activity?(runtime) when is_map(runtime) do
    Enum.any?([:active_count, :queued_count, :stopped_count, :failed_count, :completed_count, :terminal_count], &(Map.get(runtime, &1, 0) > 0))
  end

  defp runtime_activity?(_runtime), do: false

  defp metadata_activity?(metadata) when is_map(metadata) do
    Enum.any?([:branch, :pr, :review_progress, :review_package, :review_suite_result], &present_metadata_value?(Map.get(metadata, &1)))
  end

  defp metadata_activity?(_metadata), do: false

  defp review_activity?(metadata) when is_map(metadata) do
    Enum.any?([:review_progress, :review_package, :review_suite_result], &present_metadata_value?(Map.get(metadata, &1)))
  end

  defp review_activity?(_metadata), do: false

  defp present_metadata_value?(nil), do: false
  defp present_metadata_value?(value) when is_map(value), do: map_size(value) > 0
  defp present_metadata_value?(value) when is_list(value), do: value != []
  defp present_metadata_value?(_value), do: true

  defp pr_merged?(%{pr: %{"stale" => true}}), do: false
  defp pr_merged?(%{pr: pr}), do: pr_merged_payload?(pr)
  defp pr_merged?(_metadata), do: false

  defp pr_merged_payload?(%{} = pr) do
    merged_value?(map_value(pr, "merged")) or
      merged_value?(map_value(pr, "state")) or
      merged_value?(map_value(pr, "status")) or
      merged_value?(map_value(pr, "conclusion")) or
      merge_state_merged?(map_value(pr, "merge_state"))
  end

  defp pr_merged_payload?(_pr), do: false

  defp merge_state_merged?(%{} = merge_state) do
    merged_value?(map_value(merge_state, "merged")) or
      merged_value?(map_value(merge_state, "state")) or
      merged_value?(map_value(merge_state, "status")) or
      merged_value?(map_value(merge_state, "mergeable_state"))
  end

  defp merge_state_merged?(_merge_state), do: false

  defp map_value(%{} = map, key) when is_binary(key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp merged_value?(true), do: true

  defp merged_value?(value) when is_binary(value) do
    value |> String.trim() |> String.downcase() |> then(&(&1 in ["merged", "true"]))
  end

  defp merged_value?(_value), do: false

  defp open_package_status?(status), do: status not in @merged_package_statuses and status not in @closed_package_statuses

  defp operational_state(key, label, tone, reason, raw_status, attention_items \\ []) do
    %{
      key: key,
      label: label,
      tone: tone,
      reason: reason,
      raw_status: raw_status,
      attention_items: attention_items
    }
  end

  defp alert_indicators(%State{} = state, runtime) do
    state
    |> readiness_context(length(state.artifacts), length(state.findings))
    |> alert_indicators(blockers(state.progress_events), runtime)
  end

  defp alert_indicators(readiness_context, blockers, runtime) do
    [
      blocker_indicator(readiness_context.work_package, blockers),
      stale_heartbeat_indicator(runtime),
      failed_run_indicator(runtime),
      missing_readiness_indicator(readiness_context),
      scope_drift_indicator(readiness_context)
    ]
  end

  defp blocker_indicator(%WorkPackage{status: "blocked"}, blockers) do
    active_count = Enum.count(blockers, & &1.active)
    alert_indicator("blocker", "Blocked", "critical", active_count > 0, blocker_detail(active_count))
  end

  defp blocker_indicator(%WorkPackage{}, blockers) do
    active_count = Enum.count(blockers, & &1.active)
    alert_indicator("blocker", "Blockers", "critical", active_count > 0, blocker_detail(active_count))
  end

  defp blocker_detail(1), do: "1 active blocker"
  defp blocker_detail(count), do: "#{count} active blockers"

  defp stale_heartbeat_indicator(%{stale_count: stale_count, stale_heartbeat_after_seconds: threshold}) do
    alert_indicator(
      "stale_heartbeat",
      "Stale heartbeat",
      "warning",
      stale_count > 0,
      "#{stale_count} run(s) past #{threshold}s"
    )
  end

  defp failed_run_indicator(%{failed_count: failed_count}) do
    alert_indicator("failed_run", "Failed runs", "warning", failed_count > 0, "#{failed_count} failed run(s)")
  end

  defp missing_readiness_indicator(%{work_package: %WorkPackage{status: status}} = context) when status in @ready_statuses do
    reasons = readiness_failure_reasons(context)
    missing = missing_readiness_gates(reasons)

    alert_indicator(
      "missing_readiness_evidence",
      "Missing readiness evidence",
      "warning",
      missing != [],
      missing_detail(missing),
      %{missing: missing, reasons: reasons}
    )
  end

  defp missing_readiness_indicator(_context) do
    alert_indicator("missing_readiness_evidence", "Missing readiness evidence", "info", false, "Package is not in a ready state", %{missing: [], reasons: []})
  end

  defp scope_drift_indicator(%{work_package: %WorkPackage{} = work_package, progress_events: progress_events}) do
    reasons = ScopeGuard.failure_reasons(work_package, progress_events)
    drift_reasons = Enum.filter(reasons, &scope_drift_reason?/1)
    blocked_reasons = Enum.filter(reasons, &scope_guard_blocked_reason?/1)
    active_reasons = drift_reasons ++ blocked_reasons
    active? = active_reasons != []

    detail =
      cond do
        drift_reasons != [] -> missing_detail(Enum.map(drift_reasons, &Map.get(&1, "code", @scope_guard_gate)))
        blocked_reasons != [] -> "Scope guard evidence unavailable: " <> missing_detail(Enum.map(blocked_reasons, &Map.get(&1, "code", @scope_guard_gate)))
        reasons != [] -> "Scope guard is awaiting required PR metadata"
        true -> "Scope guard satisfied or not required"
      end

    severity =
      cond do
        drift_reasons != [] -> "critical"
        blocked_reasons != [] -> "warning"
        true -> "info"
      end

    alert_indicator("scope_drift", "Scope guard", severity, active?, detail, %{
      placeholder: false,
      reasons: reasons
    })
  end

  defp scope_drift_reason?(%{"code" => code}) do
    code in [
      "wrong_base_branch",
      "out_of_scope_files",
      "scope_constraints_missing",
      "overbroad_scope_constraints",
      "invalid_changed_file_paths"
    ]
  end

  defp scope_drift_reason?(_reason), do: false

  defp scope_guard_blocked_reason?(%{"code" => "changed_files_unavailable"}), do: true
  defp scope_guard_blocked_reason?(_reason), do: false

  defp alert_indicator(type, label, severity, active, detail, extra \\ %{}) do
    Map.merge(%{type: type, label: label, severity: severity, active: active, detail: detail}, extra)
  end

  defp missing_detail([]), do: "No missing evidence detected"
  defp missing_detail(missing), do: Enum.join(missing, ", ")

  defp readiness_context(%State{} = state, _artifact_count, _finding_count) do
    readiness_context(state.work_package, state.plan_nodes, state.progress_events, state.artifacts, state.findings)
  end

  defp readiness_context(%WorkPackage{} = work_package, plan_nodes, progress_events, artifacts, findings) do
    %{
      work_package: work_package,
      plan_nodes: plan_nodes,
      progress_events: chronological_progress_events(progress_events),
      artifacts: artifacts,
      findings: findings,
      artifact_count: length(artifacts),
      finding_count: length(findings)
    }
  end

  @spec missing_readiness_evidence(map()) :: [String.t()]
  def missing_readiness_evidence(%{work_package: %WorkPackage{}} = context) do
    context
    |> readiness_failure_reasons()
    |> missing_readiness_gates()
  end

  defp missing_readiness_gates(reasons) do
    reasons
    |> Enum.map(&Map.fetch!(&1, "gate"))
    |> Enum.uniq()
  end

  defp readiness_failure_reasons(%{work_package: %WorkPackage{}} = context) do
    [
      {active_blocker?(context.progress_events), "no_active_blockers"},
      {incomplete_plan?(context), "plan_complete"},
      {acceptance_missing?(context), "acceptance_criteria_met"},
      {tests_missing?(context), "tests_passed"},
      {merge_metadata_missing?(context, "branch"), "branch_attached"},
      {merge_metadata_missing?(context, "pr"), "pr_attached"},
      {current_pr_state_missing?(context), "current_pr_state"},
      {review_suite_result_missing?(context), "review_suite_result"},
      {ScopeGuard.missing?(context.work_package, context.progress_events), @scope_guard_gate},
      {review_package_missing?(context), "review_package_submitted"},
      {review_artifacts_missing?(context), "review_artifacts_attached"},
      {review_lanes_missing?(context), "review_lanes_complete"},
      {investigation_findings_missing?(context), "findings_documented"},
      {investigation_recommendation_missing?(context), "recommendation_artifact_recorded"}
    ]
    |> Enum.flat_map(fn
      {true, @scope_guard_gate} -> ScopeGuard.failure_reasons(context.work_package, context.progress_events)
      {true, gate} -> [readiness_failure_reason(gate)]
      {false, _gate} -> []
    end)
  end

  defp readiness_failure_reason(gate) do
    %{
      "gate" => gate,
      "code" => gate,
      "message" => readiness_failure_message(gate)
    }
  end

  defp readiness_failure_message("no_active_blockers"), do: "Active blockers must be resolved before readiness."
  defp readiness_failure_message("plan_complete"), do: "Required package plan nodes must be complete."
  defp readiness_failure_message("acceptance_criteria_met"), do: "Acceptance criteria evidence is missing."
  defp readiness_failure_message("tests_passed"), do: "Focused test evidence is missing."
  defp readiness_failure_message("branch_attached"), do: "Current branch metadata is missing."
  defp readiness_failure_message("pr_attached"), do: "Current PR metadata is missing."
  defp readiness_failure_message("current_pr_state"), do: "Current synced PR state is missing."
  defp readiness_failure_message("review_suite_result"), do: "Current-head review-suite result evidence is missing."
  defp readiness_failure_message("review_package_submitted"), do: "Current-head review package is missing."
  defp readiness_failure_message("review_artifacts_attached"), do: "Current-head review artifacts are missing."
  defp readiness_failure_message("review_lanes_complete"), do: "Required review profiles are not green."
  defp readiness_failure_message("findings_documented"), do: "Investigation findings are missing."
  defp readiness_failure_message("recommendation_artifact_recorded"), do: "Investigation recommendation artifact is missing."
  defp readiness_failure_message(_gate), do: "Readiness gate is not satisfied."

  defp merge_metadata_missing?(context, "pr") do
    merge_required?(context.work_package) and pr_required?(context.work_package) and
      not metadata_present?(context.progress_events, "pr", latest_current_head_sha(context.progress_events))
  end

  defp merge_metadata_missing?(context, "branch") do
    merge_required?(context.work_package) and
      not metadata_present?(context.progress_events, "branch", latest_current_head_sha(context.progress_events))
  end

  defp merge_metadata_missing?(context, type) do
    merge_required?(context.work_package) and
      not metadata_present?(context.progress_events, type, latest_current_head_sha(context.progress_events))
  end

  defp current_pr_state_missing?(context) do
    merge_required?(context.work_package) and pr_required?(context.work_package) and
      required_gate?(context.work_package, "current_pr_state") and
      not current_pr_state_present?(context.progress_events, latest_current_head_sha(context.progress_events))
  end

  defp review_suite_result_missing?(context) do
    required_gate?(context.work_package, "review_suite_result") and
      not review_suite_result_present?(context.progress_events, context.artifacts, context.work_package.id, review_head_sha_for_readiness(context))
  end

  defp review_suite_result_present?(_progress_events, _artifacts, _work_package_id, nil), do: false

  defp review_suite_result_present?(progress_events, artifacts, work_package_id, readiness_head_sha) do
    case latest_review_suite_result_event(progress_events, work_package_id, readiness_head_sha) do
      %ProgressEvent{payload: payload} ->
        valid_review_suite_result_payload?(payload, work_package_id, readiness_head_sha) and
          persisted_review_suite_artifact?(artifacts, work_package_id, Map.fetch!(payload, "head_sha"))

      nil ->
        false
    end
  end

  defp review_package_missing?(context) do
    readiness_head_sha = review_head_sha_for_readiness(context)
    required_lanes = required_review_lanes(context.work_package)

    merge_required?(context.work_package) and review_lanes_required?(required_lanes) and
      current_head_review_package_events(context.progress_events, readiness_head_sha) == []
  end

  defp review_artifacts_missing?(context) do
    required_lanes = required_review_lanes(context.work_package)

    merge_required?(context.work_package) and review_lanes_required?(required_lanes) and
      not review_artifacts_present?(context.progress_events, context.artifacts, context.work_package.id)
  end

  defp review_lanes_missing?(context) do
    required_lanes = required_review_lanes(context.work_package)
    review_lanes_required?(required_lanes) and not review_lanes_present?(context, required_lanes)
  end

  defp investigation_findings_missing?(context), do: context.work_package.kind == "investigation" and context.findings == []

  defp investigation_recommendation_missing?(context) do
    context.work_package.kind == "investigation" and
      not recommendation_artifact_recorded?(context.artifacts, context.work_package.id)
  end

  defp incomplete_plan?(context) do
    plan_required?(context.work_package) and
      (context.plan_nodes == [] or Enum.any?(context.plan_nodes, &(&1.status not in @complete_plan_statuses)))
  end

  defp acceptance_missing?(context) do
    required_gate?(context.work_package, "package_acceptance") and not acceptance_recorded?(context)
  end

  defp tests_missing?(context) do
    required_gate?(context.work_package, "focused_tests") and not tests_recorded?(context)
  end

  defp active_blocker?(progress_events) do
    progress_events
    |> Enum.filter(&blocker_event?/1)
    |> Enum.reduce(%{}, fn event, active_by_id ->
      Map.put(active_by_id, blocker_id(event), Map.get(event.payload || %{}, "active") == true)
    end)
    |> Map.values()
    |> Enum.any?(& &1)
  end

  defp blocker_id(%ProgressEvent{payload: payload, idempotency_key: idempotency_key, id: id}) do
    normalize_blocker_id(Map.get(payload || %{}, "blocker_id") || idempotency_key || id)
  end

  defp plan_required?(%WorkPackage{} = work_package) do
    case policy_for(work_package) do
      {:ok, policy} -> get_in(policy, [:constraints, :planning_depth]) == "package"
      {:error, _reason} -> true
    end
  end

  defp required_gate?(%WorkPackage{} = work_package, gate) do
    case policy_for(work_package) do
      {:ok, policy} -> gate in Map.get(policy, :required_gates, [])
      {:error, _reason} -> false
    end
  end

  defp required_review_lanes(%WorkPackage{} = work_package) do
    case policy_for(work_package) do
      {:ok, policy} ->
        policy
        |> get_in([:review_suite, :required])
        |> ReviewProfiles.normalize_profiles()

      {:error, _reason} ->
        []
    end
  end

  defp policy_for(%WorkPackage{} = work_package), do: LifecycleService.policy_for(work_package)

  defp review_lanes_required?(required_lanes), do: required_lanes != []

  defp merge_required?(%WorkPackage{} = work_package) do
    case policy_for(work_package) do
      {:ok, policy} ->
        required_gates = Map.get(policy, :required_gates, [])
        Enum.any?(@merge_required_gates, &(&1 in required_gates))

      {:error, _reason} ->
        work_package.kind in @runtime_merge_required_kinds
    end
  end

  defp pr_required?(%WorkPackage{}), do: true

  defp acceptance_recorded?(context) do
    progress_events = progress_events_for_review_payload(context)

    if merge_required?(context.work_package) do
      review_package_acceptance_recorded?(progress_events, review_head_sha_for_readiness(context))
    else
      review_package_acceptance_recorded?(progress_events, review_head_sha_for_readiness(context)) or
        current_branch_acceptance_recorded?(progress_events)
    end
  end

  defp review_package_acceptance_recorded?(progress_events, readiness_head_sha) do
    case latest_review_package_event(progress_events, readiness_head_sha) do
      %ProgressEvent{payload: payload} when is_map(payload) -> Map.get(payload, "acceptance_criteria_met") == true
      _event -> false
    end
  end

  defp current_branch_acceptance_recorded?(progress_events) do
    progress_events
    |> Enum.reverse()
    |> Enum.any?(fn
      %ProgressEvent{payload: payload} = event when is_map(payload) ->
        payload_type?(event, "review_package", "submit_review_package") and Map.get(payload, "acceptance_criteria_met") == true

      %ProgressEvent{} ->
        false
    end)
  end

  defp tests_recorded?(context) do
    if merge_required?(context.work_package) do
      review_package_tests_recorded?(context.progress_events, review_head_sha_for_readiness(context))
    else
      progress_events = current_branch_progress_events(context.progress_events)

      review_package_tests_recorded?(progress_events, review_head_sha_for_readiness(context)) or
        progress_status_recorded?(progress_events, "tests_passed")
    end
  end

  defp review_package_tests_recorded?(progress_events, readiness_head_sha) do
    case latest_review_package_event(progress_events, readiness_head_sha) do
      %ProgressEvent{payload: payload} when is_map(payload) ->
        case Map.get(payload, "tests") do
          tests when is_list(tests) -> Enum.any?(tests, &(is_binary(&1) and String.trim(&1) != ""))
          _tests -> false
        end

      _event ->
        false
    end
  end

  defp review_lanes_present?(context, required_lanes) do
    if merge_required?(context.work_package) do
      review_package_lanes_present?(
        context.progress_events,
        required_lanes,
        review_head_sha_for_readiness(context)
      )
    else
      progress_events = current_branch_progress_events(context.progress_events)

      review_package_lanes_present?(progress_events, required_lanes, review_head_sha_for_readiness(context)) or
        progress_review_lanes_present?(progress_events, required_lanes)
    end
  end

  defp review_package_lanes_present?(progress_events, required_lanes, readiness_head_sha) do
    latest_verdicts =
      case latest_review_package_event(progress_events, readiness_head_sha) do
        %ProgressEvent{} = event ->
          event
          |> review_package_reviews(readiness_head_sha)
          |> Enum.reduce(%{}, fn review, verdicts ->
            Map.put(verdicts, ReviewProfiles.normalize_profile(Map.get(review, "lane")), Map.get(review, "verdict"))
          end)

        nil ->
          %{}
      end

    Enum.all?(required_lanes, &(Map.get(latest_verdicts, &1) == "green"))
  end

  defp progress_review_lanes_present?(progress_events, required_lanes) do
    Enum.all?(required_lanes, fn lane ->
      green_statuses = ReviewProfiles.green_statuses(lane)

      latest_generic_progress_status(progress_events, ReviewProfiles.statuses(lane)) in green_statuses
    end)
  end

  defp progress_status_recorded?(progress_events, expected_status) do
    latest_generic_progress_status(progress_events, [expected_status, failed_status(expected_status)]) ==
      expected_status
  end

  defp current_branch_progress_events(progress_events) do
    case latest_branch_event_index(progress_events) do
      nil -> progress_events
      index -> Enum.drop(progress_events, index + 1)
    end
  end

  defp latest_branch_event_index(progress_events) do
    progress_events
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%ProgressEvent{} = event, index} ->
        if payload_type?(event, "branch", "attach_branch"), do: index

      _entry ->
        nil
    end)
  end

  defp latest_generic_progress_status(progress_events, statuses) do
    statuses = MapSet.new(statuses)

    progress_events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{status: status} = event ->
        status = normalized_status(status)
        if generic_append_progress_event?(event) and MapSet.member?(statuses, status), do: status

      _event ->
        nil
    end)
  end

  defp generic_append_progress_event?(%ProgressEvent{payload: payload}) when is_map(payload), do: Map.get(payload, "source_tool") == nil
  defp generic_append_progress_event?(%ProgressEvent{payload: nil}), do: true
  defp generic_append_progress_event?(%ProgressEvent{}), do: false

  defp failed_status("tests_passed"), do: "tests_failed"
  defp failed_status(status), do: status <> "_failed"

  defp latest_review_package_event(progress_events, readiness_head_sha) do
    progress_events
    |> current_head_review_package_events(readiness_head_sha)
    |> List.last()
  end

  defp current_head_review_package_events(progress_events, readiness_head_sha) do
    Enum.filter(progress_events, fn event ->
      payload_type?(event, "review_package", "submit_review_package") and review_head_matches?(event.payload, readiness_head_sha)
    end)
  end

  defp review_artifacts_present?(progress_events, artifacts, work_package_id) do
    current_head_sha = latest_current_head_sha(progress_events)
    artifact_references = current_head_review_artifact_references(progress_events, current_head_sha)

    artifact_references != [] and
      Enum.all?(artifact_references, fn {path, artifact_head_sha} ->
        persisted_review_artifact?(artifacts, work_package_id, artifact_head_sha, path)
      end)
  end

  defp current_head_review_artifact_references(progress_events, current_head_sha) do
    case latest_review_package_event(progress_events, current_head_sha) do
      %ProgressEvent{} = event -> review_package_artifact_references(event, current_head_sha)
      nil -> []
    end
  end

  defp review_package_artifact_paths(%ProgressEvent{payload: payload}, readiness_head_sha) when is_map(payload) do
    artifacts = Map.get(payload, "artifacts")

    if is_list(artifacts) and review_head_matches?(payload, readiness_head_sha) do
      Enum.filter(artifacts, &(is_binary(&1) and String.trim(&1) != ""))
    else
      []
    end
  end

  defp review_package_artifact_paths(%ProgressEvent{}, _readiness_head_sha), do: []

  defp review_package_artifact_references(%ProgressEvent{payload: payload} = event, readiness_head_sha) when is_map(payload) do
    event
    |> review_package_artifact_paths(readiness_head_sha)
    |> Enum.map(&{&1, Map.get(payload, "head_sha")})
  end

  defp review_package_artifact_references(%ProgressEvent{}, _readiness_head_sha), do: []

  defp persisted_review_artifact?(artifacts, work_package_id, head_sha, path) do
    expected_id = review_artifact_id(work_package_id, head_sha, path)
    Enum.any?(artifacts, &(&1.id == expected_id and &1.kind == "review" and &1.path == path))
  end

  defp latest_review_suite_result_event(progress_events, work_package_id, readiness_head_sha) do
    progress_events
    |> chronological_progress_events()
    |> Enum.filter(&(dedicated_review_suite_result_event?(&1, work_package_id) and review_head_matches?(&1.payload, readiness_head_sha)))
    |> List.last()
  end

  defp dedicated_review_suite_result_event?(%ProgressEvent{idempotency_key: idempotency_key} = event, work_package_id) do
    payload_type?(event, "review_suite_result", "attach_review_suite_result") and
      is_binary(idempotency_key) and String.starts_with?(idempotency_key, "attach_review_suite_result:#{work_package_id}:")
  end

  defp valid_review_suite_result_payload?(%{} = payload, work_package_id, readiness_head_sha) do
    Map.get(payload, "work_package_id") == work_package_id and
      review_head_matches?(payload, readiness_head_sha) and
      review_suite_status_passed?(Map.get(payload, "status")) and
      review_suite_verdict_passed?(Map.get(payload, "verdict")) and
      filled_string?(Map.get(payload, "suite")) and
      filled_string?(Map.get(payload, "anchor")) and
      filled_string?(Map.get(payload, "summary"))
  end

  defp valid_review_suite_result_payload?(_payload, _work_package_id, _readiness_head_sha), do: false

  defp review_suite_status_passed?(status) when is_binary(status), do: normalized_status(status) in ["passed", "pass", "green", "success"]
  defp review_suite_status_passed?(_status), do: false

  defp review_suite_verdict_passed?(verdict) when is_binary(verdict) do
    normalized_status(verdict) in ["green", "passed", "pass", "success", "approved"]
  end

  defp review_suite_verdict_passed?(_verdict), do: false

  defp persisted_review_suite_artifact?(artifacts, work_package_id, head_sha) do
    expected_id = review_suite_artifact_id(work_package_id, head_sha)

    Enum.any?(
      artifacts,
      &(&1.id == expected_id and &1.work_package_id == work_package_id and &1.kind == "review_suite" and &1.path == "review-suite-result.json")
    )
  end

  defp review_suite_artifact_id(work_package_id, head_sha) do
    material = [work_package_id, head_sha, "review-suite-result.json"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp review_artifact_id(work_package_id, head_sha, artifact) do
    material = [work_package_id, head_sha || "no-head", artifact] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp recommendation_artifact_recorded?(artifacts, work_package_id) do
    artifact_id = recommendation_artifact_id(work_package_id)

    Enum.any?(
      artifacts,
      &(&1.id == artifact_id and &1.work_package_id == work_package_id and &1.path == "recommendation.md" and
          &1.title == "Investigation recommendation" and &1.kind == "recommendation")
    )
  end

  defp recommendation_artifact_id(work_package_id) do
    material = [work_package_id, "recommendation", "recommendation.md"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp review_package_reviews(%ProgressEvent{payload: payload}, readiness_head_sha) when is_map(payload) do
    reviews = Map.get(payload, "reviews")

    if is_list(reviews) and review_head_matches?(payload, readiness_head_sha) do
      Enum.flat_map(reviews, &normalize_review_entry/1)
    else
      []
    end
  end

  defp normalize_review_entry(%{} = review) do
    keys = review |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    lane = Map.get(review, "lane")
    verdict = Map.get(review, "verdict")

    if keys == ["lane", "verdict"] and filled_string?(lane) and filled_string?(verdict) do
      [%{"lane" => lane |> String.trim() |> String.downcase(), "verdict" => verdict |> String.trim() |> String.downcase()}]
    else
      []
    end
  end

  defp normalize_review_entry(_review), do: []

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp review_head_matches?(payload, :any_head) when is_map(payload) do
    head_sha = Map.get(payload, "head_sha")
    is_binary(head_sha) and String.trim(head_sha) != ""
  end

  defp review_head_matches?(payload, head_sha) when is_map(payload) and is_binary(head_sha), do: Map.get(payload, "head_sha") == head_sha
  defp review_head_matches?(_payload, _head_sha), do: false

  defp review_head_sha_for_readiness(context) do
    current_head_sha = latest_current_head_sha(context.progress_events)

    cond do
      is_binary(current_head_sha) -> current_head_sha
      merge_required?(context.work_package) -> nil
      true -> :any_head
    end
  end

  defp progress_events_for_review_payload(context) do
    if merge_required?(context.work_package) do
      context.progress_events
    else
      current_branch_progress_events(context.progress_events)
    end
  end

  defp latest_current_head_sha(progress_events) do
    progress_events
    |> Enum.filter(&payload_type?(&1, "branch", "attach_branch"))
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{payload: payload} -> payload_head_sha(payload)
      _event -> nil
    end)
  end

  defp metadata_present?(progress_events, "pr", head_sha) when is_binary(head_sha) do
    case latest_attached_pr_ref(progress_events) do
      {:ok, attached_ref} ->
        Enum.any?(progress_events, fn
          %ProgressEvent{payload: payload} = event when is_map(payload) ->
            payload_type?(event, "pr", ["attach_pr", "sync_pr"]) and head_sha_matches?(Map.get(payload, "head_sha"), head_sha) and
              pr_payload_ref(payload) == attached_ref

          %ProgressEvent{} ->
            false
        end)

      {:error, :not_found} ->
        false
    end
  end

  defp metadata_present?(progress_events, type, head_sha) when is_binary(head_sha) do
    tool = metadata_tool(type)

    Enum.any?(progress_events, fn
      %ProgressEvent{payload: payload} = event when is_map(payload) ->
        payload_type?(event, type, tool) and head_sha_matches?(Map.get(payload, "head_sha"), head_sha)

      %ProgressEvent{} ->
        false
    end)
  end

  defp metadata_present?(_progress_events, _type, _head_sha), do: false

  defp current_pr_state_present?(progress_events, head_sha) when is_binary(head_sha) do
    case latest_attached_pr_ref_with_sequence(progress_events) do
      {:ok, attached_ref, attach_sequence} ->
        Enum.any?(progress_events, fn
          %ProgressEvent{payload: payload} = event when is_map(payload) ->
            payload_type?(event, "pr", "sync_pr") and progress_after_pr_attach_boundary?(event, attach_sequence) and
              head_sha_matches?(Map.get(payload, "head_sha"), head_sha) and
              pr_payload_ref(payload) == attached_ref and current_pr_state_payload?(payload)

          %ProgressEvent{} ->
            false
        end)

      {:error, :not_found} ->
        false
    end
  end

  defp current_pr_state_present?(_progress_events, _head_sha), do: false

  defp progress_after_pr_attach_boundary?(%ProgressEvent{}, nil), do: true
  defp progress_after_pr_attach_boundary?(%ProgressEvent{sequence: sequence}, attach_sequence) when is_integer(sequence), do: sequence > attach_sequence
  defp progress_after_pr_attach_boundary?(%ProgressEvent{}, _attach_sequence), do: false

  defp current_pr_state_payload?(%{"source_tool" => "sync_pr"} = payload), do: semantic_pr_payload?(payload)
  defp current_pr_state_payload?(_payload), do: false

  defp semantic_pr_payload?(payload) do
    semantic_pr_state?(payload, "check_summary", ["conclusion", "state", "status"]) or
      semantic_pr_state?(payload, "review_state", ["decision", "state", "status"]) or
      semantic_pr_state?(payload, "merge_state", ["mergeable_state", "state", "status"]) or
      semantic_pr_boolean?(payload, "merge_state", ["mergeable", "merged"])
  end

  defp semantic_pr_state?(payload, key, semantic_keys) do
    case Map.get(payload, key) do
      value when is_map(value) ->
        Enum.any?(semantic_keys, fn semantic_key ->
          semantic_pr_value?(value, semantic_key)
        end)

      _value ->
        false
    end
  end

  defp semantic_pr_value(value, key), do: Map.get(value, key) || Map.get(value, String.to_atom(key))

  defp semantic_pr_value?(value, "state") do
    case semantic_pr_value(value, "state") do
      state when is_binary(state) ->
        normalized = state |> String.trim() |> String.downcase()
        normalized != "" and normalized not in ["open", "closed"]

      _state ->
        false
    end
  end

  defp semantic_pr_value?(value, key), do: value |> semantic_pr_value(key) |> filled_string?()

  defp semantic_pr_boolean?(payload, key, semantic_keys) do
    case Map.get(payload, key) do
      value when is_map(value) ->
        Enum.any?(semantic_keys, fn semantic_key ->
          is_boolean(Map.get(value, semantic_key)) or is_boolean(Map.get(value, String.to_atom(semantic_key)))
        end)

      _value ->
        false
    end
  end

  defp metadata_tool("branch"), do: "attach_branch"
  defp metadata_tool("pr"), do: ["attach_pr", "sync_pr"]
  defp metadata_tool(_type), do: nil

  defp normalized_status(status) when is_binary(status), do: status |> String.trim() |> String.downcase()
  defp normalized_status(_status), do: ""

  defp metadata(progress_events, artifacts, work_package_id) do
    branch = latest_payload(progress_events, "branch", "attach_branch")
    head_filter = metadata_head_filter(progress_events, branch)
    pr = latest_pr_payload(progress_events, head_filter)

    %{
      branch: branch,
      pr: pr_metadata(pr, head_filter),
      review_progress: latest_payload(progress_events, "review_progress", nil),
      review_package: latest_current_payload(progress_events, "review_package", "submit_review_package", head_filter),
      review_suite_result: review_suite_result_payload(progress_events, artifacts, work_package_id, head_filter)
    }
  end

  defp review_suite_result_payload(progress_events, artifacts, work_package_id, {:head, head_sha}) do
    case latest_review_suite_result_event(progress_events, work_package_id, head_sha) do
      %ProgressEvent{payload: payload} ->
        if valid_review_suite_result_payload?(payload, work_package_id, head_sha) and
             persisted_review_suite_artifact?(artifacts, work_package_id, Map.fetch!(payload, "head_sha")) do
          redacted_json(payload || %{})
        else
          nil
        end

      nil ->
        nil
    end
  end

  defp review_suite_result_payload(_progress_events, _artifacts, _work_package_id, _head_filter), do: nil

  defp pr_metadata(nil, _head_filter), do: nil

  defp pr_metadata(%{} = pr, {:head, current_head_sha}) do
    stale? = not head_sha_matches?(Map.get(pr, "head_sha"), current_head_sha)

    pr
    |> Map.put("stale", stale?)
    |> Map.put("current_head_sha", current_head_sha)
  end

  defp pr_metadata(%{} = pr, :none), do: pr
  defp pr_metadata(%{} = _pr, _head_filter), do: nil

  defp latest_pr_payload(progress_events, :none) do
    case latest_attached_pr_ref_with_sequence(progress_events) do
      {:ok, attached_ref, attach_sequence} ->
        latest_preferred_pr_payload(progress_events, :any, attached_ref, attach_sequence)

      {:error, :not_found} ->
        nil
    end
  end

  defp latest_pr_payload(progress_events, head_filter) do
    case latest_attached_pr_ref_with_sequence(progress_events) do
      {:ok, attached_ref, attach_sequence} ->
        latest_preferred_pr_payload(progress_events, head_filter, attached_ref, attach_sequence) ||
          latest_preferred_pr_payload(progress_events, :any, attached_ref, attach_sequence)

      {:error, :not_found} ->
        nil
    end
  end

  defp latest_preferred_pr_payload(progress_events, head_filter, attached_ref, attach_sequence) do
    latest_payload = latest_pr_display_payload(progress_events, head_filter, attached_ref, attach_sequence)

    cond do
      is_nil(latest_payload) ->
        latest_current_pr_payload(progress_events, head_filter, attached_ref, attach_sequence)

      display_pr_payload?(latest_payload) ->
        latest_payload

      true ->
        latest_current_pr_payload(progress_events, head_filter, attached_ref, attach_sequence) || latest_payload
    end
  end

  defp display_pr_payload?(%{"source_tool" => "sync_pr"}), do: true
  defp display_pr_payload?(%{"source_tool" => "attach_pr"} = payload), do: semantic_pr_payload?(payload)
  defp display_pr_payload?(_payload), do: false

  defp latest_pr_display_payload(progress_events, head_filter, attached_ref, attach_sequence) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find(fn
      %ProgressEvent{payload: payload} = event when is_map(payload) ->
        pr_display_payload?(event, payload, head_filter, attached_ref, attach_sequence)

      %ProgressEvent{} ->
        false
    end)
    |> case do
      %ProgressEvent{payload: payload} -> redacted_json(payload || %{})
      nil -> nil
    end
  end

  defp pr_display_payload?(event, payload, head_filter, attached_ref, attach_sequence) do
    cond do
      payload_type?(event, "pr", "attach_pr") ->
        payload_head_matches?(payload, head_filter) and pr_ref_matches?(payload, attached_ref)

      payload_type?(event, "pr", "sync_pr") ->
        progress_after_pr_attach_boundary?(event, attach_sequence) and payload_head_matches?(payload, head_filter) and
          pr_ref_matches?(payload, attached_ref)

      true ->
        false
    end
  end

  defp latest_current_pr_payload(progress_events, head_filter, attached_ref, attach_sequence) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find(fn
      %ProgressEvent{payload: payload} = event when is_map(payload) ->
        payload_type?(event, "pr", "sync_pr") and progress_after_pr_attach_boundary?(event, attach_sequence) and
          payload_head_matches?(payload, head_filter) and
          pr_ref_matches?(payload, attached_ref) and current_pr_state_payload?(payload)

      %ProgressEvent{} ->
        false
    end)
    |> case do
      %ProgressEvent{payload: payload} -> redacted_json(payload || %{})
      nil -> nil
    end
  end

  defp latest_current_payload(progress_events, type, source_tool, :none) do
    latest_payload(progress_events, type, source_tool, :none)
  end

  defp latest_current_payload(progress_events, type, source_tool, head_filter) do
    latest_payload(progress_events, type, source_tool, head_filter)
  end

  defp latest_payload(progress_events, type, source_tool) do
    latest_payload(progress_events, type, source_tool, :any)
  end

  defp latest_payload(progress_events, type, source_tool, head_filter) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find(&(payload_type?(&1, type, source_tool) and payload_head_matches?(&1.payload, head_filter)))
    |> case do
      %ProgressEvent{payload: payload} -> redacted_json(payload || %{})
      nil -> nil
    end
  end

  defp pr_ref_matches?(_payload, :any), do: true
  defp pr_ref_matches?(payload, pr_ref), do: pr_payload_ref(payload) == pr_ref

  defp latest_attached_pr_ref(progress_events) do
    case latest_attached_pr_ref_with_sequence(progress_events) do
      {:ok, ref, _sequence} -> {:ok, ref}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp latest_attached_pr_ref_with_sequence(progress_events) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find_value(&attached_pr_ref_with_sequence/1)
    |> case do
      nil -> {:error, :not_found}
      {ref, sequence} -> {:ok, ref, sequence}
    end
  end

  defp attached_pr_ref_with_sequence(%ProgressEvent{payload: payload, sequence: sequence} = event) when is_map(payload) do
    if payload_type?(event, "pr", "attach_pr"), do: pr_payload_ref_with_sequence(payload, sequence)
  end

  defp attached_pr_ref_with_sequence(_event), do: nil

  defp pr_payload_ref_with_sequence(payload, sequence) do
    case pr_payload_ref(payload) do
      nil -> nil
      ref -> {ref, sequence}
    end
  end

  defp pr_payload_ref(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_integer(number), do: normalized_pr_ref(repository, number)
  defp pr_payload_ref(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_binary(number), do: normalized_pr_ref(repository, number)

  defp pr_payload_ref(%{"url" => url}) when is_binary(url) do
    case PullRequest.parse(%{"url" => url}, nil) do
      {:ok, ref} -> normalized_pr_ref(ref.repository, ref.number)
      {:error, _reason} -> legacy_url_ref(url)
    end
  end

  defp pr_payload_ref(_payload), do: nil

  defp normalized_pr_ref(repository, number) when is_binary(repository), do: {String.downcase(repository), number}

  defp legacy_url_ref(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        if String.downcase(host) == "github.com", do: nil, else: {:url, url}

      _uri ->
        {:url, url}
    end
  rescue
    _error in URI.Error -> {:url, url}
  end

  defp metadata_head_filter(_progress_events, nil), do: :none

  defp metadata_head_filter(progress_events, %{} = branch) do
    head_sha = payload_head_sha(branch) || latest_branch_head_sha(progress_events, payload_branch(branch))

    if is_binary(head_sha), do: {:head, head_sha}, else: :none
  end

  defp latest_branch_head_sha(_progress_events, nil), do: nil

  defp latest_branch_head_sha(progress_events, branch_name) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{payload: payload} when is_map(payload) ->
        if payload_type?(%ProgressEvent{payload: payload}, "branch", "attach_branch") and payload_branch(payload) == branch_name do
          payload_head_sha(payload)
        end

      _event ->
        nil
    end)
  end

  defp payload_head_matches?(_payload, :any), do: true
  defp payload_head_matches?(_payload, :none), do: false
  defp payload_head_matches?(payload, {:head, head_sha}) when is_map(payload), do: head_sha_matches?(Map.get(payload, "head_sha"), head_sha)
  defp payload_head_matches?(_payload, {:head, _head_sha}), do: false

  defp head_sha_matches?(left, right), do: PullRequest.head_sha_matches?(left, right)

  defp payload_branch(%{} = payload) do
    case Map.get(payload, "branch") do
      branch when is_binary(branch) ->
        branch = String.trim(branch)
        if branch == "", do: nil, else: branch

      _missing ->
        nil
    end
  end

  defp payload_head_sha(%{} = payload) do
    case Map.get(payload, "head_sha") do
      head_sha when is_binary(head_sha) ->
        if String.trim(head_sha) == "", do: nil, else: head_sha

      _missing ->
        nil
    end
  end

  defp payload_head_sha(_payload), do: nil

  defp blockers(progress_events) do
    progress_events
    |> Enum.filter(&blocker_event?/1)
    |> chronological_progress_events()
    |> Enum.reduce(%{}, fn event, blockers ->
      payload = event.payload || %{}
      blocker_id = normalize_blocker_id(Map.get(payload, "blocker_id") || event.idempotency_key || event.id)

      Map.put(blockers, blocker_id, %{
        id: blocker_id,
        active: Map.get(payload, "active") == true,
        summary: redacted_text(event.summary),
        body: redacted_text(event.body),
        status: event.status,
        source_tool: Map.get(payload, "source_tool"),
        resolution: Map.get(payload, "resolution"),
        blocked_by: blocker_endpoint(Map.get(payload, "blocked_by")),
        blocked_item: blocker_endpoint(Map.get(payload, "blocked_item")),
        actor: actor(event),
        event_id: event.id,
        updated_at: timestamp(event.created_at)
      })
    end)
    |> Map.values()
    |> Enum.sort_by(&{not &1.active, &1.updated_at || "", &1.id || ""})
  end

  defp chronological_progress_events(progress_events) do
    Enum.sort_by(progress_events, &progress_event_order/1)
  end

  defp progress_event_order(%ProgressEvent{} = event) do
    {timestamp_sort_value(event.created_at), event.sequence || 0, event.id || ""}
  end

  defp payload_type?(%ProgressEvent{payload: payload}, type, source_tool) when is_map(payload) and is_list(source_tool) do
    Map.get(payload, "type") == type and Map.get(payload, "source_tool") in source_tool
  end

  defp payload_type?(%ProgressEvent{payload: payload}, type, source_tool) when is_map(payload) do
    Map.get(payload, "type") == type and (is_nil(source_tool) or Map.get(payload, "source_tool") == source_tool)
  end

  defp payload_type?(%ProgressEvent{}, _type, _source_tool), do: false

  defp blocker_event?(%ProgressEvent{payload: payload}) when is_map(payload) do
    Map.get(payload, "type") == "blocker" and Map.get(payload, "source_tool") in ["report_blocker", "resolve_blocker"]
  end

  defp blocker_event?(%ProgressEvent{}), do: false

  defp blocker_endpoint(%{} = value) do
    kind = value |> Map.get("kind", Map.get(value, :kind)) |> normalize_blocker_endpoint_kind()
    id = value |> Map.get("id", Map.get(value, :id)) |> normalize_blocker_endpoint_id()

    if kind && id do
      %{kind: kind, id: id}
    end
  end

  defp blocker_endpoint(_value), do: nil

  defp normalize_blocker_endpoint_kind(value) when is_binary(value) do
    case String.trim(value) do
      "planned_slice" -> "slice"
      "slice" -> "slice"
      "work_package" -> "work_package"
      _other -> nil
    end
  end

  defp normalize_blocker_endpoint_kind(_value), do: nil

  defp normalize_blocker_endpoint_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      id -> id
    end
  end

  defp normalize_blocker_endpoint_id(_value), do: nil

  defp actor(%ProgressEvent{} = event) do
    %{
      id: event.actor_id,
      type: event.actor_type,
      access_grant_id: event.access_grant_id
    }
  end

  defp grant_status(%AccessGrant{revoked_at: %DateTime{}}), do: "revoked"

  defp grant_status(%AccessGrant{expires_at: %DateTime{} = expires_at} = grant) do
    if DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) != :gt do
      "expired"
    else
      claimed_grant_status(grant)
    end
  end

  defp grant_status(%AccessGrant{} = grant), do: claimed_grant_status(grant)

  defp claimed_grant_status(%AccessGrant{claimed_at: nil}), do: "unclaimed"
  defp claimed_grant_status(%AccessGrant{claimed_by: nil}), do: "unclaimed"
  defp claimed_grant_status(%AccessGrant{}), do: "active"

  defp active_grant?(%AccessGrant{} = grant), do: grant_status(grant) == "active"

  defp normalize_blocker_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_blocker_id(value), do: to_string(value)

  defp redacted_json(value) do
    value
    |> Redactor.redact()
    |> Redactor.json_safe()
    |> redact_url_values()
  end

  defp redact_url_values(%{} = value) do
    Map.new(value, fn {key, field_value} ->
      {key, redacted_json_field(key, field_value)}
    end)
  end

  defp redact_url_values(values) when is_list(values), do: Enum.map(values, &redacted_json_value/1)
  defp redact_url_values(value), do: redacted_json_value(value)

  defp redacted_json_value(%{} = value) do
    Map.new(value, fn {key, field_value} ->
      {key, redacted_json_field(key, field_value)}
    end)
  end

  defp redacted_json_value(values) when is_list(values), do: Enum.map(values, &redacted_json_value/1)
  defp redacted_json_value(value) when is_binary(value), do: redacted_text(value)
  defp redacted_json_value(value), do: value

  defp redacted_json_field(key, value) do
    cond do
      sensitive_key?(key) -> "[REDACTED]"
      url_key?(key) -> redact_url_field(value)
      true -> redacted_json_value(value)
    end
  end

  defp sensitive_key?(key) when is_binary(key) do
    key = String.downcase(key)

    String.contains?(key, "secret") or String.contains?(key, "token") or String.contains?(key, "hash")
  end

  defp sensitive_key?(key) when is_atom(key), do: key |> Atom.to_string() |> sensitive_key?()
  defp sensitive_key?(_key), do: false

  defp url_key?(key) when is_binary(key), do: String.downcase(key) in ["href", "link", "links", "uri", "url", "urls"]
  defp url_key?(_key), do: false

  defp redact_url_field(%{} = value), do: Map.new(value, fn {key, field_value} -> {key, redact_url_field(field_value)} end)
  defp redact_url_field(values) when is_list(values), do: Enum.map(values, &redact_url_field/1)
  defp redact_url_field(value), do: redacted_uri(value)

  defp redacted_text(nil), do: nil

  defp redacted_text(value) when is_binary(value) do
    redacted = redact_signed_url_text(value)

    cond do
      redacted != value -> "[REDACTED]"
      sensitive_text?(value) -> "[REDACTED]"
      true -> value
    end
  end

  defp redacted_text(value), do: value

  defp sensitive_text?(value) do
    String.match?(
      value,
      ~r/(bearer\s+\S+|wk_[A-Za-z0-9_-]{43,}|raw[_-]?secret[_-][A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|xox[baprs]-[A-Za-z0-9-]{8,})/i
    )
  end

  defp redacted_uri(nil), do: nil

  defp redacted_uri(value) when is_binary(value) do
    uri = URI.parse(value)

    cond do
      is_binary(uri.query) and uri.query != "" -> "[REDACTED]"
      sensitive_text?(value) -> "[REDACTED]"
      true -> value
    end
  end

  defp redacted_uri(value), do: value

  defp redact_signed_url_text(value) do
    Regex.replace(~r/https?:\/\/[^\s<>"']+\?[^\s<>"']*/i, value, "[REDACTED_URL]")
  end

  defp timestamp_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)

  defp timestamp_sort_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      {:error, _reason} -> -1
    end
  end

  defp timestamp_sort_value(nil), do: -1

  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp(nil), do: nil
end
