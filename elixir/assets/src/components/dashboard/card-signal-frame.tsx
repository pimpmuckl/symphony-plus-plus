import type { ReactNode } from "react";

import { CARD_SIGNAL_TONE_CLASSES } from "@/components/dashboard/state-card-style";
import type { SignalTone } from "@/components/dashboard/state-card-style";
import { cn } from "@/lib/utils";

export function CardSignalFrame({
  children,
  tone,
  className,
  onClick,
  ariaLabel,
  title,
}: {
  children: ReactNode;
  tone: SignalTone;
  className?: string;
  onClick?: () => void;
  ariaLabel?: string;
  title?: string;
}) {
  const signalClassName = cn(
    "min-w-0 max-w-full rounded-md border text-xs",
    CARD_SIGNAL_TONE_CLASSES[tone],
    onClick &&
      "card-signal-action cursor-pointer text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-2",
    className,
  );

  if (onClick) {
    return (
      <button
        type="button"
        className={signalClassName}
        onClick={(event) => {
          event.stopPropagation();
          onClick();
        }}
        aria-label={ariaLabel}
        title={title}
        data-card-signal
      >
        {children}
      </button>
    );
  }

  return (
    <div className={signalClassName} aria-label={ariaLabel} title={title} data-card-signal>
      {children}
    </div>
  );
}
