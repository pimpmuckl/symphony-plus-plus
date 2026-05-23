import type { ButtonHTMLAttributes, CSSProperties, HTMLAttributes, ReactNode } from "react";

import { cn } from "@/lib/utils";

export type SignalTone = "muted" | "info" | "warning" | "danger" | "success";
export type StateCardTone = "request" | "queued" | "slice" | "implementing" | "review" | "merge" | "guidance" | "blocked" | "finished" | "muted";

type StateToneStyle = {
  card: string;
  accent: string;
};

const STATE_CARD_TONES: Record<StateCardTone, StateToneStyle> = {
  request: { card: "border-slate-200 bg-slate-50/80 dark:border-slate-700/80 dark:bg-slate-900/70", accent: "rgb(203 213 225)" },
  queued: { card: "border-teal-200/80 bg-teal-50/80 dark:border-teal-700/70 dark:bg-teal-950/45", accent: "rgb(45 212 191)" },
  slice: { card: "border-cyan-200/80 bg-cyan-50/80 dark:border-cyan-700/70 dark:bg-cyan-950/45", accent: "rgb(34 211 238)" },
  implementing: { card: "border-sky-200/80 bg-sky-50/80 dark:border-sky-700/70 dark:bg-sky-950/45", accent: "rgb(56 189 248)" },
  review: { card: "border-indigo-200/80 bg-indigo-50/80 dark:border-indigo-700/70 dark:bg-indigo-950/45", accent: "rgb(129 140 248)" },
  merge: { card: "border-lime-200/80 bg-lime-50/80 dark:border-lime-700/70 dark:bg-lime-950/45", accent: "rgb(163 230 53)" },
  guidance: { card: "border-violet-200/80 bg-violet-50/80 dark:border-violet-700/70 dark:bg-violet-950/45", accent: "rgb(167 139 250)" },
  blocked: { card: "border-rose-200/80 bg-rose-50/80 dark:border-rose-700/70 dark:bg-rose-950/45", accent: "rgb(251 113 133)" },
  finished: { card: "border-emerald-200/80 bg-emerald-50/80 dark:border-emerald-700/70 dark:bg-emerald-950/45", accent: "rgb(52 211 153)" },
  muted: { card: "border-zinc-200/80 bg-zinc-50/80 dark:border-zinc-700/80 dark:bg-zinc-900/70", accent: "rgb(212 212 216)" },
};

const CARD_SIGNAL_TONE_CLASSES: Record<SignalTone, string> = {
  muted: "border-transparent bg-muted text-foreground",
  info: "border-sky-200 bg-sky-50 text-sky-800 dark:border-sky-700/70 dark:bg-sky-950/50 dark:text-sky-200",
  warning: "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-700/70 dark:bg-amber-950/50 dark:text-amber-200",
  danger: "border-rose-200 bg-rose-50 text-rose-800 dark:border-rose-700/70 dark:bg-rose-950/50 dark:text-rose-200",
  success: "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-700/70 dark:bg-emerald-950/50 dark:text-emerald-200",
};

export function wireToneStyle(tone: StateCardTone) {
  return { "--wire-color": STATE_CARD_TONES[tone].accent } as CSSProperties;
}

type StateCardBaseProps = {
  children: ReactNode;
  className?: string;
  style?: CSSProperties;
  tone: StateCardTone;
};

type StateCardProps =
  | (Omit<HTMLAttributes<HTMLDivElement>, "children" | "className" | "style"> & StateCardBaseProps & { as?: "div" })
  | (Omit<ButtonHTMLAttributes<HTMLButtonElement>, "children" | "className" | "style"> & StateCardBaseProps & { as: "button" });

export function StateCard(props: StateCardProps) {
  const { as = "div", children, className, style, tone, ...elementProps } = props;
  const toneStyle = STATE_CARD_TONES[tone];
  const frameClassName = cn(
    "min-w-0 max-w-full rounded-lg border border-l-4 shadow-sm transition-[background-color,border-color,box-shadow,transform] duration-150 ease-out",
    toneStyle.card,
    className,
  );
  const frameStyle = { ...style, "--state-accent": toneStyle.accent, borderLeftColor: toneStyle.accent } as CSSProperties;

  if (as === "button") {
    const { type = "button", ...buttonProps } = elementProps as ButtonHTMLAttributes<HTMLButtonElement>;

    return (
      <button type={type} className={frameClassName} style={frameStyle} {...buttonProps}>
        {children}
      </button>
    );
  }

  return (
    <div
      className={frameClassName}
      style={frameStyle}
      {...(elementProps as HTMLAttributes<HTMLDivElement>)}
    >
      {children}
    </div>
  );
}

export function CardSignal({
  label,
  value,
  tone,
  className,
  onClick,
  ariaLabel,
}: {
  label: string;
  value: string;
  tone: SignalTone;
  className?: string;
  onClick?: () => void;
  ariaLabel?: string;
}) {
  const signalClassName = cn(
    "min-w-0 max-w-full w-full rounded-md border px-2.5 py-2 text-xs",
    CARD_SIGNAL_TONE_CLASSES[tone],
    onClick &&
      "card-signal-action cursor-pointer text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-2",
    className,
  );
  const content = (
    <>
      <p className="text-[11px] leading-none opacity-70">{label}</p>
      <p className="mt-1 truncate font-semibold">{value}</p>
    </>
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
        data-card-signal
      >
        {content}
      </button>
    );
  }

  return (
    <div className={signalClassName} data-card-signal>
      {content}
    </div>
  );
}
