defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @stale_heartbeat_after_seconds 300
  @ready_statuses ["ready_for_human_merge", "ready_for_architect_merge"]
  @complete_plan_statuses ["done", "completed", "skipped"]
  @merge_required_gates ["human_merge", "architect_merge"]
  @runtime_merge_required_kinds ["hotfix", "adapter", "mcp", "skill", "hooks", "phase_child"]
  @scope_guard_gate "scope_guard"

  @type repo :: module()
  @type dashboard_error :: :not_found | :forbidden | :database_busy | {:storage_failed, String.t()} | term()

  @spec board(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def board(repo) when is_atom(repo) do
    safe_read(fn -> build_board(repo) end)
  end

  @spec phase_board(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def phase_board(repo, phase_id) when is_atom(repo) and is_binary(phase_id) do
    safe_read(fn -> build_phase_board(repo, phase_id) end)
  end

  @spec detail(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def detail(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_read(fn ->
      with {:ok, state} <- planning_state(repo, work_package_id),
           {:ok, grants} <- AccessGrantRepository.list_for_work_package(repo, work_package_id),
           {:ok, agent_runs} <- AgentRunRepository.list_for_work_package(repo, work_package_id) do
        blockers = blockers(state.progress_events)
        summary = summary(state, grants, agent_runs, blockers)

        {:ok,
         %{
           work_package: work_package_detail(state.work_package),
           summary: summary,
           plan: Enum.map(state.plan_nodes, &plan_node/1),
           findings: Enum.map(state.findings, &finding/1),
           progress: Enum.map(state.progress_events, &progress_event/1),
           artifacts: Enum.map(state.artifacts, &artifact/1),
           blockers: blockers,
           grants: Enum.map(grants, &grant/1),
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
      with {:ok, status_summary} <- PlanningRepository.get_status_summary(repo, work_package.id),
           {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package.id),
           {:ok, readiness_collections} <- readiness_collections(repo, work_package),
           {:ok, agent_runs} <- AgentRunRepository.list_for_work_package(repo, work_package.id) do
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

        {:ok,
         %{
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
           metadata: metadata(progress_events, artifacts, work_package.id),
           alert_indicators: alert_indicators(readiness_context, blockers, runtime),
           inserted_at: timestamp(work_package.inserted_at),
           updated_at: timestamp(work_package.updated_at)
         }}
      end
    end)
  end

  defp readiness_collections(repo, %WorkPackage{} = work_package) do
    with {:ok, artifacts} <- readiness_artifacts(repo, work_package),
         {:ok, findings} <- readiness_findings(repo, work_package) do
      {:ok, %{artifacts: artifacts, findings: findings}}
    end
  end

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

  defp build_board(repo) do
    with {:ok, work_packages} <- WorkPackageRepository.list(repo),
         {:ok, cards} <- cards_for_packages(repo, work_packages) do
      {:ok,
       %{
         groups: group_cards(cards),
         statuses: WorkPackage.statuses(),
         total_count: length(cards)
       }}
    end
  end

  defp build_phase_board(repo, phase_id) do
    with {:ok, phase} <- PhaseRepository.get(repo, phase_id),
         {:ok, work_packages} <- WorkPackageRepository.list_for_phase(repo, phase_id),
         {:ok, cards} <- cards_for_packages(repo, work_packages) do
      {:ok,
       %{
         phase: phase(phase),
         groups: group_cards(cards),
         statuses: WorkPackage.statuses(),
         total_count: length(cards)
       }}
    end
  end

  defp cards_for_packages(repo, work_packages) do
    work_packages
    |> Enum.map(&card(repo, &1))
    |> collect_or_error()
  end

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

  defp summary(%State{} = state, grants, agent_runs, blockers) do
    runtime = runtime_summary(agent_runs)

    %{
      artifact_count: length(state.artifacts),
      finding_count: length(state.findings),
      progress_event_count: length(state.progress_events),
      active_blocker_count: Enum.count(blockers, & &1.active),
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
    artifacts = artifacts || []
    findings = findings || []

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
  defp readiness_failure_message("review_lanes_complete"), do: "Required review lanes are not green."
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
      {:ok, policy} -> get_in(policy, [:review_suite, :required]) || []
      {:error, _reason} -> []
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
          |> Enum.reduce(%{}, fn review, verdicts -> Map.put(verdicts, Map.get(review, "lane"), Map.get(review, "verdict")) end)

        nil ->
          %{}
      end

    Enum.all?(required_lanes, &(Map.get(latest_verdicts, &1) == "green"))
  end

  defp progress_review_lanes_present?(progress_events, required_lanes) do
    Enum.all?(required_lanes, fn lane ->
      latest_generic_progress_status(progress_events, ["#{lane}_green", "#{lane}_red", "#{lane}_failed"]) ==
        "#{lane}_green"
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
