import type { ActiveBlockingEdge, PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { ProductTreeCompletionMark, ProductTreeNode } from "@/types/product-tree";
import { sliceLane } from "@/lib/operational-state";

export function requestProgress(detail: WorkRequestDetail, packageById: Map<string, WorkPackageCard>) {
  const slices = detail.planned_slices ?? [];
  const treeMarks = productTreeRootProgressMarks(detail, slices, packageById);
  const marks = treeMarks.length > 0 ? completionMarkCounts(treeMarks) : sliceProgressMarkCounts(slices, packageById);

  if (marks.total > 0) return Math.round(((marks.done + marks.partial * 0.5) / marks.total) * 100);
  return detail.work_request.operational_state?.key === "completed" ? 100 : 0;
}

export function productTreeCounts(detail: WorkRequestDetail, activeBlockerCount: number) {
  const summary = detail.product_tree?.summary;

  return {
    nodeCount: numberValue(summary?.node_count, detail.product_tree?.nodes?.length),
    sliceCount: numberValue(summary?.slice_count, detail.planned_slices?.length),
    guidanceCount: numberValue(detail.summary?.open_question_count, detail.work_request.open_question_count, openQuestionCount(detail)),
    blockerCount: activeBlockerCount > 0 ? activeBlockerCount : numberValue(summary?.blocker_count),
  };
}

export function activeBlockerCounts(edges: ActiveBlockingEdge[]) {
  return edges.reduce<Map<string, number>>((counts, edge) => {
    if (!edge.work_request_id) return counts;
    counts.set(edge.work_request_id, (counts.get(edge.work_request_id) ?? 0) + 1);
    return counts;
  }, new Map());
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
