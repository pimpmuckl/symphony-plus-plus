import type { ActiveBlockingEdge, ActiveBlockingEdgeEndpoint, PlannedSlice, WorkPackageBlocker, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";

export function activePackageBlockers(pkg: WorkPackageCard | undefined) {
  return (pkg?.active_blockers || []).filter((blocker) => blocker.active !== false);
}

export function packageBlockerEdge(
  blocker: WorkPackageBlocker,
  pkg: WorkPackageCard,
  context: {
    detail?: WorkRequestDetail;
    slice?: PlannedSlice;
    fallbackKey?: string | number;
  } = {},
): ActiveBlockingEdge {
  const { from, to } = packageBlockerEndpoints(blocker, pkg, context.slice);
  const blockerId = blocker.id || "";
  const edgeKey = blockerEdgeKey(blocker, context.fallbackKey);

  return {
    id: `active_blocking_edge:${pkg.id}:${edgeKey}`,
    blocker_id: blockerId,
    from,
    to,
    summary: blocker.summary,
    body: blocker.body,
    updated_at: blocker.updated_at,
    work_request_id: context.detail?.work_request.id || context.slice?.work_request_id || null,
    planned_slice_id: context.slice?.id || null,
    work_package_id: pkg.id,
  };
}

export function pendingPackageBlockerEdge(
  pkg: WorkPackageCard,
  context: {
    detail?: WorkRequestDetail;
    slice?: PlannedSlice;
  } = {},
): ActiveBlockingEdge {
  const fallbackPackageEndpoint = packageEndpoint(pkg);
  const fallbackSliceEndpoint = sliceEndpoint(context.slice);

  return {
    id: `active_blocking_edge:${pkg.id}:pending`,
    blocker_id: "",
    from: fallbackSliceEndpoint || fallbackPackageEndpoint,
    to: fallbackPackageEndpoint,
    summary: "Active blocker",
    body: null,
    updated_at: pkg.latest_progress_at || pkg.updated_at || null,
    work_request_id: context.detail?.work_request.id || context.slice?.work_request_id || null,
    planned_slice_id: context.slice?.id || null,
    work_package_id: pkg.id,
  };
}

function packageBlockerEndpoints(blocker: WorkPackageBlocker, pkg: WorkPackageCard, slice?: PlannedSlice) {
  const fallbackPackageEndpoint = packageEndpoint(pkg);
  const fallbackSliceEndpoint = sliceEndpoint(slice);

  return {
    from: blocker.blocked_by || fallbackSliceEndpoint || fallbackPackageEndpoint,
    to: blocker.blocked_item || fallbackPackageEndpoint,
  };
}

function packageEndpoint(pkg: WorkPackageCard): ActiveBlockingEdgeEndpoint {
  return { kind: "work_package", id: pkg.id };
}

function sliceEndpoint(slice: PlannedSlice | undefined): ActiveBlockingEdgeEndpoint | null {
  return slice ? { kind: "slice", id: slice.id } : null;
}

function blockerEdgeKey(blocker: WorkPackageBlocker, fallbackKey: string | number | undefined) {
  const key = blocker.id || blocker.event_id || blocker.updated_at || fallbackKey;
  return String(key ?? "blocker");
}
