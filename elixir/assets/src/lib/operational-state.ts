import type { SignalTone, StateCardTone } from "@/components/dashboard/state-card-style";
import { statusLabel } from "@/lib/status-labels";
import type { PackageOperationalAttention, PlannedSlice, WorkPackageCard, WorkRequestCard } from "@/types/dashboard";

export type BadgeTone = "default" | "secondary" | "outline" | "success" | "warning" | "danger" | "info" | "ready";
export type BoardLane = "slices" | "implementing" | "finished";
type RequestLane = "requested" | "slices" | "finished";

const CARD_TONES: Record<string, StateCardTone> = {
  active: "implementing",
  abandoned: "muted",
  blocked: "blocked",
  ci_waiting: "review",
  claimed: "queued",
  closed: "finished",
  completed: "finished",
  completed_no_pr: "muted",
  created: "queued",
  delivered: "finished",
  dispatched: "slice",
  implementing: "implementing",
  in_progress: "implementing",
  merge_ready: "merge",
  merged: "finished",
  merged_into_phase: "finished",
  merging: "merge",
  merging_into_phase: "merge",
  needs_attention: "queued",
  needs_closeout: "merge",
  planned: "slice",
  planning: "queued",
  ready_for_architect_merge: "merge",
  ready_for_human_merge: "merge",
  ready_for_worker: "queued",
  reviewing: "review",
  skipped: "muted",
  started_paused: "queued",
  superseded: "muted",
};

const BADGE_TONES: Record<string, BadgeTone> = {
  active: "info",
  abandoned: "secondary",
  answered: "success",
  approved: "info",
  blocked: "danger",
  ci_waiting: "info",
  claimed: "info",
  closed: "success",
  completed: "success",
  completed_no_pr: "secondary",
  created: "info",
  delivered: "success",
  human_info_needed: "danger",
  implementing: "info",
  in_progress: "info",
  merge_ready: "ready",
  merged: "success",
  merged_into_phase: "success",
  merging: "ready",
  merging_into_phase: "ready",
  needs_attention: "danger",
  needs_closeout: "warning",
  planning: "info",
  ready_for_architect_merge: "ready",
  ready_for_human_merge: "ready",
  ready_for_slicing: "info",
  ready_for_worker: "info",
  reviewing: "info",
  skipped: "secondary",
  started_paused: "info",
  superseded: "secondary",
};

const BOARD_LANES: Record<string, BoardLane> = {
  active: "implementing",
  abandoned: "finished",
  blocked: "implementing",
  ci_waiting: "implementing",
  claimed: "implementing",
  closed: "finished",
  completed: "finished",
  completed_no_pr: "finished",
  created: "implementing",
  delivered: "finished",
  implementing: "implementing",
  in_progress: "implementing",
  merge_ready: "implementing",
  merged: "finished",
  merged_into_phase: "finished",
  merging: "implementing",
  merging_into_phase: "implementing",
  needs_attention: "implementing",
  needs_closeout: "implementing",
  planning: "implementing",
  ready_for_architect_merge: "implementing",
  ready_for_human_merge: "implementing",
  ready_for_worker: "implementing",
  reviewing: "implementing",
  skipped: "finished",
  started_paused: "implementing",
  superseded: "finished",
};

const REQUEST_LANES: Record<string, RequestLane> = {
  active: "slices",
  abandoned: "finished",
  blocked: "slices",
  ci_waiting: "slices",
  claimed: "slices",
  closed: "finished",
  completed: "finished",
  completed_no_pr: "finished",
  delivered: "finished",
  implementing: "slices",
  in_progress: "slices",
  merge_ready: "slices",
  merged: "finished",
  merged_into_phase: "finished",
  merging: "slices",
  merging_into_phase: "slices",
  needs_attention: "slices",
  needs_closeout: "slices",
  planned: "slices",
  planning: "slices",
  ready_for_architect_merge: "slices",
  ready_for_human_merge: "slices",
  ready_for_slicing: "slices",
  ready_for_worker: "slices",
  reviewing: "slices",
  skipped: "finished",
  sliced: "slices",
  started_paused: "slices",
  superseded: "finished",
};

export function architectHandoffEligibleRequest(request: WorkRequestCard) {
  const status = request.status || "";
  return Boolean(
    request.id &&
      request.repo &&
      request.base_branch &&
      ["ready_for_clarification", "clarifying", "human_info_needed", "ready_for_slicing", "sliced"].includes(status),
  );
}

export function sliceCardTone(slice: PlannedSlice, pkg: WorkPackageCard | undefined, lane: BoardLane): StateCardTone {
  const operational = sliceOperationalState(slice, pkg);
  const tone = operationalCardTone(operational, slice.status);
  if (tone) return tone;

  if (pkg) return packageCardTone(pkg, lane);
  if (lane === "finished") return "finished";

  switch (slice.status) {
    case "approved":
      return "queued";
    case "planned":
      return "slice";
    case "skipped":
      return "muted";
    default:
      return "slice";
  }
}

function packageCardTone(pkg: WorkPackageCard, lane?: BoardLane): StateCardTone {
  const status = pkg.status || "";
  if ((pkg.active_blocker_count || 0) > 0 || status === "blocked") return "blocked";

  const operational = pkg.operational_state || null;
  const tone = operationalCardTone(operational, pkg.status);
  if (tone) return tone;

  return lane === "implementing" ? "implementing" : "slice";
}

function operationalCardTone(operational?: WorkPackageCard["operational_state"], fallbackStatus?: string | null): StateCardTone | null {
  const key = operational?.key || fallbackStatus || "";
  return CARD_TONES[key] || null;
}

export function sliceOperationalState(slice: PlannedSlice, pkg?: WorkPackageCard): WorkPackageCard["operational_state"] {
  return slice.operational_state || pkg?.operational_state || null;
}

export function operationalLabel(operational?: WorkPackageCard["operational_state"], fallbackStatus?: string | null) {
  return operational?.label || statusLabel(fallbackStatus);
}

function signalToneForBackendTone(tone?: string | null): SignalTone {
  switch (tone) {
    case "critical":
      return "danger";
    case "warning":
      return "warning";
    case "success":
      return "success";
    case "info":
      return "info";
    default:
      return "muted";
  }
}

export function operationalBadgeVariant(operational?: WorkPackageCard["operational_state"], fallbackStatus?: string | null): BadgeTone {
  if (!operational) return statusVariant(fallbackStatus);
  const key = operational.key || "";

  if (operational.tone === "critical") return "danger";
  if (key === "completed_no_pr" || key === "superseded") return "secondary";
  if (key === "needs_closeout") return "warning";
  if (key === "merge_ready") return operational.tone === "warning" ? "warning" : "ready";
  if (key === "blocked") return "danger";
  if (["merged", "merged_into_phase", "closed", "completed"].includes(key) || operational.tone === "success") return "success";
  if (["abandoned", "skipped"].includes(key)) return "secondary";
  if (operational.tone === "warning") return "warning";
  if (operational.tone === "info") return "info";
  return statusVariant(key || operational.raw_status || fallbackStatus);
}

export function attentionTone(attention?: PackageOperationalAttention | null): SignalTone {
  return signalToneForBackendTone(attention?.tone);
}

function statusVariant(status?: string | null): BadgeTone {
  return BADGE_TONES[status || ""] || "secondary";
}

export function isFinishedBoardStatus(status?: string | null) {
  return BOARD_LANES[status || ""] === "finished";
}

function boardLaneForStatus(status?: string | null): BoardLane {
  return BOARD_LANES[status || ""] || "slices";
}

export function packageLane(pkg: WorkPackageCard): BoardLane {
  return boardLaneForStatus(pkg.operational_state?.key || pkg.status);
}

export function sliceLane(slice: PlannedSlice, pkg?: WorkPackageCard): BoardLane {
  return boardLaneForStatus(sliceOperationalState(slice, pkg)?.key || slice.work_package_status || slice.status);
}

export function workRequestLane(request: WorkRequestCard): RequestLane {
  return REQUEST_LANES[request.operational_state?.key || request.status || ""] || "requested";
}
