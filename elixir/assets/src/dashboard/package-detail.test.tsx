import { describe, expect, it } from "vitest";

import { scopedBlockerDetailPayload } from "./package-detail";
import type { CardDetailSelection } from "./runtime";
import type { WorkPackageDetailPayload } from "@/types/dashboard";

describe("package detail blocker modal", () => {
  it("does not hydrate blocker detail from a different package with the same blocker id", () => {
    const selection: Extract<CardDetailSelection, { kind: "blocker" }> = {
      kind: "blocker",
      pkg: { id: "pkg-selected", title: "Selected package", status: "blocked" },
      blocker: {
        id: "edge-selected",
        blocker_id: "shared-blocker",
        from: { kind: "work_package", id: "pkg-source" },
        to: { kind: "work_package", id: "pkg-selected" },
        summary: "Selected blocker",
        body: "Selected body",
        work_package_id: "pkg-selected",
      },
    };
    const detailPayload: WorkPackageDetailPayload = {
      work_package: { id: "pkg-other", title: "Other package", status: "blocked" },
      blockers: [{ id: "shared-blocker", active: true, summary: "Stale blocker", body: "Stale body" }],
    };

    expect(scopedBlockerDetailPayload(selection, detailPayload)).toBeNull();
  });
});
