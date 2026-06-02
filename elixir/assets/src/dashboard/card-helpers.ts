import type * as React from "react";

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
