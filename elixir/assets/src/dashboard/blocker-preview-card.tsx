import { AlertTriangle } from "lucide-react";
import { AnimatedBadge } from "@/components/dashboard/motion";
import type { UpdateMotion } from "@/components/dashboard/motion";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";
import { StateCard } from "@/components/dashboard/state-card";
import { cn } from "@/lib/utils";
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

function blockerBadgeLabel(item: BlockerItem) {
  return item.blockerCount > 1 ? `${item.blockerCount} blockers` : "Blocked";
}

function cardDetailDataKind(selection: CardDetailSelection) {
  return selection.kind;
}
