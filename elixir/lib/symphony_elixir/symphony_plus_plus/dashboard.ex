defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type repo :: module()
  @type dashboard_error :: :not_found | :forbidden | :database_busy | {:storage_failed, String.t()} | term()

  @spec board(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def board(repo) when is_atom(repo) do
    safe_read(fn -> build_board(repo) end)
  end

  @spec detail(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def detail(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_read(fn ->
      with {:ok, state} <- planning_state(repo, work_package_id),
           {:ok, grants} <- AccessGrantRepository.list_for_work_package(repo, work_package_id),
           {:ok, agent_runs} <- AgentRunRepository.list_for_work_package(repo, work_package_id) do
        blockers = blockers(state.progress_events)

        {:ok,
         %{
           work_package: work_package_detail(state.work_package),
           summary: summary(state, grants, agent_runs, blockers),
           plan: Enum.map(state.plan_nodes, &plan_node/1),
           findings: Enum.map(state.findings, &finding/1),
           progress: Enum.map(state.progress_events, &progress_event/1),
           artifacts: Enum.map(state.artifacts, &artifact/1),
           blockers: blockers,
           grants: Enum.map(grants, &grant/1),
           agent_runs: Enum.map(agent_runs, &agent_run/1),
           metadata: metadata(state.progress_events)
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
           {:ok, agent_runs} <- AgentRunRepository.list_for_work_package(repo, work_package.id) do
        blockers = blockers(progress_events)

        {:ok,
         %{
           id: work_package.id,
           title: redacted_text(work_package.title),
           kind: work_package.kind,
           status: work_package.status,
           repo: work_package.repo,
           base_branch: work_package.base_branch,
           owner_id: work_package.owner_id,
           active_agent_run: latest_active_agent_run(agent_runs),
           latest_progress_at: latest_progress_at(progress_events),
           active_blocker_count: Enum.count(blockers, & &1.active),
           artifact_count: status_summary.artifact_count,
           finding_count: status_summary.finding_count,
           plan: plan_summary(status_summary.plan_nodes),
           metadata: metadata(progress_events),
           inserted_at: timestamp(work_package.inserted_at),
           updated_at: timestamp(work_package.updated_at)
         }}
      end
    end)
  end

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
    %{
      artifact_count: length(state.artifacts),
      finding_count: length(state.findings),
      progress_event_count: length(state.progress_events),
      active_blocker_count: Enum.count(blockers, & &1.active),
      grant_count: length(grants),
      active_grant_count: Enum.count(grants, &active_grant?/1),
      agent_run_count: length(agent_runs),
      active_agent_run_count: Enum.count(agent_runs, &(&1.status in AgentRun.active_statuses())),
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

  defp agent_run(%AgentRun{} = run) do
    %{
      id: run.id,
      work_package_id: run.work_package_id,
      access_grant_id: run.access_grant_id,
      actor_id: run.actor_id,
      status: run.status,
      attempt: run.attempt,
      worker_host: run.worker_host,
      worker_task_handle: run.worker_task_handle,
      workspace_path: run.workspace_path,
      session_id: run.session_id,
      codex_input_tokens: run.codex_input_tokens,
      codex_output_tokens: run.codex_output_tokens,
      codex_total_tokens: run.codex_total_tokens,
      turn_count: run.turn_count,
      started_at: timestamp(run.started_at),
      last_seen_at: timestamp(run.last_seen_at),
      finished_at: timestamp(run.finished_at),
      reason: run.reason
    }
  end

  defp latest_active_agent_run(agent_runs) do
    agent_runs
    |> Enum.filter(&(&1.status in AgentRun.active_statuses()))
    |> List.last()
    |> case do
      %AgentRun{} = run -> agent_run(run)
      nil -> nil
    end
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

  defp metadata(progress_events) do
    branch = latest_payload(progress_events, "branch", "attach_branch")
    head_filter = metadata_head_filter(progress_events, branch)

    %{
      branch: branch,
      pr: latest_current_payload(progress_events, "pr", "attach_pr", head_filter),
      review_package: latest_current_payload(progress_events, "review_package", "submit_review_package", head_filter)
    }
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
  defp payload_head_matches?(payload, {:head, head_sha}) when is_map(payload), do: Map.get(payload, "head_sha") == head_sha
  defp payload_head_matches?(_payload, {:head, _head_sha}), do: false

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
