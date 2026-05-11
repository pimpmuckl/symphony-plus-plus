defmodule SymphonyElixirWeb.SymppWorkRequestLive do
  @moduledoc """
  Read-only Symphony++ WorkRequest browser.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixirWeb.SymppBoardLive
  alias SymphonyElixirWeb.SymppDashboardApiController

  @impl true
  def mount(params, session, socket) do
    board_grant_id = Map.get(session, "sympp_board_grant_id")
    authorization = board_grant_authorization(board_grant_id)

    {:ok,
     socket
     |> assign(:board_grant_id, board_grant_id)
     |> assign(:board_grant, authorized_grant(authorization))
     |> assign(:work_request_id, params["work_request_id"])
     |> assign(:page, initial_page(socket.assigns.live_action, authorization))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :work_request_id, params["work_request_id"])

    case board_grant_authorization(socket.assigns.board_grant_id) do
      {:ok, grant} ->
        {:noreply,
         socket
         |> assign(:board_grant, grant)
         |> assign(:page, load_page(socket.assigns.live_action, grant, socket.assigns.work_request_id))}

      {:error, reason} ->
        {:noreply, assign(socket, :page, unauthorized_page(reason))}
    end
  end

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <section class="sympp-work-request-shell">
      <header class="sympp-work-request-header">
        <div>
          <p class="eyebrow">Symphony++</p>
          <h1 class="sympp-work-request-title">WorkRequests</h1>
        </div>

        <nav class="sympp-surface-nav" aria-label="Symphony++ surfaces">
          <a href="board">Work packages</a>
          <a class="active" href="work-requests">WorkRequests</a>
        </nav>
      </header>

      <%= if @page.error do %>
        <section class="error-card">
          <h2 class="error-title">WorkRequests unavailable</h2>
          <p class="error-copy"><%= @page.error %></p>
        </section>
      <% else %>
        <section class="sympp-work-request-summary" aria-label="WorkRequest summary">
          <div>
            <span class="sympp-board-count numeric"><%= @page.total_count %></span>
            <span class="muted">total</span>
          </div>
          <div>
            <span class="sympp-board-count numeric"><%= total_questions(@page.work_requests) %></span>
            <span class="muted">questions</span>
          </div>
          <div>
            <span class="sympp-board-count numeric"><%= total_decisions(@page.work_requests) %></span>
            <span class="muted">decisions</span>
          </div>
          <div>
            <span class="sympp-board-count numeric"><%= total_slices(@page.work_requests) %></span>
            <span class="muted">slices</span>
          </div>
        </section>

        <%= if @page.work_requests == [] do %>
          <p class="sympp-empty-state">No WorkRequests are visible for this board scope.</p>
        <% else %>
          <div class="sympp-work-request-list" role="list">
            <a :for={request <- @page.work_requests} class="sympp-work-request-row" href={work_request_path(request)} role="listitem">
              <div class="sympp-work-request-row-main">
                <div class="sympp-work-request-row-heading">
                  <span class="sympp-card-id"><%= value(request, :id) %></span>
                  <span class={status_class(value(request, :status))}><%= status_label(value(request, :status)) %></span>
                </div>
                <h2><%= value(request, :title) || "Untitled WorkRequest" %></h2>
                <dl class="sympp-work-request-meta">
                  <div>
                    <dt>Repo / base</dt>
                    <dd><%= repo_base(request) %></dd>
                  </div>
                  <div>
                    <dt>Work type</dt>
                    <dd><%= label_value(value(request, :work_type)) %></dd>
                  </div>
                  <div>
                    <dt>Dispatch shape</dt>
                    <dd><%= label_value(value(request, :desired_dispatch_shape)) %></dd>
                  </div>
                  <div>
                    <dt>Updated</dt>
                    <dd class="numeric"><%= timestamp_label(value(request, :updated_at)) %></dd>
                  </div>
                </dl>
              </div>

              <dl class="sympp-work-request-counts" aria-label="WorkRequest counts">
                <div>
                  <dt>Open Q</dt>
                  <dd class="numeric"><%= value(request, :open_question_count, 0) %></dd>
                </div>
                <div>
                  <dt>Answered</dt>
                  <dd class="numeric"><%= value(request, :answered_question_count, 0) %></dd>
                </div>
                <div>
                  <dt>Decisions</dt>
                  <dd class="numeric"><%= value(request, :decision_count, 0) %></dd>
                </div>
                <div>
                  <dt>Slices</dt>
                  <dd class="numeric"><%= slice_total(request) %></dd>
                </div>
              </dl>
            </a>
          </div>
        <% end %>
      <% end %>
    </section>
    """
  end

  def render(%{live_action: :show} = assigns) do
    ~H"""
    <section class="sympp-work-request-shell">
      <header class="sympp-work-request-header">
        <div>
          <p class="eyebrow">Symphony++ WorkRequest</p>
          <h1 class="sympp-work-request-title"><%= detail_title(@page) %></h1>
        </div>

        <nav class="sympp-surface-nav" aria-label="Symphony++ surfaces">
          <a href="../board">Work packages</a>
          <a href="../work-requests">WorkRequests</a>
        </nav>
      </header>

      <%= if @page.error do %>
        <section class="error-card">
          <h2 class="error-title">WorkRequest unavailable</h2>
          <p class="error-copy"><%= @page.error %></p>
        </section>
      <% else %>
        <section class="sympp-work-request-detail">
          <div class="sympp-work-request-detail-main">
            <div class="sympp-copy-row">
              <label for="sympp-work-request-id">WorkRequest ID</label>
              <input id="sympp-work-request-id" class="mono" readonly value={value(@page.work_request, :id)} />
            </div>
            <div class="sympp-detail-signal-row">
              <span class={status_class(value(@page.work_request, :status))}><%= status_label(value(@page.work_request, :status)) %></span>
              <span class="sympp-readiness"><%= label_value(value(@page.work_request, :work_type)) %></span>
              <span class="sympp-readiness"><%= label_value(value(@page.work_request, :desired_dispatch_shape)) %></span>
            </div>
            <p><%= value(@page.work_request, :human_description) %></p>
          </div>

          <dl class="sympp-work-request-detail-side">
            <div>
              <dt>Repo / base</dt>
              <dd><%= repo_base(@page.work_request) %></dd>
            </div>
            <div>
              <dt>Created</dt>
              <dd class="numeric"><%= timestamp_label(value(@page.work_request, :inserted_at)) %></dd>
            </div>
            <div>
              <dt>Updated</dt>
              <dd class="numeric"><%= timestamp_label(value(@page.work_request, :updated_at)) %></dd>
            </div>
          </dl>
        </section>

        <section class="sympp-work-request-summary" aria-label="WorkRequest detail counts">
          <div>
            <span class="sympp-board-count numeric"><%= value(@page.summary, :open_question_count, 0) %></span>
            <span class="muted">open questions</span>
          </div>
          <div>
            <span class="sympp-board-count numeric"><%= value(@page.summary, :answered_question_count, 0) %></span>
            <span class="muted">answered</span>
          </div>
          <div>
            <span class="sympp-board-count numeric"><%= value(@page.summary, :decision_count, 0) %></span>
            <span class="muted">decisions</span>
          </div>
          <div>
            <span class="sympp-board-count numeric"><%= summary_slice_total(@page.summary) %></span>
            <span class="muted">planned slices</span>
          </div>
        </section>

        <section class="sympp-work-request-grid">
          <article class="sympp-panel sympp-panel-wide">
            <h2>Constraints</h2>
            <pre class="sympp-json-block"><%= json_block(value(@page.work_request, :constraints, %{})) %></pre>
          </article>

          <article class="sympp-panel">
            <h2>Clarification questions</h2>
            <div :if={@page.clarification_questions != []} class="sympp-stack-list">
              <div :for={question <- @page.clarification_questions} class="sympp-stack-item">
                <div class="sympp-work-request-row-heading">
                  <span class="sympp-card-id"><%= sequence_label(question) %></span>
                  <span class={status_class(value(question, :status))}><%= status_label(value(question, :status)) %></span>
                </div>
                <p class="mono"><%= value(question, :id) %></p>
                <h3><%= value(question, :question) %></h3>
                <p><%= value(question, :why_needed) %></p>
                <p :if={value(question, :answer)}><strong>Answer:</strong> <%= value(question, :answer) %></p>
              </div>
            </div>
            <p :if={@page.clarification_questions == []} class="sympp-empty-inline">No clarification questions recorded.</p>
          </article>

          <article class="sympp-panel">
            <h2>Decision log</h2>
            <div :if={@page.decision_logs != []} class="sympp-stack-list">
              <div :for={decision <- @page.decision_logs} class="sympp-stack-item">
                <div class="sympp-work-request-row-heading">
                  <span class="sympp-card-id"><%= sequence_label(decision) %></span>
                  <span class="sympp-readiness"><%= label_value(value(decision, :source_type)) %></span>
                </div>
                <p class="mono"><%= value(decision, :id) %></p>
                <h3><%= value(decision, :decision) %></h3>
                <p><%= value(decision, :rationale) %></p>
                <p><%= value(decision, :scope_impact) %></p>
              </div>
            </div>
            <p :if={@page.decision_logs == []} class="sympp-empty-inline">No decisions recorded.</p>
          </article>

          <article class="sympp-panel sympp-panel-wide">
            <h2>Planned slices</h2>
            <div :if={@page.planned_slices != []} class="sympp-slice-list">
              <div :for={slice <- @page.planned_slices} class="sympp-slice-row">
                <div>
                  <div class="sympp-work-request-row-heading">
                    <span class="sympp-card-id"><%= sequence_label(slice) %></span>
                    <span class={status_class(value(slice, :status))}><%= status_label(value(slice, :status)) %></span>
                  </div>
                  <p class="mono"><%= value(slice, :id) %></p>
                  <h3><%= value(slice, :title) %></h3>
                  <p><%= value(slice, :goal) %></p>
                </div>
                <dl class="sympp-work-request-meta">
                  <div>
                    <dt>Kind</dt>
                    <dd><%= label_value(value(slice, :work_package_kind)) %></dd>
                  </div>
                  <div>
                    <dt>Target base</dt>
                    <dd><%= label_value(value(slice, :target_base_branch)) %></dd>
                  </div>
                  <div>
                    <dt>Owned files</dt>
                    <dd><%= list_label(value(slice, :owned_file_globs, [])) %></dd>
                  </div>
                  <div>
                    <dt>Review</dt>
                    <dd><%= list_label(value(slice, :review_lanes, [])) %></dd>
                  </div>
                </dl>
              </div>
            </div>
            <p :if={@page.planned_slices == []} class="sympp-empty-inline">No planned slices recorded.</p>
          </article>
        </section>
      <% end %>
    </section>
    """
  end

  defp board_grant_authorization(grant_id) do
    case SymppDashboardApiController.authorize_board_grant_id(grant_id) do
      {:ok, grant} -> {:ok, grant}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorized_grant({:ok, grant}), do: grant
  defp authorized_grant(_authorization), do: nil

  defp initial_page(_live_action, {:ok, _grant}), do: loading_page()
  defp initial_page(_live_action, {:error, reason}), do: unauthorized_page(reason)

  defp load_page(:index, %AccessGrant{} = grant, _work_request_id) do
    case SymppBoardLive.with_dashboard_repo(&Dashboard.work_requests_for_grant(&1, grant)) do
      {:ok, payload} -> Map.merge(%{error: nil}, payload)
      {:error, reason} -> error_page(reason)
    end
  end

  defp load_page(:show, %AccessGrant{} = grant, work_request_id) when is_binary(work_request_id) do
    case SymppBoardLive.with_dashboard_repo(&Dashboard.work_request_detail_for_grant(&1, work_request_id, grant)) do
      {:ok, payload} -> Map.merge(%{error: nil}, payload)
      {:error, reason} -> error_page(reason)
    end
  end

  defp load_page(:show, %AccessGrant{}, _work_request_id), do: error_page(:not_found)

  defp loading_page do
    %{
      error: nil,
      total_count: 0,
      work_requests: [],
      work_request: %{},
      clarification_questions: [],
      decision_logs: [],
      planned_slices: [],
      summary: %{}
    }
  end

  defp unauthorized_page(reason) when reason in [:unauthorized, :forbidden] do
    Map.put(loading_page(), :error, "Board access expired. Reload and enter a current board work key.")
  end

  defp unauthorized_page(reason), do: error_page(reason)

  defp error_page(reason), do: Map.put(loading_page(), :error, error_message(reason))

  defp error_message(:not_found), do: "The WorkRequest was not found in this board scope."
  defp error_message(:database_busy), do: "The Symphony++ ledger is busy. Refresh shortly."
  defp error_message({:storage_failed, _reason}), do: "The Symphony++ ledger could not be read."
  defp error_message(_reason), do: "The WorkRequest surface could not be loaded."

  defp detail_title(%{work_request: work_request}) when is_map(work_request) do
    value(work_request, :title) || value(work_request, :id) || "WorkRequest"
  end

  defp detail_title(_page), do: "WorkRequest"

  defp work_request_path(request), do: "work-requests/#{path_segment(value(request, :id))}"

  defp path_segment("."), do: "%2E"
  defp path_segment(".."), do: "%2E%2E"
  defp path_segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  defp repo_base(item) do
    [value(item, :repo), value(item, :base_branch)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" / ")
    |> case do
      "" -> "n/a"
      label -> label
    end
  end

  defp total_questions(requests) do
    Enum.reduce(requests, 0, fn request, count ->
      count + value(request, :open_question_count, 0) + value(request, :answered_question_count, 0) +
        value(request, :closed_question_count, 0)
    end)
  end

  defp total_decisions(requests), do: Enum.reduce(requests, 0, &(&2 + value(&1, :decision_count, 0)))
  defp total_slices(requests), do: Enum.reduce(requests, 0, &(&2 + slice_total(&1)))

  defp slice_total(item) do
    value(item, :planned_slice_count, 0) + value(item, :approved_slice_count, 0) +
      value(item, :dispatched_slice_count, 0) + value(item, :skipped_slice_count, 0)
  end

  defp summary_slice_total(summary), do: slice_total(summary)

  defp sequence_label(item), do: "##{value(item, :sequence, "?")}"

  defp status_label(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp status_label(value), do: label_value(value)

  defp status_class("open"), do: "state-badge state-badge-warning"
  defp status_class("human_info_needed"), do: "state-badge state-badge-warning"
  defp status_class("ready_for_clarification"), do: "state-badge state-badge-warning"
  defp status_class("answered"), do: "state-badge state-badge-active"
  defp status_class("approved"), do: "state-badge state-badge-active"
  defp status_class("dispatched"), do: "state-badge state-badge-active"
  defp status_class("sliced"), do: "state-badge state-badge-active"
  defp status_class("closed"), do: "state-badge"
  defp status_class(_status), do: "state-badge"

  defp timestamp_label(nil), do: "n/a"
  defp timestamp_label(value), do: to_string(value)

  defp label_value(nil), do: "n/a"
  defp label_value(""), do: "n/a"
  defp label_value(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp label_value(value), do: to_string(value)

  defp list_label([]), do: "n/a"
  defp list_label(values) when is_list(values), do: Enum.map_join(values, ", ", &to_string/1)
  defp list_label(value), do: label_value(value)

  defp json_block(value), do: Jason.encode!(value, pretty: true)

  defp value(map, key, default \\ nil)
  defp value(map, key, default) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp value(_map, _key, default), do: default
end
