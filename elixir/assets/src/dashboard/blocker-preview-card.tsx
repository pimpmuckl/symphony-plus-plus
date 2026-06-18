import { AlertTriangle } from "lucide-react";
import type { UpdateMotion } from "@/components/dashboard/motion";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";
import { StateCard } from "@/components/dashboard/state-card";
import { cn } from "@/lib/utils";
import type { ActiveBlockingEdgeEndpoint } from "@/types/dashboard";
import { interactiveCardProps } from "./card-helpers";
import { BlockerItem } from "./dashboard-state";
import { stripMarkdown } from "./dashboard-text";
import { CardDetailSelection } from "./runtime";
import { blockerUpdateKey } from "./update-animations";

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
  const detail = blockerPreviewText(item.detail);
  const blocker = item.selection.kind === "blocker" ? item.selection.blocker : null;
  const blockedBy = blocker ? blockedByText(blocker.from, blocker.to) : "";

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
          <p className="line-clamp-2 text-sm font-semibold">{item.title}</p>
          <p className="mt-1 truncate text-xs text-muted-foreground">{item.repo}</p>
        </div>
        <AlertTriangle className="mt-0.5 size-4 shrink-0 text-rose-600 dark:text-rose-300" aria-hidden="true" />
      </div>
      {blockedBy ? <p className="mt-2 truncate text-xs font-medium text-muted-foreground">{blockedBy}</p> : null}
      {detail ? <p className="mt-3 line-clamp-2 text-sm text-muted-foreground">{detail}</p> : null}
    </StateCard>
  );
}

function blockerPreviewText(value: string) {
  const text = stripMarkdown(value).trim();
  if (!text || /^raw lifecycle status is /i.test(text) || /^this work package has active blockers?/i.test(text)) return "";
  return text;
}

function cardDetailDataKind(selection: CardDetailSelection) {
  return selection.kind;
}

function blockedByText(from?: ActiveBlockingEdgeEndpoint, to?: ActiveBlockingEdgeEndpoint) {
  if (!from || (to && from.kind === to.kind && from.id === to.id)) return "";
  return `Blocked by ${from.id}`;
}
