import { Route } from "lucide-react";
import { AnimatedBadge } from "@/components/dashboard/motion";
import type { UpdateMotion } from "@/components/dashboard/motion";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";
import { StateCard } from "@/components/dashboard/state-card";
import type { StateCardTone } from "@/components/dashboard/state-card-style";
import { Badge } from "@/components/ui/badge";
import type { GuidanceItem } from "@/types/dashboard";
import { stripMarkdown } from "./dashboard-text";
import { guidanceUpdateKey } from "./update-animations";

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
