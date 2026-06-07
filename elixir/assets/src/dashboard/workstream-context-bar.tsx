import { FileText, GitBranch, Layers3 } from "lucide-react";
import type { RefObject } from "react";
import { useEffect, useMemo, useState } from "react";

const STICKY_CONTEXT_ACTIVE_THRESHOLD = 122;
const STICKY_CONTEXT_VISIBILITY_THRESHOLD = 150;
const MAX_CONTEXT_PLAN_NODES = 2;
type ContextPartKind = "plan" | "repo" | "request";
type RollDirection = "down" | "up";
type ContextState = {
  path: string[];
  direction: RollDirection;
  previousDisplayPath: string[];
  rollingParts: boolean[];
};
type RenderedContextPart = {
  current?: string;
  previous?: string;
  rolling: boolean;
};
type ContextPart = {
  kind: ContextPartKind;
  label: string;
};

export function contextPathValue(path: string[]) {
  return JSON.stringify(path.map((part) => part.trim()).filter(Boolean));
}

export function WorkstreamContextBar({
  boardRef,
  repoLabel,
  signature,
}: {
  boardRef: RefObject<HTMLDivElement | null>;
  repoLabel: string;
  signature: string;
}) {
  const [context, setContext] = useState<ContextState>({ path: [], direction: "down", previousDisplayPath: [], rollingParts: [] });
  const displayPath = useMemo(() => contextDisplayPath(repoLabel, context.path), [context.path, repoLabel]);
  const renderedPath = useMemo(() => {
    const length = Math.max(displayPath.length, context.previousDisplayPath.length);
    return Array.from({ length }, (_, index): RenderedContextPart => ({
      current: displayPath[index],
      previous: context.previousDisplayPath[index],
      rolling: context.rollingParts[index] === true,
    })).filter((part) => Boolean(part.current) || (part.rolling && Boolean(part.previous)));
  }, [context.previousDisplayPath, context.rollingParts, displayPath]);

  useEffect(() => {
    let frame = 0;
    let lastScrollY = window.scrollY;
    const update = () => {
      window.cancelAnimationFrame(frame);
      frame = window.requestAnimationFrame(() => {
        const scrollY = window.scrollY;
        const direction = scrollY >= lastScrollY ? "down" : "up";
        const path = activeContextPath(boardRef.current);
        lastScrollY = scrollY;
        setContext((current) => {
          if (samePath(current.path, path)) return current;

          const previousDisplayPath = contextDisplayPath(repoLabel, current.path);
          const nextDisplayPath = contextDisplayPath(repoLabel, path);
          const length = Math.max(previousDisplayPath.length, nextDisplayPath.length);
          return {
            path,
            direction,
            previousDisplayPath,
            rollingParts: Array.from({ length }, (_, index) => previousDisplayPath[index] !== nextDisplayPath[index]),
          };
        });
      });
    };
    const resizeObserver = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(update);

    update();
    window.addEventListener("scroll", update, { passive: true });
    window.addEventListener("resize", update);
    if (boardRef.current) resizeObserver?.observe(boardRef.current);

    return () => {
      window.cancelAnimationFrame(frame);
      window.removeEventListener("scroll", update);
      window.removeEventListener("resize", update);
      resizeObserver?.disconnect();
    };
  }, [boardRef, repoLabel, signature]);

  useEffect(() => {
    if (!context.rollingParts.some(Boolean)) return;

    const timeout = window.setTimeout(() => {
      setContext((current) => (
        samePath(current.path, context.path)
          ? { ...current, previousDisplayPath: [], rollingParts: [] }
          : current
      ));
    }, 260);

    return () => window.clearTimeout(timeout);
  }, [context.path, context.rollingParts]);

  if (context.path.length === 0 || displayPath.length === 0) return null;

  return (
    <div className="v3-workstream-context-slot">
      <div className="v3-workstream-context-bar" aria-label={`Current board position: ${displayPath.join(" / ")}`}>
        <GitBranch className="v3-workstream-context-leading-icon" aria-hidden="true" />
        <span className="v3-workstream-context-path" data-roll-direction={context.direction}>
          {renderedPath.map((part, index) => (
            <span key={index} className="v3-workstream-context-part">
              <RollingCrumb
                current={part.current}
                previous={part.previous}
                rolling={part.rolling}
                direction={context.direction}
                separator={index > 0}
                kind={contextPartKind(index)}
              />
            </span>
          ))}
        </span>
      </div>
    </div>
  );
}

function RollingCrumb({
  current,
  previous,
  rolling,
  direction,
  separator,
  kind,
}: {
  current?: string;
  previous?: string;
  rolling: boolean;
  direction: RollDirection;
  separator: boolean;
  kind: ContextPartKind;
}) {
  const shouldRoll = rolling && previous !== current;
  const hasPrevious = shouldRoll && Boolean(previous);
  const hasCurrent = Boolean(current);
  const rollMode = !shouldRoll ? "static" : hasPrevious && hasCurrent ? "replace" : hasCurrent ? "enter" : "exit";

  return (
    <span className="v3-workstream-context-wheel" data-roll-mode={rollMode} data-rolling={shouldRoll ? "true" : "false"} data-roll-direction={direction}>
      {hasPrevious ? (
        <span className="v3-workstream-context-line v3-workstream-context-line-previous" title={previous} aria-hidden="true">
          {separator ? <span className="v3-workstream-context-separator">/</span> : null}
          <ContextPartIcon kind={kind} />
          <span className="v3-workstream-context-crumb">{previous}</span>
        </span>
      ) : null}
      {hasCurrent ? (
        <span className="v3-workstream-context-line v3-workstream-context-line-current" title={current}>
          {separator ? <span className="v3-workstream-context-separator">/</span> : null}
          <ContextPartIcon kind={kind} />
          <span className="v3-workstream-context-crumb">{current}</span>
        </span>
      ) : null}
    </span>
  );
}

function ContextPartIcon({ kind }: { kind: ContextPartKind }) {
  if (kind === "repo") return null;
  const Icon = kind === "request" ? FileText : Layers3;
  return <Icon className="v3-workstream-context-kind-icon" aria-hidden="true" />;
}

function contextPartKind(index: number): ContextPartKind {
  if (index === 0) return "repo";
  return index === 1 ? "request" : "plan";
}

function activeContextPath(board: HTMLDivElement | null) {
  if (!board) return [];

  const markers = [...board.querySelectorAll<HTMLElement>("[data-v3-context-path]")].filter(elementIsVisible);
  if (markers.length === 0) return [];

  const boardRect = board.getBoundingClientRect();
  if (boardRect.top > STICKY_CONTEXT_VISIBILITY_THRESHOLD || boardRect.bottom <= STICKY_CONTEXT_VISIBILITY_THRESHOLD) return [];

  let active = markers[0];
  for (const marker of markers) {
    if (marker.getBoundingClientRect().top > STICKY_CONTEXT_ACTIVE_THRESHOLD) break;
    active = marker;
  }

  return parseContextPath(active.dataset.v3ContextPath);
}

function elementIsVisible(element: HTMLElement) {
  if (element.closest("[hidden]")) return false;

  const rect = element.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0;
}

function parseContextPath(value?: string) {
  if (!value) return [];

  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.filter((part): part is string => typeof part === "string" && part.trim().length > 0) : [];
  } catch {
    return [];
  }
}

function uniquePathParts(parts: string[]) {
  return parts.filter((part, index) => part && part !== parts[index - 1]);
}

function contextDisplayPath(repoLabel: string, path: string[]) {
  const [request, ...planNodes] = path;
  const parts: ContextPart[] = [
    { kind: "repo", label: repoLabel },
    ...(request ? [{ kind: "request" as const, label: request }] : []),
    ...planNodes.slice(-MAX_CONTEXT_PLAN_NODES).map((label) => ({ kind: "plan" as const, label })),
  ];

  return uniquePathParts(parts.map((part) => part.label));
}

function samePath(left: string[], right: string[]) {
  return left.length === right.length && left.every((part, index) => part === right[index]);
}
