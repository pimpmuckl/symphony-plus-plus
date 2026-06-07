import { AlertTriangle, Route } from "lucide-react";
import { AnimatedBadge } from "@/components/dashboard/motion";
import { Badge } from "@/components/ui/badge";
import type { GuidanceItem } from "@/types/dashboard";
import { StateCard } from "@/components/dashboard/state-card";
import type { StateCardTone } from "@/components/dashboard/state-card-style";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import type { UpdateMotion } from "@/components/dashboard/motion";
import { cn } from "@/lib/utils";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";
import { BlockerItem } from "./dashboard-state";
import { CardDetailSelection, DashboardConnectionIssue, isLocalOperatorAuthRequiredMessage } from "./runtime";
import { stripMarkdown } from "./dashboard-text";
import { blockerUpdateKey, guidanceUpdateKey } from "./update-animations";
import { interactiveCardProps } from "./card-helpers";

export function LiveLedgerBadge({
  error,
  connectionIssue,
  databasePath,
}: {
  error: string | null;
  connectionIssue: DashboardConnectionIssue | null;
  databasePath?: string | null;
}) {
  const reconnecting = Boolean(connectionIssue && !error);
  const authRequired = isLocalOperatorAuthRequiredMessage(error);
  const label = authRequired ? "Auth required" : error ? "API unavailable" : reconnecting ? "Reconnecting..." : "Live ledger";
  const variant = error ? "danger" : reconnecting ? "warning" : "success";
  const heading = authRequired ? "Local operator" : error || reconnecting ? "Status" : "Database";
  const tooltip = error
    ? error
    : reconnecting
      ? `Last update failed. Retrying for up to 5 minutes before surfacing an error. ${connectionIssue?.message || ""}`.trim()
      : databasePath || "Database path unavailable.";

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Badge variant={variant} className="cursor-help">
          {label}
        </Badge>
      </TooltipTrigger>
      <TooltipContent className="max-w-[min(34rem,calc(100vw-2rem))]">
        <div className="grid gap-1">
          <span className="text-xs font-medium">{heading}</span>
          <span className="break-all font-mono text-[11px] leading-relaxed text-muted-foreground">{tooltip}</span>
        </div>
      </TooltipContent>
    </Tooltip>
  );
}

export function GuidancePreviewCard({
  item,
  index,
  onSelect,
  motion,
}: {
  item: GuidanceItem;
  index: number;
  onSelect: (item: GuidanceItem) => void;
  motion?: UpdateMotion;
}) {
  const tone: StateCardTone = item.source === "guidance" ? "guidance" : "queued";

  return (
    <StateCard
      as="button"
      tone={tone}
      className="stagger-item grid gap-4 p-4 text-left hover:border-primary/50 hover:shadow-dashboard focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      style={{ animationDelay: `${index * 45}ms` }}
      onClick={() => onSelect(item)}
      data-flip-id={guidanceUpdateKey(item)}
      {...updateMotionAttributes(motion)}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <div className="flex size-8 shrink-0 items-center justify-center rounded-md bg-violet-50 text-violet-700 dark:bg-violet-950/70 dark:text-violet-200">
              <Route className="size-4" />
            </div>
            <p className="truncate text-sm font-semibold">{item.repo}</p>
            <Badge variant="secondary">{item.source === "guidance" ? "Package" : "Request"}</Badge>
          </div>
          <p className="mt-4 text-sm font-medium">TL;DR</p>
          <p className="mt-1 line-clamp-2 text-sm text-muted-foreground">{stripMarkdown(item.prompt?.tl_dr || item.title)}</p>
          <p className="mt-4 text-sm font-medium">Description</p>
          <p className="mt-1 line-clamp-3 text-sm text-muted-foreground">{stripMarkdown(item.prompt?.details || item.detail)}</p>
        </div>
        <AnimatedBadge
          label={item.source === "guidance" ? "Guidance Needed" : "Clarify"}
          variant={item.source === "guidance" ? "danger" : "warning"}
        />
      </div>
    </StateCard>
  );
}

function blockerBadgeLabel(item: BlockerItem) {
  return item.blockerCount > 1 ? `${item.blockerCount} blockers` : "Blocked";
}

function cardDetailDataKind(selection: CardDetailSelection) {
  return selection.kind;
}

export function BlockerPreviewCard({
  item,
  index,
  onSelectCard,
  motion,
}: {
  item: BlockerItem;
  index: number;
  onSelectCard?: () => void;
  motion?: UpdateMotion;
}) {
  return (
    <StateCard
      tone="blocked"
      className={cn("stagger-item p-4", onSelectCard && "card-detail-trigger")}
      style={{ animationDelay: `${index * 45}ms` }}
      data-flip-id={blockerUpdateKey(item)}
      data-card-detail-kind={cardDetailDataKind(item.selection)}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{item.title}</p>
          <p className="mt-1 truncate text-xs text-muted-foreground">{item.repo}</p>
        </div>
        <AnimatedBadge label={blockerBadgeLabel(item)} variant="danger" className="shrink-0" />
      </div>
      <p className="mt-4 line-clamp-3 text-sm text-muted-foreground">{stripMarkdown(item.detail)}</p>
      <div className="mt-4 flex items-center gap-2 text-xs text-amber-800 dark:text-amber-200">
        <AlertTriangle className="size-4" />
        {item.blockerCount} active blocker{item.blockerCount === 1 ? "" : "s"}
      </div>
    </StateCard>
  );
}
