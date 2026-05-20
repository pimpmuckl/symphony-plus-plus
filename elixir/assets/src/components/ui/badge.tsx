import { cva, type VariantProps } from "class-variance-authority";
import * as React from "react";

import { cn } from "@/lib/utils";

const badgeVariants = cva(
  "inline-flex items-center rounded-md border px-2 py-0.5 text-xs font-medium transition-colors",
  {
    variants: {
      variant: {
        default: "border-transparent bg-primary text-primary-foreground",
        secondary: "border-transparent bg-secondary text-secondary-foreground",
        outline: "text-foreground",
        success: "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-700/70 dark:bg-emerald-950/50 dark:text-emerald-200",
        ready: "border-lime-200 bg-lime-50 text-lime-800 dark:border-lime-700/70 dark:bg-lime-950/50 dark:text-lime-200",
        warning: "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-700/70 dark:bg-amber-950/50 dark:text-amber-200",
        danger: "border-rose-200 bg-rose-50 text-rose-700 dark:border-rose-700/70 dark:bg-rose-950/50 dark:text-rose-200",
        info: "border-sky-200 bg-sky-50 text-sky-700 dark:border-sky-700/70 dark:bg-sky-950/50 dark:text-sky-200",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  },
);

export interface BadgeProps extends React.HTMLAttributes<HTMLDivElement>, VariantProps<typeof badgeVariants> {}

const Badge = React.forwardRef<HTMLDivElement, BadgeProps>(({ className, variant, ...props }, ref) => (
  <div ref={ref} className={cn(badgeVariants({ variant }), className)} {...props} />
));
Badge.displayName = "Badge";

export { Badge, badgeVariants };
