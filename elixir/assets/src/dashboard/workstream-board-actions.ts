import type { GuidanceItem, PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
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
  const item = guidanceItemForSlices(slices, packageById, guidanceItems) ?? requestGuidanceItem(detail, guidanceItems);
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

export function openBlockersForSlices(
  detail: WorkRequestDetail,
  slices: PlannedSlice[],
  packageById: Map<string, WorkPackageCard>,
  activeBlockerCountBySliceId: Map<string, number>,
  onSelectCard: CardDetailSelect,
) {
  const slice = slices.find((candidate) => sliceBlockerCount(candidate, packageById.get(candidate.work_package_id || ""), activeBlockerCountBySliceId) > 0) ?? slices[0];
  if (slice) {
    const pkg = packageById.get(slice.work_package_id || "");
    onSelectCard(pkg ? { kind: "package", pkg, detail, slice } : { kind: "slice", detail, slice, pkg });
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

function guidanceItemForSlices(slices: PlannedSlice[], packageById: Map<string, WorkPackageCard>, guidanceItems: GuidanceItem[]) {
  for (const slice of slices) {
    const item = packageGuidanceItem(packageById.get(slice.work_package_id || ""), guidanceItems);
    if (item) return item;
  }

  return null;
}
