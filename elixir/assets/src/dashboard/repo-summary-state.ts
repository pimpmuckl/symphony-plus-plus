import type { RepoSummary } from "./dashboard-data";
import type { WorkstreamCategoryCounts } from "./dashboard-state";
import type { RepoSummaryPlateTone } from "./runtime";

export type RepoSummaryMetricKey = "requests" | "planNodes" | "slices" | "guidance" | "blockers";

export const REPO_SUMMARY_METRIC_KEYS: RepoSummaryMetricKey[] = ["requests", "planNodes", "slices", "guidance", "blockers"];

export const REPO_SUMMARY_PLATE_WIDTH_VAR_BY_KEY: Record<RepoSummaryMetricKey, string> = {
  requests: "--v3-repo-plate-requests-width",
  planNodes: "--v3-repo-plate-plan-nodes-width",
  slices: "--v3-repo-plate-slices-width",
  guidance: "--v3-repo-plate-guidance-width",
  blockers: "--v3-repo-plate-blockers-width",
};

export type RepoSummaryMetric = {
  key: RepoSummaryMetricKey;
  label: string;
  value: number;
  tone: RepoSummaryPlateTone;
  group: "progress" | "attention";
};

export function repoSummaryMetrics(repo: RepoSummary, categoryCounts: WorkstreamCategoryCounts): RepoSummaryMetric[] {
  return [
    { key: "requests", label: "Requests", value: categoryCounts.requests, tone: "requested", group: "progress" },
    { key: "planNodes", label: "Plan Nodes", value: categoryCounts.planNodes, tone: "implementing", group: "progress" },
    { key: "slices", label: "Slices", value: categoryCounts.slices, tone: "active", group: "progress" },
    { key: "guidance", label: "Guidance Needed", value: repo.guidanceCount, tone: "guidance", group: "attention" },
    { key: "blockers", label: "Active Blockers", value: repo.blockerCount, tone: "blocker", group: "attention" },
  ];
}

export function repoSummaryPlateLabels(repo: RepoSummary, categoryCounts: WorkstreamCategoryCounts) {
  return repoSummaryMetrics(repo, categoryCounts).map(repoSummaryPlateLabel);
}

export function repoSummaryPlateLabel(metric: RepoSummaryMetric) {
  return `${metric.value} ${metric.label}`;
}
