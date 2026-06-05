import type { ClarificationQuestion, DashboardPayload, GuidanceItem, SoloSession, WorkPackageCard, WorkRequestCard, WorkRequestDetail } from "@/types/dashboard";
import { operationalLabel, packageLane, sliceLane, sliceOperationalState, workRequestLane } from "@/lib/operational-state";
import { sortedCopy } from "@/lib/collections";
import type { BlockerItem, FinishedHighlight } from "./dashboard-state";
import type { CardDetailSelection } from "./runtime";
import { stripMarkdown } from "./dashboard-text";
import { operatorApiUrl } from "./runtime";
import type { RepoIdentitySource } from "./dashboard-persistence";
import { addBranch, repoDisplayName, repoIdentityKey, repoRemoteName } from "./dashboard-persistence";
import { packageHasActiveBlocker } from "./workstream-data";

export const FINISHED_HIGHLIGHT_LIMIT = 80;

export function dashboardContentFingerprint(payload: DashboardPayload | null) {
  if (!payload) return "null";

  const content = { ...payload } as Record<string, unknown>;
  delete content.generated_at;
  return JSON.stringify(content);
}

export type RepoSummary = {
  repoKey: string;
  repo: string;
  repoRemote?: string | null;
  baseBranches: string[];
  requested: number;
  active: number;
  implementing: number;
  finished: number;
  guidanceCount: number;
  blockerCount: number;
  packages: WorkPackageCard[];
  requests: WorkRequestCard[];
};

export function allPackages(dashboard: DashboardPayload | null): WorkPackageCard[] {
  const groups = dashboard?.board?.groups || {};
  return Object.values(groups).flat();
}

export function allGuidanceItems(dashboard: DashboardPayload | null): GuidanceItem[] {
  const guidance = (dashboard?.guidance_requests?.guidance_requests || []).map<GuidanceItem>((item) => ({
    source: "guidance",
    id: item.id,
    repo: repoDisplayName(item),
    repoKey: repoIdentityKey(item),
    repoRemote: repoRemoteName(item),
    title: item.decision_prompt?.tl_dr || item.summary || stripMarkdown(item.question) || item.id,
    packageId: item.work_package_id,
    prompt: item.decision_prompt,
    detail: item.decision_prompt?.details || item.context || item.question || "",
    guidance: item,
  }));

  const details = dashboard?.work_request_details || [];
  const clarifications = details.flatMap<GuidanceItem>((detail) => {
    const items: GuidanceItem[] = [];
    (detail.clarification_questions || []).forEach((question) => {
      if (question.status === "open") items.push(clarificationGuidanceItem(detail, question));
    });
    return items;
  });

  return [...guidance, ...clarifications];
}

export function clarificationGuidanceItem(detail: WorkRequestDetail, question: ClarificationQuestion): GuidanceItem {
  return {
    source: "clarification",
    id: question.id,
    repo: repoDisplayName(detail.work_request),
    repoKey: repoIdentityKey(detail.work_request),
    repoRemote: repoRemoteName(detail.work_request),
    title: question.decision_prompt?.tl_dr || stripMarkdown(question.question) || question.id,
    workRequestId: detail.work_request.id,
    prompt: question.decision_prompt,
    detail: question.decision_prompt?.details || question.why_needed || question.question || "",
    question,
    request: detail.work_request,
  };
}

export function activeBlockerItems(packages: WorkPackageCard[], packageSelections: ReadonlyMap<string, CardDetailSelection> = new Map()): BlockerItem[] {
  return packages.reduce<BlockerItem[]>((items, pkg) => {
    const operational = pkg.operational_state || null;
    if (packageHasActiveBlocker(pkg)) {
      items.push({
        id: pkg.id,
        title: pkg.title || pkg.id,
        repo: repoDisplayName(pkg),
        status: operational?.key || pkg.status,
        blockerCount: Math.max(pkg.active_blocker_count || 0, pkg.status === "blocked" || operational?.key === "blocked" ? 1 : 0),
        detail:
          operational?.reason ||
          (pkg.status === "blocked"
            ? "This work package is blocked and needs another condition or dependency cleared before it can move."
            : "This work package has active blockers attached to its execution path."),
        selection: packageSelections.get(pkg.id) ?? { kind: "package", pkg },
      });
    }

    return items;
  }, []);
}

export function recentFinishedHighlights(
  packages: WorkPackageCard[],
  requests: WorkRequestCard[],
  details: WorkRequestDetail[],
  packageSelections: ReadonlyMap<string, CardDetailSelection> = new Map(),
  limit: number | null = FINISHED_HIGHLIGHT_LIMIT,
): FinishedHighlight[] {
  const detailByRequestId = new Map(details.map((detail) => [detail.work_request.id, detail]));
  const packageById = new Map(packages.map((pkg) => [pkg.id, pkg]));

  const packageHighlights = packages.reduce<FinishedHighlight[]>((items, pkg) => {
    if (packageLane(pkg) === "finished") {
      const operational = pkg.operational_state || null;
      items.push({
        id: pkg.id,
        title: pkg.title || pkg.id,
        repo: repoDisplayName(pkg),
        kind: "Work Package",
        state: operationalLabel(operational, pkg.status),
        at: latestTimestamp(pkg.latest_progress_at, pkg.updated_at, pkg.inserted_at),
        selection: packageSelections.get(pkg.id) ?? { kind: "package", pkg },
      });
    }

    return items;
  }, []);
  const visiblePackageHighlights = limit === null ? packageHighlights : sortedCopy(packageHighlights, compareHighlightRecency).slice(0, limit);

  const requestHighlights = requests.reduce<FinishedHighlight[]>((items, request) => {
    if (workRequestLane(request) === "finished") {
      const detail = detailByRequestId.get(request.id);
      if (!detail) return items;

      const operational = request.operational_state || null;
      items.push({
        id: request.id,
        title: request.title || request.id,
        repo: repoDisplayName(request),
        kind: "Request",
        state: operationalLabel(operational, request.status),
        at: request.updated_at || request.inserted_at,
        selection: { kind: "request", detail },
      });
    }

    return items;
  }, []);

  const sliceHighlights = details.flatMap<FinishedHighlight>((detail) => {
    const items: FinishedHighlight[] = [];
    (detail.planned_slices || []).forEach((slice) => {
      const pkg = slice.work_package_id ? packageById.get(slice.work_package_id) : undefined;

      if (sliceLane(slice, pkg) === "finished") {
        const operational = sliceOperationalState(slice, pkg);
        items.push({
          id: slice.id,
          title: slice.title || slice.id,
          repo: repoDisplayName(detail.work_request),
          kind: "Slice",
          state: operationalLabel(operational, slice.work_package_status || slice.status),
          at: detail.work_request.updated_at || detail.work_request.inserted_at,
          selection: pkg ? { kind: "package", pkg, detail, slice } : { kind: "slice", detail, slice },
        });
      }
    });
    return items;
  });

  return sortedCopy([...visiblePackageHighlights, ...requestHighlights, ...sliceHighlights], compareHighlightRecency);
}

function compareHighlightRecency(a: FinishedHighlight, b: FinishedHighlight) {
  const left = a.at ? Date.parse(a.at) : 0;
  const right = b.at ? Date.parse(b.at) : 0;
  return right - left;
}

function latestTimestamp(...values: (string | null | undefined)[]) {
  return sortedCopy(values.filter((value): value is string => Boolean(value)), (a, b) => Date.parse(b) - Date.parse(a))[0] ?? null;
}

export function repoSummaries(
  packages: WorkPackageCard[],
  requests: WorkRequestCard[],
  guidance: GuidanceItem[],
  sessions: SoloSession[],
  details: WorkRequestDetail[],
): RepoSummary[] {
  const repos = new Map<string, RepoSummary>();
  const packageById = new Map(packages.map((pkg) => [pkg.id, pkg]));

  const ensure = (identity: RepoIdentitySource): RepoSummary => {
    const repoKey = repoIdentityKey(identity);
    const repo = repoDisplayName(identity);
    if (!repos.has(repoKey)) {
      repos.set(repoKey, {
        repoKey,
        repo,
        repoRemote: repoRemoteName(identity),
        baseBranches: [],
        requested: 0,
        active: 0,
        implementing: 0,
        finished: 0,
        guidanceCount: 0,
        blockerCount: 0,
        packages: [],
        requests: [],
      });
    }
    const summary = repos.get(repoKey)!;
    summary.repoRemote ||= repoRemoteName(identity);
    return summary;
  };

  requests.forEach((request) => {
    const summary = ensure(request);
    summary.requests.push(request);
    addBranch(summary, request.base_branch);
  });

  packages.forEach((pkg) => {
    const summary = ensure(pkg);
    summary.packages.push(pkg);
    addBranch(summary, pkg.base_branch);
  });

  sessions.forEach((session) => {
    const summary = ensure(session);
    addBranch(summary, session.base_branch);
  });

  guidance.forEach((item) => {
    ensure({ repo: item.repo, repo_key: item.repoKey, repo_display: item.repo, repo_remote: item.repoRemote }).guidanceCount += 1;
  });

  repos.forEach((summary) => {
    summary.requests.forEach((request) => {
      const lane = workRequestLane(request);
      if (lane === "requested") summary.requested += 1;
      if (lane === "slices") summary.active += 1;
    });

    summary.packages.forEach((pkg) => {
      const lane = packageLane(pkg);
      if (lane === "slices") summary.active += 1;
      if (lane === "implementing") summary.implementing += 1;
      if (lane === "finished") summary.finished += 1;
      if (packageHasActiveBlocker(pkg)) summary.blockerCount += 1;
    });
  });

  details.forEach((detail) => {
    const summary = ensure(detail.work_request);
    (detail.planned_slices || []).forEach((slice) => {
      const lane = sliceLane(slice, slice.work_package_id ? packageById.get(slice.work_package_id) : undefined);
      if (lane === "slices") summary.active += 1;
      if (lane === "implementing") summary.implementing += 1;
      if (lane === "finished") summary.finished += 1;
    });
  });

  return sortedCopy([...repos.values()], (a, b) => a.repo.localeCompare(b.repo));
}

export function guidanceAnswerUrl(item: GuidanceItem) {
  if (item.source === "guidance") {
    return operatorApiUrl(`/work-packages/${encodeURIComponent(item.packageId)}/guidance/${encodeURIComponent(item.id)}/answer`);
  }

  return operatorApiUrl(`/work-requests/${encodeURIComponent(item.workRequestId)}/questions/${encodeURIComponent(item.id)}/answer`);
}
