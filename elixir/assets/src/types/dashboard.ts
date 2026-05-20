export type PackagePlanSummary = {
  completed_count?: number;
  total_count?: number;
  open_count?: number;
};

export type PackageBranchMetadata = {
  branch?: string;
  head_sha?: string;
  type?: string;
  source_tool?: string;
};

export type PackagePrMetadata = {
  url?: string;
  number?: number | string;
  title?: string;
  state?: string;
  head_sha?: string;
};

export type PackageReviewMetadata = {
  lane?: string;
  review_lane?: string;
  suite?: string;
  profile?: string;
  mode?: string;
  provider?: string;
  verdict?: string;
  status?: string;
  step_current?: number | string;
  step_total?: number | string;
  step_name?: string | null;
  reviews?: PackageReviewMetadata[];
  head_sha?: string;
};

export type PackageAlertIndicator = {
  active?: boolean;
  label?: string;
  type?: string;
  severity?: string;
  detail?: string;
  missing?: string[];
  reasons?: Array<Record<string, unknown>>;
};

export type PackageMetadata = {
  branch?: PackageBranchMetadata | null;
  pr?: PackagePrMetadata | null;
  review_progress?: PackageReviewMetadata | null;
  review_package?: PackageReviewMetadata | null;
  review_suite_result?: PackageReviewMetadata | null;
};

export type ActiveAgentRun = {
  runtime_state?: string;
  stale?: boolean;
};

export type WorkPackageCard = {
  id: string;
  title?: string | null;
  kind?: string | null;
  status?: string | null;
  repo?: string | null;
  base_branch?: string | null;
  parent_id?: string | null;
  phase_id?: string | null;
  owner_id?: string | null;
  active_blocker_count?: number;
  artifact_count?: number;
  finding_count?: number;
  latest_progress_at?: string | null;
  inserted_at?: string | null;
  updated_at?: string | null;
  plan?: PackagePlanSummary | null;
  metadata?: PackageMetadata | null;
  alert_indicators?: PackageAlertIndicator[];
  active_agent_run?: ActiveAgentRun | null;
  runtime?: Record<string, unknown> | null;
};

export type WorkRequestCard = {
  id: string;
  title?: string | null;
  repo?: string | null;
  base_branch?: string | null;
  work_type?: string | null;
  desired_dispatch_shape?: string | null;
  status?: string | null;
  open_question_count?: number;
  answered_question_count?: number;
  planned_slice_count?: number;
  approved_slice_count?: number;
  dispatched_slice_count?: number;
  skipped_slice_count?: number;
  inserted_at?: string | null;
  updated_at?: string | null;
};

export type DecisionOption = {
  id: string;
  label: string;
  description?: string;
  pros?: string[];
  cons?: string[];
  answer?: string;
};

export type DecisionPrompt = {
  tl_dr?: string;
  details?: string;
  custom_redirect_label?: string;
  options?: DecisionOption[];
};

export type ClarificationQuestion = {
  id: string;
  work_request_id: string;
  sequence?: number;
  category?: string | null;
  question?: string | null;
  why_needed?: string | null;
  decision_prompt?: DecisionPrompt | null;
  status?: string | null;
  asked_by_agent_run_id?: string | null;
  answer?: string | null;
  answered_by?: string | null;
  answered_at?: string | null;
  inserted_at?: string | null;
  updated_at?: string | null;
};

export type PlannedSlice = {
  id: string;
  work_request_id: string;
  sequence?: number;
  title?: string | null;
  goal?: string | null;
  status?: string | null;
  work_package_id?: string | null;
  work_package_status?: string | null;
  work_package_kind?: string | null;
  target_base_branch?: string | null;
  branch_pattern?: string | null;
  owned_file_globs?: string[];
  forbidden_file_globs?: string[];
  acceptance_criteria?: string[];
  validation_steps?: string[];
  dispatched_at?: string | null;
  review_lanes?: string[];
  stop_conditions?: string[];
  inserted_at?: string | null;
  updated_at?: string | null;
};

export type DecisionLogEntry = {
  id: string;
  work_request_id: string;
  sequence?: number;
  source_type?: string | null;
  source_id?: string | null;
  decision?: string | null;
  rationale?: string | null;
  scope_impact?: string | null;
  created_by?: string | null;
  created_at?: string | null;
  inserted_at?: string | null;
  updated_at?: string | null;
};

export type WorkRequestDetail = {
  work_request: WorkRequestCard & {
    human_description?: string | null;
    constraints?: Record<string, unknown>;
  };
  clarification_questions?: ClarificationQuestion[];
  decision_logs?: DecisionLogEntry[];
  planned_slices?: PlannedSlice[];
  summary?: {
    open_question_count?: number;
    answered_question_count?: number;
    closed_question_count?: number;
    decision_count?: number;
    planned_slice_count?: number;
    approved_slice_count?: number;
    dispatched_slice_count?: number;
    skipped_slice_count?: number;
  };
};

export type GuidanceRequest = {
  id: string;
  work_package_id: string;
  work_package_title?: string | null;
  package_kind?: string | null;
  repo?: string | null;
  base_branch?: string | null;
  summary?: string | null;
  question?: string | null;
  context?: string | null;
  human_info_reason?: string | null;
  recommended_language?: string | null;
  decision_prompt?: DecisionPrompt | null;
  status?: string | null;
  blocker_id?: string | null;
};

export type SoloSession = {
  id: string;
  title?: string | null;
  repo?: string | null;
  base_branch?: string | null;
  caller_id?: string | null;
  status?: string | null;
  last_activity_at?: string | null;
  inserted_at?: string | null;
  updated_at?: string | null;
  entry_counts?: Array<{
    kind?: string | null;
    label?: string | null;
    count?: number | null;
  }>;
  latest_entry?: {
    kind?: string | null;
    status?: string | null;
    title?: string | null;
    body?: string | null;
    kind_label?: string | null;
    created_at?: string | null;
  } | null;
};

export type SoloSessionEntry = {
  id?: string | null;
  sequence?: number | null;
  kind?: string | null;
  kind_label?: string | null;
  status?: string | null;
  status_label?: string | null;
  title?: string | null;
  body?: string | null;
  created_at?: string | null;
  updated_at?: string | null;
};

export type SoloSessionDetailPayload = {
  solo_session?: SoloSession & {
    workspace_path?: string | null;
    archived_at?: string | null;
  };
  entries?: SoloSessionEntry[];
  entry_count?: number;
};

export type WorkPackageDetailPayload = {
  work_package?: WorkPackageCard & {
    branch_pattern?: string | null;
    product_description?: string | null;
    engineering_scope?: string | null;
    allowed_file_globs?: string[];
    policy_template?: string | null;
    acceptance_criteria?: string[];
  };
  summary?: {
    artifact_count?: number;
    finding_count?: number;
    progress_event_count?: number;
    active_blocker_count?: number;
    guidance_request_count?: number;
    active_agent_run_count?: number;
    queued_agent_run_count?: number;
    failed_agent_run_count?: number;
    stale_agent_run_count?: number;
    runtime?: Record<string, unknown> | null;
    latest_progress_at?: string | null;
    plan?: PackagePlanSummary | null;
  };
  plan?: Array<{
    id?: string;
    title?: string | null;
    body?: string | null;
    status?: string | null;
    position?: number | null;
    created_at?: string | null;
    updated_at?: string | null;
  }>;
  findings?: Array<{
    id?: string;
    title?: string | null;
    body?: string | null;
    severity?: string | null;
    sequence?: number | null;
    created_at?: string | null;
  }>;
  progress?: Array<{
    id?: string;
    summary?: string | null;
    body?: string | null;
    status?: string | null;
    sequence?: number | null;
    created_at?: string | null;
  }>;
  artifacts?: Array<{
    id?: string;
    path?: string | null;
    title?: string | null;
    kind?: string | null;
    uri?: string | null;
    sequence?: number | null;
    created_at?: string | null;
  }>;
  blockers?: Array<{
    id?: string;
    active?: boolean;
    summary?: string | null;
    body?: string | null;
    status?: string | null;
    resolution?: string | null;
    updated_at?: string | null;
  }>;
  guidance_requests?: GuidanceRequest[];
  agent_runs?: Array<ActiveAgentRun & {
    id?: string;
    status?: string | null;
    actor_id?: string | null;
    attempt?: number | null;
    started_at?: string | null;
    last_seen_at?: string | null;
    finished_at?: string | null;
    reason?: string | null;
  }>;
  metadata?: PackageMetadata | null;
  alert_indicators?: PackageAlertIndicator[];
};

export type DashboardPayload = {
  generated_at?: string;
  board?: {
    groups?: Record<string, WorkPackageCard[]>;
    total_count?: number;
  };
  work_requests?: {
    work_requests?: WorkRequestCard[];
    total_count?: number;
  };
  work_request_details?: WorkRequestDetail[];
  guidance_requests?: {
    guidance_requests?: GuidanceRequest[];
    total_count?: number;
  };
  solo_sessions?: {
    solo_sessions?: SoloSession[];
    total_count?: number;
  };
};
