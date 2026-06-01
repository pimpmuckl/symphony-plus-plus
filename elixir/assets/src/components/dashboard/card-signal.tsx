import { CardSignalFrame } from "@/components/dashboard/card-signal-frame";
import type { SignalTone } from "@/components/dashboard/state-card-style";
import { cn } from "@/lib/utils";

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
  return (
    <CardSignalFrame
      tone={tone}
      className={cn("w-full px-2.5 py-2", className)}
      onClick={onClick}
      ariaLabel={ariaLabel}
    >
      <p className="text-[11px] leading-none opacity-70">{label}</p>
      <p className="mt-1 truncate font-semibold">{value}</p>
    </CardSignalFrame>
  );
}
