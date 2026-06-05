import { describe, expect, it } from "vitest";

import type { PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import {
  countPlateWidthForLabels,
  rowProgressIconState,
  requestStatusLabels,
  statusBadgeWidthForLabels,
  statusBadgeWidthForRequestDetails,
} from "./workstream-row-state";

describe("workstream row state", () => {
  it("sizes status badges from the longest rendered label without the old wide bucket", () => {
    expect(statusBadgeWidthForLabels(["Delivered", "Clarifying"])).toBe("6.2rem");
    expect(statusBadgeWidthForLabels(["Delivered", "Completed Without PR", "Ready For Worker"])).toBe("9.2rem");
  });

  it("sizes repo count plates from the longest rendered count label", () => {
    expect(countPlateWidthForLabels(["3 Requests", "0 Plan Nodes", "0 Active Blockers"])).toBe("11.04rem");
    expect(countPlateWidthForLabels(["0 Guidance Needed"])).toBe("11.04rem");
  });

  it("maps row progress icons by attention, completion, and active progress priority", () => {
    expect(rowProgressIconState({ progress: 100, tone: "finished" })).toBe("done");
    expect(rowProgressIconState({ progress: 100, blockerCount: 1, tone: "finished" })).toBe("blocked");
    expect(rowProgressIconState({ progress: 100, guidanceCount: 1, tone: "finished" })).toBe("guidance");
    expect(rowProgressIconState({ tone: "muted" })).toBe("muted");
    expect(rowProgressIconState({ progress: 100, tone: "muted" })).toBe("muted");
    expect(rowProgressIconState({ progress: 45, tone: "implementing" })).toBe("active");
  });

  it("collects request, product node, and slice status labels for one row group", () => {
    const detail: WorkRequestDetail = {
      work_request: {
        id: "wr-row-state",
        status: "ready_for_slicing",
        operational_state: { key: "ready_for_slicing", label: "Ready For Slicing" },
      },
      product_tree: {
        available: true,
        mode: "product_tree",
        nodes: [{ id: "node-1", completion_mark: "partial", completion_label: "Partially Complete" }],
        root_node_ids: ["node-1"],
      },
      planned_slices: [
        plannedSlice("slice-1", "pkg-1", "completed_no_pr", "Completed Without PR"),
        plannedSlice("slice-2", undefined, "delivered", "Delivered"),
      ],
    };
    const packageById = new Map<string, WorkPackageCard>([
      ["pkg-1", { id: "pkg-1", status: "completed_no_pr", operational_state: { key: "completed_no_pr", label: "Completed Without PR" } }],
    ]);

    expect(requestStatusLabels(detail, packageById)).toEqual([
      "Ready For Slicing",
      "Partially Complete",
      "Completed Without PR",
      "Delivered",
    ]);
    expect(statusBadgeWidthForRequestDetails([detail], packageById)).toBe("9.2rem");
  });
});

function plannedSlice(id: string, workPackageId: string | undefined, stateKey: string, label: string): PlannedSlice {
  return {
    id,
    work_request_id: "wr-row-state",
    title: id,
    status: stateKey,
    work_package_id: workPackageId,
    operational_state: { key: stateKey, label },
  };
}
