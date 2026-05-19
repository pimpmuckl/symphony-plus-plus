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
  Sparkles,
} from "lucide-react";
import type * as React from "react";
import { FormEvent, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";

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

type NewRequestForm = {
  title: string;
  repo: string;
  base_branch: string;
  work_type: string;
  desired_dispatch_shape: string;
  human_description: string;
  allowed_paths: string;
  forbidden_paths: string;
  compatibility_stance: string;
};

type BadgeTone = "default" | "secondary" | "outline" | "success" | "warning" | "danger" | "info";

const initialRequestForm: NewRequestForm = {
  title: "",
  repo: "symphony-plus-plus",
  base_branch: "main",
  work_type: "feature",
  desired_dispatch_shape: "architect_led_feature_branch",
  human_description: "",
  allowed_paths: "",
  forbidden_paths: "",
  compatibility_stance: "",
};

export default function App() {
  const [dashboard, setDashboard] = useState<DashboardPayload | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selectedGuidance, setSelectedGuidance] = useState<GuidanceItem | null>(null);
  const [newRequestOpen, setNewRequestOpen] = useState(false);

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
            <div className="flex items-start gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary text-primary-foreground shadow-sm motion-pop">
                <Sparkles className="h-5 w-5" />
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

          <RepoGlance repos={repos} />

          <Tabs defaultValue="workstreams" className="w-full motion-card">
            <TabsList>
              <TabsTrigger value="workstreams">Workstreams</TabsTrigger>
              <TabsTrigger value="solo">Solo Sessions</TabsTrigger>
            </TabsList>
            <TabsContent value="workstreams">
              <div className="grid gap-5">
                {repos.length === 0 ? (
                  <EmptyPanel title="No workstreams yet" />
                ) : (
                  repos.map((repo) => <RepoWorkstream key={repo.repo} repo={repo} requestDetails={requestDetails} />)
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
  const [openPanel, setOpenPanel] = useState<TopPanelKey | null>("guidance");
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
            <ScrollArea className="max-h-[400px] pr-3">
              <div className="grid gap-2">
                {finishedHighlights.slice(0, 18).map((item, index) => (
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
      className="stagger-item grid gap-4 rounded-lg border bg-background p-4 text-left shadow-sm transition-all hover:-translate-y-0.5 hover:border-primary/50 hover:shadow-dashboard"
      style={{ animationDelay: `${index * 45}ms` }}
      onClick={() => onSelect(item)}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <div className="flex h-8 w-8 items-center justify-center rounded-md bg-violet-50 text-violet-700">
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
      className="stagger-item rounded-lg border border-amber-200 bg-amber-50/30 p-4 shadow-sm"
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
      className="stagger-item flex items-center justify-between gap-4 rounded-lg border bg-background p-3 shadow-sm"
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

function RepoGlance({ repos }: { repos: RepoSummary[] }) {
  return (
    <Card className="motion-card">
      <CardHeader>
        <CardTitle>Repository Glance</CardTitle>
      </CardHeader>
      <CardContent className="grid gap-3">
        {repos.length === 0 ? (
          <EmptyPanel title="No repositories yet" compact />
        ) : (
          repos.map((repo) => (
            <div key={repo.repo} className="grid gap-3 rounded-lg border p-3 md:grid-cols-[minmax(180px,1fr)_repeat(4,minmax(92px,0.45fr))]">
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  <GitBranch className="h-4 w-4 text-primary" />
                  <p className="truncate text-sm font-semibold">{repo.repo}</p>
                </div>
                <p className="mt-1 truncate text-xs text-muted-foreground">{repo.baseBranches.join(", ") || "main"}</p>
              </div>
              <GlanceStat label="Requested" value={repo.requested} />
              <GlanceStat label="Active" value={repo.active} />
              <GlanceStat label="Implementing" value={repo.implementing} />
              <GlanceStat label="Finished" value={repo.finished} />
            </div>
          ))
        )}
      </CardContent>
    </Card>
  );
}

function GlanceStat({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-md bg-muted px-3 py-2">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="mt-1 text-lg font-semibold">{value}</p>
    </div>
  );
}

function RepoWorkstream({ repo, requestDetails }: { repo: RepoSummary; requestDetails: WorkRequestDetail[] }) {
  const [open, setOpen] = useState(() => (typeof window === "undefined" ? true : window.innerWidth >= 900));
  const repoDetails = requestDetails.filter((detail) => repoName(detail.work_request.repo) === repo.repo);
  const unlinkedPackages = repo.packages.filter((pkg) => !packageLinkedToRequest(pkg, requestDetails));

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
            <div className="flex flex-wrap gap-2">
              <Badge variant="danger">{repo.blockerCount} Blockers</Badge>
              <Badge variant="warning">{repo.guidanceCount} Guidance</Badge>
              <Badge variant="info">{repo.implementing} Implementing</Badge>
              <Badge variant="success">{repo.finished} Finished</Badge>
            </div>
          </div>
        </CardHeader>
        <CollapsibleContent className="collapsible-content">
          <CardContent className="p-0">
            <div className="overflow-x-auto">
              <div className="min-w-[1040px]">
                <div className="grid grid-cols-4 border-b bg-muted/55 text-xs font-medium uppercase text-muted-foreground">
                  {["Requested", "Active / Blocked", "Implementing", "Finished"].map((lane) => (
                    <div key={lane} className="border-r px-4 py-3 last:border-r-0">
                      {lane}
                    </div>
                  ))}
                </div>
                <div className="divide-y">
                  {repoDetails.length === 0 ? (
                    <PackageLaneGrid packages={unlinkedPackages} />
                  ) : (
                    repoDetails.map((detail) => <RequestSwimlane key={detail.work_request.id} detail={detail} packages={repo.packages} />)
                  )}
                  {repoDetails.length > 0 && unlinkedPackages.length > 0 ? <PackageLaneGrid packages={unlinkedPackages} /> : null}
                </div>
              </div>
            </div>
          </CardContent>
        </CollapsibleContent>
      </Card>
    </Collapsible>
  );
}

function RequestSwimlane({ detail, packages }: { detail: WorkRequestDetail; packages: WorkPackageCard[] }) {
  const slices = detail.planned_slices ?? [];
  const active = slices.filter((slice) => sliceLane(slice) === "active");
  const implementing = slices.filter((slice) => sliceLane(slice) === "implementing");
  const finished = slices.filter((slice) => sliceLane(slice) === "finished");
  const hasConnectors = slices.length > 0;

  return (
    <div className="relative grid min-h-[132px] grid-cols-4">
      {hasConnectors ? <div className="pointer-events-none absolute left-[22%] right-[8%] top-1/2 h-px bg-border" /> : null}
      <LaneCell>
        <RequestCard request={detail.work_request} questionCount={detail.clarification_questions?.filter((q) => q.status === "open").length ?? 0} />
      </LaneCell>
      <LaneCell>
        <SliceStack slices={active} packages={packages} emptyLabel="Architect" />
      </LaneCell>
      <LaneCell>
        <SliceStack slices={implementing} packages={packages} emptyLabel="Worker" />
      </LaneCell>
      <LaneCell last>
        <SliceStack slices={finished} packages={packages} emptyLabel="Done" />
      </LaneCell>
    </div>
  );
}

function PackageLaneGrid({ packages }: { packages: WorkPackageCard[] }) {
  const active = packages.filter((pkg) => packageLane(pkg) === "active");
  const implementing = packages.filter((pkg) => packageLane(pkg) === "implementing");
  const finished = packages.filter((pkg) => packageLane(pkg) === "finished");

  return (
    <div className="grid min-h-[128px] grid-cols-4 bg-card/60">
      <LaneCell>
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <Route className="h-4 w-4" />
          Unlinked packages
        </div>
      </LaneCell>
      <LaneCell>
        <PackageStack packages={active} />
      </LaneCell>
      <LaneCell>
        <PackageStack packages={implementing} />
      </LaneCell>
      <LaneCell last>
        <PackageStack packages={finished} />
      </LaneCell>
    </div>
  );
}

function LaneCell({ children, last = false }: { children: React.ReactNode; last?: boolean }) {
  return <div className={`relative z-10 border-r p-3 ${last ? "border-r-0" : ""}`}>{children}</div>;
}

function RequestCard({ request, questionCount }: { request: WorkRequestCard; questionCount: number }) {
  return (
    <div className="rounded-lg border bg-background p-3 shadow-sm">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{request.title || request.id}</p>
          <p className="mt-1 text-xs text-muted-foreground">{request.work_type || "feature"}</p>
        </div>
        <Badge variant={requestStatusVariant(request.status)}>{formatStatus(request.status)}</Badge>
      </div>
      <div className="mt-3 grid grid-cols-3 gap-2 text-xs">
        <MiniCount label="Open Q" value={questionCount || request.open_question_count || 0} />
        <MiniCount label="Slices" value={(request.planned_slice_count || 0) + (request.approved_slice_count || 0) + (request.dispatched_slice_count || 0)} />
        <MiniCount label="Done" value={request.dispatched_slice_count || 0} />
      </div>
    </div>
  );
}

function SliceStack({ slices, packages, emptyLabel }: { slices: PlannedSlice[]; packages: WorkPackageCard[]; emptyLabel: string }) {
  if (slices.length === 0) {
    return <div className="rounded-md border border-dashed px-3 py-2 text-xs text-muted-foreground">{emptyLabel}</div>;
  }

  return (
    <div className="grid gap-2">
      {slices.map((slice) => {
        const pkg = packages.find((candidate) => candidate.id === slice.work_package_id);
        return (
          <div key={slice.id} className="rounded-lg border bg-background p-3 shadow-sm">
            <div className="flex items-start justify-between gap-2">
              <p className="min-w-0 truncate text-sm font-medium">{slice.title || pkg?.title || slice.id}</p>
              <Badge variant={statusVariant(slice.work_package_status || slice.status)}>{formatStatus(slice.work_package_status || slice.status)}</Badge>
            </div>
            <p className="mt-2 line-clamp-2 text-xs text-muted-foreground">{slice.goal || pkg?.kind || slice.work_package_kind}</p>
          </div>
        );
      })}
    </div>
  );
}

function PackageStack({ packages }: { packages: WorkPackageCard[] }) {
  if (packages.length === 0) {
    return <div className="rounded-md border border-dashed px-3 py-2 text-xs text-muted-foreground">None</div>;
  }

  return (
    <div className="grid gap-2">
      {packages.map((pkg) => (
        <div key={pkg.id} className="rounded-lg border bg-background p-3 shadow-sm">
          <div className="flex items-start justify-between gap-2">
            <p className="min-w-0 truncate text-sm font-medium">{pkg.title || pkg.id}</p>
            <Badge variant={statusVariant(pkg.status)}>{formatStatus(pkg.status)}</Badge>
          </div>
          <div className="mt-3 grid grid-cols-3 gap-2 text-xs">
            <MiniCount label="Block" value={pkg.active_blocker_count || 0} />
            <MiniCount label="Find" value={pkg.finding_count || 0} />
            <MiniCount label="Art" value={pkg.artifact_count || 0} />
          </div>
        </div>
      ))}
    </div>
  );
}

function MiniCount({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-md bg-muted px-2 py-1">
      <p className="text-muted-foreground">{label}</p>
      <p className="font-semibold">{value}</p>
    </div>
  );
}

function SoloSessions({ sessions }: { sessions: SoloSession[] }) {
  if (sessions.length === 0) {
    return <EmptyPanel title="No solo sessions" />;
  }

  return (
    <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
      {sessions.map((session) => (
        <Card key={session.id}>
          <CardContent className="p-4">
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <p className="truncate text-sm font-semibold">{session.title || session.id}</p>
                <p className="mt-1 truncate text-xs text-muted-foreground">{repoName(session.repo)}</p>
              </div>
              <Badge variant={statusVariant(session.status)}>{formatStatus(session.status)}</Badge>
            </div>
            {session.latest_entry ? (
              <>
                <Separator className="my-3" />
                <p className="line-clamp-2 text-sm">{session.latest_entry.title || session.latest_entry.body}</p>
              </>
            ) : null}
          </CardContent>
        </Card>
      ))}
    </div>
  );
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
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const options = useMemo(() => guidanceOptions(item?.prompt), [item?.prompt]);

  useEffect(() => {
    if (item) {
      setSelectedChoice(options[0]?.id || CUSTOM_CHOICE);
      setNotes({});
      setError(null);
    }
  }, [item, options]);

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
      <DialogContent>
        {item ? (
          <>
            <DialogHeader>
              <DialogTitle>{item.prompt?.tl_dr || item.title}</DialogTitle>
              <DialogDescription>{item.repo}</DialogDescription>
            </DialogHeader>
            <div className="grid gap-4">
              <section className="rounded-lg border bg-muted/40 p-4">
                <p className="text-sm font-medium">TL;DR</p>
                <p className="mt-2 text-sm text-muted-foreground">{item.prompt?.tl_dr || item.title}</p>
              </section>
              <section className="rounded-lg border p-4">
                <p className="text-sm font-medium">Details</p>
                <p className="mt-2 whitespace-pre-wrap text-sm text-muted-foreground">{item.prompt?.details || item.detail}</p>
              </section>
              <div className="grid gap-3">
                {options.map((option) => (
                  <div
                    key={option.id}
                    className={`rounded-lg border p-4 text-left transition-colors ${
                      selectedChoice === option.id ? "border-primary bg-primary/5" : "bg-background hover:border-primary/50"
                    }`}
                    onClick={() => setSelectedChoice(option.id)}
                  >
                    <div className="flex items-start gap-3">
                      <CircleDot className={`mt-0.5 h-4 w-4 ${selectedChoice === option.id ? "text-primary" : "text-muted-foreground"}`} />
                      <div className="min-w-0 flex-1">
                        <p className="text-sm font-semibold">{option.label}</p>
                        {option.description ? <p className="mt-1 text-sm text-muted-foreground">{option.description}</p> : null}
                        <ProsCons option={option} />
                        <Label className="mt-3 block text-xs text-muted-foreground">
                          {option.id === CUSTOM_CHOICE ? "Do this instead" : "Add Extra Note"}
                        </Label>
                        <Textarea
                          className="mt-1 min-h-[72px]"
                          placeholder={option.id === CUSTOM_CHOICE ? "None of the above, do this instead:" : "Add extra note"}
                          value={notes[option.id] || ""}
                          onChange={(event) => setNotes((current) => ({ ...current, [option.id]: event.target.value }))}
                          onClick={(event) => event.stopPropagation()}
                        />
                      </div>
                    </div>
                  </div>
                ))}
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
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated: (dashboard: DashboardPayload) => void;
  defaultRepo?: string;
}) {
  const [form, setForm] = useState<NewRequestForm>({ ...initialRequestForm, repo: defaultRepo || initialRequestForm.repo });
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (open) {
      setForm((current) => ({ ...current, repo: current.repo || defaultRepo || initialRequestForm.repo }));
      setError(null);
    }
  }, [defaultRepo, open]);

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
          constraints: {
            allowed_paths: splitLines(form.allowed_paths),
            forbidden_paths: splitLines(form.forbidden_paths),
            compatibility_stance: form.compatibility_stance.trim(),
          },
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
      <DialogContent>
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
              <Input value={form.repo} onChange={(event) => setFormValue(setForm, "repo", event.target.value)} required />
            </Field>
            <Field label="Base Branch">
              <Input value={form.base_branch} onChange={(event) => setFormValue(setForm, "base_branch", event.target.value)} required />
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
            <Field label="Compatibility">
              <Input value={form.compatibility_stance} onChange={(event) => setFormValue(setForm, "compatibility_stance", event.target.value)} />
            </Field>
          </div>
          <Field label="Description">
            <Textarea value={form.human_description} onChange={(event) => setFormValue(setForm, "human_description", event.target.value)} required />
          </Field>
          <div className="grid gap-4 md:grid-cols-2">
            <Field label="Allowed Paths">
              <Textarea className="min-h-[80px]" value={form.allowed_paths} onChange={(event) => setFormValue(setForm, "allowed_paths", event.target.value)} />
            </Field>
            <Field label="Forbidden Paths">
              <Textarea className="min-h-[80px]" value={form.forbidden_paths} onChange={(event) => setFormValue(setForm, "forbidden_paths", event.target.value)} />
            </Field>
          </div>
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
      .map((question) => ({
        source: "clarification",
        id: question.id,
        repo: repoName(detail.work_request.repo),
        title: question.decision_prompt?.tl_dr || question.question || question.id,
        workRequestId: detail.work_request.id,
        prompt: question.decision_prompt,
        detail: question.decision_prompt?.details || question.why_needed || question.question || "",
        question,
        request: detail.work_request,
      })),
  );

  return [...guidance, ...clarifications];
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
      summary.requests.filter((request) => requestLane(request) === "active").length +
      summary.packages.filter((pkg) => packageLane(pkg) === "active").length;
    summary.implementing = summary.packages.filter((pkg) => packageLane(pkg) === "implementing").length;
    summary.finished = summary.packages.filter((pkg) => packageLane(pkg) === "finished").length;
    summary.blockerCount = activeBlockerItems(summary.packages).length;
    details
      .filter((detail) => repoName(detail.work_request.repo) === summary.repo)
      .flatMap((detail) => detail.planned_slices || [])
      .forEach((slice) => {
        const lane = sliceLane(slice);
        if (lane === "implementing") summary.implementing += 1;
        if (lane === "finished") summary.finished += 1;
      });
  });

  return [...repos.values()].sort((a, b) => a.repo.localeCompare(b.repo));
}

function dashboardTotals(packages: WorkPackageCard[], requests: WorkRequestCard[], guidance: GuidanceItem[]) {
  return {
    guidance: guidance.length,
    active: requests.filter((request) => requestLane(request) === "active").length + packages.filter((pkg) => packageLane(pkg) === "active").length,
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
      pros: ["Preserves human intent"],
      cons: ["Needs precise wording"],
    },
  ];
}

function guidanceAnswerUrl(item: GuidanceItem) {
  if (item.source === "guidance") {
    return `/api/v1/sympp/operator/work-packages/${encodeURIComponent(item.packageId)}/guidance/${encodeURIComponent(item.id)}/answer`;
  }

  return `/api/v1/sympp/operator/work-requests/${encodeURIComponent(item.workRequestId)}/questions/${encodeURIComponent(item.id)}/answer`;
}

function requestLane(request: WorkRequestCard): "requested" | "active" | "finished" {
  if (request.status === "sliced") return "finished";
  if (request.status === "ready_for_slicing") return "active";
  return "requested";
}

function packageLane(pkg: WorkPackageCard): "active" | "implementing" | "finished" {
  if (["merged_into_phase", "merged", "closed"].includes(pkg.status || "")) return "finished";
  if (["implementing", "reviewing", "ci_waiting", "merging_into_phase"].includes(pkg.status || "")) return "implementing";
  return "active";
}

function sliceLane(slice: PlannedSlice): "active" | "implementing" | "finished" {
  const status = slice.work_package_status || slice.status || "";
  if (["dispatched", "merged_into_phase", "merged", "closed"].includes(status)) return "finished";
  if (["implementing", "reviewing", "ci_waiting", "merging_into_phase"].includes(status)) return "implementing";
  return "active";
}

function packageLinkedToRequest(pkg: WorkPackageCard, details: WorkRequestDetail[]) {
  return details.some((detail) => (detail.planned_slices || []).some((slice) => slice.work_package_id === pkg.id));
}

function statusVariant(status?: string | null): BadgeTone {
  if (["merged", "merged_into_phase", "closed", "answered"].includes(status || "")) return "success";
  if (["blocked", "human_info_needed"].includes(status || "")) return "danger";
  if (["implementing", "reviewing", "ci_waiting"].includes(status || "")) return "info";
  if (["ready_for_human_merge", "ready_for_architect_merge", "ready_for_slicing"].includes(status || "")) return "warning";
  return "secondary";
}

function requestStatusVariant(status?: string | null): BadgeTone {
  if (status === "sliced") return "success";
  if (status === "human_info_needed") return "danger";
  if (status === "ready_for_slicing") return "warning";
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

function splitLines(value: string) {
  return value
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
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
