import { AnimatedBadge, AnimatedCardBody } from "@/components/dashboard/motion";
import type { BoardLane } from "@/lib/operational-state";
import { Button } from "@/components/ui/button";
import { CardSignal } from "@/components/dashboard/card-signal";
import { CardSignalFrame } from "@/components/dashboard/card-signal-frame";
import { ChevronRight, MessageSquareText } from "lucide-react";
import type { CopyArchitectHandoff, GuidanceItem, PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type * as React from "react";
import { StateCard } from "@/components/dashboard/state-card";
import type { UpdateMotion } from "@/components/dashboard/motion";
import { architectHandoffEligibleRequest, isFinishedBoardStatus, operationalBadgeVariant, operationalLabel, packageAttentionSignal, packageBlockerSignal, packageCardTone, requestStateCardTone, sliceCardTone, sliceOperationalState } from "@/lib/operational-state";
import { cn } from "@/lib/utils";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";
import { useCallback } from "react";
import { CommentCardSignal } from "./runtime";
import { clarificationGuidanceItem } from "./dashboard-data";
import { firstParagraph } from "./dashboard-text";
import { useScopedHandoffCopy } from "./dashboard-state";
import { sliceSuccessorLabel } from "./workstream-data";

export function stateCardBodyMotionKey(...parts: Array<string | number | boolean | null | undefined>) {
  return parts.map((part) => (part === null || part === undefined ? "" : String(part))).join("|");
}

export function interactiveCardProps(onActivate?: () => void): React.HTMLAttributes<HTMLDivElement> {
  if (!onActivate) return {};

  return {
    role: "button",
    tabIndex: 0,
    onClick: onActivate,
    onKeyDown: (event) => {
      if (event.defaultPrevented || event.target !== event.currentTarget) return;
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        onActivate();
      }
    },
  };
}

export function SequenceBadge({ sequence }: { sequence?: number | null }) {
  if (!sequence) return null;

  return (
    <span
      className="inline-flex h-5 shrink-0 items-center rounded-md border border-border/70 bg-background/70 px-1.5 text-[11px] font-semibold leading-none text-muted-foreground shadow-sm"
      title={`Slice ${sequence}`}
    >
      S{sequence}
    </span>
  );
}

export function RequestCard({
  detail,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  index = 0,
  nodeId,
  motion,
  childrenExpanded,
  childCount = 0,
  onToggleChildren,
}: {
  detail: WorkRequestDetail;
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard?: () => void;
  onCopyArchitectHandoff?: CopyArchitectHandoff;
  index?: number;
  nodeId?: string;
  motion?: UpdateMotion;
  childrenExpanded?: boolean;
  childCount?: number;
  onToggleChildren?: () => void;
}) {
  const request = detail.work_request;
  const openQuestions = detail.clarification_questions?.filter((question) => question.status === "open") ?? [];
  const questionCount = openQuestions.length || request.open_question_count || 0;
  const operational = request.operational_state || null;
  const finishedRequest = [operational?.key, request.status].some(isFinishedBoardStatus);
  const collapsedFinished = finishedRequest && !childrenExpanded;
  const question = collapsedFinished ? undefined : openQuestions[0];
  const description = collapsedFinished ? null : firstParagraph(request.human_description);
  const handoffEligible = architectHandoffEligibleRequest(request);
  const handoffHasOpenQuestions = !finishedRequest && questionCount > 0;
  const handoffIdentity = `${questionCount}:${request.id}:${request.status || ""}:${request.updated_at || ""}`;
  const commentSignal = cardCommentSignal(request.open_comment_count, request.comment_count);
  const {
    cachedHandoff,
    recordCopyError,
    recordCopyResult,
    startCopy,
    state: handoffCopyState,
  } = useScopedHandoffCopy(handoffIdentity);

  const answerQuestion = question
    ? () => {
        onSelectGuidance(clarificationGuidanceItem(detail, question));
      }
    : undefined;
  const canCopyHandoff = !finishedRequest && handoffEligible && Boolean(onCopyArchitectHandoff);
  const canToggleChildren = finishedRequest && childCount > 0 && Boolean(onToggleChildren);
  const handoffSignalValue =
    handoffCopyState === "copying"
      ? "Copying..."
      : handoffCopyState === "copied"
        ? "Copied"
        : handoffCopyState === "error"
          ? "Try again"
          : handoffHasOpenQuestions
            ? "Resume prompt"
            : "Copy prompt";
  const copyHandoff = useCallback(
    async () => {
      if (!onCopyArchitectHandoff) return;

      startCopy();

      try {
        recordCopyResult(await onCopyArchitectHandoff(request.id, cachedHandoff()));
      } catch {
        recordCopyError("Architect handoff could not be copied");
      }
    },
    [cachedHandoff, onCopyArchitectHandoff, recordCopyError, recordCopyResult, request.id, startCopy],
  );
  const tone = requestStateCardTone(detail);
  const bodyMotionKey = stateCardBodyMotionKey(
    "request",
    request.id,
    collapsedFinished,
    childrenExpanded,
    description,
    questionCount,
    question?.id,
    question?.question,
    canCopyHandoff,
    handoffHasOpenQuestions,
    handoffCopyState,
    commentSignal ? `${commentSignal.open}:${commentSignal.total}` : null,
  );

  const card = (
    <StateCard
      tone={tone}
      className={cn("stagger-item p-3", canToggleChildren && "pr-10", onSelectCard && "card-detail-trigger")}
      data-wire-id={nodeId}
      data-card-detail-kind="request"
      style={{ animationDelay: `${index * 30}ms` }}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{request.title || request.id}</p>
          {!collapsedFinished ? <p className="mt-1 text-xs text-muted-foreground">{request.work_type || "feature"}</p> : null}
        </div>
        <div className="flex shrink-0 items-center gap-1.5">
          <AnimatedBadge
            label={operationalLabel(operational, request.status)}
            variant={operationalBadgeVariant(operational, request.status)}
            className="shrink-0"
          />
        </div>
      </div>
      <AnimatedCardBody motionKey={bodyMotionKey}>
        {description ? <p className="request-card-description mt-3 text-xs leading-relaxed text-muted-foreground">{description}</p> : null}
        {!collapsedFinished && questionCount > 0 ? (
          <CardSignal
            className="mt-3"
            label="Open Questions"
            value={String(questionCount)}
            tone="danger"
            onClick={answerQuestion}
            ariaLabel={question ? `Answer open question for ${request.title || request.id}` : undefined}
          />
        ) : null}
        {question ? <p className="mt-2 line-clamp-2 text-xs text-muted-foreground">{question.question}</p> : null}
        {canCopyHandoff || commentSignal ? (
          <div className="mt-3 flex min-w-0 items-stretch gap-2">
            {canCopyHandoff ? (
              <CardSignal
                className="min-h-12 flex-1"
                label={handoffHasOpenQuestions ? "Architect Handoff" : "Agent Handoff"}
                value={handoffSignalValue}
                tone={handoffHasOpenQuestions ? "muted" : "info"}
                onClick={copyHandoff}
                ariaLabel={`Copy agent handoff for ${request.title || request.id}`}
              />
            ) : null}
            {commentSignal ? (
              <CommentCardSignalButton
                signal={commentSignal}
                title={request.title || request.id}
                onClick={onSelectCard}
                expanded={!canCopyHandoff}
              />
            ) : null}
          </div>
        ) : null}
      </AnimatedCardBody>
    </StateCard>
  );

  if (!canToggleChildren) return card;

  return (
    <div className="relative min-w-0 max-w-full">
      {card}
      <Button
        type="button"
        size="icon"
        variant="ghost"
        className="request-children-toggle absolute right-2 top-2 size-7"
        aria-expanded={childrenExpanded}
        aria-label={`${childrenExpanded ? "Hide" : "Show"} ${childCount} child item${childCount === 1 ? "" : "s"} for ${request.title || request.id}`}
        title={`${childrenExpanded ? "Hide" : "Show"} child slices and packages`}
        onClick={onToggleChildren}
      >
        <ChevronRight className={cn("size-4 transition-transform duration-200", childrenExpanded && "rotate-90")} />
      </Button>
    </div>
  );
}

export function SliceCard({
  slice,
  pkg,
  lane,
  index = 0,
  nodeId,
  onSelectCard,
  motion,
}: {
  slice: PlannedSlice;
  pkg?: WorkPackageCard;
  lane: BoardLane;
  index?: number;
  nodeId?: string;
  onSelectCard?: () => void;
  motion?: UpdateMotion;
}) {
  const operational = sliceOperationalState(slice, pkg);
  const rawStatus = lane === "slices" ? slice.status : slice.work_package_status || slice.status;
  const tone = sliceCardTone(slice, pkg, lane);
  const detail = sliceCardSubtitle(slice, pkg, operational, rawStatus);
  const blockerSignal = lane === "slices" ? null : packageBlockerSignal(pkg, operational);
  const commentSignal = cardCommentSignal(slice.open_comment_count, slice.comment_count);
  const bodyMotionKey = stateCardBodyMotionKey(
    "slice",
    slice.id,
    lane,
    detail,
    blockerSignal?.label,
    blockerSignal?.value,
    blockerSignal?.tone,
    commentSignal ? `${commentSignal.open}:${commentSignal.total}` : null,
  );

  return (
    <StateCard
      tone={tone}
      className={cn("stagger-item p-3", onSelectCard && "card-detail-trigger")}
      data-wire-id={nodeId}
      data-card-detail-kind={pkg && lane !== "slices" ? "package" : "slice"}
      style={{ animationDelay: `${index * 30}ms` }}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <div className="flex min-w-0 items-center gap-2">
          <SequenceBadge sequence={slice.sequence} />
          <p className="min-w-0 truncate text-sm font-medium">{slice.title || pkg?.title || slice.id}</p>
        </div>
        <AnimatedBadge
          label={operationalLabel(operational, rawStatus)}
          variant={operationalBadgeVariant(operational, rawStatus)}
          className="shrink-0"
        />
      </div>
      <AnimatedCardBody motionKey={bodyMotionKey}>
        {detail ? <p className="mt-2 line-clamp-2 text-xs text-muted-foreground">{detail}</p> : null}
        {blockerSignal || commentSignal ? (
          <div className="mt-3 flex min-w-0 items-stretch gap-2">
            {blockerSignal ? (
              <CardSignal
                className="min-h-12 flex-1"
                label={blockerSignal.label}
                value={blockerSignal.value}
                tone={blockerSignal.tone}
                onClick={onSelectCard}
                ariaLabel={`Open blockers for ${slice.title || pkg?.title || slice.id}`}
              />
            ) : null}
            {commentSignal ? (
              <CommentCardSignalButton
                signal={commentSignal}
                title={slice.title || pkg?.title || slice.id}
                onClick={onSelectCard}
                expanded={!blockerSignal}
              />
            ) : null}
          </div>
        ) : null}
      </AnimatedCardBody>
    </StateCard>
  );
}

export function sliceCardSubtitle(
  slice: PlannedSlice,
  pkg: WorkPackageCard | undefined,
  operational: WorkPackageCard["operational_state"],
  status?: string | null,
) {
  const deliveryDetail = sliceDeliverySubtitle(slice, operational);
  if (deliveryDetail) return deliveryDetail;

  const terminal = [operational?.key, status, pkg?.status].some((key) => key === "blocked" || isFinishedBoardStatus(key));
  if (slice.status === "skipped") return null;
  if (terminal) return null;
  if (pkg) return `Linked package: ${operationalLabel(pkg.operational_state, pkg.status)}.`;
  return slice.goal || slice.work_package_kind;
}

export function sliceDeliverySubtitle(slice: PlannedSlice, operational: WorkPackageCard["operational_state"]) {
  const key = operational?.key;

  if (key === "needs_closeout") return "Delivery closeout needed.";
  if (key === "completed_no_pr") return "Completed without PR.";
  if (key === "delivered") return "Merged PR recorded.";

  if (key === "superseded") {
    const successor = sliceSuccessorLabel(slice);
    return successor ? `Successor: ${successor}.` : null;
  }

  return null;
}

export function cardCommentSignal(openCount?: number | null, totalCount?: number | null): CommentCardSignal | null {
  const open = openCount ?? 0;
  if (open <= 0) return null;

  const total = totalCount ?? open;
  return { open, total };
}

export function CommentCardSignalButton({
  signal,
  title,
  onClick,
  expanded = false,
  className,
}: {
  signal: CommentCardSignal;
  title: string;
  onClick?: () => void;
  expanded?: boolean;
  className?: string;
}) {
  const summary = totalCommentSignalLabel(signal);
  const ariaLabel = `Open comments for ${title}: ${summary}`;
  const signalClassName = cn("comment-card-signal", expanded && "comment-card-signal-expanded", className);

  return (
    <CardSignalFrame
      tone="warning"
      className={signalClassName}
      title={summary}
      ariaLabel={ariaLabel}
      onClick={onClick}
    >
      <MessageSquareText className="size-4" />
      {expanded ? <span className="comment-card-signal-label">Unresolved Comments</span> : null}
      <span className="comment-card-signal-count">{signal.open}</span>
    </CardSignalFrame>
  );
}

export function totalCommentSignalLabel(signal: CommentCardSignal) {
  const totalSuffix = signal.total > signal.open ? `, ${signal.total} total` : "";
  return `${signal.open} unresolved ${plural("comment", signal.open)}${totalSuffix}`;
}

export function plural(word: string, count: number) {
  return count === 1 ? word : `${word}s`;
}

export function PackageCard({
  pkg,
  lane,
  index = 0,
  nodeId,
  sequence,
  onSelectCard,
  motion,
}: {
  pkg: WorkPackageCard;
  lane: BoardLane;
  index?: number;
  nodeId?: string;
  sequence?: number | null;
  onSelectCard?: () => void;
  motion?: UpdateMotion;
}) {
  const tone = packageCardTone(pkg, lane);
  const attention = packageAttentionSignal(pkg);
  const commentSignal = cardCommentSignal(pkg.open_comment_count, pkg.comment_count);
  const operational = pkg.operational_state || null;
  const bodyMotionKey = stateCardBodyMotionKey(
    "package",
    pkg.id,
    attention?.label,
    attention?.value,
    attention?.tone,
    commentSignal ? `${commentSignal.open}:${commentSignal.total}` : null,
  );

  return (
    <StateCard
      tone={tone}
      className={cn("stagger-item p-3", onSelectCard && "card-detail-trigger")}
      data-wire-id={nodeId}
      data-card-detail-kind="package"
      style={{ animationDelay: `${index * 30}ms` }}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <div className="flex min-w-0 items-center gap-2">
          <SequenceBadge sequence={sequence} />
          <p className="min-w-0 truncate text-sm font-medium">{pkg.title || pkg.id}</p>
        </div>
        <AnimatedBadge label={operationalLabel(operational, pkg.status)} variant={operationalBadgeVariant(operational, pkg.status)} className="shrink-0" />
      </div>
      <AnimatedCardBody motionKey={bodyMotionKey}>
        {attention || commentSignal ? (
          <div className="mt-3 flex min-w-0 items-stretch gap-2">
            {attention ? <CardSignal className="min-h-12 flex-1" label={attention.label} value={attention.value} tone={attention.tone} /> : null}
            {commentSignal ? (
              <CommentCardSignalButton
                signal={commentSignal}
                title={pkg.title || pkg.id}
                onClick={onSelectCard}
                expanded={!attention}
              />
            ) : null}
          </div>
        ) : null}
      </AnimatedCardBody>
    </StateCard>
  );
}
