import { AlertTriangle, CheckCircle2, ChevronDown, MessageSquareText, RefreshCw } from "lucide-react";
import { AnimatedTopGrid, NumberWheel, TOP_PANEL_RESIZE_MS, TOP_PANEL_SLIDE_MS, useCountMotion } from "@/components/dashboard/motion";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { GuidanceItem } from "@/types/dashboard";
import type * as React from "react";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { clearMotionTimers, later, measureElementHeight, nextFrame } from "@/components/dashboard/motion-utils";
import { cn } from "@/lib/utils";
import { useCallback, useEffect, useLayoutEffect, useReducer, useRef, useState } from "react";
import { BlockerItem, FinishedHighlight } from "./dashboard-state";
import { BlockerPreviewCard, FinishedHighlightsBoard, GuidancePreviewCard } from "./status-cards";
import { CardDetailSelect, CardDetailSelection, DashboardUpdateAnimations, STATUS_TILE_TONES, StatusTileTone, TopPanelDirection, TopPanelKey, TopPanelPhase } from "./runtime";
import { EmptyPanel } from "./detail-extras";
import { blockerUpdateKey, guidanceUpdateKey } from "./update-animations";
import { readStoredTopPanel, topPanelDirection, writeDashboardUiStateValue } from "./dashboard-persistence";

const UPDATE_SIMULATION_CONTROLS = [
  { kind: "guidance", label: "G", icon: <MessageSquareText className="size-3.5" />, tooltip: "Simulate new human guidance" },
  { kind: "blocker", label: "B", icon: <AlertTriangle className="size-3.5" />, tooltip: "Simulate a fresh blocker" },
  { kind: "finished", label: "F", icon: <CheckCircle2 className="size-3.5" />, tooltip: "Simulate finished work" },
  { kind: "changed", label: "U", icon: <RefreshCw className="size-3.5" />, tooltip: "Simulate a card update" },
] as const;

export function StatusRail({
  guidanceItems,
  blockerItems,
  finishedHighlights,
  onSelectGuidance,
  onSelectCard,
  updateAnimations,
}: {
  guidanceItems: GuidanceItem[];
  blockerItems: BlockerItem[];
  finishedHighlights: FinishedHighlight[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const [openPanel, setOpenPanel] = useState<TopPanelKey | null>(readStoredTopPanel);
  const selectCardFromPanel = useCallback((selection: CardDetailSelection) => onSelectCard(selection), [onSelectCard]);
  const tileConfigs: StatusTileConfig[] = [
    {
      icon: <MessageSquareText className="size-6" />,
      panel: "guidance",
      pulseToken: updateAnimations.countPulseFor("guidance"),
      title: "Human Guidance Needed",
      tone: "violet",
      value: guidanceItems.length,
    },
    {
      icon: <AlertTriangle className="size-6" />,
      panel: "blockers",
      pulseToken: updateAnimations.countPulseFor("blockers"),
      title: "Active Blockers",
      tone: "amber",
      value: blockerItems.length,
    },
    {
      icon: <CheckCircle2 className="size-6" />,
      panel: "finished",
      pulseToken: updateAnimations.countPulseFor("finished"),
      title: "Finished",
      tone: "emerald",
      value: finishedHighlights.length,
    },
  ];
  const panelContentProps = {
    blockerItems,
    finishedHighlights,
    guidanceItems,
    onSelectCard: selectCardFromPanel,
    onSelectGuidance,
    updateAnimations,
  };

  useEffect(() => {
    writeDashboardUiStateValue("topPanel", openPanel);
  }, [openPanel]);

  return (
    <section className="relative grid gap-3">
      <div className="grid gap-3 lg:hidden">
        {tileConfigs.map((tile) => (
          <div key={tile.panel} className="top-panel-inline grid gap-3">
            <StatusTile {...tile} openPanel={openPanel} onToggle={setOpenPanel} />
            <MobileTopPanel active={openPanel === tile.panel} panel={tile.panel} {...panelContentProps} />
          </div>
        ))}
      </div>

      <div className="hidden gap-3 lg:grid lg:grid-cols-3">
        {tileConfigs.map((tile) => (
          <StatusTile key={tile.panel} {...tile} openPanel={openPanel} onToggle={setOpenPanel} />
        ))}
      </div>

      <div className="hidden lg:block">
        <TopPanelCarousel activePanel={openPanel} {...panelContentProps} />
      </div>
    </section>
  );
}

function MobileTopPanel({
  active,
  panel,
  ...contentProps
}: Omit<TopPanelContentProps, "interactive"> & {
  active: boolean;
}) {
  if (!active) return null;

  return (
    <div className="top-panel-viewport" data-phase="idle" data-resize="steady" data-has-content="true">
      <div className="top-panel-static" data-motion="idle">
        <div className="top-panel-motion-frame">
          <div className="top-panel-pane-inner">
            <TopPanelContent {...contentProps} panel={panel} />
          </div>
        </div>
      </div>
    </div>
  );
}

type StatusTileConfig = {
  icon: React.ReactNode;
  panel: TopPanelKey;
  pulseToken: number;
  title: string;
  tone: StatusTileTone;
  value: number;
};

export type TopPanelContentProps = {
  panel: TopPanelKey;
  interactive?: boolean;
  guidanceItems: GuidanceItem[];
  blockerItems: BlockerItem[];
  finishedHighlights: FinishedHighlight[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
};

export function TopPanelContent({
  panel,
  interactive = true,
  guidanceItems,
  blockerItems,
  finishedHighlights,
  onSelectGuidance,
  onSelectCard,
  updateAnimations,
}: TopPanelContentProps) {
  if (panel === "guidance") {
    return (
      <TopTray title="Decisions and input needed to keep work moving">
        {guidanceItems.length === 0 ? (
          <EmptyPanel title="No human guidance needed" compact />
        ) : (
          <AnimatedTopGrid className="grid gap-3 xl:grid-cols-2">
            {guidanceItems.slice(0, 6).map((item, index) => (
              <GuidancePreviewCard
                key={`${item.source}-${item.id}`}
                item={item}
                index={index}
                onSelect={onSelectGuidance}
                motion={updateAnimations.motionFor(guidanceUpdateKey(item))}
              />
            ))}
          </AnimatedTopGrid>
        )}
      </TopTray>
    );
  }

  if (panel === "blockers") {
    return (
      <TopTray title="Blocked packages and dependency waits">
        {blockerItems.length === 0 ? (
          <EmptyPanel title="No active blockers" compact />
        ) : (
          <AnimatedTopGrid className="grid gap-3 lg:grid-cols-2 xl:grid-cols-3">
            {blockerItems.map((item, index) => (
              <BlockerPreviewCard
                key={item.id}
                item={item}
                index={index}
                onSelectCard={interactive ? () => onSelectCard(item.selection) : undefined}
                motion={updateAnimations.motionFor(blockerUpdateKey(item))}
              />
            ))}
          </AnimatedTopGrid>
        )}
      </TopTray>
    );
  }

  return (
    <TopTray title="Recently finished requests, slices, and execution records">
      {finishedHighlights.length === 0 ? (
        <EmptyPanel title="Nothing finished yet" compact />
      ) : (
        <FinishedHighlightsBoard
          items={finishedHighlights}
          onSelectCard={interactive ? onSelectCard : undefined}
          updateAnimations={updateAnimations}
        />
      )}
    </TopTray>
  );
}

export type TopPanelCarouselState = {
  visiblePanel: TopPanelKey | null;
  previousPanel: TopPanelKey | null;
  phase: TopPanelPhase;
  direction: TopPanelDirection;
  height: number | "auto";
  transitionHeights: { from: number; to: number };
};

export type TopPanelCarouselAction =
  | { type: "replace"; state: TopPanelCarouselState }
  | { type: "patch"; state: Partial<TopPanelCarouselState> };

function initialTopPanelCarouselState(activePanel: TopPanelKey | null): TopPanelCarouselState {
  return {
    visiblePanel: activePanel,
    previousPanel: null,
    phase: "idle",
    direction: "forward",
    height: activePanel ? "auto" : 0,
    transitionHeights: { from: 0, to: 0 },
  };
}

function topPanelCarouselReducer(state: TopPanelCarouselState, action: TopPanelCarouselAction): TopPanelCarouselState {
  if (action.type === "replace") return action.state;
  return { ...state, ...action.state };
}

export function TopPanelCarousel({
  activePanel,
  guidanceItems,
  blockerItems,
  finishedHighlights,
  onSelectGuidance,
  onSelectCard,
  updateAnimations,
}: Omit<TopPanelContentProps, "panel" | "interactive"> & {
  activePanel: TopPanelKey | null;
}) {
  const [state, dispatch] = useReducer(topPanelCarouselReducer, activePanel, initialTopPanelCarouselState);
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const visibleRef = useRef<HTMLDivElement | null>(null);
  const measureRef = useRef<HTMLDivElement | null>(null);
  const latestPanelRef = useRef<TopPanelKey | null>(activePanel);
  const timersRef = useRef<number[]>([]);
  const framesRef = useRef<number[]>([]);
  const contentProps = {
    blockerItems,
    finishedHighlights,
    guidanceItems,
    onSelectCard,
    onSelectGuidance,
    updateAnimations,
  };

  useEffect(
    () => () => {
      clearMotionTimers(timersRef, framesRef);
    },
    [],
  );

  useLayoutEffect(() => {
    const oldPanel = latestPanelRef.current;
    if (oldPanel === activePanel) return;

    clearMotionTimers(timersRef, framesRef);

    const oldHeight = measureElementHeight(visibleRef.current) || measureElementHeight(viewportRef.current);
    const newHeight = activePanel ? measureElementHeight(measureRef.current) : 0;
    const nextDirection = topPanelDirection(oldPanel, activePanel);
    const transitionHeights = { from: oldHeight, to: newHeight };

    if (!oldPanel && activePanel) {
      latestPanelRef.current = activePanel;
      dispatch({
        type: "replace",
        state: {
          visiblePanel: activePanel,
          previousPanel: null,
          phase: "opening",
          direction: nextDirection,
          height: 0,
          transitionHeights,
        },
      });
      nextFrame(framesRef, () => dispatch({ type: "patch", state: { height: newHeight } }));
      later(timersRef, TOP_PANEL_SLIDE_MS, () => {
        dispatch({ type: "patch", state: { phase: "idle", height: "auto" } });
      });
      return;
    }

    if (oldPanel && !activePanel) {
      latestPanelRef.current = null;
      dispatch({
        type: "replace",
        state: {
          visiblePanel: oldPanel,
          previousPanel: null,
          phase: "closing",
          direction: nextDirection,
          height: oldHeight,
          transitionHeights,
        },
      });
      nextFrame(framesRef, () => dispatch({ type: "patch", state: { height: 0 } }));
      later(timersRef, TOP_PANEL_SLIDE_MS, () => {
        dispatch({ type: "patch", state: { visiblePanel: null, phase: "idle", height: 0 } });
      });
      return;
    }

    if (!oldPanel || !activePanel) return;

    latestPanelRef.current = activePanel;

    if (newHeight > oldHeight + 2) {
      dispatch({
        type: "replace",
        state: {
          visiblePanel: activePanel,
          previousPanel: oldPanel,
          phase: "pre-resize",
          direction: nextDirection,
          height: oldHeight,
          transitionHeights,
        },
      });
      nextFrame(framesRef, () => dispatch({ type: "patch", state: { height: newHeight } }));
      later(timersRef, TOP_PANEL_RESIZE_MS, () => {
        dispatch({ type: "patch", state: { phase: "swapping" } });
        later(timersRef, TOP_PANEL_SLIDE_MS, () => {
          dispatch({ type: "patch", state: { previousPanel: null, phase: "idle", height: "auto" } });
        });
      });
      return;
    }

    dispatch({
      type: "replace",
      state: {
        visiblePanel: activePanel,
        previousPanel: oldPanel,
        phase: "swapping",
        direction: nextDirection,
        height: oldHeight,
        transitionHeights,
      },
    });
    later(timersRef, TOP_PANEL_SLIDE_MS, () => {
      if (newHeight < oldHeight - 2) {
        dispatch({ type: "patch", state: { previousPanel: null, phase: "post-resize" } });
        nextFrame(framesRef, () => dispatch({ type: "patch", state: { height: newHeight } }));
        later(timersRef, TOP_PANEL_RESIZE_MS, () => {
          dispatch({ type: "patch", state: { phase: "idle", height: "auto" } });
        });
      } else {
        dispatch({ type: "patch", state: { previousPanel: null, phase: "idle", height: "auto" } });
      }
    });
  }, [activePanel]);

  const showStaticPrevious = state.phase === "pre-resize" && state.previousPanel;
  const showSwapping = state.phase === "swapping" && state.previousPanel !== null && state.visiblePanel !== null;
  const showTrackCurrent = state.visiblePanel !== null && !showStaticPrevious && state.phase !== "opening" && state.phase !== "closing";
  const showStaticCurrent = state.visiblePanel && !showStaticPrevious && !showTrackCurrent;
  const panes =
    showSwapping && state.previousPanel !== null && state.visiblePanel !== null
      ? state.direction === "forward"
        ? [
            { panel: state.previousPanel, current: false },
            { panel: state.visiblePanel, current: true },
          ]
        : [
            { panel: state.visiblePanel, current: true },
            { panel: state.previousPanel, current: false },
          ]
      : state.visiblePanel
        ? [{ panel: state.visiblePanel, current: true }]
        : [];
  const resizeMode =
    state.phase === "swapping" && state.transitionHeights.to < state.transitionHeights.from - 2
      ? "shrinking"
      : state.phase === "swapping" && state.transitionHeights.to > state.transitionHeights.from + 2
        ? "growing"
        : "steady";
  const viewportStyle = {
    height: topPanelViewportHeight(panes.length > 0, state.height),
    "--top-panel-next-height": `${Math.max(state.transitionHeights.to, 0)}px`,
  } as React.CSSProperties;

  return (
    <>
      <div className="top-panel-measure" ref={measureRef} aria-hidden="true">
        {activePanel ? (
          <div className="top-panel-motion-frame">
            <div className="top-panel-pane-inner">
              <TopPanelContent {...contentProps} panel={activePanel} interactive={false} />
            </div>
          </div>
        ) : null}
      </div>
      <div
        ref={viewportRef}
        className="top-panel-viewport"
        data-phase={state.phase}
        data-resize={resizeMode}
        data-has-content={panes.length > 0}
        style={viewportStyle}
      >
        {showStaticPrevious ? (
          <div ref={visibleRef} className="top-panel-static" data-motion="hold">
            <div className="top-panel-motion-frame">
              <div className="top-panel-pane-inner">
                {state.previousPanel ? <TopPanelContent {...contentProps} panel={state.previousPanel} /> : null}
              </div>
            </div>
          </div>
        ) : null}
        {showTrackCurrent ? (
          <div className="top-panel-track" data-direction={state.direction} data-phase={showSwapping ? "swapping" : "idle"}>
            {panes.map(({ panel, current }) => (
              <div
                key={panel}
                ref={current ? visibleRef : undefined}
                className="top-panel-pane"
                data-pane={current ? "current" : "previous"}
                aria-hidden={!current}
              >
                <div className="top-panel-motion-frame">
                  <div className="top-panel-pane-inner">
                    <TopPanelContent {...contentProps} panel={panel} />
                  </div>
                </div>
              </div>
            ))}
          </div>
        ) : null}
        {showStaticCurrent ? (
          <div
            ref={visibleRef}
            className="top-panel-static"
            data-motion={state.phase === "opening" ? "open" : state.phase === "closing" ? "close" : "idle"}
            data-direction={state.direction}
          >
            <div className="top-panel-motion-frame">
              <div className="top-panel-pane-inner">
                {state.visiblePanel ? <TopPanelContent {...contentProps} panel={state.visiblePanel} /> : null}
              </div>
            </div>
          </div>
        ) : null}
      </div>
    </>
  );
}

function topPanelViewportHeight(hasPanes: boolean, height: TopPanelCarouselState["height"]) {
  if (!hasPanes) return "0px";
  if (height === "auto") return undefined;
  return `${Math.max(height, 0)}px`;
}

export function StatusTile({
  panel,
  title,
  value,
  icon,
  tone,
  openPanel,
  onToggle,
  pulseToken = 0,
}: {
  panel: TopPanelKey;
  title: string;
  value: number;
  icon: React.ReactNode;
  tone: StatusTileTone;
  openPanel: TopPanelKey | null;
  onToggle: (panel: TopPanelKey | null) => void;
  pulseToken?: number;
}) {
  const open = openPanel === panel;
  const countMotion = useCountMotion(value, pulseToken);
  const toneClasses = STATUS_TILE_TONES[tone];

  return (
    <button
      type="button"
      className={cn(
        "dashboard-glass-surface status-tile motion-card group flex min-h-[104px] items-center justify-between rounded-lg border bg-card p-5 text-left shadow-sm outline-none transition-all hover:shadow-dashboard focus-visible:ring-2 focus-visible:ring-ring",
        open && toneClasses.card,
      )}
      data-count-motion={countMotion.direction}
      onClick={() => onToggle(open ? null : panel)}
      aria-expanded={open}
    >
      <div className="flex items-center gap-4">
        <div className={cn("flex size-12 items-center justify-center rounded-full border", toneClasses.icon)}>{icon}</div>
        <div>
          <p className="text-base font-semibold">{title}</p>
          <p className={cn("mt-2 text-3xl font-semibold", toneClasses.value)}>
            <NumberWheel value={value} motion={countMotion} />
          </p>
        </div>
      </div>
      <Tooltip>
        <TooltipTrigger asChild>
          <span className="flex size-8 items-center justify-center rounded-md text-muted-foreground transition-colors group-hover:bg-muted group-hover:text-foreground">
            <ChevronDown className={cn("size-4 transition-transform duration-200", open && "rotate-180")} />
          </span>
        </TooltipTrigger>
        <TooltipContent>{open ? "Collapse" : "Open"}</TooltipContent>
      </Tooltip>
    </button>
  );
}

export function TopTray({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <Card className="dashboard-glass-surface top-tray-card overflow-hidden">
      <CardHeader className="pb-3">
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent>{children}</CardContent>
    </Card>
  );
}

export function UpdateSimulationControls({ updateAnimations }: { updateAnimations: DashboardUpdateAnimations }) {
  return (
    <div className="update-sim-controls" aria-label="Simulate dashboard update animations">
      {UPDATE_SIMULATION_CONTROLS.map((control) => (
        <Tooltip key={control.kind}>
          <TooltipTrigger asChild>
            <button
              type="button"
              className="update-sim-button"
              onClick={() => updateAnimations.simulate(control.kind)}
              aria-label={control.tooltip}
            >
              {control.icon}
              <span className="sr-only">{control.label}</span>
            </button>
          </TooltipTrigger>
          <TooltipContent>{control.tooltip}</TooltipContent>
        </Tooltip>
      ))}
    </div>
  );
}
