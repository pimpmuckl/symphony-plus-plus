import { ALIGNED_ROW_MIN_HEIGHT } from "@/components/dashboard/board-layout";
import type { ActiveBlockingEdge, PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { BoardWire } from "@/components/dashboard/board-wires";
import type { StateCardTone } from "@/components/dashboard/state-card-style";
import { isFinishedBoardStatus, packageCardTone, requestStateCardTone, sliceCardTone, sliceLane } from "@/lib/operational-state";
import { sortedCopy } from "@/lib/collections";
import type { CardDetailSelection } from "./runtime";
import type { SliceEntry, WorkstreamCategoryCounts, WorkstreamRow } from "./dashboard-state";
import { repoIdentityKey } from "./dashboard-persistence";

export function requestDetailsByRepoKey(details: WorkRequestDetail[]) {
  return details.reduce<Map<string, WorkRequestDetail[]>>((byRepo, detail) => {
    const repoKey = repoIdentityKey(detail.work_request);
    const repoDetails = byRepo.get(repoKey) || [];
    repoDetails.push(detail);
    byRepo.set(repoKey, repoDetails);
    return byRepo;
  }, new Map());
}

export function linkedPackageIdsForDetails(details: WorkRequestDetail[]) {
  return details.reduce<Set<string>>((ids, detail) => {
    (detail.planned_slices || []).forEach((slice) => {
      if (slice.work_package_id) ids.add(slice.work_package_id);
    });
    return ids;
  }, new Set());
}

export function packageSelectionIndex(details: WorkRequestDetail[], packages: WorkPackageCard[]) {
  const packageById = new Map(packages.map((pkg) => [pkg.id, pkg]));
  const selections = new Map<string, CardDetailSelection>();

  details.forEach((detail) => {
    (detail.planned_slices || []).forEach((slice) => {
      if (!slice.work_package_id || selections.has(slice.work_package_id)) return;

      const pkg = packageById.get(slice.work_package_id);
      if (!pkg) return;

      selections.set(slice.work_package_id, sliceLane(slice, pkg) === "slices" ? { kind: "slice", detail, slice, pkg } : { kind: "package", pkg, detail, slice });
    });
  });

  return selections;
}

export function packageHasActiveBlocker(pkg: WorkPackageCard) {
  const operational = pkg.operational_state || null;
  return operational?.key === "blocked" || pkg.status === "blocked" || (pkg.active_blocker_count || 0) > 0;
}

export function sliceSuccessorLabel(slice: PlannedSlice) {
  return [
    slice.successor?.planned_slice?.title,
    slice.successor?.planned_slice_id,
    slice.successor?.work_package?.title,
    slice.successor?.work_package_id,
    slice.delivery?.successor_planned_slice_id,
    slice.delivery?.successor_work_package_id,
  ].find(Boolean) || null;
}

export function sortWorkRequestDetails(details: WorkRequestDetail[]) {
  return sortedCopy(details, (left, right) => {
    const leftTime = sortableTime(left.work_request.inserted_at || left.work_request.updated_at);
    const rightTime = sortableTime(right.work_request.inserted_at || right.work_request.updated_at);
    if (leftTime !== rightTime) return leftTime - rightTime;
    return (left.work_request.title || left.work_request.id).localeCompare(right.work_request.title || right.work_request.id);
  });
}

export function sortPackages(packages: WorkPackageCard[]) {
  return sortedCopy(packages, (left, right) => {
    const leftTime = sortableTime(left.latest_progress_at || left.updated_at);
    const rightTime = sortableTime(right.latest_progress_at || right.updated_at);
    if (leftTime !== rightTime) return rightTime - leftTime;
    return (left.title || left.id).localeCompare(right.title || right.id);
  });
}

export function sortPlannedSlices(slices: PlannedSlice[]) {
  return sortedCopy(slices, comparePlannedSlices);
}

export function sortSliceEntries(entries: SliceEntry[]) {
  return sortedCopy(entries, (left, right) => {
    const requestDelta = left.requestIndex - right.requestIndex;
    if (requestDelta !== 0) return requestDelta;
    return comparePlannedSlices(left.slice, right.slice);
  });
}

export function comparePlannedSlices(left: PlannedSlice, right: PlannedSlice) {
  const sequenceDelta = sortableSequence(left.sequence) - sortableSequence(right.sequence);
  if (sequenceDelta !== 0) return sequenceDelta;

  const leftTime = sortableTime(left.inserted_at || left.updated_at);
  const rightTime = sortableTime(right.inserted_at || right.updated_at);
  if (leftTime !== rightTime) return leftTime - rightTime;

  return (left.title || left.id).localeCompare(right.title || right.id);
}

export function sortableSequence(sequence?: number | null) {
  return typeof sequence === "number" && Number.isFinite(sequence) ? sequence : Number.MAX_SAFE_INTEGER;
}

export function sortableTime(value?: string | null) {
  const timestamp = value ? Date.parse(value) : 0;
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

export function workstreamCategoryCounts(details: WorkRequestDetail[]): WorkstreamCategoryCounts {
  let planNodes = 0;
  let slices = 0;

  details.forEach((detail) => {
    const summary = detail.product_tree?.summary;
    planNodes += summary?.node_count ?? detail.product_tree?.nodes?.length ?? 0;
    slices += summary?.slice_count ?? detail.planned_slices?.length ?? 0;
  });

  return {
    requests: details.length,
    planNodes,
    slices,
  };
}

export function workstreamRows(
  details: WorkRequestDetail[],
  sliceEntries: SliceEntry[],
  activePackages: WorkPackageCard[],
  implementingPackages: WorkPackageCard[],
  finishedPackages: WorkPackageCard[],
): WorkstreamRow[] {
  const entriesByRequestIndex = sliceEntries.reduce<Map<number, SliceEntry[]>>((byIndex, entry) => {
    const entries = byIndex.get(entry.requestIndex) || [];
    entries.push(entry);
    byIndex.set(entry.requestIndex, entries);
    return byIndex;
  }, new Map());

  const rows: WorkstreamRow[] = details.map((detail, index) => {
    const active = entriesByRequestIndex.get(index) || [];
    const packageEntries = active.filter((entry) => entry.pkg);
    const implementing = packageEntries.filter((entry) => sliceLane(entry.slice, entry.pkg) !== "finished");
    const finished = packageEntries.filter((entry) => sliceLane(entry.slice, entry.pkg) === "finished");

    return {
      detail,
      active,
      implementing,
      finished,
      activePackages: [],
      implementingPackages: [],
      finishedPackages: [],
      minHeight: ALIGNED_ROW_MIN_HEIGHT,
    };
  });

  if (activePackages.length > 0 || implementingPackages.length > 0 || finishedPackages.length > 0) {
    rows.push({
      active: [],
      implementing: [],
      finished: [],
      activePackages,
      implementingPackages,
      finishedPackages,
      minHeight: ALIGNED_ROW_MIN_HEIGHT,
      unlinked: true,
    });
  }

  return rows;
}

export function requestDetailFinished(detail: WorkRequestDetail) {
  const request = detail.work_request;
  return [request.operational_state?.key, request.status].some(isFinishedBoardStatus);
}

export function requestChildrenVisible(detail: WorkRequestDetail, expandedFinishedRequests: Record<string, boolean>, scopeKey: string) {
  if (!requestDetailFinished(detail)) return true;
  return expandedFinishedRequests[finishedRequestChildrenStorageKey(scopeKey, detail.work_request.id)] === true;
}

export function requestChildCount(detail: WorkRequestDetail, packageById: Map<string, WorkPackageCard>) {
  const slices = detail.planned_slices || [];
  const linkedPackages = slices.filter((slice) => slice.work_package_id && packageById.has(slice.work_package_id)).length;
  return (detail.product_tree?.summary?.node_count ?? detail.product_tree?.nodes?.length ?? 0) + slices.length + linkedPackages;
}

export function detailsWithVisibleSlices(details: WorkRequestDetail[], visibleEntries: SliceEntry[]) {
  const visibleSliceIdsByRequest = visibleEntries.reduce<Map<string, Set<string>>>((byRequest, entry) => {
    const workRequestId = entry.detail.work_request.id;
    const sliceIds = byRequest.get(workRequestId) || new Set<string>();
    sliceIds.add(entry.slice.id);
    byRequest.set(workRequestId, sliceIds);
    return byRequest;
  }, new Map());

  return details.map((detail) => {
    const slices = detail.planned_slices || [];
    const visibleSliceIds = visibleSliceIdsByRequest.get(detail.work_request.id);
    if (!visibleSliceIds) return slices.length === 0 ? detail : { ...detail, planned_slices: [] };
    if (visibleSliceIds.size === slices.length) return detail;
    return { ...detail, planned_slices: slices.filter((slice) => visibleSliceIds.has(slice.id)) };
  });
}

export function finishedRequestChildrenStorageKey(scopeKey: string, workRequestId: string) {
  return `${scopeKey}::${workRequestId}`;
}

export function workstreamRowKey(row: WorkstreamRow, index: number) {
  if (row.detail) return `request-row:${row.detail.work_request.id}`;
  return row.unlinked ? "unlinked-row" : `row:${index}`;
}

export function workstreamWires(
  details: WorkRequestDetail[],
  sliceEntries: SliceEntry[],
  packages: WorkPackageCard[],
  activeBlockingEdges: ActiveBlockingEdge[] = [],
): BoardWire[] {
  const packageMap = new Map(packages.map((pkg) => [pkg.id, pkg]));
  const sourceToneByRequestId = new Map<string, StateCardTone>();
  details.forEach((detail) => {
    sourceToneByRequestId.set(detail.work_request.id, requestStateCardTone(detail));
  });

  const progressWires = sliceEntries.flatMap((entry, index) => {
    const { detail, slice: target } = entry;
    const source = requestNodeId(detail);
    const sourceTone = sourceToneByRequestId.get(detail.work_request.id) || requestStateCardTone(detail);
    const pkg = packageMap.get(target.work_package_id || "");
    const targetNode = sliceNodeId(target);
    const targetTone = sliceCardTone(target, pkg, "slices");
    const wires: BoardWire[] = [{
      id: `${source}->${targetNode}:${index}:slice`,
      from: source,
      to: targetNode,
      sourceTone,
      tone: targetTone,
    }];

    if (pkg) {
      const packageTargetNode = packageNodeId(pkg);
      wires.push({
        id: `${targetNode}->${packageTargetNode}:${index}:package`,
        from: targetNode,
        to: packageTargetNode,
        sourceTone: targetTone,
        tone: packageCardTone(pkg, sliceLane(target, pkg)),
      });
    }

    return wires;
  });

  return [...progressWires, ...activeBlockingWires(details, packages, activeBlockingEdges)];
}

export function requestNodeId(detail: WorkRequestDetail) {
  return `request:${detail.work_request.id}`;
}

export function sliceNodeId(slice: PlannedSlice) {
  return `slice:${slice.id}`;
}

export function packageNodeId(pkg: WorkPackageCard | string) {
  return `package:${typeof pkg === "string" ? pkg : pkg.id}`;
}

export function activeBlockingWires(details: WorkRequestDetail[], packages: WorkPackageCard[], activeBlockingEdges: ActiveBlockingEdge[]): BoardWire[] {
  if (activeBlockingEdges.length === 0) return [];

  const context = blockerWireContext(details, packages);

  return activeBlockingEdges.flatMap((edge) => {
    const target = blockerEndpoint(edge.to, context, "target");
    if (!target) return [];

    const source = blockerEndpoint(edge.from, context, "source") || blockerFallbackSourceEndpoint(edge, context);
    if (!source || source === target) return [];

    return [
      {
        id: `blocker:${edge.id}`,
        from: source,
        to: target,
        sourceTone: "blocked",
        tone: "blocked",
        kind: "blocker",
      },
    ];
  });
}

export function blockerWireContext(details: WorkRequestDetail[], packages: WorkPackageCard[]) {
  const detailById = new Map(details.map((detail) => [detail.work_request.id, detail]));
  const detailBySliceId = new Map<string, WorkRequestDetail>();
  const sliceById = new Map<string, PlannedSlice>();
  const packageById = new Map(packages.map((pkg) => [pkg.id, pkg]));

  details.forEach((detail) => {
    (detail.planned_slices || []).forEach((slice) => {
      sliceById.set(slice.id, slice);
      detailBySliceId.set(slice.id, detail);
    });
  });

  return { detailById, detailBySliceId, packageById, sliceById };
}

export function blockerEndpoint(
  endpoint: ActiveBlockingEdge["from"],
  context: ReturnType<typeof blockerWireContext>,
  role: "source" | "target",
): string | undefined {
  if (endpoint.kind === "work_package") {
    return context.packageById.has(endpoint.id) ? packageNodeId(endpoint.id) : undefined;
  }

  const slice = context.sliceById.get(endpoint.id);
  if (!slice) return undefined;

  const pkg = context.packageById.get(slice.work_package_id || "");
  if (pkg) return packageNodeId(pkg);

  if (sliceLane(slice, pkg) === "slices") return sliceNodeId(slice);
  return role === "target" ? sliceNodeId(slice) : undefined;
}

export function blockerFallbackSourceEndpoint(edge: ActiveBlockingEdge, context: ReturnType<typeof blockerWireContext>) {
  if (edge.from.kind === "slice") {
    const detail = context.detailBySliceId.get(edge.from.id);
    if (detail) return requestNodeId(detail);
  }

  if (edge.work_request_id) {
    const detail = context.detailById.get(edge.work_request_id);
    if (detail) return requestNodeId(detail);
  }

  return undefined;
}
