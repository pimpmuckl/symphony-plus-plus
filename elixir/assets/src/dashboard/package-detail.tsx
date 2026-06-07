import { Badge } from "@/components/ui/badge";
import { DetailDisclosure, DetailFacts, DetailHeader, DetailList, DetailSection, DetailStatGrid } from "@/components/dashboard/detail-layout";
import { MarkdownBlock } from "@/components/dashboard/markdown-block";
import type { PlannedSlice, WorkPackageCard, WorkPackageDetailPayload, WorkRequestDetail } from "@/types/dashboard";
import { isFinishedBoardStatus, operationalBadgeVariant, operationalLabel, sliceOperationalState } from "@/lib/operational-state";
import { reviewLaneLabel } from "@/lib/review-signals";
import { statusLabel } from "@/lib/status-labels";
import { useCallback, useReducer } from "react";
import { CardDetailSelection, ResolveContextComment, SubmitContextComment, WorkPackageArchiveMutation, WorkPackageStateAction, WorkPackageStateMutation } from "./runtime";
import { CommentsPanel, useSyncedComments } from "./comments-panel";
import { packageBlockerCopyText } from "./detail-copy";
import { DetailAttentionList, RecentDecisionsDisclosure } from "./detail-extras";
import { commentStatLabel, detailDate, latestPackageProgress, packageOperationalFallbackText, planSummaryText, sliceDeliveryFacts, sliceDeliverySummary, sliceProgressText, targetCommentStats } from "./detail-utils";
import { initialPackageDetailUiState, packageDetailUiReducer } from "./dashboard-state";
import { repoDisplayName } from "./dashboard-persistence";
import { PackageDetailBody, PackageDetailDialogs, type PackageDetailComments, type PackageDetailControls, type PackageDetailDialogControls, type PackageDetailPackage, type PackageDetailStatus } from "./package-detail-presentation";

export function SliceDetailContent({
  detail,
  slice,
  pkg,
  onSubmitComment,
  onResolveComment,
  canMutateComments,
}: {
  detail: WorkRequestDetail;
  slice: PlannedSlice;
  pkg?: WorkPackageCard;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
  canMutateComments: boolean;
}) {
  const [sliceComments, setSliceComments] = useSyncedComments(slice.comments || []);
  const status = slice.work_package_status || slice.status;
  const operational = sliceOperationalState(slice, pkg);
  const blockerCount = Math.max(pkg?.active_blocker_count || 0, pkg?.status === "blocked" || operational?.key === "blocked" ? 1 : 0);
  const reviewLanes = slice.review_lanes || [];
  const attentionItems = operational?.attention_items || [];
  const currentCommentStats = targetCommentStats(slice, slice.comments || [], sliceComments);
  const deliveryFacts = sliceDeliveryFacts(slice);
  const deliverySummary = sliceDeliverySummary(slice, operational);
  const deliveryMarkdown = sliceDeliveryMarkdown(slice);

  return (
    <>
      <DetailHeader
        title={slice.title || pkg?.title || slice.id}
        eyebrow={`${repoDisplayName(detail.work_request)} / ${detail.work_request.title || detail.work_request.id}`}
        badge={<Badge variant={operationalBadgeVariant(operational, status)}>{operationalLabel(operational, status)}</Badge>}
      />
      <div className="detail-modal-reveal-body grid gap-4">
        <DetailStatGrid
          stats={[
            { label: "State", value: operationalLabel(operational, status) },
            { label: "Package", value: pkg ? operationalLabel(pkg.operational_state || null, pkg.status) : "Not dispatched" },
            { label: "Review", value: reviewLanes.length > 0 ? reviewLanes.map(reviewLaneLabel).join(", ") : "Not recorded" },
            { label: "Blockers", value: String(blockerCount) },
            { label: "Comments", value: commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count) },
            { label: "Updated", value: detailDate(slice.updated_at || slice.dispatched_at || slice.inserted_at) },
          ]}
        />
        <DetailSection title="Slice Goal">
          <MarkdownBlock value={slice.goal} empty={pkg?.kind || "No slice goal has been recorded yet."} />
        </DetailSection>
        <DetailSection title="Progress">
          <div className="grid gap-2">
            <p>{operational?.reason || sliceProgressText(slice, pkg)}</p>
            {attentionItems.length > 0 ? <DetailAttentionList items={attentionItems} /> : null}
          </div>
        </DetailSection>
        {deliverySummary || deliveryFacts.length > 0 ? (
          <DetailDisclosure title="Delivery" meta={slice.delivery?.outcome ? statusLabel(slice.delivery.outcome) : operationalLabel(operational, status)}>
            {deliveryMarkdown ? (
              <MarkdownDetail label={deliveryMarkdown.label} value={deliveryMarkdown.value} />
            ) : deliverySummary ? (
              <MarkdownBlock className="mb-3 text-sm" value={deliverySummary} />
            ) : null}
            <DetailFacts facts={deliveryFacts} />
          </DetailDisclosure>
        ) : null}
        <DetailSection title="Blocked By">
          {blockerCount > 0 ? (
            <p>{blockerCount} active blocker{blockerCount === 1 ? "" : "s"} on the linked work package.</p>
          ) : (
            <p>No blocker surfaced for this slice.</p>
          )}
        </DetailSection>
        <DetailDisclosure title="Comments" meta={commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count)}>
          <CommentsPanel
            key={`planned_slice:${slice.id}`}
            target={{ target_kind: "planned_slice", target_id: slice.id }}
            comments={sliceComments}
            onCommentsChange={setSliceComments}
            onSubmitComment={onSubmitComment}
            onResolveComment={onResolveComment}
            canMutate={canMutateComments}
          />
        </DetailDisclosure>
        <RecentDecisionsDisclosure detail={detail} />
        <DetailDisclosure title="Details" meta="Branch, files, and acceptance">
          <DetailFacts
            facts={[
              ["Slice ID", slice.id],
              ["Work Package", slice.work_package_id || "Not dispatched"],
              ["Raw Lifecycle", statusLabel(slice.status)],
              ["Target Branch", slice.target_base_branch || detail.work_request.base_branch || "main"],
              ["Dispatched", detailDate(slice.dispatched_at)],
            ]}
          />
          <DetailList title="Acceptance" items={slice.acceptance_criteria || []} empty="No acceptance criteria recorded." />
          <DetailList title="Validation" items={slice.validation_steps || []} empty="No validation steps recorded." />
          <DetailList title="Owned paths" items={slice.owned_file_globs || []} empty="No owned path constraints recorded." />
          <DetailList title="Stop conditions" items={slice.stop_conditions || []} empty="No stop conditions recorded." />
        </DetailDisclosure>
      </div>
    </>
  );
}

export function PackageDetailContent({
  selection,
  detailPayload,
  loading,
  error,
  onChangeWorkPackageState,
  onArchiveWorkPackage,
  linkedWorkPackageIds,
  onSubmitComment,
  onResolveComment,
  canMutateComments,
}: {
  selection: Extract<CardDetailSelection, { kind: "package" }>;
  detailPayload: WorkPackageDetailPayload | null;
  loading: boolean;
  error: string | null;
  onChangeWorkPackageState: WorkPackageStateMutation;
  onArchiveWorkPackage: WorkPackageArchiveMutation;
  linkedWorkPackageIds: Set<string>;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
  canMutateComments: boolean;
}) {
  const [packageComments, setPackageComments] = useSyncedComments(detailPayload?.comments || []);
  const [uiState, dispatchUiState] = useReducer(packageDetailUiReducer, initialPackageDetailUiState);
  const {
    archiveError,
    archivePending,
    stateError,
    statePending,
  } = uiState;
  const setArchiveConfirmOpen = useCallback((open: boolean) => dispatchUiState({ type: "archiveConfirmOpen", open }), []);
  const setEvidenceDialogOpen = useCallback((open: boolean) => dispatchUiState({ type: "evidenceDialogOpen", open }), []);
  const setNoPrEvidence = useCallback((value: string) => dispatchUiState({ type: "noPrEvidence", value }), []);
  const setStateConfirmOpen = useCallback((open: boolean) => dispatchUiState({ type: "stateConfirmOpen", open }), []);
  const pkg = { ...selection.pkg, ...(detailPayload?.work_package || {}) } as PackageDetailPackage;
  const summary = detailPayload?.summary;
  const blockers = (detailPayload?.blockers || []).filter((blocker) => blocker.active !== false);
  const progress = latestPackageProgress(detailPayload);
  const plan = summary?.plan || pkg.plan;
  const operational = pkg.operational_state || null;
  const lineage = detailPayload?.lineage || pkg.lineage || null;
  const purposeMarkdown = packagePurposeMarkdown(pkg);
  const attentionItems = operational?.attention_items || [];
  const blockerCount = packageBlockerCount(blockers.length, summary, pkg, operational);
  const blockerCopyText = blockerCount > 0
    ? packageBlockerCopyText({
        blockerCount,
        blockers,
        operationalTruth: operational?.reason || packageOperationalFallbackText(pkg),
        pkg,
        repo: repoDisplayName(pkg),
        state: operationalLabel(operational, pkg.status),
      })
    : "";
  const currentCommentStats = targetCommentStats(summary || pkg, detailPayload?.comments || [], packageComments);
  const canMarkMerged = !isFinishedBoardStatus(operational?.key || pkg.status);
  const isLinkedPackage = linkedWorkPackageIds.has(pkg.id);
  const canArchiveUnlinked = !isLinkedPackage && ["merged", "merged_into_phase", "closed"].includes(pkg.status || "");
  const canCloseWithEvidence = Boolean(isLinkedPackage && canMarkMerged);
  const stateActions: Array<{ value: WorkPackageStateAction; label: string }> = isLinkedPackage
    ? [
        ...(canMarkMerged ? [{ value: "merged" as const, label: "Mark Merged" }] : []),
        ...(canCloseWithEvidence ? [{ value: "completed_no_pr" as const, label: "Close With Evidence" }] : []),
      ]
    : !isLinkedPackage && canMarkMerged
      ? [
          { value: "merged_and_archive", label: "Merged + Archive" },
          { value: "closed_and_archive", label: "Closed + Archive" },
        ]
      : [];
  function selectStateAction(action: string) {
    const nextAction = action as WorkPackageStateAction;
    dispatchUiState({ type: "stateError", error: null });
    setNoPrEvidence("");

    if (nextAction === "completed_no_pr") {
      setEvidenceDialogOpen(true);
      return;
    }

    dispatchUiState({ type: "pendingStateAction", action: nextAction });
    setStateConfirmOpen(true);
  }

  async function changePackageState(action: WorkPackageStateAction, options?: { noPrEvidence?: string }) {
    dispatchUiState({ type: "statePending", pending: true });
    dispatchUiState({ type: "stateError", error: null });

    try {
      await onChangeWorkPackageState(pkg.id, action, options);
      dispatchUiState({ type: "stateClosed" });
    } catch (caught) {
      dispatchUiState({ type: "stateError", error: caught instanceof Error ? caught.message : "WorkPackage state was not changed" });
    } finally {
      dispatchUiState({ type: "statePending", pending: false });
    }
  }

  async function archivePackage() {
    dispatchUiState({ type: "archivePending", pending: true });
    dispatchUiState({ type: "archiveError", error: null });

    try {
      await onArchiveWorkPackage(pkg.id);
      setArchiveConfirmOpen(false);
    } catch (caught) {
      dispatchUiState({ type: "archiveError", error: caught instanceof Error ? caught.message : "WorkPackage was not archived" });
    } finally {
      dispatchUiState({ type: "archivePending", pending: false });
    }
  }

  const comments: PackageDetailComments = {
    canMutate: canMutateComments,
    comments: packageComments,
    onCommentsChange: setPackageComments,
    onResolveComment,
    onSubmitComment,
  };
  const controls: PackageDetailControls = {
    actions: stateActions,
    archiveError,
    archivePending,
    canArchiveUnlinked,
    onArchiveRequest: () => setArchiveConfirmOpen(true),
    onSelectStateAction: selectStateAction,
    stateError,
    statePending,
  };
  const dialogControls: PackageDetailDialogControls = {
    archivePackage,
    changePackageState,
    dispatchUiState,
    setArchiveConfirmOpen,
    setEvidenceDialogOpen,
    setNoPrEvidence,
    setStateConfirmOpen,
  };
  const status: PackageDetailStatus = { error, loading };

  return (
    <>
      <PackageDetailBody
        attentionItems={attentionItems}
        blockerCopyText={blockerCopyText}
        blockerCount={blockerCount}
        blockers={blockers}
        comments={comments}
        controls={controls}
        currentCommentStats={currentCommentStats}
        detailPayload={detailPayload}
        lineage={lineage}
        operational={operational}
        pkg={pkg}
        planLabel={planSummaryText(plan)}
        progress={progress}
        purposeMarkdown={purposeMarkdown}
        selection={selection}
        status={status}
        summary={summary}
      />
      <PackageDetailDialogs controls={dialogControls} uiState={uiState} />
    </>
  );
}

function MarkdownDetail({ label, value }: { label: string; value: string }) {
  return (
    <div className="mb-3 grid gap-1">
      <p className="text-xs font-semibold text-muted-foreground">{label}</p>
      <MarkdownBlock className="text-sm" value={value} />
    </div>
  );
}

function sliceDeliveryMarkdown(slice: PlannedSlice) {
  if (slice.delivery?.outcome === "completed_no_pr" && slice.delivery.no_pr_evidence) {
    return { label: "Evidence", value: slice.delivery.no_pr_evidence };
  }

  if (slice.delivery?.outcome === "superseded" && slice.delivery.superseded_reason) {
    return { label: "Reason", value: slice.delivery.superseded_reason };
  }

  if (slice.delivery?.outcome === "abandoned" && slice.delivery.abandoned_rationale) {
    return { label: "Rationale", value: slice.delivery.abandoned_rationale };
  }

  return null;
}

function packagePurposeMarkdown(pkg: { engineering_scope?: string | null; product_description?: string | null }) {
  return pkg.engineering_scope || pkg.product_description || "";
}

function packageBlockerCount(
  visibleBlockerCount: number,
  summary: WorkPackageDetailPayload["summary"] | undefined,
  pkg: WorkPackageCard,
  operational: WorkPackageCard["operational_state"] | null,
) {
  return visibleBlockerCount || summary?.active_blocker_count || pkg.active_blocker_count || (operational?.key === "blocked" || pkg.status === "blocked" ? 1 : 0);
}
