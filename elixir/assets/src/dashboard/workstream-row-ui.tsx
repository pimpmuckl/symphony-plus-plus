import type { CopyArchitectHandoff, PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { ProductTreeCompletionMark, ProductTreeNode } from "@/types/product-tree";
import { AlertTriangle, CheckCircle2, CircleAlert, CircleDashed, CircleHelp, ClipboardCopy, Info, Layers3, MessageSquareText, Package, Split } from "lucide-react";
import type { ComponentProps, CSSProperties, ReactNode } from "react";
import { useCallback, useEffect, useRef, useState } from "react";

import { AnimatedBadge } from "@/components/dashboard/motion";
import { Button } from "@/components/ui/button";
import { architectHandoffEligibleRequest, operationalBadgeVariant } from "@/lib/operational-state";
import { cn } from "@/lib/utils";
import type { CardDetailSelect } from "./runtime";
import { rowProgressIconState, type RowProgressIconState } from "./workstream-row-state";

type EntityCountChip = {
  key: string;
  icon: ReactNode;
  count: number;
  label: string;
  tone?: "guidance" | "blocker";
  showZero?: boolean;
};

export function EntityCountChips({
  items,
  reserveEmpty = false,
  className,
}: {
  items: EntityCountChip[];
  reserveEmpty?: boolean;
  className?: string;
}) {
  return (
    <span className={cn("v3-row-signals", className)}>
      {items.map((item) => {
        const visible = item.count > 0 || item.showZero;
        if (!visible && !reserveEmpty) return null;

        return (
          <span
            key={item.key}
            className={cn(
              "v3-signal-chip",
              item.tone === "guidance" && "v3-guidance-chip",
              item.tone === "blocker" && "v3-blocker-chip",
              !visible && "v3-signal-chip-empty",
            )}
            aria-hidden={visible ? undefined : "true"}
            aria-label={visible ? `${item.count} ${item.label}` : undefined}
            title={visible ? item.label : undefined}
          >
            {visible ? item.icon : null}
            {visible ? item.count : null}
          </span>
        );
      })}
    </span>
  );
}

export function EntityKindSlot({
  icon,
  value,
  title,
  muted = false,
}: {
  icon: ReactNode;
  value?: ReactNode;
  title: string;
  muted?: boolean;
}) {
  return (
    <span className={cn("v3-entity-kind-slot", muted && "v3-entity-kind-slot-muted")} title={title} aria-label={title}>
      {icon}
      {value !== undefined ? <span className="v3-entity-kind-value">{value}</span> : null}
    </span>
  );
}

export function RequestHeaderActions({
  detail,
  progress,
  progressIconState,
  progressLabel,
  onSelectCard,
  onCopyArchitectHandoff,
}: {
  detail: WorkRequestDetail;
  progress: number;
  progressIconState: RowProgressIconState;
  progressLabel: string;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
}) {
  const [copying, setCopying] = useState(false);
  const [copyToastVisible, setCopyToastVisible] = useState(false);
  const copyToastTimerRef = useRef<number | null>(null);
  const request = detail.work_request;
  const canCopyHandoff = architectHandoffEligibleRequest(request);
  const showCopyToast = useCallback(() => {
    if (copyToastTimerRef.current !== null) {
      window.clearTimeout(copyToastTimerRef.current);
    }
    setCopyToastVisible(true);
    copyToastTimerRef.current = window.setTimeout(() => {
      setCopyToastVisible(false);
      copyToastTimerRef.current = null;
    }, 3000);
  }, []);

  useEffect(
    () => () => {
      if (copyToastTimerRef.current !== null) {
        window.clearTimeout(copyToastTimerRef.current);
      }
    },
    [],
  );

  const copyHandoff = useCallback(async () => {
    setCopying(true);
    try {
      const result = await onCopyArchitectHandoff(request.id);
      if (result.copied) {
        showCopyToast();
      }
    } catch {
      setCopyToastVisible(false);
    } finally {
      setCopying(false);
    }
  }, [onCopyArchitectHandoff, request.id, showCopyToast]);

  return (
    <div className="v3-request-header-actions v3-row-actions">
      <ProgressStateIcon state={progressIconState} progress={progress} label={progressLabel} />
      <Button
        type="button"
        variant="secondary"
        size="icon"
        className="v3-request-action-button"
        aria-label="Open request details"
        title="Request details"
        onClick={() => onSelectCard({ kind: "request", detail })}
      >
        <Info className="size-4" />
      </Button>
      {canCopyHandoff ? (
        <Button
          type="button"
          variant="outline"
          size="icon"
          className="v3-request-action-button"
          aria-label={copying ? "Copying architect handoff" : "Copy architect handoff"}
          title={copying ? "Copying architect handoff" : "Architect handoff"}
          onClick={copyHandoff}
          disabled={copying}
        >
          <ClipboardCopy className="size-4" />
        </Button>
      ) : null}
      {copyToastVisible ? (
        <div className="v3-handoff-copy-toast" role="status" aria-live="polite">
          Handoff copied to Clipboard
        </div>
      ) : null}
    </div>
  );
}

export function ProgressStateIcon({
  label,
  progress = 0,
  state,
}: {
  label: string;
  progress?: number;
  state: RowProgressIconState;
}) {
  const clampedProgress = Math.max(0, Math.min(100, Math.round(progress)));
  const accessibleLabel = state === "active" ? `${label}, ${clampedProgress}% progress` : label;
  const style = { "--v3-progress-state-value": `${clampedProgress}%` } as CSSProperties;

  return (
    <span className={cn("v3-progress-state-icon", `v3-progress-state-${state}`)} title={accessibleLabel} aria-label={accessibleLabel} style={style}>
      {state === "done" ? <CheckCircle2 className="size-4" /> : null}
      {state === "blocked" ? <CircleAlert className="size-4" /> : null}
      {state === "guidance" ? <CircleHelp className="size-4" /> : null}
      {state === "muted" ? <CircleDashed className="size-4" /> : null}
      {state === "active" ? <span className="v3-progress-state-ring" /> : null}
    </span>
  );
}

export function SliceKindSlot({
  detail,
  slice,
  pkg,
  onSelectCard,
}: {
  detail: WorkRequestDetail;
  slice: PlannedSlice;
  pkg?: WorkPackageCard;
  onSelectCard: CardDetailSelect;
}) {
  if (pkg) {
    return (
      <Button
        type="button"
        size="icon"
        variant="ghost"
        className="v3-entity-kind-button v3-slice-package-button"
        title={pkg.title || pkg.id}
        aria-label={`Open execution details for ${pkg.title || pkg.id}`}
        onClick={() => onSelectCard({ kind: "package", pkg, detail, slice })}
      >
        <Package className="size-4" />
      </Button>
    );
  }

  return (
    <EntityKindSlot
      icon={<Split className="size-3.5" />}
      title="Subwork placeholder"
      muted
    />
  );
}

export function ProductNodeHeader({
  node,
  nodeSliceCount,
  visibleNodeKind,
  mark,
  tone,
  statusLabel,
  guidanceCount,
  blockerCount,
}: {
  node: ProductTreeNode;
  nodeSliceCount: number;
  visibleNodeKind?: string | null;
  mark: ProductTreeCompletionMark;
  tone: string;
  statusLabel: string;
  guidanceCount: number;
  blockerCount: number;
}) {
  const progress = completionMarkProgress(mark);
  const progressIconState = rowProgressIconState({ blockerCount, guidanceCount, progress, tone });

  return (
    <div className="v3-product-node-header v3-entity-row" data-tone={tone}>
      <ProgressStateIcon state={progressIconState} progress={progress} label={statusLabel} />
      <span className="v3-product-node-title-group">
        <span className="v3-product-node-title">{node.title || node.id}</span>
        <span className="v3-product-node-meta">
          {visibleNodeKind ? <span>{visibleNodeKind}</span> : null}
          <span>{nodeSliceCount} slices</span>
        </span>
      </span>
      <EntityCountChips
        reserveEmpty
        items={[
          { key: "guidance", icon: <MessageSquareText className="size-3.5" />, count: guidanceCount, label: "guidance needed", tone: "guidance" },
          { key: "blockers", icon: <AlertTriangle className="size-3.5" />, count: blockerCount, label: "active blockers", tone: "blocker" },
        ]}
      />
      <span className="v3-row-status">
        <ProgressPill progress={progress} />
        <RowBadgeSlot label={statusLabel} variant={completionBadgeVariant(mark)} />
      </span>
      <EntityKindSlot icon={<Layers3 className="size-3.5" />} title="Product plan node" />
    </div>
  );
}

export function RowBadgeSlot({
  label,
  variant,
}: {
  label: string;
  variant?: ComponentProps<typeof AnimatedBadge>["variant"];
}) {
  return (
    <span className="v3-row-badge-slot">
      <AnimatedBadge label={label} variant={variant} className="v3-row-status-badge" />
    </span>
  );
}

export function ProgressPill({ progress }: { progress: number }) {
  return (
    <span className="v3-progress-pill">
      <span className="v3-progress-bar"><span style={{ width: `${progress}%` }} /></span>
      <span>{progress}%</span>
    </span>
  );
}

function completionMarkProgress(mark: ProductTreeCompletionMark) {
  if (mark === "done") return 100;
  if (mark === "partial") return 50;
  return 0;
}

function completionBadgeVariant(mark: ProductTreeCompletionMark): ReturnType<typeof operationalBadgeVariant> {
  if (mark === "done") return "success";
  if (mark === "partial") return "warning";
  if (mark === "not_done") return "info";
  return "secondary";
}
