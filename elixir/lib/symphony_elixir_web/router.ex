defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    get("/", ReactDashboardController, :index)
    get("/sympp", ReactDashboardController, :index)
    get("/sympp/*path", ReactDashboardController, :index)

    post("/sympp/board/session", SymppDashboardApiController, :board_session)
    post("/sympp/work-packages/:work_package_id/session", SymppDashboardApiController, :package_session)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/sympp/operator/dashboard", SymppDashboardApiController, :operator_dashboard)
    get("/api/v1/sympp/operator/work-packages/:work_package_id", SymppDashboardApiController, :operator_package_detail)
    get("/api/v1/sympp/operator/solo-sessions/:solo_session_id", SymppDashboardApiController, :operator_solo_session_detail)
    post("/api/v1/sympp/operator/work-requests", SymppDashboardApiController, :operator_create_work_request)

    post(
      "/api/v1/sympp/operator/work-requests/:work_request_id/questions/:question_id/answer",
      SymppDashboardApiController,
      :operator_answer_question
    )

    post(
      "/api/v1/sympp/operator/work-packages/:work_package_id/guidance/:guidance_request_id/answer",
      SymppDashboardApiController,
      :operator_answer_guidance
    )

    post(
      "/api/v1/sympp/operator/work-requests/:work_request_id/architect-handoff",
      SymppDashboardApiController,
      :operator_create_architect_handoff
    )

    post(
      "/api/v1/sympp/operator/work-requests/:work_request_id/planned-slices/:planned_slice_id/dispatch",
      SymppDashboardApiController,
      :operator_dispatch_planned_slice
    )

    get("/api/v1/sympp/board", SymppDashboardApiController, :board)
    get("/api/v1/sympp/work-requests", SymppDashboardApiController, :work_requests)
    get("/api/v1/sympp/work-requests/:work_request_id", SymppDashboardApiController, :work_request_detail)
    get("/api/v1/sympp/work-packages/:work_package_id", SymppDashboardApiController, :detail)
    get("/api/v1/sympp/work-packages/:work_package_id/timeline", SymppDashboardApiController, :timeline)
    get("/api/v1/sympp/work-packages/:work_package_id/artifacts", SymppDashboardApiController, :artifacts)
    get("/api/v1/sympp/work-packages/:work_package_id/blockers", SymppDashboardApiController, :blockers)
    get("/api/v1/sympp/work-packages/:work_package_id/grants", SymppDashboardApiController, :grants)
    get("/api/v1/sympp/work-packages/:work_package_id/agent-runs", SymppDashboardApiController, :agent_runs)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/board", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/dashboard", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-packages/:work_package_id", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/solo-sessions/:solo_session_id", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/operator/work-requests", ObservabilityApiController, :method_not_allowed)

    match(:*, "/api/v1/sympp/work-requests", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/sympp/work-requests/:work_request_id", ObservabilityApiController, :method_not_allowed)
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
end
