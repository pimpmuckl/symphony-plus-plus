import type { PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { ProductTreeCompletionMark, ProductTreeNode } from "@/types/product-tree";
import { operationalLabel, sliceOperationalState } from "@/lib/operational-state";

const MIN_STATUS_LABEL_LENGTH = 8;
const MIN_STATUS_BADGE_WIDTH_REM = 6.1;
const MAX_STATUS_BADGE_WIDTH_REM = 11;

export type RowProgressIconState = "active" | "blocked" | "done" | "guidance" | "muted";
export type RowProgressAttentionState = "blocked" | "guidance" | null;

export function rowProgressIconState({
  blockerCount = 0,
  guidanceCount = 0,
  progress = 0,
  tone,
}: {
  blockerCount?: number;
  guidanceCount?: number;
  progress?: number;
  tone?: string | null;
}): RowProgressIconState {
  if (tone === "muted") return "muted";
  if (progress >= 100 || tone === "finished") return "done";
  if (blockerCount > 0 || tone === "blocked") return "blocked";
  if (guidanceCount > 0 || tone === "guidance") return "guidance";
  return "active";
}

export function rowProgressAttentionState({
  blockerCount = 0,
  guidanceCount = 0,
  tone,
}: {
  blockerCount?: number;
  guidanceCount?: number;
  tone?: string | null;
}): RowProgressAttentionState {
  if (blockerCount > 0 || tone === "blocked") return "blocked";
  if (guidanceCount > 0 || tone === "guidance") return "guidance";
  return null;
}

export function statusBadgeWidthForLabels(labels: Iterable<string | null | undefined>) {
  const width = Math.min(MAX_STATUS_BADGE_WIDTH_REM, Math.max(MIN_STATUS_BADGE_WIDTH_REM, longestStatusLabelLength(labels) * 0.3 + 3.2));
  return `${Number(width.toFixed(2))}rem`;
}

export function statusBadgeWidthForRequestDetails(details: WorkRequestDetail[], packageById: Map<string, WorkPackageCard>) {
  return statusBadgeWidthForLabels(details.flatMap((detail) => requestStatusLabels(detail, packageById)));
}

export function requestStatusLabels(detail: WorkRequestDetail, packageById: Map<string, WorkPackageCard>) {
  const request = detail.work_request;
  const labels = [operationalLabel(request.operational_state, request.status)];

  for (const node of detail.product_tree?.nodes ?? []) {
    labels.push(productNodeStatusLabel(node));
  }

  for (const slice of detail.planned_slices ?? []) {
    const pkg = packageById.get(slice.work_package_id || "");
    labels.push(operationalLabel(sliceOperationalState(slice, pkg), slice.work_package_status || slice.status));
  }

  return labels;
}

function longestStatusLabelLength(labels: Iterable<string | null | undefined>) {
  let longest = MIN_STATUS_LABEL_LENGTH;

  for (const label of labels) {
    longest = Math.max(longest, label?.trim().length ?? 0);
  }

  return longest;
}

function activeBlockerCountForNode(
  node: ProductTreeNode,
  treeIndex: { childrenByParent: Map<string, ProductTreeNode[]> },
  activeBlockerCountBySliceId: Map<string, number>,
  activeBlockerKeysBySliceId?: Map<string, Set<string>>,
  visited = new Set<string>(),
) {
  if (visited.has(node.id)) return 0;
  visited.add(node.id);

  if (activeBlockerKeysBySliceId) {
    return activeBlockerKeysForNode(node, treeIndex, activeBlockerKeysBySliceId, visited).size;
  }

  let count = 0;
  for (const sliceId of node.slice_ids ?? []) {
    count += activeBlockerCountBySliceId.get(sliceId) ?? 0;
  }

  for (const child of treeIndex.childrenByParent.get(node.id) ?? []) {
    count += activeBlockerCountForNode(child, treeIndex, activeBlockerCountBySliceId, undefined, visited);
  }

  return count;
}

function activeBlockerKeysForNode(
  node: ProductTreeNode,
  treeIndex: { childrenByParent: Map<string, ProductTreeNode[]> },
  activeBlockerKeysBySliceId: Map<string, Set<string>>,
  visited: Set<string>,
) {
  const blockerKeys = new Set<string>();

  for (const sliceId of node.slice_ids ?? []) {
    for (const blockerKey of activeBlockerKeysBySliceId.get(sliceId) ?? []) {
      blockerKeys.add(blockerKey);
    }
  }

  for (const child of treeIndex.childrenByParent.get(node.id) ?? []) {
    if (visited.has(child.id)) continue;
    visited.add(child.id);
    for (const blockerKey of activeBlockerKeysForNode(child, treeIndex, activeBlockerKeysBySliceId, visited)) {
      blockerKeys.add(blockerKey);
    }
  }

  return blockerKeys;
}

export function productNodeState(
  node: ProductTreeNode,
  nodeSliceCount: number,
  treeIndex: { childrenByParent: Map<string, ProductTreeNode[]> },
  activeBlockerCountBySliceId: Map<string, number>,
  activeBlockerKeysBySliceId?: Map<string, Set<string>>,
) {
  const activeBlockerCount = activeBlockerCountForNode(node, treeIndex, activeBlockerCountBySliceId, activeBlockerKeysBySliceId);
  const blockerCount = Math.max(node.blocker_count ?? 0, activeBlockerCount);
  const guidanceCount = Math.max((node.attention_count ?? 0) - blockerCount, 0);
  const mark = node.computed_completion_mark || node.completion_mark || "unknown";

  return {
    blockerCount,
    guidanceCount,
    mark,
    nodeSliceCount: node.slice_count || nodeSliceCount,
    statusLabel: productNodeStatusLabel(node, mark),
    tone: productNodeTone(mark, guidanceCount, blockerCount),
    visibleNodeKind: node.node_kind === "product_plan_node" ? null : node.node_kind,
  };
}

function productNodeStatusLabel(node: ProductTreeNode, mark = node.computed_completion_mark || node.completion_mark || "unknown") {
  return node.completion_label || completionMarkLabel(mark);
}

function productNodeTone(mark: ProductTreeCompletionMark, guidanceCount: number, blockerCount: number) {
  if (blockerCount > 0) return "blocked";
  if (guidanceCount > 0) return "guidance";
  if (mark === "done") return "finished";
  if (mark === "partial") return "review";
  if (mark === "deferred") return "muted";
  return "slice";
}

function completionMarkLabel(mark: ProductTreeCompletionMark) {
  switch (mark) {
    case "done":
      return "Done";
    case "partial":
      return "Partial";
    case "not_done":
      return "Not started";
    case "deferred":
      return "Deferred";
    default:
      return "Unknown";
  }
}

export function sliceBlockerCount(
  slice: PlannedSlice,
  pkg: WorkPackageCard | undefined,
  activeBlockerCountBySliceId: Map<string, number>,
  activeBlockerCountByPackageId: Map<string, number>,
) {
  const operational = sliceOperationalState(slice, pkg);
  const linkedPackageBlockers = slice.work_package_id ? activeBlockerCountByPackageId.get(slice.work_package_id) ?? 0 : 0;
  const activeCount = Math.max(activeBlockerCountBySliceId.get(slice.id) ?? 0, linkedPackageBlockers, pkg?.active_blocker_count ?? 0);

  if (activeCount > 0) return activeCount;

  const attentionCount = attentionBlockerCount(operational);
  if (attentionCount > 0) return attentionCount;

  return [operational?.key, slice.work_package_status, slice.status, pkg?.status].includes("blocked") ? 1 : 0;
}

export function sliceGuidanceCount(slice: PlannedSlice, pkg: WorkPackageCard | undefined, blockerCount: number) {
  const operational = sliceOperationalState(slice, pkg);
  const nonBlockerAttention = (operational?.attention_items ?? []).filter((item) => !attentionItemIsBlocker(item)).length;
  const reasonCount = Math.max(operational?.attention_reason_codes?.length ?? 0, slice.attention_reason_codes?.length ?? 0);
  const stateNeedsGuidance = [operational?.key, slice.status, slice.work_package_status, pkg?.status].some((status) =>
    status === "needs_attention" || status === "human_info_needed",
  );

  return Math.max(nonBlockerAttention, reasonCount, blockerCount > 0 ? 0 : stateNeedsGuidance ? 1 : 0);
}

function attentionBlockerCount(operational?: WorkPackageCard["operational_state"]) {
  const blockerIds = new Set<string>();
  let fallbackCount = 0;

  for (const item of operational?.attention_items ?? []) {
    if (!attentionItemIsBlocker(item)) continue;

    fallbackCount += 1;
    for (const blockerId of item.blocker_ids ?? []) {
      blockerIds.add(blockerId);
    }
  }

  return blockerIds.size || fallbackCount;
}

function attentionItemIsBlocker(item: NonNullable<NonNullable<WorkPackageCard["operational_state"]>["attention_items"]>[number]) {
  const key = (item.key || "").toLowerCase();
  const label = (item.label || "").toLowerCase();
  return key.includes("blocker") || label.includes("blocker") || (item.blocker_ids?.length ?? 0) > 0;
}
