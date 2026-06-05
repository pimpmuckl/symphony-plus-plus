import type { ActiveBlockingEdge, PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { ProductTreeCompletionMark, ProductTreeNode } from "@/types/product-tree";
import { isFinishedBoardStatus, sliceLane } from "@/lib/operational-state";

export type ActiveBlockerEntityCounts = {
  requests: Map<string, number>;
  slices: Map<string, number>;
  packages: Map<string, number>;
};

export function requestProgress(detail: WorkRequestDetail, packageById: Map<string, WorkPackageCard>) {
  const slices = detail.planned_slices ?? [];
  const treeMarks = productTreeRootProgressMarks(detail, slices, packageById);
  const marks = treeMarks.length > 0 ? completionMarkCounts(treeMarks) : sliceProgressMarkCounts(slices, packageById);

  if (marks.total > 0) return Math.round(((marks.done + marks.partial * 0.5) / marks.total) * 100);
  return isFinishedBoardStatus(detail.work_request.operational_state?.key || detail.work_request.status) ? 100 : 0;
}

export function productTreeCounts(detail: WorkRequestDetail, activeBlockerCount: number) {
  const summary = detail.product_tree?.summary;
  const treeBlockerCount = numberValue(summary?.blocker_count);

  return {
    nodeCount: numberValue(summary?.node_count, detail.product_tree?.nodes?.length),
    sliceCount: numberValue(summary?.slice_count, detail.planned_slices?.length),
    guidanceCount: numberValue(detail.summary?.open_question_count, detail.work_request.open_question_count, openQuestionCount(detail)),
    blockerCount: treeBlockerCount + activeBlockerCount,
  };
}

export function activeBlockerCounts(edges: ActiveBlockingEdge[], requestDetails: WorkRequestDetail[] = []) {
  return activeBlockerEntityCounts(edges, requestDetails).requests;
}

export function activeBlockerEntityCounts(edges: ActiveBlockingEdge[], requestDetails: WorkRequestDetail[] = []): ActiveBlockerEntityCounts {
  const requestIndex = blockerRequestIndex(requestDetails);

  return edges.reduce<ActiveBlockerEntityCounts>((counts, edge) => {
    incrementCounts(counts.requests, activeBlockerRequestIds(edge, requestIndex));
    incrementCounts(counts.slices, activeBlockerSliceIds(edge, requestIndex));
    incrementCounts(counts.packages, activeBlockerPackageIds(edge));

    return counts;
  }, { requests: new Map(), slices: new Map(), packages: new Map() });
}

type BlockerRequestIndex = {
  requestIdBySliceId: Map<string, string>;
  requestIdsByPackageId: Map<string, Set<string>>;
  sliceIdsByPackageId: Map<string, Set<string>>;
};

function blockerRequestIndex(requestDetails: WorkRequestDetail[]): BlockerRequestIndex {
  const requestIdBySliceId = new Map<string, string>();
  const requestIdsByPackageId = new Map<string, Set<string>>();
  const sliceIdsByPackageId = new Map<string, Set<string>>();

  for (const detail of requestDetails) {
    const requestId = detail.work_request.id;
    for (const slice of detail.planned_slices ?? []) {
      requestIdBySliceId.set(slice.id, requestId);
      if (!slice.work_package_id) continue;

      const requestIds = requestIdsByPackageId.get(slice.work_package_id) ?? new Set<string>();
      requestIds.add(requestId);
      requestIdsByPackageId.set(slice.work_package_id, requestIds);

      const sliceIds = sliceIdsByPackageId.get(slice.work_package_id) ?? new Set<string>();
      sliceIds.add(slice.id);
      sliceIdsByPackageId.set(slice.work_package_id, sliceIds);
    }
  }

  return { requestIdBySliceId, requestIdsByPackageId, sliceIdsByPackageId };
}

function activeBlockerRequestIds(edge: ActiveBlockingEdge, requestIndex: BlockerRequestIndex) {
  const derivedRequestIds = new Set<string>();
  addEndpointRequestIds(derivedRequestIds, requestIndex, edge.from);
  addEndpointRequestIds(derivedRequestIds, requestIndex, edge.to);
  if (derivedRequestIds.size > 0) return derivedRequestIds;

  return edge.work_request_id ? new Set([edge.work_request_id]) : new Set<string>();
}

function activeBlockerSliceIds(edge: ActiveBlockingEdge, requestIndex: BlockerRequestIndex) {
  const sliceIds = new Set<string>();
  if (edge.planned_slice_id) sliceIds.add(edge.planned_slice_id);
  addEndpointSliceIds(sliceIds, requestIndex, edge.from);
  addEndpointSliceIds(sliceIds, requestIndex, edge.to);
  return sliceIds;
}

function activeBlockerPackageIds(edge: ActiveBlockingEdge) {
  const packageIds = new Set<string>();
  if (edge.work_package_id) packageIds.add(edge.work_package_id);
  addEndpointPackageIds(packageIds, edge.from);
  addEndpointPackageIds(packageIds, edge.to);
  return packageIds;
}

function addEndpointRequestIds(
  requestIds: Set<string>,
  requestIndex: BlockerRequestIndex,
  endpoint?: ActiveBlockingEdge["from"],
) {
  if (!endpoint) return;

  if (endpoint.kind === "slice") {
    const requestId = requestIndex.requestIdBySliceId.get(endpoint.id);
    if (requestId) requestIds.add(requestId);
  }

  if (endpoint.kind === "work_package") {
    for (const requestId of requestIndex.requestIdsByPackageId.get(endpoint.id) ?? []) {
      requestIds.add(requestId);
    }
  }
}

function addEndpointSliceIds(
  sliceIds: Set<string>,
  requestIndex: BlockerRequestIndex,
  endpoint?: ActiveBlockingEdge["from"],
) {
  if (!endpoint) return;

  if (endpoint.kind === "slice") {
    sliceIds.add(endpoint.id);
  }

  if (endpoint.kind === "work_package") {
    for (const sliceId of requestIndex.sliceIdsByPackageId.get(endpoint.id) ?? []) {
      sliceIds.add(sliceId);
    }
  }
}

function addEndpointPackageIds(packageIds: Set<string>, endpoint?: ActiveBlockingEdge["from"]) {
  if (endpoint?.kind === "work_package") packageIds.add(endpoint.id);
}

function incrementCounts(counts: Map<string, number>, ids: Iterable<string>) {
  for (const id of ids) {
    counts.set(id, (counts.get(id) ?? 0) + 1);
  }
}

export function rootProductSliceIds(detail: WorkRequestDetail, slices: PlannedSlice[]) {
  const productTree = detail.product_tree;
  if (!productTree) return slices.map((slice) => slice.id);

  const explicitRootSliceIds = productTree.root_slice_ids ?? [];
  if (explicitRootSliceIds.length > 0) return explicitRootSliceIds;

  const nestedSliceIds = new Set((productTree.nodes ?? []).flatMap((node) => node.slice_ids ?? []));
  const rootSliceIds: string[] = [];

  for (const slice of slices) {
    if (!nestedSliceIds.has(slice.id)) rootSliceIds.push(slice.id);
  }

  return rootSliceIds;
}

function openQuestionCount(detail: WorkRequestDetail) {
  return (detail.clarification_questions ?? []).filter((question) => question.status === "open").length;
}

function productTreeRootProgressMarks(detail: WorkRequestDetail, slices: PlannedSlice[], packageById: Map<string, WorkPackageCard>) {
  const nodes = detail.product_tree?.nodes ?? [];
  if (nodes.length === 0) return [];

  const nodeById = new Map(nodes.map((node) => [node.id, node]));
  const rootNodeIds = detail.product_tree?.root_node_ids?.length ? detail.product_tree.root_node_ids : implicitRootNodeIds(nodes);
  return [...rootNodeProgressMarks(rootNodeIds, nodeById), ...rootSliceProgressMarks(detail, slices, packageById)];
}

function rootNodeProgressMarks(rootNodeIds: string[], nodeById: Map<string, ProductTreeNode>) {
  const marks: ProductTreeCompletionMark[] = [];
  for (const nodeId of rootNodeIds) {
    const node = nodeById.get(nodeId);
    if (node) marks.push(node.computed_completion_mark || node.completion_mark || "unknown");
  }
  return marks;
}

function rootSliceProgressMarks(detail: WorkRequestDetail, slices: PlannedSlice[], packageById: Map<string, WorkPackageCard>) {
  const marks: ProductTreeCompletionMark[] = [];
  const sliceById = new Map(slices.map((slice) => [slice.id, slice]));
  for (const sliceId of rootProductSliceIds(detail, slices)) {
    const slice = sliceById.get(sliceId);
    if (slice) marks.push(sliceProgressMark(slice, packageById));
  }
  return marks;
}

function implicitRootNodeIds(nodes: ProductTreeNode[]) {
  const rootIds: string[] = [];
  for (const node of nodes) {
    if (!node.parent_id) rootIds.push(node.id);
  }
  return rootIds;
}

function sliceProgressMarkCounts(slices: PlannedSlice[], packageById: Map<string, WorkPackageCard>) {
  const marks: ProductTreeCompletionMark[] = [];
  for (const slice of slices) marks.push(sliceProgressMark(slice, packageById));
  return completionMarkCounts(marks);
}

function sliceProgressMark(slice: PlannedSlice, packageById: Map<string, WorkPackageCard>): ProductTreeCompletionMark {
  const lane = sliceLane(slice, packageById.get(slice.work_package_id || ""));
  if (lane === "finished") return "done";
  if (lane === "implementing") return "partial";
  return "not_done";
}

function completionMarkCounts(marks: ProductTreeCompletionMark[]) {
  let done = 0;
  let partial = 0;
  let notDone = 0;
  let unknown = 0;

  for (const mark of marks) {
    if (mark === "done") done += 1;
    if (mark === "partial") partial += 1;
    if (mark === "not_done") notDone += 1;
    if (mark === "unknown") unknown += 1;
  }

  return { done, partial, total: done + partial + notDone + unknown };
}

function numberValue(...values: Array<number | null | undefined>) {
  return values.find((value): value is number => typeof value === "number" && Number.isFinite(value)) ?? 0;
}
