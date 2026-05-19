export type WorkPackageCard = {
  id: string;
  title?: string | null;
  kind?: string | null;
  status?: string | null;
  repo?: string | null;
  base_branch?: string | null;
  parent_id?: string | null;
  phase_id?: string | null;
  active_blocker_count?: number;
  artifact_count?: number;
  finding_count?: number;
  latest_progress_at?: string | null;
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
  answer?: string | null;
};

export type PlannedSlice = {
  id: string;
  work_request_id: string;
  title?: string | null;
  goal?: string | null;
  status?: string | null;
  work_package_id?: string | null;
  work_package_status?: string | null;
  work_package_kind?: string | null;
};

export type WorkRequestDetail = {
  work_request: WorkRequestCard & {
    human_description?: string | null;
    constraints?: Record<string, unknown>;
  };
  clarification_questions?: ClarificationQuestion[];
  planned_slices?: PlannedSlice[];
  summary?: Record<string, unknown>;
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
  status?: string | null;
  last_activity_at?: string | null;
  latest_entry?: {
    title?: string | null;
    body?: string | null;
    kind_label?: string | null;
  } | null;
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
