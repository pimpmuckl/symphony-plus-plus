import { Archive, CheckCircle2, Loader2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { DetailCopyButton } from "@/components/dashboard/detail-copy-button";
import { DetailDisclosure, DetailFacts, DetailHeader, DetailList, DetailSection, DetailStatGrid } from "@/components/dashboard/detail-layout";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { MarkdownBlock } from "@/components/dashboard/markdown-block";
import type { ActiveBlockingEdgeEndpoint, PlannedSlice, WorkPackageCard, WorkPackageDetailPayload, WorkRequestDetail } from "@/types/dashboard";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { isFinishedBoardStatus, operationalBadgeVariant, operationalLabel, sliceOperationalState } from "@/lib/operational-state";
import { packageReviewLabel, reviewLaneLabel } from "@/lib/review-signals";
import { statusLabel } from "@/lib/status-labels";
import { useCallback, useReducer, useState } from "react";
import { COMMENT_BODY_MAX_LENGTH, CardDetailSelection, ResolveContextComment, SubmitContextComment, WorkPackageArchiveMutation, WorkPackageBlockerClearMutation, WorkPackageStateAction, WorkPackageStateMutation } from "./runtime";
import { CommentsPanel, useSyncedComments } from "./comments-panel";
import { DangerousStateConfirmationDialog } from "./request-detail";
import { packageBlockerCopyText } from "./detail-copy";
import { DetailActivityList, DetailAttentionList, LineageDisclosure, RecentDecisionsDisclosure } from "./detail-extras";
import { activeAlertLabels, commentStatLabel, detailDate, latestPackageProgress, lineageHasSignal, packageOperationalFallbackText, packageRuntimeText, planSummaryText, sliceDeliveryFacts, sliceDeliverySummary, sliceProgressText, targetCommentStats } from "./detail-utils";
import { initialPackageDetailUiState, packageDetailUiReducer } from "./dashboard-state";
import { repoDisplayName } from "./dashboard-persistence";
import { activePackageBlockers, packageBlockerEdge } from "./blocker-selection";

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

export function BlockerDetailContent({
  selection,
  detailPayload,
  loading,
  error,
  onClearWorkPackageBlocker,
}: {
  selection: Extract<CardDetailSelection, { kind: "blocker" }>;
  detailPayload: WorkPackageDetailPayload | null;
  loading: boolean;
  error: string | null;
  onClearWorkPackageBlocker: WorkPackageBlockerClearMutation;
}) {
  const [pending, setPending] = useState(false);
  const [clearError, setClearError] = useState<string | null>(null);
  const pkg = selection.pkg || detailPayload?.work_package;
  const detail = selection.detail;
  const slice = selection.slice;
  const loadedBlocker = matchingLoadedBlocker(selection.blocker.blocker_id, detailPayload);
  const blocker = loadedBlocker && pkg ? packageBlockerEdge(loadedBlocker, pkg, { detail, slice }) : selection.blocker;
  const blockerId = blocker.blocker_id;
  const displayBlockerId = blockerId || blocker.id;
  const workPackageId = pkg?.id || blocker.work_package_id || endpointId(blocker.from, "work_package") || endpointId(blocker.to, "work_package");
  const title = blocker.summary || pkg?.title || displayBlockerId || "Active blocker";

  async function clearBlocker() {
    if (!workPackageId || !blockerId) return;

    setPending(true);
    setClearError(null);

    try {
      await onClearWorkPackageBlocker(workPackageId, blockerId);
    } catch (caught) {
      setClearError(caught instanceof Error ? caught.message : "Blocker was not cleared");
    } finally {
      setPending(false);
    }
  }

  return (
    <>
      <DetailHeader
        title={title}
        eyebrow={`${pkg ? repoDisplayName(pkg) : detail ? repoDisplayName(detail.work_request) : "Work package"} / active blocker`}
        badge={<Badge variant="danger">Blocked</Badge>}
      />
      <div className="detail-modal-reveal-body grid gap-4">
        <DetailStatGrid
          stats={[
            { label: "Blocker", value: displayBlockerId || "Not recorded" },
            { label: "Package", value: workPackageId || "Not linked" },
            { label: "Request", value: detail?.work_request.id || blocker.work_request_id || "Not linked" },
            { label: "Slice", value: slice?.id || blocker.planned_slice_id || "Not linked" },
            { label: "Updated", value: detailDate(blocker.updated_at) },
          ]}
        />
        <DetailSection title="Blocker">
          <MarkdownBlock value={blocker.body || blocker.summary || ""} empty={loading ? "Loading blocker detail..." : "No blocker body recorded."} />
          {error ? <p className="mt-2 text-xs text-destructive">{error}</p> : null}
        </DetailSection>
        <DetailSection title="Context">
          <DetailFacts
            facts={[
              ["From", endpointLabel(blocker.from)],
              ["To", endpointLabel(blocker.to)],
              ["Work Package", pkg?.title || workPackageId || "Not linked"],
              ["Planned Slice", slice?.title || slice?.id || blocker.planned_slice_id || "Not linked"],
              ["Work Request", detail?.work_request.title || detail?.work_request.id || blocker.work_request_id || "Not linked"],
            ]}
          />
        </DetailSection>
        <div className="flex flex-col items-start gap-2 border-t border-destructive/20 pt-4">
          <Button type="button" size="sm" variant="destructive" onClick={() => void clearBlocker()} disabled={pending || !workPackageId || !blockerId}>
            {pending ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}
            Clear
          </Button>
          {clearError ? <p className="text-xs text-destructive">{clearError}</p> : null}
          {!workPackageId || !blockerId ? <p className="text-xs text-destructive">Blocker cannot be cleared because its package or blocker id is missing.</p> : null}
        </div>
      </div>
    </>
  );
}

function matchingLoadedBlocker(blockerId: string | null | undefined, detailPayload: WorkPackageDetailPayload | null) {
  const blockers = activePackageBlockers(detailPayload?.work_package ? { ...detailPayload.work_package, active_blockers: detailPayload.blockers || [] } : undefined);
  return blockers.find((blocker) => blocker.id === blockerId) || blockers[0] || null;
}

function endpointId(endpoint: ActiveBlockingEdgeEndpoint | undefined, kind: ActiveBlockingEdgeEndpoint["kind"]) {
  return endpoint?.kind === kind ? endpoint.id : null;
}

function endpointLabel(endpoint: ActiveBlockingEdgeEndpoint | undefined) {
  if (!endpoint) return "Not recorded";
  return `${statusLabel(endpoint.kind)} ${endpoint.id}`;
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
    archiveConfirmOpen,
    archiveError,
    archivePending,
    evidenceDialogOpen,
    noPrEvidence,
    pendingStateAction,
    stateConfirmOpen,
    stateError,
    statePending,
  } = uiState;
  const setArchiveConfirmOpen = useCallback((open: boolean) => dispatchUiState({ type: "archiveConfirmOpen", open }), []);
  const setEvidenceDialogOpen = useCallback((open: boolean) => dispatchUiState({ type: "evidenceDialogOpen", open }), []);
  const setNoPrEvidence = useCallback((value: string) => dispatchUiState({ type: "noPrEvidence", value }), []);
  const setStateConfirmOpen = useCallback((open: boolean) => dispatchUiState({ type: "stateConfirmOpen", open }), []);
  const pkg = { ...selection.pkg, ...(detailPayload?.work_package || {}) } as WorkPackageCard & {
    branch_pattern?: string | null;
    product_description?: string | null;
    engineering_scope?: string | null;
    acceptance_criteria?: string[];
    policy_template?: string | null;
  };
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

  return (
    <>
      <DetailHeader
        title={pkg.title || pkg.id}
        eyebrow={`${repoDisplayName(pkg)} / ${pkg.base_branch || "main"} / ${pkg.kind || "work package"}`}
        badge={<Badge variant={operationalBadgeVariant(operational, pkg.status)}>{operationalLabel(operational, pkg.status)}</Badge>}
        action={blockerCopyText ? <DetailCopyButton label="Copy blocker details" text={blockerCopyText} /> : null}
      />
      <div className="detail-modal-reveal-body grid gap-4">
        <DetailStatGrid
          stats={[
            { label: "State", value: operationalLabel(operational, pkg.status) },
            { label: "Plan", value: planSummaryText(plan) },
            { label: "Runtime", value: packageRuntimeText(summary, pkg) },
            { label: "Blockers", value: String(blockerCount) },
            { label: "Comments", value: commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count) },
            { label: "Updated", value: detailDate(summary?.latest_progress_at || pkg.latest_progress_at || pkg.updated_at || pkg.inserted_at) },
          ]}
        />
        <DetailSection title="Execution Scope">
          <MarkdownBlock value={purposeMarkdown} empty={pkg.kind || "No execution scope has been recorded yet."} />
        </DetailSection>
        <DetailSection title="Operational Truth">
          <div className="grid gap-2">
            <p>{operational?.reason || packageOperationalFallbackText(pkg)}</p>
            {attentionItems.length > 0 ? <DetailAttentionList items={attentionItems} /> : null}
          </div>
        </DetailSection>
        <DetailSection title="Progress">
          {loading ? (
            <p>Loading latest package activity&hellip;</p>
          ) : progress.length > 0 ? (
            <DetailActivityList items={progress.map((item) => ({ title: item.summary || item.status || "Progress", body: item.body, at: item.created_at }))} />
          ) : (
            <p>{planSummaryText(plan) === "No plan" ? "No package progress recorded yet." : `Plan is ${planSummaryText(plan).toLowerCase()}.`}</p>
          )}
        </DetailSection>
        <DetailSection title="Blocked By">
          {error ? (
            <p>{error}</p>
          ) : blockerCount > 0 ? (
            <DetailActivityList
              items={(blockers.length > 0 ? blockers : [{ summary: "Package is blocked", body: "No blocker detail was included in the board summary." }]).map(
                (blocker) => ({ title: blocker.summary || blocker.status || "Blocker", body: blocker.body || blocker.resolution, at: blocker.updated_at }),
              )}
            />
          ) : (
            <p>No active blockers surfaced.</p>
          )}
        </DetailSection>
        <DetailDisclosure title="Comments" meta={commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count)}>
          <CommentsPanel
            key={`work_package:${pkg.id}`}
            target={{ target_kind: "work_package", target_id: pkg.id }}
            comments={packageComments}
            onCommentsChange={setPackageComments}
            onSubmitComment={onSubmitComment}
            onResolveComment={onResolveComment}
            canMutate={canMutateComments}
          />
        </DetailDisclosure>
        {selection.detail ? <RecentDecisionsDisclosure detail={selection.detail} /> : null}
        {lineageHasSignal(lineage) ? <LineageDisclosure lineage={lineage} /> : null}
        <DetailDisclosure title="Details" meta="PR, review, artifacts, and raw identifiers">
          <DetailFacts
            facts={[
              ["Package ID", pkg.id],
              ["Parent", pkg.parent_id || selection.slice?.work_request_id || "Not linked"],
              ["Raw Status", statusLabel(operational?.raw_status || pkg.status)],
              ["Policy", pkg.policy_template || pkg.kind || "Not recorded"],
              ["Branch", pkg.metadata?.branch?.branch || pkg.branch_pattern || "Not recorded"],
              ["PR", pkg.metadata?.pr?.number ? `PR #${pkg.metadata.pr.number}` : pkg.metadata?.pr?.url ? "PR attached" : "Not attached"],
              [
                "Review",
                packageReviewLabel(pkg) || (pkg.status === "reviewing" ? "Reviewing" : "Not recorded"),
              ],
              ["Artifacts", String(summary?.artifact_count ?? pkg.artifact_count ?? 0)],
              ["Findings", String(summary?.finding_count ?? pkg.finding_count ?? 0)],
            ]}
          />
          <DetailList title="Acceptance" items={pkg.acceptance_criteria || selection.slice?.acceptance_criteria || []} empty="No acceptance criteria recorded." />
          <DetailList title="Alerts" items={activeAlertLabels(detailPayload?.alert_indicators || pkg.alert_indicators || [])} empty="No active alerts." />
        </DetailDisclosure>
        {stateActions.length > 0 || canArchiveUnlinked ? (
          <div className="flex flex-col items-start gap-2 border-t border-destructive/20 pt-4">
            <div className="flex flex-wrap gap-2">
              {stateActions.length > 0 ? (
                <Select value="" onValueChange={selectStateAction} disabled={statePending}>
                  <SelectTrigger className="h-9 w-[190px] border-destructive/40 text-xs">
                    <SelectValue placeholder="Change State" />
                  </SelectTrigger>
                  <SelectContent>
                    {stateActions.map((action) => (
                      <SelectItem key={action.value} value={action.value}>
                        {action.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              ) : null}
              {canArchiveUnlinked ? (
                <Button type="button" size="sm" variant="outline" onClick={() => setArchiveConfirmOpen(true)} disabled={archivePending}>
                  {archivePending ? <Loader2 className="size-4 animate-spin" /> : <Archive className="size-4" />}
                  Archive Record
                </Button>
              ) : null}
            </div>
            {stateError ? <p className="text-xs text-destructive">{stateError}</p> : null}
            {archiveError ? <p className="text-xs text-destructive">{archiveError}</p> : null}
          </div>
        ) : null}
      </div>
      <DangerousStateConfirmationDialog
        open={stateConfirmOpen}
        onOpenChange={(open) => {
          setStateConfirmOpen(open);
          if (!open) dispatchUiState({ type: "pendingStateAction", action: null });
        }}
        title={pendingStateAction === "closed_and_archive" ? "Close and Archive Execution Record?" : "Mark Execution Merged?"}
        description={
          pendingStateAction === "merged_and_archive"
            ? "This marks the unlinked execution record Merged and hides it from the active execution view. The package record stays in the local ledger."
            : pendingStateAction === "closed_and_archive"
              ? "This marks the unlinked execution record Closed and hides it from the active execution view. The package record stays in the local ledger."
              : "This manually marks the execution record Merged for the local dashboard. Use it only when the external merge or worker handoff was missed."
        }
        confirmLabel={
          pendingStateAction === "merged_and_archive"
            ? "Merged + Archive"
            : pendingStateAction === "closed_and_archive"
              ? "Closed + Archive"
              : "Mark Merged"
        }
        pending={statePending}
        onConfirm={() => {
          if (pendingStateAction) void changePackageState(pendingStateAction);
        }}
      />
      <Dialog open={evidenceDialogOpen} onOpenChange={setEvidenceDialogOpen}>
        <DialogContent className="dashboard-dialog-content sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>Close With Evidence</DialogTitle>
            <DialogDescription>Record a completed-without-PR delivery for the linked planned slice.</DialogDescription>
          </DialogHeader>
          <div className="grid gap-3">
            <Textarea
              value={noPrEvidence}
              onChange={(event) => setNoPrEvidence(event.target.value)}
              placeholder="Markdown evidence note..."
              disabled={statePending}
              maxLength={COMMENT_BODY_MAX_LENGTH}
            />
            {stateError ? <p className="text-xs text-destructive">{stateError}</p> : null}
            <div className="flex justify-end gap-2">
              <Button type="button" size="sm" variant="outline" onClick={() => setEvidenceDialogOpen(false)} disabled={statePending}>
                Cancel
              </Button>
              <Button
                type="button"
                size="sm"
                variant="destructive"
                onClick={() => void changePackageState("completed_no_pr", { noPrEvidence: noPrEvidence.trim() })}
                disabled={statePending || noPrEvidence.trim().length === 0}
              >
                {statePending ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}
                Mark Completed Without PR
              </Button>
            </div>
          </div>
        </DialogContent>
      </Dialog>
      <DangerousStateConfirmationDialog
        open={archiveConfirmOpen}
        onOpenChange={setArchiveConfirmOpen}
        title="Archive Unlinked Execution Record?"
        description="This hides the delivered unlinked execution record from the active execution view. The package record stays in the local ledger."
        confirmLabel="Archive Record"
        pending={archivePending}
        onConfirm={() => void archivePackage()}
      />
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
