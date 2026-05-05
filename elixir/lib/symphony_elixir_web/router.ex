defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :sympp_board_auth do
    plug(:authorize_sympp_board)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    post("/sympp/board/session", SymppDashboardApiController, :board_session)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through([:browser, :sympp_board_auth])

    live("/sympp/board", SymppBoardLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/sympp/board", SymppDashboardApiController, :board)
    get("/api/v1/sympp/work-packages/:work_package_id", SymppDashboardApiController, :detail)
    get("/api/v1/sympp/work-packages/:work_package_id/timeline", SymppDashboardApiController, :timeline)
    get("/api/v1/sympp/work-packages/:work_package_id/artifacts", SymppDashboardApiController, :artifacts)
    get("/api/v1/sympp/work-packages/:work_package_id/blockers", SymppDashboardApiController, :blockers)
    get("/api/v1/sympp/work-packages/:work_package_id/grants", SymppDashboardApiController, :grants)
    get("/api/v1/sympp/work-packages/:work_package_id/agent-runs", SymppDashboardApiController, :agent_runs)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/board", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-packages/:work_package_id", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-packages/:work_package_id/timeline", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-packages/:work_package_id/artifacts", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-packages/:work_package_id/blockers", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-packages/:work_package_id/grants", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-packages/:work_package_id/agent-runs", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end

  defp authorize_sympp_board(conn, opts) do
    SymphonyElixirWeb.SymppDashboardApiController.authorize_board_browser(conn, opts)
  end
end
