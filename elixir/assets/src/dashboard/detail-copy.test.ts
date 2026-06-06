import { describe, expect, it } from "vitest";

import type { GuidanceItem, WorkPackageCard } from "@/types/dashboard";
import { guidanceCopyText, packageBlockerCopyText } from "./detail-copy";

describe("detail copy helpers", () => {
  it("formats guidance details with the answer options", () => {
    const item: GuidanceItem = {
      source: "guidance",
      id: "gr-1",
      repo: "symphony-plus-plus",
      repoKey: "symphony-plus-plus",
      title: "Pick delivery path",
      packageId: "pkg-1",
      detail: "Choose whether this package should land now.",
      guidance: {
        id: "gr-1",
        work_package_id: "pkg-1",
        question: "Which path?",
      },
    };

    const text = guidanceCopyText(item, [
      { id: "ship", label: "Ship it", answer: "Proceed", description: "Continue with the current package." },
    ]);

    expect(text).toContain("Guidance: Pick delivery path");
    expect(text).toContain("Work Package: pkg-1");
    expect(text).toContain("Details\nChoose whether this package should land now.");
    expect(text).toContain("1. Ship it");
    expect(text).toContain("Answer: Proceed");
  });

  it("formats blocker detail with package state and blocker bodies", () => {
    const pkg: WorkPackageCard = {
      id: "pkg-blocked",
      title: "Blocked worker",
      repo: "symphony-plus-plus",
      status: "blocked",
    };

    const text = packageBlockerCopyText({
      blockerCount: 1,
      blockers: [{ id: "blocker-1", summary: "Waiting on review", body: "Reviewer needs to sign off.", updated_at: "2026-06-06T10:00:00Z" }],
      operationalTruth: "Blocked by external review.",
      pkg,
      repo: "symphony-plus-plus",
      state: "Blocked",
    });

    expect(text).toContain("Blockers: Blocked worker");
    expect(text).toContain("Active blockers: 1");
    expect(text).toContain("Operational Truth\nBlocked by external review.");
    expect(text).toContain("1. Waiting on review");
    expect(text).toContain("Body\nReviewer needs to sign off.");
  });
});
