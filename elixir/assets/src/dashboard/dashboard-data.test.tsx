import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { activeBlockerItems, FINISHED_HIGHLIGHT_LIMIT, recentFinishedHighlights } from "./dashboard-data";
import { RepoSummaryStrip } from "./repo-workstream";
import type { WorkPackageCard, WorkRequestCard, WorkRequestDetail } from "@/types/dashboard";
import type { RepoSummary } from "./dashboard-data";

describe("dashboard data helpers", () => {
  it("caps finished highlights to the most recent records", () => {
    const packages = Array.from({ length: FINISHED_HIGHLIGHT_LIMIT + 4 }, (_, index) =>
      finishedPackage(`pkg-${index}`, new Date(Date.UTC(2026, 5, 4, 12, 0, index)).toISOString()),
    );

    const highlights = recentFinishedHighlights(packages, [], [], new Map(), 3);

    expect(highlights.map((highlight) => highlight.id)).toEqual([
      `pkg-${FINISHED_HIGHLIGHT_LIMIT + 3}`,
      `pkg-${FINISHED_HIGHLIGHT_LIMIT + 2}`,
      `pkg-${FINISHED_HIGHLIGHT_LIMIT + 1}`,
    ]);
  });

  it("preserves finished package highlights when the server limit is null", () => {
    const packages = Array.from({ length: FINISHED_HIGHLIGHT_LIMIT + 4 }, (_, index) =>
      finishedPackage(`pkg-${index}`, new Date(Date.UTC(2026, 5, 4, 12, 0, index)).toISOString()),
    );

    const highlights = recentFinishedHighlights(packages, [], [], new Map(), null);

    expect(highlights).toHaveLength(FINISHED_HIGHLIGHT_LIMIT + 4);
    expect(highlights[0]?.id).toBe(`pkg-${FINISHED_HIGHLIGHT_LIMIT + 3}`);
  });

  it("uses the newest package timestamp when progress predates an update", () => {
    const oldProgressNewUpdate = finishedPackage("pkg-updated", new Date(Date.UTC(2026, 5, 4, 10)).toISOString());
    oldProgressNewUpdate.updated_at = new Date(Date.UTC(2026, 5, 4, 13)).toISOString();
    const progressOnly = finishedPackage("pkg-progress", new Date(Date.UTC(2026, 5, 4, 12)).toISOString());

    const highlights = recentFinishedHighlights([oldProgressNewUpdate, progressOnly], [], [], new Map(), null);

    expect(highlights.map((highlight) => highlight.id)).toEqual(["pkg-updated", "pkg-progress"]);
  });

  it("does not apply the finished package cap to request highlights", () => {
    const request = finishedRequest("wr-finished", new Date(Date.UTC(2026, 5, 4, 13)).toISOString());
    const packages = [
      finishedPackage("pkg-old", new Date(Date.UTC(2026, 5, 4, 11)).toISOString()),
      finishedPackage("pkg-new", new Date(Date.UTC(2026, 5, 4, 12)).toISOString()),
    ];
    const detail = { work_request: request, planned_slices: [] } satisfies WorkRequestDetail;

    const highlights = recentFinishedHighlights(packages, [request], [detail], new Map(), 1);

    expect(highlights.map((highlight) => highlight.id)).toEqual(["wr-finished", "pkg-new"]);
  });

  it("builds blocker list items from package-card active blocker details", () => {
    const pkg: WorkPackageCard = {
      id: "pkg-blocked",
      title: "Blocked package",
      status: "blocked",
      active_blocker_count: 1,
      active_blockers: [{ id: "blocker-1", active: true, summary: "Needs scope approval", body: "Review asked for one more file." }],
    };

    const items = activeBlockerItems([pkg]);

    expect(items).toEqual([
      expect.objectContaining({
        id: "active_blocking_edge:pkg-blocked:blocker-1",
        title: "Needs scope approval",
        detail: "Review asked for one more file.",
        selection: expect.objectContaining({
          kind: "blocker",
          blocker: expect.objectContaining({ blocker_id: "blocker-1", work_package_id: "pkg-blocked" }),
          pkg,
        }),
      }),
    ]);
  });

  it("keeps blocker list item ids unique across packages", () => {
    const packages: WorkPackageCard[] = [
      {
        id: "pkg-a",
        title: "Package A",
        status: "blocked",
        active_blocker_count: 1,
        active_blockers: [{ id: "blocker-1", active: true, summary: "Shared blocker id" }],
      },
      {
        id: "pkg-b",
        title: "Package B",
        status: "blocked",
        active_blocker_count: 1,
        active_blockers: [{ id: "blocker-1", active: true, summary: "Shared blocker id" }],
      },
    ];

    const ids = activeBlockerItems(packages).map((item) => item.id);

    expect(ids).toEqual(["active_blocking_edge:pkg-a:blocker-1", "active_blocking_edge:pkg-b:blocker-1"]);
  });

  it("hides zero plan and attention plates from repo summaries", () => {
    const repo = repoSummary({ guidanceCount: 0, blockerCount: 0 });
    const html = renderToStaticMarkup(<RepoSummaryStrip repo={repo} categoryCounts={{ requests: 1, planNodes: 0, slices: 2 }} />);

    expect(html).toContain("Requests");
    expect(html).toContain("Slices");
    expect(html).not.toContain("Plan Nodes");
    expect(html).not.toContain("Guidance Needed");
    expect(html).not.toContain("Active Blockers");
  });

  it("shows non-zero plan and attention plates in repo summaries", () => {
    const repo = repoSummary({ guidanceCount: 1, blockerCount: 2 });
    const html = renderToStaticMarkup(<RepoSummaryStrip repo={repo} categoryCounts={{ requests: 1, planNodes: 3, slices: 2 }} />);

    expect(html).toContain("Plan Nodes");
    expect(html).toContain("Guidance Needed");
    expect(html).toContain("Active Blockers");
  });
});

function finishedPackage(id: string, updatedAt: string): WorkPackageCard {
  return {
    id,
    title: id,
    repo: "symphony-plus-plus",
    repo_display: "symphony-plus-plus",
    status: "merged",
    latest_progress_at: updatedAt,
    updated_at: updatedAt,
  };
}

function finishedRequest(id: string, updatedAt: string): WorkRequestCard {
  return {
    id,
    title: id,
    repo: "symphony-plus-plus",
    repo_display: "symphony-plus-plus",
    status: "completed",
    updated_at: updatedAt,
  };
}

function repoSummary(overrides: Partial<RepoSummary>): RepoSummary {
  return {
    active: 0,
    baseBranches: ["main"],
    blockerCount: 0,
    finished: 0,
    guidanceCount: 0,
    implementing: 0,
    packages: [],
    repo: "symphony-plus-plus",
    repoKey: "symphony-plus-plus",
    requested: 0,
    requests: [],
    ...overrides,
  };
}
