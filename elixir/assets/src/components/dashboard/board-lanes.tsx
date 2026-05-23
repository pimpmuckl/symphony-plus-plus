import { Route } from "lucide-react";
import { Children } from "react";
import type { CSSProperties, ReactNode } from "react";

import { cn } from "@/lib/utils";

type BoardLaneColumnProps = {
  title: string;
  count: number;
  emptyLabel: string;
  children: ReactNode;
  bodyStyle?: CSSProperties;
  aligned?: boolean;
};

export function BoardLaneColumn({
  title,
  count,
  emptyLabel,
  children,
  bodyStyle,
  aligned = false,
}: BoardLaneColumnProps) {
  const hasChildren = Children.count(children) > 0;

  return (
    <section className="jira-lane">
      <div className="jira-lane-header">
        <span>{title}</span>
        <span className="jira-lane-count">{count}</span>
      </div>
      <div className={cn("jira-lane-body", aligned && "jira-lane-body-aligned")} style={bodyStyle}>
        {count > 0 || (aligned && hasChildren) ? children : <div className="jira-lane-empty">{emptyLabel}</div>}
      </div>
    </section>
  );
}

type FeatureLaneRowProps = {
  rowKey: string;
  lane: string;
  slotTemplate?: string;
  emptyOverride?: boolean;
  children: ReactNode;
};

export function FeatureLaneRow({
  rowKey,
  lane,
  slotTemplate,
  emptyOverride,
  children,
}: FeatureLaneRowProps) {
  const renderedChildren = Children.toArray(children);
  const empty = emptyOverride ?? renderedChildren.length === 0;

  return (
    <div
      className="feature-lane-row"
      data-feature-row={rowKey}
      data-lane={lane}
      data-empty={empty ? "true" : undefined}
      style={slotTemplate ? { gridTemplateRows: slotTemplate } : undefined}
    >
      {renderedChildren}
      {empty && renderedChildren.length === 0 ? <div className="feature-lane-empty" /> : null}
    </div>
  );
}

type AlignedCardSlotProps = {
  rowKey: string;
  slotKey: string;
  lane: string;
  empty?: boolean;
  children: ReactNode;
};

export function AlignedCardSlot({
  rowKey,
  slotKey,
  lane,
  empty = false,
  children,
}: AlignedCardSlotProps) {
  return (
    <div
      className="aligned-card-slot"
      data-feature-row={rowKey}
      data-slot-key={slotKey}
      data-lane={lane}
      data-empty={empty ? "true" : undefined}
    >
      {children}
    </div>
  );
}

export function LaneGroupLabel({ label }: { label: string }) {
  return (
    <div className="flex items-center gap-2 px-1 pt-1 text-xs font-medium text-muted-foreground">
      <Route className="size-3.5" />
      {label}
    </div>
  );
}
