import type { ButtonHTMLAttributes, CSSProperties, HTMLAttributes, ReactNode } from "react";

import { STATE_CARD_TONES } from "@/components/dashboard/state-card-style";
import type { StateCardTone } from "@/components/dashboard/state-card-style";
import { cn } from "@/lib/utils";

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
