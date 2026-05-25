import * as DialogPrimitive from "@radix-ui/react-dialog";
import { X } from "lucide-react";
import * as React from "react";

import { cn } from "@/lib/utils";

const Dialog = DialogPrimitive.Root;
const DialogTrigger = DialogPrimitive.Trigger;
const DialogPortal = DialogPrimitive.Portal;
const DialogClose = DialogPrimitive.Close;
const DIALOG_SIZE_MOTION_MS = 240;

function DialogOverlay({ className, ref, ...props }: React.ComponentProps<typeof DialogPrimitive.Overlay>) {
  return (
    <DialogPrimitive.Overlay
      ref={ref}
      className={cn("dialog-overlay fixed inset-0 z-50", className)}
      {...props}
    />
  );
}
DialogOverlay.displayName = DialogPrimitive.Overlay.displayName;

function DialogContent({ className, children, ref, style, ...props }: React.ComponentProps<typeof DialogPrimitive.Content>) {
  const contentRef = React.useRef<HTMLDivElement | null>(null);
  const innerRef = React.useRef<HTMLDivElement | null>(null);
  const frameRef = React.useRef<number | null>(null);
  const settleTimerRef = React.useRef<number | null>(null);
  const [height, setHeight] = React.useState<number | null>(null);

  const setContentRef = React.useCallback(
    (node: HTMLDivElement | null) => {
      contentRef.current = node;

      if (typeof ref === "function") {
        ref(node);
      } else if (ref) {
        ref.current = node;
      }
    },
    [ref],
  );

  const measure = React.useCallback(() => {
    const content = contentRef.current;
    const inner = innerRef.current;
    if (!content || !inner || prefersReducedDialogMotion()) return;

    const currentHeight = Math.ceil(content.getBoundingClientRect().height);
    const nextHeight = Math.ceil(content.scrollHeight);
    if (currentHeight <= 0 || nextHeight <= 0 || Math.abs(nextHeight - currentHeight) <= 1) return;

    if (frameRef.current !== null) {
      window.cancelAnimationFrame(frameRef.current);
    }

    if (settleTimerRef.current !== null) {
      window.clearTimeout(settleTimerRef.current);
    }

    setHeight(currentHeight);
    frameRef.current = window.requestAnimationFrame(() => {
      setHeight(nextHeight);
      frameRef.current = null;
    });

    settleTimerRef.current = window.setTimeout(() => {
      setHeight(null);
      settleTimerRef.current = null;
    }, DIALOG_SIZE_MOTION_MS + 80);
  }, []);

  React.useLayoutEffect(() => {
    if (prefersReducedDialogMotion()) return;

    const frame = window.requestAnimationFrame(measure);
    return () => window.cancelAnimationFrame(frame);
  }, [children, measure]);

  React.useEffect(() => {
    const inner = innerRef.current;
    if (!inner || typeof ResizeObserver === "undefined" || prefersReducedDialogMotion()) return;

    const observer = new ResizeObserver(() => {
      if (frameRef.current !== null) {
        window.cancelAnimationFrame(frameRef.current);
      }

      frameRef.current = window.requestAnimationFrame(() => {
        measure();
        frameRef.current = null;
      });
    });

    observer.observe(inner);

    return () => {
      observer.disconnect();

      if (frameRef.current !== null) {
        window.cancelAnimationFrame(frameRef.current);
        frameRef.current = null;
      }

      if (settleTimerRef.current !== null) {
        window.clearTimeout(settleTimerRef.current);
        settleTimerRef.current = null;
      }
    };
  }, [measure]);

  return (
    <DialogPortal>
      <DialogOverlay />
      <DialogPrimitive.Content
        ref={setContentRef}
        className={cn(
          "dialog-content fixed left-1/2 top-1/2 z-50 max-h-[88vh] w-[calc(100vw-2rem)] max-w-3xl -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-lg border bg-background p-6 shadow-dashboard focus:outline-none",
          height !== null && "dialog-content-sizing",
          className,
        )}
        style={height === null ? style : { ...style, height }}
        {...props}
      >
        <div ref={innerRef} className="dialog-content-inner">
          {children}
        </div>
        <DialogPrimitive.Close className="absolute right-4 top-4 rounded-md p-1 text-muted-foreground opacity-70 transition-opacity hover:opacity-100 focus:outline-none focus:ring-2 focus:ring-ring">
          <X className="size-4" />
          <span className="sr-only">Close</span>
        </DialogPrimitive.Close>
      </DialogPrimitive.Content>
    </DialogPortal>
  );
}
DialogContent.displayName = DialogPrimitive.Content.displayName;

function prefersReducedDialogMotion() {
  return typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

const DialogHeader = ({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) => (
  <div className={cn("flex flex-col space-y-2 text-left", className)} {...props} />
);
DialogHeader.displayName = "DialogHeader";

const DialogFooter = ({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) => (
  <div className={cn("flex flex-col-reverse gap-2 sm:flex-row sm:justify-end", className)} {...props} />
);
DialogFooter.displayName = "DialogFooter";

function DialogTitle({ className, ref, ...props }: React.ComponentProps<typeof DialogPrimitive.Title>) {
  return <DialogPrimitive.Title ref={ref} className={cn("text-lg font-semibold leading-none tracking-normal", className)} {...props} />;
}
DialogTitle.displayName = DialogPrimitive.Title.displayName;

function DialogDescription({ className, ref, ...props }: React.ComponentProps<typeof DialogPrimitive.Description>) {
  return <DialogPrimitive.Description ref={ref} className={cn("text-sm text-muted-foreground", className)} {...props} />;
}
DialogDescription.displayName = DialogPrimitive.Description.displayName;

export {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogPortal,
  DialogTitle,
  DialogTrigger,
};
