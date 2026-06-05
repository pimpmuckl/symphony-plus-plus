import { describe, expect, it } from "vitest";

import type { RepoSummary } from "./dashboard-data";
import type { WorkstreamCategoryCounts } from "./dashboard-state";
import { REPO_SUMMARY_PLATE_WIDTH_VAR_BY_KEY, repoSummaryMetrics, repoSummaryPlateLabels } from "./repo-summary-state";

describe("repo summary state", () => {
  it("builds the rendered repo summary labels that drive shared plate sizing", () => {
    const repo: RepoSummary = {
      repoKey: "repo-summary",
      repo: "repo-summary",
      baseBranches: ["main"],
      requested: 0,
      active: 0,
      implementing: 0,
      finished: 0,
      guidanceCount: 2,
      blockerCount: 1,
      packages: [],
      requests: [],
    };
    const categoryCounts: WorkstreamCategoryCounts = {
      requests: 3,
      planNodes: 12,
      slices: 46,
    };

    expect(repoSummaryPlateLabels(repo, categoryCounts)).toEqual([
      "3 Requests",
      "12 Plan Nodes",
      "46 Slices",
      "2 Guidance Needed",
      "1 Active Blockers",
    ]);
    expect(repoSummaryMetrics(repo, categoryCounts).map((item) => [item.key, item.group, item.tone])).toEqual([
      ["requests", "progress", "requested"],
      ["planNodes", "progress", "implementing"],
      ["slices", "progress", "active"],
      ["guidance", "attention", "guidance"],
      ["blockers", "attention", "blocker"],
    ]);
    expect(REPO_SUMMARY_PLATE_WIDTH_VAR_BY_KEY).toEqual({
      requests: "--v3-repo-plate-requests-width",
      planNodes: "--v3-repo-plate-plan-nodes-width",
      slices: "--v3-repo-plate-slices-width",
      guidance: "--v3-repo-plate-guidance-width",
      blockers: "--v3-repo-plate-blockers-width",
    });
  });
});
