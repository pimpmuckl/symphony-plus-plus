import * as React from "react";

import { cn } from "@/lib/utils";

function Card({ className, ref, ...props }: React.ComponentProps<"div">) {
  return <div ref={ref} className={cn("rounded-lg border bg-card text-card-foreground shadow-sm", className)} {...props} />;
}
Card.displayName = "Card";

function CardHeader({ className, ref, ...props }: React.ComponentProps<"div">) {
  return <div ref={ref} className={cn("flex flex-col space-y-1.5 p-5", className)} {...props} />;
}
CardHeader.displayName = "CardHeader";

function CardTitle({ className, children, ref, ...props }: React.ComponentProps<"h3">) {
  return (
    <h3 ref={ref} className={cn("text-base font-semibold leading-none tracking-normal", className)} {...props}>
      {children}
    </h3>
  );
}
CardTitle.displayName = "CardTitle";

function CardDescription({ className, ref, ...props }: React.ComponentProps<"p">) {
  return <p ref={ref} className={cn("text-sm text-muted-foreground", className)} {...props} />;
}
CardDescription.displayName = "CardDescription";

function CardContent({ className, ref, ...props }: React.ComponentProps<"div">) {
  return <div ref={ref} className={cn("p-5 pt-0", className)} {...props} />;
}
CardContent.displayName = "CardContent";

export { Card, CardContent, CardDescription, CardHeader, CardTitle };
