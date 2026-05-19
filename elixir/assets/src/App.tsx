import {
  AlertCircle,
  AlertTriangle,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  CircleDot,
  Clock3,
  GitBranch,
  Loader2,
  MessageSquareText,
  Plus,
  RefreshCw,
  Route,
  Send,
} from "lucide-react";
import type * as React from "react";
import { Children, FormEvent, useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Separator } from "@/components/ui/separator";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import type {
  ClarificationQuestion,
  DashboardPayload,
  DecisionOption,
  DecisionPrompt,
  GuidanceRequest,
  PlannedSlice,
  SoloSession,
  WorkPackageCard,
  WorkRequestCard,
  WorkRequestDetail,
} from "@/types/dashboard";

const CUSTOM_CHOICE = "__custom_redirect__";
const DASHBOARD_URL = "/api/v1/sympp/operator/dashboard";
const DASHBOARD_UI_STATE_KEY = "symphony-plus-plus.dashboard.ui-state.v1";
const TOP_PANEL_ORDER: TopPanelKey[] = ["guidance", "blockers", "finished"];
const TOP_PANEL_RESIZE_MS = 210;
const TOP_PANEL_SLIDE_MS = 360;

type GuidanceItem =
  | {
      source: "guidance";
      id: string;
      repo: string;
      title: string;
      packageId: string;
      prompt?: DecisionPrompt | null;
      detail: string;
      guidance: GuidanceRequest;
    }
  | {
      source: "clarification";
      id: string;
      repo: string;
      title: string;
      workRequestId: string;
      prompt?: DecisionPrompt | null;
      detail: string;
      question: ClarificationQuestion;
      request: WorkRequestCard;
    };

type TopPanelKey = "guidance" | "blockers" | "finished";
type TopPanelDirection = "forward" | "backward";
type TopPanelPhase = "idle" | "opening" | "closing" | "pre-resize" | "swapping" | "post-resize";
type BoardLane = "slices" | "implementing" | "finished";
type SignalTone = "muted" | "info" | "warning" | "danger" | "success";
type StateCardTone = "request" | "queued" | "slice" | "implementing" | "review" | "merge" | "guidance" | "blocked" | "finished" | "muted";
type BoardWireTone = StateCardTone;
type WorkspaceTab = "workstreams" | "solo";
type WorkstreamLayoutMode = "jira" | "aligned";
type DashboardUiState = {
  workspaceTab?: WorkspaceTab;
  topPanel?: TopPanelKey | null;
  repoWorkstreams?: Record<string, boolean>;
  workstreamLayout?: WorkstreamLayoutMode;
};

type BlockerItem = {
  id: string;
  title: string;
  repo: string;
  status?: string | null;
  blockerCount: number;
  detail: string;
};

type FinishedHighlight = {
  id: string;
  title: string;
  repo: string;
  kind: "Request" | "Slice" | "Package";
  status?: string | null;
  at?: string | null;
};

type BoardWire = {
  id: string;
  from: string;
  to: string;
  tone: BoardWireTone;
};

type BoardWirePath = BoardWire & {
  path: string;
  sourceX: number;
  sourceY: number;
  targetX: number;
  targetY: number;
  hiddenRects: BoardWireHiddenRect[];
};

type BoardWireHiddenRect = {
  x: number;
  y: number;
  width: number;
  height: number;
};

type SliceEntry = {
  detail: WorkRequestDetail;
  slice: PlannedSlice;
  pkg?: WorkPackageCard;
  requestIndex: number;
};

type WorkstreamRow = {
  detail?: WorkRequestDetail;
  active: SliceEntry[];
  implementing: SliceEntry[];
  finished: SliceEntry[];
  activePackages: WorkPackageCard[];
  implementingPackages: WorkPackageCard[];
  finishedPackages: WorkPackageCard[];
  height: number;
  unlinked?: boolean;
};

type NewRequestForm = {
  title: string;
  repo: string;
  base_branch: string;
  work_type: string;
  desired_dispatch_shape: string;
  human_description: string;
};

type BadgeTone = "default" | "secondary" | "outline" | "success" | "warning" | "danger" | "info";

const initialRequestForm: NewRequestForm = {
  title: "",
  repo: "symphony-plus-plus",
  base_branch: "main",
  work_type: "feature",
  desired_dispatch_shape: "architect_led_feature_branch",
  human_description: "",
};

export default function App() {
  const [dashboard, setDashboard] = useState<DashboardPayload | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selectedGuidance, setSelectedGuidance] = useState<GuidanceItem | null>(null);
  const [newRequestOpen, setNewRequestOpen] = useState(false);
  const [workspaceTab, setWorkspaceTab] = useState<WorkspaceTab>(readStoredWorkspaceTab);
  const [workstreamLayout, setWorkstreamLayout] = useState<WorkstreamLayoutMode>(readStoredWorkstreamLayout);

  const loadDashboard = useCallback(async (mode: "initial" | "refresh" = "refresh") => {
    if (mode === "initial") {
      setLoading(true);
    } else {
      setRefreshing(true);
    }

    try {
      const response = await fetch(DASHBOARD_URL, { headers: { accept: "application/json" } });
      const payload = await response.json();

      if (!response.ok) {
        throw new Error(payload?.error?.message || "Dashboard API unavailable");
      }

      setDashboard(payload);
      setError(null);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Dashboard API unavailable");
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, []);

  useEffect(() => {
    void loadDashboard("initial");
  }, [loadDashboard]);

  useEffect(() => {
    writeDashboardUiStateValue("workspaceTab", workspaceTab);
  }, [workspaceTab]);

  useEffect(() => {
    writeDashboardUiStateValue("workstreamLayout", workstreamLayout);
  }, [workstreamLayout]);

  const packages = useMemo(() => allPackages(dashboard), [dashboard]);
  const requests = dashboard?.work_requests?.work_requests ?? [];
  const requestDetails = dashboard?.work_request_details ?? [];
  const guidanceItems = useMemo(() => allGuidanceItems(dashboard), [dashboard]);
  const blockerItems = useMemo(() => activeBlockerItems(packages), [packages]);
  const finishedHighlights = useMemo(() => recentFinishedHighlights(packages, requests, requestDetails), [packages, requests, requestDetails]);
  const soloSessions = dashboard?.solo_sessions?.solo_sessions ?? [];
  const repos = useMemo(() => repoSummaries(packages, requests, guidanceItems, soloSessions, requestDetails), [
    packages,
    requests,
    guidanceItems,
    soloSessions,
    requestDetails,
  ]);

  if (loading) {
    return (
      <main className="flex min-h-screen items-center justify-center">
        <div className="flex items-center gap-3 rounded-lg border bg-card px-5 py-4 text-sm text-muted-foreground shadow-sm">
          <Loader2 className="h-4 w-4 animate-spin" />
          Loading Symphony++
        </div>
      </main>
    );
  }

  return (
    <TooltipProvider delayDuration={150}>
      <main className="min-h-screen bg-background">
        <header className="sticky top-0 z-20 border-b bg-background/92 backdrop-blur">
          <div className="mx-auto flex max-w-[1500px] flex-col gap-4 px-4 py-4 sm:px-6 lg:flex-row lg:items-center lg:justify-between lg:px-8">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center overflow-hidden rounded-lg border bg-card shadow-sm motion-pop">
                <img src="/splusplus-logo.png" alt="Symphony++" className="h-full w-full scale-[1.34] object-contain" />
              </div>
              <div>
                <h1 className="text-xl font-semibold">Symphony++</h1>
                <p className="text-sm text-muted-foreground">Operator cockpit</p>
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <Badge variant={error ? "danger" : "success"}>{error ? "API unavailable" : "Live ledger"}</Badge>
              <Button variant="outline" size="sm" onClick={() => void loadDashboard()} disabled={refreshing} className="button-lift">
                {refreshing ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}
                Refresh
              </Button>
              <NewRequestDialog
                open={newRequestOpen}
                onOpenChange={setNewRequestOpen}
                onCreated={(payload) => {
                  setDashboard(payload);
                  setNewRequestOpen(false);
                }}
                defaultRepo={repos[0]?.repo}
                repos={repos}
              />
            </div>
          </div>
        </header>

        <div className="mx-auto grid max-w-[1500px] gap-5 px-4 py-5 sm:px-6 lg:px-8">
          {error ? (
            <Card className="border-rose-200 bg-rose-50 motion-card">
              <CardContent className="flex items-center gap-3 p-4 text-sm text-rose-800">
                <AlertCircle className="h-4 w-4" />
                {error}
              </CardContent>
            </Card>
          ) : null}

          <StatusRail
            guidanceItems={guidanceItems}
            blockerItems={blockerItems}
            finishedHighlights={finishedHighlights}
            onSelectGuidance={setSelectedGuidance}
          />

          <Tabs value={workspaceTab} onValueChange={(value) => setWorkspaceTab(value as WorkspaceTab)} className="w-full motion-card">
            <div className="dashboard-tabs-row">
              <TabsList className="dashboard-tabs-list">
                <span className="dashboard-tabs-indicator" data-tab={workspaceTab} aria-hidden="true" />
                <TabsTrigger value="workstreams" className="dashboard-tabs-trigger">
                  Workstreams
                </TabsTrigger>
                <TabsTrigger value="solo" className="dashboard-tabs-trigger">
                  Solo Sessions
                </TabsTrigger>
              </TabsList>
              {workspaceTab === "workstreams" ? <WorkstreamLayoutToggle value={workstreamLayout} onChange={setWorkstreamLayout} /> : null}
            </div>
            <TabsContent value="workstreams">
              <div className="grid gap-5">
                {repos.length === 0 ? (
                  <EmptyPanel title="No workstreams yet" />
                ) : (
                  repos.map((repo) => (
                    <RepoWorkstream
                      key={repoWorkstreamStateKey(repo)}
                      repo={repo}
                      requestDetails={requestDetails}
                      onSelectGuidance={setSelectedGuidance}
                      layoutMode={workstreamLayout}
                    />
                  ))
                )}
              </div>
            </TabsContent>
            <TabsContent value="solo">
              <SoloSessions sessions={soloSessions} />
            </TabsContent>
          </Tabs>
        </div>

        <GuidanceDialog
          item={selectedGuidance}
          onOpenChange={(open) => {
            if (!open) setSelectedGuidance(null);
          }}
          onAnswered={(payload) => {
            setDashboard(payload);
            setSelectedGuidance(null);
          }}
        />
      </main>
    </TooltipProvider>
  );
}

function StatusRail({
  guidanceItems,
  blockerItems,
  finishedHighlights,
  onSelectGuidance,
}: {
  guidanceItems: GuidanceItem[];
  blockerItems: BlockerItem[];
  finishedHighlights: FinishedHighlight[];
  onSelectGuidance: (item: GuidanceItem) => void;
}) {
  const [openPanel, setOpenPanel] = useState<TopPanelKey | null>(readStoredTopPanel);
  const renderPanel = useCallback(
    (panel: TopPanelKey) => {
      if (panel === "guidance") {
        return (
          <TopTray title="Decisions and input needed to keep work moving">
            {guidanceItems.length === 0 ? (
              <EmptyPanel title="No human guidance needed" compact />
            ) : (
              <div className="grid gap-3 xl:grid-cols-2">
                {guidanceItems.slice(0, 6).map((item, index) => (
                  <GuidancePreviewCard key={`${item.source}-${item.id}`} item={item} index={index} onSelect={onSelectGuidance} />
                ))}
              </div>
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
              <div className="grid gap-3 lg:grid-cols-2 xl:grid-cols-3">
                {blockerItems.map((item, index) => (
                  <BlockerPreviewCard key={item.id} item={item} index={index} />
                ))}
              </div>
            )}
          </TopTray>
        );
      }

      return (
        <TopTray title="Most recent finished work">
          {finishedHighlights.length === 0 ? (
            <EmptyPanel title="Nothing finished yet" compact />
          ) : (
            <ScrollArea className="finished-highlights-scroll pr-3">
              <div className="grid gap-2">
                {finishedHighlights.map((item, index) => (
                  <FinishedHighlightRow key={`${item.kind}-${item.id}`} item={item} index={index} />
                ))}
              </div>
            </ScrollArea>
          )}
        </TopTray>
      );
    },
    [blockerItems, finishedHighlights, guidanceItems, onSelectGuidance],
  );

  useEffect(() => {
    writeDashboardUiStateValue("topPanel", openPanel);
  }, [openPanel]);

  return (
    <section className="relative grid gap-3">
      <div className="grid gap-3 lg:grid-cols-3">
        <StatusTile
          panel="guidance"
          title="Human Guidance Needed"
          value={guidanceItems.length}
          icon={<MessageSquareText className="h-6 w-6" />}
          tone="violet"
          openPanel={openPanel}
          onToggle={setOpenPanel}
        />
        <StatusTile
          panel="blockers"
          title="Active Blockers"
          value={blockerItems.length}
          icon={<AlertTriangle className="h-6 w-6" />}
          tone="amber"
          openPanel={openPanel}
          onToggle={setOpenPanel}
        />
        <StatusTile
          panel="finished"
          title="Ready / Finished"
          value={finishedHighlights.length}
          icon={<CheckCircle2 className="h-6 w-6" />}
          tone="emerald"
          openPanel={openPanel}
          onToggle={setOpenPanel}
        />
      </div>

      <TopPanelCarousel activePanel={openPanel} renderPanel={renderPanel} />
    </section>
  );
}

function TopPanelCarousel({
  activePanel,
  renderPanel,
}: {
  activePanel: TopPanelKey | null;
  renderPanel: (panel: TopPanelKey) => React.ReactNode;
}) {
  const [visiblePanel, setVisiblePanel] = useState<TopPanelKey | null>(activePanel);
  const [previousPanel, setPreviousPanel] = useState<TopPanelKey | null>(null);
  const [phase, setPhase] = useState<TopPanelPhase>("idle");
  const [direction, setDirection] = useState<TopPanelDirection>("forward");
  const [height, setHeight] = useState<number | "auto">(activePanel ? "auto" : 0);
  const [transitionHeights, setTransitionHeights] = useState({ from: 0, to: 0 });
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const visibleRef = useRef<HTMLDivElement | null>(null);
  const measureRef = useRef<HTMLDivElement | null>(null);
  const latestPanelRef = useRef<TopPanelKey | null>(activePanel);
  const timersRef = useRef<number[]>([]);
  const framesRef = useRef<number[]>([]);

  useEffect(
    () => () => {
      clearTopPanelTimers(timersRef, framesRef);
    },
    [],
  );

  useLayoutEffect(() => {
    const oldPanel = latestPanelRef.current;
    if (oldPanel === activePanel) return;

    clearTopPanelTimers(timersRef, framesRef);

    const oldHeight = measureElementHeight(visibleRef.current) || measureElementHeight(viewportRef.current);
    const newHeight = activePanel ? measureElementHeight(measureRef.current) : 0;
    const nextDirection = topPanelDirection(oldPanel, activePanel);

    setDirection(nextDirection);
    setTransitionHeights({ from: oldHeight, to: newHeight });

    if (!oldPanel && activePanel) {
      latestPanelRef.current = activePanel;
      setVisiblePanel(activePanel);
      setPreviousPanel(null);
      setPhase("opening");
      setHeight(0);
      nextFrame(framesRef, () => setHeight(newHeight));
      later(timersRef, TOP_PANEL_SLIDE_MS, () => {
        setPhase("idle");
        setHeight("auto");
      });
      return;
    }

    if (oldPanel && !activePanel) {
      latestPanelRef.current = null;
      setVisiblePanel(oldPanel);
      setPreviousPanel(null);
      setPhase("closing");
      setHeight(oldHeight);
      nextFrame(framesRef, () => setHeight(0));
      later(timersRef, TOP_PANEL_SLIDE_MS, () => {
        setVisiblePanel(null);
        setPhase("idle");
      });
      return;
    }

    if (!oldPanel || !activePanel) return;

    latestPanelRef.current = activePanel;
    setPreviousPanel(oldPanel);
    setVisiblePanel(activePanel);

    if (newHeight > oldHeight + 2) {
      setPhase("pre-resize");
      setHeight(oldHeight);
      nextFrame(framesRef, () => setHeight(newHeight));
      later(timersRef, TOP_PANEL_RESIZE_MS, () => {
        setPhase("swapping");
        later(timersRef, TOP_PANEL_SLIDE_MS, () => {
          setPreviousPanel(null);
          setPhase("idle");
          setHeight("auto");
        });
      });
      return;
    }

    setPhase("swapping");
    setHeight(oldHeight);
    later(timersRef, TOP_PANEL_SLIDE_MS, () => {
      setPreviousPanel(null);

      if (newHeight < oldHeight - 2) {
        setPhase("post-resize");
        nextFrame(framesRef, () => setHeight(newHeight));
        later(timersRef, TOP_PANEL_RESIZE_MS, () => {
          setPhase("idle");
          setHeight("auto");
        });
      } else {
        setPhase("idle");
        setHeight("auto");
      }
    });
  }, [activePanel]);

  const showStaticPrevious = phase === "pre-resize" && previousPanel;
  const showSwapping = phase === "swapping" && previousPanel && visiblePanel;
  const showStaticCurrent = visiblePanel && !showStaticPrevious && !showSwapping;
  const resizeMode =
    phase === "swapping" && transitionHeights.to < transitionHeights.from - 2
      ? "shrinking"
      : phase === "swapping" && transitionHeights.to > transitionHeights.from + 2
        ? "growing"
        : "steady";
  const viewportStyle = {
    height: height === "auto" ? undefined : `${Math.max(height, 0)}px`,
    "--top-panel-next-height": `${Math.max(transitionHeights.to, 0)}px`,
  } as React.CSSProperties;

  return (
    <>
      <div className="top-panel-measure" ref={measureRef} aria-hidden="true">
        {activePanel ? renderPanel(activePanel) : null}
      </div>
      <div
        ref={viewportRef}
        className="top-panel-viewport"
        data-phase={phase}
        data-resize={resizeMode}
        style={viewportStyle}
      >
        {showStaticPrevious ? (
          <div ref={visibleRef} className="top-panel-static" data-motion="hold">
            {renderPanel(previousPanel)}
          </div>
        ) : null}
        {showSwapping ? (
          <>
            <div className="top-panel-layer" data-motion="exit" data-direction={direction}>
              {renderPanel(previousPanel)}
            </div>
            <div ref={visibleRef} className="top-panel-layer" data-motion="enter" data-direction={direction}>
              {renderPanel(visiblePanel)}
            </div>
          </>
        ) : null}
        {showStaticCurrent ? (
          <div
            ref={visibleRef}
            className="top-panel-static"
            data-motion={phase === "opening" ? "open" : phase === "closing" ? "close" : "idle"}
            data-direction={direction}
          >
            {renderPanel(visiblePanel)}
          </div>
        ) : null}
      </div>
    </>
  );
}

function StatusTile({
  panel,
  title,
  value,
  icon,
  tone,
  openPanel,
  onToggle,
}: {
  panel: TopPanelKey;
  title: string;
  value: number;
  icon: React.ReactNode;
  tone: "violet" | "amber" | "emerald";
  openPanel: TopPanelKey | null;
  onToggle: (panel: TopPanelKey | null) => void;
}) {
  const open = openPanel === panel;
  const tones = {
    violet: {
      card: "border-violet-300 bg-violet-50/35",
      icon: "border-violet-200 bg-violet-50 text-violet-700",
      value: "text-violet-700",
    },
    amber: {
      card: "border-amber-200 bg-amber-50/25",
      icon: "border-amber-200 bg-amber-50 text-amber-700",
      value: "text-amber-700",
    },
    emerald: {
      card: "border-emerald-200 bg-emerald-50/25",
      icon: "border-emerald-200 bg-emerald-50 text-emerald-700",
      value: "text-emerald-700",
    },
  };

  return (
    <button
      type="button"
      className={cn(
        "status-tile motion-card group flex min-h-[104px] items-center justify-between rounded-lg border bg-card p-5 text-left shadow-sm outline-none transition-all hover:-translate-y-0.5 hover:shadow-dashboard focus-visible:ring-2 focus-visible:ring-ring",
        open && tones[tone].card,
      )}
      onClick={() => onToggle(open ? null : panel)}
      aria-expanded={open}
    >
      <div className="flex items-center gap-4">
        <div className={cn("flex h-12 w-12 items-center justify-center rounded-full border", tones[tone].icon)}>{icon}</div>
        <div>
          <p className="text-base font-semibold">{title}</p>
          <p className={cn("mt-2 text-3xl font-semibold", tones[tone].value)}>{value}</p>
        </div>
      </div>
      <Tooltip>
        <TooltipTrigger asChild>
          <span className="flex h-8 w-8 items-center justify-center rounded-md text-muted-foreground transition-colors group-hover:bg-muted group-hover:text-foreground">
            <ChevronDown className={cn("h-4 w-4 transition-transform duration-200", open && "rotate-180")} />
          </span>
        </TooltipTrigger>
        <TooltipContent>{open ? "Collapse" : "Open"}</TooltipContent>
      </Tooltip>
    </button>
  );
}

function TopTray({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <Card className="top-tray-card overflow-hidden">
      <CardHeader className="pb-3">
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent>{children}</CardContent>
    </Card>
  );
}

function GuidancePreviewCard({ item, index, onSelect }: { item: GuidanceItem; index: number; onSelect: (item: GuidanceItem) => void }) {
  return (
    <button
      type="button"
      className={stateCardClassName(
        item.source === "guidance" ? "guidance" : "queued",
        "stagger-item grid gap-4 p-4 text-left hover:border-primary/50 hover:shadow-dashboard",
      )}
      style={{ animationDelay: `${index * 45}ms` }}
      onClick={() => onSelect(item)}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-violet-50 text-violet-700">
              <Route className="h-4 w-4" />
            </div>
            <p className="truncate text-sm font-semibold">{item.repo}</p>
            <Badge variant="secondary">{item.source === "guidance" ? "Package" : "Request"}</Badge>
          </div>
          <p className="mt-4 text-sm font-medium">TL;DR</p>
          <p className="mt-1 line-clamp-2 text-sm text-muted-foreground">{item.prompt?.tl_dr || item.title}</p>
          <p className="mt-4 text-sm font-medium">Description</p>
          <p className="mt-1 line-clamp-3 text-sm text-muted-foreground">{item.prompt?.details || item.detail}</p>
        </div>
        <Badge variant={item.source === "guidance" ? "danger" : "warning"}>{item.source === "guidance" ? "Guidance" : "Clarify"}</Badge>
      </div>
    </button>
  );
}

function BlockerPreviewCard({ item, index }: { item: BlockerItem; index: number }) {
  return (
    <div
      className={stateCardClassName("blocked", "stagger-item p-4")}
      style={{ animationDelay: `${index * 45}ms` }}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{item.title}</p>
          <p className="mt-1 truncate text-xs text-muted-foreground">{item.repo}</p>
        </div>
        <Badge variant="danger">{formatStatus(item.status)}</Badge>
      </div>
      <p className="mt-4 line-clamp-3 text-sm text-muted-foreground">{item.detail}</p>
      <div className="mt-4 flex items-center gap-2 text-xs text-amber-800">
        <AlertTriangle className="h-4 w-4" />
        {item.blockerCount} active blocker{item.blockerCount === 1 ? "" : "s"}
      </div>
    </div>
  );
}

function FinishedHighlightRow({ item, index }: { item: FinishedHighlight; index: number }) {
  return (
    <div
      className={stateCardClassName("finished", "stagger-item flex items-center justify-between gap-4 p-3")}
      style={{ animationDelay: `${index * 30}ms` }}
    >
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <CheckCircle2 className="h-4 w-4 text-emerald-600" />
          <p className="truncate text-sm font-semibold">{item.title}</p>
        </div>
        <p className="mt-1 truncate text-xs text-muted-foreground">{item.repo}</p>
      </div>
      <div className="flex shrink-0 items-center gap-2">
        <Badge variant="success">{item.kind}</Badge>
        {item.at ? (
          <span className="hidden items-center gap-1 text-xs text-muted-foreground sm:flex">
            <Clock3 className="h-3.5 w-3.5" />
            {formatDate(item.at)}
          </span>
        ) : null}
      </div>
    </div>
  );
}

function RepoWorkstream({
  repo,
  requestDetails,
  onSelectGuidance,
  layoutMode,
}: {
  repo: RepoSummary;
  requestDetails: WorkRequestDetail[];
  onSelectGuidance: (item: GuidanceItem) => void;
  layoutMode: WorkstreamLayoutMode;
}) {
  const stateKey = repoWorkstreamStateKey(repo);
  const [open, setOpen] = useState(() => readStoredRepoWorkstreamOpen(stateKey, defaultRepoWorkstreamOpen()));
  const repoDetails = requestDetails.filter((detail) => repoName(detail.work_request.repo) === repo.repo);
  const unlinkedPackages = repo.packages.filter((pkg) => !packageLinkedToRequest(pkg, requestDetails));

  useEffect(() => {
    writeStoredRepoWorkstreamOpen(stateKey, open);
  }, [open, stateKey]);

  return (
    <Collapsible open={open} onOpenChange={setOpen}>
      <Card className="motion-card overflow-hidden">
        <CardHeader className="border-b bg-card">
          <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
            <div className="flex min-w-0 items-center gap-3">
              <CollapsibleTrigger asChild>
                <Button variant="ghost" size="icon" className="h-8 w-8 shrink-0" aria-label={`${open ? "Collapse" : "Open"} ${repo.repo}`}>
                  <ChevronRight className={cn("h-4 w-4 transition-transform duration-200", open && "rotate-90")} />
                </Button>
              </CollapsibleTrigger>
              <div className="min-w-0">
                <CardTitle className="flex items-center gap-2">
                  <GitBranch className="h-4 w-4 text-primary" />
                  <span className="truncate">{repo.repo}</span>
                </CardTitle>
                <p className="mt-1 truncate text-sm text-muted-foreground">{repo.baseBranches.join(", ") || "main"}</p>
              </div>
            </div>
            <div className="flex min-w-0 flex-col gap-2 md:items-end">
              <RepoSummaryStrip repo={repo} />
            </div>
          </div>
        </CardHeader>
        <CollapsibleContent className="collapsible-content">
          <CardContent className="p-3 sm:p-4">
            <WorkstreamBoard
              repoDetails={repoDetails}
              packages={repo.packages}
              unlinkedPackages={unlinkedPackages}
              onSelectGuidance={onSelectGuidance}
              layoutMode={layoutMode}
            />
          </CardContent>
        </CollapsibleContent>
      </Card>
    </Collapsible>
  );
}

function RepoSummaryStrip({ repo }: { repo: RepoSummary }) {
  const progress = [
    { label: "Requests", value: repo.requested, tone: "requested" },
    { label: "Slices", value: repo.active, tone: "active" },
    { label: "Implementing", value: repo.implementing, tone: "implementing" },
    { label: "Finished", value: repo.finished, tone: "finished" },
  ] as const;
  const attention = [
    { label: "Guidance Needed", value: repo.guidanceCount, tone: "guidance" },
    { label: "Active Blockers", value: repo.blockerCount, tone: "blocker" },
  ] as const;

  return (
    <div className="flex min-w-0 flex-wrap items-center gap-2 md:justify-end">
      <div className="flex flex-wrap items-center gap-1.5">
        {progress.map((item) => (
          <RepoSummaryPlate key={item.label} label={item.label} value={item.value} tone={item.tone} />
        ))}
      </div>
      <div className="hidden h-6 w-px bg-border md:block" />
      <div className="flex flex-wrap items-center gap-1.5">
        {attention.map((item) => (
          <RepoSummaryPlate key={item.label} label={item.label} value={item.value} tone={item.tone} />
        ))}
      </div>
    </div>
  );
}

function WorkstreamLayoutToggle({ value, onChange }: { value: WorkstreamLayoutMode; onChange: (mode: WorkstreamLayoutMode) => void }) {
  return (
    <div className="workstream-layout-toggle" role="group" aria-label="Workstream layout">
      {[
        { value: "jira", label: "Jira" },
        { value: "aligned", label: "Aligned" },
      ].map((option) => (
        <button
          key={option.value}
          type="button"
          className="workstream-layout-toggle-button"
          data-active={value === option.value}
          onClick={() => onChange(option.value as WorkstreamLayoutMode)}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}

function RepoSummaryPlate({
  label,
  value,
  tone,
}: {
  label: string;
  value: number;
  tone: "requested" | "active" | "implementing" | "finished" | "guidance" | "blocker";
}) {
  const tones: Record<typeof tone, string> = {
    requested: "border-slate-200 bg-slate-50 text-slate-700",
    active: "border-cyan-200 bg-cyan-50 text-cyan-800",
    implementing: "border-sky-200 bg-sky-50 text-sky-700",
    finished: "border-emerald-200 bg-emerald-50 text-emerald-700",
    guidance: "border-violet-200 bg-violet-50 text-violet-700",
    blocker: "border-amber-200 bg-amber-50 text-amber-800",
  };

  return (
    <div className={cn("inline-flex items-center gap-1.5 rounded-md border px-2 py-1 text-xs font-medium", tones[tone])}>
      <span className="font-semibold tabular-nums">{value}</span>
      <span className="whitespace-nowrap">{label}</span>
    </div>
  );
}

function stateCardClassName(tone: StateCardTone, className?: string) {
  const tones: Record<StateCardTone, string> = {
    request: "border-slate-200 bg-slate-50/80 border-l-slate-300",
    queued: "border-teal-200/80 bg-teal-50/80 border-l-teal-400",
    slice: "border-cyan-200/80 bg-cyan-50/80 border-l-cyan-400",
    implementing: "border-sky-200/80 bg-sky-50/80 border-l-sky-400",
    review: "border-indigo-200/80 bg-indigo-50/80 border-l-indigo-400",
    merge: "border-amber-200/80 bg-amber-50/80 border-l-amber-400",
    guidance: "border-violet-200/80 bg-violet-50/80 border-l-violet-400",
    blocked: "border-rose-200/80 bg-rose-50/80 border-l-rose-400",
    finished: "border-emerald-200/80 bg-emerald-50/80 border-l-emerald-400",
    muted: "border-zinc-200/80 bg-zinc-50/80 border-l-zinc-300",
  };

  return cn(
    "min-w-0 max-w-full rounded-lg border border-l-4 shadow-sm transition-[background-color,border-color,box-shadow,transform] duration-150 ease-out",
    tones[tone],
    className,
  );
}

function WorkstreamBoard({
  repoDetails,
  packages,
  unlinkedPackages,
  onSelectGuidance,
  layoutMode,
}: {
  repoDetails: WorkRequestDetail[];
  packages: WorkPackageCard[];
  unlinkedPackages: WorkPackageCard[];
  onSelectGuidance: (item: GuidanceItem) => void;
  layoutMode: WorkstreamLayoutMode;
}) {
  const boardRef = useRef<HTMLDivElement | null>(null);
  const sortedDetails = useMemo(() => sortWorkRequestDetails(repoDetails), [repoDetails]);
  const requested = sortedDetails;
  const sliceEntries = sortedDetails.flatMap((detail, requestIndex) =>
    (detail.planned_slices ?? []).map((slice) => ({
      detail,
      slice,
      pkg: packages.find((candidate) => candidate.id === slice.work_package_id),
      requestIndex,
    })),
  );
  const active = sliceEntries.filter((entry) => sliceLane(entry.slice) === "slices");
  const implementing = sliceEntries.filter((entry) => sliceLane(entry.slice) === "implementing");
  const finished = sliceEntries.filter((entry) => sliceLane(entry.slice) === "finished");
  const sortedUnlinkedPackages = useMemo(() => sortPackages(unlinkedPackages), [unlinkedPackages]);
  const activePackages = sortedUnlinkedPackages.filter((pkg) => packageLane(pkg) === "slices");
  const implementingPackages = sortedUnlinkedPackages.filter((pkg) => packageLane(pkg) === "implementing");
  const finishedPackages = sortedUnlinkedPackages.filter((pkg) => packageLane(pkg) === "finished");
  const alignedRows = useMemo(
    () => workstreamRows(sortedDetails, sliceEntries, activePackages, implementingPackages, finishedPackages),
    [activePackages, finishedPackages, implementingPackages, sliceEntries, sortedDetails],
  );
  const rowTemplate = useAlignedRowTemplate(boardRef, alignedRows, layoutMode);
  const wires = useMemo(() => workstreamWires(sortedDetails, packages), [sortedDetails, packages]);
  const { paths: wirePaths, size: wireSize } = useBoardWirePaths(boardRef, wires, layoutMode);

  return (
    <div className="overflow-x-auto pb-1">
      <div
        ref={boardRef}
        className={cn("jira-board workstream-board min-w-[1040px]", layoutMode === "aligned" && "workstream-board-aligned")}
        data-layout={layoutMode}
      >
        <BoardWireLayer paths={wirePaths} width={wireSize.width} height={wireSize.height} />
        {layoutMode === "aligned" ? (
          <AlignedWorkstreamColumns
            rows={alignedRows}
            rowTemplate={rowTemplate}
            requestedCount={requested.length}
            sliceCount={active.length + activePackages.length}
            implementingCount={implementing.length + implementingPackages.length}
            finishedCount={finished.length + finishedPackages.length}
            onSelectGuidance={onSelectGuidance}
          />
        ) : (
          <StackedWorkstreamColumns
            requested={requested}
            active={active}
            implementing={implementing}
            finished={finished}
            activePackages={activePackages}
            implementingPackages={implementingPackages}
            finishedPackages={finishedPackages}
            onSelectGuidance={onSelectGuidance}
          />
        )}
      </div>
    </div>
  );
}

function StackedWorkstreamColumns({
  requested,
  active,
  implementing,
  finished,
  activePackages,
  implementingPackages,
  finishedPackages,
  onSelectGuidance,
}: {
  requested: WorkRequestDetail[];
  active: SliceEntry[];
  implementing: SliceEntry[];
  finished: SliceEntry[];
  activePackages: WorkPackageCard[];
  implementingPackages: WorkPackageCard[];
  finishedPackages: WorkPackageCard[];
  onSelectGuidance: (item: GuidanceItem) => void;
}) {
  return (
    <>
      <BoardLaneColumn title="Requests" count={requested.length} emptyLabel="No requested work">
        {requested.map((detail, index) => (
          <RequestCard key={detail.work_request.id} detail={detail} onSelectGuidance={onSelectGuidance} index={index} nodeId={requestNodeId(detail)} />
        ))}
      </BoardLaneColumn>
      <BoardLaneColumn title="Slices" count={active.length + activePackages.length} emptyLabel="No slices ready">
        {active.map(({ slice, pkg }, index) => (
          <SliceCard key={slice.id} slice={slice} pkg={pkg} lane="slices" index={index} nodeId={sliceNodeId(slice)} />
        ))}
        {activePackages.length > 0 ? <LaneGroupLabel label="Unlinked packages" /> : null}
        {activePackages.map((pkg, index) => (
          <PackageCard key={pkg.id} pkg={pkg} lane="slices" index={active.length + index} />
        ))}
      </BoardLaneColumn>
      <BoardLaneColumn title="Implementing" count={implementing.length + implementingPackages.length} emptyLabel="No implementation running">
        {implementing.map(({ slice, pkg }, index) => (
          <SliceCard key={slice.id} slice={slice} pkg={pkg} lane="implementing" index={index} nodeId={sliceNodeId(slice)} />
        ))}
        {implementingPackages.length > 0 ? <LaneGroupLabel label="Unlinked packages" /> : null}
        {implementingPackages.map((pkg, index) => (
          <PackageCard key={pkg.id} pkg={pkg} lane="implementing" index={implementing.length + index} />
        ))}
      </BoardLaneColumn>
      <BoardLaneColumn title="Finished" count={finished.length + finishedPackages.length} emptyLabel="Nothing finished yet">
        {finished.map(({ slice, pkg }, index) => (
          <SliceCard key={slice.id} slice={slice} pkg={pkg} lane="finished" index={index} nodeId={sliceNodeId(slice)} />
        ))}
        {finishedPackages.length > 0 ? <LaneGroupLabel label="Unlinked packages" /> : null}
        {finishedPackages.map((pkg, index) => (
          <PackageCard key={pkg.id} pkg={pkg} lane="finished" index={finished.length + index} />
        ))}
      </BoardLaneColumn>
    </>
  );
}

function AlignedWorkstreamColumns({
  rows,
  rowTemplate,
  requestedCount,
  sliceCount,
  implementingCount,
  finishedCount,
  onSelectGuidance,
}: {
  rows: WorkstreamRow[];
  rowTemplate: string;
  requestedCount: number;
  sliceCount: number;
  implementingCount: number;
  finishedCount: number;
  onSelectGuidance: (item: GuidanceItem) => void;
}) {
  const rowStyle = { gridTemplateRows: rowTemplate } as React.CSSProperties;

  return (
    <>
      <BoardLaneColumn title="Requests" count={requestedCount} emptyLabel="No requested work" bodyStyle={rowStyle} aligned>
        {rows.map((row, index) => (
          <FeatureLaneRow key={workstreamRowKey(row, index)} row={row} lane="requested" index={index}>
            {row.detail ? <RequestCard detail={row.detail} onSelectGuidance={onSelectGuidance} index={index} nodeId={requestNodeId(row.detail)} /> : null}
          </FeatureLaneRow>
        ))}
      </BoardLaneColumn>
      <BoardLaneColumn title="Slices" count={sliceCount} emptyLabel="No slices ready" bodyStyle={rowStyle} aligned>
        {rows.map((row, index) => (
          <FeatureLaneRow key={workstreamRowKey(row, index)} row={row} lane="slices" index={index}>
            {row.active.map(({ slice, pkg }, sliceIndex) => (
              <SliceCard key={slice.id} slice={slice} pkg={pkg} lane="slices" index={sliceIndex} nodeId={sliceNodeId(slice)} />
            ))}
            {row.activePackages.length > 0 ? <LaneGroupLabel label="Unlinked packages" /> : null}
            {row.activePackages.map((pkg, packageIndex) => (
              <PackageCard key={pkg.id} pkg={pkg} lane="slices" index={row.active.length + packageIndex} />
            ))}
          </FeatureLaneRow>
        ))}
      </BoardLaneColumn>
      <BoardLaneColumn title="Implementing" count={implementingCount} emptyLabel="No implementation running" bodyStyle={rowStyle} aligned>
        {rows.map((row, index) => (
          <FeatureLaneRow key={workstreamRowKey(row, index)} row={row} lane="implementing" index={index}>
            {row.implementing.map(({ slice, pkg }, sliceIndex) => (
              <SliceCard key={slice.id} slice={slice} pkg={pkg} lane="implementing" index={sliceIndex} nodeId={sliceNodeId(slice)} />
            ))}
            {row.implementingPackages.length > 0 ? <LaneGroupLabel label="Unlinked packages" /> : null}
            {row.implementingPackages.map((pkg, packageIndex) => (
              <PackageCard key={pkg.id} pkg={pkg} lane="implementing" index={row.implementing.length + packageIndex} />
            ))}
          </FeatureLaneRow>
        ))}
      </BoardLaneColumn>
      <BoardLaneColumn title="Finished" count={finishedCount} emptyLabel="Nothing finished yet" bodyStyle={rowStyle} aligned>
        {rows.map((row, index) => (
          <FeatureLaneRow key={workstreamRowKey(row, index)} row={row} lane="finished" index={index}>
            {row.finished.map(({ slice, pkg }, sliceIndex) => (
              <SliceCard key={slice.id} slice={slice} pkg={pkg} lane="finished" index={sliceIndex} nodeId={sliceNodeId(slice)} />
            ))}
            {row.finishedPackages.length > 0 ? <LaneGroupLabel label="Unlinked packages" /> : null}
            {row.finishedPackages.map((pkg, packageIndex) => (
              <PackageCard key={pkg.id} pkg={pkg} lane="finished" index={row.finished.length + packageIndex} />
            ))}
          </FeatureLaneRow>
        ))}
      </BoardLaneColumn>
    </>
  );
}

function BoardLaneColumn({
  title,
  count,
  emptyLabel,
  children,
  className,
  bodyStyle,
  aligned = false,
}: {
  title: string;
  count: number;
  emptyLabel: string;
  children: React.ReactNode;
  className?: string;
  bodyStyle?: React.CSSProperties;
  aligned?: boolean;
}) {
  const hasChildren = Children.count(children) > 0;

  return (
    <section className={cn("jira-lane", className)}>
      <div className="jira-lane-header">
        <span>{title}</span>
        <span className="jira-lane-count">{count}</span>
      </div>
      <div className={cn("jira-lane-body", aligned && "jira-lane-body-aligned")} style={bodyStyle}>
        {count > 0 || (aligned && hasChildren) ? children : <div className="jira-lane-empty">{emptyLabel}</div>}
      </div>
    </section>
  );
}

function FeatureLaneRow({
  row,
  lane,
  index,
  children,
}: {
  row: WorkstreamRow;
  lane: "requested" | "slices" | "implementing" | "finished";
  index: number;
  children: React.ReactNode;
}) {
  const empty = Children.count(children) === 0;

  return (
    <div className="feature-lane-row" data-feature-row={workstreamRowKey(row, index)} data-lane={lane}>
      {children}
      {empty ? <div className="feature-lane-empty" /> : null}
    </div>
  );
}

function LaneGroupLabel({ label }: { label: string }) {
  return (
    <div className="flex items-center gap-2 px-1 pt-1 text-xs font-medium text-muted-foreground">
      <Route className="h-3.5 w-3.5" />
      {label}
    </div>
  );
}

function BoardWireLayer({ paths, width, height }: { paths: BoardWirePath[]; width: number; height: number }) {
  const layerId = useId().replace(/:/g, "");
  if (paths.length === 0 || width <= 0 || height <= 0) return null;
  const maskedPaths = paths
    .map((wire, index) => ({ wire, maskId: `${layerId}-board-wire-mask-${index}` }))
    .filter(({ wire }) => wire.hiddenRects.length > 0);

  return (
    <>
      <svg className="board-wire-layer" width={width} height={height} viewBox={`0 0 ${width} ${height}`} aria-hidden="true">
        {maskedPaths.length > 0 ? (
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
        ) : null}
        {paths.map((wire, index) => {
          const maskId = wire.hiddenRects.length > 0 ? `${layerId}-board-wire-mask-${index}` : undefined;

          return (
            <g key={wire.id} data-wire-tone={wire.tone} data-wire-from={wire.from} data-wire-to={wire.to} data-mask-rects={wire.hiddenRects.length}>
              <path className="board-wire-path" d={wire.path} mask={maskId ? `url(#${maskId})` : undefined} />
            </g>
          );
        })}
      </svg>
      <svg className="board-wire-node-layer" width={width} height={height} viewBox={`0 0 ${width} ${height}`} aria-hidden="true">
        {paths.map((wire) => (
          <g key={wire.id} data-wire-tone={wire.tone} data-wire-from={wire.from} data-wire-to={wire.to}>
            <circle className="board-wire-node board-wire-node-target" cx={wire.targetX} cy={wire.targetY} r="4" />
          </g>
        ))}
      </svg>
    </>
  );
}

function useBoardWirePaths(boardRef: React.RefObject<HTMLDivElement>, wires: BoardWire[], measureKey: string) {
  const [paths, setPaths] = useState<BoardWirePath[]>([]);
  const [size, setSize] = useState({ width: 0, height: 0 });

  useLayoutEffect(() => {
    const board = boardRef.current;
    if (!board) return;

    let frame: number | null = null;
    const timers: number[] = [];
    const schedule = () => {
      if (frame !== null) return;
      frame = window.requestAnimationFrame(() => {
        frame = null;
        const measured = measureBoardWires(board, wires);
        setPaths(measured.paths);
        setSize(measured.size);
      });
    };

    schedule();
    timers.push(window.setTimeout(schedule, 180), window.setTimeout(schedule, 420));

    const observer = new ResizeObserver(schedule);
    observer.observe(board);
    board.querySelectorAll<HTMLElement>("[data-wire-id]").forEach((node) => observer.observe(node));
    window.addEventListener("resize", schedule);

    return () => {
      if (frame !== null) {
        window.cancelAnimationFrame(frame);
      }
      timers.forEach((timer) => window.clearTimeout(timer));
      observer.disconnect();
      window.removeEventListener("resize", schedule);
    };
  }, [boardRef, measureKey, wires]);

  return { paths, size };
}

function useAlignedRowTemplate(boardRef: React.RefObject<HTMLDivElement>, rows: WorkstreamRow[], layoutMode: WorkstreamLayoutMode) {
  const baseHeights = useMemo(() => rows.map((row) => row.height), [rows]);
  const rowKeys = useMemo(() => rows.map((row, index) => workstreamRowKey(row, index)), [rows]);
  const baseKey = baseHeights.join(",");
  const rowKey = rowKeys.join("|");
  const measurementKey = `${baseKey}|${rowKey}`;
  const [measuredRows, setMeasuredRows] = useState<{ key: string; heights: number[] }>({ key: "", heights: [] });

  useLayoutEffect(() => {
    const board = boardRef.current;
    if (!board || layoutMode !== "aligned") return;

    let frame: number | null = null;
    const timers: number[] = [];
    const rowIndex = new Map(rowKeys.map((key, index) => [key, index]));

    const measure = () => {
      frame = null;
      const next = [...baseHeights];

      board.querySelectorAll<HTMLElement>(".feature-lane-row[data-feature-row]").forEach((rowNode) => {
        const index = rowIndex.get(rowNode.dataset.featureRow || "");
        if (index === undefined) return;
        next[index] = Math.max(next[index], featureRowContentHeight(rowNode));
      });

      setMeasuredRows((previous) => (previous.key === measurementKey && sameNumbers(previous.heights, next) ? previous : { key: measurementKey, heights: next }));
    };

    const schedule = () => {
      if (frame !== null) return;
      frame = window.requestAnimationFrame(measure);
    };

    schedule();
    timers.push(window.setTimeout(schedule, 160), window.setTimeout(schedule, 420));

    const observer = new ResizeObserver(schedule);
    observer.observe(board);
    board.querySelectorAll<HTMLElement>(".feature-lane-row[data-feature-row], .feature-lane-row[data-feature-row] .stagger-item").forEach((node) => {
      observer.observe(node);
    });
    window.addEventListener("resize", schedule);

    return () => {
      if (frame !== null) {
        window.cancelAnimationFrame(frame);
      }
      timers.forEach((timer) => window.clearTimeout(timer));
      observer.disconnect();
      window.removeEventListener("resize", schedule);
    };
  }, [baseHeights, boardRef, layoutMode, measurementKey, rowKeys]);

  const heights = layoutMode === "aligned" && measuredRows.key === measurementKey ? measuredRows.heights : baseHeights;
  return heights.map((height) => `${height}px`).join(" ");
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

  return {
    size: { width, height },
    paths: wires.flatMap<BoardWirePath>((wire) => {
      const source = nodes.get(wire.from);
      const target = nodes.get(wire.to);
      if (!source || !target) return [];

      const sourceRect = layoutRectWithinBoard(source, board);
      const targetRect = layoutRectWithinBoard(target, board);
      const sourceX = sourceRect.x + sourceRect.width;
      const sourceY = sourceRect.y + sourceRect.height / 2;
      const targetX = targetRect.x;
      const targetY = targetRect.y + targetRect.height / 2;

      return [
        {
          ...wire,
          path: boardWirePath(sourceX, sourceY, targetX, targetY),
          sourceX,
          sourceY,
          targetX,
          targetY,
          hiddenRects: skippedLaneRects(source, target, lanes),
        },
      ];
    }),
  };
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
  source: HTMLElement,
  target: HTMLElement,
  lanes: Array<{ node: HTMLElement; rect: BoardWireHiddenRect }>,
): BoardWireHiddenRect[] {
  const sourceLane = lanes.findIndex((lane) => lane.node.contains(source));
  const targetLane = lanes.findIndex((lane) => lane.node.contains(target));
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

function boardWirePath(sourceX: number, sourceY: number, targetX: number, targetY: number) {
  const deltaX = targetX - sourceX;
  if (deltaX <= 24 || Math.abs(targetY - sourceY) < 2) {
    return `M ${sourceX} ${sourceY} H ${targetX}`;
  }

  const bendX = sourceX + Math.max(28, Math.min(96, deltaX * 0.46));
  const turn = targetY >= sourceY ? 1 : -1;
  const radius = Math.min(14, Math.abs(targetY - sourceY) / 2, Math.abs(bendX - sourceX) / 2, Math.abs(targetX - bendX) / 2);

  return [
    `M ${sourceX} ${sourceY}`,
    `H ${bendX - radius}`,
    `Q ${bendX} ${sourceY} ${bendX} ${sourceY + turn * radius}`,
    `V ${targetY - turn * radius}`,
    `Q ${bendX} ${targetY} ${bendX + radius} ${targetY}`,
    `H ${targetX}`,
  ].join(" ");
}

function RequestCard({
  detail,
  onSelectGuidance,
  index = 0,
  nodeId,
}: {
  detail: WorkRequestDetail;
  onSelectGuidance: (item: GuidanceItem) => void;
  index?: number;
  nodeId?: string;
}) {
  const request = detail.work_request;
  const openQuestions = detail.clarification_questions?.filter((question) => question.status === "open") ?? [];
  const questionCount = openQuestions.length || request.open_question_count || 0;
  const question = openQuestions[0];
  const answerQuestion = question ? () => onSelectGuidance(clarificationGuidanceItem(detail, question)) : undefined;
  const tone = requestCardTone(detail, questionCount);

  return (
    <div
      className={stateCardClassName(tone, "stagger-item p-3")}
      data-wire-id={nodeId}
      style={{ animationDelay: `${index * 30}ms` }}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{request.title || request.id}</p>
          <p className="mt-1 text-xs text-muted-foreground">{request.work_type || "feature"}</p>
        </div>
        <Badge variant={requestStatusVariant(request.status)} className="shrink-0">
          {formatStatus(request.status)}
        </Badge>
      </div>
      <CardSignal
        className="mt-3"
        label="Open Qs"
        value={String(questionCount)}
        tone={questionCount > 0 ? "danger" : "muted"}
        onClick={answerQuestion}
        ariaLabel={question ? `Answer open question for ${request.title || request.id}` : undefined}
      />
      {question ? <p className="mt-2 line-clamp-2 text-xs text-muted-foreground">{question.question}</p> : null}
    </div>
  );
}

function SliceCard({
  slice,
  pkg,
  lane,
  index = 0,
  nodeId,
}: {
  slice: PlannedSlice;
  pkg?: WorkPackageCard;
  lane: BoardLane;
  index?: number;
  nodeId?: string;
}) {
  const signal = sliceSignal(slice, pkg, lane);
  const tone = sliceCardTone(slice, pkg, lane);

  return (
    <div
      className={stateCardClassName(tone, "stagger-item p-3")}
      data-wire-id={nodeId}
      style={{ animationDelay: `${index * 30}ms` }}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <p className="min-w-0 truncate text-sm font-medium">{slice.title || pkg?.title || slice.id}</p>
        <Badge variant={statusVariant(slice.work_package_status || slice.status)} className="shrink-0">
          {formatStatus(slice.work_package_status || slice.status)}
        </Badge>
      </div>
      <p className="mt-2 line-clamp-2 text-xs text-muted-foreground">{slice.goal || pkg?.kind || slice.work_package_kind}</p>
      <CardSignal className="mt-3" label={signal.label} value={signal.value} tone={signal.tone} />
    </div>
  );
}

function PackageCard({ pkg, lane, index = 0 }: { pkg: WorkPackageCard; lane: BoardLane; index?: number }) {
  const signal = packageSignal(pkg, lane);
  const tone = packageCardTone(pkg, lane);

  return (
    <div className={stateCardClassName(tone, "stagger-item p-3")} style={{ animationDelay: `${index * 30}ms` }}>
      <div className="flex min-w-0 items-start justify-between gap-2">
        <p className="min-w-0 truncate text-sm font-medium">{pkg.title || pkg.id}</p>
        <Badge variant={statusVariant(pkg.status)} className="shrink-0">
          {formatStatus(pkg.status)}
        </Badge>
      </div>
      <CardSignal className="mt-3" label={signal.label} value={signal.value} tone={signal.tone} />
    </div>
  );
}

function CardSignal({
  label,
  value,
  tone,
  className,
  onClick,
  ariaLabel,
}: {
  label: string;
  value: string;
  tone: SignalTone;
  className?: string;
  onClick?: () => void;
  ariaLabel?: string;
}) {
  const toneClasses: Record<SignalTone, string> = {
    muted: "border-transparent bg-muted text-foreground",
    info: "border-sky-200 bg-sky-50 text-sky-800",
    warning: "border-amber-200 bg-amber-50 text-amber-900",
    danger: "border-rose-200 bg-rose-50 text-rose-800",
    success: "border-emerald-200 bg-emerald-50 text-emerald-800",
  };
  const signalClassName = cn(
    "min-w-0 max-w-full w-full rounded-md border px-2.5 py-2 text-xs",
    toneClasses[tone],
    onClick &&
      "cursor-pointer text-left transition-[border-color,box-shadow,transform] duration-150 ease-out hover:-translate-y-0.5 hover:shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60 focus-visible:ring-offset-2 active:translate-y-0",
    className,
  );
  const content = (
    <>
      <p className="text-[11px] leading-none opacity-70">{label}</p>
      <p className="mt-1 truncate font-semibold">{value}</p>
    </>
  );

  if (onClick) {
    return (
      <button type="button" className={signalClassName} onClick={onClick} aria-label={ariaLabel}>
        {content}
      </button>
    );
  }

  return (
    <div className={signalClassName}>
      {content}
    </div>
  );
}

function requestCardTone(detail: WorkRequestDetail, questionCount?: number): StateCardTone {
  const request = detail.work_request;
  const status = request.status || "";
  const openQuestions = questionCount ?? request.open_question_count ?? 0;

  if (openQuestions > 0 || status === "human_info_needed") return "guidance";
  if (status === "ready_for_slicing") return "queued";
  if (status === "sliced") return "slice";
  if (status === "draft" || status === "clarifying" || status === "ready_for_clarification") return "request";
  return "request";
}

function sliceCardTone(slice: PlannedSlice, pkg: WorkPackageCard | undefined, lane: BoardLane): StateCardTone {
  if (pkg) return packageCardTone(pkg, lane);
  if (lane === "finished") return "finished";

  switch (slice.status) {
    case "approved":
      return "queued";
    case "planned":
      return "slice";
    case "skipped":
      return "muted";
    default:
      return "slice";
  }
}

function packageCardTone(pkg: WorkPackageCard, lane?: BoardLane): StateCardTone {
  const status = pkg.status || "";

  if ((pkg.active_blocker_count || 0) > 0 || status === "blocked") return "blocked";
  if ((lane === "finished" && packageLane(pkg) === "finished") || ["merged_into_phase", "merged", "closed"].includes(status)) return "finished";
  if (status === "abandoned") return "muted";
  if (status === "reviewing" || status === "ci_waiting") return "review";
  if (["ready_for_human_merge", "ready_for_architect_merge", "merging_into_phase"].includes(status)) return "merge";
  if (status === "implementing") return "implementing";
  if (["created", "ready_for_worker", "claimed", "planning"].includes(status)) return "queued";
  return lane === "implementing" ? "implementing" : "slice";
}

function sliceSignal(slice: PlannedSlice, pkg: WorkPackageCard | undefined, lane: BoardLane) {
  if (pkg) {
    return packageSignal(pkg, lane);
  }

  if (lane === "finished") {
    return { label: "Finished", value: formatStatus(slice.status), tone: "success" as const };
  }

  if (slice.status === "approved") {
    return { label: "Slice", value: "Approved to dispatch", tone: "info" as const };
  }

  if (slice.status === "planned") {
    return { label: "Slice", value: "Planned", tone: "muted" as const };
  }

  if (slice.status === "skipped") {
    return { label: "Slice", value: "Skipped", tone: "muted" as const };
  }

  return { label: lane === "implementing" ? "Worker" : "Slice", value: formatStatus(slice.work_package_status || slice.status), tone: "info" as const };
}

function packageSignal(pkg: WorkPackageCard, lane: BoardLane): { label: string; value: string; tone: SignalTone } {
  const status = pkg.status || "";
  const blockerCount = pkg.active_blocker_count || 0;

  if (lane === "finished" || packageLane(pkg) === "finished") {
    return { label: "Finished", value: terminalPackageLabel(pkg), tone: "success" };
  }

  if (blockerCount > 0 || status === "blocked") {
    return { label: "Blockers", value: `${blockerCount || 1} ${plural("blocker", blockerCount || 1)}`, tone: "danger" };
  }

  if (status === "reviewing") {
    return packageReviewSignal(pkg) || { label: "Review", value: "In review", tone: "info" };
  }

  if (status === "ci_waiting") {
    return { label: "CI", value: "Waiting", tone: "info" };
  }

  if (status === "ready_for_human_merge") {
    return { label: "Merge", value: packagePrLabel(pkg) || "Ready for human", tone: "warning" };
  }

  if (status === "ready_for_architect_merge") {
    return { label: "Merge", value: packagePrLabel(pkg) || "Ready for architect", tone: "warning" };
  }

  if (status === "merging_into_phase") {
    return { label: "Merge", value: "Merging", tone: "info" };
  }

  if (status === "implementing") {
    return packageRuntimeSignal(pkg) || { label: "Implementation", value: planProgressLabel(pkg) || "Active", tone: "info" };
  }

  if (status === "created" || status === "ready_for_worker") {
    return { label: "Worker", value: "Queued for worker", tone: "muted" };
  }

  if (status === "claimed") {
    return { label: "Worker", value: "Claimed", tone: "info" };
  }

  if (status === "planning") {
    return { label: "Architect", value: "Planning", tone: "info" };
  }

  return { label: lane === "slices" ? "Slice" : "State", value: planProgressLabel(pkg) || formatStatus(status), tone: "muted" };
}

function packageRuntimeSignal(pkg: WorkPackageCard) {
  const run = pkg.active_agent_run;
  const runtime = pkg.runtime || {};

  if (run?.stale === true || runtimeBoolean(runtime, "stale_count")) {
    return { label: "Worker", value: "Stale run", tone: "warning" as const };
  }

  if (run?.runtime_state === "queued" || runtimeBoolean(runtime, "queued_count")) {
    return { label: "Worker", value: "Queued", tone: "muted" as const };
  }

  if (run || runtimeBoolean(runtime, "active_count")) {
    return { label: "Worker", value: "Active run", tone: "info" as const };
  }

  return null;
}

function runtimeBoolean(runtime: Record<string, unknown>, key: string) {
  const value = runtime[key];
  return typeof value === "number" && value > 0;
}

function packageReviewSignal(pkg: WorkPackageCard) {
  return reviewPayloadSignal(pkg.metadata?.review_suite_result) || reviewPackageSignal(pkg.metadata?.review_package);
}

function reviewPackageSignal(reviewPackage: WorkPackageCard["metadata"] extends infer _Metadata ? NonNullable<WorkPackageCard["metadata"]>["review_package"] : never) {
  if (!reviewPackage) return null;

  const reviews = Array.isArray(reviewPackage.reviews) ? reviewPackage.reviews : [];
  const signals = reviews.map(reviewPayloadSignal).filter((signal): signal is NonNullable<ReturnType<typeof reviewPayloadSignal>> => Boolean(signal));

  if (signals.length > 0) {
    return signals[signals.length - 1];
  }

  return reviewPayloadSignal(reviewPackage);
}

function reviewPayloadSignal(payload?: NonNullable<WorkPackageCard["metadata"]>["review_suite_result"] | null) {
  if (!payload) return null;

  const lane = payload.lane || payload.review_lane || payload.suite;
  if (!lane) return null;

  const state = reviewState(payload.verdict || payload.status);
  const tone: SignalTone = state === "green" ? "success" : state === "failed" ? "danger" : "info";
  const suffix = state === "green" ? "Green" : state === "failed" ? "Failed" : "Pending";

  return { label: "Review", value: `${reviewLaneLabel(lane)} ${suffix}`, tone, rank: reviewLaneRank(lane) };
}

function reviewState(value?: string) {
  const normalized = value?.trim().toLowerCase();
  if (["green", "clean", "passed", "pass"].includes(normalized || "")) return "green";
  if (["red", "failed", "fail", "findings"].includes(normalized || "")) return "failed";
  return "pending";
}

function reviewLaneLabel(lane: string) {
  switch (lane.trim().toLowerCase()) {
    case "review_deslop":
      return "Review-Deslop";
    case "review_t1":
      return "Review-T1";
    case "review_t2":
      return "Review-T2";
    case "review_t3":
      return "Review-T3";
    case "review_t4":
      return "Review-T4";
    case "review_github":
      return "Review-GitHub";
    default:
      return "Review";
  }
}

function reviewLaneRank(lane: string) {
  return ["review_deslop", "review_t1", "review_t2", "review_t3", "review_t4", "review_github"].indexOf(lane.trim().toLowerCase());
}

function packagePrLabel(pkg: WorkPackageCard) {
  const pr = pkg.metadata?.pr;
  if (!pr) return null;

  if (pr.number) {
    return `PR #${pr.number}`;
  }

  return pr.url ? "PR attached" : null;
}

function planProgressLabel(pkg: WorkPackageCard) {
  const total = pkg.plan?.total_count || 0;
  if (total <= 0) return null;

  const done = pkg.plan?.completed_count || 0;
  const open = pkg.plan?.open_count || 0;

  return open > 0 ? `${open} open / ${total} total` : `${done}/${total} done`;
}

function terminalPackageLabel(pkg: WorkPackageCard) {
  if (pkg.status === "merged" || pkg.status === "merged_into_phase") return "Merged";
  if (pkg.status === "closed") return "Closed";
  return "Finished";
}

function plural(word: string, count: number) {
  return count === 1 ? word : `${word}s`;
}

function SoloSessions({ sessions }: { sessions: SoloSession[] }) {
  if (sessions.length === 0) {
    return <EmptyPanel title="No solo sessions" />;
  }

  return (
    <div className="grid gap-5">
      {soloSessionGroups(sessions).map((group) => (
        <SoloSessionGroup key={`${group.repo}:${group.baseBranch}`} group={group} />
      ))}
    </div>
  );
}

function SoloSessionGroup({
  group,
}: {
  group: {
    repo: string;
    baseBranch: string;
    active: SoloSession[];
    finished: SoloSession[];
    guidanceCount: number;
    blockerCount: number;
  };
}) {
  return (
    <Card className="motion-card overflow-hidden">
      <CardHeader className="border-b bg-card">
        <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
          <div className="min-w-0">
            <CardTitle className="flex items-center gap-2">
              <GitBranch className="h-4 w-4 text-primary" />
              <span className="truncate">{group.repo}</span>
            </CardTitle>
            <p className="mt-1 truncate text-sm text-muted-foreground">{group.baseBranch}</p>
          </div>
          <div className="flex min-w-0 flex-wrap items-center gap-1.5 md:justify-end">
            <RepoSummaryPlate label="Active" value={group.active.length} tone="active" />
            <RepoSummaryPlate label="Finished" value={group.finished.length} tone="finished" />
            {group.guidanceCount > 0 ? <RepoSummaryPlate label="Guidance Needed" value={group.guidanceCount} tone="guidance" /> : null}
            {group.blockerCount > 0 ? <RepoSummaryPlate label="Active Blockers" value={group.blockerCount} tone="blocker" /> : null}
          </div>
        </div>
      </CardHeader>
      <CardContent className="p-3 sm:p-4">
        <div className="overflow-x-auto pb-1">
          <div className="jira-board jira-board-solo min-w-[640px]">
            <SoloSessionLane title="Active" sessions={group.active} emptyLabel="No active solo sessions" />
            <SoloSessionLane title="Finished" sessions={group.finished} emptyLabel="No finished solo sessions" />
          </div>
        </div>
      </CardContent>
    </Card>
  );
}

function SoloSessionLane({ title, sessions, emptyLabel }: { title: string; sessions: SoloSession[]; emptyLabel: string }) {
  return (
    <BoardLaneColumn title={title} count={sessions.length} emptyLabel={emptyLabel}>
      {sessions.map((session, index) => <SoloSessionCard key={session.id} session={session} index={index} />)}
    </BoardLaneColumn>
  );
}

function SoloSessionCard({ session, index }: { session: SoloSession; index: number }) {
  const attention = soloSessionAttention(session);
  const latest = session.latest_entry;
  const latestText = latest?.title || latest?.body || "No recent entry";
  const latestSignalValue = latest?.status ? formatStatus(latest.status) : latestText;
  const latestKind = latest?.kind_label || formatStatus(latest?.kind);
  const entryCounts = session.entry_counts || [];
  const tone = soloSessionCardTone(session);

  return (
    <div className={stateCardClassName(tone, "stagger-item p-3")} style={{ animationDelay: `${index * 35}ms` }}>
      <div className="flex min-w-0 items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{session.title || session.id}</p>
          <p className="mt-1 truncate text-xs text-muted-foreground">{session.id}</p>
        </div>
        <Badge variant={soloSessionStatusVariant(session.status)} className="shrink-0">
          {formatStatus(session.status)}
        </Badge>
      </div>

      <div className="mt-3 grid min-w-0 gap-2 sm:grid-cols-2">
        <CardSignal label="State" value={soloSessionStateLabel(session)} tone={soloSessionSignalTone(session.status)} />
        <CardSignal label={soloSessionLatestSignalLabel(session)} value={latestSignalValue} tone={soloSessionLatestSignalTone(session)} />
      </div>

      {attention.guidanceCount > 0 || attention.blockerCount > 0 ? (
        <div className="mt-3 flex flex-wrap gap-1.5">
          {attention.guidanceCount > 0 ? <RepoSummaryPlate label="Guidance Needed" value={attention.guidanceCount} tone="guidance" /> : null}
          {attention.blockerCount > 0 ? <RepoSummaryPlate label="Active Blockers" value={attention.blockerCount} tone="blocker" /> : null}
        </div>
      ) : null}

      {latest ? (
        <>
          <Separator className="my-3" />
          <div className="flex min-w-0 items-start gap-2">
            <Badge variant="secondary" className="shrink-0">
              {latestKind}
            </Badge>
            <p className="line-clamp-2 min-w-0 text-sm text-muted-foreground">{latestText}</p>
          </div>
        </>
      ) : null}

      {entryCounts.length > 0 ? (
        <div className="mt-3 flex flex-wrap gap-1.5">
          {entryCounts.slice(0, 5).map((entryCount) => (
            <span key={entryCount.kind || entryCount.label} className="rounded-md bg-muted px-2 py-1 text-xs text-muted-foreground">
              {entryCount.label || formatStatus(entryCount.kind)} <span className="font-semibold text-foreground">{entryCount.count || 0}</span>
            </span>
          ))}
        </div>
      ) : null}
    </div>
  );
}

function soloSessionGroups(sessions: SoloSession[]) {
  const groups = new Map<
    string,
    {
      repo: string;
      baseBranch: string;
      active: SoloSession[];
      finished: SoloSession[];
      guidanceCount: number;
      blockerCount: number;
    }
  >();

  sessions.forEach((session) => {
    const repo = repoName(session.repo);
    const baseBranch = session.base_branch?.trim() || "main";
    const key = `${repo}:${baseBranch}`;
    const group =
      groups.get(key) ||
      ({
        repo,
        baseBranch,
        active: [],
        finished: [],
        guidanceCount: 0,
        blockerCount: 0,
      } satisfies {
        repo: string;
        baseBranch: string;
        active: SoloSession[];
        finished: SoloSession[];
        guidanceCount: number;
        blockerCount: number;
      });

    const attention = soloSessionAttention(session);
    group.guidanceCount += attention.guidanceCount;
    group.blockerCount += attention.blockerCount;

    if (soloSessionLane(session) === "finished") {
      group.finished.push(session);
    } else {
      group.active.push(session);
    }

    groups.set(key, group);
  });

  return [...groups.values()].map((group) => ({
    ...group,
    active: sortSoloSessions(group.active),
    finished: sortSoloSessions(group.finished),
  }));
}

function sortSoloSessions(sessions: SoloSession[]) {
  return [...sessions].sort((left, right) => soloSessionTime(right) - soloSessionTime(left));
}

function soloSessionTime(session: SoloSession) {
  const value = session.last_activity_at || session.updated_at || session.inserted_at;
  const timestamp = value ? Date.parse(value) : 0;
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

function soloSessionLane(session: SoloSession): "active" | "finished" {
  return ["completed", "archived", "finished", "closed"].includes(session.status || "") ? "finished" : "active";
}

function soloSessionAttention(session: SoloSession) {
  const entryCounts = session.entry_counts || [];
  const text = [session.status, session.latest_entry?.kind, session.latest_entry?.kind_label, session.latest_entry?.status, session.latest_entry?.title, session.latest_entry?.body]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  return {
    guidanceCount:
      entryCounts.reduce((count, entry) => count + (soloEntryMentions(entry, ["guidance", "human_info", "human info", "question"]) ? entry.count || 0 : 0), 0) ||
      (/(guidance|human info|human_info|question)/.test(text) ? 1 : 0),
    blockerCount:
      entryCounts.reduce((count, entry) => count + (soloEntryMentions(entry, ["blocker", "blocked"]) ? entry.count || 0 : 0), 0) ||
      (/(blocker|blocked)/.test(text) ? 1 : 0),
  };
}

function soloEntryMentions(entry: NonNullable<SoloSession["entry_counts"]>[number], needles: string[]) {
  const text = [entry.kind, entry.label].filter(Boolean).join(" ").toLowerCase();
  return needles.some((needle) => text.includes(needle));
}

function soloSessionStatusVariant(status?: string | null): BadgeTone {
  if (["completed", "archived", "finished", "closed"].includes(status || "")) return "success";
  if (["blocked", "human_info_needed"].includes(status || "")) return "danger";
  if (status === "paused") return "warning";
  return "info";
}

function soloSessionCardTone(session: SoloSession): StateCardTone {
  const attention = soloSessionAttention(session);
  const status = session.status || "";
  const latestText = [session.latest_entry?.kind, session.latest_entry?.kind_label, session.latest_entry?.status, session.latest_entry?.title, session.latest_entry?.body]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  if (attention.blockerCount > 0 || status === "blocked") return "blocked";
  if (attention.guidanceCount > 0 || status === "human_info_needed") return "guidance";
  if (["completed", "archived", "finished", "closed"].includes(status)) return "finished";
  if (latestText.includes("review")) return "review";
  if (latestText.includes("validation")) return latestText.includes("completed") ? "finished" : "implementing";
  if (status === "paused") return "merge";
  return "implementing";
}

function soloSessionSignalTone(status?: string | null): SignalTone {
  if (["completed", "archived", "finished", "closed"].includes(status || "")) return "success";
  if (["blocked", "human_info_needed"].includes(status || "")) return "danger";
  if (status === "paused") return "warning";
  return "info";
}

function soloSessionStateLabel(session: SoloSession) {
  const lastActivity = session.last_activity_at ? formatDate(session.last_activity_at) : null;
  return lastActivity ? `${formatStatus(session.status)} / ${lastActivity}` : formatStatus(session.status);
}

function soloSessionLatestSignalLabel(session: SoloSession) {
  const latest = session.latest_entry;
  if (!latest) return "Latest";

  const latestText = [latest.kind, latest.kind_label, latest.status].filter(Boolean).join(" ").toLowerCase();
  if (latestText.includes("review")) return "Review";
  if (latestText.includes("validation")) return "Validation";
  if (latestText.includes("blocker") || latestText.includes("blocked")) return "Blocker";
  if (latestText.includes("guidance") || latestText.includes("human info")) return "Guidance";
  return latest.kind_label || "Latest";
}

function soloSessionLatestSignalTone(session: SoloSession): SignalTone {
  const latest = session.latest_entry;
  const text = [latest?.kind, latest?.kind_label, latest?.status, latest?.title, latest?.body].filter(Boolean).join(" ").toLowerCase();

  if (text.includes("blocker") || text.includes("blocked") || text.includes("failed")) return "danger";
  if (text.includes("guidance") || text.includes("human info") || text.includes("question")) return "warning";
  if (text.includes("review") || text.includes("validation")) return text.includes("completed") || text.includes("green") ? "success" : "info";
  return "muted";
}

function GuidanceDialog({
  item,
  onOpenChange,
  onAnswered,
}: {
  item: GuidanceItem | null;
  onOpenChange: (open: boolean) => void;
  onAnswered: (dashboard: DashboardPayload) => void;
}) {
  const [selectedChoice, setSelectedChoice] = useState<string>("");
  const [notes, setNotes] = useState<Record<string, string>>({});
  const [openNotes, setOpenNotes] = useState<Record<string, boolean>>({});
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const options = useMemo(() => guidanceOptions(item?.prompt), [item?.prompt]);

  useEffect(() => {
    if (item) {
      setSelectedChoice(options[0]?.id || CUSTOM_CHOICE);
      setNotes({});
      setOpenNotes({});
      setError(null);
    }
  }, [item, options]);

  function selectChoice(optionId: string) {
    setSelectedChoice(optionId);
  }

  function toggleNote(optionId: string) {
    selectChoice(optionId);
    setOpenNotes((current) => ({ ...current, [optionId]: !current[optionId] }));
  }

  function focusNote(optionId: string) {
    selectChoice(optionId);
    if (optionId !== CUSTOM_CHOICE) {
      setOpenNotes((current) => ({ ...current, [optionId]: true }));
    }
  }

  function updateNote(optionId: string, value: string) {
    focusNote(optionId);
    setNotes((current) => ({ ...current, [optionId]: value }));
  }

  async function submitAnswer() {
    if (!item || !selectedChoice) return;

    setSubmitting(true);
    setError(null);

    try {
      const answerNote = notes[selectedChoice] || "";
      const body = JSON.stringify({
        answer_choice: selectedChoice,
        answer_note: answerNote,
        answer: selectedChoice === CUSTOM_CHOICE ? answerNote : undefined,
      });

      const response = await fetch(guidanceAnswerUrl(item), {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body,
      });
      const payload = await response.json();

      if (!response.ok) {
        throw new Error(payload?.error?.message || "Answer was not recorded");
      }

      onAnswered(payload.dashboard);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Answer was not recorded");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Dialog open={Boolean(item)} onOpenChange={onOpenChange}>
      <DialogContent className="dashboard-dialog-content">
        {item ? (
          <>
            <DialogHeader data-guidance-section style={{ animationDelay: "35ms" }}>
              <DialogTitle>{item.prompt?.tl_dr || item.title}</DialogTitle>
              <DialogDescription>{item.repo}</DialogDescription>
            </DialogHeader>
            <div className="grid gap-4">
              <section className="rounded-lg border bg-muted/40 p-4" data-guidance-section style={{ animationDelay: "70ms" }}>
                <p className="text-sm font-medium">TL;DR</p>
                <p className="mt-2 text-sm text-muted-foreground">{item.prompt?.tl_dr || item.title}</p>
              </section>
              <section className="rounded-lg border p-4" data-guidance-section style={{ animationDelay: "95ms" }}>
                <p className="text-sm font-medium">Details</p>
                <p className="mt-2 whitespace-pre-wrap text-sm text-muted-foreground">{item.prompt?.details || item.detail}</p>
              </section>
              <div className="grid gap-3" role="radiogroup" aria-label="Guidance options" data-guidance-section style={{ animationDelay: "120ms" }}>
                {options.map((option, index) => {
                  const isCustom = option.id === CUSTOM_CHOICE;
                  const selected = selectedChoice === option.id;
                  const noteOpen = isCustom || Boolean(openNotes[option.id]);

                  return (
                    <div
                      key={option.id}
                      className={cn(
                        "guidance-option rounded-lg border p-4 text-left outline-none transition-colors",
                        selected ? "border-primary bg-primary/5" : "bg-background hover:border-primary/50",
                      )}
                      role="radio"
                      aria-checked={selected}
                      tabIndex={0}
                      onClick={() => selectChoice(option.id)}
                      onKeyDown={(event) => {
                        if (event.target !== event.currentTarget) return;
                        if (event.key === "Enter" || event.key === " ") {
                          event.preventDefault();
                          selectChoice(option.id);
                        }
                      }}
                      style={{ animationDelay: `${index * 35}ms` }}
                    >
                      <div className="flex items-start gap-3">
                        <CircleDot className={cn("mt-0.5 h-4 w-4", selected ? "text-primary" : "text-muted-foreground")} />
                        <div className="min-w-0 flex-1">
                          <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                            <div className="min-w-0">
                              <p className="text-sm font-semibold">{option.label}</p>
                              {option.description ? <p className="mt-1 text-sm text-muted-foreground">{option.description}</p> : null}
                            </div>
                            {!isCustom ? (
                              <Button
                                type="button"
                                variant="ghost"
                                size="sm"
                                className="button-lift h-8 shrink-0 justify-start px-2 text-xs"
                                aria-expanded={noteOpen}
                                onClick={(event) => {
                                  event.stopPropagation();
                                  toggleNote(option.id);
                                }}
                              >
                                <ChevronDown className={cn("h-3.5 w-3.5 transition-transform duration-200", noteOpen && "rotate-180")} />
                                Add Extra Note
                              </Button>
                            ) : null}
                          </div>
                          {!isCustom ? <ProsCons option={option} /> : null}
                          <Collapsible open={noteOpen}>
                            <CollapsibleContent className="collapsible-content option-note-content">
                              <div className="px-0.5 pb-0.5 pt-3">
                                <Label className="block text-xs text-muted-foreground">
                                  {isCustom ? "None of the above, do this instead:" : "Extra note"}
                                </Label>
                                <Textarea
                                  className="mt-1 min-h-[72px]"
                                  placeholder={isCustom ? "Tell the architect what to do instead." : "Add optional context for this answer."}
                                  value={notes[option.id] || ""}
                                  onFocus={() => focusNote(option.id)}
                                  onChange={(event) => updateNote(option.id, event.target.value)}
                                  onClick={(event) => {
                                    event.stopPropagation();
                                    focusNote(option.id);
                                  }}
                                />
                              </div>
                            </CollapsibleContent>
                          </Collapsible>
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
              {error ? <p className="text-sm text-destructive">{error}</p> : null}
            </div>
            <DialogFooter>
              <Button variant="outline" onClick={() => onOpenChange(false)}>
                Cancel
              </Button>
              <Button onClick={submitAnswer} disabled={submitting || (selectedChoice === CUSTOM_CHOICE && !notes[selectedChoice]?.trim())}>
                {submitting ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />}
                Answer
              </Button>
            </DialogFooter>
          </>
        ) : null}
      </DialogContent>
    </Dialog>
  );
}

function ProsCons({ option }: { option: DecisionOption }) {
  if (!option.pros?.length && !option.cons?.length) return null;

  return (
    <div className="mt-3 grid gap-2 md:grid-cols-2">
      <div className="rounded-md bg-emerald-50 p-3 text-xs text-emerald-800">
        <p className="font-semibold">Pros</p>
        <ul className="mt-1 space-y-1">
          {(option.pros || ["No specific pros recorded"]).map((pro) => (
            <li key={pro}>{pro}</li>
          ))}
        </ul>
      </div>
      <div className="rounded-md bg-rose-50 p-3 text-xs text-rose-800">
        <p className="font-semibold">Cons</p>
        <ul className="mt-1 space-y-1">
          {(option.cons || ["No specific cons recorded"]).map((con) => (
            <li key={con}>{con}</li>
          ))}
        </ul>
      </div>
    </div>
  );
}

function NewRequestDialog({
  open,
  onOpenChange,
  onCreated,
  defaultRepo,
  repos,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated: (dashboard: DashboardPayload) => void;
  defaultRepo?: string;
  repos: RepoSummary[];
}) {
  const repoChoices = useMemo(() => repoOptions(repos, defaultRepo), [defaultRepo, repos]);
  const initialRepo = defaultRepo || repoChoices[0] || initialRequestForm.repo;
  const [form, setForm] = useState<NewRequestForm>({
    ...initialRequestForm,
    repo: initialRepo,
    base_branch: baseBranchOptionsForRepo(repos, initialRepo)[0] || initialRequestForm.base_branch,
  });
  const branchChoices = useMemo(() => baseBranchOptionsForRepo(repos, form.repo), [form.repo, repos]);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setForm((current) => {
        const repo = repoChoices.includes(current.repo) ? current.repo : repoChoices[0] || initialRequestForm.repo;
        const branches = baseBranchOptionsForRepo(repos, repo);
        const baseBranch = branches.includes(current.base_branch) ? current.base_branch : branches[0] || initialRequestForm.base_branch;

        if (repo === current.repo && baseBranch === current.base_branch) {
          return current;
        }

        return { ...current, repo, base_branch: baseBranch };
      });
      setError(null);
    }
  }, [open, repoChoices, repos]);

  async function submit(event: FormEvent) {
    event.preventDefault();
    setSubmitting(true);
    setError(null);

    try {
      const response = await fetch("/api/v1/sympp/operator/work-requests", {
        method: "POST",
        headers: { "content-type": "application/json", accept: "application/json" },
        body: JSON.stringify({
          title: form.title,
          repo: form.repo,
          base_branch: form.base_branch,
          work_type: form.work_type,
          desired_dispatch_shape: form.desired_dispatch_shape,
          human_description: form.human_description,
        }),
      });
      const payload = await response.json();

      if (!response.ok) {
        throw new Error(payload?.error?.message || "Request was not created");
      }

      setForm({ ...initialRequestForm, repo: form.repo, base_branch: form.base_branch });
      onCreated(payload.dashboard);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Request was not created");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogTrigger asChild>
        <Button size="sm">
          <Plus className="h-4 w-4" />
          New Request
        </Button>
      </DialogTrigger>
      <DialogContent className="dashboard-dialog-content">
        <form onSubmit={submit} className="grid gap-5">
          <DialogHeader>
            <DialogTitle>New Request</DialogTitle>
            <DialogDescription>Architect-owned intake</DialogDescription>
          </DialogHeader>
          <div className="grid gap-4 md:grid-cols-2">
            <Field label="Title">
              <Input value={form.title} onChange={(event) => setFormValue(setForm, "title", event.target.value)} required />
            </Field>
            <Field label="Repository">
              <Select
                value={form.repo}
                onValueChange={(value) => {
                  const branches = baseBranchOptionsForRepo(repos, value);
                  setForm((current) => ({ ...current, repo: value, base_branch: branches[0] || initialRequestForm.base_branch }));
                }}
              >
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {repoChoices.map((value) => (
                    <SelectItem key={value} value={value}>
                      {value}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field label="Base Branch">
              <Select value={form.base_branch} onValueChange={(value) => setFormValue(setForm, "base_branch", value)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {branchChoices.map((value) => (
                    <SelectItem key={value} value={value}>
                      {value}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field label="Work Type">
              <Select value={form.work_type} onValueChange={(value) => setFormValue(setForm, "work_type", value)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {["feature", "bugfix", "hotfix", "refactor", "investigation", "docs", "review"].map((value) => (
                    <SelectItem key={value} value={value}>
                      {formatStatus(value)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
            <Field label="Dispatch Shape">
              <Select value={form.desired_dispatch_shape} onValueChange={(value) => setFormValue(setForm, "desired_dispatch_shape", value)}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {["architect_led_feature_branch", "single_package", "direct_main_fix", "investigation_first", "review_only"].map((value) => (
                    <SelectItem key={value} value={value}>
                      {formatStatus(value)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
          </div>
          <Field label="Description">
            <Textarea value={form.human_description} onChange={(event) => setFormValue(setForm, "human_description", event.target.value)} required />
          </Field>
          {error ? <p className="text-sm text-destructive">{error}</p> : null}
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button type="submit" disabled={submitting}>
              {submitting ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />}
              Create
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="grid gap-2">
      <Label>{label}</Label>
      {children}
    </div>
  );
}

function EmptyPanel({ title, compact = false }: { title: string; compact?: boolean }) {
  return (
    <div className={`flex items-center justify-center rounded-lg border border-dashed bg-muted/30 text-sm text-muted-foreground ${compact ? "min-h-[96px]" : "min-h-[180px]"}`}>
      {title}
    </div>
  );
}

type RepoSummary = {
  repo: string;
  baseBranches: string[];
  requested: number;
  active: number;
  implementing: number;
  finished: number;
  guidanceCount: number;
  blockerCount: number;
  packages: WorkPackageCard[];
  requests: WorkRequestCard[];
};

function allPackages(dashboard: DashboardPayload | null): WorkPackageCard[] {
  const groups = dashboard?.board?.groups || {};
  return Object.values(groups).flat();
}

function allGuidanceItems(dashboard: DashboardPayload | null): GuidanceItem[] {
  const guidance = (dashboard?.guidance_requests?.guidance_requests || []).map<GuidanceItem>((item) => ({
    source: "guidance",
    id: item.id,
    repo: repoName(item.repo),
    title: item.decision_prompt?.tl_dr || item.summary || item.question || item.id,
    packageId: item.work_package_id,
    prompt: item.decision_prompt,
    detail: item.decision_prompt?.details || item.context || item.question || "",
    guidance: item,
  }));

  const details = dashboard?.work_request_details || [];
  const clarifications = details.flatMap<GuidanceItem>((detail) =>
    (detail.clarification_questions || [])
      .filter((question) => question.status === "open")
      .map((question) => clarificationGuidanceItem(detail, question)),
  );

  return [...guidance, ...clarifications];
}

function clarificationGuidanceItem(detail: WorkRequestDetail, question: ClarificationQuestion): GuidanceItem {
  return {
    source: "clarification",
    id: question.id,
    repo: repoName(detail.work_request.repo),
    title: question.decision_prompt?.tl_dr || question.question || question.id,
    workRequestId: detail.work_request.id,
    prompt: question.decision_prompt,
    detail: question.decision_prompt?.details || question.why_needed || question.question || "",
    question,
    request: detail.work_request,
  };
}

function activeBlockerItems(packages: WorkPackageCard[]): BlockerItem[] {
  return packages
    .filter((pkg) => pkg.status === "blocked" || (pkg.active_blocker_count || 0) > 0)
    .map((pkg) => ({
      id: pkg.id,
      title: pkg.title || pkg.id,
      repo: repoName(pkg.repo),
      status: pkg.status,
      blockerCount: Math.max(pkg.active_blocker_count || 0, pkg.status === "blocked" ? 1 : 0),
      detail:
        pkg.status === "blocked"
          ? "This work package is blocked and needs another condition or dependency cleared before it can move."
          : "This work package has active blockers attached to its execution path.",
    }));
}

function recentFinishedHighlights(
  packages: WorkPackageCard[],
  requests: WorkRequestCard[],
  details: WorkRequestDetail[],
): FinishedHighlight[] {
  const packageHighlights = packages
    .filter((pkg) => packageLane(pkg) === "finished")
    .map<FinishedHighlight>((pkg) => ({
      id: pkg.id,
      title: pkg.title || pkg.id,
      repo: repoName(pkg.repo),
      kind: "Package",
      status: pkg.status,
      at: pkg.latest_progress_at,
    }));

  const requestHighlights = requests
    .filter((request) => requestLane(request) === "finished")
    .map<FinishedHighlight>((request) => ({
      id: request.id,
      title: request.title || request.id,
      repo: repoName(request.repo),
      kind: "Request",
      status: request.status,
      at: request.updated_at || request.inserted_at,
    }));

  const sliceHighlights = details.flatMap<FinishedHighlight>((detail) =>
    (detail.planned_slices || [])
      .filter((slice) => sliceLane(slice) === "finished")
      .map((slice) => ({
        id: slice.id,
        title: slice.title || slice.id,
        repo: repoName(detail.work_request.repo),
        kind: "Slice",
        status: slice.work_package_status || slice.status,
        at: detail.work_request.updated_at || detail.work_request.inserted_at,
      })),
  );

  return [...packageHighlights, ...requestHighlights, ...sliceHighlights].sort((a, b) => {
    const left = a.at ? Date.parse(a.at) : 0;
    const right = b.at ? Date.parse(b.at) : 0;
    return right - left;
  });
}

function repoSummaries(
  packages: WorkPackageCard[],
  requests: WorkRequestCard[],
  guidance: GuidanceItem[],
  sessions: SoloSession[],
  details: WorkRequestDetail[],
): RepoSummary[] {
  const repos = new Map<string, RepoSummary>();

  const ensure = (repo: string): RepoSummary => {
    if (!repos.has(repo)) {
      repos.set(repo, {
        repo,
        baseBranches: [],
        requested: 0,
        active: 0,
        implementing: 0,
        finished: 0,
        guidanceCount: 0,
        blockerCount: 0,
        packages: [],
        requests: [],
      });
    }
    return repos.get(repo)!;
  };

  requests.forEach((request) => {
    const summary = ensure(repoName(request.repo));
    summary.requests.push(request);
    addBranch(summary, request.base_branch);
  });

  packages.forEach((pkg) => {
    const summary = ensure(repoName(pkg.repo));
    summary.packages.push(pkg);
    addBranch(summary, pkg.base_branch);
  });

  sessions.forEach((session) => {
    const summary = ensure(repoName(session.repo));
    addBranch(summary, session.base_branch);
  });

  guidance.forEach((item) => {
    ensure(item.repo).guidanceCount += 1;
  });

  repos.forEach((summary) => {
    summary.requested = summary.requests.filter((request) => requestLane(request) === "requested").length;
    summary.active =
      summary.requests.filter((request) => requestLane(request) === "slices").length +
      summary.packages.filter((pkg) => packageLane(pkg) === "slices").length;
    summary.implementing = summary.packages.filter((pkg) => packageLane(pkg) === "implementing").length;
    summary.finished = summary.packages.filter((pkg) => packageLane(pkg) === "finished").length;
    summary.blockerCount = activeBlockerItems(summary.packages).length;
    details
      .filter((detail) => repoName(detail.work_request.repo) === summary.repo)
      .flatMap((detail) => detail.planned_slices || [])
      .forEach((slice) => {
        const lane = sliceLane(slice);
        if (lane === "slices") summary.active += 1;
        if (lane === "implementing") summary.implementing += 1;
        if (lane === "finished") summary.finished += 1;
      });
  });

  return [...repos.values()].sort((a, b) => a.repo.localeCompare(b.repo));
}

function dashboardTotals(packages: WorkPackageCard[], requests: WorkRequestCard[], guidance: GuidanceItem[]) {
  return {
    guidance: guidance.length,
    active: requests.filter((request) => requestLane(request) === "slices").length + packages.filter((pkg) => packageLane(pkg) === "slices").length,
    implementing: packages.filter((pkg) => packageLane(pkg) === "implementing").length,
    finished: packages.filter((pkg) => packageLane(pkg) === "finished").length,
  };
}

function guidanceOptions(prompt?: DecisionPrompt | null): DecisionOption[] {
  const options = prompt?.options?.length
    ? prompt.options
    : [
        {
          id: "continue",
          label: "Continue",
          description: "Proceed with the proposed direction.",
          pros: ["Fastest path forward"],
          cons: ["Can preserve ambiguity"],
          answer: "Continue with the proposed direction.",
        },
        {
          id: "narrow",
          label: "Narrow scope",
          description: "Reduce or clarify the scope before implementation.",
          pros: ["Lower delivery risk"],
          cons: ["Adds clarification time"],
          answer: "Narrow the scope before continuing.",
        },
      ];

  return [
    ...options,
    {
      id: CUSTOM_CHOICE,
      label: "None of the above, do this instead:",
      description: "Give the architect or worker a different direction.",
    },
  ];
}

function guidanceAnswerUrl(item: GuidanceItem) {
  if (item.source === "guidance") {
    return `/api/v1/sympp/operator/work-packages/${encodeURIComponent(item.packageId)}/guidance/${encodeURIComponent(item.id)}/answer`;
  }

  return `/api/v1/sympp/operator/work-requests/${encodeURIComponent(item.workRequestId)}/questions/${encodeURIComponent(item.id)}/answer`;
}

function requestLane(request: WorkRequestCard): "requested" | "slices" | "finished" {
  if (request.status === "sliced" || request.status === "ready_for_slicing") return "slices";
  return "requested";
}

function packageLane(pkg: WorkPackageCard): BoardLane {
  if (["merged_into_phase", "merged", "closed"].includes(pkg.status || "")) return "finished";
  if (
    ["implementing", "reviewing", "ci_waiting", "ready_for_human_merge", "ready_for_architect_merge", "merging_into_phase"].includes(
      pkg.status || "",
    )
  ) {
    return "implementing";
  }
  return "slices";
}

function sliceLane(slice: PlannedSlice): BoardLane {
  const status = slice.work_package_status || slice.status || "";
  if (["merged_into_phase", "merged", "closed"].includes(status)) return "finished";
  if (["implementing", "reviewing", "ci_waiting", "ready_for_human_merge", "ready_for_architect_merge", "merging_into_phase"].includes(status)) {
    return "implementing";
  }
  return "slices";
}

function packageLinkedToRequest(pkg: WorkPackageCard, details: WorkRequestDetail[]) {
  return details.some((detail) => (detail.planned_slices || []).some((slice) => slice.work_package_id === pkg.id));
}

function sortWorkRequestDetails(details: WorkRequestDetail[]) {
  return [...details].sort((left, right) => {
    const leftTime = sortableTime(left.work_request.inserted_at || left.work_request.updated_at);
    const rightTime = sortableTime(right.work_request.inserted_at || right.work_request.updated_at);
    if (leftTime !== rightTime) return leftTime - rightTime;
    return (left.work_request.title || left.work_request.id).localeCompare(right.work_request.title || right.work_request.id);
  });
}

function sortPackages(packages: WorkPackageCard[]) {
  return [...packages].sort((left, right) => {
    const leftTime = sortableTime(left.latest_progress_at || left.updated_at);
    const rightTime = sortableTime(right.latest_progress_at || right.updated_at);
    if (leftTime !== rightTime) return rightTime - leftTime;
    return (left.title || left.id).localeCompare(right.title || right.id);
  });
}

function sortableTime(value?: string | null) {
  const timestamp = value ? Date.parse(value) : 0;
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

function workstreamRows(
  details: WorkRequestDetail[],
  sliceEntries: SliceEntry[],
  activePackages: WorkPackageCard[],
  implementingPackages: WorkPackageCard[],
  finishedPackages: WorkPackageCard[],
): WorkstreamRow[] {
  const rows: WorkstreamRow[] = details.map((detail, index) => {
    const entries = sliceEntries.filter((entry) => entry.requestIndex === index);
    const active = entries.filter((entry) => sliceLane(entry.slice) === "slices");
    const implementing = entries.filter((entry) => sliceLane(entry.slice) === "implementing");
    const finished = entries.filter((entry) => sliceLane(entry.slice) === "finished");

    return {
      detail,
      active,
      implementing,
      finished,
      activePackages: [],
      implementingPackages: [],
      finishedPackages: [],
      height: featureRowHeight([1, active.length, implementing.length, finished.length]),
    };
  });

  if (activePackages.length > 0 || implementingPackages.length > 0 || finishedPackages.length > 0) {
    rows.push({
      active: [],
      implementing: [],
      finished: [],
      activePackages,
      implementingPackages,
      finishedPackages,
      height: featureRowHeight([0, activePackages.length, implementingPackages.length, finishedPackages.length], true),
      unlinked: true,
    });
  }

  return rows;
}

function featureRowHeight(counts: number[], hasGroupLabel = false) {
  const cardCount = Math.max(...counts, 0);
  const labelSpace = hasGroupLabel ? 28 : 0;
  return Math.max(150, labelSpace + cardCount * 136 + Math.max(0, cardCount - 1) * 10 + 18);
}

function workstreamRowKey(row: WorkstreamRow, index: number) {
  if (row.detail) return `request-row:${row.detail.work_request.id}`;
  return row.unlinked ? "unlinked-row" : `row:${index}`;
}

function workstreamWires(details: WorkRequestDetail[], packages: WorkPackageCard[]): BoardWire[] {
  const packageMap = new Map(packages.map((pkg) => [pkg.id, pkg]));

  return details.flatMap((detail) => {
    const byLane = {
      slices: [] as PlannedSlice[],
      implementing: [] as PlannedSlice[],
      finished: [] as PlannedSlice[],
    };

    (detail.planned_slices || []).forEach((slice) => {
      byLane[sliceLane(slice)].push(slice);
    });

    const wires: BoardWire[] = [];
    let sources = [requestNodeId(detail)];

    ([byLane.slices, byLane.implementing, byLane.finished] as PlannedSlice[][]).forEach((targets) => {
      if (targets.length === 0) return;

      targets.forEach((target, index) => {
        const source = sources[Math.min(index, sources.length - 1)];
        const targetNode = sliceNodeId(target);
        wires.push({
          id: `${source}->${targetNode}`,
          from: source,
          to: targetNode,
          tone: wireToneForSlice(target, packageMap.get(target.work_package_id || "")),
        });
      });

      sources = targets.map(sliceNodeId);
    });

    return wires;
  });
}

function requestNodeId(detail: WorkRequestDetail) {
  return `request:${detail.work_request.id}`;
}

function sliceNodeId(slice: PlannedSlice) {
  return `slice:${slice.id}`;
}

function wireToneForSlice(slice: PlannedSlice, pkg?: WorkPackageCard): BoardWireTone {
  return sliceCardTone(slice, pkg, sliceLane(slice));
}

function statusVariant(status?: string | null): BadgeTone {
  if (["merged", "merged_into_phase", "closed", "answered"].includes(status || "")) return "success";
  if (["blocked", "human_info_needed"].includes(status || "")) return "danger";
  if (["implementing", "reviewing", "ci_waiting", "ready_for_slicing", "approved", "created", "ready_for_worker", "claimed", "planning"].includes(status || "")) {
    return "info";
  }
  if (["ready_for_human_merge", "ready_for_architect_merge"].includes(status || "")) return "warning";
  return "secondary";
}

function requestStatusVariant(status?: string | null): BadgeTone {
  if (status === "sliced") return "success";
  if (status === "human_info_needed") return "danger";
  if (status === "ready_for_slicing") return "info";
  return "secondary";
}

function formatStatus(status?: string | null) {
  return status ? status.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase()) : "Unknown";
}

function formatDate(value: string) {
  const timestamp = Date.parse(value);

  if (Number.isNaN(timestamp)) {
    return "recent";
  }

  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(timestamp);
}

function repoName(value?: string | null) {
  const trimmed = value?.trim();
  return trimmed || "Unscoped";
}

function addBranch(summary: RepoSummary, branch?: string | null) {
  const value = branch?.trim();
  if (value && !summary.baseBranches.includes(value)) {
    summary.baseBranches.push(value);
  }
}

const BRANCH_INTAKE_OPTIONS = ["main", "beta", "dev", "beta/dev"];

function repoOptions(repos: RepoSummary[], defaultRepo?: string) {
  const dashboardRepos = uniqueNonEmpty(repos.map((repo) => repo.repo));
  if (dashboardRepos.length > 0) {
    return dashboardRepos;
  }

  return uniqueNonEmpty([defaultRepo, initialRequestForm.repo]);
}

function baseBranchOptionsForRepo(repos: RepoSummary[], repo: string) {
  const summary = repos.find((candidate) => candidate.repo === repo);
  const exposedBranches = uniqueNonEmpty(summary?.baseBranches || []);
  const branchOptions = BRANCH_INTAKE_OPTIONS.filter((branch) => exposedBranches.includes(branch));
  return branchOptions.length > 0 ? branchOptions : [initialRequestForm.base_branch];
}

function uniqueNonEmpty(values: Array<string | undefined | null>) {
  return [...new Set(values.map((value) => value?.trim()).filter((value): value is string => Boolean(value)))];
}

function readStoredWorkspaceTab(): WorkspaceTab {
  const storedTab = readDashboardUiState().workspaceTab;
  return isWorkspaceTab(storedTab) ? storedTab : "workstreams";
}

function readStoredTopPanel(): TopPanelKey | null {
  const state = readDashboardUiState();
  if (!("topPanel" in state)) return "guidance";
  if (state.topPanel === null) return null;
  return isTopPanelKey(state.topPanel) ? state.topPanel : "guidance";
}

function readStoredWorkstreamLayout(): WorkstreamLayoutMode {
  const storedLayout = readDashboardUiState().workstreamLayout;
  return isWorkstreamLayoutMode(storedLayout) ? storedLayout : "jira";
}

function readStoredRepoWorkstreamOpen(stateKey: string, fallback: boolean) {
  const repoWorkstreams = readDashboardUiState().repoWorkstreams;
  const storedOpen = repoWorkstreams?.[stateKey];
  return typeof storedOpen === "boolean" ? storedOpen : fallback;
}

function writeStoredRepoWorkstreamOpen(stateKey: string, open: boolean) {
  updateDashboardUiState((state) => ({
    ...state,
    repoWorkstreams: {
      ...(state.repoWorkstreams || {}),
      [stateKey]: open,
    },
  }));
}

function writeDashboardUiStateValue<Key extends keyof DashboardUiState>(key: Key, value: DashboardUiState[Key]) {
  updateDashboardUiState((state) => ({ ...state, [key]: value }));
}

function readDashboardUiState(): DashboardUiState {
  if (typeof window === "undefined") return {};

  try {
    const rawState = window.localStorage.getItem(DASHBOARD_UI_STATE_KEY);
    if (!rawState) return {};

    const parsed = JSON.parse(rawState);
    return isRecord(parsed) ? (parsed as DashboardUiState) : {};
  } catch {
    return {};
  }
}

function updateDashboardUiState(updater: (state: DashboardUiState) => DashboardUiState) {
  if (typeof window === "undefined") return;

  try {
    const nextState = updater(readDashboardUiState());
    window.localStorage.setItem(DASHBOARD_UI_STATE_KEY, JSON.stringify(nextState));
  } catch {
    // Storage can be unavailable in locked-down browser contexts; UI state should stay non-critical.
  }
}

function defaultRepoWorkstreamOpen() {
  return typeof window === "undefined" ? true : window.innerWidth >= 900;
}

function repoWorkstreamStateKey(repo: Pick<RepoSummary, "repo" | "baseBranches">) {
  const branchKey = uniqueNonEmpty(repo.baseBranches).sort().join("|") || "main";
  return `${repo.repo}::${branchKey}`;
}

function isWorkspaceTab(value: unknown): value is WorkspaceTab {
  return value === "workstreams" || value === "solo";
}

function isTopPanelKey(value: unknown): value is TopPanelKey {
  return typeof value === "string" && (TOP_PANEL_ORDER as readonly string[]).includes(value);
}

function isWorkstreamLayoutMode(value: unknown): value is WorkstreamLayoutMode {
  return value === "jira" || value === "aligned";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function topPanelDirection(from: TopPanelKey | null, to: TopPanelKey | null): TopPanelDirection {
  if (!from || !to) return "forward";
  return TOP_PANEL_ORDER.indexOf(to) > TOP_PANEL_ORDER.indexOf(from) ? "forward" : "backward";
}

function measureElementHeight(element: HTMLElement | null) {
  return element?.getBoundingClientRect().height || 0;
}

function nextFrame(refs: React.MutableRefObject<number[]>, callback: () => void) {
  const id = window.requestAnimationFrame(callback);
  refs.current.push(id);
}

function later(refs: React.MutableRefObject<number[]>, delay: number, callback: () => void) {
  const id = window.setTimeout(callback, delay);
  refs.current.push(id);
}

function clearTopPanelTimers(
  timersRef: React.MutableRefObject<number[]>,
  framesRef: React.MutableRefObject<number[]>,
) {
  timersRef.current.forEach((id) => window.clearTimeout(id));
  framesRef.current.forEach((id) => window.cancelAnimationFrame(id));
  timersRef.current = [];
  framesRef.current = [];
}

function setFormValue(setForm: React.Dispatch<React.SetStateAction<NewRequestForm>>, key: keyof NewRequestForm, value: string) {
  setForm((current) => ({ ...current, [key]: value }));
}
