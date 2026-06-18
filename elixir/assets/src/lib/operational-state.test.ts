import { describe, expect, it } from "vitest";

import { operationalBadgeVariant, sliceCardTone, sliceLane } from "./operational-state";
import type { PlannedSlice } from "@/types/dashboard";

describe("operational state presentation", () => {
  it("uses guidance color for clarifying statuses", () => {
    expect(operationalBadgeVariant({ key: "clarifying", label: "Clarifying", tone: "warning" }, "clarifying")).toBe("guidance");
    expect(operationalBadgeVariant(undefined, "human_info_needed")).toBe("guidance");
  });

  it("uses ready color for ready slices", () => {
    for (const status of ["approved", "ready_for_worker", "sliced"]) {
      const slice = plannedSlice(status);

      expect(sliceCardTone(slice, undefined, sliceLane(slice))).toBe("ready");
      expect(operationalBadgeVariant(slice.operational_state, slice.status)).toBe("ready");
    }
  });
});

function plannedSlice(status: string): PlannedSlice {
  return {
    id: `slice-${status}`,
    work_request_id: "wr-colors",
    status,
    operational_state: { key: status, label: "Ready" },
  };
}
