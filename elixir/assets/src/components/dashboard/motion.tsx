import { Children, isValidElement, useEffect, useLayoutEffect, useReducer, useRef, useState } from "react";
import type { ComponentProps, ReactNode } from "react";

import { Badge } from "@/components/ui/badge";
import {
  clearMotionTimers,
  dashboardPrefersReducedMotion,
  later,
  measureElementHeight,
  nextFrame,
} from "@/components/dashboard/motion-utils";
import { cn } from "@/lib/utils";

export const TOP_PANEL_RESIZE_MS = 210;
export const TOP_PANEL_SLIDE_MS = 360;
export const WORKSPACE_TAB_SLIDE_MS = 360;
export const UPDATE_ANIMATION_TTL_MS = 4000;

const CARD_BODY_RESIZE_MS = TOP_PANEL_RESIZE_MS;
const CARD_BODY_CONTENT_MS = TOP_PANEL_SLIDE_MS;
const BADGE_TEXT_PUSH_MS = 3200;
const BADGE_RESIZE_MS = 400;

export type UpdateMotionKind = "added" | "changed" | "guidance" | "blocker" | "finished" | "removed";
export type UpdateMotion = { kind: UpdateMotionKind | "settled"; token: number };

type BadgePushPhase = "idle" | "measure" | "resize-first" | "push" | "resize-last";
type CardBodySizePhase = "idle" | "pre-grow" | "enter" | "pre-shrink" | "post-shrink";

type AnimatedBadgeState = {
  currentLabel: string;
  previousLabel: string | null;
  phase: BadgePushPhase;
  width: number | null;
};
type AnimatedBadgeAction =
  | { type: "replace"; state: AnimatedBadgeState }
  | { type: "patch"; state: Partial<AnimatedBadgeState> };

type AnimatedCardBodyState = {
  targetKey: string;
  renderedChildren: ReactNode;
  phase: CardBodySizePhase;
  height: number | "auto";
};

type AnimatedCardBodyAction =
  | { type: "replace"; state: AnimatedCardBodyState }
  | { type: "patch"; state: Partial<AnimatedCardBodyState> };

export function useCountMotion(value: number, pulseToken = 0) {
  const currentRef = useRef(value);
  const pulseRef = useRef(pulseToken);
  const tokenRef = useRef(0);
  const [motion, setMotion] = useState({
    active: false,
    direction: "idle" as "idle" | "up" | "down",
    previous: value,
    token: 0,
  });

  useEffect(() => {
    const previous = currentRef.current;
    const pulsing = pulseRef.current !== pulseToken;
    if (previous === value && !pulsing) return;

    pulseRef.current = pulseToken;
    currentRef.current = value;
    const token = (tokenRef.current += 1);
    const direction = value >= previous ? "up" : "down";
    const displayedPrevious = pulsing && previous === value ? Math.max(0, value - 1) : previous;

    setMotion({ active: true, direction, previous: displayedPrevious, token });

    const timer = window.setTimeout(() => {
      setMotion({ active: false, direction: "idle", previous: value, token });
    }, 760);

    return () => window.clearTimeout(timer);
  }, [pulseToken, value]);

  return motion;
}

export function NumberWheel({
  value,
  motion,
  compact = false,
}: {
  value: number;
  motion: ReturnType<typeof useCountMotion>;
  compact?: boolean;
}) {
  return (
    <span
      key={motion.token}
      className={cn("number-wheel", compact && "number-wheel-compact")}
      data-direction={motion.active ? motion.direction : undefined}
      data-animating={motion.active ? "true" : undefined}
    >
      <span className="number-wheel-value number-wheel-old">{motion.previous}</span>
      <span className="number-wheel-value number-wheel-new">{value}</span>
    </span>
  );
}

export function AnimatedTopGrid({ children, className }: { children: ReactNode; className?: string }) {
  const layoutKey = Children.toArray(children)
    .map((child, index) => (isValidElement(child) ? child.key ?? index : index))
    .join("|");
  const flipRef = useFlipList(layoutKey);

  return (
    <div className={className} ref={flipRef}>
      {children}
    </div>
  );
}

export function AnimatedBadge({
  label,
  variant,
  className,
}: {
  label: string;
  variant?: ComponentProps<typeof Badge>["variant"];
  className?: string;
}) {
  const [state, dispatch] = useReducer(animatedBadgeReducer, label, initialAnimatedBadgeState);
  const badgeRef = useRef<HTMLDivElement | null>(null);
  const currentTextRef = useRef<HTMLSpanElement | null>(null);
  const measureRef = useRef<HTMLSpanElement | null>(null);
  const timersRef = useRef<number[]>([]);
  const framesRef = useRef<number[]>([]);

  useEffect(
    () => () => {
      clearMotionTimers(timersRef, framesRef);
    },
    [],
  );

  useLayoutEffect(() => {
    if (label === state.currentLabel) return;

    clearMotionTimers(timersRef, framesRef);

    const oldWidth = measureElementWidth(badgeRef.current);
    const oldTextWidth = measureElementWidth(currentTextRef.current);
    const chromeWidth = Math.max(0, oldWidth - oldTextWidth);

    dispatch({ type: "replace", state: { currentLabel: label, previousLabel: state.currentLabel, phase: "measure", width: oldWidth } });

    nextFrame(framesRef, () => {
      const newTextWidth = measureElementWidth(measureRef.current);
      const newWidth = Math.ceil(newTextWidth + chromeWidth);
      const wider = newWidth > oldWidth + 1;

      if (wider) {
        dispatch({ type: "patch", state: { phase: "resize-first", width: newWidth } });

        later(timersRef, BADGE_RESIZE_MS, () => {
          dispatch({ type: "patch", state: { phase: "push" } });
          later(timersRef, BADGE_TEXT_PUSH_MS, () =>
            dispatch({ type: "patch", state: { previousLabel: null, phase: "idle", width: null } }),
          );
        });
      } else {
        dispatch({ type: "patch", state: { phase: "push" } });

        later(timersRef, BADGE_TEXT_PUSH_MS, () => {
          dispatch({ type: "patch", state: { phase: "resize-last", width: newWidth } });
          later(timersRef, BADGE_RESIZE_MS, () =>
            dispatch({ type: "patch", state: { previousLabel: null, phase: "idle", width: null } }),
          );
        });
      }
    });
  }, [label, state.currentLabel]);

  const renderMeasure = label !== state.currentLabel || state.phase !== "idle";

  return (
    <Badge
      ref={badgeRef}
      variant={variant}
      className={cn("state-update-badge", className)}
      data-badge-phase={state.phase}
      data-badge-has-previous={state.previousLabel ? "true" : "false"}
      style={state.width === null ? undefined : { width: `${Math.max(state.width, 0)}px` }}
    >
      {renderMeasure ? (
        <span ref={measureRef} className="badge-push-measure">
          {state.currentLabel}
        </span>
      ) : null}
      <span className="badge-push-stack">
        {state.previousLabel ? <span className="badge-push-old">{state.previousLabel}</span> : null}
        <span ref={currentTextRef} className="badge-push-new">
          {state.currentLabel}
        </span>
      </span>
    </Badge>
  );
}

export function AnimatedCardBody({ motionKey, children }: { motionKey: string; children: ReactNode }) {
  const visibleRef = useRef<HTMLDivElement | null>(null);
  const frameRef = useRef<HTMLDivElement | null>(null);
  const measureRef = useRef<HTMLDivElement | null>(null);
  const timersRef = useRef<number[]>([]);
  const framesRef = useRef<number[]>([]);
  const [state, dispatch] = useReducer(animatedCardBodyReducer, {
    targetKey: motionKey,
    renderedChildren: children,
    phase: "idle",
    height: "auto",
  });

  useEffect(
    () => () => {
      clearMotionTimers(timersRef, framesRef);
    },
    [],
  );

  useLayoutEffect(() => {
    if (motionKey === state.targetKey) return;

    clearMotionTimers(timersRef, framesRef);

    if (dashboardPrefersReducedMotion()) {
      dispatch({ type: "replace", state: { targetKey: motionKey, renderedChildren: children, phase: "idle", height: "auto" } });
      return;
    }

    const oldHeight = measureElementHeight(frameRef.current) || measureElementHeight(visibleRef.current);
    const newHeight = measureElementHeight(measureRef.current);

    if (Math.abs(newHeight - oldHeight) <= 2) {
      dispatch({ type: "replace", state: { targetKey: motionKey, renderedChildren: children, phase: "idle", height: "auto" } });
      return;
    }

    if (newHeight > oldHeight) {
      dispatch({
        type: "replace",
        state: {
          targetKey: motionKey,
          renderedChildren: state.renderedChildren,
          phase: "pre-grow",
          height: oldHeight,
        },
      });
      nextFrame(framesRef, () => dispatch({ type: "patch", state: { height: newHeight } }));
      later(timersRef, CARD_BODY_RESIZE_MS, () => {
        dispatch({ type: "patch", state: { renderedChildren: children, phase: "enter", height: newHeight } });
        later(timersRef, CARD_BODY_CONTENT_MS, () => {
          dispatch({ type: "patch", state: { phase: "idle", height: "auto" } });
        });
      });
      return;
    }

    dispatch({
      type: "replace",
      state: {
        targetKey: motionKey,
        renderedChildren: children,
        phase: "pre-shrink",
        height: oldHeight,
      },
    });
    later(timersRef, CARD_BODY_CONTENT_MS, () => {
      dispatch({ type: "patch", state: { phase: "post-shrink" } });
      nextFrame(framesRef, () => dispatch({ type: "patch", state: { height: newHeight } }));
      later(timersRef, CARD_BODY_RESIZE_MS, () => {
        dispatch({ type: "patch", state: { phase: "idle", height: "auto" } });
      });
    });
  }, [children, motionKey, state.renderedChildren, state.targetKey]);

  const renderedChildren = state.phase === "idle" && state.targetKey === motionKey ? children : state.renderedChildren;
  const renderMeasure = motionKey !== state.targetKey || state.phase !== "idle";

  return (
    <div className="state-card-size-shell">
      {renderMeasure ? (
        <div ref={measureRef} className="state-card-size-measure" aria-hidden="true">
          <div className="state-card-size-inner">{children}</div>
        </div>
      ) : null}
      <div
        ref={frameRef}
        className="state-card-size-frame"
        data-card-size-phase={state.phase === "enter" ? "enter" : state.phase === "idle" ? "idle" : "sizing"}
        style={state.height === "auto" ? undefined : { height: `${Math.max(state.height, 0)}px` }}
      >
        <div ref={visibleRef} className="state-card-size-inner">
          {renderedChildren}
        </div>
      </div>
    </div>
  );
}

function useFlipList(layoutKey: string) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const previousRectsRef = useRef<Map<string, DOMRect> | null>(null);

  useLayoutEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const previousRects = previousRectsRef.current ?? new Map<string, DOMRect>();
    const nextRects = new Map<string, DOMRect>();
    const nodes = Array.from(container.querySelectorAll<HTMLElement>("[data-flip-id]"));

    nodes.forEach((node) => {
      const id = node.dataset.flipId;
      if (!id) return;

      const rect = node.getBoundingClientRect();
      const previous = previousRects.get(id);
      nextRects.set(id, rect);

      if (!previous) return;

      const deltaX = previous.left - rect.left;
      const deltaY = previous.top - rect.top;
      if (Math.abs(deltaX) < 1 && Math.abs(deltaY) < 1) return;

      node.animate(
        [
          { transform: `translate3d(${deltaX}px, ${deltaY}px, 0)` },
          { transform: "translate3d(0, 0, 0)" },
        ],
        {
          duration: 360,
          easing: "cubic-bezier(0.16, 1, 0.3, 1)",
        },
      );
    });

    previousRectsRef.current = nextRects;
  }, [layoutKey]);

  return containerRef;
}

function initialAnimatedBadgeState(label: string): AnimatedBadgeState {
  return {
    currentLabel: label,
    previousLabel: null,
    phase: "idle",
    width: null,
  };
}

function animatedBadgeReducer(state: AnimatedBadgeState, action: AnimatedBadgeAction): AnimatedBadgeState {
  if (action.type === "replace") return action.state;
  return { ...state, ...action.state };
}

function animatedCardBodyReducer(state: AnimatedCardBodyState, action: AnimatedCardBodyAction): AnimatedCardBodyState {
  if (action.type === "replace") return action.state;
  return { ...state, ...action.state };
}

function measureElementWidth(element: HTMLElement | null) {
  return element?.getBoundingClientRect().width || 0;
}
