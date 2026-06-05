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
