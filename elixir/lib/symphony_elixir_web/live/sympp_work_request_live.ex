defmodule SymphonyElixirWeb.SymppWorkRequestLive do
  @moduledoc """
  Symphony++ WorkRequest browser and clarification surface.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  import Ecto.Query
  import Phoenix.HTML.Form, only: [input_value: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest
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
     |> assign(:path_prefix, "")
     |> assign(:work_request_id, params["work_request_id"])
     |> assign(:page, initial_page(socket.assigns.live_action, authorization))}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket = assign(socket, :work_request_id, params["work_request_id"])

    case board_grant_authorization(socket.assigns.board_grant_id) do
      {:ok, grant} ->
        {:noreply,
         socket
         |> assign(:board_grant, grant)
         |> assign(:path_prefix, path_prefix(uri, socket.assigns.live_action, params))
         |> assign(
           :page,
           load_page(socket.assigns.live_action, grant, socket.assigns.work_request_id)
         )}

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

        <div class="sympp-work-request-header-actions">
          <nav class="sympp-surface-nav" aria-label="Symphony++ surfaces">
            <a href="board">Work packages</a>
            <a class="active" href="work-requests">WorkRequests</a>
          </nav>
          <a :if={can_create_work_request?(@board_grant)} class="sympp-primary-link" href="work-requests/new">New WorkRequest</a>
        </div>
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

  def render(%{live_action: :new} = assigns) do
    ~H"""
    <section class="sympp-work-request-shell">
      <header class="sympp-work-request-header">
        <div>
          <p class="eyebrow">Symphony++ WorkRequest</p>
          <h1 class="sympp-work-request-title">New WorkRequest</h1>
        </div>

        <nav class="sympp-surface-nav" aria-label="Symphony++ surfaces">
          <a href="../board">Work packages</a>
          <a href="../work-requests">WorkRequests</a>
        </nav>
      </header>

      <%= if @page.error do %>
        <section class="error-card">
          <h2 class="error-title">WorkRequest intake unavailable</h2>
          <p class="error-copy"><%= @page.error %></p>
        </section>
      <% else %>
        <.form :let={f} for={@page.form} as={:work_request} phx-submit="create_work_request" class="sympp-work-request-form">
          <section class="sympp-locked-scope" aria-label="Locked WorkRequest scope">
            <div>
              <span>Repo</span>
              <strong><%= @page.intake_scope.repo %></strong>
            </div>
            <div>
              <span>Base branch</span>
              <strong><%= @page.intake_scope.base_branch %></strong>
            </div>
          </section>

          <p :if={@page.form_error} class="sympp-form-error"><%= @page.form_error %></p>

          <div class="sympp-form-grid">
            <label>
              <span>Title</span>
              <input name={f[:title].name} value={input_value(f, :title)} required maxlength="160" />
            </label>

            <label>
              <span>Work type</span>
              <select name={f[:work_type].name} required>
                <option :for={work_type <- WorkRequest.work_types()} value={work_type} selected={input_value(f, :work_type) == work_type}>
                  <%= label_value(work_type) %>
                </option>
              </select>
            </label>

            <label>
              <span>Dispatch shape</span>
              <select name={f[:desired_dispatch_shape].name} required>
                <option
                  :for={shape <- WorkRequest.dispatch_shapes()}
                  value={shape}
                  selected={input_value(f, :desired_dispatch_shape) == shape}
                >
                  <%= label_value(shape) %>
                </option>
              </select>
            </label>

            <label class="sympp-form-wide">
              <span>Description</span>
              <textarea name={f[:human_description].name} required rows="6"><%= input_value(f, :human_description) %></textarea>
            </label>

            <label class="sympp-form-wide">
              <span>Constraints JSON</span>
              <textarea name={f[:constraints_json].name} rows="7" spellcheck="false"><%= input_value(f, :constraints_json) %></textarea>
            </label>
          </div>

          <div class="sympp-form-actions">
            <button type="submit">Create draft</button>
            <a class="sympp-secondary-link" href="../work-requests">Cancel</a>
          </div>
        </.form>
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
            <p :if={@page.action_error} class="sympp-form-error"><%= @page.action_error %></p>
            <div class="sympp-action-row">
              <button
                :if={value(@page.work_request, :status) == "draft"}
                type="button"
                phx-click="mark_ready_for_clarification"
              >
                Mark ready for clarification
              </button>
              <button
                :if={can_mark_human_info_needed?(@page.work_request)}
                type="button"
                class="secondary"
                phx-click="mark_human_info_needed"
              >
                Mark human info needed
              </button>
              <button
                :if={can_mark_ready_for_slicing?(@page.work_request)}
                type="button"
                phx-click="mark_ready_for_slicing"
              >
                Mark ready for slicing
              </button>
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
            <.form
              :if={can_clarify?(@page.work_request)}
              :let={f}
              for={%{}}
              as={:question}
              phx-submit="ask_question"
              class="sympp-compact-form"
            >
              <div class="sympp-form-grid sympp-form-grid-compact">
                <label>
                  <span>Category</span>
                  <input name={f[:category].name} required maxlength="80" />
                </label>
                <label class="sympp-form-wide">
                  <span>Question</span>
                  <textarea name={f[:question].name} required rows="3"></textarea>
                </label>
                <label class="sympp-form-wide">
                  <span>Why needed</span>
                  <textarea name={f[:why_needed].name} required rows="2"></textarea>
                </label>
              </div>
              <div class="sympp-form-actions">
                <button type="submit">Ask question</button>
              </div>
            </.form>
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
                <div :if={value(question, :status) == "open"} class="sympp-question-actions">
                  <.form :let={f} for={%{}} as={:question} phx-submit="answer_question" class="sympp-inline-answer-form">
                    <input type="hidden" name={f[:id].name} value={value(question, :id)} />
                    <input type="hidden" name={f[:current_status].name} value={value(question, :status)} />
                    <label>
                      <span>Answer</span>
                      <textarea name={f[:answer].name} required rows="2"></textarea>
                    </label>
                    <label>
                      <span>Answered by</span>
                      <input name={f[:answered_by].name} value={default_actor(@board_grant)} required maxlength="120" />
                    </label>
                    <div class="sympp-form-actions">
                      <button type="submit">Answer</button>
                    </div>
                  </.form>
                  <.form :let={f} for={%{}} as={:question} phx-submit="close_question" class="sympp-close-form">
                    <input type="hidden" name={f[:id].name} value={value(question, :id)} />
                    <input type="hidden" name={f[:current_status].name} value={value(question, :status)} />
                    <button type="submit" class="secondary">Close unanswered</button>
                  </.form>
                </div>
              </div>
            </div>
            <p :if={@page.clarification_questions == []} class="sympp-empty-inline">No clarification questions recorded.</p>
          </article>

          <article class="sympp-panel">
            <h2>Decision log</h2>
            <.form
              :if={can_clarify?(@page.work_request)}
              :let={f}
              for={%{}}
              as={:decision}
              phx-submit="record_decision"
              class="sympp-compact-form"
            >
              <div class="sympp-form-grid sympp-form-grid-compact">
                <label>
                  <span>Source</span>
                  <select name={f[:source_type].name} required>
                    <option :for={source <- decision_source_types()} value={source}><%= label_value(source) %></option>
                  </select>
                </label>
                <label>
                  <span>Created by</span>
                  <input name={f[:created_by].name} value={default_actor(@board_grant)} required maxlength="120" />
                </label>
                <label class="sympp-form-wide">
                  <span>Decision</span>
                  <textarea name={f[:decision].name} required rows="2"></textarea>
                </label>
                <label class="sympp-form-wide">
                  <span>Rationale</span>
                  <textarea name={f[:rationale].name} required rows="2"></textarea>
                </label>
                <label class="sympp-form-wide">
                  <span>Scope impact</span>
                  <textarea name={f[:scope_impact].name} required rows="2"></textarea>
                </label>
              </div>
              <div class="sympp-form-actions">
                <button type="submit">Record decision</button>
              </div>
            </.form>
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

  @impl true
  def handle_event("create_work_request", %{"work_request" => params}, socket) do
    case board_grant_authorization(socket.assigns.board_grant_id) do
      {:ok, %AccessGrant{} = grant} ->
        socket = assign(socket, :board_grant, grant)

        case create_work_request(grant, params) do
          {:ok, work_request} ->
            {:noreply,
             socket
             |> put_flash(:info, "WorkRequest draft created.")
             |> push_navigate(to: work_request_route(socket, work_request.id))}

          {:error, reason, form} ->
            {:noreply, assign(socket, :page, new_page(grant, form, form_error_message(reason)))}
        end

      {:error, reason} ->
        {:noreply, assign(socket, :page, unauthorized_page(reason))}
    end
  end

  def handle_event("mark_ready_for_clarification", _params, socket) do
    case board_grant_authorization(socket.assigns.board_grant_id) do
      {:ok, %AccessGrant{} = grant} ->
        socket = assign(socket, :board_grant, grant)

        case mark_ready_for_clarification(grant, socket.assigns.work_request_id) do
          {:ok, _work_request} ->
            {:noreply,
             socket
             |> put_flash(:info, "WorkRequest marked ready for clarification.")
             |> assign(:page, load_page(:show, grant, socket.assigns.work_request_id))}

          {:error, reason} ->
            page =
              :show
              |> load_page(grant, socket.assigns.work_request_id)
              |> Map.put(:action_error, action_error_message(reason))

            {:noreply, assign(socket, :page, page)}
        end

      {:error, reason} ->
        {:noreply, assign(socket, :page, unauthorized_page(reason))}
    end
  end

  def handle_event("ask_question", %{"question" => params}, socket) do
    handle_scoped_action(socket, fn grant ->
      ask_question(grant, socket.assigns.work_request_id, params)
    end)
  end

  def handle_event("answer_question", %{"question" => params}, socket) do
    handle_scoped_action(socket, fn grant ->
      answer_question(grant, socket.assigns.work_request_id, params)
    end)
  end

  def handle_event("close_question", %{"question" => params}, socket) do
    handle_scoped_action(socket, fn grant ->
      close_question(grant, socket.assigns.work_request_id, params)
    end)
  end

  def handle_event("record_decision", %{"decision" => params}, socket) do
    handle_scoped_action(socket, fn grant ->
      record_decision(grant, socket.assigns.work_request_id, params)
    end)
  end

  def handle_event("mark_human_info_needed", _params, socket) do
    handle_scoped_action(socket, fn grant ->
      mark_human_info_needed(grant, socket.assigns.work_request_id)
    end)
  end

  def handle_event("mark_ready_for_slicing", _params, socket) do
    handle_scoped_action(socket, fn grant ->
      mark_ready_for_slicing(grant, socket.assigns.work_request_id)
    end)
  end

  defp handle_scoped_action(socket, action) when is_function(action, 1) do
    case board_grant_authorization(socket.assigns.board_grant_id) do
      {:ok, %AccessGrant{} = grant} ->
        socket = assign(socket, :board_grant, grant)

        case action.(grant) do
          {:ok, _result} ->
            {:noreply, assign(socket, :page, load_page(:show, grant, socket.assigns.work_request_id))}

          {:error, reason} ->
            page =
              :show
              |> load_page(grant, socket.assigns.work_request_id)
              |> Map.put(:action_error, action_error_message(reason))

            {:noreply, assign(socket, :page, page)}
        end

      {:error, reason} ->
        {:noreply, assign(socket, :page, unauthorized_page(reason))}
    end
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
      {:ok, payload} -> loading_page() |> Map.merge(payload) |> Map.put(:error, nil)
      {:error, reason} -> error_page(reason)
    end
  end

  defp load_page(:new, %AccessGrant{} = grant, _work_request_id), do: new_page(grant)

  defp load_page(:show, %AccessGrant{} = grant, work_request_id)
       when is_binary(work_request_id) do
    case SymppBoardLive.with_dashboard_repo(&Dashboard.work_request_detail_for_grant(&1, work_request_id, grant)) do
      {:ok, payload} -> loading_page() |> Map.merge(payload) |> Map.put(:error, nil)
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
      summary: %{},
      form: work_request_form(),
      form_error: nil,
      intake_scope: nil,
      action_error: nil
    }
  end

  defp new_page(%AccessGrant{} = grant, form \\ work_request_form(), form_error \\ nil) do
    case intake_scope(grant) do
      {:ok, scope} ->
        loading_page()
        |> Map.put(:form, work_request_form(form))
        |> Map.put(:form_error, form_error)
        |> Map.put(:intake_scope, scope)

      {:error, reason} ->
        error_page(reason)
    end
  end

  defp unauthorized_page(reason) when reason in [:unauthorized, :forbidden] do
    Map.put(
      loading_page(),
      :error,
      "Board access expired. Reload and enter a current board work key."
    )
  end

  defp unauthorized_page(reason), do: error_page(reason)

  defp error_page(reason), do: Map.put(loading_page(), :error, error_message(reason))

  defp error_message(:not_found), do: "The WorkRequest was not found in this board scope."

  defp error_message(:forbidden),
    do: "This board grant cannot create WorkRequests for a frozen repo and base branch."

  defp error_message(:database_busy), do: "The Symphony++ ledger is busy. Refresh shortly."
  defp error_message({:storage_failed, _reason}), do: "The Symphony++ ledger could not be read."
  defp error_message(_reason), do: "The WorkRequest surface could not be loaded."

  defp form_error_message(:invalid_constraints_json), do: "Constraints must be valid JSON."
  defp form_error_message(:constraints_not_object), do: "Constraints JSON must be an object."
  defp form_error_message(:forbidden), do: error_message(:forbidden)
  defp form_error_message(:database_busy), do: "The Symphony++ ledger is busy. Try again shortly."

  defp form_error_message({:storage_failed, _reason}),
    do: "The Symphony++ ledger could not store the WorkRequest."

  defp form_error_message(%Ecto.Changeset{}), do: "Check the required fields and selected values."
  defp form_error_message(_reason), do: "The WorkRequest could not be created."

  defp action_error_message(:stale_status),
    do: "The WorkRequest status changed. Refresh and try again."

  defp action_error_message(:already_answered), do: "That question is already answered."
  defp action_error_message(:already_closed), do: "That question is already closed."

  defp action_error_message(:open_questions),
    do: "Close or answer all open questions before marking ready for slicing."

  defp action_error_message(:invalid_status),
    do: "That action is not available from the current status."

  defp action_error_message(:not_found), do: "The WorkRequest was not found in this board scope."

  defp action_error_message(:database_busy),
    do: "The Symphony++ ledger is busy. Try again shortly."

  defp action_error_message({:storage_failed, _reason}),
    do: "The Symphony++ ledger could not update the WorkRequest."

  defp action_error_message(:forbidden), do: error_message(:forbidden)

  defp action_error_message(%Ecto.Changeset{}),
    do: "Check the required fields and selected values."

  defp action_error_message(_reason), do: "The WorkRequest could not be updated."

  defp create_work_request(%AccessGrant{} = grant, params) do
    form = work_request_form(params)

    with {:ok, scope} <- intake_scope(grant),
         {:ok, constraints} <- decode_constraints(form["constraints_json"]) do
      attrs =
        form
        |> Map.take(["title", "work_type", "human_description", "desired_dispatch_shape"])
        |> Map.put("repo", scope.repo)
        |> Map.put("base_branch", scope.base_branch)
        |> Map.put("constraints", constraints)

      case SymppBoardLive.with_dashboard_repo(&WorkRequestService.create(&1, attrs)) do
        {:ok, work_request} -> {:ok, work_request}
        {:error, reason} -> {:error, reason, form}
      end
    else
      {:error, reason} -> {:error, reason, form}
    end
  end

  defp mark_ready_for_clarification(%AccessGrant{} = grant, work_request_id)
       when is_binary(work_request_id) do
    SymppBoardLive.with_dashboard_repo(&mark_ready_in_repo(&1, grant, work_request_id))
  end

  defp mark_ready_for_clarification(_grant, _work_request_id), do: {:error, :not_found}

  defp ask_question(%AccessGrant{} = grant, work_request_id, params)
       when is_binary(work_request_id) and is_map(params) do
    SymppBoardLive.with_dashboard_repo(&ask_question_in_repo(&1, grant, work_request_id, params))
  end

  defp ask_question(_grant, _work_request_id, _params), do: {:error, :not_found}

  defp answer_question(%AccessGrant{} = grant, work_request_id, params)
       when is_binary(work_request_id) and is_map(params) do
    SymppBoardLive.with_dashboard_repo(&answer_question_in_repo(&1, grant, work_request_id, params))
  end

  defp answer_question(_grant, _work_request_id, _params), do: {:error, :not_found}

  defp close_question(%AccessGrant{} = grant, work_request_id, params)
       when is_binary(work_request_id) and is_map(params) do
    SymppBoardLive.with_dashboard_repo(&close_question_in_repo(&1, grant, work_request_id, params))
  end

  defp close_question(_grant, _work_request_id, _params), do: {:error, :not_found}

  defp record_decision(%AccessGrant{} = grant, work_request_id, params)
       when is_binary(work_request_id) and is_map(params) do
    SymppBoardLive.with_dashboard_repo(&record_decision_in_repo(&1, grant, work_request_id, params))
  end

  defp record_decision(_grant, _work_request_id, _params), do: {:error, :not_found}

  defp mark_human_info_needed(%AccessGrant{} = grant, work_request_id)
       when is_binary(work_request_id) do
    SymppBoardLive.with_dashboard_repo(&mark_human_info_needed_in_repo(&1, grant, work_request_id))
  end

  defp mark_human_info_needed(_grant, _work_request_id), do: {:error, :not_found}

  defp mark_ready_for_slicing(%AccessGrant{} = grant, work_request_id)
       when is_binary(work_request_id) do
    SymppBoardLive.with_dashboard_repo(&mark_ready_for_slicing_in_repo(&1, grant, work_request_id))
  end

  defp mark_ready_for_slicing(_grant, _work_request_id), do: {:error, :not_found}

  defp mark_ready_in_repo(repo, %AccessGrant{} = grant, work_request_id) do
    with {:ok, scope} <- intake_scope(repo, grant),
         {:ok, work_request} <- WorkRequestService.get(repo, work_request_id),
         :ok <- work_request_in_scope?(work_request, scope),
         :ok <- visible_work_request?(repo, work_request, grant) do
      WorkRequestService.update_status(repo, work_request_id, "draft", "ready_for_clarification")
    end
  end

  defp ask_question_in_repo(repo, %AccessGrant{} = grant, work_request_id, params) do
    with {:ok, work_request} <- scoped_work_request(repo, grant, work_request_id),
         :ok <- require_clarification_status(work_request.status),
         attrs <- question_attrs(params, grant) do
      ask_question_transaction(repo, work_request, attrs)
    end
  end

  defp answer_question_in_repo(repo, %AccessGrant{} = grant, work_request_id, params) do
    with {:ok, work_request} <- scoped_work_request(repo, grant, work_request_id),
         :ok <- require_clarification_status(work_request.status),
         {:ok, question} <- scoped_question(repo, work_request.id, Map.get(params, "id")) do
      WorkRequestService.answer_question(
        repo,
        question.id,
        Map.get(params, "current_status", ""),
        answer_attrs(params, grant)
      )
    end
  end

  defp close_question_in_repo(repo, %AccessGrant{} = grant, work_request_id, params) do
    with {:ok, work_request} <- scoped_work_request(repo, grant, work_request_id),
         :ok <- require_clarification_status(work_request.status),
         {:ok, question} <- scoped_question(repo, work_request.id, Map.get(params, "id")) do
      WorkRequestService.close_question(repo, question.id, Map.get(params, "current_status", ""))
    end
  end

  defp record_decision_in_repo(repo, %AccessGrant{} = grant, work_request_id, params) do
    with {:ok, work_request} <- scoped_work_request(repo, grant, work_request_id),
         :ok <- require_clarification_status(work_request.status) do
      WorkRequestService.record_decision(repo, work_request.id, decision_attrs(params, grant))
    end
  end

  defp mark_human_info_needed_in_repo(repo, %AccessGrant{} = grant, work_request_id) do
    with {:ok, work_request} <- scoped_work_request(repo, grant, work_request_id),
         :ok <- require_status(work_request.status, ["ready_for_clarification", "clarifying"]) do
      WorkRequestService.update_status(
        repo,
        work_request.id,
        work_request.status,
        "human_info_needed"
      )
    end
  end

  defp mark_ready_for_slicing_in_repo(repo, %AccessGrant{} = grant, work_request_id) do
    with {:ok, work_request} <- scoped_work_request(repo, grant, work_request_id),
         :ok <-
           require_status(work_request.status, [
             "ready_for_clarification",
             "clarifying",
             "human_info_needed"
           ]) do
      mark_ready_for_slicing_transaction(repo, work_request)
    end
  end

  defp ask_question_transaction(repo, work_request, attrs) do
    repo.transaction(fn ->
      with {:ok, work_request} <- transition_to_clarifying(repo, work_request),
           {:ok, question} <- WorkRequestService.ask_question(repo, work_request.id, attrs) do
        question
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp mark_ready_for_slicing_transaction(repo, work_request) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      work_request.id
      |> ready_for_slicing_update_query(work_request.status)
      |> repo.update_all(set: [status: "ready_for_slicing", updated_at: now])
      |> case do
        {1, _rows} -> repo.get!(WorkRequest, work_request.id)
        {0, _rows} -> repo.rollback(ready_for_slicing_blocker(repo, work_request))
      end
    end)
    |> normalize_transaction_result()
  end

  defp ready_for_slicing_update_query(work_request_id, current_status) do
    from(work_request in WorkRequest,
      where: work_request.id == ^work_request_id and work_request.status == ^current_status,
      where:
        fragment(
          """
          NOT EXISTS (
            SELECT 1
            FROM sympp_work_request_clarification_questions AS question
            WHERE question.work_request_id = ? AND question.status = 'open'
          )
          """,
          work_request.id
        )
    )
  end

  defp ready_for_slicing_blocker(repo, work_request) do
    cond do
      open_questions?(repo, work_request.id) ->
        :open_questions

      stale_work_request_status?(repo, work_request) ->
        :stale_status

      true ->
        :not_found
    end
  end

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp scoped_work_request(repo, %AccessGrant{} = grant, work_request_id) do
    with {:ok, scope} <- intake_scope(repo, grant),
         {:ok, work_request} <- WorkRequestService.get(repo, work_request_id),
         :ok <- work_request_in_scope?(work_request, scope),
         :ok <- visible_work_request?(repo, work_request, grant) do
      {:ok, work_request}
    end
  end

  defp scoped_question(repo, work_request_id, question_id) when is_binary(question_id) do
    with {:ok, questions} <- WorkRequestService.list_questions(repo, work_request_id) do
      case Enum.find(questions, &(&1.id == question_id)) do
        nil -> {:error, :not_found}
        question -> {:ok, question}
      end
    end
  end

  defp scoped_question(_repo, _work_request_id, _question_id), do: {:error, :not_found}

  defp transition_to_clarifying(repo, %{status: "ready_for_clarification"} = work_request) do
    WorkRequestService.update_status(
      repo,
      work_request.id,
      "ready_for_clarification",
      "clarifying"
    )
  end

  defp transition_to_clarifying(repo, %{status: status} = work_request)
       when status in ["clarifying", "human_info_needed"] do
    WorkRequestService.update_status(repo, work_request.id, status, status)
  end

  defp transition_to_clarifying(_repo, _work_request), do: {:error, :invalid_status}

  defp require_clarification_status(status),
    do: require_status(status, ["ready_for_clarification", "clarifying", "human_info_needed"])

  defp require_status(status, allowed_statuses) do
    if status in allowed_statuses, do: :ok, else: {:error, :invalid_status}
  end

  defp open_questions?(repo, work_request_id) do
    case WorkRequestService.list_questions(repo, work_request_id) do
      {:ok, questions} -> Enum.any?(questions, &(&1.status == "open"))
      {:error, _reason} -> false
    end
  end

  defp stale_work_request_status?(repo, work_request) do
    case repo.get(WorkRequest, work_request.id) do
      %WorkRequest{status: status} -> status != work_request.status
      nil -> false
    end
  end

  defp visible_work_request?(repo, work_request, %AccessGrant{} = grant) do
    with {:ok, filters} <- Dashboard.work_request_filters_for_grant(repo, grant) do
      if work_request_matches_filters?(work_request, filters) do
        :ok
      else
        {:error, :not_found}
      end
    end
  end

  defp work_request_matches_filters?(work_request, filters) do
    Enum.all?(filters, fn
      {:repo, repo} when is_binary(repo) ->
        work_request.repo == repo

      {:base_branch, base_branch} when is_binary(base_branch) ->
        work_request.base_branch == base_branch

      _filter ->
        false
    end)
  end

  defp can_create_work_request?(%AccessGrant{} = grant),
    do: match?({:ok, _scope}, intake_scope(grant))

  defp can_create_work_request?(_grant), do: false

  defp intake_scope(%AccessGrant{} = grant) do
    case SymppBoardLive.with_dashboard_repo(&intake_scope(&1, grant)) do
      {:ok, scope} -> {:ok, scope}
      {:error, reason} -> {:error, reason}
    end
  end

  defp intake_scope(repo, %AccessGrant{} = grant) do
    with {:ok, grant_scope} <- grant_frozen_scope(grant),
         {:ok, filters} <- Dashboard.work_request_filters_for_grant(repo, grant),
         {:ok, filter_scope} <- supported_intake_filter_scope(filters),
         :ok <- matching_intake_scopes?(grant_scope, filter_scope) do
      {:ok, grant_scope}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  defp work_request_in_scope?(work_request, %{repo: repo, base_branch: base_branch}) do
    if work_request.repo == repo and work_request.base_branch == base_branch do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp grant_frozen_scope(%AccessGrant{scope_repo: repo, scope_base_branch: base_branch}) do
    with {:ok, repo} <- locked_scope_value(repo),
         {:ok, base_branch} <- locked_scope_value(base_branch) do
      {:ok, %{repo: repo, base_branch: base_branch}}
    end
  end

  defp supported_intake_filter_scope(filters) when is_list(filters) do
    Enum.reduce_while(filters, {:ok, %{}}, fn
      {:repo, repo}, {:ok, scope} ->
        {:cont, {:ok, Map.put(scope, :repo, repo)}}

      {:base_branch, base_branch}, {:ok, scope} ->
        {:cont, {:ok, Map.put(scope, :base_branch, base_branch)}}

      _filter, _acc ->
        {:halt, {:error, :forbidden}}
    end)
    |> case do
      {:ok, %{repo: repo, base_branch: base_branch}} ->
        with {:ok, repo} <- locked_scope_value(repo),
             {:ok, base_branch} <- locked_scope_value(base_branch) do
          {:ok, %{repo: repo, base_branch: base_branch}}
        end

      {:ok, _scope} ->
        {:error, :forbidden}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp matching_intake_scopes?(scope, scope), do: :ok
  defp matching_intake_scopes?(_grant_scope, _filter_scope), do: {:error, :forbidden}

  defp locked_scope_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :forbidden}
      trimmed -> {:ok, trimmed}
    end
  end

  defp locked_scope_value(_value), do: {:error, :forbidden}

  defp work_request_form(attrs \\ %{}) do
    attrs = normalize_keys(attrs)

    %{
      "title" => Map.get(attrs, "title", ""),
      "work_type" => Map.get(attrs, "work_type", "feature"),
      "desired_dispatch_shape" => Map.get(attrs, "desired_dispatch_shape", "single_package"),
      "human_description" => Map.get(attrs, "human_description", ""),
      "constraints_json" => Map.get(attrs, "constraints_json", "{\n  \"allowed_paths\": []\n}")
    }
  end

  defp decode_constraints(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, %{}}

      json ->
        case Jason.decode(json) do
          {:ok, constraints} when is_map(constraints) -> {:ok, constraints}
          {:ok, _value} -> {:error, :constraints_not_object}
          {:error, _reason} -> {:error, :invalid_constraints_json}
        end
    end
  end

  defp decode_constraints(_value), do: {:error, :invalid_constraints_json}

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp question_attrs(params, %AccessGrant{} = grant) do
    params
    |> normalize_keys()
    |> Map.take(["category", "question", "why_needed"])
    |> put_if_filled("asked_by_agent_run_id", default_actor(grant))
  end

  defp answer_attrs(params, %AccessGrant{} = grant) do
    params
    |> normalize_keys()
    |> Map.take(["answer", "answered_by"])
    |> put_if_filled("answered_by", default_actor(grant))
  end

  defp decision_attrs(params, %AccessGrant{} = grant) do
    params
    |> normalize_keys()
    |> Map.take([
      "source_type",
      "source_id",
      "decision",
      "rationale",
      "scope_impact",
      "created_by"
    ])
    |> put_if_filled("created_by", default_actor(grant))
  end

  defp put_if_filled(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""] and filled_string?(value) do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp can_clarify?(work_request),
    do:
      value(work_request, :status) in [
        "ready_for_clarification",
        "clarifying",
        "human_info_needed"
      ]

  defp can_mark_human_info_needed?(work_request),
    do: value(work_request, :status) in ["ready_for_clarification", "clarifying"]

  defp can_mark_ready_for_slicing?(work_request) do
    value(work_request, :status) in ["ready_for_clarification", "clarifying", "human_info_needed"]
  end

  defp decision_source_types, do: ["human", "architect", "operator", "ask_pro_advisory"]

  defp default_actor(%AccessGrant{claimed_by: claimed_by}) when is_binary(claimed_by),
    do: claimed_by

  defp default_actor(%AccessGrant{id: id}) when is_binary(id), do: id
  defp default_actor(_grant), do: "operator"

  defp filled_string?(value), do: String.trim(value) != ""

  defp detail_title(%{work_request: work_request}) when is_map(work_request) do
    value(work_request, :title) || value(work_request, :id) || "WorkRequest"
  end

  defp detail_title(_page), do: "WorkRequest"

  defp work_request_path(request), do: "work-requests/#{path_segment(value(request, :id))}"

  defp work_request_route(socket, work_request_id) do
    prefixed_path(
      socket.assigns.path_prefix,
      "/sympp/work-requests/#{path_segment(work_request_id)}"
    )
  end

  defp path_prefix(uri, :new, _params), do: path_prefix(uri, "/sympp/work-requests/new")
  defp path_prefix(uri, :index, _params), do: path_prefix(uri, "/sympp/work-requests")

  defp path_prefix(uri, :show, %{"work_request_id" => id}),
    do: path_prefix(uri, "/sympp/work-requests/#{path_segment(id)}")

  defp path_prefix(_uri, _action, _params), do: ""

  defp path_prefix(uri, route_path) do
    path = uri |> URI.parse() |> Map.get(:path) |> Kernel.||("")

    if String.ends_with?(path, route_path) do
      path
      |> String.slice(0, byte_size(path) - byte_size(route_path))
      |> normalize_path_prefix()
    else
      ""
    end
  end

  defp normalize_path_prefix(""), do: ""
  defp normalize_path_prefix("/"), do: ""
  defp normalize_path_prefix(prefix), do: String.trim_trailing(prefix, "/")

  defp prefixed_path("", path), do: path
  defp prefixed_path(prefix, path), do: prefix <> path

  if Mix.env() == :test do
    @doc false
    @spec __test_work_request_route(URI.t(), atom(), map(), String.t()) :: String.t()
    def __test_work_request_route(uri, action, params, work_request_id) do
      uri
      |> path_prefix(action, params)
      |> prefixed_path("/sympp/work-requests/#{path_segment(work_request_id)}")
    end
  end

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
      count + value(request, :open_question_count, 0) +
        value(request, :answered_question_count, 0) +
        value(request, :closed_question_count, 0)
    end)
  end

  defp total_decisions(requests),
    do: Enum.reduce(requests, 0, &(&2 + value(&1, :decision_count, 0)))

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

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value(_map, _key, default), do: default
end
