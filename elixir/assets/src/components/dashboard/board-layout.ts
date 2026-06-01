import type { RefObject } from "react";
import { useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from "react";

import { dashboardPrefersReducedMotion } from "@/components/dashboard/motion-utils";

export const ALIGNED_ROW_MIN_HEIGHT = 112;
const ALIGNED_SLOT_MIN_HEIGHT = 76;
const BOARD_LAYOUT_MOTION_MS = 360;
const BOARD_LAYOUT_VISIBILITY_ROOT_MARGIN = "1000px 0px";

export type BoardLayoutMode = "jira" | "aligned";

export type BoardLayoutMeasurementRow = {
  activeSlotKeys: string[];
  minHeight: number;
  rowKey: string;
};

export function useBoardLayoutMotion(
  shellRef: RefObject<HTMLDivElement | null>,
  boardRef: RefObject<HTMLDivElement | null>,
  motionKey: string,
) {
  const [active, dispatchLayoutActive] = useReducer(booleanReducer, false);
  const previousKeyRef = useRef(motionKey);
  const lastHeightRef = useRef<number | null>(null);
  const timersRef = useRef<number[]>([]);

  useEffect(
    () => () => {
      timersRef.current.forEach((timer) => window.clearTimeout(timer));
      timersRef.current = [];
    },
    [],
  );

  useLayoutEffect(() => {
    const board = boardRef.current;
    if (!board) return;

    let frame: number | null = null;
    const syncHeight = () => {
      if (frame !== null) return;
      frame = window.requestAnimationFrame(() => {
        frame = null;
        if (!active && previousKeyRef.current === motionKey) {
          lastHeightRef.current = measureBoardHeight(board);
        }
      });
    };

    syncHeight();

    const observer = new ResizeObserver(syncHeight);
    observer.observe(board);

    return () => {
      if (frame !== null) {
        window.cancelAnimationFrame(frame);
      }
      observer.disconnect();
    };
  }, [active, boardRef, motionKey]);

  useLayoutEffect(() => {
    const shell = shellRef.current;
    const board = boardRef.current;
    if (!shell || !board) return;

    const measuredHeight = measureBoardHeight(board);
    if (dashboardPrefersReducedMotion()) {
      lastHeightRef.current = measuredHeight;
      previousKeyRef.current = motionKey;
      return;
    }

    if (lastHeightRef.current === null) {
      lastHeightRef.current = measuredHeight;
      previousKeyRef.current = motionKey;
      return;
    }

    if (previousKeyRef.current === motionKey) {
      lastHeightRef.current = measuredHeight;
      return;
    }

    timersRef.current.forEach((timer) => window.clearTimeout(timer));
    timersRef.current = [];

    const startHeight = lastHeightRef.current;
    const previousStyleText = shell.getAttribute("style");
    previousKeyRef.current = motionKey;
    lastHeightRef.current = measuredHeight;
    dispatchLayoutActive(true);

    applyBoardShellMotionStyle(shell, previousStyleText, startHeight);

    const syncHeight = () => {
      const nextHeight = measureBoardHeight(board);
      if (nextHeight <= 0) return;
      lastHeightRef.current = nextHeight;
      shell.style.height = `${nextHeight}px`;
    };

    const observer = new ResizeObserver(syncHeight);
    observer.observe(board);

    void shell.offsetHeight;
    syncHeight();

    let settled = false;
    const settleTimer = window.setTimeout(() => {
      settled = true;
      observer.disconnect();
      timersRef.current = timersRef.current.filter((timer) => timer !== settleTimer);
      lastHeightRef.current = measureBoardHeight(board);
      restoreElementStyle(shell, previousStyleText);
      dispatchLayoutActive(false);
    }, BOARD_LAYOUT_MOTION_MS + 90);
    timersRef.current.push(settleTimer);

    return () => {
      observer.disconnect();
      if (settled) return;
      window.clearTimeout(settleTimer);
      timersRef.current = timersRef.current.filter((timer) => timer !== settleTimer);
      restoreElementStyle(shell, previousStyleText);
      dispatchLayoutActive(false);
    };
  }, [boardRef, motionKey, shellRef]);

  return active;
}

function booleanReducer(current: boolean, next: boolean) {
  return current === next ? current : next;
}

export function useAlignedBoardLayout(
  boardRef: RefObject<HTMLDivElement | null>,
  rows: BoardLayoutMeasurementRow[],
  layoutMode: BoardLayoutMode,
) {
  const baseHeights = useMemo(() => rows.map((row) => row.minHeight), [rows]);
  const measurementKey = useMemo(
    () => rows.map(({ activeSlotKeys, minHeight, rowKey }) => `${rowKey}:${minHeight}:${activeSlotKeys.join(",")}`).join("|"),
    [rows],
  );
  const [measuredLayout, setMeasuredLayout] = useState<{ key: string; rowHeights: number[]; slotTemplates: Record<string, string> }>({
    key: "",
    rowHeights: [],
    slotTemplates: {},
  });

  useLayoutEffect(() => {
    const board = boardRef.current;
    if (!board || layoutMode !== "aligned") return;

    let active = false;
    let frame: number | null = null;
    const timers: number[] = [];
    let resizeObserver: ResizeObserver | null = null;
    let listeningForResize = false;

    const measure = () => {
      frame = null;
      if (!active) return;
      const rowIndex = new Map(rows.map((row, index) => [row.rowKey, index]));
      const rowHeights = [...baseHeights];
      const slotHeightsByRow = new Map<string, Map<string, number>>();

      board.querySelectorAll<HTMLElement>(".aligned-card-slot[data-feature-row][data-slot-key]").forEach((slotNode) => {
        const rowKey = slotNode.dataset.featureRow;
        const slotKey = slotNode.dataset.slotKey;
        if (!rowKey || !slotKey) return;

        const height = alignedSlotContentHeight(slotNode);
        if (height <= 0) return;

        const slotHeights = slotHeightsByRow.get(rowKey) || new Map<string, number>();
        slotHeights.set(slotKey, Math.max(slotHeights.get(slotKey) || 0, height));
        slotHeightsByRow.set(rowKey, slotHeights);
      });

      board.querySelectorAll<HTMLElement>(".feature-lane-row[data-feature-row]").forEach((rowNode) => {
        const index = rowIndex.get(rowNode.dataset.featureRow || "");
        if (index === undefined) return;
        rowHeights[index] = Math.max(rowHeights[index], featureRowContentHeight(rowNode));
      });

      const slotTemplates = rows.reduce<Record<string, string>>((result, { activeSlotKeys, rowKey }) => {
        if (activeSlotKeys.length === 0) return result;

        const rowHeights = slotHeightsByRow.get(rowKey);
        result[rowKey] = activeSlotKeys
          .map((slotKey) => `${Math.max(ALIGNED_SLOT_MIN_HEIGHT, Math.ceil(rowHeights?.get(slotKey) || 0))}px`)
          .join(" ");
        return result;
      }, {});

      setMeasuredLayout((previous) =>
        previous.key === measurementKey && sameNumbers(previous.rowHeights, rowHeights) && sameStringRecords(previous.slotTemplates, slotTemplates)
          ? previous
          : { key: measurementKey, rowHeights, slotTemplates },
      );
    };

    const schedule = () => {
      if (!active) return;
      if (frame !== null) return;
      frame = window.requestAnimationFrame(measure);
    };

    const clearTimers = () => {
      while (timers.length > 0) {
        const timer = timers.pop();
        if (timer !== undefined) window.clearTimeout(timer);
      }
    };

    const stopMeasuring = () => {
      if (!active) return;
      active = false;
      if (frame !== null) {
        window.cancelAnimationFrame(frame);
        frame = null;
      }
      clearTimers();
      resizeObserver?.disconnect();
      resizeObserver = null;
      if (listeningForResize) {
        window.removeEventListener("resize", schedule);
        listeningForResize = false;
      }
    };

    const startMeasuring = () => {
      if (active) return;
      active = true;

      resizeObserver = new ResizeObserver(schedule);
      resizeObserver.observe(board);
      board.querySelectorAll<HTMLElement>(".stagger-item").forEach((node) => {
        resizeObserver?.observe(node);
      });
      window.addEventListener("resize", schedule);
      listeningForResize = true;

      schedule();
      timers.push(window.setTimeout(schedule, 160), window.setTimeout(schedule, 420));
    };

    if (!("IntersectionObserver" in window)) {
      startMeasuring();
      return stopMeasuring;
    }

    const visibilityObserver = new IntersectionObserver(
      ([entry]) => {
        if (entry?.isIntersecting) {
          startMeasuring();
        } else {
          stopMeasuring();
        }
      },
      { rootMargin: BOARD_LAYOUT_VISIBILITY_ROOT_MARGIN },
    );
    visibilityObserver.observe(board);

    return () => {
      visibilityObserver.disconnect();
      stopMeasuring();
    };
  }, [baseHeights, boardRef, layoutMode, measurementKey, rows]);

  const activeLayout = layoutMode === "aligned" && measuredLayout.key === measurementKey ? measuredLayout : null;

  return {
    rowTemplate: (activeLayout?.rowHeights ?? baseHeights).map((height) => `${height}px`).join(" "),
    slotTemplates: activeLayout?.slotTemplates ?? {},
  };
}

function measureBoardHeight(board: HTMLDivElement) {
  return Math.max(0, Math.ceil(board.getBoundingClientRect().height));
}

function applyBoardShellMotionStyle(shell: HTMLDivElement, previousStyleText: string | null, height: number) {
  const base = previousStyleText ? `${previousStyleText}; ` : "";
  shell.style.cssText = `${base}height: ${height}px; overflow: clip; transition: height ${BOARD_LAYOUT_MOTION_MS}ms cubic-bezier(0.16, 1, 0.3, 1); will-change: height;`;
}

function restoreElementStyle(element: HTMLElement, previousStyleText: string | null) {
  if (previousStyleText) {
    element.setAttribute("style", previousStyleText);
  } else {
    element.removeAttribute("style");
  }
}

function alignedSlotContentHeight(slotNode: HTMLElement) {
  return Array.from(slotNode.children)
    .filter((child): child is HTMLElement => child instanceof HTMLElement)
    .reduce((height, child) => Math.max(height, child.offsetHeight), 0);
}

function featureRowContentHeight(rowNode: HTMLElement) {
  const computed = window.getComputedStyle(rowNode);
  const paddingY = cssPixelValue(computed.paddingTop) + cssPixelValue(computed.paddingBottom);
  const rowGap = cssPixelValue(computed.rowGap);
  const children = Array.from(rowNode.children).filter((child): child is HTMLElement => child instanceof HTMLElement);
  const childrenHeight = children.reduce((total, child) => total + child.offsetHeight, 0);
  const gapHeight = Math.max(0, children.length - 1) * rowGap;

  return Math.ceil(paddingY + childrenHeight + gapHeight + 1);
}

function cssPixelValue(value: string) {
  const parsed = Number.parseFloat(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function sameNumbers(left: number[], right: number[]) {
  return left.length === right.length && left.every((value, index) => Math.abs(value - right[index]) < 1);
}

function sameStringRecords(left: Record<string, string>, right: Record<string, string>) {
  const leftKeys = Object.keys(left);
  const rightKeys = Object.keys(right);
  return leftKeys.length === rightKeys.length && leftKeys.every((key) => left[key] === right[key]);
}
