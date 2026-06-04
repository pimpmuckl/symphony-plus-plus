import { describe, expect, it } from "vitest";

import { productTreeCounts, requestProgress } from "./workstream-progress";
import type { PlannedSlice, WorkRequestDetail, WorkPackageCard } from "@/types/dashboard";

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

function plannedSlice(id: string, state: string): PlannedSlice {
  return {
    id,
    work_request_id: "wr-progress",
    title: id,
    status: "planned",
    operational_state: { key: state },
  };
}
