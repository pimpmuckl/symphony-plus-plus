defmodule SymphonyElixirWeb.SymppDetailLive do
  @moduledoc """
  Read-only Symphony++ work package detail view.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixirWeb.SymppBoardLive
  alias SymphonyElixirWeb.SymppDashboardApiController

  @known_keys ~w(
    access_grant_id active_agent_run_count active_blocker_count active_grant_count
    active alert_indicators agent_run_count agent_runs artifact_count artifacts base_branch
    body branch branch_pattern capabilities claimed_at claimed_by codex_total_tokens
    completed_count created_at detail display_key engineering_scope events expires_at
    failed_count finding_count findings finished_at grant_count grant_role grants
    head_sha id inserted_at kind label latest last_seen_at latest_progress_at metadata
    missing open_count path placeholder plan position pr product_description progress_event_count
    queued_agent_run_count reason repo revoked_at runtime runtime_state scope severity
    sequence session_id stale stale_after_seconds stale_agent_run_count
    stale_heartbeat_after_seconds status stopped_agent_run_count summary terminal_count
    timeline_order title total_count turn_count type updated_at uri url work_package
    worker_host worker_task_handle workspace_path
  )
  @known_key_atoms Map.new(@known_keys, &{&1, String.to_atom(&1)})

  @impl true
  def mount(params, session, socket) do
    work_package_id = params |> Map.get("work_package_id") |> SymppDashboardApiController.normalize_package_route_id()
    package_grant_id = session |> Map.get("sympp_package_grant_ids") |> package_session_grant_id(work_package_id)
    board_grant_id = Map.get(session, "sympp_board_grant_id")

    {:ok,
     socket
     |> assign(:work_package_id, work_package_id)
     |> assign(:package_grant_id, package_grant_id)
     |> assign(:board_grant_id, board_grant_id)
     |> assign(:grant, nil)
     |> assign(:phase_reader?, false)
     |> assign(:detail, empty_detail(error: nil))
     |> assign(:timeline, %{events: []})
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(%{"work_package_id" => work_package_id}, _uri, socket) do
    work_package_id = SymppDashboardApiController.normalize_package_route_id(work_package_id)

    case authorize_session(socket, work_package_id) do
      {:ok, %AccessGrant{} = grant} ->
        {:noreply,
         socket
         |> assign(:work_package_id, work_package_id)
         |> assign(:grant, grant)
         |> assign(:phase_reader?, phase_reader?(grant))
         |> assign_detail()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:work_package_id, work_package_id)
         |> assign(:grant, nil)
         |> assign(:phase_reader?, false)
         |> assign(:detail, empty_detail(error: error_message(reason)))
         |> assign(:timeline, %{events: []})
         |> assign(:error, error_message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="sympp-detail-shell">
      <header class="sympp-detail-header">
        <div>
          <p class="eyebrow">Symphony++</p>
          <h1 class="sympp-detail-title"><%= package_title(@detail.work_package) %></h1>
        </div>

        <a :if={@phase_reader?} class="sympp-back-link" href="../board">Board</a>
      </header>

      <%= if @error do %>
        <section class="error-card">
          <h2 class="error-title">Package unavailable</h2>
          <p class="error-copy"><%= @error %></p>
        </section>
      <% else %>
        <section class="sympp-detail-overview">
          <div class="sympp-detail-main">
            <div class="sympp-copy-row">
              <label for="sympp-package-id">Package ID</label>
              <input id="sympp-package-id" class="mono" readonly value={@detail.work_package.id || @work_package_id} />
            </div>

            <dl class="sympp-detail-meta">
              <div>
                <dt>Status</dt>
                <dd><span class="state-badge"><%= status_label(@detail.work_package.status) %></span></dd>
              </div>
              <div>
                <dt>Kind</dt>
                <dd><%= present(@detail.work_package.kind) %></dd>
              </div>
              <div>
                <dt>Repo</dt>
                <dd><%= repo_base(@detail.work_package) %></dd>
              </div>
              <div>
                <dt>Updated</dt>
                <dd class="numeric"><%= present(@detail.summary.latest_progress_at || @detail.work_package.updated_at) %></dd>
              </div>
            </dl>
          </div>

          <aside class="sympp-detail-side">
            <a :if={pr_url(@detail.metadata)} class="sympp-pr-link" href={pr_url(@detail.metadata)} target="_blank" rel="noopener noreferrer">
              Open PR
            </a>
            <p :if={!pr_url(@detail.metadata)} class="sympp-empty-inline">No PR attached.</p>
            <p class="mono sympp-branch"><%= branch_label(@detail.metadata) %></p>
            <p :if={pr_state_label(@detail.metadata)} class="mono sympp-branch"><%= pr_state_label(@detail.metadata) %></p>
            <dl :if={pr_summary_items(@detail.metadata) != []} class="sympp-pr-state-list">
              <div :for={{label, value} <- pr_summary_items(@detail.metadata)}>
                <dt><%= label %></dt>
                <dd><%= value %></dd>
              </div>
            </dl>
          </aside>
        </section>

        <section class="sympp-detail-grid">
          <article class="sympp-panel sympp-panel-wide">
            <h2>Scope</h2>
            <dl class="sympp-detail-list">
              <div>
                <dt>Product</dt>
                <dd><%= present(@detail.work_package.product_description) %></dd>
              </div>
              <div>
                <dt>Engineering</dt>
                <dd><%= present(@detail.work_package.engineering_scope) %></dd>
              </div>
              <div>
                <dt>Files</dt>
                <dd><%= list_text(@detail.work_package.allowed_file_globs) %></dd>
              </div>
            </dl>
          </article>

          <article class="sympp-panel">
            <h2>Acceptance</h2>
            <ul :if={@detail.work_package.acceptance_criteria != []} class="sympp-plain-list">
              <li :for={criterion <- @detail.work_package.acceptance_criteria}><%= criterion %></li>
            </ul>
            <p :if={@detail.work_package.acceptance_criteria == []} class="sympp-empty-inline">No acceptance criteria recorded.</p>
          </article>

          <article class="sympp-panel">
            <h2>Summary</h2>
            <dl class="sympp-count-grid">
              <div><dt>Plan</dt><dd class="numeric"><%= plan_progress(@detail.summary.plan) %></dd></div>
              <div><dt>Findings</dt><dd class="numeric"><%= @detail.summary.finding_count %></dd></div>
              <div><dt>Events</dt><dd class="numeric"><%= @detail.summary.progress_event_count %></dd></div>
              <div><dt>Artifacts</dt><dd class="numeric"><%= @detail.summary.artifact_count %></dd></div>
              <div><dt>Active blockers</dt><dd class="numeric"><%= @detail.summary.active_blocker_count %></dd></div>
              <div><dt>Active runs</dt><dd class="numeric"><%= @detail.summary.active_agent_run_count %></dd></div>
              <div><dt>Queued runs</dt><dd class="numeric"><%= @detail.summary.queued_agent_run_count %></dd></div>
              <div><dt>Stale runs</dt><dd class="numeric"><%= @detail.summary.stale_agent_run_count %></dd></div>
            </dl>
          </article>

          <article class="sympp-panel">
            <h2>Runtime Alerts</h2>
            <div class="sympp-stack-list">
              <div :for={alert <- @detail.alert_indicators} class="sympp-mini-row">
                <span class={alert_badge_class(alert)}><%= alert.label %></span>
                <span><%= alert_state(alert) %></span>
                <span class="muted"><%= alert.detail %></span>
              </div>
            </div>
          </article>

          <article class="sympp-panel sympp-panel-wide">
            <h2>Virtual Task Plan</h2>
            <div :if={@detail.plan != []} class="sympp-plan-list">
              <div :for={node <- @detail.plan} class="sympp-plan-row">
                <span class={plan_status_class(node.status)}><%= status_label(node.status) %></span>
                <div>
                  <h3><%= node.title %></h3>
                  <p><%= present(node.body) %></p>
                </div>
              </div>
            </div>
            <p :if={@detail.plan == []} class="sympp-empty-inline">No virtual plan nodes recorded.</p>
          </article>

          <article class="sympp-panel">
            <h2>Findings</h2>
            <div :if={@detail.findings != []} class="sympp-stack-list">
              <div :for={finding <- @detail.findings} class="sympp-stack-item">
                <span class="state-badge"><%= finding.severity || "unknown" %></span>
                <h3><%= finding.title %></h3>
                <p><%= present(finding.body) %></p>
              </div>
            </div>
            <p :if={@detail.findings == []} class="sympp-empty-inline">No findings recorded.</p>
          </article>

          <article class="sympp-panel">
            <h2>Artifacts</h2>
            <div :if={@detail.artifacts != []} class="sympp-stack-list">
              <div :for={artifact <- @detail.artifacts} class="sympp-stack-item">
                <span class="state-badge"><%= artifact.kind || "artifact" %></span>
                <h3><%= artifact.title %></h3>
                <p class="mono"><%= artifact.path %></p>
                <a :if={public_http_url(artifact.uri)} href={artifact.uri} target="_blank" rel="noopener noreferrer">Open artifact</a>
              </div>
            </div>
            <p :if={@detail.artifacts == []} class="sympp-empty-inline">No artifacts recorded.</p>
          </article>

          <article class="sympp-panel sympp-panel-wide">
            <h2>Timeline</h2>
            <ol :if={@timeline.events != []} class="sympp-timeline">
              <li :for={event <- @timeline.events}>
                <time class="numeric"><%= present(event.created_at) %></time>
                <div>
                  <span class="state-badge"><%= event.type %></span>
                  <h3><%= timeline_title(event) %></h3>
                  <p><%= timeline_body(event) %></p>
                </div>
              </li>
            </ol>
            <p :if={@timeline.events == []} class="sympp-empty-inline">No progress or finding timeline events recorded.</p>
          </article>

          <article class="sympp-panel">
            <h2>Grants</h2>
            <dl class="sympp-count-grid">
              <div><dt>Total</dt><dd class="numeric"><%= @detail.summary.grant_count %></dd></div>
              <div><dt>Active</dt><dd class="numeric"><%= @detail.summary.active_grant_count %></dd></div>
            </dl>
            <div :if={@detail.grants != []} class="sympp-stack-list">
              <div :for={grant <- @detail.grants} class="sympp-mini-row">
                <span class="state-badge"><%= grant.status %></span>
                <span><%= grant.grant_role %></span>
                <span class="mono"><%= grant.display_key %></span>
              </div>
            </div>
          </article>

          <article class="sympp-panel">
            <h2>Agent Runs</h2>
            <dl class="sympp-count-grid">
              <div><dt>Total</dt><dd class="numeric"><%= @detail.summary.agent_run_count %></dd></div>
              <div><dt>Active</dt><dd class="numeric"><%= @detail.summary.active_agent_run_count %></dd></div>
              <div><dt>Queued</dt><dd class="numeric"><%= @detail.summary.queued_agent_run_count %></dd></div>
              <div><dt>Stopped</dt><dd class="numeric"><%= @detail.summary.stopped_agent_run_count %></dd></div>
            </dl>
            <div :if={@detail.agent_runs != []} class="sympp-stack-list">
              <div :for={run <- @detail.agent_runs} class="sympp-stack-item">
                <span class={run_badge_class(run)}><%= run_status_label(run) %></span>
                <h3><%= present(run.worker_task_handle) %></h3>
                <p class="mono"><%= run.session_id || run.id %></p>
                <p class="mono"><%= present(run.workspace_path) %></p>
                <p class="muted"><%= token_summary(run) %> / last seen <%= present(run.last_seen_at) %></p>
                <p :if={run.status == "failed"} class="muted"><%= present(run.reason) %></p>
              </div>
            </div>
            <p :if={@detail.agent_runs == []} class="sympp-empty-inline">No agent runs recorded.</p>
          </article>
        </section>
      <% end %>
    </section>
    """
  end

  defp authorize_session(socket, work_package_id) do
    package_result =
      SymppDashboardApiController.authorize_package_grant_id(socket.assigns.package_grant_id, work_package_id)

    board_result =
      SymppDashboardApiController.authorize_package_grant_id(socket.assigns.board_grant_id, work_package_id)

    case {package_result, board_result} do
      {_package_result, {:ok, %AccessGrant{}} = authorized} -> authorized
      {{:ok, %AccessGrant{}} = authorized, _board_result} -> authorized
      {{:error, _package_reason}, {:error, :not_found}} -> {:error, :not_found}
      {{:error, :unauthorized}, {:error, reason}} -> {:error, reason}
      {{:error, reason}, _board_result} -> {:error, reason}
    end
  end

  defp package_session_grant_id(sessions, work_package_id) when is_map(sessions) and is_binary(work_package_id) do
    Map.get(sessions, work_package_id)
  end

  defp package_session_grant_id(_sessions, _work_package_id), do: nil

  defp phase_reader?(%AccessGrant{capabilities: capabilities}) when is_list(capabilities), do: "read:phase" in capabilities
  defp phase_reader?(_grant), do: false

  defp assign_detail(socket) do
    work_package_id = socket.assigns.work_package_id
    grant = socket.assigns.grant

    case SymppBoardLive.with_dashboard_repo(fn repo -> load_detail(repo, work_package_id, grant) end) do
      {:ok, %{detail: detail, timeline: timeline}} ->
        socket
        |> assign(:detail, detail_view(detail))
        |> assign(:timeline, timeline_view(timeline))
        |> assign(:error, nil)

      {:error, reason} ->
        socket
        |> assign(:detail, empty_detail(error: error_message(reason)))
        |> assign(:timeline, %{events: []})
        |> assign(:error, error_message(reason))
    end
  end

  defp load_detail(repo, work_package_id, %AccessGrant{} = grant) do
    with {:ok, detail} <- Dashboard.detail(repo, work_package_id),
         {:ok, timeline} <- Dashboard.timeline(repo, work_package_id) do
      {:ok,
       %{
         detail: SymppDashboardApiController.scope_package_payload_for_grant(grant, detail),
         timeline: SymppDashboardApiController.scope_package_payload_for_grant(grant, timeline)
       }}
    end
  end

  defp detail_view(payload) do
    payload
    |> atomize_payload()
    |> Map.put_new(:work_package, %{})
    |> Map.put_new(:summary, %{})
    |> Map.put_new(:metadata, %{})
    |> Map.put_new(:plan, [])
    |> Map.put_new(:findings, [])
    |> Map.put_new(:artifacts, [])
    |> Map.put_new(:grants, [])
    |> Map.put_new(:agent_runs, [])
    |> Map.put_new(:alert_indicators, [])
    |> then(fn detail ->
      detail
      |> Map.update!(:work_package, &atomize_payload/1)
      |> Map.update!(:summary, &summary_view/1)
      |> Map.update!(:metadata, &atomize_payload/1)
      |> Map.update!(:plan, &atomize_list/1)
      |> Map.update!(:findings, &atomize_list/1)
      |> Map.update!(:artifacts, &atomize_list/1)
      |> Map.update!(:grants, &atomize_list/1)
      |> Map.update!(:agent_runs, &atomize_list/1)
      |> Map.update!(:alert_indicators, &atomize_list/1)
    end)
  end

  defp summary_view(summary) do
    summary
    |> atomize_payload()
    |> Map.put_new(:artifact_count, 0)
    |> Map.put_new(:finding_count, 0)
    |> Map.put_new(:progress_event_count, 0)
    |> Map.put_new(:active_blocker_count, 0)
    |> Map.put_new(:grant_count, 0)
    |> Map.put_new(:active_grant_count, 0)
    |> Map.put_new(:agent_run_count, 0)
    |> Map.put_new(:active_agent_run_count, 0)
    |> Map.put_new(:queued_agent_run_count, 0)
    |> Map.put_new(:stopped_agent_run_count, 0)
    |> Map.put_new(:failed_agent_run_count, 0)
    |> Map.put_new(:stale_agent_run_count, 0)
    |> Map.put_new(:latest_progress_at, nil)
    |> Map.update(:runtime, %{}, &atomize_payload/1)
    |> Map.update(:plan, %{total_count: 0, completed_count: 0, open_count: 0}, &atomize_payload/1)
  end

  defp timeline_view(payload) do
    events =
      payload
      |> atomize_payload()
      |> Map.get(:events, [])
      |> atomize_list()

    %{events: events}
  end

  defp empty_detail(_opts) do
    detail_view(%{
      work_package: %{},
      summary: %{},
      metadata: %{},
      plan: [],
      findings: [],
      artifacts: [],
      grants: [],
      agent_runs: [],
      alert_indicators: []
    })
  end

  defp atomize_list(values) when is_list(values), do: Enum.map(values, &atomize_payload/1)
  defp atomize_list(_values), do: []

  defp atomize_payload(%{} = payload) do
    Map.new(payload, fn {key, value} -> {atom_key(key), atomize_value(value)} end)
  end

  defp atomize_payload(_payload), do: %{}

  defp atomize_value(%{} = value), do: atomize_payload(value)
  defp atomize_value(values) when is_list(values), do: Enum.map(values, &atomize_value/1)
  defp atomize_value(value), do: value

  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: Map.get(@known_key_atoms, key, key)

  defp package_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp package_title(_work_package), do: "Work package detail"

  defp repo_base(work_package) do
    [Map.get(work_package, :repo), Map.get(work_package, :base_branch)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" / ")
    |> present()
  end

  defp list_text(values) when is_list(values) and values != [], do: Enum.join(values, ", ")
  defp list_text(_values), do: "n/a"

  defp plan_progress(%{total_count: total, completed_count: completed}) when is_integer(total) and total > 0 do
    "#{completed}/#{total}"
  end

  defp plan_progress(_plan), do: "n/a"

  defp plan_status_class(status) when status in ["done", "completed", "skipped"], do: "state-badge state-badge-active"
  defp plan_status_class(_status), do: "state-badge"

  defp branch_label(metadata) do
    branch_metadata = map_value(metadata, :branch)
    branch = map_value(branch_metadata, :branch)
    head_sha = map_value(branch_metadata, :head_sha)

    branch_label(branch, head_sha)
  end

  defp branch_label(branch, head_sha) when is_binary(branch) do
    [branch, short_sha(head_sha)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" @ ")
  end

  defp branch_label(_branch, _head_sha), do: "No branch attached"

  defp pr_url(metadata), do: metadata |> map_value(:pr) |> map_value(:url) |> public_http_url()

  defp pr_state_label(metadata) do
    pr = map_value(metadata, :pr)
    stale? = map_value(pr, :stale)
    head_sha = map_value(pr, :head_sha)
    current_head_sha = map_value(pr, :current_head_sha)

    cond do
      stale? == true -> "PR stale @ #{short_sha(head_sha) || "unknown"}; branch @ #{short_sha(current_head_sha) || "unknown"}"
      is_binary(head_sha) -> "PR head @ #{short_sha(head_sha) || head_sha}"
      true -> nil
    end
  end

  defp pr_summary_items(metadata) do
    pr = map_value(metadata, :pr)

    [
      {"Checks", pr_summary_value(pr, "check_summary", ["conclusion", "state", "status"])},
      {"Reviews", pr_summary_value(pr, "review_state", ["state", "decision", "status"])},
      {"Merge", pr_summary_value(pr, "merge_state", ["state", "mergeable_state", "status"])}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
  end

  defp pr_summary_value(pr, key, fields) do
    case map_value(pr, key) do
      %{} = state when map_size(state) > 0 ->
        Enum.find_value(fields, &compact_state_value(Map.get(state, &1))) || "recorded"

      _state ->
        nil
    end
  end

  defp compact_state_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp compact_state_value(value) when is_atom(value), do: Atom.to_string(value)
  defp compact_state_value(value) when is_boolean(value), do: to_string(value)
  defp compact_state_value(value) when is_number(value), do: to_string(value)
  defp compact_state_value(_value), do: nil

  defp map_value(%{} = map, key) when is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp map_value(%{} = map, key) when is_binary(key), do: Map.get(map, key)
  defp map_value(_map, _key), do: nil

  defp public_http_url(nil), do: nil
  defp public_http_url("[REDACTED]"), do: nil

  defp public_http_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      url
    end
  rescue
    _error in URI.Error -> nil
  end

  defp public_http_url(_url), do: nil

  defp short_sha(head_sha) when is_binary(head_sha) and byte_size(head_sha) >= 7, do: String.slice(head_sha, 0, 7)
  defp short_sha(_head_sha), do: nil

  defp timeline_title(%{type: "finding"} = event), do: event.title || "Finding"
  defp timeline_title(event), do: event.summary || event.status || "Progress"

  defp timeline_body(%{type: "finding"} = event), do: present(event.body)
  defp timeline_body(event), do: present(event.body || event.status)

  defp token_summary(run) do
    total = run.codex_total_tokens || 0
    turns = run.turn_count || 0
    "#{total} tokens / #{turns} turns"
  end

  defp alert_badge_class(%{active: true, severity: "critical"}), do: "state-badge state-badge-danger"
  defp alert_badge_class(%{active: true, severity: "warning"}), do: "state-badge state-badge-warning"
  defp alert_badge_class(%{active: true}), do: "state-badge state-badge-active"
  defp alert_badge_class(_alert), do: "state-badge"

  defp alert_state(%{active: true}), do: "active"
  defp alert_state(_alert), do: "clear"

  defp run_badge_class(%{status: "failed"}), do: "state-badge state-badge-danger"
  defp run_badge_class(%{stale: true}), do: "state-badge state-badge-warning"
  defp run_badge_class(%{runtime_state: runtime_state}) when runtime_state in ["active", "queued"], do: "state-badge state-badge-active"
  defp run_badge_class(_run), do: "state-badge"

  defp run_status_label(%{status: status}) when status in ["completed", "failed"], do: status
  defp run_status_label(%{runtime_state: runtime_state}) when is_binary(runtime_state), do: runtime_state
  defp run_status_label(%{status: status}), do: status

  defp status_label(nil), do: "n/a"

  defp status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp present(nil), do: "n/a"
  defp present(""), do: "n/a"
  defp present(value), do: value

  defp error_message(:not_found), do: "The Symphony++ work package could not be found."
  defp error_message(:database_busy), do: "The Symphony++ package ledger is busy. Refresh shortly."
  defp error_message({:repo_database_mismatch, _repo}), do: "The configured Symphony++ repo does not match the package ledger."
  defp error_message({:storage_failed, _reason}), do: "The Symphony++ package ledger could not be read."
  defp error_message(_reason), do: "The Symphony++ work package could not be loaded."
end
