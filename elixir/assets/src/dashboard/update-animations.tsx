import type { GuidanceItem, PlannedSlice, SoloSession, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import { UPDATE_ANIMATION_TTL_MS } from "@/components/dashboard/motion";
import type { UpdateMotion, UpdateMotionKind } from "@/components/dashboard/motion";
import { packageLane, sliceLane, sliceOperationalState, workRequestLane } from "@/lib/operational-state";
import { useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from "react";
import { BlockerItem, FinishedHighlight, updateMotionsReducer } from "./dashboard-state";
import { DashboardUpdateAnimations, MAX_UPDATE_MOTION_ENTRIES, TopPanelKey, UpdateAnimationEntity } from "./runtime";
import { soloSessionAttention, soloSessionLane, soloSessionUpdateKey } from "./solo-session-utils";

export function useDashboardUpdateAnimations({
  blockerItems,
  finishedHighlights,
  guidanceItems,
  packages,
  ready,
  requestDetails,
  soloSessions,
}: {
  blockerItems: BlockerItem[];
  finishedHighlights: FinishedHighlight[];
  guidanceItems: GuidanceItem[];
  packages: WorkPackageCard[];
  ready: boolean;
  requestDetails: WorkRequestDetail[];
  soloSessions: SoloSession[];
}): DashboardUpdateAnimations {
  const previousSnapshotRef = useRef<Map<string, UpdateAnimationEntity> | null>(null);
  const initialLatestSnapshot = useMemo(() => new Map<string, UpdateAnimationEntity>(), []);
  const latestSnapshotRef = useRef<Map<string, UpdateAnimationEntity>>(initialLatestSnapshot);
  const timersRef = useRef<number[]>([]);
  const tokenRef = useRef(0);
  const [motions, dispatchMotions] = useReducer(updateMotionsReducer, {});
  const [countPulses, setCountPulses] = useState<Record<TopPanelKey, number>>({ blockers: 0, finished: 0, guidance: 0 });

  const applyMotions = useCallback((nextMotions: Record<string, UpdateMotion>) => {
    const motionEntries = Object.entries(nextMotions).slice(0, MAX_UPDATE_MOTION_ENTRIES);
    if (motionEntries.length === 0) return;

    dispatchMotions({ type: "merge", motions: Object.fromEntries(motionEntries) });

    const timer = window.setTimeout(() => {
      dispatchMotions({ type: "settle", entries: motionEntries });
    }, UPDATE_ANIMATION_TTL_MS);

    timersRef.current.push(timer);
  }, []);

  useEffect(
    () => () => {
      timersRef.current.forEach((timer) => window.clearTimeout(timer));
      timersRef.current = [];
    },
    [],
  );

  useLayoutEffect(() => {
    if (!ready) {
      latestSnapshotRef.current = new Map();
      previousSnapshotRef.current = null;
      dispatchMotions({ type: "clear" });
      return;
    }

    const snapshot = dashboardAnimationSnapshot({ blockerItems, finishedHighlights, guidanceItems, packages, requestDetails, soloSessions });
    latestSnapshotRef.current = snapshot;
    const previousSnapshot = previousSnapshotRef.current;

    if (!previousSnapshot) {
      previousSnapshotRef.current = snapshot;
      return;
    }

    const nextMotions: Record<string, UpdateMotion> = {};
    snapshot.forEach((entity, key) => {
      const motionKind = classifyUpdateMotion(previousSnapshot.get(key), entity);
      if (!motionKind) return;

      nextMotions[key] = { kind: motionKind, token: (tokenRef.current += 1) };
    });

    previousSnapshotRef.current = snapshot;

    applyMotions(nextMotions);
  }, [applyMotions, blockerItems, finishedHighlights, guidanceItems, packages, ready, requestDetails, soloSessions]);

  const motionFor = useCallback((key?: string | null) => (ready && key ? motions[key] : undefined), [motions, ready]);
  const countPulseFor = useCallback((panel: TopPanelKey) => countPulses[panel] || 0, [countPulses]);
  const simulate = useCallback(
    (kind: UpdateMotionKind) => {
      const snapshot = latestSnapshotRef.current;
      const keys = simulatedMotionKeys(kind, snapshot);
      const nextMotions = Object.fromEntries(keys.map((key) => [key, { kind, token: (tokenRef.current += 1) } satisfies UpdateMotion]));

      applyMotions(nextMotions);

      const panel = topPanelForMotionKind(kind);
      if (panel) {
        setCountPulses((current) => ({ ...current, [panel]: (current[panel] || 0) + 1 }));
      }
    },
    [applyMotions],
  );

  return useMemo(() => ({ countPulseFor, motionFor, simulate }), [countPulseFor, motionFor, simulate]);
}

function dashboardAnimationSnapshot({
  blockerItems,
  finishedHighlights,
  guidanceItems,
  packages,
  requestDetails,
  soloSessions,
}: {
  blockerItems: BlockerItem[];
  finishedHighlights: FinishedHighlight[];
  guidanceItems: GuidanceItem[];
  packages: WorkPackageCard[];
  requestDetails: WorkRequestDetail[];
  soloSessions: SoloSession[];
}) {
  const snapshot = new Map<string, UpdateAnimationEntity>();
  const packageById = new Map(packages.map((pkg) => [pkg.id, pkg]));

  requestDetails.forEach((detail) => {
    snapshot.set(requestUpdateKey(detail), requestAnimationEntity(detail));

    (detail.planned_slices || []).forEach((slice) => {
      snapshot.set(sliceUpdateKey(slice), sliceAnimationEntity(slice, slice.work_package_id ? packageById.get(slice.work_package_id) : undefined));
    });
  });

  packages.forEach((pkg) => {
    snapshot.set(packageUpdateKey(pkg), packageAnimationEntity(pkg));
  });

  guidanceItems.forEach((item) => {
    snapshot.set(guidanceUpdateKey(item), guidanceAnimationEntity(item));
  });

  blockerItems.forEach((item) => {
    snapshot.set(blockerUpdateKey(item), blockerAnimationEntity(item));
  });

  finishedHighlights.forEach((item) => {
    snapshot.set(finishedHighlightUpdateKey(item), finishedHighlightAnimationEntity(item));
  });

  soloSessions.forEach((session) => {
    snapshot.set(soloSessionUpdateKey(session), soloSessionAnimationEntity(session));
  });

  return snapshot;
}

export function requestUpdateKey(detail: WorkRequestDetail) {
  return `request:${detail.work_request.id}`;
}

export function sliceUpdateKey(slice: PlannedSlice) {
  return `slice:${slice.id}`;
}

export function packageUpdateKey(pkg: WorkPackageCard) {
  return `package:${pkg.id}`;
}

export function guidanceUpdateKey(item: GuidanceItem) {
  return `guidance:${item.source}:${item.id}`;
}

export function blockerUpdateKey(item: BlockerItem) {
  return `blocker:${item.id}`;
}

export function finishedHighlightUpdateKey(item: FinishedHighlight) {
  return `finished:${item.kind}:${item.id}`;
}

export function finishedHighlightsListKey(items: FinishedHighlight[]) {
  return items.map(finishedHighlightUpdateKey).join("|");
}

function classifyUpdateMotion(previous: UpdateAnimationEntity | undefined, current: UpdateAnimationEntity): UpdateMotionKind | null {
  if (!previous) {
    if (current.finished) return "finished";
    if (current.blockerCount > 0 || isBlockedStatus(current.status)) return "blocker";
    if (current.guidanceCount > 0) return "guidance";
    return "added";
  }

  if (previous.signature === current.signature) return null;
  if (current.finished && !previous.finished) return "finished";
  if (current.blockerCount > previous.blockerCount || (!isBlockedStatus(previous.status) && isBlockedStatus(current.status))) return "blocker";
  if (current.guidanceCount > previous.guidanceCount) return "guidance";
  return "changed";
}

function simulatedMotionKeys(kind: UpdateMotionKind, snapshot: Map<string, UpdateAnimationEntity>) {
  const entries = [...snapshot.entries()];
  const preferred =
    kind === "guidance"
      ? entries.filter(([, entity]) => entity.guidanceCount > 0)
      : kind === "blocker"
        ? entries.filter(([, entity]) => entity.blockerCount > 0 || isBlockedStatus(entity.status))
        : kind === "finished"
          ? entries.filter(([, entity]) => entity.finished)
          : entries.filter(([key]) => key.startsWith("request:") || key.startsWith("slice:") || key.startsWith("package:") || key.startsWith("solo:"));

  return (preferred.length > 0 ? preferred : entries).slice(0, kind === "changed" ? 4 : 3).map(([key]) => key);
}

function topPanelForMotionKind(kind: UpdateMotionKind): TopPanelKey | null {
  if (kind === "guidance") return "guidance";
  if (kind === "blocker") return "blockers";
  if (kind === "finished") return "finished";
  return null;
}

function requestAnimationEntity(detail: WorkRequestDetail): UpdateAnimationEntity {
  const request = detail.work_request;
  const operational = request.operational_state || null;
  const openQuestions = detail.clarification_questions?.filter((question) => question.status === "open") ?? [];
  const guidanceCount = Math.max(openQuestions.length, request.open_question_count || 0, request.status === "human_info_needed" ? 1 : 0);

  return {
    signature: stableSignature([
      request.status,
      request.operational_state,
      request.updated_at,
      request.open_question_count,
      request.answered_question_count,
      request.planned_slice_count,
      request.approved_slice_count,
      request.dispatched_slice_count,
      request.skipped_slice_count,
      detail.summary,
      (detail.clarification_questions || []).map((question) => [
        question.id,
        question.status,
        question.answer,
        question.answered_at,
        question.updated_at,
      ]),
    ]),
    status: operational?.key || request.status,
    guidanceCount,
    blockerCount: 0,
    finished: workRequestLane(request) === "finished",
  };
}

function sliceAnimationEntity(slice: PlannedSlice, pkg?: WorkPackageCard): UpdateAnimationEntity {
  const operational = sliceOperationalState(slice, pkg);
  const status = operational?.key || slice.work_package_status || slice.status;
  const blockerCount = pkg?.active_blocker_count || (pkg?.status === "blocked" || operational?.key === "blocked" ? 1 : 0);

  return {
    signature: stableSignature([
      slice.status,
      slice.work_package_id,
      slice.work_package_status,
      slice.operational_state,
      slice.updated_at,
      slice.dispatched_at,
      pkg?.status,
      pkg?.operational_state,
      pkg?.lineage,
      pkg?.active_blocker_count,
      pkg?.latest_progress_at,
      pkg?.updated_at,
      pkg?.plan,
    ]),
    status,
    guidanceCount: 0,
    blockerCount,
    finished: sliceLane(slice, pkg) === "finished" || Boolean(pkg && packageLane(pkg) === "finished"),
  };
}

function packageAnimationEntity(pkg: WorkPackageCard): UpdateAnimationEntity {
  const operational = pkg.operational_state || null;
  const blockerCount = pkg.active_blocker_count || (pkg.status === "blocked" || operational?.key === "blocked" ? 1 : 0);

  return {
    signature: stableSignature([
      pkg.status,
      pkg.operational_state,
      pkg.lineage,
      pkg.updated_at,
      pkg.latest_progress_at,
      pkg.active_blocker_count,
      pkg.artifact_count,
      pkg.finding_count,
      pkg.plan,
      pkg.metadata?.pr,
      pkg.metadata?.review_package,
      pkg.metadata?.review_suite_result,
      pkg.active_agent_run,
      pkg.runtime,
    ]),
    status: operational?.key || pkg.status,
    guidanceCount: 0,
    blockerCount,
    finished: packageLane(pkg) === "finished",
  };
}

function guidanceAnimationEntity(item: GuidanceItem): UpdateAnimationEntity {
  const status = item.source === "guidance" ? item.guidance.status : item.question.status;

  return {
    signature: stableSignature([item.title, item.detail, status, item.prompt, item.source === "clarification" ? item.question.answer : item.guidance.context]),
    status,
    guidanceCount: isClosedGuidanceStatus(status) ? 0 : 1,
    blockerCount: 0,
    finished: false,
  };
}

function blockerAnimationEntity(item: BlockerItem): UpdateAnimationEntity {
  return {
    signature: stableSignature([item.status, item.blockerCount, item.detail, item.title]),
    status: item.status,
    guidanceCount: 0,
    blockerCount: item.blockerCount,
    finished: false,
  };
}

function finishedHighlightAnimationEntity(item: FinishedHighlight): UpdateAnimationEntity {
  return {
    signature: stableSignature([item.state, item.at, item.title, item.kind]),
    status: item.state,
    guidanceCount: 0,
    blockerCount: 0,
    finished: true,
  };
}

function soloSessionAnimationEntity(session: SoloSession): UpdateAnimationEntity {
  const attention = soloSessionAttention(session);

  return {
    signature: stableSignature([session.status, session.last_activity_at, session.updated_at, session.entry_counts, session.latest_entry]),
    status: session.status,
    guidanceCount: attention.guidanceCount,
    blockerCount: attention.blockerCount,
    finished: soloSessionLane(session) === "finished",
  };
}

function stableSignature(value: unknown) {
  return JSON.stringify(value);
}

function isClosedGuidanceStatus(status?: string | null) {
  return ["answered", "closed", "resolved", "done", "completed"].includes(status || "");
}

function isBlockedStatus(status?: string | null) {
  return status === "blocked";
}
