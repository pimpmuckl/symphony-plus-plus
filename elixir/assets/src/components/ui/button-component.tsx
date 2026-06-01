import { Slot } from "@radix-ui/react-slot";
import * as React from "react";

import { buttonVariants } from "@/components/ui/button-style";
import type { ButtonProps } from "@/components/ui/button-style";
import { cn } from "@/lib/utils";

function Button({ className, variant, size, asChild = false, ref, ...props }: ButtonProps) {
  const Comp = asChild ? Slot : "button";
  return <Comp className={cn(buttonVariants({ variant, size, className }))} ref={ref} {...props} />;
}
Button.displayName = "Button";

export { Button };
