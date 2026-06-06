import type { ActiveBlockingEdge, GuidanceItem, PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { ProductTreeNode } from "@/types/product-tree";
import type { CardDetailSelect } from "./runtime";
import { sliceBlockerCount, sliceGuidanceCount } from "./workstream-row-state";

type TreeIndex = {
  childrenByParent: Map<string, ProductTreeNode[]>;
};

export function requestGuidanceItem(detail: WorkRequestDetail, guidanceItems: GuidanceItem[]) {
  return guidanceItems.find((item) => item.source === "clarification" && item.workRequestId === detail.work_request.id) ?? null;
}

export function openGuidanceForSlices(
  detail: WorkRequestDetail,
  slices: PlannedSlice[],
  packageById: Map<string, WorkPackageCard>,
  guidanceItems: GuidanceItem[],
  onSelectGuidance: (item: GuidanceItem) => void,
  onSelectCard: CardDetailSelect,
) {
  const item = guidanceItemForSlices(slices, packageById, guidanceItems);
  if (item) {
    onSelectGuidance(item);
    return;
  }

  const slice = slices.find((candidate) => sliceGuidanceCount(candidate, packageById.get(candidate.work_package_id || "")) > 0) ?? slices[0];
  if (slice) {
    onSelectCard({ kind: "slice", detail, slice, pkg: packageById.get(slice.work_package_id || "") });
    return;
  }

  onSelectCard({ kind: "request", detail });
}

export function openGuidanceForSlice(
  detail: WorkRequestDetail,
  slice: PlannedSlice,
  pkg: WorkPackageCard | undefined,
  guidanceItems: GuidanceItem[],
  onSelectGuidance: (item: GuidanceItem) => void,
  onSelectCard: CardDetailSelect,
) {
  const item = packageGuidanceItem(pkg, guidanceItems);
  if (item) {
    onSelectGuidance(item);
    return;
  }

  onSelectCard({ kind: "slice", detail, slice, pkg });
}

export function openBlockersForRequest(
  detail: WorkRequestDetail,
  slices: PlannedSlice[],
  packageById: Map<string, WorkPackageCard>,
  activeBlockerCountBySliceId: Map<string, number>,
  activeBlockingEdges: ActiveBlockingEdge[],
  onSelectCard: CardDetailSelect,
) {
  const slice = blockedSlice(slices, packageById, activeBlockerCountBySliceId);
  if (slice) {
    openSliceBlocker(detail, slice, packageById, onSelectCard);
    return;
  }

  const edgeTarget = requestBlockerEdgeTarget(detail, slices, activeBlockingEdges);
  if (edgeTarget?.kind === "work_package") {
    const pkg = packageById.get(edgeTarget.id);
    if (pkg) {
      onSelectCard({ kind: "package", pkg, detail });
      return;
    }
  }

  if (edgeTarget?.kind === "slice") {
    const edgeSlice = slices.find((candidate) => candidate.id === edgeTarget.id);
    if (edgeSlice) {
      openSliceBlocker(detail, edgeSlice, packageById, onSelectCard);
      return;
    }
  }

  onSelectCard({ kind: "request", detail });
}

export function openBlockersForSlices(
  detail: WorkRequestDetail,
  slices: PlannedSlice[],
  packageById: Map<string, WorkPackageCard>,
  activeBlockerCountBySliceId: Map<string, number>,
  onSelectCard: CardDetailSelect,
) {
  const slice = blockedSlice(slices, packageById, activeBlockerCountBySliceId);
  if (slice) {
    openSliceBlocker(detail, slice, packageById, onSelectCard);
    return;
  }

  onSelectCard({ kind: "request", detail });
}

export function productNodeSubtreeSlices(
  node: ProductTreeNode,
  treeIndex: TreeIndex,
  slicesById: Map<string, PlannedSlice>,
  visited = new Set<string>(),
): PlannedSlice[] {
  if (visited.has(node.id)) return [];
  visited.add(node.id);

  const slices = (node.slice_ids ?? []).map((sliceId) => slicesById.get(sliceId)).filter((slice): slice is PlannedSlice => Boolean(slice));
  for (const child of treeIndex.childrenByParent.get(node.id) ?? []) {
    slices.push(...productNodeSubtreeSlices(child, treeIndex, slicesById, visited));
  }

  return slices;
}

function packageGuidanceItem(pkg: WorkPackageCard | undefined, guidanceItems: GuidanceItem[]) {
  if (!pkg) return null;
  return guidanceItems.find((item) => item.source === "guidance" && item.packageId === pkg.id) ?? null;
}

function blockedSlice(
  slices: PlannedSlice[],
  packageById: Map<string, WorkPackageCard>,
  activeBlockerCountBySliceId: Map<string, number>,
) {
  return slices.find((candidate) => sliceBlockerCount(candidate, packageById.get(candidate.work_package_id || ""), activeBlockerCountBySliceId) > 0);
}

function openSliceBlocker(
  detail: WorkRequestDetail,
  slice: PlannedSlice,
  packageById: Map<string, WorkPackageCard>,
  onSelectCard: CardDetailSelect,
) {
  const pkg = packageById.get(slice.work_package_id || "");
  onSelectCard(pkg ? { kind: "package", pkg, detail, slice } : { kind: "slice", detail, slice, pkg });
}

function requestBlockerEdgeTarget(
  detail: WorkRequestDetail,
  slices: PlannedSlice[],
  activeBlockingEdges: ActiveBlockingEdge[],
): ActiveBlockingEdge["from"] | null {
  const requestId = detail.work_request.id;
  const sliceIds = new Set(slices.map((slice) => slice.id));
  const packageIds = new Set(slices.map((slice) => slice.work_package_id).filter((id): id is string => Boolean(id)));

  for (const edge of activeBlockingEdges) {
    if (!edgeMatchesRequest(edge, requestId, sliceIds, packageIds)) continue;
    if (edge.work_package_id) return { kind: "work_package", id: edge.work_package_id };
    if (edge.planned_slice_id) return { kind: "slice", id: edge.planned_slice_id };
    if (edge.from.kind === "work_package" || edge.from.kind === "slice") return edge.from;
    if (edge.to.kind === "work_package" || edge.to.kind === "slice") return edge.to;
  }

  return null;
}

function edgeMatchesRequest(
  edge: ActiveBlockingEdge,
  requestId: string,
  sliceIds: Set<string>,
  packageIds: Set<string>,
) {
  return (
    edge.work_request_id === requestId ||
    Boolean(edge.planned_slice_id && sliceIds.has(edge.planned_slice_id)) ||
    Boolean(edge.work_package_id && packageIds.has(edge.work_package_id)) ||
    endpointMatches(edge.from, sliceIds, packageIds) ||
    endpointMatches(edge.to, sliceIds, packageIds)
  );
}

function endpointMatches(endpoint: ActiveBlockingEdge["from"], sliceIds: Set<string>, packageIds: Set<string>) {
  return endpoint.kind === "slice" ? sliceIds.has(endpoint.id) : packageIds.has(endpoint.id);
}

function guidanceItemForSlices(slices: PlannedSlice[], packageById: Map<string, WorkPackageCard>, guidanceItems: GuidanceItem[]) {
  for (const slice of slices) {
    const item = packageGuidanceItem(packageById.get(slice.work_package_id || ""), guidanceItems);
    if (item) return item;
  }

  return null;
}
