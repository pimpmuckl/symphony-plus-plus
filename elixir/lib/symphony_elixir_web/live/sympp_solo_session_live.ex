defmodule SymphonyElixirWeb.SymppSoloSessionLive do
  @moduledoc """
  Read-only local-operator Solo Session detail view.
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
    operator_mode? = effective_operator_mode?(local_operator_mode?(session, socket), authorization)
    solo_session_id = Map.get(params, "solo_session_id")

    connected? = connected?(socket)

    {:ok,
     socket
     |> assign(:board_grant_id, board_grant_id)
     |> assign(:board_grant, authorized_grant(authorization))
     |> assign(:operator_mode?, operator_mode?)
     |> assign(:solo_session_id, solo_session_id)
     |> assign(:page, initial_page(operator_mode?, authorization, solo_session_id, connected?))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    solo_session_id = Map.get(params, "solo_session_id", socket.assigns.solo_session_id)

    {:noreply,
     socket
     |> assign(:solo_session_id, solo_session_id)
     |> assign(:page, handle_params_page(socket, solo_session_id))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="sympp-detail-shell sympp-solo-detail-shell">
      <header class="sympp-detail-header">
        <div>
          <p class="eyebrow">Symphony++ Solo Session</p>
          <h1 class="sympp-detail-title"><%= page_title(@page) %></h1>
        </div>
        <div class="sympp-detail-header-actions">
          <a class="sympp-back-link" href="../board">Back to cockpit</a>
        </div>
      </header>

      <%= if @page.error do %>
        <section class="error-card">
          <h2 class="error-title">Solo Session unavailable</h2>
          <p class="error-copy"><%= @page.error %></p>
        </section>
      <% else %>
        <section class="sympp-detail-overview sympp-solo-detail-overview">
          <div class="sympp-detail-main">
            <div class="sympp-detail-signal-row">
              <span class="sympp-card-id"><%= @page.solo_session.id %></span>
              <span class="state-badge"><%= status_label(@page.solo_session.status) %></span>
              <span class="sympp-readiness sympp-readiness-ready numeric"><%= @page.entry_count %> ledger entries</span>
            </div>
            <dl class="sympp-detail-meta sympp-solo-detail-meta">
              <div>
                <dt>Repo</dt>
                <dd><%= repo_base(@page.solo_session) %></dd>
              </div>
              <div>
                <dt>Workspace</dt>
                <dd><%= value_or_na(@page.solo_session.workspace_path) %></dd>
              </div>
              <div>
                <dt>Caller</dt>
                <dd><%= value_or_na(@page.solo_session.caller_id) %></dd>
              </div>
              <div>
                <dt>Last activity</dt>
                <dd class="numeric"><%= relative_time(@page.solo_session.last_activity_at) %></dd>
              </div>
              <div>
                <dt>Created</dt>
                <dd class="numeric"><%= value_or_na(@page.solo_session.inserted_at) %></dd>
              </div>
              <div>
                <dt>Updated</dt>
                <dd class="numeric"><%= value_or_na(@page.solo_session.updated_at) %></dd>
              </div>
              <div :if={@page.solo_session.archived_at}>
                <dt>Archived</dt>
                <dd class="numeric"><%= @page.solo_session.archived_at %></dd>
              </div>
            </dl>
          </div>
        </section>

        <section class="sympp-panel sympp-solo-ledger-panel" aria-label="Solo Session ledger">
          <h2>Ledger</h2>
          <ol :if={@page.entries != []} class="sympp-solo-ledger">
            <li :for={entry <- @page.entries} class="sympp-solo-ledger-entry">
              <div class="sympp-solo-ledger-index numeric"><%= entry.sequence %></div>
              <article>
                <header>
                  <div>
                    <span class="state-badge"><%= entry.kind_label %></span>
                    <span class="sympp-readiness"><%= entry.status_label %></span>
                  </div>
                  <time class="numeric"><%= value_or_na(entry.created_at) %></time>
                </header>
                <h3><%= entry.title || "Untitled entry" %></h3>
                <p :if={entry.body} class="sympp-solo-ledger-body"><%= entry.body %></p>
              </article>
            </li>
          </ol>
          <p :if={@page.entries == []} class="sympp-empty-inline">No ledger entries are recorded for this Solo Session.</p>
        </section>
      <% end %>
    </section>
    """
  end

  defp initial_page(true, _authorization, solo_session_id, _connected?), do: load_page(true, solo_session_id)
  defp initial_page(false, _authorization, _solo_session_id, false), do: unavailable_page(:verifying_local_operator)
  defp initial_page(false, {:ok, %AccessGrant{}}, _solo_session_id, true), do: unavailable_page(:forbidden)
  defp initial_page(false, {:error, reason}, _solo_session_id, true), do: unavailable_page(reason)

  defp handle_params_page(socket, solo_session_id) do
    if connected?(socket) do
      load_page(socket.assigns.operator_mode?, solo_session_id)
    else
      socket.assigns.page
    end
  end

  defp load_page(true, solo_session_id) when is_binary(solo_session_id) and solo_session_id != "" do
    case SymppBoardLive.with_dashboard_repo(&Dashboard.solo_session_detail(&1, solo_session_id)) do
      {:ok, page} -> Map.put(page, :error, nil)
      {:error, reason} -> unavailable_page(reason)
    end
  end

  defp load_page(true, _solo_session_id), do: unavailable_page(:not_found)
  defp load_page(false, _solo_session_id), do: unavailable_page(:forbidden)

  defp unavailable_page(reason), do: %{error: error_message(reason), solo_session: nil, entries: [], entry_count: 0}

  defp local_operator_mode?(session, socket) do
    SymppDashboardApiController.local_operator_session?(session) and
      if connected?(socket) do
        SymppDashboardApiController.local_operator_live_connect_info?(%{
          peer_data: get_connect_info(socket, :peer_data),
          uri: get_connect_info(socket, :uri),
          x_headers: get_connect_info(socket, :x_headers)
        })
      else
        false
      end
  end

  defp effective_operator_mode?(true, {:ok, %AccessGrant{}}), do: false
  defp effective_operator_mode?(operator_mode?, _authorization), do: operator_mode?

  defp board_grant_authorization(grant_id) do
    case SymppDashboardApiController.authorize_board_grant_id(grant_id) do
      {:ok, grant} -> {:ok, grant}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorized_grant({:ok, grant}), do: grant
  defp authorized_grant(_authorization), do: nil

  defp page_title(%{solo_session: %{title: title}}) when is_binary(title), do: title
  defp page_title(_page), do: "Solo Session"

  defp repo_base(item) do
    [Map.get(item, :repo), Map.get(item, :base_branch)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" / ")
    |> case do
      "" -> "n/a"
      value -> value
    end
  end

  defp status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_label(status), do: to_string(status)

  defp relative_time(nil), do: "n/a"

  defp relative_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> relative_time(datetime, DateTime.utc_now())
      _error -> timestamp
    end
  end

  defp relative_time(%DateTime{} = datetime, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, datetime, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp value_or_na(nil), do: "n/a"
  defp value_or_na(""), do: "n/a"
  defp value_or_na(value), do: value

  defp error_message(:forbidden), do: "Solo Session details are only available in local operator mode."
  defp error_message(:verifying_local_operator), do: "Verifying local operator access."
  defp error_message(:not_found), do: "No Solo Session was found for this route."
  defp error_message(:database_busy), do: "The Symphony++ ledger is busy. Refresh shortly."
  defp error_message({:repo_database_mismatch, _repo}), do: "The configured Symphony++ repo does not match the selected ledger."
  defp error_message({:storage_failed, _reason}), do: "The Symphony++ ledger could not be read."
  defp error_message(_reason), do: "The Solo Session detail could not be loaded."
end
