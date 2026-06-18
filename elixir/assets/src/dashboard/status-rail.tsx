import { AlertTriangle, MessageSquareText, RefreshCw } from "lucide-react";
import { AnimatedTopGrid, NumberWheel, TOP_PANEL_RESIZE_MS, TOP_PANEL_SLIDE_MS, useCountMotion } from "@/components/dashboard/motion";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { GuidanceItem } from "@/types/dashboard";
import type * as React from "react";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { clearMotionTimers, later, measureElementHeight, nextFrame } from "@/components/dashboard/motion-utils";
import { BlockerPreviewCard } from "./blocker-preview-card";
import { useCallback, useEffect, useLayoutEffect, useReducer, useRef } from "react";
import { BlockerItem } from "./dashboard-state";
import { GuidancePreviewCard } from "./guidance-preview-card";
import { CardDetailSelect, CardDetailSelection, DashboardUpdateAnimations, TopPanelDirection, TopPanelKey, TopPanelPhase } from "./runtime";
import { EmptyPanel } from "./detail-extras";
import { blockerUpdateKey, guidanceUpdateKey } from "./update-animations";
import { topPanelDirection } from "./dashboard-persistence";

const UPDATE_SIMULATION_CONTROLS = [
  { kind: "guidance", label: "G", icon: <MessageSquareText className="size-3.5" />, tooltip: "Simulate new human guidance" },
  { kind: "blocker", label: "B", icon: <AlertTriangle className="size-3.5" />, tooltip: "Simulate a fresh blocker" },
  { kind: "changed", label: "U", icon: <RefreshCw className="size-3.5" />, tooltip: "Simulate a card update" },
] as const;

export function StatusRail({
  openPanel,
  guidanceItems,
  blockerItems,
  onSelectGuidance,
  onSelectCard,
  updateAnimations,
}: Omit<TopPanelContentProps, "panel" | "interactive"> & {
  openPanel: TopPanelKey | null;
}) {
  const selectCardFromPanel = useCallback((selection: CardDetailSelection) => onSelectCard(selection), [onSelectCard]);
  const panelContentProps = {
    blockerItems,
    guidanceItems,
    onSelectCard: selectCardFromPanel,
    onSelectGuidance,
    updateAnimations,
  };

  return (
    <section className="dashboard-top-panel-anchor top-panel-inline" data-open-panel={openPanel ?? "none"}>
      <TopPanelCarousel activePanel={openPanel} {...panelContentProps} />
    </section>
  );
}

export function AttentionBarControls({
  openPanel,
  guidanceItems,
  blockerItems,
  onToggle,
  updateAnimations,
}: {
  openPanel: TopPanelKey | null;
  guidanceItems: GuidanceItem[];
  blockerItems: BlockerItem[];
  onToggle: (panel: TopPanelKey | null) => void;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const configs: AttentionButtonConfig[] = [
    {
      icon: <MessageSquareText className="size-6" />,
      panel: "guidance",
      pulseToken: updateAnimations.countPulseFor("guidance"),
      title: "Human Guidance Needed",
      tone: "guidance",
      value: guidanceItems.length,
    },
    {
      icon: <AlertTriangle className="size-6" />,
      panel: "blockers",
      pulseToken: updateAnimations.countPulseFor("blockers"),
      title: "Active Blockers",
      tone: blockerItems.length === 0 ? "blocker-clear" : "blocker",
      value: blockerItems.length,
    },
  ];

  return (
    <div className="dashboard-attention-controls" aria-label="Dashboard attention">
      {configs.map((config) => (
        <AttentionBarButton key={config.panel} {...config} open={openPanel === config.panel} onToggle={onToggle} />
      ))}
    </div>
  );
}

type AttentionButtonConfig = {
  icon: React.ReactNode;
  panel: TopPanelKey;
  pulseToken: number;
  title: string;
  tone: "guidance" | "blocker" | "blocker-clear";
  value: number;
};

export type TopPanelContentProps = {
  panel: TopPanelKey;
  interactive?: boolean;
  guidanceItems: GuidanceItem[];
  blockerItems: BlockerItem[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
};

function TopPanelContent({
  panel,
  interactive = true,
  guidanceItems,
  blockerItems,
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

function TopPanelCarousel({
  activePanel,
  guidanceItems,
  blockerItems,
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
    if (newHeight < oldHeight - 2) {
      nextFrame(framesRef, () => dispatch({ type: "patch", state: { height: newHeight } }));
    }
    later(timersRef, TOP_PANEL_SLIDE_MS, () => {
      dispatch({ type: "patch", state: { previousPanel: null, phase: "idle", height: "auto" } });
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

function AttentionBarButton({
  panel,
  title,
  value,
  icon,
  tone,
  open,
  onToggle,
  pulseToken = 0,
}: AttentionButtonConfig & {
  open: boolean;
  onToggle: (panel: TopPanelKey | null) => void;
}) {
  const countMotion = useCountMotion(value, pulseToken);

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button
          type="button"
          className="dashboard-attention-button"
          data-count-motion={countMotion.direction}
          data-state={open ? "open" : "closed"}
          data-tone={tone}
          onClick={() => onToggle(open ? null : panel)}
          aria-label={`${title}: ${value}`}
          aria-expanded={open}
        >
          {icon}
          <span className="dashboard-attention-count" aria-hidden="true">
            <NumberWheel value={value} motion={countMotion} compact />
          </span>
        </button>
      </TooltipTrigger>
      <TooltipContent>{title}</TooltipContent>
    </Tooltip>
  );
}

function TopTray({ title, children }: { title: string; children: React.ReactNode }) {
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
