import type { UpdateMotion } from "@/components/dashboard/motion";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";
import { StateCard } from "@/components/dashboard/state-card";
import type { StateCardTone } from "@/components/dashboard/state-card-style";
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
  const title = stripMarkdown(item.prompt?.tl_dr || item.title);
  const detail = guidancePreviewText(item.prompt?.details || item.detail);

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
      <div className="min-w-0">
        <p className="truncate text-xs text-muted-foreground">{item.repo}</p>
        <p className="mt-1 line-clamp-2 text-sm font-semibold">{title}</p>
        {detail ? <p className="mt-3 line-clamp-2 text-sm text-muted-foreground">{detail}</p> : null}
      </div>
    </StateCard>
  );
}

function guidancePreviewText(value: string) {
  return stripMarkdown(value).trim();
}
