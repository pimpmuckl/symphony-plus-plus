import type { RefObject } from "react";
import { useId, useLayoutEffect, useReducer, useRef } from "react";

import { wireToneStyle } from "@/components/dashboard/state-card-style";
import type { StateCardTone } from "@/components/dashboard/state-card-style";
import { sortedCopy } from "@/lib/collections";

const BOARD_WIRE_TRACK_CLEARANCE = 40;
const BOARD_WIRE_VISIBILITY_ROOT_MARGIN = "1000px 0px";
const BOARD_WIRE_EXHAUSTIVE_ASSIGNMENT_LIMIT = 7;
const BOARD_WIRE_LOCAL_SEARCH_ASSIGNMENT_LIMIT = 18;
const BOARD_WIRE_LOCAL_SEARCH_MAX_PASSES = 2;

export type BoardWire = {
  id: string;
  from: string;
  to: string;
  sourceTone: StateCardTone;
  tone: StateCardTone;
  kind?: "progress" | "blocker";
};

type BoardWirePath = BoardWire & {
  path: string;
  sourceX: number;
  sourceY: number;
  targetX: number;
  targetY: number;
  trackX: number;
  trackIndex: number;
  trackCount: number;
  trackSide: WireTrackSide;
  hiddenRects: BoardWireHiddenRect[];
};

type BoardWireHiddenRect = {
  x: number;
  y: number;
  width: number;
  height: number;
};

type BoardWireHorizontalSegment = {
  x1: number;
  x2: number;
  y: number;
};

type BoardWireVerticalSegment = {
  x: number;
  y1: number;
  y2: number;
};

type WireTrackSide = "source" | "target" | "spread";

type MeasuredBoardWire = BoardWire & {
  source: HTMLElement;
  target: HTMLElement;
  sourceLane: number;
  targetLane: number;
  sourceRect: BoardWireHiddenRect;
  targetRect: BoardWireHiddenRect;
  sourceX: number;
  sourceY: number;
  targetX: number;
  targetY: number;
  trackX: number;
  trackIndex: number;
  trackCount: number;
  trackSide: WireTrackSide;
};

type BoardWireLayerProps = {
  paths: BoardWirePath[];
  width: number;
  height: number;
};

type BoardWireMeasurement = {
  paths: BoardWirePath[];
  size: {
    width: number;
    height: number;
  };
};

const EMPTY_BOARD_WIRE_MEASUREMENT: BoardWireMeasurement = {
  paths: [],
  size: { width: 0, height: 0 },
};
const EMPTY_BOARD_WIRE_SIGNATURE = "0x0:";

type BoardWireMeasurementAction =
  | { type: "clear" }
  | { type: "replace"; measurement: BoardWireMeasurement };

export function BoardWireLayer({ paths, width, height }: BoardWireLayerProps) {
  const layerId = useId().replace(/:/g, "");
  if (paths.length === 0 || width <= 0 || height <= 0) return null;
  const maskedPaths = paths.reduce<Array<{ wire: BoardWirePath; maskId: string }>>((result, wire, index) => {
    if (wire.hiddenRects.length > 0) {
      result.push({ wire, maskId: `${layerId}-board-wire-mask-${index}` });
    }
    return result;
  }, []);

  return (
    <>
      <svg className="board-wire-layer" width={width} height={height} viewBox={`0 0 ${width} ${height}`} aria-hidden="true">
        <defs>
          {maskedPaths.map(({ wire, maskId }) => (
            <mask key={maskId} id={maskId} maskUnits="userSpaceOnUse">
              <rect x="0" y="0" width={width} height={height} fill="white" />
              {wire.hiddenRects.map((rect, rectIndex) => (
                <rect key={rectIndex} x={rect.x} y={rect.y} width={rect.width} height={rect.height} fill="black" />
              ))}
            </mask>
          ))}
        </defs>
        {paths.map((wire, index) => {
          const maskId = wire.hiddenRects.length > 0 ? `${layerId}-board-wire-mask-${index}` : undefined;

          return (
            <g
              className="board-wire-group"
              key={wire.id}
              data-wire-kind={wire.kind || "progress"}
              data-wire-tone={wire.tone}
              data-wire-from={wire.from}
              data-wire-to={wire.to}
              data-wire-track-x={wire.trackX.toFixed(2)}
              data-wire-track-index={wire.trackIndex}
              data-wire-track-count={wire.trackCount}
              data-wire-track-side={wire.trackSide}
              data-mask-rects={wire.hiddenRects.length}
              style={wireToneStyle(wire.tone)}
            >
              <path className="board-wire-path" d={wire.path} mask={maskId ? `url(#${maskId})` : undefined} />
            </g>
          );
        })}
      </svg>
      <svg className="board-wire-node-layer" width={width} height={height} viewBox={`0 0 ${width} ${height}`} aria-hidden="true">
        {paths.map((wire) => (
          <g
            className="board-wire-node-group"
            key={wire.id}
            data-wire-kind={wire.kind || "progress"}
            data-wire-tone={wire.tone}
            data-wire-from={wire.from}
            data-wire-to={wire.to}
            data-wire-track-x={wire.trackX.toFixed(2)}
            data-wire-track-index={wire.trackIndex}
            data-wire-track-count={wire.trackCount}
            style={wireToneStyle(wire.tone)}
          >
            {wire.kind === "blocker" ? (
              <path className="board-wire-node board-wire-node-target board-wire-node-blocker-target" d={diamondPath(wire.targetX, wire.targetY, 5.25)} />
            ) : (
              <circle className="board-wire-node board-wire-node-target" cx={wire.targetX} cy={wire.targetY} r={4} />
            )}
          </g>
        ))}
      </svg>
    </>
  );
}

function diamondPath(x: number, y: number, radius: number) {
  return `M ${x} ${y - radius} L ${x + radius} ${y} L ${x} ${y + radius} L ${x - radius} ${y} Z`;
}

export function useBoardWirePaths(boardRef: RefObject<HTMLDivElement | null>, wires: BoardWire[], measureKey: string) {
  const [measurement, dispatchMeasurement] = useReducer(boardWireMeasurementReducer, EMPTY_BOARD_WIRE_MEASUREMENT);
  const measurementSignatureRef = useRef(EMPTY_BOARD_WIRE_SIGNATURE);

  useLayoutEffect(() => {
    const board = boardRef.current;
    if (!board || wires.length === 0) {
      measurementSignatureRef.current = EMPTY_BOARD_WIRE_SIGNATURE;
      dispatchMeasurement({ type: "clear" });
      return;
    }

    let active = false;
    let frame: number | null = null;
    const timers: number[] = [];
    let resizeObserver: ResizeObserver | null = null;
    let listeningForResize = false;

    const schedule = () => {
      if (!active) return;
      if (frame !== null) return;
      frame = window.requestAnimationFrame(() => {
        frame = null;
        if (!active) return;
        const measured = measureBoardWires(board, wires);
        const signature = boardWireMeasurementSignature(measured);
        if (measurementSignatureRef.current === signature) return;

        measurementSignatureRef.current = signature;
        dispatchMeasurement({ type: "replace", measurement: measured });
      });
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
      measurementSignatureRef.current = EMPTY_BOARD_WIRE_SIGNATURE;
      dispatchMeasurement({ type: "clear" });
    };

    const startMeasuring = () => {
      if (active) return;
      active = true;

      resizeObserver = new ResizeObserver(schedule);
      resizeObserver.observe(board);
      board.querySelectorAll<HTMLElement>("[data-wire-id]").forEach((node) => resizeObserver?.observe(node));
      window.addEventListener("resize", schedule);
      listeningForResize = true;

      schedule();
      timers.push(window.setTimeout(schedule, 180), window.setTimeout(schedule, 420));
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
      { rootMargin: BOARD_WIRE_VISIBILITY_ROOT_MARGIN },
    );
    visibilityObserver.observe(board);

    return () => {
      visibilityObserver.disconnect();
      stopMeasuring();
    };
  }, [boardRef, measureKey, wires]);

  return measurement;
}

function boardWireMeasurementReducer(current: BoardWireMeasurement, action: BoardWireMeasurementAction) {
  if (action.type === "clear") return boardWireMeasurementIsEmpty(current) ? current : EMPTY_BOARD_WIRE_MEASUREMENT;
  return action.measurement;
}

function boardWireMeasurementIsEmpty(measurement: BoardWireMeasurement) {
  return measurement.paths.length === 0 && measurement.size.width === 0 && measurement.size.height === 0;
}

function boardWireMeasurementSignature(measurement: BoardWireMeasurement) {
  return `${measurement.size.width}x${measurement.size.height}:` + measurement.paths.map(boardWirePathSignature).join("|");
}

function boardWirePathSignature(wire: BoardWirePath) {
  const hiddenRects = wire.hiddenRects
    .map((rect) => `${wireSignatureNumber(rect.x)},${wireSignatureNumber(rect.y)},${wireSignatureNumber(rect.width)},${wireSignatureNumber(rect.height)}`)
    .join(";");
  return [
    wire.id,
    wire.kind || "progress",
    wire.tone,
    wireSignatureNumber(wire.sourceX),
    wireSignatureNumber(wire.sourceY),
    wireSignatureNumber(wire.targetX),
    wireSignatureNumber(wire.targetY),
    wireSignatureNumber(wire.trackX),
    wire.trackIndex,
    wire.trackCount,
    wire.trackSide,
    hiddenRects,
  ].join(":");
}

function wireSignatureNumber(value: number) {
  return value.toFixed(1);
}

function measureBoardWires(board: HTMLDivElement, wires: BoardWire[]) {
  const boardRect = layoutRectWithinBoard(board, board);
  const width = Math.ceil(board.scrollWidth || boardRect.width);
  const height = Math.ceil(board.scrollHeight || boardRect.height);
  const nodes = new Map<string, HTMLElement>();
  const lanes = Array.from(board.querySelectorAll<HTMLElement>(".jira-lane")).map((lane) => ({
    node: lane,
    rect: layoutRectWithinBoard(lane, board),
  }));

  board.querySelectorAll<HTMLElement>("[data-wire-id]").forEach((node) => {
    const id = node.dataset.wireId;
    if (id) nodes.set(id, node);
  });
  const laneIndexByNode = new Map<HTMLElement, number>();
  nodes.forEach((node) => {
    laneIndexByNode.set(node, lanes.findIndex((lane) => lane.node.contains(node)));
  });

  const measuredWires = wires.flatMap<MeasuredBoardWire>((wire) => {
    const source = nodes.get(wire.from);
    const target = nodes.get(wire.to);
    if (!source || !target) return [];

    const sourceLane = laneIndexByNode.get(source) ?? -1;
    const targetLane = laneIndexByNode.get(target) ?? -1;
    if (sourceLane < 0 || targetLane < 0) return [];

    const sourceRect = layoutRectWithinBoard(source, board);
    const targetRect = layoutRectWithinBoard(target, board);
    const sameLaneSide = sourceLane === targetLane ? sameLaneBoardWireSide(sourceLane, lanes) : undefined;
    const forward = targetLane >= sourceLane;
    const sourceX = sameLaneSide === "left" ? sourceRect.x : sameLaneSide === "right" ? sourceRect.x + sourceRect.width : forward ? sourceRect.x + sourceRect.width : sourceRect.x;
    const targetX = sameLaneSide === "left" ? targetRect.x : sameLaneSide === "right" ? targetRect.x + targetRect.width : forward ? targetRect.x : targetRect.x + targetRect.width;
    const sourceY = sourceRect.y + sourceRect.height / 2;
    const targetY = targetRect.y + targetRect.height / 2;

    return [
      {
        ...wire,
        source,
        target,
        sourceLane,
        targetLane,
        sourceRect,
        targetRect,
        sourceX,
        sourceY,
        targetX,
        targetY,
        trackX: sourceLane === targetLane ? sameLaneBoardWireTrackX(sourceLane, lanes, 0, 1) : defaultBoardWireTrackX(sourceX, targetX),
        trackIndex: 0,
        trackCount: 1,
        trackSide: sourceLane === targetLane ? "spread" : "source",
      },
    ];
  });
  const routedWires = assignBoardWireTracks(applyBoardWireAnchorSlots(measuredWires), lanes);

  return {
    size: { width, height },
    paths: routedWires.map<BoardWirePath>((wire) => ({
      id: wire.id,
      from: wire.from,
      to: wire.to,
      sourceTone: wire.sourceTone,
      tone: wire.tone,
      kind: wire.kind,
      path: boardWirePath(wire.sourceX, wire.sourceY, wire.targetX, wire.targetY, wire.trackX, boardWireBendRadius(wire, lanes)),
      sourceX: wire.sourceX,
      sourceY: wire.sourceY,
      targetX: wire.targetX,
      targetY: wire.targetY,
      trackX: wire.trackX,
      trackIndex: wire.trackIndex,
      trackCount: wire.trackCount,
      trackSide: wire.trackSide,
      hiddenRects: skippedLaneRects(wire.sourceLane, wire.targetLane, lanes),
    })),
  };
}

function applyBoardWireAnchorSlots(wires: MeasuredBoardWire[]) {
  const next = wires.map((wire) => ({ ...wire }));

  groupedWires(next, (wire) => wire.from).forEach((group) => {
    if (group.length <= 1) return;
    sortedCopy(group, (left, right) => left.targetY - right.targetY)
      .forEach((wire, index) => {
        wire.sourceY = edgeSlotY(wire.sourceRect, index, group.length);
      });
  });

  groupedWires(next, (wire) => wire.to).forEach((group) => {
    if (group.length <= 1) return;
    sortedCopy(group, (left, right) => left.sourceY - right.sourceY)
      .forEach((wire, index) => {
        wire.targetY = edgeSlotY(wire.targetRect, index, group.length);
      });
  });

  return next;
}

function assignBoardWireTracks(wires: MeasuredBoardWire[], lanes: Array<{ node: HTMLElement; rect: BoardWireHiddenRect }>) {
  const groups = new Map<string, MeasuredBoardWire[]>();
  const fanoutSources = new Map<string, number>();
  const fanoutGaps = new Set<number>();

  wires.forEach((wire) => {
    const gapIndex = primaryBoardWireGapIndex(wire);
    if (wire.sourceLane === wire.targetLane) return;
    if (gapIndex < 0 || gapIndex >= lanes.length - 1) return;
    const key = `${gapIndex}:${wire.from}`;
    fanoutSources.set(key, (fanoutSources.get(key) || 0) + 1);
  });
  fanoutSources.forEach((count, key) => {
    if (count > 1) fanoutGaps.add(Number(key.split(":")[0]));
  });

  wires.forEach((wire) => {
    const gapIndex = primaryBoardWireGapIndex(wire);
    if (wire.sourceLane !== wire.targetLane && (gapIndex < 0 || gapIndex >= lanes.length - 1)) return;

    wire.trackSide = fanoutGaps.has(gapIndex) ? "spread" : boardWireTrackSide(wire);
    const key = boardWireTrackGroupKey(wire, lanes);
    const group = groups.get(key) || [];
    group.push(wire);
    groups.set(key, group);
  });

  groups.forEach((group) => {
    const tracks: number[] = [];
    const sorted = sortedCopy(group, (left, right) => {
      const leftSpan = boardWireVerticalSpan(left);
      const rightSpan = boardWireVerticalSpan(right);
      if (leftSpan.start !== rightSpan.start) return leftSpan.start - rightSpan.start;
      return leftSpan.end - rightSpan.end;
    });

    sorted.forEach((wire) => {
      const span = boardWireVerticalSpan(wire);
      const reusableTrack = tracks.findIndex((endY) => endY + BOARD_WIRE_TRACK_CLEARANCE < span.start);
      const trackIndex = reusableTrack >= 0 ? reusableTrack : tracks.length;
      tracks[trackIndex] = span.end;
      wire.trackIndex = trackIndex;
    });

    group.forEach((wire) => {
      wire.trackCount = Math.max(1, tracks.length);
    });
    if (group[0]?.trackSide === "spread") {
      reorderSpreadTracks(group, lanes);
    } else {
      reorderSameSourceFanoutTracks(group, lanes);
    }
    group.forEach((wire) => {
      wire.trackX = boardWireTrackX(wire, lanes);
    });
  });

  return wires;
}

function reorderSpreadTracks(wires: MeasuredBoardWire[], lanes: Array<{ node: HTMLElement; rect: BoardWireHiddenRect }>) {
  if (wires.length <= 1) return;

  const trackCount = wires.length;
  const sorted = sortedCopy(wires, (left, right) => {
    if (left.targetY !== right.targetY) return left.targetY - right.targetY;
    return left.sourceY - right.sourceY;
  });
  const assignment = bestSpreadTrackAssignment(sorted, lanes, trackCount);

  sorted.forEach((wire, index) => {
    wire.trackCount = Math.max(wire.trackCount, trackCount);
    wire.trackIndex = assignment[index] ?? wire.trackIndex;
  });
}

function bestSpreadTrackAssignment(
  wires: MeasuredBoardWire[],
  lanes: Array<{ node: HTMLElement; rect: BoardWireHiddenRect }>,
  trackCount: number,
) {
  const indices = Array.from({ length: trackCount }, (_, index) => index);
  const initial = [...indices].reverse();

  if (wires.length > BOARD_WIRE_LOCAL_SEARCH_ASSIGNMENT_LIMIT) {
    return initial;
  }

  if (wires.length > BOARD_WIRE_EXHAUSTIVE_ASSIGNMENT_LIMIT) {
    return optimizeSpreadTrackAssignment(wires, lanes, initial, trackCount);
  }

  let best = initial;
  let bestCost = boardWireAssignmentCost(wires, lanes, initial, trackCount);
  const used = new Set<number>();
  const current: number[] = [];

  const visit = () => {
    if (current.length === wires.length) {
      const candidate = [...current];
      const cost = boardWireAssignmentCost(wires, lanes, candidate, trackCount);
      if (cost < bestCost) {
        best = candidate;
        bestCost = cost;
      }
      return;
    }

    indices.forEach((index) => {
      if (used.has(index)) return;
      used.add(index);
      current.push(index);
      visit();
      current.pop();
      used.delete(index);
    });
  };

  visit();
  return best;
}

function optimizeSpreadTrackAssignment(
  wires: MeasuredBoardWire[],
  lanes: Array<{ node: HTMLElement; rect: BoardWireHiddenRect }>,
  initial: number[],
  trackCount: number,
) {
  const assignment = [...initial];
  let bestCost = boardWireAssignmentCost(wires, lanes, assignment, trackCount);
  let improved = true;
  let pass = 0;

  while (improved && pass < BOARD_WIRE_LOCAL_SEARCH_MAX_PASSES) {
    improved = false;
    pass += 1;
    for (let left = 0; left < assignment.length; left += 1) {
      for (let right = left + 1; right < assignment.length; right += 1) {
        [assignment[left], assignment[right]] = [assignment[right], assignment[left]];
        const cost = boardWireAssignmentCost(wires, lanes, assignment, trackCount);
        if (cost < bestCost) {
          bestCost = cost;
          improved = true;
        } else {
          [assignment[left], assignment[right]] = [assignment[right], assignment[left]];
        }
      }
    }
  }

  return assignment;
}

function boardWireAssignmentCost(
  wires: MeasuredBoardWire[],
  lanes: Array<{ node: HTMLElement; rect: BoardWireHiddenRect }>,
  assignment: number[],
  trackCount: number,
) {
  const routes = wires.map((wire, index) => boardWireRouteSegments(wire, boardWireTrackX(wire, lanes, assignment[index], trackCount)));
  let cost = 0;

  routes.forEach((route) => {
    cost += (route.source.x2 - route.source.x1 + route.target.x2 - route.target.x1) * 0.01;
  });

  for (let left = 0; left < routes.length; left += 1) {
    for (let right = left + 1; right < routes.length; right += 1) {
      cost += boardWireRoutePairCost(routes[left], routes[right]);
    }
  }

  return cost;
}

function boardWireRouteSegments(wire: MeasuredBoardWire, trackX: number) {
  return {
    source: horizontalSegment(wire.sourceX, trackX, wire.sourceY),
    trunk: verticalSegment(trackX, wire.sourceY, wire.targetY),
    target: horizontalSegment(trackX, wire.targetX, wire.targetY),
  };
}

function boardWireRoutePairCost(
  left: { source: BoardWireHorizontalSegment; trunk: BoardWireVerticalSegment; target: BoardWireHorizontalSegment },
  right: { source: BoardWireHorizontalSegment; trunk: BoardWireVerticalSegment; target: BoardWireHorizontalSegment },
) {
  let cost = 0;
  [left.source, left.target].forEach((horizontal) => {
    cost += horizontalVerticalCrossingCost(horizontal, right.trunk);
  });
  [right.source, right.target].forEach((horizontal) => {
    cost += horizontalVerticalCrossingCost(horizontal, left.trunk);
  });
  cost += horizontalOverlapCost(left.source, right.source);
  cost += horizontalOverlapCost(left.target, right.target);
  return cost;
}

function horizontalSegment(leftX: number, rightX: number, y: number): BoardWireHorizontalSegment {
  return { x1: Math.min(leftX, rightX), x2: Math.max(leftX, rightX), y };
}

function verticalSegment(x: number, topY: number, bottomY: number): BoardWireVerticalSegment {
  return { x, y1: Math.min(topY, bottomY), y2: Math.max(topY, bottomY) };
}

function horizontalVerticalCrossingCost(horizontal: BoardWireHorizontalSegment, vertical: BoardWireVerticalSegment) {
  const crossing =
    vertical.x > horizontal.x1 + 2 &&
    vertical.x < horizontal.x2 - 2 &&
    horizontal.y > vertical.y1 + 2 &&
    horizontal.y < vertical.y2 - 2;

  return crossing ? 1000 : 0;
}

function horizontalOverlapCost(left: BoardWireHorizontalSegment, right: BoardWireHorizontalSegment) {
  if (Math.abs(left.y - right.y) > 3) return 0;
  const overlap = Math.min(left.x2, right.x2) - Math.max(left.x1, right.x1);
  return overlap > 0 ? overlap * 0.25 : 0;
}

function reorderSameSourceFanoutTracks(wires: MeasuredBoardWire[], lanes: Array<{ node: HTMLElement; rect: BoardWireHiddenRect }>) {
  groupedWires(wires, (wire) => wire.from).forEach((group) => {
    if (group.length <= 1) return;

    const indices = sortedCopy([...new Set(group.map((wire) => wire.trackIndex))], (left, right) => left - right);
    if (indices.length <= 1) return;
    const sample = group[0];

    const indicesFromOutsideIn = indices.sort((left, right) => {
      const leftDistance = Math.abs(boardWireTrackX(sample, lanes, left) - sample.sourceX);
      const rightDistance = Math.abs(boardWireTrackX(sample, lanes, right) - sample.sourceX);
      return rightDistance - leftDistance;
    });

    sortedCopy(group, (left, right) => {
      const leftDistance = Math.abs(left.targetY - left.sourceY);
      const rightDistance = Math.abs(right.targetY - right.sourceY);
      if (leftDistance !== rightDistance) return leftDistance - rightDistance;
      return left.targetY - right.targetY;
    })
      .forEach((wire, index) => {
        wire.trackIndex = indicesFromOutsideIn[Math.min(index, indicesFromOutsideIn.length - 1)] ?? wire.trackIndex;
      });
  });
}

function groupedWires(wires: MeasuredBoardWire[], keyFor: (wire: MeasuredBoardWire) => string) {
  const groups = new Map<string, MeasuredBoardWire[]>();
  wires.forEach((wire) => {
    const key = keyFor(wire);
    const group = groups.get(key) || [];
    group.push(wire);
    groups.set(key, group);
  });
  return groups;
}

function edgeSlotY(rect: BoardWireHiddenRect, index: number, count: number) {
  const centerY = rect.y + rect.height / 2;
  const guard = Math.min(22, Math.max(4, rect.height / 4));
  const offset = clampNumber((index - (count - 1) / 2) * 10, -24, 24);
  return clampNumber(centerY + offset, rect.y + guard, rect.y + rect.height - guard);
}

function primaryBoardWireGapIndex(wire: MeasuredBoardWire) {
  if (wire.sourceLane === wire.targetLane) return -1;
  return Math.min(wire.sourceLane, wire.targetLane);
}

function boardWireTrackSide(wire: MeasuredBoardWire): WireTrackSide {
  if (wire.sourceLane === wire.targetLane) return "spread";
  return wire.targetY >= wire.sourceY ? "source" : "target";
}

function boardWireTrackGroupKey(wire: MeasuredBoardWire, lanes: Array<{ node: HTMLElement; rect: BoardWireHiddenRect }>) {
  if (wire.sourceLane === wire.targetLane) {
    const side = sameLaneBoardWireSide(wire.sourceLane, lanes);
    return `same-gap:${sameLaneBoardWireGapIndex(wire.sourceLane, side)}`;
  }

  return `${primaryBoardWireGapIndex(wire)}:${wire.trackSide}`;
}

function boardWireVerticalSpan(wire: MeasuredBoardWire) {
  return {
    start: Math.min(wire.sourceY, wire.targetY),
    end: Math.max(wire.sourceY, wire.targetY),
  };
}

function boardWireTrackX(
  wire: MeasuredBoardWire,
  lanes: Array<{ node: HTMLElement; rect: BoardWireHiddenRect }>,
  trackIndex = wire.trackIndex,
  trackCount = wire.trackCount,
) {
  if (wire.sourceLane === wire.targetLane) {
    return sameLaneBoardWireTrackX(wire.sourceLane, lanes, trackIndex, trackCount);
  }

  const gapIndex = primaryBoardWireGapIndex(wire);
  const leftLane = lanes[gapIndex];
  const rightLane = lanes[gapIndex + 1];
  if (!leftLane || !rightLane) return defaultBoardWireTrackX(wire.sourceX, wire.targetX);

  const gapStart = leftLane.rect.x + leftLane.rect.width;
  const gapEnd = rightLane.rect.x;
  const minX = Math.min(gapStart, gapEnd) + 4;
  const maxX = Math.max(gapStart, gapEnd) - 4;
  if (maxX <= minX) return defaultBoardWireTrackX(wire.sourceX, wire.targetX);

  const safeTrackCount = Math.max(1, trackCount);
  const trackRatio = safeTrackCount === 1 ? 0.5 : trackIndex / (safeTrackCount - 1);

  if (wire.trackSide === "spread") {
    return clampNumber(minX + (maxX - minX) * trackRatio, minX, maxX);
  }

  const forward = wire.targetLane >= wire.sourceLane;
  const preferStart = wire.trackSide === "source" ? forward : !forward;
  const centerX = (minX + maxX) / 2;
  const bandGap = Math.min(6, (maxX - minX) / 6);
  const bandStart = preferStart ? minX : centerX + bandGap;
  const bandEnd = preferStart ? centerX - bandGap : maxX;
  if (bandEnd <= bandStart) return preferStart ? minX : maxX;

  const rawX = preferStart
    ? bandStart + (bandEnd - bandStart) * trackRatio
    : bandEnd - (bandEnd - bandStart) * trackRatio;

  return clampNumber(rawX, bandStart, bandEnd);
}

function sameLaneBoardWireSide(laneIndex: number, lanes: Array<{ node: HTMLElement; rect: BoardWireHiddenRect }>) {
  return laneIndex < lanes.length - 1 ? "right" : "left";
}

function sameLaneBoardWireGapIndex(laneIndex: number, side: "left" | "right") {
  return side === "right" ? laneIndex : laneIndex - 1;
}

function sameLaneBoardWireTrackX(
  laneIndex: number,
  lanes: Array<{ node: HTMLElement; rect: BoardWireHiddenRect }>,
  trackIndex = 0,
  trackCount = 1,
) {
  const lane = lanes[laneIndex];
  if (!lane) return 0;

  const side = sameLaneBoardWireSide(laneIndex, lanes);
  const neighbor = side === "right" ? lanes[laneIndex + 1] : lanes[laneIndex - 1];
  if (!neighbor) return side === "right" ? lane.rect.x + lane.rect.width + 12 : lane.rect.x - 12;

  const gapStart = side === "right" ? lane.rect.x + lane.rect.width : neighbor.rect.x + neighbor.rect.width;
  const gapEnd = side === "right" ? neighbor.rect.x : lane.rect.x;
  const minX = Math.min(gapStart, gapEnd) + 4;
  const maxX = Math.max(gapStart, gapEnd) - 4;
  if (maxX <= minX) return side === "right" ? gapStart + 8 : gapEnd - 8;

  const safeTrackCount = Math.max(1, trackCount);
  const trackRatio = safeTrackCount === 1 ? 0.5 : trackIndex / (safeTrackCount - 1);
  const rawX = minX + (maxX - minX) * trackRatio;
  return clampNumber(rawX, minX, maxX);
}

function boardWireBendRadius(wire: MeasuredBoardWire, lanes: Array<{ node: HTMLElement; rect: BoardWireHiddenRect }>) {
  if (wire.trackCount <= 1) return 14;
  const adjacentTrackGap = Math.abs(boardWireTrackX(wire, lanes, 1, wire.trackCount) - boardWireTrackX(wire, lanes, 0, wire.trackCount));
  return clampNumber(adjacentTrackGap / 2, 3, 8);
}

function layoutRectWithinBoard(node: HTMLElement, board: HTMLElement): BoardWireHiddenRect {
  if (node === board) {
    return {
      x: 0,
      y: 0,
      width: board.offsetWidth,
      height: board.offsetHeight,
    };
  }

  let x = node.offsetLeft;
  let y = node.offsetTop;
  let parent = node.offsetParent;

  while (parent instanceof HTMLElement && parent !== board) {
    x += parent.offsetLeft;
    y += parent.offsetTop;
    parent = parent.offsetParent;
  }

  if (parent !== board) {
    const nodeRect = node.getBoundingClientRect();
    const boardRect = board.getBoundingClientRect();

    return {
      x: Math.max(0, nodeRect.left - boardRect.left),
      y: Math.max(0, nodeRect.top - boardRect.top),
      width: Math.max(0, nodeRect.width),
      height: Math.max(0, nodeRect.height),
    };
  }

  return {
    x: Math.max(0, x),
    y: Math.max(0, y),
    width: Math.max(0, node.offsetWidth),
    height: Math.max(0, node.offsetHeight),
  };
}

function skippedLaneRects(
  sourceLane: number,
  targetLane: number,
  lanes: Array<{ node: HTMLElement; rect: BoardWireHiddenRect }>,
): BoardWireHiddenRect[] {
  if (sourceLane < 0 || targetLane < 0 || Math.abs(targetLane - sourceLane) <= 1) return [];

  const start = Math.min(sourceLane, targetLane) + 1;
  const end = Math.max(sourceLane, targetLane);

  return lanes.slice(start, end).map(({ rect }) => ({
    x: Math.max(0, rect.x),
    y: Math.max(0, rect.y),
    width: Math.max(0, rect.width),
    height: Math.max(0, rect.height),
  }));
}

function boardWirePath(sourceX: number, sourceY: number, targetX: number, targetY: number, trackX = defaultBoardWireTrackX(sourceX, targetX), maxRadius = 14) {
  const deltaX = targetX - sourceX;
  if (Math.abs(targetY - sourceY) < 2) {
    return `M ${sourceX} ${sourceY} H ${targetX}`;
  }

  const xTurn = Math.abs(deltaX) <= 2 ? (trackX >= sourceX ? 1 : -1) : deltaX >= 0 ? 1 : -1;
  const yTurn = targetY >= sourceY ? 1 : -1;
  const minBendX = Math.min(sourceX, targetX) + 10;
  const maxBendX = Math.max(sourceX, targetX) - 10;
  const bendX = minBendX <= maxBendX ? clampNumber(trackX, minBendX, maxBendX) : trackX;
  const radius = Math.min(maxRadius, Math.abs(targetY - sourceY) / 2, Math.abs(bendX - sourceX) / 2, Math.abs(targetX - bendX) / 2);

  if (radius < 1) {
    return [`M ${sourceX} ${sourceY}`, `H ${bendX}`, `V ${targetY}`, `H ${targetX}`].join(" ");
  }

  return [
    `M ${sourceX} ${sourceY}`,
    `H ${bendX - xTurn * radius}`,
    `Q ${bendX} ${sourceY} ${bendX} ${sourceY + yTurn * radius}`,
    `V ${targetY - yTurn * radius}`,
    `Q ${bendX} ${targetY} ${bendX + xTurn * radius} ${targetY}`,
    `H ${targetX}`,
  ].join(" ");
}

function defaultBoardWireTrackX(sourceX: number, targetX: number) {
  const deltaX = targetX - sourceX;
  const direction = deltaX >= 0 ? 1 : -1;
  return sourceX + direction * Math.max(28, Math.min(96, Math.abs(deltaX) * 0.46));
}

function clampNumber(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value));
}
