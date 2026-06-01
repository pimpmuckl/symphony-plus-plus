import type { ContextComment, PackageAlertIndicator, PackageOperationalAttention, PlannedSlice, WorkPackageCard, WorkPackageDetailPayload, WorkRequestDetail } from "@/types/dashboard";
import { DetailDisclosure } from "@/components/dashboard/detail-layout";
import { attentionTone, operationalLabel } from "@/lib/operational-state";
import { cn } from "@/lib/utils";
import { formatStatus, statusLabel } from "@/lib/status-labels";
import { packageReviewLabel, planProgressLabel } from "@/lib/review-signals";
import { sortedCopy } from "@/lib/collections";
import { CommentStats, DashboardRuntimeConfig, PackageLineageProjection } from "./runtime";
import { formatDate } from "./dashboard-persistence";
import { firstParagraph } from "./dashboard-text";
import { sliceSuccessorLabel, sortableTime } from "./workstream-data";

export function RecentDecisionsDisclosure({ detail }: { detail: WorkRequestDetail }) {
  const decisions = latestDecisionLogs(detail);

  return (
    <DetailDisclosure title="Recent Decisions" meta={decisions.length > 0 ? `${decisions.length} recorded` : "None recorded"}>
      {decisions.length > 0 ? (
        <DetailActivityList
          items={decisions.slice(0, 3).map((decision) => ({
            title: decision.decision || decision.scope_impact || "Decision",
            body: decision.rationale,
            at: decision.created_at || decision.inserted_at,
          }))}
        />
      ) : (
        <p className="text-sm text-muted-foreground">No decisions recorded for this request yet.</p>
      )}
    </DetailDisclosure>
  );
}

export function DetailActivityList({ items }: { items: Array<{ title?: string | null; body?: string | null; at?: string | null }> }) {
  const rows = detailActivityRows(items);

  return (
    <div className="grid gap-2">
      {rows.map(({ item, key }) => (
        <div key={key} className="detail-list-item">
          <div className="flex min-w-0 items-start justify-between gap-3">
            <span className="min-w-0 text-sm font-medium">{item.title || "Update"}</span>
            {item.at ? <span className="shrink-0 text-xs text-muted-foreground">{formatDate(item.at)}</span> : null}
          </div>
          {item.body ? <p className="mt-1 line-clamp-2 text-xs text-muted-foreground">{item.body}</p> : null}
        </div>
      ))}
    </div>
  );
}

export function detailActivityRows(items: Array<{ title?: string | null; body?: string | null; at?: string | null }>) {
  const seen = new Map<string, number>();

  return items.slice(0, 3).map((item) => {
    const baseKey = detailActivityKey(item);
    const occurrence = seen.get(baseKey) || 0;
    seen.set(baseKey, occurrence + 1);
    return { item, key: occurrence === 0 ? baseKey : `${baseKey}:${occurrence}` };
  });
}

export function detailActivityKey(item: { title?: string | null; body?: string | null; at?: string | null }) {
  return `activity:${hashText([item.title, item.body, item.at].filter(Boolean).join("|"))}`;
}

export function DetailAttentionList({ items }: { items: PackageOperationalAttention[] }) {
  const visibleItems = items.slice(0, 3);

  return (
    <div className="grid gap-2">
      {visibleItems.map((item) => (
        <div key={item.key || item.label || item.reason} className={cn("detail-list-item border-l-4", attentionBorderClassName(item))}>
          <div className="flex min-w-0 items-center justify-between gap-3">
            <span className="min-w-0 text-sm font-medium">{item.label || formatStatus(item.key)}</span>
            {item.missing?.length ? <span className="shrink-0 text-xs text-muted-foreground">{item.missing.length} missing</span> : null}
          </div>
          {item.reason ? <p className="mt-1 text-xs text-muted-foreground">{item.reason}</p> : null}
        </div>
      ))}
      {items.length > visibleItems.length ? <p className="text-xs text-muted-foreground">+{items.length - visibleItems.length} more attention item{items.length - visibleItems.length === 1 ? "" : "s"}</p> : null}
    </div>
  );
}

export function LineageDisclosure({ lineage }: { lineage: WorkPackageCard["lineage"] }) {
  const entries = lineageDetailRows(lineage);
  const attentionItems = lineage?.cleanup_attention || [];

  return (
    <DetailDisclosure title="Operational Lineage" meta={lineageSummary(lineage)} defaultOpen={Boolean(lineage?.unavailable || attentionItems.length)}>
      <div className="grid gap-3">
        {lineage?.unavailable ? <p className="text-sm text-muted-foreground">Lineage could not be read{lineage.error ? `: ${lineage.error}` : "."}</p> : null}
        {entries.length > 0 ? (
          <DetailActivityList
            items={entries.map((entry) => ({
              title: entry.title,
              body: entry.body,
              at: entry.at,
            }))}
          />
        ) : lineage?.unavailable ? null : (
          <p className="text-sm text-muted-foreground">No lineage relationships recorded.</p>
        )}
        {attentionItems.length > 0 ? <DetailAttentionList items={attentionItems} /> : null}
      </div>
    </DetailDisclosure>
  );
}

export function hashText(text: string) {
  let hash = 0;
  for (let index = 0; index < text.length; index += 1) {
    hash = (hash * 31 + text.charCodeAt(index)) | 0;
  }
  return Math.abs(hash).toString(36);
}

export function requestOpenQuestions(detail: WorkRequestDetail) {
  return (detail.clarification_questions || []).filter((question) => question.status === "open");
}

export function requestSliceCounts(detail: WorkRequestDetail) {
  const summary = detail.summary || {};
  const planned = summary.planned_slice_count ?? detail.work_request.planned_slice_count ?? 0;
  const approved = summary.approved_slice_count ?? detail.work_request.approved_slice_count ?? 0;
  const dispatched = summary.dispatched_slice_count ?? detail.work_request.dispatched_slice_count ?? 0;
  const skipped = summary.skipped_slice_count ?? detail.work_request.skipped_slice_count ?? 0;
  const total = Math.max(detail.planned_slices?.length || 0, planned + approved + dispatched + skipped);

  return { planned, approved, dispatched, skipped, total };
}

export function commentStatLabel(openCount?: number | null, totalCount?: number | null) {
  const open = openCount ?? 0;
  const total = totalCount ?? open;
  return open > 0 ? `${open} open / ${total} total` : String(total);
}

export function commentStats(comments: ContextComment[]): CommentStats {
  const commentCount = comments.length;
  const openCommentCount = comments.filter((comment) => comment.status !== "resolved").length;
  return { comment_count: commentCount, open_comment_count: openCommentCount };
}

export function serverCommentStats(counts: { comment_count?: number | null; open_comment_count?: number | null } | null | undefined, fallbackComments: ContextComment[]): CommentStats {
  const fallbackStats = commentStats(fallbackComments);

  return {
    comment_count: counts?.comment_count ?? fallbackStats.comment_count,
    open_comment_count: counts?.open_comment_count ?? fallbackStats.open_comment_count,
  };
}

export function targetCommentStats(
  counts: { comment_count?: number | null; open_comment_count?: number | null } | null | undefined,
  initialComments: ContextComment[],
  currentComments: ContextComment[],
): CommentStats {
  const base = serverCommentStats(counts, initialComments);
  const initialStats = commentStats(initialComments);
  const currentStats = commentStats(currentComments);

  return {
    comment_count: Math.max(0, base.comment_count + currentStats.comment_count - initialStats.comment_count),
    open_comment_count: Math.max(0, base.open_comment_count + currentStats.open_comment_count - initialStats.open_comment_count),
  };
}

export function requestCommentStats(detail: WorkRequestDetail, requestComments: ContextComment[]): CommentStats {
  const sliceComments = (detail.planned_slices || []).flatMap((slice) => slice.comments || []);
  const base = serverCommentStats(detail.summary || detail.work_request, [...(detail.comments || []), ...sliceComments]);
  const initialRequestStats = commentStats(detail.comments || []);
  const currentRequestStats = commentStats(requestComments);

  return {
    comment_count: Math.max(0, base.comment_count + currentRequestStats.comment_count - initialRequestStats.comment_count),
    open_comment_count: Math.max(0, base.open_comment_count + currentRequestStats.open_comment_count - initialRequestStats.open_comment_count),
  };
}

export function canMutateDashboardComments(config?: DashboardRuntimeConfig) {
  return config?.operatorMode === true;
}

export function requestProgressText(detail: WorkRequestDetail) {
  const request = detail.work_request;
  const operational = request.operational_state || null;
  const questions = requestOpenQuestions(detail);
  const slices = requestSliceCounts(detail);

  if (questions.length > 0) {
    return `${questions.length} open human question${questions.length === 1 ? "" : "s"} before the architect can continue.`;
  }

  if (request.status === "sliced" || slices.total > 0) {
    const state = operational?.key && operational.key !== request.status ? `${operational.label || statusLabel(operational.key)}. ` : "";
    return `${state}${slices.total} slice${slices.total === 1 ? "" : "s"} recorded: ${slices.approved} approved, ${slices.dispatched} dispatched, ${slices.skipped} skipped.`;
  }

  if (request.status === "ready_for_slicing") {
    return "Ready for an architecture agent to slice into work packages.";
  }

  if (request.status === "clarifying" || request.status === "ready_for_clarification") {
    return "Architecture intake is still clarifying the request.";
  }

  return `Current request state: ${formatStatus(request.status)}.`;
}

export function sliceProgressText(slice: PlannedSlice, pkg?: WorkPackageCard) {
  if (pkg) {
    const progress = planProgressLabel(pkg.plan);
    const label = operationalLabel(pkg.operational_state || null, pkg.status);
    return progress ? `Linked work package is ${label} with ${progress.toLowerCase()}.` : `Linked work package is ${label}.`;
  }

  if (slice.status === "approved") {
    return "Approved and ready to dispatch into a worker-owned package.";
  }

  if (slice.status === "planned") {
    return "Planned by architecture; not dispatched yet.";
  }

  if (slice.status === "skipped") {
    return "Skipped by architecture and not expected to move forward.";
  }

  return `Current slice state: ${formatStatus(slice.status)}.`;
}

export function sliceDeliverySummary(slice: PlannedSlice, operational: WorkPackageCard["operational_state"]) {
  if (operational?.key === "needs_closeout") {
    const reason = operational.attention_items?.[0]?.reason || operational.reason;
    return reason || "Delivery closeout is not recorded.";
  }

  if (slice.delivery?.outcome === "completed_no_pr") {
    return slice.delivery.no_pr_evidence || "Completed without PR.";
  }

  if (slice.delivery?.outcome === "superseded") {
    const successor = sliceSuccessorLabel(slice);
    if (slice.delivery.superseded_reason) return slice.delivery.superseded_reason;
    return successor ? `Successor: ${successor}.` : "Superseded.";
  }

  if (slice.delivery?.outcome === "abandoned") {
    return slice.delivery.abandoned_rationale || "Abandoned.";
  }

  if (slice.delivery?.outcome === "pr_merged") {
    return slice.delivery.pr_url || slice.delivery.pr_repository ? "Merged PR delivery is recorded." : "Merged delivery is recorded.";
  }

  return null;
}

export function sliceDeliveryFacts(slice: PlannedSlice): Array<[string, string | null | undefined]> {
  const facts: Array<[string, string | null | undefined]> = [];

  if (slice.delivery?.outcome) facts.push(["Outcome", statusLabel(slice.delivery.outcome)]);
  if (slice.delivery?.pr_url) facts.push(["PR", slice.delivery.pr_url]);
  if (slice.delivery?.merge_commit_sha) facts.push(["Merge Commit", slice.delivery.merge_commit_sha]);
  if (slice.delivery?.recorded_by) facts.push(["Recorded By", slice.delivery.recorded_by]);
  if (slice.delivery?.recorded_at) facts.push(["Recorded", detailDate(slice.delivery.recorded_at)]);
  if (slice.delivery?.abandoned_rationale) facts.push(["Rationale", slice.delivery.abandoned_rationale]);
  if (slice.successor?.planned_slice_id || slice.delivery?.successor_planned_slice_id) {
    facts.push(["Successor Slice", slice.successor?.planned_slice_id || slice.delivery?.successor_planned_slice_id]);
  }
  if (slice.successor?.work_package_id || slice.delivery?.successor_work_package_id) {
    facts.push(["Successor Package", slice.successor?.work_package_id || slice.delivery?.successor_work_package_id]);
  }
  if (slice.attention_reason_codes?.length) facts.push(["Reason Codes", slice.attention_reason_codes.map(statusLabel).join(", ")]);

  return facts;
}

export function latestPackageProgress(payload: WorkPackageDetailPayload | null) {
  return sortedCopy(payload?.progress || [], (left, right) => {
    const sequenceDelta = (right.sequence || 0) - (left.sequence || 0);
    if (sequenceDelta !== 0) return sequenceDelta;
    return sortableTime(right.created_at) - sortableTime(left.created_at);
  });
}

export function planSummaryText(plan?: WorkPackageCard["plan"] | null) {
  return planProgressLabel(plan) || "No plan";
}

export function packageRuntimeText(summary: WorkPackageDetailPayload["summary"] | undefined, pkg: WorkPackageCard) {
  if (summary?.stale_agent_run_count) return `${summary.stale_agent_run_count} stale`;
  if (summary?.failed_agent_run_count) return `${summary.failed_agent_run_count} failed`;
  if (summary?.active_agent_run_count) return `${summary.active_agent_run_count} active`;
  if (summary?.queued_agent_run_count) return `${summary.queued_agent_run_count} queued`;
  if (pkg.active_agent_run?.stale) return "Stale run";
  if (pkg.active_agent_run?.runtime_state === "queued") return "Queued";
  if (pkg.active_agent_run || (typeof pkg.runtime?.active_count === "number" && pkg.runtime.active_count > 0)) return "Active";
  return "No active run";
}

export function packagePurpose(pkg: WorkPackageCard | NonNullable<WorkPackageDetailPayload["work_package"]>) {
  const richPackage = pkg as NonNullable<WorkPackageDetailPayload["work_package"]>;
  return firstParagraph(richPackage.engineering_scope) || firstParagraph(richPackage.product_description) || pkg.kind || "No package description has been recorded yet.";
}

export function packageOperationalFallbackText(pkg: WorkPackageCard) {
  const review = packageReviewLabel(pkg);
  if (review) return `Review signal: ${review}.`;

  const progress = planProgressLabel(pkg.plan);
  if (progress) return `Plan is ${progress.toLowerCase()}.`;

  return `Raw lifecycle status is ${statusLabel(pkg.status)}.`;
}

export function attentionBorderClassName(attention: PackageOperationalAttention) {
  switch (attentionTone(attention)) {
    case "danger":
      return "border-l-rose-400";
    case "warning":
      return "border-l-amber-400";
    case "success":
      return "border-l-emerald-400";
    case "info":
      return "border-l-sky-400";
    default:
      return "border-l-slate-300";
  }
}

export function activeAlertLabels(alerts: PackageAlertIndicator[]) {
  return alerts.reduce<string[]>((items, item) => {
    if (item.active !== false) items.push(item.detail || item.label || item.type || "Alert");
    return items;
  }, []);
}

export function lineageHasSignal(lineage?: WorkPackageCard["lineage"] | null) {
  if (!lineage) return false;
  const rows = lineageDetailRows(lineage);
  return (
    Boolean(lineage.unavailable) ||
    (lineage.cleanup_attention || []).length > 0 ||
    rows.length > 0 ||
    Boolean(lineage.oracle_status?.preserved || lineage.oracle_status?.has_oracle)
  );
}

export function lineageSummary(lineage?: WorkPackageCard["lineage"] | null) {
  if (!lineage) return "None recorded";
  if (lineage.unavailable) return lineage.error ? `Unavailable: ${lineage.error}` : "Unavailable";

  const rows = lineageDetailRows(lineage);
  if (rows.length === 0) return "None recorded";

  const parts = [
    lineage.recut_as?.length ? `${lineage.recut_as.length} recut` : null,
    lineage.superseded_by?.length ? `${lineage.superseded_by.length} superseded` : null,
    lineage.original_work?.length ? `${lineage.original_work.length} original` : null,
    lineage.oracle_for?.length || lineage.oracle_work?.length ? "oracle" : null,
  ].filter(Boolean);

  return parts.length > 0 ? parts.join(" / ") : `${rows.length} relationship${rows.length === 1 ? "" : "s"}`;
}

export function lineageDetailRows(lineage?: WorkPackageCard["lineage"] | null) {
  if (!lineage) return [];
  const explicitSuccessorKeys = new Set([...(lineage.recut_as || []), ...(lineage.superseded_by || [])].map(lineageEntryKey));
  const genericSuccessors = (lineage.successor_work || []).filter((entry) => !explicitSuccessorKeys.has(lineageEntryKey(entry)));

  return [
    ...lineageEntries("Recut as", lineage.recut_as),
    ...lineageEntries("Superseded by", lineage.superseded_by),
    ...lineageEntries("Successor work", genericSuccessors),
    ...lineageEntries("Original work", lineage.original_work),
    ...lineageEntries("Oracle for", lineage.oracle_for),
    ...lineageEntries("Oracle work", lineage.oracle_work),
  ];
}

export function lineageEntryKey(entry: NonNullable<PackageLineageProjection["successor_work"]>[number]) {
  return [entry.relationship, entry.work_package_id, entry.target_work_package_id, entry.source_work_package_id, entry.event_id].filter(Boolean).join(":");
}

export function lineageEntries(label: string, entries?: PackageLineageProjection["successor_work"]) {
  return (entries || []).map((entry) => ({
    title: `${label} ${entry.work_package_id || entry.target_work_package_id || entry.source_work_package_id || "work package"}`,
    body: lineageEntryBody(entry),
    at: entry.recorded_at,
  }));
}

export function lineageEntryBody(entry: NonNullable<PackageLineageProjection["successor_work"]>[number]) {
  const status = entry.status || entry.target_status || entry.source_status;
  const branch = entry.branch || entry.target_branch || entry.source_branch;
  const details = [status ? statusLabel(status) : null, branch, entry.oracle_preserved ? "oracle preserved" : null, entry.reason].filter(Boolean);
  return details.join(" / ");
}

export function latestDecisionLogs(detail: WorkRequestDetail) {
  return sortedCopy(detail.decision_logs || [], (left, right) => {
    const sequenceDelta = (right.sequence || 0) - (left.sequence || 0);
    if (sequenceDelta !== 0) return sequenceDelta;
    return sortableTime(right.created_at || right.inserted_at) - sortableTime(left.created_at || left.inserted_at);
  });
}

export function detailDate(value?: string | null) {
  return value ? formatDate(value) : "Not recorded";
}

export function EmptyPanel({ title, compact = false }: { title: string; compact?: boolean }) {
  return (
    <div
      className={`dashboard-glass-surface flex items-center justify-center rounded-lg border border-dashed bg-muted/30 text-sm text-muted-foreground ${compact ? "min-h-[96px]" : "min-h-[180px]"}`}
    >
      {title}
    </div>
  );
}
