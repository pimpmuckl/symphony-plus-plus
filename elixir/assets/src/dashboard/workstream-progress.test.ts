import { describe, expect, it } from "vitest";

import { activeBlockerCounts, productTreeCounts, requestProgress } from "./workstream-progress";
import type { ActiveBlockingEdge, PlannedSlice, WorkRequestDetail, WorkPackageCard } from "@/types/dashboard";

describe("workstream progress", () => {
  it("counts active direct slices as partial progress", () => {
    const detail = workRequestDetail([
      plannedSlice("slice-active", "active"),
      plannedSlice("slice-planned", "planned"),
    ]);

    expect(requestProgress(detail, new Map<string, WorkPackageCard>())).toBe(25);
  });

  it("adds product-tree blockers and explicit blocker edges", () => {
    const detail = workRequestDetail([]);
    detail.product_tree = {
      ...detail.product_tree,
      summary: {
        blocker_count: 3,
        node_count: 2,
        slice_count: 4,
      },
    };

    expect(productTreeCounts(detail, 2).blockerCount).toBe(5);
  });

  it("counts blocker edges through slice and package endpoints before work request fallbacks", () => {
    const detail = workRequestDetail([
      plannedSlice("slice-endpoint", "blocked", "pkg-endpoint"),
      plannedSlice("slice-package", "blocked", "pkg-shared"),
    ]);

    const counts = activeBlockerCounts(
      [
        blockingEdge("blocker-slice", { kind: "slice", id: "slice-endpoint" }, { kind: "work_package", id: "unknown-package" }),
        blockingEdge("blocker-package", { kind: "work_package", id: "pkg-shared" }, { kind: "work_package", id: "unknown-package" }),
        blockingEdge("blocker-fallback", { kind: "work_package", id: "unknown-package" }, { kind: "work_package", id: "unknown-package" }, "wr-progress"),
      ],
      [detail],
    );

    expect(counts.get("wr-progress")).toBe(3);
  });
});

function workRequestDetail(plannedSlices: PlannedSlice[]): WorkRequestDetail {
  return {
    work_request: { id: "wr-progress", status: "sliced", operational_state: { key: "active" } },
    planned_slices: plannedSlices,
    product_tree: {
      available: true,
      mode: "direct_slices",
      nodes: [],
      root_node_ids: [],
      root_slice_ids: plannedSlices.map((slice) => slice.id),
    },
  };
}

function plannedSlice(id: string, state: string, workPackageId?: string): PlannedSlice {
  return {
    id,
    work_request_id: "wr-progress",
    title: id,
    status: "planned",
    work_package_id: workPackageId,
    operational_state: { key: state },
  };
}

function blockingEdge(
  id: string,
  from: ActiveBlockingEdge["from"],
  to: ActiveBlockingEdge["to"],
  workRequestId?: string,
): ActiveBlockingEdge {
  return {
    id,
    blocker_id: id,
    from,
    to,
    work_request_id: workRequestId,
  };
}
