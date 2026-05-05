defmodule SymphonyElixirWeb.SymppBoardLive do
  @moduledoc """
  Read-only Symphony++ work package board.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.SymppDashboardApiController

  @empty_filter "all"

  @impl true
  def mount(params, session, socket) do
    board_grant_id = Map.get(session, "sympp_board_grant_id")
    authorized? = board_grant_authorized?(board_grant_id)

    {:ok,
     socket
     |> assign(:board_grant_id, board_grant_id)
     |> assign(:authorized?, authorized?)
     |> assign(:empty_filter, @empty_filter)
     |> assign(:filters, filters(params))
     |> assign_new(:board, fn -> unauthorized_board(authorized?) end)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :filters, filters(params))

    if board_grant_authorized?(socket.assigns.board_grant_id) do
      {:noreply, socket |> assign(:authorized?, true) |> assign_board()}
    else
      {:noreply,
       socket
       |> assign(:authorized?, false)
       |> assign(:board, unauthorized_board(false))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="sympp-board-shell">
      <header class="sympp-board-header">
        <div>
          <p class="eyebrow">Symphony++</p>
          <h1 class="sympp-board-title">Work package board</h1>
        </div>

        <div class="sympp-board-summary">
          <span class="sympp-board-count numeric"><%= @board.total_count %></span>
          <span class="muted">packages</span>
        </div>
      </header>

      <%= if @board.error do %>
        <section class="error-card">
          <h2 class="error-title">Board unavailable</h2>
          <p class="error-copy"><%= @board.error %></p>
        </section>
      <% else %>
        <form class="sympp-board-filters" method="get" action="/sympp/board">
          <label>
            <span>Kind</span>
            <select name="kind">
              <option value={@empty_filter} selected={@filters.kind == @empty_filter}>All</option>
              <option :for={kind <- @board.filter_options.kinds} value={kind} selected={@filters.kind == kind}>
                <%= kind %>
              </option>
            </select>
          </label>

          <label>
            <span>Repo</span>
            <select name="repo">
              <option value={@empty_filter} selected={@filters.repo == @empty_filter}>All</option>
              <option :for={repo <- @board.filter_options.repos} value={repo} selected={@filters.repo == repo}>
                <%= repo %>
              </option>
            </select>
          </label>

          <label>
            <span>Phase</span>
            <select name="phase">
              <option value={@empty_filter} selected={@filters.phase == @empty_filter}>All</option>
              <option :for={phase <- @board.filter_options.phases} value={phase} selected={@filters.phase == phase}>
                <%= phase %>
              </option>
            </select>
          </label>

          <button class="subtle-button" type="submit">Apply</button>
          <a class="sympp-clear-link" href="/sympp/board">Clear</a>
        </form>

        <%= if @board.visible_count == 0 do %>
          <p class="sympp-empty-state">No work packages match the current board filters.</p>
        <% else %>
          <div class="sympp-board-columns" style={"--sympp-column-count: #{@board.column_count};"}>
            <section :for={column <- @board.columns} class="sympp-board-column">
              <header class="sympp-column-header">
                <h2><%= status_label(column.status) %></h2>
                <span class="numeric"><%= length(column.cards) %></span>
              </header>

              <div class="sympp-card-list">
                <article :for={card <- column.cards} class={card_class(card)}>
                  <header class="sympp-card-header">
                    <span class="sympp-card-id"><%= card.id %></span>
                    <span class="state-badge"><%= card.kind || "unknown" %></span>
                  </header>

                  <h3 class="sympp-card-title"><%= card.title || "Untitled package" %></h3>

                  <dl class="sympp-card-meta">
                    <div>
                      <dt>Repo</dt>
                      <dd><%= repo_base(card) %></dd>
                    </div>
                    <div>
                      <dt>Updated</dt>
                      <dd class="numeric"><%= relative_time(card.latest_progress_at || card.updated_at) %></dd>
                    </div>
                    <div>
                      <dt>Blockers</dt>
                      <dd class="numeric"><%= card.active_blocker_count || 0 %></dd>
                    </div>
                  </dl>

                  <div class="sympp-readiness-row">
                    <span class={readiness_class(card, :plan)}>
                      Plan <%= plan_progress(card) %>
                    </span>
                    <span class={readiness_class(card, :review)}>
                      Review <%= review_state(card) %>
                    </span>
                  </div>

                  <footer class="sympp-card-footer">
                    <a :if={pr_url(card)} href={pr_url(card)} target="_blank" rel="noopener noreferrer">PR</a>
                    <span :if={active_agent_run?(card)} class="sympp-live-pill">active run</span>
                  </footer>
                </article>
              </div>
            </section>
          </div>
        <% end %>
      <% end %>
    </section>
    """
  end

  defp assign_board(socket) do
    assign(socket, :board, load_board(socket.assigns.filters))
  end

  defp board_grant_authorized?(grant_id) do
    match?({:ok, _grant}, SymppDashboardApiController.authorize_board_grant_id(grant_id))
  end

  defp load_board(filters) do
    case with_dashboard_repo(&Dashboard.board/1) do
      {:ok, payload} -> board_view(payload, filters)
      {:error, reason} -> empty_board(error_message(reason))
    end
  end

  defp with_dashboard_repo(fun) when is_function(fun, 1) do
    case configured_dashboard_repo() do
      repo when is_atom(repo) and repo != Repo ->
        with_custom_dashboard_repo(repo, fun)

      _repo ->
        with_default_dashboard_repo(fun)
    end
  end

  defp configured_dashboard_repo do
    :symphony_elixir
    |> Application.get_env(Endpoint, [])
    |> Keyword.get(:sympp_repo)
    |> Kernel.||(Endpoint.config(:sympp_repo))
  end

  defp with_custom_dashboard_repo(repo, fun) do
    case custom_repo_database_path(repo) do
      database_path when is_binary(database_path) -> with_custom_dashboard_repo(repo, database_path, fun)
      _missing -> {:error, :not_found}
    end
  end

  defp with_custom_dashboard_repo(repo, database_path, fun) do
    case Process.whereis(repo) do
      pid when is_pid(pid) ->
        if custom_repo_uses_database?(repo, database_path) do
          fun.(repo)
        else
          {:error, {:repo_database_mismatch, repo}}
        end

      nil ->
        start_custom_dashboard_repo(database_path, repo, fun)
    end
  end

  defp custom_repo_database_path(repo) do
    repo.config()
    |> Keyword.get(:database)
    |> Kernel.||(Repo.database_path())
    |> existing_database_path()
  rescue
    _error -> nil
  end

  defp custom_repo_uses_database?(repo, database_path) do
    case repo.query("PRAGMA database_list", []) do
      {:ok, %{rows: rows}} -> Enum.any?(rows, &main_database_row?(&1, database_path))
      {:error, _reason} -> false
    end
  rescue
    _error in Exqlite.Error -> false
  end

  defp start_custom_dashboard_repo(nil, _repo, _fun), do: {:error, :not_found}

  defp start_custom_dashboard_repo(database_path, repo, fun) do
    case repo.start_link(database: database_path, name: nil) do
      {:ok, pid} -> call_owned_custom_repo(unlink_transient_repo(pid), repo, fun)
      {:error, {:already_started, pid}} -> call_existing_custom_repo(pid, repo, database_path, fun)
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp call_existing_custom_repo(pid, repo, database_path, fun) do
    if custom_repo_uses_database?(pid, repo, database_path) do
      call_dynamic_custom_repo(pid, repo, fun)
    else
      {:error, {:repo_database_mismatch, repo}}
    end
  end

  defp call_owned_custom_repo(pid, repo, fun) do
    call_dynamic_custom_repo(pid, repo, fun)
  after
    stop_transient_repo(pid)
  end

  defp custom_repo_uses_database?(pid, repo, database_path) do
    call_dynamic_custom_repo(pid, repo, fn dynamic_repo ->
      custom_repo_uses_database?(dynamic_repo, database_path)
    end)
  end

  defp call_dynamic_custom_repo(pid, repo, fun) do
    original_repo = repo.put_dynamic_repo(pid)

    try do
      fun.(repo)
    after
      repo.put_dynamic_repo(original_repo)
    end
  end

  defp with_default_dashboard_repo(fun) do
    case Repo.database_path_if_present() do
      database_path when is_binary(database_path) ->
        read_existing_dashboard_repo(database_path, fun)

      _missing ->
        {:error, :not_found}
    end
  end

  defp existing_database_path(nil), do: nil
  defp existing_database_path(database_path) when not is_binary(database_path), do: nil

  defp existing_database_path(database_path) do
    cond do
      Repo.memory_database?(database_path) ->
        database_path

      Repo.filesystem_database_path?(database_path) ->
        database_path = Path.expand(database_path)
        if File.exists?(database_path), do: database_path

      true ->
        existing_sqlite_uri_path(database_path)
    end
  end

  defp existing_sqlite_uri_path("file:" <> _uri = database_path) do
    case Repo.sqlite_file_uri_path(database_path) do
      path when is_binary(path) and path != "" -> if(File.exists?(path), do: database_path)
      _missing -> nil
    end
  end

  defp existing_sqlite_uri_path(database_path), do: database_path

  defp read_existing_dashboard_repo(database_path, fun) do
    case default_repo_pid(database_path) do
      pid when is_pid(pid) -> call_dynamic_repo(pid, fun)
      :undefined -> start_transient_repo(database_path, fun)
    end
  end

  defp default_repo_pid(database_path) do
    case :global.whereis_name(Repo.process_key(database_path)) do
      pid when is_pid(pid) -> pid
      :undefined -> named_repo_pid(database_path)
    end
  end

  defp named_repo_pid(database_path) do
    case Process.whereis(Repo) do
      pid when is_pid(pid) -> if(repo_uses_database?(pid, database_path), do: pid, else: :undefined)
      nil -> :undefined
    end
  end

  defp repo_uses_database?(pid, database_path) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      case Repo.query("PRAGMA database_list", []) do
        {:ok, %{rows: rows}} -> Enum.any?(rows, &main_database_row?(&1, database_path))
        {:error, _reason} -> false
      end
    rescue
      _error in Exqlite.Error -> false
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp main_database_row?([_seq, "main", path], database_path) when is_binary(path) and is_binary(database_path) do
    cond do
      path == "" -> Repo.memory_database?(database_path)
      Repo.filesystem_database_path?(database_path) -> Repo.same_database_path?(path, database_path)
      true -> sqlite_database_uri_matches_path?(database_path, path)
    end
  end

  defp main_database_row?(_row, _database_path), do: false

  defp sqlite_database_uri_matches_path?("file:" <> _uri = database_path, path) do
    case Repo.sqlite_file_uri_path(database_path) do
      uri_path when is_binary(uri_path) and uri_path != "" -> Repo.same_database_path?(uri_path, path)
      _missing -> false
    end
  end

  defp sqlite_database_uri_matches_path?(_database_path, _path), do: false

  defp start_transient_repo(database_path, fun) do
    options = Repo.child_options(database: database_path, name: nil)

    case Repo.start_link(options) do
      {:ok, pid} -> call_owned_repo(unlink_transient_repo(pid), fun)
      {:error, {:already_started, pid}} -> call_dynamic_repo(pid, fun)
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp call_owned_repo(pid, fun) do
    call_dynamic_repo(pid, fun)
  after
    stop_transient_repo(pid)
  end

  defp unlink_transient_repo(pid) do
    Process.unlink(pid)
    pid
  end

  defp call_dynamic_repo(pid, fun) do
    original_repo = Repo.put_dynamic_repo(pid)

    try do
      fun.(Repo)
    after
      Repo.put_dynamic_repo(original_repo)
    end
  end

  defp stop_transient_repo(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp board_view(payload, filters) do
    statuses = Map.get(payload, :statuses, [])
    groups = Map.get(payload, :groups, %{})
    all_cards = Enum.flat_map(statuses, &Map.get(groups, &1, []))

    filtered_groups =
      Map.new(statuses, fn status ->
        {status, groups |> Map.get(status, []) |> Enum.filter(&matches_filters?(&1, filters))}
      end)

    columns =
      statuses
      |> Enum.map(&%{status: &1, cards: Map.get(filtered_groups, &1, [])})
      |> Enum.reject(&(&1.cards == []))

    visible_count = filtered_groups |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

    %{
      error: nil,
      total_count: Map.get(payload, :total_count, length(all_cards)),
      visible_count: visible_count,
      column_count: max(length(columns), 1),
      columns: columns,
      filter_options: filter_options(all_cards)
    }
  end

  defp empty_board(error) do
    %{
      error: error,
      total_count: 0,
      visible_count: 0,
      column_count: 1,
      columns: [],
      filter_options: %{kinds: [], repos: [], phases: []}
    }
  end

  defp unauthorized_board(true), do: empty_board(nil)
  defp unauthorized_board(false), do: empty_board("Board access expired. Reload and enter a current board work key.")

  defp filters(params) when is_map(params) do
    %{
      kind: filter_value(params["kind"]),
      repo: filter_value(params["repo"]),
      phase: filter_value(params["phase"])
    }
  end

  defp filter_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: @empty_filter, else: value
  end

  defp filter_value(_value), do: @empty_filter

  defp matches_filters?(card, filters) do
    matches_filter?(card.kind, filters.kind) and
      matches_filter?(card.repo, filters.repo) and
      matches_filter?(phase(card), filters.phase)
  end

  defp matches_filter?(_value, @empty_filter), do: true
  defp matches_filter?(value, filter), do: value == filter

  defp filter_options(cards) do
    %{
      kinds: sorted_present_values(cards, & &1.kind),
      repos: sorted_present_values(cards, & &1.repo),
      phases: sorted_present_values(cards, &phase/1)
    }
  end

  defp sorted_present_values(cards, fun) do
    cards
    |> Enum.map(fun)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp phase(%{id: id}) when is_binary(id) do
    case Regex.run(~r/^SYMPP-(P\d+)-/, id) do
      [_, phase] -> phase
      _match -> nil
    end
  end

  defp phase(_card), do: nil

  defp status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_label(status), do: to_string(status)

  defp card_class(card) do
    base = "sympp-work-card"

    cond do
      (card.active_blocker_count || 0) > 0 -> "#{base} sympp-work-card-blocked"
      active_agent_run?(card) -> "#{base} sympp-work-card-active"
      true -> base
    end
  end

  defp repo_base(card) do
    [card.repo, card.base_branch]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" / ")
    |> case do
      "" -> "n/a"
      value -> value
    end
  end

  defp plan_progress(%{plan: %{total_count: total, completed_count: completed}})
       when is_integer(total) and is_integer(completed) and total > 0 do
    "#{completed}/#{total}"
  end

  defp plan_progress(_card), do: "n/a"

  defp readiness_class(card, :plan) do
    case card.plan do
      %{total_count: total, open_count: 0} when is_integer(total) and total > 0 -> "sympp-readiness sympp-readiness-ready"
      %{total_count: total} when is_integer(total) and total > 0 -> "sympp-readiness"
      _plan -> "sympp-readiness sympp-readiness-muted"
    end
  end

  defp readiness_class(card, :review) do
    if review_present?(card) do
      "sympp-readiness sympp-readiness-ready"
    else
      "sympp-readiness sympp-readiness-muted"
    end
  end

  defp review_state(card), do: if(review_present?(card), do: "attached", else: "none")

  defp review_present?(card), do: not is_nil(metadata_value(card, :review_package, "review_package"))

  defp pr_url(card) do
    case metadata_value(card, :pr, "pr") do
      %{} = pr -> Map.get(pr, "url") || Map.get(pr, :url)
      _missing -> nil
    end
    |> case do
      url when is_binary(url) and url != "[REDACTED]" -> url
      _url -> nil
    end
  end

  defp metadata_value(%{metadata: %{} = metadata}, atom_key, string_key) do
    Map.get(metadata, atom_key) || Map.get(metadata, string_key)
  end

  defp metadata_value(_card, _atom_key, _string_key), do: nil

  defp active_agent_run?(card), do: not is_nil(card.active_agent_run)

  defp relative_time(nil), do: "n/a"

  defp relative_time(%DateTime{} = datetime), do: relative_time(datetime, DateTime.utc_now())

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

  defp error_message(:not_found), do: "No Symphony++ work package ledger was found."
  defp error_message(:database_busy), do: "The Symphony++ ledger is busy. Refresh shortly."
  defp error_message({:repo_database_mismatch, _repo}), do: "The configured Symphony++ repo does not match the selected ledger."
  defp error_message({:storage_failed, _reason}), do: "The Symphony++ ledger could not be read."
  defp error_message(_reason), do: "The Symphony++ board could not be loaded."
end
