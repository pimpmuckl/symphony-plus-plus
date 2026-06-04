import { AlertTriangle, CheckCircle2, Clock3, Route } from "lucide-react";
import { AnimatedBadge, useFlipList } from "@/components/dashboard/motion";
import { Badge } from "@/components/ui/badge";
import type { GuidanceItem } from "@/types/dashboard";
import { ScrollArea } from "@/components/ui/scroll-area";
import { StateCard } from "@/components/dashboard/state-card";
import type { StateCardTone } from "@/components/dashboard/state-card-style";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import type { UpdateMotion } from "@/components/dashboard/motion";
import { cn } from "@/lib/utils";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";
import { BlockerItem, FinishedHighlight, FinishedHighlightKind } from "./dashboard-state";
import { CardDetailSelect, CardDetailSelection, DashboardConnectionIssue, DashboardUpdateAnimations, isLocalOperatorAuthRequiredMessage } from "./runtime";
import { stripMarkdown } from "./dashboard-text";
import { blockerUpdateKey, finishedHighlightUpdateKey, finishedHighlightsListKey, guidanceUpdateKey } from "./update-animations";
import { formatDate } from "./dashboard-persistence";
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

const finishedHighlightLanes: { kind: FinishedHighlightKind; title: string; empty: string }[] = [
  { kind: "Request", title: "Requests", empty: "No finished requests" },
  { kind: "Slice", title: "Slices", empty: "No finished slices" },
  { kind: "Work Package", title: "Execution", empty: "No finished execution records" },
];

export function FinishedHighlightsBoard({
  items,
  onSelectCard,
  updateAnimations,
}: {
  items: FinishedHighlight[];
  onSelectCard?: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const flipRef = useFlipList(finishedHighlightsListKey(items));

  return (
    <ScrollArea className="finished-highlights-scroll pr-3" type="auto">
      <div className="finished-highlights-grid" ref={flipRef}>
        {finishedHighlightLanes.map((lane) => {
          const laneItems = items.filter((item) => item.kind === lane.kind);

          return (
            <section key={lane.kind} className="finished-mini-lane">
              <div className="finished-mini-lane-header">
                <span>{lane.title}</span>
                <span className="jira-lane-count">{laneItems.length}</span>
              </div>
              <div className="finished-mini-lane-body">
                {laneItems.length === 0 ? (
                  <div className="jira-lane-empty">{lane.empty}</div>
                ) : (
                  laneItems.map((item, index) => (
                    <FinishedHighlightCard
                      key={`${item.kind}-${item.id}`}
                      item={item}
                      index={index}
                      onSelectCard={onSelectCard ? () => onSelectCard(item.selection) : undefined}
                      motion={updateAnimations.motionFor(finishedHighlightUpdateKey(item))}
                    />
                  ))
                )}
              </div>
            </section>
          );
        })}
      </div>
    </ScrollArea>
  );
}

export function FinishedHighlightCard({
  item,
  index,
  onSelectCard,
  motion,
}: {
  item: FinishedHighlight;
  index: number;
  onSelectCard?: () => void;
  motion?: UpdateMotion;
}) {
  return (
    <StateCard
      tone="finished"
      className={cn("stagger-item p-3", onSelectCard && "card-detail-trigger")}
      style={{ animationDelay: `${index * 30}ms` }}
      data-flip-id={finishedHighlightUpdateKey(item)}
      data-card-detail-kind={cardDetailDataKind(item.selection)}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start gap-2">
        <CheckCircle2 className="mt-0.5 size-4 shrink-0 text-emerald-600" />
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{item.title}</p>
          <p className="mt-1 truncate text-xs text-muted-foreground">{item.repo}</p>
        </div>
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <AnimatedBadge label={item.state || "Finished"} variant="success" />
        {item.at ? (
          <span className="flex items-center gap-1 text-xs text-muted-foreground">
            <Clock3 className="size-3.5" />
            {formatDate(item.at)}
          </span>
        ) : null}
      </div>
    </StateCard>
  );
}
