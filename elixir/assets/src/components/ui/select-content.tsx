import * as SelectPrimitive from "@radix-ui/react-select";
import * as React from "react";

import { cn } from "@/lib/utils";

function SelectContent({ className, children, position = "popper", ref, ...props }: React.ComponentProps<typeof SelectPrimitive.Content>) {
  return (
    <SelectPrimitive.Portal>
      <SelectPrimitive.Content
        ref={ref}
        className={cn(
          "relative z-50 max-h-80 min-w-[8rem] overflow-hidden rounded-md border bg-popover text-popover-foreground shadow-md",
          position === "popper" && "data-[side=bottom]:translate-y-1 data-[side=top]:-translate-y-1",
          className,
        )}
        position={position}
        {...props}
      >
        <SelectPrimitive.Viewport className={cn("p-1", position === "popper" && "h-[var(--radix-select-trigger-height)] w-full min-w-[var(--radix-select-trigger-width)]")}>
          {children}
        </SelectPrimitive.Viewport>
      </SelectPrimitive.Content>
    </SelectPrimitive.Portal>
  );
}
SelectContent.displayName = SelectPrimitive.Content.displayName;

export { SelectContent };
