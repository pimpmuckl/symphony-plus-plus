import * as React from "react";

import { badgeVariants } from "@/components/ui/badge-style";
import type { BadgeProps } from "@/components/ui/badge-style";
import { cn } from "@/lib/utils";

function Badge({ className, variant, ref, ...props }: BadgeProps) {
  return <div ref={ref} className={cn(badgeVariants({ variant }), className)} {...props} />;
}
Badge.displayName = "Badge";

export { Badge };
