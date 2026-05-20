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
  Moon,
  Plus,
  RefreshCw,
  Route,
  Send,
  Sun,
} from "lucide-react";
import type * as React from "react";
import { Children, FormEvent, isValidElement, useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";

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
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import type {
  ActiveBlockingEdge,
  ClarificationQuestion,
  DashboardPayload,
  DecisionOption,
  DecisionPrompt,
  GuidanceRequest,
  PlannedSlice,
  SoloSession,
  SoloSessionDetailPayload,
  SoloSessionEntry,
  WorkPackageCard,
  WorkPackageDetailPayload,
  WorkRequestCard,
  WorkRequestDetail,
} from "@/types/dashboard";

declare global {
  interface Window {
    SYMPP_DASHBOARD_CONFIG?: {
      apiBase?: string;
      basePath?: string;
      csrfToken?: string;
      logoUrl?: string;
    };
  }
}

const CUSTOM_CHOICE = "__custom_redirect__";
const DASHBOARD_UI_STATE_KEY = "symphony-plus-plus.dashboard.ui-state.v1";
const DASHBOARD_THEME_KEY = "symphony-plus-plus.dashboard.theme.v1";
const ALIGNED_ROW_MIN_HEIGHT = 112;
const BOARD_WIRE_TRACK_CLEARANCE = 40;
const DASHBOARD_POLL_INTERVAL_MS = 7000;
const TOP_PANEL_ORDER: TopPanelKey[] = ["guidance", "blockers", "finished"];
const TOP_PANEL_RESIZE_MS = 210;
const TOP_PANEL_SLIDE_MS = 360;
const UPDATE_ANIMATION_TTL_MS = 1800;
const WORKSPACE_TAB_SLIDE_MS = 360;
const BADGE_TEXT_PUSH_MS = 220;
const BADGE_RESIZE_MS = 150;
const DEFAULT_DASHBOARD_API_BASE = "/api/v1/sympp/operator";

type DashboardRuntimeConfig = {
  apiBase?: string;
  basePath?: string;
  csrfToken?: string;
  logoUrl?: string;
};

let dashboardRuntimeConfig: DashboardRuntimeConfig | undefined = typeof window === "undefined" ? undefined : window.SYMPP_DASHBOARD_CONFIG;
let dashboardRuntimeConfigPromise: Promise<DashboardRuntimeConfig | undefined> | null = null;
const DASHBOARD_LOGO_URL = dashboardRuntimeConfig?.logoUrl || "/splusplus-logo.png";

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
type FeatureLane = "requested" | "slices" | "packages";
type SignalTone = "muted" | "info" | "warning" | "danger" | "success";
type StateCardTone = "request" | "queued" | "slice" | "implementing" | "review" | "merge" | "guidance" | "blocked" | "finished" | "muted";
type BoardWireTone = StateCardTone;
type StateToneStyle = {
  card: string;
  accent: string;
};
type WorkspaceTab = "workstreams" | "solo";
type WorkspaceTabPhase = "idle" | "swapping";
type WorkstreamLayoutMode = "jira" | "aligned";
type DashboardTheme = "light" | "dark";
type UpdateMotionKind = "added" | "changed" | "guidance" | "blocker" | "finished";
type UpdateMotion = { kind: UpdateMotionKind | "settled"; token: number };
type BadgePushPhase = "idle" | "measure" | "resize-first" | "push" | "resize-last";
type UpdateAnimationEntity = {
  signature: string;
  status?: string | null;
  guidanceCount: number;
  blockerCount: number;
  finished: boolean;
};
type DashboardUpdateAnimations = {
  countPulseFor: (panel: TopPanelKey) => number;
  motionFor: (key?: string | null) => UpdateMotion | undefined;
  simulate: (kind: UpdateMotionKind) => void;
};
type CardDetailSelection =
  | { kind: "request"; detail: WorkRequestDetail }
  | { kind: "slice"; detail: WorkRequestDetail; slice: PlannedSlice; pkg?: WorkPackageCard }
  | { kind: "package"; pkg: WorkPackageCard; detail?: WorkRequestDetail; slice?: PlannedSlice }
  | { kind: "solo"; session: SoloSession };
type CardDetailSelect = (selection: CardDetailSelection) => void;
type DashboardUiState = {
  workspaceTab?: WorkspaceTab;
  topPanel?: TopPanelKey | null;
  repoWorkstreams?: Record<string, boolean>;
  workstreamLayout?: WorkstreamLayoutMode;
};

function normalizeRuntimeBase(value: string | undefined, fallback: string) {
  const base = value?.trim() || fallback;
  return base.replace(/\/+$/, "");
}

function operatorApiUrl(path: string) {
  const base = normalizeRuntimeBase(dashboardRuntimeConfig?.apiBase, DEFAULT_DASHBOARD_API_BASE);
  const suffix = path.startsWith("/") ? path : `/${path}`;
  return `${base}${suffix}`;
}

function jsonHeaders({ csrf = false, content = false }: { csrf?: boolean; content?: boolean } = {}) {
  const headers: Record<string, string> = { accept: "application/json" };

  if (content) {
    headers["content-type"] = "application/json";
  }

  if (csrf && dashboardRuntimeConfig?.csrfToken) {
    headers["x-csrf-token"] = dashboardRuntimeConfig.csrfToken;
  }

  return headers;
}

async function ensureDashboardRuntimeConfig() {
  if (dashboardRuntimeConfig?.csrfToken) return dashboardRuntimeConfig;

  dashboardRuntimeConfigPromise ??= fetch(operatorApiUrl("/config"), { headers: jsonHeaders() })
    .then(async (response) => {
      const payload = await response.json();
      if (!response.ok) {
        throw new Error(payload?.error?.message || "Dashboard runtime config unavailable");
      }
      dashboardRuntimeConfig = payload;
      return dashboardRuntimeConfig;
    })
    .finally(() => {
      dashboardRuntimeConfigPromise = null;
    });

  return dashboardRuntimeConfigPromise;
}

async function mutationHeaders() {
  await ensureDashboardRuntimeConfig();
  return jsonHeaders({ csrf: true, content: true });
}

type BlockerItem = {
  id: string;
  title: string;
  repo: string;
  status?: string | null;
  blockerCount: number;
  detail: string;
  selection: CardDetailSelection;
};

type FinishedHighlight = {
  id: string;
  title: string;
  repo: string;
  kind: FinishedHighlightKind;
  status?: string | null;
  at?: string | null;
  selection: CardDetailSelection;
};

type FinishedHighlightKind = "Request" | "Slice" | "Work Package";

type BoardWire = {
  id: string;
  from: string;
  to: string;
  tone: BoardWireTone;
  kind?: BoardWireKind;
};

type BoardWireKind = "progress" | "blocker";

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

const STATE_CARD_TONES: Record<StateCardTone, StateToneStyle> = {
  request: { card: "border-slate-200 bg-slate-50/80 dark:border-slate-700/80 dark:bg-slate-900/70", accent: "rgb(203 213 225)" },
  queued: { card: "border-teal-200/80 bg-teal-50/80 dark:border-teal-700/70 dark:bg-teal-950/45", accent: "rgb(45 212 191)" },
  slice: { card: "border-cyan-200/80 bg-cyan-50/80 dark:border-cyan-700/70 dark:bg-cyan-950/45", accent: "rgb(34 211 238)" },
  implementing: { card: "border-sky-200/80 bg-sky-50/80 dark:border-sky-700/70 dark:bg-sky-950/45", accent: "rgb(56 189 248)" },
  review: { card: "border-indigo-200/80 bg-indigo-50/80 dark:border-indigo-700/70 dark:bg-indigo-950/45", accent: "rgb(129 140 248)" },
  merge: { card: "border-lime-200/80 bg-lime-50/80 dark:border-lime-700/70 dark:bg-lime-950/45", accent: "rgb(163 230 53)" },
  guidance: { card: "border-violet-200/80 bg-violet-50/80 dark:border-violet-700/70 dark:bg-violet-950/45", accent: "rgb(167 139 250)" },
  blocked: { card: "border-rose-200/80 bg-rose-50/80 dark:border-rose-700/70 dark:bg-rose-950/45", accent: "rgb(251 113 133)" },
  finished: { card: "border-emerald-200/80 bg-emerald-50/80 dark:border-emerald-700/70 dark:bg-emerald-950/45", accent: "rgb(52 211 153)" },
  muted: { card: "border-zinc-200/80 bg-zinc-50/80 dark:border-zinc-700/80 dark:bg-zinc-900/70", accent: "rgb(212 212 216)" },
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
  minHeight: number;
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

type BadgeTone = "default" | "secondary" | "outline" | "success" | "warning" | "danger" | "info" | "ready";

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
  const [selectedCardDetail, setSelectedCardDetail] = useState<CardDetailSelection | null>(null);
  const [newRequestOpen, setNewRequestOpen] = useState(false);
  const [workspaceTab, setWorkspaceTab] = useState<WorkspaceTab>(readStoredWorkspaceTab);
  const [workstreamLayout, setWorkstreamLayout] = useState<WorkstreamLayoutMode>(readStoredWorkstreamLayout);
  const [theme, setTheme] = useState<DashboardTheme>(readStoredTheme);
  const loadInFlightRef = useRef(false);

  const loadDashboard = useCallback(async (mode: "initial" | "refresh" | "silent" = "refresh") => {
    if (loadInFlightRef.current && mode === "silent") return;
    loadInFlightRef.current = true;

    if (mode === "initial") {
      setLoading(true);
    } else if (mode === "refresh") {
      setRefreshing(true);
    }

    try {
      const response = await fetch(operatorApiUrl("/dashboard"), { headers: jsonHeaders() });
      const payload = await response.json();

      if (!response.ok) {
        throw new Error(payload?.error?.message || "Dashboard API unavailable");
      }

      setDashboard(payload);
      setError(null);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Dashboard API unavailable");
    } finally {
      loadInFlightRef.current = false;
      setLoading(false);
      if (mode === "refresh") setRefreshing(false);
    }
  }, []);

  useEffect(() => {
    void loadDashboard("initial");
  }, [loadDashboard]);

  useEffect(() => {
    const interval = window.setInterval(() => {
      if (document.visibilityState === "visible") {
        void loadDashboard("silent");
      }
    }, DASHBOARD_POLL_INTERVAL_MS);

    return () => window.clearInterval(interval);
  }, [loadDashboard]);

  useEffect(() => {
    writeDashboardUiStateValue("workspaceTab", workspaceTab);
  }, [workspaceTab]);

  useEffect(() => {
    writeDashboardUiStateValue("workstreamLayout", workstreamLayout);
  }, [workstreamLayout]);

  useEffect(() => {
    writeStoredTheme(theme);
  }, [theme]);

  const packages = useMemo(() => allPackages(dashboard), [dashboard]);
  const requests = dashboard?.work_requests?.work_requests ?? [];
  const requestDetails = dashboard?.work_request_details ?? [];
  const guidanceItems = useMemo(() => allGuidanceItems(dashboard), [dashboard]);
  const blockerItems = useMemo(() => activeBlockerItems(packages, requestDetails), [packages, requestDetails]);
  const finishedHighlights = useMemo(() => recentFinishedHighlights(packages, requests, requestDetails), [packages, requests, requestDetails]);
  const soloSessions = dashboard?.solo_sessions?.solo_sessions ?? [];
  const repos = useMemo(() => repoSummaries(packages, requests, guidanceItems, soloSessions, requestDetails), [
    packages,
    requests,
    guidanceItems,
    soloSessions,
    requestDetails,
  ]);
  const updateAnimations = useDashboardUpdateAnimations({
    blockerItems,
    finishedHighlights,
    guidanceItems,
    packages,
    requestDetails,
    ready: dashboard !== null,
    soloSessions,
  });

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
      <main className="dashboard-shell min-h-screen">
        <header className="dashboard-header-glass sticky top-0 z-20">
          <div className="mx-auto flex max-w-[1500px] flex-col gap-4 px-4 py-4 sm:px-6 lg:flex-row lg:items-center lg:justify-between lg:px-8">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center overflow-hidden rounded-lg border bg-card shadow-sm motion-pop">
                <img src={DASHBOARD_LOGO_URL} alt="Symphony++" className="h-full w-full scale-[1.34] object-contain" />
              </div>
              <div>
                <h1 className="text-xl font-semibold">Symphony++</h1>
                <p className="text-sm text-muted-foreground">Operator cockpit</p>
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              <UpdateSimulationControls updateAnimations={updateAnimations} />
              <Badge variant={error ? "danger" : "success"}>{error ? "API unavailable" : "Live ledger"}</Badge>
              <ThemeToggle theme={theme} onToggle={() => setTheme((currentTheme) => (currentTheme === "dark" ? "light" : "dark"))} />
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
            <Card className="dashboard-glass-surface border-rose-200 bg-rose-50 motion-card dark:border-rose-700/70 dark:bg-rose-950/45">
              <CardContent className="flex items-center gap-3 p-4 text-sm text-rose-800 dark:text-rose-200">
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
            onSelectCard={setSelectedCardDetail}
            updateAnimations={updateAnimations}
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
            <WorkspaceTabCarousel
              activeTab={workspaceTab}
              renderTab={(tab) =>
                tab === "workstreams" ? (
                  <div className="grid gap-5">
                    {repos.length === 0 ? (
                      <EmptyPanel title="No workstreams yet" />
                    ) : (
                      repos.map((repo) => (
                        <RepoWorkstream
                          key={repoWorkstreamStateKey(repo)}
                          repo={repo}
                          requestDetails={requestDetails}
                          activeBlockingEdges={dashboard?.active_blocking_edges ?? []}
                          onSelectGuidance={setSelectedGuidance}
                          onSelectCard={setSelectedCardDetail}
                          layoutMode={workstreamLayout}
                          updateAnimations={updateAnimations}
                        />
                      ))
                    )}
                  </div>
                ) : (
                  <SoloSessions sessions={soloSessions} onSelectCard={setSelectedCardDetail} updateAnimations={updateAnimations} />
                )
              }
            />
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
        <CardDetailDialog
          selection={selectedCardDetail}
          onOpenChange={(open) => {
            if (!open) setSelectedCardDetail(null);
          }}
          onSelectGuidance={setSelectedGuidance}
        />
      </main>
    </TooltipProvider>
  );
}

function useDashboardUpdateAnimations({
  blockerItems,
  finishedHighlights,
  guidanceItems,
  packages,
  ready,
  requestDetails,
  soloSessions,
}: {
  blockerItems: BlockerItem[];
  finishedHighlights: FinishedHighlight[];
  guidanceItems: GuidanceItem[];
  packages: WorkPackageCard[];
  ready: boolean;
  requestDetails: WorkRequestDetail[];
  soloSessions: SoloSession[];
}): DashboardUpdateAnimations {
  const previousSnapshotRef = useRef<Map<string, UpdateAnimationEntity> | null>(null);
  const latestSnapshotRef = useRef<Map<string, UpdateAnimationEntity>>(new Map());
  const timersRef = useRef<number[]>([]);
  const tokenRef = useRef(0);
  const [motions, setMotions] = useState<Record<string, UpdateMotion>>({});
  const [countPulses, setCountPulses] = useState<Record<TopPanelKey, number>>({ blockers: 0, finished: 0, guidance: 0 });

  const applyMotions = useCallback((nextMotions: Record<string, UpdateMotion>) => {
    const motionEntries = Object.entries(nextMotions);
    if (motionEntries.length === 0) return;

    setMotions((current) => ({ ...current, ...nextMotions }));

    const timer = window.setTimeout(() => {
      setMotions((current) => {
        let changed = false;
        const next = { ...current };

        motionEntries.forEach(([key, motion]) => {
          if (next[key]?.token === motion.token) {
            next[key] = { kind: "settled", token: motion.token };
            changed = true;
          }
        });

        return changed ? next : current;
      });
    }, UPDATE_ANIMATION_TTL_MS);

    timersRef.current.push(timer);
  }, []);

  useEffect(
    () => () => {
      timersRef.current.forEach((timer) => window.clearTimeout(timer));
      timersRef.current = [];
    },
    [],
  );

  useEffect(() => {
    if (!ready) {
      latestSnapshotRef.current = new Map();
      previousSnapshotRef.current = null;
      setMotions((current) => (Object.keys(current).length > 0 ? {} : current));
      return;
    }

    const snapshot = dashboardAnimationSnapshot({ blockerItems, finishedHighlights, guidanceItems, packages, requestDetails, soloSessions });
    latestSnapshotRef.current = snapshot;
    const previousSnapshot = previousSnapshotRef.current;

    if (!previousSnapshot) {
      previousSnapshotRef.current = snapshot;
      return;
    }

    const nextMotions: Record<string, UpdateMotion> = {};
    snapshot.forEach((entity, key) => {
      const motionKind = classifyUpdateMotion(previousSnapshot.get(key), entity);
      if (!motionKind) return;

      nextMotions[key] = { kind: motionKind, token: (tokenRef.current += 1) };
    });

    previousSnapshotRef.current = snapshot;

    applyMotions(nextMotions);
  }, [applyMotions, blockerItems, finishedHighlights, guidanceItems, packages, ready, requestDetails, soloSessions]);

  const motionFor = useCallback((key?: string | null) => (key ? motions[key] : undefined), [motions]);
  const countPulseFor = useCallback((panel: TopPanelKey) => countPulses[panel] || 0, [countPulses]);
  const simulate = useCallback(
    (kind: UpdateMotionKind) => {
      const snapshot = latestSnapshotRef.current;
      const keys = simulatedMotionKeys(kind, snapshot);
      const nextMotions = Object.fromEntries(keys.map((key) => [key, { kind, token: (tokenRef.current += 1) } satisfies UpdateMotion]));

      applyMotions(nextMotions);

      const panel = topPanelForMotionKind(kind);
      if (panel) {
        setCountPulses((current) => ({ ...current, [panel]: (current[panel] || 0) + 1 }));
      }
    },
    [applyMotions],
  );

  return useMemo(() => ({ countPulseFor, motionFor, simulate }), [countPulseFor, motionFor, simulate]);
}

function dashboardAnimationSnapshot({
  blockerItems,
  finishedHighlights,
  guidanceItems,
  packages,
  requestDetails,
  soloSessions,
}: {
  blockerItems: BlockerItem[];
  finishedHighlights: FinishedHighlight[];
  guidanceItems: GuidanceItem[];
  packages: WorkPackageCard[];
  requestDetails: WorkRequestDetail[];
  soloSessions: SoloSession[];
}) {
  const snapshot = new Map<string, UpdateAnimationEntity>();
  const packageById = new Map(packages.map((pkg) => [pkg.id, pkg]));

  requestDetails.forEach((detail) => {
    snapshot.set(requestUpdateKey(detail), requestAnimationEntity(detail));

    (detail.planned_slices || []).forEach((slice) => {
      snapshot.set(sliceUpdateKey(slice), sliceAnimationEntity(slice, slice.work_package_id ? packageById.get(slice.work_package_id) : undefined));
    });
  });

  packages.forEach((pkg) => {
    snapshot.set(packageUpdateKey(pkg), packageAnimationEntity(pkg));
  });

  guidanceItems.forEach((item) => {
    snapshot.set(guidanceUpdateKey(item), guidanceAnimationEntity(item));
  });

  blockerItems.forEach((item) => {
    snapshot.set(blockerUpdateKey(item), blockerAnimationEntity(item));
  });

  finishedHighlights.forEach((item) => {
    snapshot.set(finishedHighlightUpdateKey(item), finishedHighlightAnimationEntity(item));
  });

  soloSessions.forEach((session) => {
    snapshot.set(soloSessionUpdateKey(session), soloSessionAnimationEntity(session));
  });

  return snapshot;
}

function requestUpdateKey(detail: WorkRequestDetail) {
  return `request:${detail.work_request.id}`;
}

function sliceUpdateKey(slice: PlannedSlice) {
  return `slice:${slice.id}`;
}

function packageUpdateKey(pkg: WorkPackageCard) {
  return `package:${pkg.id}`;
}

function guidanceUpdateKey(item: GuidanceItem) {
  return `guidance:${item.source}:${item.id}`;
}

function blockerUpdateKey(item: BlockerItem) {
  return `blocker:${item.id}`;
}

function finishedHighlightUpdateKey(item: FinishedHighlight) {
  return `finished:${item.kind}:${item.id}`;
}

function soloSessionUpdateKey(session: SoloSession) {
  return `solo:${session.id}`;
}

function finishedHighlightsListKey(items: FinishedHighlight[]) {
  return items.map(finishedHighlightUpdateKey).join("|");
}

function classifyUpdateMotion(previous: UpdateAnimationEntity | undefined, current: UpdateAnimationEntity): UpdateMotionKind | null {
  if (!previous) {
    if (current.finished) return "finished";
    if (current.blockerCount > 0 || isBlockedStatus(current.status)) return "blocker";
    if (current.guidanceCount > 0) return "guidance";
    return "added";
  }

  if (previous.signature === current.signature) return null;
  if (current.finished && !previous.finished) return "finished";
  if (current.blockerCount > previous.blockerCount || (!isBlockedStatus(previous.status) && isBlockedStatus(current.status))) return "blocker";
  if (current.guidanceCount > previous.guidanceCount) return "guidance";
  return "changed";
}

function simulatedMotionKeys(kind: UpdateMotionKind, snapshot: Map<string, UpdateAnimationEntity>) {
  const entries = [...snapshot.entries()];
  const preferred =
    kind === "guidance"
      ? entries.filter(([, entity]) => entity.guidanceCount > 0)
      : kind === "blocker"
        ? entries.filter(([, entity]) => entity.blockerCount > 0 || isBlockedStatus(entity.status))
        : kind === "finished"
          ? entries.filter(([, entity]) => entity.finished)
          : entries.filter(([key]) => key.startsWith("request:") || key.startsWith("slice:") || key.startsWith("package:") || key.startsWith("solo:"));

  return (preferred.length > 0 ? preferred : entries).slice(0, kind === "changed" ? 4 : 3).map(([key]) => key);
}

function topPanelForMotionKind(kind: UpdateMotionKind): TopPanelKey | null {
  if (kind === "guidance") return "guidance";
  if (kind === "blocker") return "blockers";
  if (kind === "finished") return "finished";
  return null;
}

function requestAnimationEntity(detail: WorkRequestDetail): UpdateAnimationEntity {
  const request = detail.work_request;
  const openQuestions = detail.clarification_questions?.filter((question) => question.status === "open") ?? [];
  const guidanceCount = Math.max(openQuestions.length, request.open_question_count || 0, request.status === "human_info_needed" ? 1 : 0);

  return {
    signature: stableSignature([
      request.status,
      request.updated_at,
      request.open_question_count,
      request.answered_question_count,
      request.planned_slice_count,
      request.approved_slice_count,
      request.dispatched_slice_count,
      request.skipped_slice_count,
      detail.summary,
      (detail.clarification_questions || []).map((question) => [
        question.id,
        question.status,
        question.answer,
        question.answered_at,
        question.updated_at,
      ]),
    ]),
    status: request.status,
    guidanceCount,
    blockerCount: 0,
    finished: requestLane(request) === "finished",
  };
}

function sliceAnimationEntity(slice: PlannedSlice, pkg?: WorkPackageCard): UpdateAnimationEntity {
  const status = slice.work_package_status || slice.status;
  const blockerCount = pkg?.active_blocker_count || (pkg?.status === "blocked" ? 1 : 0);

  return {
    signature: stableSignature([
      slice.status,
      slice.work_package_id,
      slice.work_package_status,
      slice.updated_at,
      slice.dispatched_at,
      pkg?.status,
      pkg?.active_blocker_count,
      pkg?.latest_progress_at,
      pkg?.updated_at,
      pkg?.plan,
    ]),
    status,
    guidanceCount: 0,
    blockerCount,
    finished: sliceLane(slice) === "finished" || Boolean(pkg && packageLane(pkg) === "finished"),
  };
}

function packageAnimationEntity(pkg: WorkPackageCard): UpdateAnimationEntity {
  const blockerCount = pkg.active_blocker_count || (pkg.status === "blocked" ? 1 : 0);

  return {
    signature: stableSignature([
      pkg.status,
      pkg.updated_at,
      pkg.latest_progress_at,
      pkg.active_blocker_count,
      pkg.artifact_count,
      pkg.finding_count,
      pkg.plan,
      pkg.metadata?.pr,
      pkg.metadata?.review_package,
      pkg.metadata?.review_suite_result,
      pkg.active_agent_run,
      pkg.runtime,
    ]),
    status: pkg.status,
    guidanceCount: 0,
    blockerCount,
    finished: packageLane(pkg) === "finished",
  };
}

function guidanceAnimationEntity(item: GuidanceItem): UpdateAnimationEntity {
  const status = item.source === "guidance" ? item.guidance.status : item.question.status;

  return {
    signature: stableSignature([item.title, item.detail, status, item.prompt, item.source === "clarification" ? item.question.answer : item.guidance.context]),
    status,
    guidanceCount: isClosedGuidanceStatus(status) ? 0 : 1,
    blockerCount: 0,
    finished: false,
  };
}

function blockerAnimationEntity(item: BlockerItem): UpdateAnimationEntity {
  return {
    signature: stableSignature([item.status, item.blockerCount, item.detail, item.title]),
    status: item.status,
    guidanceCount: 0,
    blockerCount: item.blockerCount,
    finished: false,
  };
}

function finishedHighlightAnimationEntity(item: FinishedHighlight): UpdateAnimationEntity {
  return {
    signature: stableSignature([item.status, item.at, item.title, item.kind]),
    status: item.status,
    guidanceCount: 0,
    blockerCount: 0,
    finished: true,
  };
}

function soloSessionAnimationEntity(session: SoloSession): UpdateAnimationEntity {
  const attention = soloSessionAttention(session);

  return {
    signature: stableSignature([session.status, session.last_activity_at, session.updated_at, session.entry_counts, session.latest_entry]),
    status: session.status,
    guidanceCount: attention.guidanceCount,
    blockerCount: attention.blockerCount,
    finished: soloSessionLane(session) === "finished",
  };
}

function stableSignature(value: unknown) {
  return JSON.stringify(value);
}

function isClosedGuidanceStatus(status?: string | null) {
  return ["answered", "closed", "resolved", "done", "completed"].includes(status || "");
}

function isBlockedStatus(status?: string | null) {
  return status === "blocked";
}

function updateMotionAttributes(motion?: UpdateMotion) {
  if (motion?.kind === "settled") return { "data-update-settled": "true" };
  return motion ? { "data-update-kind": motion.kind, "data-update-token": motion.token } : {};
}

function useCountMotion(value: number, pulseToken = 0) {
  const currentRef = useRef(value);
  const pulseRef = useRef(pulseToken);
  const tokenRef = useRef(0);
  const [motion, setMotion] = useState({
    active: false,
    current: value,
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

    setMotion({ active: true, current: value, direction, previous: displayedPrevious, token });

    const timer = window.setTimeout(() => {
      setMotion({ active: false, current: value, direction: "idle", previous: value, token });
    }, 760);

    return () => window.clearTimeout(timer);
  }, [pulseToken, value]);

  return motion;
}

function NumberWheel({
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

function AnimatedTopGrid({ children, className }: { children: React.ReactNode; className?: string }) {
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

function useFlipList(layoutKey: string) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const previousRectsRef = useRef<Map<string, DOMRect>>(new Map());

  useLayoutEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const nextRects = new Map<string, DOMRect>();
    const nodes = Array.from(container.querySelectorAll<HTMLElement>("[data-flip-id]"));

    nodes.forEach((node) => {
      const id = node.dataset.flipId;
      if (!id) return;

      const rect = node.getBoundingClientRect();
      const previous = previousRectsRef.current.get(id);
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

function WorkspaceTabCarousel({
  activeTab,
  renderTab,
}: {
  activeTab: WorkspaceTab;
  renderTab: (tab: WorkspaceTab) => React.ReactNode;
}) {
  const [visibleTab, setVisibleTab] = useState<WorkspaceTab>(activeTab);
  const [previousTab, setPreviousTab] = useState<WorkspaceTab | null>(null);
  const [phase, setPhase] = useState<WorkspaceTabPhase>("idle");
  const [direction, setDirection] = useState<TopPanelDirection>("forward");
  const [height, setHeight] = useState<number | "auto">("auto");
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const visibleRef = useRef<HTMLDivElement | null>(null);
  const latestTabRef = useRef<WorkspaceTab>(activeTab);
  const transitionTokenRef = useRef(0);
  const timersRef = useRef<number[]>([]);
  const framesRef = useRef<number[]>([]);

  useEffect(
    () => () => {
      clearTopPanelTimers(timersRef, framesRef);
    },
    [],
  );

  useLayoutEffect(() => {
    const oldTab = latestTabRef.current;
    if (oldTab === activeTab) return;

    clearTopPanelTimers(timersRef, framesRef);

    latestTabRef.current = activeTab;
    transitionTokenRef.current += 1;

    setDirection(workspaceTabDirection(oldTab, activeTab));
    setPreviousTab(oldTab);
    setVisibleTab(activeTab);
    setPhase("swapping");
    setHeight(measureElementHeight(visibleRef.current) || measureElementHeight(viewportRef.current));
  }, [activeTab]);

  useLayoutEffect(() => {
    if (phase !== "swapping") return;

    const token = transitionTokenRef.current;
    const nextHeight = measureElementHeight(visibleRef.current);

    nextFrame(framesRef, () => {
      if (transitionTokenRef.current === token) {
        setHeight(nextHeight);
      }
    });

    later(timersRef, WORKSPACE_TAB_SLIDE_MS, () => {
      if (transitionTokenRef.current !== token) return;

      setPreviousTab(null);
      setPhase("idle");
      setHeight("auto");
    });
  }, [phase, visibleTab]);

  const showSwapping = phase === "swapping" && previousTab !== null;
  const panes =
    showSwapping && previousTab !== null
      ? direction === "forward"
        ? [
            { tab: previousTab, current: false },
            { tab: visibleTab, current: true },
          ]
        : [
            { tab: visibleTab, current: true },
            { tab: previousTab, current: false },
          ]
      : [{ tab: visibleTab, current: true }];
  const viewportStyle = {
    height: height === "auto" ? undefined : `${Math.max(height, 0)}px`,
  } as React.CSSProperties;

  return (
    <div ref={viewportRef} className="workspace-tab-viewport" data-phase={phase} style={viewportStyle}>
      <div className="workspace-tab-track" data-direction={direction} data-phase={showSwapping ? "swapping" : "idle"}>
        {panes.map(({ tab, current }) => (
          <div
            key={tab}
            ref={current ? visibleRef : undefined}
            className="workspace-tab-pane"
            data-pane={current ? "current" : "previous"}
            aria-hidden={!current}
          >
            <div className="workspace-tab-pane-inner">{renderTab(tab)}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

function StatusRail({
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
  const renderPanel = useCallback(
    (panel: TopPanelKey, interactive = true) => {
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
                    onSelectCard={interactive ? () => selectCardFromPanel(item.selection) : undefined}
                    motion={updateAnimations.motionFor(blockerUpdateKey(item))}
                  />
                ))}
              </AnimatedTopGrid>
            )}
          </TopTray>
        );
      }

      return (
        <TopTray title="Recently finished requests, slices, and work packages">
          {finishedHighlights.length === 0 ? (
            <EmptyPanel title="Nothing finished yet" compact />
          ) : (
            <FinishedHighlightsBoard
              items={finishedHighlights}
              onSelectCard={interactive ? selectCardFromPanel : undefined}
              updateAnimations={updateAnimations}
            />
          )}
        </TopTray>
      );
    },
    [blockerItems, finishedHighlights, guidanceItems, onSelectGuidance, selectCardFromPanel, updateAnimations],
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
          pulseToken={updateAnimations.countPulseFor("guidance")}
        />
        <StatusTile
          panel="blockers"
          title="Active Blockers"
          value={blockerItems.length}
          icon={<AlertTriangle className="h-6 w-6" />}
          tone="amber"
          openPanel={openPanel}
          onToggle={setOpenPanel}
          pulseToken={updateAnimations.countPulseFor("blockers")}
        />
        <StatusTile
          panel="finished"
          title="Finished"
          value={finishedHighlights.length}
          icon={<CheckCircle2 className="h-6 w-6" />}
          tone="emerald"
          openPanel={openPanel}
          onToggle={setOpenPanel}
          pulseToken={updateAnimations.countPulseFor("finished")}
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
  renderPanel: (panel: TopPanelKey, interactive?: boolean) => React.ReactNode;
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
  const showSwapping = phase === "swapping" && previousPanel !== null && visiblePanel !== null;
  const showTrackCurrent = visiblePanel !== null && !showStaticPrevious && phase !== "opening" && phase !== "closing";
  const showStaticCurrent = visiblePanel && !showStaticPrevious && !showTrackCurrent;
  const panes =
    showSwapping && previousPanel !== null && visiblePanel !== null
      ? direction === "forward"
        ? [
            { panel: previousPanel, current: false },
            { panel: visiblePanel, current: true },
          ]
        : [
            { panel: visiblePanel, current: true },
            { panel: previousPanel, current: false },
          ]
      : visiblePanel
        ? [{ panel: visiblePanel, current: true }]
        : [];
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
        {activePanel ? renderPanel(activePanel, false) : null}
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
            <div className="top-panel-pane-inner">{renderPanel(previousPanel)}</div>
          </div>
        ) : null}
        {showTrackCurrent ? (
          <div className="top-panel-track" data-direction={direction} data-phase={showSwapping ? "swapping" : "idle"}>
            {panes.map(({ panel, current }) => (
              <div
                key={panel}
                ref={current ? visibleRef : undefined}
                className="top-panel-pane"
                data-pane={current ? "current" : "previous"}
                aria-hidden={!current}
              >
                <div className="top-panel-pane-inner">{renderPanel(panel)}</div>
              </div>
            ))}
          </div>
        ) : null}
        {showStaticCurrent ? (
          <div
            ref={visibleRef}
            className="top-panel-static"
            data-motion={phase === "opening" ? "open" : phase === "closing" ? "close" : "idle"}
            data-direction={direction}
          >
            <div className="top-panel-pane-inner">{renderPanel(visiblePanel)}</div>
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
  pulseToken = 0,
}: {
  panel: TopPanelKey;
  title: string;
  value: number;
  icon: React.ReactNode;
  tone: "violet" | "amber" | "emerald";
  openPanel: TopPanelKey | null;
  onToggle: (panel: TopPanelKey | null) => void;
  pulseToken?: number;
}) {
  const open = openPanel === panel;
  const countMotion = useCountMotion(value, pulseToken);
  const tones = {
    violet: {
      card: "border-violet-300 bg-violet-50/35 dark:border-violet-700/70 dark:bg-violet-950/35",
      icon: "border-violet-200 bg-violet-50 text-violet-700 dark:border-violet-700/70 dark:bg-violet-950/70 dark:text-violet-200",
      value: "text-violet-700 dark:text-violet-200",
    },
    amber: {
      card: "border-amber-200 bg-amber-50/25 dark:border-amber-700/70 dark:bg-amber-950/30",
      icon: "border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-700/70 dark:bg-amber-950/70 dark:text-amber-200",
      value: "text-amber-700 dark:text-amber-200",
    },
    emerald: {
      card: "border-emerald-200 bg-emerald-50/25 dark:border-emerald-700/70 dark:bg-emerald-950/30",
      icon: "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-700/70 dark:bg-emerald-950/70 dark:text-emerald-200",
      value: "text-emerald-700 dark:text-emerald-200",
    },
  };

  return (
    <button
      type="button"
      className={cn(
        "dashboard-glass-surface status-tile motion-card group flex min-h-[104px] items-center justify-between rounded-lg border bg-card p-5 text-left shadow-sm outline-none transition-all hover:-translate-y-0.5 hover:shadow-dashboard focus-visible:ring-2 focus-visible:ring-ring",
        open && tones[tone].card,
      )}
      data-count-motion={countMotion.direction}
      onClick={() => onToggle(open ? null : panel)}
      aria-expanded={open}
    >
      <div className="flex items-center gap-4">
        <div className={cn("flex h-12 w-12 items-center justify-center rounded-full border", tones[tone].icon)}>{icon}</div>
        <div>
          <p className="text-base font-semibold">{title}</p>
          <p className={cn("mt-2 text-3xl font-semibold", tones[tone].value)}>
            <NumberWheel value={value} motion={countMotion} />
          </p>
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
    <Card className="dashboard-glass-surface top-tray-card overflow-hidden">
      <CardHeader className="pb-3">
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent>{children}</CardContent>
    </Card>
  );
}

function UpdateSimulationControls({ updateAnimations }: { updateAnimations: DashboardUpdateAnimations }) {
  const controls: Array<{
    kind: UpdateMotionKind;
    label: string;
    icon: React.ReactNode;
    tooltip: string;
  }> = [
    { kind: "guidance", label: "G", icon: <MessageSquareText className="h-3.5 w-3.5" />, tooltip: "Simulate new human guidance" },
    { kind: "blocker", label: "B", icon: <AlertTriangle className="h-3.5 w-3.5" />, tooltip: "Simulate a fresh blocker" },
    { kind: "finished", label: "F", icon: <CheckCircle2 className="h-3.5 w-3.5" />, tooltip: "Simulate finished work" },
    { kind: "changed", label: "U", icon: <RefreshCw className="h-3.5 w-3.5" />, tooltip: "Simulate a card update" },
  ];

  return (
    <div className="update-sim-controls" aria-label="Simulate dashboard update animations">
      {controls.map((control) => (
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

function GuidancePreviewCard({
  item,
  index,
  onSelect,
  motion,
}: {
  item: GuidanceItem;
  index: number;
  onSelect: (item: GuidanceItem) => void;
  motion?: UpdateMotion;
}) {
  const tone: StateCardTone = item.source === "guidance" ? "guidance" : "queued";

  return (
    <button
      type="button"
      className={stateCardClassName(
        tone,
        "stagger-item grid gap-4 p-4 text-left hover:border-primary/50 hover:shadow-dashboard",
      )}
      style={stateCardStyle(tone, { animationDelay: `${index * 45}ms` })}
      onClick={() => onSelect(item)}
      data-flip-id={guidanceUpdateKey(item)}
      {...updateMotionAttributes(motion)}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-violet-50 text-violet-700 dark:bg-violet-950/70 dark:text-violet-200">
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
        <AnimatedBadge
          label={item.source === "guidance" ? "Guidance" : "Clarify"}
          variant={item.source === "guidance" ? "danger" : "warning"}
        />
      </div>
    </button>
  );
}

function blockerBadgeLabel(item: BlockerItem) {
  return item.blockerCount > 1 ? `${item.blockerCount} blockers` : "Blocked";
}

function cardDetailDataKind(selection: CardDetailSelection) {
  return selection.kind;
}

function BlockerPreviewCard({
  item,
  index,
  onSelectCard,
  motion,
}: {
  item: BlockerItem;
  index: number;
  onSelectCard?: () => void;
  motion?: UpdateMotion;
}) {
  return (
    <div
      className={stateCardClassName("blocked", cn("stagger-item p-4", onSelectCard && "card-detail-trigger"))}
      style={stateCardStyle("blocked", { animationDelay: `${index * 45}ms` })}
      data-flip-id={blockerUpdateKey(item)}
      data-card-detail-kind={cardDetailDataKind(item.selection)}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{item.title}</p>
          <p className="mt-1 truncate text-xs text-muted-foreground">{item.repo}</p>
        </div>
        <AnimatedBadge label={blockerBadgeLabel(item)} variant="danger" className="shrink-0" />
      </div>
      <p className="mt-4 line-clamp-3 text-sm text-muted-foreground">{item.detail}</p>
      <div className="mt-4 flex items-center gap-2 text-xs text-amber-800 dark:text-amber-200">
        <AlertTriangle className="h-4 w-4" />
        {item.blockerCount} active blocker{item.blockerCount === 1 ? "" : "s"}
      </div>
    </div>
  );
}

const finishedHighlightLanes: { kind: FinishedHighlightKind; title: string; empty: string }[] = [
  { kind: "Request", title: "Requests", empty: "No finished requests" },
  { kind: "Slice", title: "Slices", empty: "No finished slices" },
  { kind: "Work Package", title: "Work Packages", empty: "No finished packages" },
];

function FinishedHighlightsBoard({
  items,
  onSelectCard,
  updateAnimations,
}: {
  items: FinishedHighlight[];
  onSelectCard?: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const flipRef = useFlipList(finishedHighlightsListKey(items));

  return (
    <ScrollArea className="finished-highlights-scroll pr-3" type="auto">
      <div className="finished-highlights-grid" ref={flipRef}>
        {finishedHighlightLanes.map((lane) => {
          const laneItems = items.filter((item) => item.kind === lane.kind);

          return (
            <section key={lane.kind} className="finished-mini-lane">
              <div className="finished-mini-lane-header">
                <span>{lane.title}</span>
                <span className="jira-lane-count">{laneItems.length}</span>
              </div>
              <div className="finished-mini-lane-body">
                {laneItems.length === 0 ? (
                  <div className="jira-lane-empty">{lane.empty}</div>
                ) : (
                  laneItems.map((item, index) => (
                    <FinishedHighlightCard
                      key={`${item.kind}-${item.id}`}
                      item={item}
                      index={index}
                      onSelectCard={onSelectCard ? () => onSelectCard(item.selection) : undefined}
                      motion={updateAnimations.motionFor(finishedHighlightUpdateKey(item))}
                    />
                  ))
                )}
              </div>
            </section>
          );
        })}
      </div>
    </ScrollArea>
  );
}

function FinishedHighlightCard({
  item,
  index,
  onSelectCard,
  motion,
}: {
  item: FinishedHighlight;
  index: number;
  onSelectCard?: () => void;
  motion?: UpdateMotion;
}) {
  return (
    <div
      className={stateCardClassName("finished", cn("stagger-item p-3", onSelectCard && "card-detail-trigger"))}
      style={stateCardStyle("finished", { animationDelay: `${index * 30}ms` })}
      data-flip-id={finishedHighlightUpdateKey(item)}
      data-card-detail-kind={cardDetailDataKind(item.selection)}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start gap-2">
        <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-emerald-600" />
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{item.title}</p>
          <p className="mt-1 truncate text-xs text-muted-foreground">{item.repo}</p>
        </div>
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <AnimatedBadge label={formatStatus(item.status)} variant="success" />
        {item.at ? (
          <span className="flex items-center gap-1 text-xs text-muted-foreground">
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
  activeBlockingEdges,
  onSelectGuidance,
  onSelectCard,
  layoutMode,
  updateAnimations,
}: {
  repo: RepoSummary;
  requestDetails: WorkRequestDetail[];
  activeBlockingEdges: ActiveBlockingEdge[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  layoutMode: WorkstreamLayoutMode;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const stateKey = repoWorkstreamStateKey(repo);
  const [open, setOpen] = useState(() => readStoredRepoWorkstreamOpen(stateKey, defaultRepoWorkstreamOpen(repo)));
  const repoDetails = useMemo(
    () => requestDetails.filter((detail) => repoName(detail.work_request.repo) === repo.repo),
    [repo.repo, requestDetails],
  );
  const unlinkedPackages = useMemo(
    () => repo.packages.filter((pkg) => !packageLinkedToRequest(pkg, requestDetails)),
    [repo.packages, requestDetails],
  );

  useEffect(() => {
    writeStoredRepoWorkstreamOpen(stateKey, open);
  }, [open, stateKey]);

  return (
    <Collapsible open={open} onOpenChange={setOpen}>
      <Card className="dashboard-glass-surface motion-card overflow-hidden">
        <CardHeader className="dashboard-panel-header border-b">
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
              activeBlockingEdges={activeBlockingEdges}
              onSelectGuidance={onSelectGuidance}
              onSelectCard={onSelectCard}
              layoutMode={layoutMode}
              updateAnimations={updateAnimations}
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
    { label: "Work Packages", value: repo.implementing + repo.finished, tone: "implementing" },
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

function ThemeToggle({ theme, onToggle }: { theme: DashboardTheme; onToggle: () => void }) {
  const dark = theme === "dark";
  const label = dark ? "Switch to light mode" : "Switch to dark mode";

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          type="button"
          variant="outline"
          size="icon"
          className="button-lift relative overflow-hidden"
          aria-label={label}
          onClick={onToggle}
        >
          <Sun
            className={cn(
              "absolute h-4 w-4 transition-all duration-200",
              dark ? "rotate-45 scale-0 opacity-0" : "rotate-0 scale-100 opacity-100",
            )}
          />
          <Moon
            className={cn(
              "absolute h-4 w-4 transition-all duration-200",
              dark ? "rotate-0 scale-100 opacity-100" : "-rotate-45 scale-0 opacity-0",
            )}
          />
        </Button>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
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
  const countMotion = useCountMotion(value);
  const tones: Record<typeof tone, string> = {
    requested: "border-slate-200 bg-slate-50 text-slate-700 dark:border-slate-700/70 dark:bg-slate-900/70 dark:text-slate-200",
    active: "border-cyan-200 bg-cyan-50 text-cyan-800 dark:border-cyan-700/70 dark:bg-cyan-950/50 dark:text-cyan-200",
    implementing: "border-sky-200 bg-sky-50 text-sky-700 dark:border-sky-700/70 dark:bg-sky-950/50 dark:text-sky-200",
    finished: "border-emerald-200 bg-emerald-50 text-emerald-700 dark:border-emerald-700/70 dark:bg-emerald-950/50 dark:text-emerald-200",
    guidance: "border-violet-200 bg-violet-50 text-violet-700 dark:border-violet-700/70 dark:bg-violet-950/50 dark:text-violet-200",
    blocker: "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-700/70 dark:bg-amber-950/50 dark:text-amber-200",
  };

  return (
    <div className={cn("inline-flex items-center gap-1.5 rounded-md border px-2 py-1 text-xs font-medium", tones[tone])}>
      <span className="font-semibold tabular-nums">
        <NumberWheel value={value} motion={countMotion} compact />
      </span>
      <span className="whitespace-nowrap">{label}</span>
    </div>
  );
}

function AnimatedBadge({
  label,
  variant,
  className,
}: {
  label: string;
  variant?: React.ComponentProps<typeof Badge>["variant"];
  className?: string;
}) {
  const [currentLabel, setCurrentLabel] = useState(label);
  const [previousLabel, setPreviousLabel] = useState<string | null>(null);
  const [phase, setPhase] = useState<BadgePushPhase>("idle");
  const [width, setWidth] = useState<number | null>(null);
  const badgeRef = useRef<HTMLDivElement | null>(null);
  const currentTextRef = useRef<HTMLSpanElement | null>(null);
  const measureRef = useRef<HTMLSpanElement | null>(null);
  const timersRef = useRef<number[]>([]);
  const framesRef = useRef<number[]>([]);

  useEffect(
    () => () => {
      clearTopPanelTimers(timersRef, framesRef);
    },
    [],
  );

  useLayoutEffect(() => {
    if (label === currentLabel) return;

    clearTopPanelTimers(timersRef, framesRef);

    const oldWidth = measureElementWidth(badgeRef.current);
    const oldTextWidth = measureElementWidth(currentTextRef.current);
    const chromeWidth = Math.max(0, oldWidth - oldTextWidth);

    setPreviousLabel(currentLabel);
    setCurrentLabel(label);
    setPhase("measure");
    setWidth(oldWidth);

    nextFrame(framesRef, () => {
      const newTextWidth = measureElementWidth(measureRef.current);
      const newWidth = Math.ceil(newTextWidth + chromeWidth);
      const wider = newWidth > oldWidth + 1;

      if (wider) {
        setPhase("resize-first");
        setWidth(newWidth);

        later(timersRef, BADGE_RESIZE_MS, () => {
          setPhase("push");
          later(timersRef, BADGE_TEXT_PUSH_MS, () => settleAnimatedBadge(setPhase, setPreviousLabel, setWidth));
        });
      } else {
        setPhase("push");

        later(timersRef, BADGE_TEXT_PUSH_MS, () => {
          setPhase("resize-last");
          setWidth(newWidth);
          later(timersRef, BADGE_RESIZE_MS, () => settleAnimatedBadge(setPhase, setPreviousLabel, setWidth));
        });
      }
    });
  }, [currentLabel, label]);

  return (
    <Badge
      ref={badgeRef}
      variant={variant}
      className={cn("state-update-badge", className)}
      data-badge-phase={phase}
      data-badge-has-previous={previousLabel ? "true" : "false"}
      style={width === null ? undefined : { width: `${Math.max(width, 0)}px` }}
    >
      <span ref={measureRef} className="badge-push-measure">
        {currentLabel}
      </span>
      <span className="badge-push-stack">
        {previousLabel ? <span className="badge-push-old">{previousLabel}</span> : null}
        <span ref={currentTextRef} className="badge-push-new">
          {currentLabel}
        </span>
      </span>
    </Badge>
  );
}

function settleAnimatedBadge(
  setPhase: React.Dispatch<React.SetStateAction<BadgePushPhase>>,
  setPreviousLabel: React.Dispatch<React.SetStateAction<string | null>>,
  setWidth: React.Dispatch<React.SetStateAction<number | null>>,
) {
  setPreviousLabel(null);
  setPhase("idle");
  setWidth(null);
}

function stateCardClassName(tone: StateCardTone, className?: string) {
  return cn(
    "min-w-0 max-w-full rounded-lg border border-l-4 shadow-sm transition-[background-color,border-color,box-shadow,transform] duration-150 ease-out",
    STATE_CARD_TONES[tone].card,
    className,
  );
}

function stateCardStyle(tone: StateCardTone, style?: React.CSSProperties) {
  return { ...style, "--state-accent": STATE_CARD_TONES[tone].accent, borderLeftColor: STATE_CARD_TONES[tone].accent } as React.CSSProperties;
}

function wireToneStyle(tone: BoardWireTone) {
  return { "--wire-color": STATE_CARD_TONES[tone].accent } as React.CSSProperties;
}

function WorkstreamBoard({
  repoDetails,
  packages,
  unlinkedPackages,
  activeBlockingEdges,
  onSelectGuidance,
  onSelectCard,
  layoutMode,
  updateAnimations,
}: {
  repoDetails: WorkRequestDetail[];
  packages: WorkPackageCard[];
  unlinkedPackages: WorkPackageCard[];
  activeBlockingEdges: ActiveBlockingEdge[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  layoutMode: WorkstreamLayoutMode;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const boardRef = useRef<HTMLDivElement | null>(null);
  const sortedDetails = useMemo(() => sortWorkRequestDetails(repoDetails), [repoDetails]);
  const requested = sortedDetails;
  const packageById = useMemo(() => new Map(packages.map((pkg) => [pkg.id, pkg])), [packages]);
  const sliceEntries = useMemo(
    () =>
      sortedDetails.flatMap((detail, requestIndex) =>
        (detail.planned_slices ?? []).map((slice) => ({
          detail,
          slice,
          pkg: slice.work_package_id ? packageById.get(slice.work_package_id) : undefined,
          requestIndex,
        })),
      ),
    [packageById, sortedDetails],
  );
  const active = useMemo(() => sliceEntries.filter((entry) => sliceLane(entry.slice) === "slices"), [sliceEntries]);
  const implementing = useMemo(() => sliceEntries.filter((entry) => sliceLane(entry.slice) === "implementing"), [sliceEntries]);
  const finished = useMemo(() => sliceEntries.filter((entry) => sliceLane(entry.slice) === "finished"), [sliceEntries]);
  const sortedUnlinkedPackages = useMemo(() => sortPackages(unlinkedPackages), [unlinkedPackages]);
  const activePackages = useMemo(() => sortedUnlinkedPackages.filter((pkg) => packageLane(pkg) === "slices"), [sortedUnlinkedPackages]);
  const implementingPackages = useMemo(
    () => sortedUnlinkedPackages.filter((pkg) => packageLane(pkg) === "implementing"),
    [sortedUnlinkedPackages],
  );
  const finishedPackages = useMemo(() => sortedUnlinkedPackages.filter((pkg) => packageLane(pkg) === "finished"), [sortedUnlinkedPackages]);
  const alignedRows = useMemo(
    () => workstreamRows(sortedDetails, sliceEntries, activePackages, implementingPackages, finishedPackages),
    [activePackages, finishedPackages, implementingPackages, sliceEntries, sortedDetails],
  );
  const rowTemplate = useAlignedRowTemplate(boardRef, alignedRows, layoutMode);
  const wires = useMemo(() => workstreamWires(sortedDetails, packages, activeBlockingEdges), [activeBlockingEdges, sortedDetails, packages]);
  const { paths: wirePaths, size: wireSize } = useBoardWirePaths(boardRef, wires, layoutMode);

  return (
    <div className="workstream-board-shell">
      <div
        ref={boardRef}
        className={cn("jira-board workstream-board", layoutMode === "aligned" && "workstream-board-aligned")}
        data-layout={layoutMode}
      >
        <BoardWireLayer paths={wirePaths} width={wireSize.width} height={wireSize.height} />
        {layoutMode === "aligned" ? (
          <AlignedWorkstreamColumns
            rows={alignedRows}
            rowTemplate={rowTemplate}
            requestedCount={requested.length}
            sliceCount={active.length + activePackages.length}
            workPackageCount={implementing.length + finished.length + implementingPackages.length + finishedPackages.length}
            onSelectGuidance={onSelectGuidance}
            onSelectCard={onSelectCard}
            updateAnimations={updateAnimations}
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
            onSelectCard={onSelectCard}
            updateAnimations={updateAnimations}
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
  onSelectCard,
  updateAnimations,
}: {
  requested: WorkRequestDetail[];
  active: SliceEntry[];
  implementing: SliceEntry[];
  finished: SliceEntry[];
  activePackages: WorkPackageCard[];
  implementingPackages: WorkPackageCard[];
  finishedPackages: WorkPackageCard[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  return (
    <>
      <BoardLaneColumn title="Requests" count={requested.length} emptyLabel="No requested work">
        {requested.map((detail, index) => (
          <RequestCard
            key={detail.work_request.id}
            detail={detail}
            onSelectGuidance={onSelectGuidance}
            onSelectCard={() => onSelectCard({ kind: "request", detail })}
            index={index}
            nodeId={requestNodeId(detail)}
            motion={updateAnimations.motionFor(requestUpdateKey(detail))}
          />
        ))}
      </BoardLaneColumn>
      <BoardLaneColumn title="Slices" count={active.length + activePackages.length} emptyLabel="No slices ready">
        {active.map(({ detail, slice, pkg }, index) => (
          <SliceCard
            key={slice.id}
            slice={slice}
            pkg={pkg}
            lane="slices"
            index={index}
            nodeId={sliceNodeId(slice)}
            onSelectCard={() => onSelectCard({ kind: "slice", detail, slice, pkg })}
            motion={updateAnimations.motionFor(sliceUpdateKey(slice))}
          />
        ))}
        {activePackages.length > 0 ? <LaneGroupLabel label="Unlinked packages" /> : null}
        {activePackages.map((pkg, index) => (
          <PackageCard
            key={pkg.id}
            pkg={pkg}
            lane="slices"
            index={active.length + index}
            nodeId={packageNodeId(pkg)}
            onSelectCard={() => onSelectCard({ kind: "package", pkg })}
            motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
          />
        ))}
      </BoardLaneColumn>
      <BoardLaneColumn title="Work Packages" count={implementing.length + finished.length + implementingPackages.length + finishedPackages.length} emptyLabel="No work packages yet">
        {implementing.map(({ detail, slice, pkg }, index) => (
          <SliceCard
            key={slice.id}
            slice={slice}
            pkg={pkg}
            lane="implementing"
            index={index}
            nodeId={pkg ? packageNodeId(pkg) : sliceNodeId(slice)}
            onSelectCard={() => onSelectCard(pkg ? { kind: "package", pkg, detail, slice } : { kind: "slice", detail, slice })}
            motion={updateAnimations.motionFor(pkg ? packageUpdateKey(pkg) : sliceUpdateKey(slice))}
          />
        ))}
        {finished.map(({ detail, slice, pkg }, index) => (
          <SliceCard
            key={slice.id}
            slice={slice}
            pkg={pkg}
            lane="finished"
            index={implementing.length + index}
            nodeId={pkg ? packageNodeId(pkg) : sliceNodeId(slice)}
            onSelectCard={() => onSelectCard(pkg ? { kind: "package", pkg, detail, slice } : { kind: "slice", detail, slice })}
            motion={updateAnimations.motionFor(pkg ? packageUpdateKey(pkg) : sliceUpdateKey(slice))}
          />
        ))}
        {implementingPackages.length + finishedPackages.length > 0 ? <LaneGroupLabel label="Unlinked packages" /> : null}
        {implementingPackages.map((pkg, index) => (
          <PackageCard
            key={pkg.id}
            pkg={pkg}
            lane="implementing"
            index={implementing.length + finished.length + index}
            nodeId={packageNodeId(pkg)}
            onSelectCard={() => onSelectCard({ kind: "package", pkg })}
            motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
          />
        ))}
        {finishedPackages.map((pkg, index) => (
          <PackageCard
            key={pkg.id}
            pkg={pkg}
            lane="finished"
            index={implementing.length + finished.length + implementingPackages.length + index}
            nodeId={packageNodeId(pkg)}
            onSelectCard={() => onSelectCard({ kind: "package", pkg })}
            motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
          />
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
  workPackageCount,
  onSelectGuidance,
  onSelectCard,
  updateAnimations,
}: {
  rows: WorkstreamRow[];
  rowTemplate: string;
  requestedCount: number;
  sliceCount: number;
  workPackageCount: number;
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const rowStyle = { gridTemplateRows: rowTemplate } as React.CSSProperties;

  return (
    <>
      <BoardLaneColumn title="Requests" count={requestedCount} emptyLabel="No requested work" bodyStyle={rowStyle} aligned>
        {rows.map((row, index) => (
          <FeatureLaneRow key={workstreamRowKey(row, index)} row={row} lane="requested" index={index}>
            {row.detail ? (
              <RequestCard
                detail={row.detail}
                onSelectGuidance={onSelectGuidance}
                onSelectCard={() => onSelectCard({ kind: "request", detail: row.detail! })}
                index={index}
                nodeId={requestNodeId(row.detail)}
                motion={updateAnimations.motionFor(requestUpdateKey(row.detail))}
              />
            ) : null}
          </FeatureLaneRow>
        ))}
      </BoardLaneColumn>
      <BoardLaneColumn title="Slices" count={sliceCount} emptyLabel="No slices ready" bodyStyle={rowStyle} aligned>
        {rows.map((row, index) => (
          <FeatureLaneRow key={workstreamRowKey(row, index)} row={row} lane="slices" index={index}>
            {row.active.map(({ detail, slice, pkg }, sliceIndex) => (
              <SliceCard
                key={slice.id}
                slice={slice}
                pkg={pkg}
                lane="slices"
                index={sliceIndex}
                nodeId={sliceNodeId(slice)}
                onSelectCard={() => onSelectCard({ kind: "slice", detail, slice, pkg })}
                motion={updateAnimations.motionFor(sliceUpdateKey(slice))}
              />
            ))}
            {row.activePackages.length > 0 ? <LaneGroupLabel label="Unlinked packages" /> : null}
            {row.activePackages.map((pkg, packageIndex) => (
              <PackageCard
                key={pkg.id}
                pkg={pkg}
                lane="slices"
                index={row.active.length + packageIndex}
                nodeId={packageNodeId(pkg)}
                onSelectCard={() => onSelectCard({ kind: "package", pkg })}
                motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
              />
            ))}
          </FeatureLaneRow>
        ))}
      </BoardLaneColumn>
      <BoardLaneColumn title="Work Packages" count={workPackageCount} emptyLabel="No work packages yet" bodyStyle={rowStyle} aligned>
        {rows.map((row, index) => (
          <FeatureLaneRow key={workstreamRowKey(row, index)} row={row} lane="packages" index={index}>
            {row.implementing.map(({ detail, slice, pkg }, sliceIndex) => (
              <SliceCard
                key={slice.id}
                slice={slice}
                pkg={pkg}
                lane="implementing"
                index={sliceIndex}
                nodeId={pkg ? packageNodeId(pkg) : sliceNodeId(slice)}
                onSelectCard={() => onSelectCard(pkg ? { kind: "package", pkg, detail, slice } : { kind: "slice", detail, slice })}
                motion={updateAnimations.motionFor(pkg ? packageUpdateKey(pkg) : sliceUpdateKey(slice))}
              />
            ))}
            {row.finished.map(({ detail, slice, pkg }, sliceIndex) => (
              <SliceCard
                key={slice.id}
                slice={slice}
                pkg={pkg}
                lane="finished"
                index={row.implementing.length + sliceIndex}
                nodeId={pkg ? packageNodeId(pkg) : sliceNodeId(slice)}
                onSelectCard={() => onSelectCard(pkg ? { kind: "package", pkg, detail, slice } : { kind: "slice", detail, slice })}
                motion={updateAnimations.motionFor(pkg ? packageUpdateKey(pkg) : sliceUpdateKey(slice))}
              />
            ))}
            {row.implementingPackages.length + row.finishedPackages.length > 0 ? <LaneGroupLabel label="Unlinked packages" /> : null}
            {row.implementingPackages.map((pkg, packageIndex) => (
              <PackageCard
                key={pkg.id}
                pkg={pkg}
                lane="implementing"
                index={row.implementing.length + row.finished.length + packageIndex}
                nodeId={packageNodeId(pkg)}
                onSelectCard={() => onSelectCard({ kind: "package", pkg })}
                motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
              />
            ))}
            {row.finishedPackages.map((pkg, packageIndex) => (
              <PackageCard
                key={pkg.id}
                pkg={pkg}
                lane="finished"
                index={row.implementing.length + row.finished.length + row.implementingPackages.length + packageIndex}
                nodeId={packageNodeId(pkg)}
                onSelectCard={() => onSelectCard({ kind: "package", pkg })}
                motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
              />
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
  lane: FeatureLane;
  index: number;
  children: React.ReactNode;
}) {
  const renderedChildren = Children.toArray(children);
  const empty = renderedChildren.length === 0;

  return (
    <div className="feature-lane-row" data-feature-row={workstreamRowKey(row, index)} data-lane={lane} data-empty={empty ? "true" : undefined}>
      {renderedChildren}
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
            <circle className="board-wire-node board-wire-node-target" cx={wire.targetX} cy={wire.targetY} r={wire.kind === "blocker" ? 4.5 : 4} />
          </g>
        ))}
      </svg>
    </>
  );
}

function useBoardWirePaths(boardRef: React.RefObject<HTMLDivElement | null>, wires: BoardWire[], measureKey: string) {
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

function useAlignedRowTemplate(boardRef: React.RefObject<HTMLDivElement | null>, rows: WorkstreamRow[], layoutMode: WorkstreamLayoutMode) {
  const baseHeights = useMemo(() => rows.map((row) => row.minHeight), [rows]);
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

  const measuredWires = wires.flatMap<MeasuredBoardWire>((wire) => {
    const source = nodes.get(wire.from);
    const target = nodes.get(wire.to);
    if (!source || !target) return [];

    const sourceLane = lanes.findIndex((lane) => lane.node.contains(source));
    const targetLane = lanes.findIndex((lane) => lane.node.contains(target));
    if (sourceLane < 0 || targetLane < 0) return [];

    const sourceRect = layoutRectWithinBoard(source, board);
    const targetRect = layoutRectWithinBoard(target, board);
    const forward = targetLane >= sourceLane;
    const sourceX = forward ? sourceRect.x + sourceRect.width : sourceRect.x;
    const targetX = forward ? targetRect.x : targetRect.x + targetRect.width;
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
        trackX: defaultBoardWireTrackX(sourceX, targetX),
        trackIndex: 0,
        trackCount: 1,
        trackSide: "source",
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
      hiddenRects: skippedLaneRects(wire.source, wire.target, lanes),
    })),
  };
}

function applyBoardWireAnchorSlots(wires: MeasuredBoardWire[]) {
  const next = wires.map((wire) => ({ ...wire }));

  groupedWires(next, (wire) => wire.from).forEach((group) => {
    if (group.length <= 1) return;
    [...group]
      .sort((left, right) => left.targetY - right.targetY)
      .forEach((wire, index) => {
        wire.sourceY = edgeSlotY(wire.sourceRect, index, group.length);
      });
  });

  groupedWires(next, (wire) => wire.to).forEach((group) => {
    if (group.length <= 1) return;
    [...group]
      .sort((left, right) => left.sourceY - right.sourceY)
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
    if (gapIndex < 0 || gapIndex >= lanes.length - 1) return;
    const key = `${gapIndex}:${wire.from}`;
    fanoutSources.set(key, (fanoutSources.get(key) || 0) + 1);
  });
  fanoutSources.forEach((count, key) => {
    if (count > 1) fanoutGaps.add(Number(key.split(":")[0]));
  });

  wires.forEach((wire) => {
    const gapIndex = primaryBoardWireGapIndex(wire);
    if (gapIndex < 0 || gapIndex >= lanes.length - 1) return;

    wire.trackSide = fanoutGaps.has(gapIndex) ? "spread" : boardWireTrackSide(wire);
    const key = `${gapIndex}:${wire.trackSide}`;
    const group = groups.get(key) || [];
    group.push(wire);
    groups.set(key, group);
  });

  groups.forEach((group) => {
    const tracks: number[] = [];
    const sorted = [...group].sort((left, right) => {
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
  const sorted = [...wires]
    .sort((left, right) => {
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

  if (wires.length > 8) {
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

  while (improved) {
    improved = false;
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

    const indices = [...new Set(group.map((wire) => wire.trackIndex))].sort((left, right) => left - right);
    if (indices.length <= 1) return;
    const sample = group[0];

    if (sample.trackSide === "spread") {
      const trackCount = group.length;
      const leftToRight = Array.from({ length: trackCount }, (_, index) => index);
      const rightToLeft = [...leftToRight].reverse();
      const forward = sample.targetLane >= sample.sourceLane;
      const aboveSource = [...group].filter((wire) => wire.targetY < wire.sourceY).sort((left, right) => left.targetY - right.targetY);
      const belowSource = [...group].filter((wire) => wire.targetY >= wire.sourceY).sort((left, right) => left.targetY - right.targetY);
      const aboveIndices = (forward ? leftToRight : rightToLeft).slice(0, aboveSource.length);
      const belowIndices = (forward ? rightToLeft : leftToRight).slice(0, belowSource.length);

      aboveSource.forEach((wire, index) => {
        wire.trackCount = Math.max(wire.trackCount, trackCount);
        wire.trackIndex = aboveIndices[index] ?? wire.trackIndex;
      });
      belowSource.forEach((wire, index) => {
        wire.trackCount = Math.max(wire.trackCount, trackCount);
        wire.trackIndex = belowIndices[index] ?? wire.trackIndex;
      });
      return;
    }

    const indicesFromOutsideIn = indices.sort((left, right) => {
      const leftDistance = Math.abs(boardWireTrackX(sample, lanes, left) - sample.sourceX);
      const rightDistance = Math.abs(boardWireTrackX(sample, lanes, right) - sample.sourceX);
      return rightDistance - leftDistance;
    });

    [...group]
      .sort((left, right) => {
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
  return wire.targetY >= wire.sourceY ? "source" : "target";
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
  const sourceSideIsStart = forward;
  const useSourceSide = wire.trackSide === "source";
  const preferStart = useSourceSide ? sourceSideIsStart : !sourceSideIsStart;
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

function boardWirePath(sourceX: number, sourceY: number, targetX: number, targetY: number, trackX = defaultBoardWireTrackX(sourceX, targetX), maxRadius = 14) {
  const deltaX = targetX - sourceX;
  if (Math.abs(deltaX) <= 24 || Math.abs(targetY - sourceY) < 2) {
    return `M ${sourceX} ${sourceY} H ${targetX}`;
  }

  const xTurn = deltaX >= 0 ? 1 : -1;
  const yTurn = targetY >= sourceY ? 1 : -1;
  const minBendX = Math.min(sourceX, targetX) + 10;
  const maxBendX = Math.max(sourceX, targetX) - 10;
  const bendX = clampNumber(trackX, minBendX, maxBendX);
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

function interactiveCardProps(onSelect?: () => void) {
  if (!onSelect) return {};

  return {
    role: "button",
    tabIndex: 0,
    onClick: onSelect,
    onKeyDown: (event: React.KeyboardEvent<HTMLDivElement>) => {
      if (event.target !== event.currentTarget) return;
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        onSelect();
      }
    },
  };
}

function RequestCard({
  detail,
  onSelectGuidance,
  onSelectCard,
  index = 0,
  nodeId,
  motion,
}: {
  detail: WorkRequestDetail;
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard?: () => void;
  index?: number;
  nodeId?: string;
  motion?: UpdateMotion;
}) {
  const request = detail.work_request;
  const openQuestions = detail.clarification_questions?.filter((question) => question.status === "open") ?? [];
  const questionCount = openQuestions.length || request.open_question_count || 0;
  const question = openQuestions[0];
  const answerQuestion = question
    ? (event: React.MouseEvent<HTMLButtonElement>) => {
        event.stopPropagation();
        onSelectGuidance(clarificationGuidanceItem(detail, question));
      }
    : undefined;
  const tone = requestCardTone(detail, questionCount);

  return (
    <div
      className={stateCardClassName(tone, cn("stagger-item p-3", onSelectCard && "card-detail-trigger"))}
      data-wire-id={nodeId}
      data-card-detail-kind="request"
      style={stateCardStyle(tone, { animationDelay: `${index * 30}ms` })}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{request.title || request.id}</p>
          <p className="mt-1 text-xs text-muted-foreground">{request.work_type || "feature"}</p>
        </div>
        <AnimatedBadge label={formatStatus(request.status)} variant={requestStatusVariant(request.status)} className="shrink-0" />
      </div>
      {questionCount > 0 ? (
        <CardSignal
          className="mt-3"
          label="Open Questions"
          value={String(questionCount)}
          tone="danger"
          onClick={answerQuestion}
          ariaLabel={question ? `Answer open question for ${request.title || request.id}` : undefined}
        />
      ) : null}
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
  onSelectCard,
  motion,
}: {
  slice: PlannedSlice;
  pkg?: WorkPackageCard;
  lane: BoardLane;
  index?: number;
  nodeId?: string;
  onSelectCard?: () => void;
  motion?: UpdateMotion;
}) {
  const tone = sliceCardTone(slice, pkg, lane);
  const detail = slice.goal || pkg?.kind || slice.work_package_kind;

  return (
    <div
      className={stateCardClassName(tone, cn("stagger-item p-3", onSelectCard && "card-detail-trigger"))}
      data-wire-id={nodeId}
      data-card-detail-kind={pkg && lane !== "slices" ? "package" : "slice"}
      style={stateCardStyle(tone, { animationDelay: `${index * 30}ms` })}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <p className="min-w-0 truncate text-sm font-medium">{slice.title || pkg?.title || slice.id}</p>
        <AnimatedBadge
          label={statusLabel(slice.work_package_status || slice.status)}
          variant={statusVariant(slice.work_package_status || slice.status)}
          className="shrink-0"
        />
      </div>
      {detail ? <p className="mt-2 line-clamp-2 text-xs text-muted-foreground">{detail}</p> : null}
    </div>
  );
}

function PackageCard({
  pkg,
  lane,
  index = 0,
  nodeId,
  onSelectCard,
  motion,
}: {
  pkg: WorkPackageCard;
  lane: BoardLane;
  index?: number;
  nodeId?: string;
  onSelectCard?: () => void;
  motion?: UpdateMotion;
}) {
  const tone = packageCardTone(pkg, lane);
  const attention = packageAttentionSignal(pkg);

  return (
    <div
      className={stateCardClassName(tone, cn("stagger-item p-3", onSelectCard && "card-detail-trigger"))}
      data-wire-id={nodeId}
      data-card-detail-kind="package"
      style={stateCardStyle(tone, { animationDelay: `${index * 30}ms` })}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <p className="min-w-0 truncate text-sm font-medium">{pkg.title || pkg.id}</p>
        <AnimatedBadge label={statusLabel(pkg.status)} variant={statusVariant(pkg.status)} className="shrink-0" />
      </div>
      {attention ? <CardSignal className="mt-3" label={attention.label} value={attention.value} tone={attention.tone} /> : null}
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
  onClick?: (event: React.MouseEvent<HTMLButtonElement>) => void;
  ariaLabel?: string;
}) {
  const toneClasses: Record<SignalTone, string> = {
    muted: "border-transparent bg-muted text-foreground",
    info: "border-sky-200 bg-sky-50 text-sky-800 dark:border-sky-700/70 dark:bg-sky-950/50 dark:text-sky-200",
    warning: "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-700/70 dark:bg-amber-950/50 dark:text-amber-200",
    danger: "border-rose-200 bg-rose-50 text-rose-800 dark:border-rose-700/70 dark:bg-rose-950/50 dark:text-rose-200",
    success: "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-700/70 dark:bg-emerald-950/50 dark:text-emerald-200",
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
      <button type="button" className={signalClassName} onClick={onClick} aria-label={ariaLabel} data-card-signal>
        {content}
      </button>
    );
  }

  return (
    <div className={signalClassName} data-card-signal>
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

function packageAttentionSignal(pkg: WorkPackageCard): { label: string; value: string; tone: SignalTone } | null {
  const blockerCount = pkg.active_blocker_count || 0;

  if (blockerCount > 0 || pkg.status === "blocked") {
    return { label: "Blockers", value: `${blockerCount || 1} ${plural("blocker", blockerCount || 1)}`, tone: "danger" };
  }

  return null;
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
    return packageReviewSignal(pkg) || { label: "Review", value: "Reviewing", tone: "info" };
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
  const progressSignal = reviewPayloadSignal(pkg.metadata?.review_progress);
  const resultSignal = reviewPayloadSignal(pkg.metadata?.review_suite_result) || reviewPackageSignal(pkg.metadata?.review_package);

  return pkg.status === "reviewing" ? progressSignal || resultSignal : resultSignal || progressSignal;
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

  const lane = payload.profile || payload.mode || payload.lane || payload.review_lane || payload.suite;
  const stage = reviewStageLabel(payload);
  if (!lane && !stage) return null;

  const state = reviewState(payload.verdict || payload.status);
  const tone: SignalTone = state === "green" ? "success" : state === "failed" ? "danger" : "info";
  const suffix = state === "green" ? "Green" : state === "failed" ? "Failed" : "Pending";
  const label = lane ? reviewLaneLabel(lane) : "Review";
  const value = stage ? `${label} ${stage}` : `${label} ${suffix}`;

  return { label: "Review", value, tone, rank: lane ? reviewLaneRank(lane) : -1 };
}

function reviewState(value?: string) {
  const normalized = value?.trim().toLowerCase();
  if (["green", "clean", "passed", "pass"].includes(normalized || "")) return "green";
  if (["red", "failed", "fail", "findings"].includes(normalized || "")) return "failed";
  return "pending";
}

function reviewLaneLabel(lane: string) {
  switch (normalizeReviewLane(lane)) {
    case "brief":
      return "Brief";
    case "normal":
      return "Normal";
    case "deep":
      return "Deep";
    case "emergency":
      return "Emergency";
    case "review_deslop":
      return "Review-Deslop";
    case "review_github":
      return "Review-GitHub";
    default:
      return formatStatus(lane);
  }
}

function reviewLaneRank(lane: string) {
  return ["review_deslop", "brief", "normal", "deep", "emergency", "review_github"].indexOf(normalizeReviewLane(lane));
}

function normalizeReviewLane(lane: string) {
  const normalized = lane.trim().toLowerCase().replace(/-/g, "_");

  switch (normalized) {
    case "review_t1":
    case "t1":
    case "review_brief":
      return "brief";
    case "review_t2":
    case "t2":
    case "review_normal":
      return "normal";
    case "review_deep":
      return "deep";
    case "review_emergency":
      return "emergency";
    default:
      return normalized;
  }
}

function reviewStageLabel(payload: NonNullable<WorkPackageCard["metadata"]>["review_suite_result"]) {
  const current = numericPayloadValue(payload?.step_current);
  const total = numericPayloadValue(payload?.step_total);

  if (current && total) return `${current}/${total}`;
  if (payload?.step_name) return formatStatus(payload.step_name);
  return null;
}

function numericPayloadValue(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) return value;

  if (typeof value === "string") {
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
  }

  return null;
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

function SoloSessions({
  sessions,
  onSelectCard,
  updateAnimations,
}: {
  sessions: SoloSession[];
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  if (sessions.length === 0) {
    return <EmptyPanel title="No solo sessions" />;
  }

  return (
    <div className="grid gap-5">
      {soloSessionGroups(sessions).map((group) => (
        <SoloSessionGroup key={`${group.repo}:${group.baseBranch}`} group={group} onSelectCard={onSelectCard} updateAnimations={updateAnimations} />
      ))}
    </div>
  );
}

function SoloSessionGroup({
  group,
  onSelectCard,
  updateAnimations,
}: {
  group: {
    repo: string;
    baseBranch: string;
    active: SoloSession[];
    finished: SoloSession[];
    guidanceCount: number;
    blockerCount: number;
  };
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  return (
    <Card className="dashboard-glass-surface motion-card overflow-hidden">
      <CardHeader className="dashboard-panel-header border-b">
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
        <div className="solo-board-shell">
          <div className="jira-board jira-board-solo">
            <SoloSessionLane
              title="Active"
              sessions={group.active}
              emptyLabel="No active solo sessions"
              onSelectCard={onSelectCard}
              updateAnimations={updateAnimations}
            />
            <SoloSessionLane
              title="Finished"
              sessions={group.finished}
              emptyLabel="No finished solo sessions"
              onSelectCard={onSelectCard}
              updateAnimations={updateAnimations}
            />
          </div>
        </div>
      </CardContent>
    </Card>
  );
}

function SoloSessionLane({
  title,
  sessions,
  emptyLabel,
  onSelectCard,
  updateAnimations,
}: {
  title: string;
  sessions: SoloSession[];
  emptyLabel: string;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  return (
    <BoardLaneColumn title={title} count={sessions.length} emptyLabel={emptyLabel}>
      {sessions.map((session, index) => (
        <SoloSessionCard
          key={session.id}
          session={session}
          index={index}
          onSelectCard={() => onSelectCard({ kind: "solo", session })}
          motion={updateAnimations.motionFor(soloSessionUpdateKey(session))}
        />
      ))}
    </BoardLaneColumn>
  );
}

function SoloSessionCard({
  session,
  index,
  onSelectCard,
  motion,
}: {
  session: SoloSession;
  index: number;
  onSelectCard: () => void;
  motion?: UpdateMotion;
}) {
  const attention = soloSessionAttention(session);
  const latest = session.latest_entry;
  const latestText = latest?.title || latest?.body;
  const latestSignalValue = latest?.status ? formatStatus(latest.status) : latestText;
  const tone = soloSessionCardTone(session);
  const showLatest = latest && latestText && !soloSessionLatestIsRedundant(session, latestText);

  return (
    <div
      className={stateCardClassName(tone, "stagger-item card-detail-trigger p-3")}
      style={stateCardStyle(tone, { animationDelay: `${index * 35}ms` })}
      data-card-detail-kind="solo"
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{session.title || session.id}</p>
          <p className="mt-1 truncate text-xs text-muted-foreground">{session.caller_id || "Solo session"}</p>
        </div>
        <AnimatedBadge label={formatStatus(session.status)} variant={soloSessionStatusVariant(session.status)} className="shrink-0" />
      </div>

      {attention.guidanceCount > 0 || attention.blockerCount > 0 ? (
        <div className="mt-3 flex flex-wrap gap-1.5">
          {attention.guidanceCount > 0 ? <RepoSummaryPlate label="Guidance Needed" value={attention.guidanceCount} tone="guidance" /> : null}
          {attention.blockerCount > 0 ? <RepoSummaryPlate label="Active Blockers" value={attention.blockerCount} tone="blocker" /> : null}
        </div>
      ) : latestSignalValue ? (
        <CardSignal className="mt-3" label={soloSessionLatestSignalLabel(session)} value={latestSignalValue} tone={soloSessionLatestSignalTone(session)} />
      ) : null}

      {showLatest ? (
        <>
          <Separator className="my-3" />
          <div className="flex min-w-0 items-start gap-2">
            <Badge variant="secondary" className="shrink-0">
              {latest.kind_label || formatStatus(latest.kind)}
            </Badge>
            <p className="line-clamp-2 min-w-0 text-sm text-muted-foreground">{latestText}</p>
          </div>
        </>
      ) : null}

      <p className="mt-3 text-xs text-muted-foreground">Updated {detailDate(session.last_activity_at || session.updated_at || session.inserted_at)}</p>
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

function soloSessionLatestIsRedundant(session: SoloSession, latestText: string) {
  const title = session.title?.trim().toLowerCase();
  const latest = latestText.trim().toLowerCase();
  return !latest || Boolean(title && (latest === title || latest.includes(title)));
}

function sortSoloEntries(entries: SoloSessionEntry[]) {
  return [...entries].sort((left, right) => {
    const leftSequence = left.sequence ?? 0;
    const rightSequence = right.sequence ?? 0;
    if (leftSequence !== rightSequence) return leftSequence - rightSequence;
    return sortableTime(left.created_at || left.updated_at) - sortableTime(right.created_at || right.updated_at);
  });
}

function latestSoloEntries(entries: SoloSessionEntry[]) {
  return [...entries]
    .sort((left, right) => {
      const timeDelta = sortableTime(right.created_at || right.updated_at) - sortableTime(left.created_at || left.updated_at);
      if (timeDelta !== 0) return timeDelta;
      return (right.sequence ?? 0) - (left.sequence ?? 0);
    })
    .slice(0, 3);
}

function soloEntriesByKind(entries: SoloSessionEntry[], kinds: string[]) {
  return entries.filter((entry) => kinds.includes(entry.kind || ""));
}

function soloPlanningGroups(entries: SoloSessionEntry[]) {
  const grouped = new Map<string, SoloSessionEntry[]>();

  entries.forEach((entry) => {
    const kind = entry.kind || "progress";
    grouped.set(kind, [...(grouped.get(kind) || []), entry]);
  });

  return [...grouped.entries()]
    .sort(([left], [right]) => soloEntryKindRank(left) - soloEntryKindRank(right))
    .map(([kind, groupEntries]) => ({
      kind,
      title: soloPlanningTitle(kind),
      entries: sortSoloEntries(groupEntries),
    }));
}

function soloEntryKindRank(kind: string) {
  const order = ["task_plan", "finding", "progress", "decision", "blocker", "validation_note"];
  const index = order.indexOf(kind);
  return index === -1 ? order.length : index;
}

function soloPlanningTitle(kind: string) {
  const titles: Record<string, string> = {
    task_plan: "Task Plan",
    finding: "Findings",
    progress: "Progress",
    decision: "Decisions",
    blocker: "Blockers",
    validation_note: "Validation Notes",
  };

  return titles[kind] || formatStatus(kind);
}

function soloPlanningMeta(groups: Array<{ entries: SoloSessionEntry[] }>, loading: boolean, error: string | null) {
  if (loading) return "Loading";
  if (error) return "Unavailable";

  const count = groups.reduce((total, group) => total + group.entries.length, 0);
  return count === 1 ? "1 entry" : `${count} entries`;
}

function soloSessionAttentionText(attention: { guidanceCount: number; blockerCount: number }) {
  const parts = [];
  if (attention.blockerCount > 0) parts.push(`${attention.blockerCount} blocker${attention.blockerCount === 1 ? "" : "s"}`);
  if (attention.guidanceCount > 0) parts.push(`${attention.guidanceCount} guidance`);
  return parts.length > 0 ? parts.join(" / ") : "Clear";
}

function soloSessionPurpose(session: SoloSession, entries: SoloSessionEntry[]) {
  const planEntry = soloEntriesByKind(entries, ["task_plan"])[0];
  const planBody = markdownSummary(planEntry?.body);
  const latestBody = markdownSummary(session.latest_entry?.body);

  return firstSentence(planBody) || firstSentence(latestBody) || session.title || "No Solo Session purpose has been recorded yet.";
}

function soloEntrySummary(entry: SoloSessionEntry) {
  return firstSentence(markdownSummary(entry.body));
}

function markdownSummary(value?: string | null) {
  if (!value?.trim()) return "";

  const meaningfulLine =
    value
      .replace(/\r\n/g, "\n")
      .split("\n")
      .map((line) => line.trim())
      .find((line) => line && !line.startsWith("#") && !line.startsWith("```")) || "";

  return stripMarkdown(meaningfulLine || value);
}

function stripMarkdown(value?: string | null) {
  return (
    value
      ?.replace(/```[\s\S]*?```/g, " ")
      .replace(/^#{1,6}\s+/gm, "")
      .replace(/^\s*[-*]\s+/gm, "")
      .replace(/^\s*\d+[.)]\s+/gm, "")
      .replace(/[`*_]/g, "")
      .replace(/\s+/g, " ")
      .trim() || ""
  );
}

function firstSentence(value: string) {
  return value.match(/^(.+?[.!?])(?:\s|$)/)?.[1] || value;
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
        headers: await mutationHeaders(),
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
      <div className="rounded-md bg-emerald-50 p-3 text-xs text-emerald-800 dark:bg-emerald-950/50 dark:text-emerald-200">
        <p className="font-semibold">Pros</p>
        <ul className="mt-1 space-y-1">
          {(option.pros || ["No specific pros recorded"]).map((pro) => (
            <li key={pro}>{pro}</li>
          ))}
        </ul>
      </div>
      <div className="rounded-md bg-rose-50 p-3 text-xs text-rose-800 dark:bg-rose-950/50 dark:text-rose-200">
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
      const response = await fetch(operatorApiUrl("/work-requests"), {
        method: "POST",
        headers: await mutationHeaders(),
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

function CardDetailDialog({
  selection,
  onOpenChange,
  onSelectGuidance,
}: {
  selection: CardDetailSelection | null;
  onOpenChange: (open: boolean) => void;
  onSelectGuidance: (item: GuidanceItem) => void;
}) {
  const [packageDetail, setPackageDetail] = useState<WorkPackageDetailPayload | null>(null);
  const [loadingPackage, setLoadingPackage] = useState(false);
  const [packageError, setPackageError] = useState<string | null>(null);
  const [soloDetail, setSoloDetail] = useState<SoloSessionDetailPayload | null>(null);
  const [loadingSolo, setLoadingSolo] = useState(false);
  const [soloError, setSoloError] = useState<string | null>(null);
  const packageId = selection?.kind === "package" ? selection.pkg.id : null;
  const soloSessionId = selection?.kind === "solo" ? selection.session.id : null;

  useEffect(() => {
    if (!packageId) {
      setPackageDetail(null);
      setPackageError(null);
      setLoadingPackage(false);
      return;
    }

    const controller = new AbortController();
    setLoadingPackage(true);
    setPackageDetail(null);
    setPackageError(null);

    fetch(operatorApiUrl(`/work-packages/${encodeURIComponent(packageId)}`), {
      headers: jsonHeaders(),
      signal: controller.signal,
    })
      .then(async (response) => {
        const payload = await response.json();
        if (!response.ok) {
          throw new Error(payload?.error?.message || "Package detail unavailable");
        }
        setPackageDetail(payload);
      })
      .catch((caught) => {
        if (caught instanceof DOMException && caught.name === "AbortError") return;
        setPackageError(caught instanceof Error ? caught.message : "Package detail unavailable");
      })
      .finally(() => {
        if (!controller.signal.aborted) {
          setLoadingPackage(false);
        }
      });

    return () => controller.abort();
  }, [packageId]);

  useEffect(() => {
    if (!soloSessionId) {
      setSoloDetail(null);
      setSoloError(null);
      setLoadingSolo(false);
      return;
    }

    const controller = new AbortController();
    setLoadingSolo(true);
    setSoloDetail(null);
    setSoloError(null);

    fetch(operatorApiUrl(`/solo-sessions/${encodeURIComponent(soloSessionId)}`), {
      headers: jsonHeaders(),
      signal: controller.signal,
    })
      .then(async (response) => {
        const payload = await response.json();
        if (!response.ok) {
          throw new Error(payload?.error?.message || "Solo Session detail unavailable");
        }
        setSoloDetail(payload);
      })
      .catch((caught) => {
        if (caught instanceof DOMException && caught.name === "AbortError") return;
        setSoloError(caught instanceof Error ? caught.message : "Solo Session detail unavailable");
      })
      .finally(() => {
        if (!controller.signal.aborted) {
          setLoadingSolo(false);
        }
      });

    return () => controller.abort();
  }, [soloSessionId]);

  const effectiveLoadingPackage = selection?.kind === "package" && !packageDetail && !packageError ? true : loadingPackage;
  const effectiveLoadingSolo = selection?.kind === "solo" && !soloDetail && !soloError ? true : loadingSolo;
  const detailMotionKey = cardDetailMotionKey(selection, {
    loadingPackage: effectiveLoadingPackage,
    loadingSolo: effectiveLoadingSolo,
    packageDetail,
    packageError,
    soloDetail,
    soloError,
  });

  return (
    <Dialog open={Boolean(selection)} onOpenChange={onOpenChange}>
      <DialogContent className="dashboard-dialog-content card-detail-dialog">
        <AnimatedDetailBody motionKey={detailMotionKey}>
          {selection?.kind === "request" ? <RequestDetailContent detail={selection.detail} onSelectGuidance={onSelectGuidance} /> : null}
          {selection?.kind === "slice" ? <SliceDetailContent detail={selection.detail} slice={selection.slice} pkg={selection.pkg} /> : null}
          {selection?.kind === "package" ? (
            <PackageDetailContent selection={selection} detailPayload={packageDetail} loading={effectiveLoadingPackage} error={packageError} />
          ) : null}
          {selection?.kind === "solo" ? (
            <SoloSessionDetailContent session={selection.session} detailPayload={soloDetail} loading={effectiveLoadingSolo} error={soloError} />
          ) : null}
        </AnimatedDetailBody>
      </DialogContent>
    </Dialog>
  );
}

function AnimatedDetailBody({ motionKey, children }: { motionKey: string; children: React.ReactNode }) {
  const innerRef = useRef<HTMLDivElement>(null);
  const animationFrameRef = useRef<number | null>(null);
  const [height, setHeight] = useState<number | null>(null);

  const measure = useCallback(() => {
    const node = innerRef.current;
    if (!node) return;

    const nextHeight = Math.ceil(node.getBoundingClientRect().height);
    if (nextHeight <= 0) return;

    setHeight((currentHeight) => (currentHeight === nextHeight ? currentHeight : nextHeight));
  }, []);

  useLayoutEffect(() => {
    measure();
  }, [measure, motionKey]);

  useEffect(() => {
    const node = innerRef.current;
    if (!node || typeof ResizeObserver === "undefined") return;

    const observer = new ResizeObserver(() => {
      if (animationFrameRef.current !== null) {
        window.cancelAnimationFrame(animationFrameRef.current);
      }

      animationFrameRef.current = window.requestAnimationFrame(measure);
    });

    observer.observe(node);

    return () => {
      observer.disconnect();

      if (animationFrameRef.current !== null) {
        window.cancelAnimationFrame(animationFrameRef.current);
        animationFrameRef.current = null;
      }
    };
  }, [measure]);

  return (
    <div className="detail-modal-size-frame" data-detail-motion-key={motionKey} style={height === null ? undefined : { height }}>
      <div ref={innerRef} className="detail-modal-size-inner">
        {children}
      </div>
    </div>
  );
}

function cardDetailMotionKey(
  selection: CardDetailSelection | null,
  state: {
    loadingPackage: boolean;
    loadingSolo: boolean;
    packageDetail: WorkPackageDetailPayload | null;
    packageError: string | null;
    soloDetail: SoloSessionDetailPayload | null;
    soloError: string | null;
  },
) {
  if (!selection) return "closed";

  switch (selection.kind) {
    case "request":
      return `request:${selection.detail.work_request.id}`;
    case "slice":
      return `slice:${selection.slice.id}:${selection.pkg?.id || "undispatched"}`;
    case "package":
      return `package:${selection.pkg.id}:${detailLoadState(state.loadingPackage, state.packageDetail, state.packageError)}`;
    case "solo":
      return `solo:${selection.session.id}:${detailLoadState(state.loadingSolo, state.soloDetail, state.soloError)}`;
  }
}

function detailLoadState(loading: boolean, payload: unknown, error: string | null) {
  if (error) return "error";
  if (payload) return "loaded";
  return loading ? "loading" : "summary";
}

function RequestDetailContent({ detail, onSelectGuidance }: { detail: WorkRequestDetail; onSelectGuidance: (item: GuidanceItem) => void }) {
  const request = detail.work_request;
  const openQuestions = requestOpenQuestions(detail);
  const sliceCounts = requestSliceCounts(detail);

  return (
    <>
      <DetailHeader
        title={request.title || request.id}
        eyebrow={`${repoName(request.repo)} / ${request.base_branch || "main"} / ${request.work_type || "feature"}`}
        badge={<Badge variant={requestStatusVariant(request.status)}>{formatStatus(request.status)}</Badge>}
      />
      <div className="grid gap-4">
        <DetailStatGrid
          stats={[
            { label: "Open Questions", value: String(openQuestions.length || request.open_question_count || 0) },
            { label: "Slices", value: String(sliceCounts.total) },
            { label: "Decisions", value: String(detail.decision_logs?.length || detail.summary?.decision_count || 0) },
            { label: "Updated", value: detailDate(request.updated_at || request.inserted_at) },
          ]}
        />
        <DetailSection title="What It Does">
          <p>{request.human_description || "No operator-facing description has been recorded yet."}</p>
        </DetailSection>
        <DetailSection title="Progress">
          <p>{requestProgressText(detail)}</p>
        </DetailSection>
        <DetailSection title="Blocked By">
          {openQuestions.length > 0 ? (
            <div className="grid gap-2">
              {openQuestions.slice(0, 2).map((question) => (
                <button
                  type="button"
                  key={question.id}
                  className="detail-list-item text-left hover:border-primary/50 hover:bg-primary/5"
                  onClick={() => onSelectGuidance(clarificationGuidanceItem(detail, question))}
                >
                  <span className="text-sm font-medium">{question.decision_prompt?.tl_dr || question.question || "Open question"}</span>
                  {question.why_needed ? <span className="mt-1 line-clamp-2 text-xs text-muted-foreground">{question.why_needed}</span> : null}
                </button>
              ))}
              {openQuestions.length > 2 ? <p className="text-xs text-muted-foreground">+{openQuestions.length - 2} more open question{openQuestions.length - 2 === 1 ? "" : "s"}</p> : null}
            </div>
          ) : (
            <p>No open human questions.</p>
          )}
        </DetailSection>
        <RecentDecisionsDisclosure detail={detail} />
        <DetailDisclosure title="Details" meta="IDs, constraints, and slice plan">
          <DetailFacts
            facts={[
              ["Request ID", request.id],
              ["Dispatch Shape", formatStatus(request.desired_dispatch_shape)],
              ["Created", detailDate(request.inserted_at)],
              ["Updated", detailDate(request.updated_at)],
            ]}
          />
          <DetailList title="Planned slices" items={(detail.planned_slices || []).map((slice) => slice.title || slice.id)} empty="No slices recorded." />
          <JsonDetail label="Constraints" value={request.constraints} />
        </DetailDisclosure>
      </div>
    </>
  );
}

function SliceDetailContent({ detail, slice, pkg }: { detail: WorkRequestDetail; slice: PlannedSlice; pkg?: WorkPackageCard }) {
  const status = slice.work_package_status || slice.status;
  const blockerCount = pkg ? Math.max(pkg.active_blocker_count || 0, pkg.status === "blocked" ? 1 : 0) : 0;
  const reviewLanes = slice.review_lanes || [];

  return (
    <>
      <DetailHeader
        title={slice.title || pkg?.title || slice.id}
        eyebrow={`${repoName(detail.work_request.repo)} / ${detail.work_request.title || detail.work_request.id}`}
        badge={<Badge variant={statusVariant(status)}>{statusLabel(status)}</Badge>}
      />
      <div className="grid gap-4">
        <DetailStatGrid
          stats={[
            { label: "Package", value: pkg ? statusLabel(pkg.status) : "Not dispatched" },
            { label: "Review", value: reviewLanes.length > 0 ? reviewLanes.map(reviewLaneLabel).join(", ") : "Not recorded" },
            { label: "Blockers", value: String(blockerCount) },
            { label: "Updated", value: detailDate(slice.updated_at || slice.dispatched_at || slice.inserted_at) },
          ]}
        />
        <DetailSection title="What It Does">
          <p>{slice.goal || pkg?.kind || "No slice goal has been recorded yet."}</p>
        </DetailSection>
        <DetailSection title="Progress">
          <p>{sliceProgressText(slice, pkg)}</p>
        </DetailSection>
        <DetailSection title="Blocked By">
          {blockerCount > 0 ? (
            <p>{blockerCount} active blocker{blockerCount === 1 ? "" : "s"} on the linked work package.</p>
          ) : (
            <p>No blocker surfaced for this slice.</p>
          )}
        </DetailSection>
        <RecentDecisionsDisclosure detail={detail} />
        <DetailDisclosure title="Details" meta="Branch, files, and acceptance">
          <DetailFacts
            facts={[
              ["Slice ID", slice.id],
              ["Work Package", slice.work_package_id || "Not dispatched"],
              ["Target Branch", slice.target_base_branch || detail.work_request.base_branch || "main"],
              ["Dispatched", detailDate(slice.dispatched_at)],
            ]}
          />
          <DetailList title="Acceptance" items={slice.acceptance_criteria || []} empty="No acceptance criteria recorded." />
          <DetailList title="Validation" items={slice.validation_steps || []} empty="No validation steps recorded." />
          <DetailList title="Owned paths" items={slice.owned_file_globs || []} empty="No owned path constraints recorded." />
          <DetailList title="Stop conditions" items={slice.stop_conditions || []} empty="No stop conditions recorded." />
        </DetailDisclosure>
      </div>
    </>
  );
}

function PackageDetailContent({
  selection,
  detailPayload,
  loading,
  error,
}: {
  selection: Extract<CardDetailSelection, { kind: "package" }>;
  detailPayload: WorkPackageDetailPayload | null;
  loading: boolean;
  error: string | null;
}) {
  const pkg = (detailPayload?.work_package || selection.pkg) as WorkPackageCard & {
    branch_pattern?: string | null;
    product_description?: string | null;
    engineering_scope?: string | null;
    acceptance_criteria?: string[];
  };
  const summary = detailPayload?.summary;
  const blockers = (detailPayload?.blockers || []).filter((blocker) => blocker.active !== false);
  const progress = latestPackageProgress(detailPayload);
  const plan = summary?.plan || pkg.plan;
  const blockerCount = blockers.length || summary?.active_blocker_count || pkg.active_blocker_count || (pkg.status === "blocked" ? 1 : 0);

  return (
    <>
      <DetailHeader
        title={pkg.title || pkg.id}
        eyebrow={`${repoName(pkg.repo)} / ${pkg.base_branch || "main"} / ${pkg.kind || "work package"}`}
        badge={<Badge variant={statusVariant(pkg.status)}>{statusLabel(pkg.status)}</Badge>}
      />
      <div className="grid gap-4">
        <DetailStatGrid
          stats={[
            { label: "Plan", value: planSummaryText(plan) },
            { label: "Runtime", value: packageRuntimeText(summary, pkg) },
            { label: "Blockers", value: String(blockerCount) },
            { label: "Updated", value: detailDate(summary?.latest_progress_at || pkg.latest_progress_at || pkg.updated_at || pkg.inserted_at) },
          ]}
        />
        <DetailSection title="What It Does">
          <p>{packagePurpose(pkg)}</p>
        </DetailSection>
        <DetailSection title="Progress">
          {loading ? (
            <p>Loading latest package activity...</p>
          ) : progress.length > 0 ? (
            <DetailActivityList items={progress.map((item) => ({ title: item.summary || item.status || "Progress", body: item.body, at: item.created_at }))} />
          ) : (
            <p>{planSummaryText(plan) === "No plan" ? "No package progress recorded yet." : `Plan is ${planSummaryText(plan).toLowerCase()}.`}</p>
          )}
        </DetailSection>
        <DetailSection title="Blocked By">
          {error ? (
            <p>{error}</p>
          ) : blockerCount > 0 ? (
            <DetailActivityList
              items={(blockers.length > 0 ? blockers : [{ summary: "Package is blocked", body: "No blocker detail was included in the board summary." }]).map(
                (blocker) => ({ title: blocker.summary || blocker.status || "Blocker", body: blocker.body || blocker.resolution, at: blocker.updated_at }),
              )}
            />
          ) : (
            <p>No active blockers surfaced.</p>
          )}
        </DetailSection>
        {selection.detail ? <RecentDecisionsDisclosure detail={selection.detail} /> : null}
        <DetailDisclosure title="Details" meta="PR, review, artifacts, and raw identifiers">
          <DetailFacts
            facts={[
              ["Package ID", pkg.id],
              ["Parent", pkg.parent_id || selection.slice?.work_request_id || "Not linked"],
              ["Branch", pkg.metadata?.branch?.branch || pkg.branch_pattern || "Not recorded"],
              ["PR", packagePrLabel(pkg) || pkg.metadata?.pr?.url || "Not attached"],
              [
                "Review",
                packageReviewSignal(pkg)?.value || (pkg.status === "reviewing" ? "Reviewing" : "Not recorded"),
              ],
              ["Artifacts", String(summary?.artifact_count ?? pkg.artifact_count ?? 0)],
              ["Findings", String(summary?.finding_count ?? pkg.finding_count ?? 0)],
            ]}
          />
          <DetailList title="Acceptance" items={pkg.acceptance_criteria || selection.slice?.acceptance_criteria || []} empty="No acceptance criteria recorded." />
          <DetailList title="Alerts" items={(detailPayload?.alert_indicators || pkg.alert_indicators || []).filter((item) => item.active !== false).map((item) => item.detail || item.label || item.type || "Alert")} empty="No active alerts." />
        </DetailDisclosure>
      </div>
    </>
  );
}

function SoloSessionDetailContent({
  session,
  detailPayload,
  loading,
  error,
}: {
  session: SoloSession;
  detailPayload: SoloSessionDetailPayload | null;
  loading: boolean;
  error: string | null;
}) {
  const detailSession: SoloSession & { workspace_path?: string | null; archived_at?: string | null } = detailPayload?.solo_session || session;
  const entries = sortSoloEntries(detailPayload?.entries || []);
  const latestEntries = latestSoloEntries(entries);
  const activeBlockers = soloEntriesByKind(entries, ["blocker"]).filter((entry) => !["resolved", "completed"].includes(entry.status || ""));
  const attention = soloSessionAttention({ ...session, ...detailSession, entry_counts: session.entry_counts, latest_entry: session.latest_entry });
  const planningGroups = soloPlanningGroups(entries);

  return (
    <>
      <DetailHeader
        title={detailSession.title || detailSession.id}
        eyebrow={`${repoName(detailSession.repo)} / ${detailSession.base_branch || "main"} / ${detailSession.caller_id || "solo"}`}
        badge={<Badge variant={soloSessionStatusVariant(detailSession.status)}>{formatStatus(detailSession.status)}</Badge>}
      />
      <div className="grid gap-4">
        <DetailStatGrid
          stats={[
            { label: "Status", value: formatStatus(detailSession.status) },
            { label: "Last Activity", value: detailDate(detailSession.last_activity_at || detailSession.updated_at || detailSession.inserted_at) },
            { label: "Entries", value: String(detailPayload?.entry_count ?? entries.length) },
            { label: "Attention", value: soloSessionAttentionText(attention) },
          ]}
        />
        <DetailSection title="What It Does">
          <p>{soloSessionPurpose(detailSession, entries)}</p>
        </DetailSection>
        <DetailSection title="Progress">
          {loading ? (
            <p>Loading the Solo Session ledger...</p>
          ) : error ? (
            <p>{error}</p>
          ) : latestEntries.length > 0 ? (
            <DetailActivityList
              items={latestEntries.map((entry) => ({
                title: entry.title || entry.kind_label || "Entry",
                body: soloEntrySummary(entry),
                at: entry.created_at || entry.updated_at,
              }))}
            />
          ) : (
            <p>No Solo Session activity has been recorded yet.</p>
          )}
        </DetailSection>
        <DetailSection title="Blocked By">
          {activeBlockers.length > 0 ? (
            <DetailActivityList
              items={activeBlockers.map((entry) => ({
                title: entry.title || entry.status_label || "Blocker",
                body: soloEntrySummary(entry),
                at: entry.created_at || entry.updated_at,
              }))}
            />
          ) : attention.guidanceCount > 0 ? (
            <p>Human guidance has been surfaced in the Solo Session ledger.</p>
          ) : (
            <p>No active blocker surfaced.</p>
          )}
        </DetailSection>
        <DetailDisclosure title="Planning Files" meta={soloPlanningMeta(planningGroups, loading, error)} defaultOpen>
          {loading ? (
            <p className="text-sm text-muted-foreground">Loading planning entries...</p>
          ) : error ? (
            <p className="text-sm text-muted-foreground">{error}</p>
          ) : planningGroups.length > 0 ? (
            <div className="grid gap-2">
              {planningGroups.map((group, index) => (
                <SoloPlanningGroup key={group.kind} group={group} defaultOpen={index === 0} />
              ))}
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">No planning entries recorded.</p>
          )}
        </DetailDisclosure>
        <DetailDisclosure title="Details" meta="Scope and raw identifiers">
          <DetailFacts
            facts={[
              ["Session ID", detailSession.id],
              ["Workspace", detailSession.workspace_path],
              ["Created", detailDate(detailSession.inserted_at)],
              ["Archived", detailDate(detailSession.archived_at)],
            ]}
          />
        </DetailDisclosure>
      </div>
    </>
  );
}

function SoloPlanningGroup({
  group,
  defaultOpen,
}: {
  group: { kind: string; title: string; entries: SoloSessionEntry[] };
  defaultOpen: boolean;
}) {
  const visibleEntries = group.entries.slice(0, 4);

  return (
    <Collapsible defaultOpen={defaultOpen} className="solo-planning-group">
      <CollapsibleTrigger className="solo-planning-trigger">
        <span className="flex min-w-0 items-center gap-2">
          <ChevronRight className="solo-planning-chevron h-4 w-4 shrink-0 transition-transform duration-150" />
          <span className="truncate">{group.title}</span>
        </span>
        <span className="shrink-0 text-xs text-muted-foreground">{group.entries.length}</span>
      </CollapsibleTrigger>
      <CollapsibleContent className="collapsible-content">
        <div className="solo-planning-body">
          {visibleEntries.map((entry) => (
            <article key={entry.id || `${entry.kind}:${entry.sequence}`} className="solo-planning-entry">
              <div className="flex min-w-0 items-start justify-between gap-3">
                <div className="min-w-0">
                  <p className="truncate text-sm font-semibold">{entry.title || entry.kind_label || "Entry"}</p>
                  <p className="mt-1 text-xs text-muted-foreground">{entry.status_label || formatStatus(entry.status)}</p>
                </div>
                <span className="shrink-0 text-xs text-muted-foreground">{detailDate(entry.created_at || entry.updated_at)}</span>
              </div>
              <MarkdownBlock value={entry.body} />
            </article>
          ))}
          {group.entries.length > visibleEntries.length ? (
            <p className="text-xs text-muted-foreground">+{group.entries.length - visibleEntries.length} older entries kept in the ledger.</p>
          ) : null}
        </div>
      </CollapsibleContent>
    </Collapsible>
  );
}

function DetailHeader({ title, eyebrow, badge }: { title: string; eyebrow: string; badge?: React.ReactNode }) {
  return (
    <DialogHeader data-guidance-section style={{ animationDelay: "35ms" }}>
      <div className="flex min-w-0 flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <DialogTitle className="pr-6">{title}</DialogTitle>
          <DialogDescription className="mt-1 truncate">{eyebrow}</DialogDescription>
        </div>
        {badge ? <div className="shrink-0 sm:pr-6">{badge}</div> : null}
      </div>
    </DialogHeader>
  );
}

function DetailStatGrid({ stats }: { stats: Array<{ label: string; value: string }> }) {
  return (
    <div className="detail-stat-grid" data-guidance-section style={{ animationDelay: "70ms" }}>
      {stats.map((stat) => (
        <div key={stat.label} className="detail-stat">
          <span>{stat.label}</span>
          <strong>{stat.value}</strong>
        </div>
      ))}
    </div>
  );
}

function DetailSection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="detail-section" data-guidance-section style={{ animationDelay: "95ms" }}>
      <h3>{title}</h3>
      <div className="detail-section-body">{children}</div>
    </section>
  );
}

function DetailDisclosure({
  title,
  meta,
  children,
  defaultOpen = false,
}: {
  title: string;
  meta?: string;
  children: React.ReactNode;
  defaultOpen?: boolean;
}) {
  return (
    <Collapsible defaultOpen={defaultOpen} className="detail-disclosure" data-guidance-section style={{ animationDelay: "120ms" }}>
      <CollapsibleTrigger className="detail-disclosure-trigger">
        <span className="flex min-w-0 items-center gap-2">
          <ChevronRight className="detail-disclosure-chevron h-4 w-4 shrink-0 transition-transform duration-150" />
          <span className="truncate">{title}</span>
        </span>
        {meta ? <span className="truncate text-xs text-muted-foreground">{meta}</span> : null}
      </CollapsibleTrigger>
      <CollapsibleContent className="collapsible-content">
        <div className="detail-disclosure-body">{children}</div>
      </CollapsibleContent>
    </Collapsible>
  );
}

function RecentDecisionsDisclosure({ detail }: { detail: WorkRequestDetail }) {
  const decisions = latestDecisionLogs(detail);

  return (
    <DetailDisclosure title="Recent Decisions" meta={decisions.length > 0 ? `${decisions.length} recorded` : "None recorded"}>
      {decisions.length > 0 ? (
        <DetailActivityList
          items={decisions.slice(0, 3).map((decision) => ({
            title: decision.decision || decision.scope_impact || "Decision",
            body: decision.rationale,
            at: decision.created_at || decision.inserted_at,
          }))}
        />
      ) : (
        <p className="text-sm text-muted-foreground">No decisions recorded for this request yet.</p>
      )}
    </DetailDisclosure>
  );
}

function DetailActivityList({ items }: { items: Array<{ title?: string | null; body?: string | null; at?: string | null }> }) {
  return (
    <div className="grid gap-2">
      {items.slice(0, 3).map((item, index) => (
        <div key={`${item.title || "item"}:${index}`} className="detail-list-item">
          <div className="flex min-w-0 items-start justify-between gap-3">
            <span className="min-w-0 text-sm font-medium">{item.title || "Update"}</span>
            {item.at ? <span className="shrink-0 text-xs text-muted-foreground">{formatDate(item.at)}</span> : null}
          </div>
          {item.body ? <p className="mt-1 line-clamp-2 text-xs text-muted-foreground">{item.body}</p> : null}
        </div>
      ))}
    </div>
  );
}

function DetailFacts({ facts }: { facts: Array<[string, string | null | undefined]> }) {
  return (
    <dl className="detail-facts">
      {facts.map(([label, value]) => (
        <div key={label}>
          <dt>{label}</dt>
          <dd>{value || "Not recorded"}</dd>
        </div>
      ))}
    </dl>
  );
}

function DetailList({ title, items, empty }: { title: string; items: string[]; empty: string }) {
  const visibleItems = items.filter(Boolean).slice(0, 4);

  return (
    <div className="grid gap-2">
      <p className="text-xs font-semibold text-muted-foreground">{title}</p>
      {visibleItems.length > 0 ? (
        <ul className="grid gap-1.5 text-sm text-muted-foreground">
          {visibleItems.map((item) => (
            <li key={item} className="detail-bullet">
              {item}
            </li>
          ))}
        </ul>
      ) : (
        <p className="text-sm text-muted-foreground">{empty}</p>
      )}
      {items.length > visibleItems.length ? <p className="text-xs text-muted-foreground">+{items.length - visibleItems.length} more</p> : null}
    </div>
  );
}

function JsonDetail({ label, value }: { label: string; value?: Record<string, unknown> }) {
  if (!value || Object.keys(value).length === 0) return null;

  return (
    <div className="grid gap-2">
      <p className="text-xs font-semibold text-muted-foreground">{label}</p>
      <pre className="detail-json">{JSON.stringify(value, null, 2)}</pre>
    </div>
  );
}

type MarkdownNode =
  | { type: "heading"; depth: number; text: string }
  | { type: "paragraph"; text: string }
  | { type: "list"; ordered: boolean; items: string[] }
  | { type: "code"; text: string };

function MarkdownBlock({ value }: { value?: string | null }) {
  const nodes = markdownNodes(value);

  if (nodes.length === 0) {
    return <p className="solo-markdown-empty">No details recorded.</p>;
  }

  return (
    <div className="solo-markdown">
      {nodes.map((node, index) => {
        if (node.type === "heading") {
          if (node.depth === 1) return <h4 key={index}>{renderMarkdownInline(node.text)}</h4>;
          if (node.depth === 2) return <h5 key={index}>{renderMarkdownInline(node.text)}</h5>;
          return <h6 key={index}>{renderMarkdownInline(node.text)}</h6>;
        }

        if (node.type === "list") {
          const List = node.ordered ? "ol" : "ul";
          return (
            <List key={index}>
              {node.items.map((item) => (
                <li key={item}>{renderMarkdownInline(item)}</li>
              ))}
            </List>
          );
        }

        if (node.type === "code") {
          return <pre key={index}>{node.text}</pre>;
        }

        return <p key={index}>{renderMarkdownInline(node.text)}</p>;
      })}
    </div>
  );
}

function renderMarkdownInline(text: string) {
  const parts = text.split(/(`[^`]+`|\*\*[^*]+\*\*)/g).filter((part) => part !== "");

  return parts.map((part, index) => {
    if (part.startsWith("`") && part.endsWith("`")) {
      return <code key={index}>{part.slice(1, -1)}</code>;
    }
    if (part.startsWith("**") && part.endsWith("**")) {
      return <strong key={index}>{part.slice(2, -2)}</strong>;
    }
    return <span key={index}>{part}</span>;
  });
}

function markdownNodes(value?: string | null): MarkdownNode[] {
  if (!value?.trim()) return [];

  const nodes: MarkdownNode[] = [];
  const lines = value.replace(/\r\n/g, "\n").split("\n");
  let paragraph: string[] = [];
  let list: { ordered: boolean; items: string[] } | null = null;
  let code: string[] | null = null;

  const flushParagraph = () => {
    if (paragraph.length > 0) {
      nodes.push({ type: "paragraph", text: paragraph.join(" ").trim() });
      paragraph = [];
    }
  };

  const flushList = () => {
    if (list) {
      nodes.push({ type: "list", ordered: list.ordered, items: list.items });
      list = null;
    }
  };

  for (const line of lines) {
    if (line.trim().startsWith("```")) {
      if (code) {
        nodes.push({ type: "code", text: code.join("\n").trimEnd() });
        code = null;
      } else {
        flushParagraph();
        flushList();
        code = [];
      }
      continue;
    }

    if (code) {
      code.push(line);
      continue;
    }

    if (line.trim() === "") {
      flushParagraph();
      flushList();
      continue;
    }

    const heading = line.match(/^(#{1,3})\s+(.+)$/);
    if (heading) {
      flushParagraph();
      flushList();
      nodes.push({ type: "heading", depth: heading[1].length, text: heading[2].trim() });
      continue;
    }

    const bullet = line.match(/^\s*[-*]\s+(.+)$/);
    const ordered = line.match(/^\s*\d+[.)]\s+(.+)$/);
    if (bullet || ordered) {
      flushParagraph();
      const orderedList = Boolean(ordered);
      if (!list || list.ordered !== orderedList) {
        flushList();
        list = { ordered: orderedList, items: [] };
      }
      list.items.push((bullet?.[1] || ordered?.[1] || "").trim());
      continue;
    }

    flushList();
    paragraph.push(line.trim());
  }

  flushParagraph();
  flushList();
  if (code) nodes.push({ type: "code", text: code.join("\n").trimEnd() });

  return nodes;
}

function requestOpenQuestions(detail: WorkRequestDetail) {
  return (detail.clarification_questions || []).filter((question) => question.status === "open");
}

function requestSliceCounts(detail: WorkRequestDetail) {
  const summary = detail.summary || {};
  const planned = summary.planned_slice_count ?? detail.work_request.planned_slice_count ?? 0;
  const approved = summary.approved_slice_count ?? detail.work_request.approved_slice_count ?? 0;
  const dispatched = summary.dispatched_slice_count ?? detail.work_request.dispatched_slice_count ?? 0;
  const skipped = summary.skipped_slice_count ?? detail.work_request.skipped_slice_count ?? 0;
  const total = Math.max(detail.planned_slices?.length || 0, planned + approved + dispatched + skipped);

  return { planned, approved, dispatched, skipped, total };
}

function requestProgressText(detail: WorkRequestDetail) {
  const request = detail.work_request;
  const questions = requestOpenQuestions(detail);
  const slices = requestSliceCounts(detail);

  if (questions.length > 0) {
    return `${questions.length} open human question${questions.length === 1 ? "" : "s"} before the architect can continue.`;
  }

  if (request.status === "sliced" || slices.total > 0) {
    return `${slices.total} slice${slices.total === 1 ? "" : "s"} recorded: ${slices.approved} approved, ${slices.dispatched} dispatched, ${slices.skipped} skipped.`;
  }

  if (request.status === "ready_for_slicing") {
    return "Ready for an architecture agent to slice into work packages.";
  }

  if (request.status === "clarifying" || request.status === "ready_for_clarification") {
    return "Architecture intake is still clarifying the request.";
  }

  return `Current request state: ${formatStatus(request.status)}.`;
}

function sliceProgressText(slice: PlannedSlice, pkg?: WorkPackageCard) {
  if (pkg) {
    const progress = planProgressLabel(pkg);
    return progress ? `Linked work package is ${statusLabel(pkg.status)} with ${progress.toLowerCase()}.` : `Linked work package is ${statusLabel(pkg.status)}.`;
  }

  if (slice.status === "approved") {
    return "Approved and ready to dispatch into a worker-owned package.";
  }

  if (slice.status === "planned") {
    return "Planned by architecture; not dispatched yet.";
  }

  if (slice.status === "skipped") {
    return "Skipped by architecture and not expected to move forward.";
  }

  return `Current slice state: ${formatStatus(slice.status)}.`;
}

function latestPackageProgress(payload: WorkPackageDetailPayload | null) {
  return [...(payload?.progress || [])].sort((left, right) => {
    const sequenceDelta = (right.sequence || 0) - (left.sequence || 0);
    if (sequenceDelta !== 0) return sequenceDelta;
    return sortableTime(right.created_at) - sortableTime(left.created_at);
  });
}

function planSummaryText(plan?: WorkPackageCard["plan"] | null) {
  const total = plan?.total_count || 0;
  if (total <= 0) return "No plan";

  const open = plan?.open_count || 0;
  const completed = plan?.completed_count || 0;

  return open > 0 ? `${open} open / ${total} total` : `${completed}/${total} done`;
}

function packageRuntimeText(summary: WorkPackageDetailPayload["summary"] | undefined, pkg: WorkPackageCard) {
  if (summary?.stale_agent_run_count) return `${summary.stale_agent_run_count} stale`;
  if (summary?.failed_agent_run_count) return `${summary.failed_agent_run_count} failed`;
  if (summary?.active_agent_run_count) return `${summary.active_agent_run_count} active`;
  if (summary?.queued_agent_run_count) return `${summary.queued_agent_run_count} queued`;
  if (pkg.active_agent_run?.stale) return "Stale run";
  if (pkg.active_agent_run?.runtime_state === "queued") return "Queued";
  if (pkg.active_agent_run || runtimeBoolean(pkg.runtime || {}, "active_count")) return "Active";
  return "No active run";
}

function packagePurpose(pkg: WorkPackageCard | NonNullable<WorkPackageDetailPayload["work_package"]>) {
  const richPackage = pkg as NonNullable<WorkPackageDetailPayload["work_package"]>;
  return firstParagraph(richPackage.engineering_scope) || firstParagraph(richPackage.product_description) || pkg.kind || "No package description has been recorded yet.";
}

function latestDecisionLogs(detail: WorkRequestDetail) {
  return [...(detail.decision_logs || [])].sort((left, right) => {
    const sequenceDelta = (right.sequence || 0) - (left.sequence || 0);
    if (sequenceDelta !== 0) return sequenceDelta;
    return sortableTime(right.created_at || right.inserted_at) - sortableTime(left.created_at || left.inserted_at);
  });
}

function detailDate(value?: string | null) {
  return value ? formatDate(value) : "Not recorded";
}

function firstParagraph(value?: string | null) {
  return value?.split(/\n\s*\n/)[0]?.trim() || "";
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
    <div
      className={`dashboard-glass-surface flex items-center justify-center rounded-lg border border-dashed bg-muted/30 text-sm text-muted-foreground ${compact ? "min-h-[96px]" : "min-h-[180px]"}`}
    >
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

function activeBlockerItems(packages: WorkPackageCard[], details: WorkRequestDetail[] = []): BlockerItem[] {
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
      selection: packageBoardSelection(pkg, details),
    }));
}

function recentFinishedHighlights(
  packages: WorkPackageCard[],
  requests: WorkRequestCard[],
  details: WorkRequestDetail[],
): FinishedHighlight[] {
  const detailByRequestId = new Map(details.map((detail) => [detail.work_request.id, detail]));
  const packageById = new Map(packages.map((pkg) => [pkg.id, pkg]));

  const packageHighlights = packages
    .filter((pkg) => packageLane(pkg) === "finished")
    .map<FinishedHighlight>((pkg) => ({
      id: pkg.id,
      title: pkg.title || pkg.id,
      repo: repoName(pkg.repo),
      kind: "Work Package",
      status: pkg.status,
      at: pkg.latest_progress_at,
      selection: packageBoardSelection(pkg, details),
    }));

  const requestHighlights = requests
    .filter((request) => requestLane(request) === "finished")
    .map<FinishedHighlight | null>((request) => {
      const detail = detailByRequestId.get(request.id);
      if (!detail) return null;

      return {
        id: request.id,
        title: request.title || request.id,
        repo: repoName(request.repo),
        kind: "Request",
        status: request.status,
        at: request.updated_at || request.inserted_at,
        selection: { kind: "request", detail },
      };
    })
    .filter((item): item is FinishedHighlight => Boolean(item));

  const sliceHighlights = details.flatMap<FinishedHighlight>((detail) =>
    (detail.planned_slices || [])
      .filter((slice) => sliceLane(slice) === "finished")
      .map((slice) => {
        const pkg = slice.work_package_id ? packageById.get(slice.work_package_id) : undefined;

        return {
          id: slice.id,
          title: slice.title || slice.id,
          repo: repoName(detail.work_request.repo),
          kind: "Slice",
          status: slice.work_package_status || slice.status,
          at: detail.work_request.updated_at || detail.work_request.inserted_at,
          selection: pkg ? { kind: "package", pkg, detail, slice } : { kind: "slice", detail, slice },
        };
      }),
  );

  return [...packageHighlights, ...requestHighlights, ...sliceHighlights].sort((a, b) => {
    const left = a.at ? Date.parse(a.at) : 0;
    const right = b.at ? Date.parse(b.at) : 0;
    return right - left;
  });
}

function packageBoardSelection(pkg: WorkPackageCard, details: WorkRequestDetail[]): CardDetailSelection {
  for (const detail of details) {
    const slice = (detail.planned_slices || []).find((candidate) => candidate.work_package_id === pkg.id);
    if (slice) {
      return sliceLane(slice) === "slices" ? { kind: "slice", detail, slice, pkg } : { kind: "package", pkg, detail, slice };
    }
  }

  return { kind: "package", pkg };
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
    return operatorApiUrl(`/work-packages/${encodeURIComponent(item.packageId)}/guidance/${encodeURIComponent(item.id)}/answer`);
  }

  return operatorApiUrl(`/work-requests/${encodeURIComponent(item.workRequestId)}/questions/${encodeURIComponent(item.id)}/answer`);
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
      minHeight: ALIGNED_ROW_MIN_HEIGHT,
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
      minHeight: ALIGNED_ROW_MIN_HEIGHT,
      unlinked: true,
    });
  }

  return rows;
}

function workstreamRowKey(row: WorkstreamRow, index: number) {
  if (row.detail) return `request-row:${row.detail.work_request.id}`;
  return row.unlinked ? "unlinked-row" : `row:${index}`;
}

function workstreamWires(details: WorkRequestDetail[], packages: WorkPackageCard[], activeBlockingEdges: ActiveBlockingEdge[] = []): BoardWire[] {
  const packageMap = new Map(packages.map((pkg) => [pkg.id, pkg]));
  const progressWires = details.flatMap((detail) => {
    const wires: BoardWire[] = [];
    const slices = detail.planned_slices || [];
    const sliceTargets = slices.filter((slice) => sliceLane(slice) === "slices");
    const packageTargets = slices.filter((slice) => sliceLane(slice) !== "slices");
    let packageSources = [requestNodeId(detail)];

    sliceTargets.forEach((target, index) => {
      const source = requestNodeId(detail);
      const targetNode = sliceNodeId(target);
      wires.push({
        id: `${source}->${targetNode}:${index}`,
        from: source,
        to: targetNode,
        tone: wireToneForSlice(target, packageMap.get(target.work_package_id || "")),
      });
    });

    if (sliceTargets.length > 0) {
      packageSources = sliceTargets.map(sliceNodeId);
    }

    packageTargets.forEach((target, index) => {
      const source = packageSources[Math.min(index, packageSources.length - 1)];
      const pkg = packageMap.get(target.work_package_id || "");
      const targetNode = pkg ? packageNodeId(pkg) : sliceNodeId(target);
      wires.push({
        id: `${source}->${targetNode}:${index}`,
        from: source,
        to: targetNode,
        tone: wireToneForSlice(target, pkg),
      });
    });

    return wires;
  });

  return [...progressWires, ...activeBlockingWires(details, packages, activeBlockingEdges)];
}

function requestNodeId(detail: WorkRequestDetail) {
  return `request:${detail.work_request.id}`;
}

function sliceNodeId(slice: PlannedSlice) {
  return `slice:${slice.id}`;
}

function packageNodeId(pkg: WorkPackageCard | string) {
  return `package:${typeof pkg === "string" ? pkg : pkg.id}`;
}

function activeBlockingWires(details: WorkRequestDetail[], packages: WorkPackageCard[], activeBlockingEdges: ActiveBlockingEdge[]): BoardWire[] {
  if (activeBlockingEdges.length === 0) return [];

  const context = blockerWireContext(details, packages);

  return activeBlockingEdges.flatMap((edge) => {
    const target = blockerEndpointNodeId(edge.to, context, "target");
    if (!target) return [];

    const source = blockerEndpointNodeId(edge.from, context, "source") || blockerFallbackSourceNode(edge, context);
    if (!source || source === target) return [];

    return [
      {
        id: `blocker:${edge.id}`,
        from: source,
        to: target,
        tone: "blocked",
        kind: "blocker",
      },
    ];
  });
}

function blockerWireContext(details: WorkRequestDetail[], packages: WorkPackageCard[]) {
  const detailById = new Map(details.map((detail) => [detail.work_request.id, detail]));
  const detailBySliceId = new Map<string, WorkRequestDetail>();
  const sliceById = new Map<string, PlannedSlice>();
  const packageById = new Map(packages.map((pkg) => [pkg.id, pkg]));

  details.forEach((detail) => {
    (detail.planned_slices || []).forEach((slice) => {
      sliceById.set(slice.id, slice);
      detailBySliceId.set(slice.id, detail);
    });
  });

  return { detailById, detailBySliceId, packageById, sliceById };
}

function blockerEndpointNodeId(
  endpoint: ActiveBlockingEdge["from"],
  context: ReturnType<typeof blockerWireContext>,
  role: "source" | "target",
) {
  if (endpoint.kind === "work_package") {
    return context.packageById.has(endpoint.id) ? packageNodeId(endpoint.id) : undefined;
  }

  const slice = context.sliceById.get(endpoint.id);
  if (!slice) return undefined;

  if (role === "target" || sliceLane(slice) === "slices") {
    return sliceNodeId(slice);
  }

  return undefined;
}

function blockerFallbackSourceNode(edge: ActiveBlockingEdge, context: ReturnType<typeof blockerWireContext>) {
  if (edge.from.kind === "slice") {
    const detail = context.detailBySliceId.get(edge.from.id);
    if (detail) return requestNodeId(detail);
  }

  if (edge.work_request_id) {
    const detail = context.detailById.get(edge.work_request_id);
    if (detail) return requestNodeId(detail);
  }

  return undefined;
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
  if (["ready_for_human_merge", "ready_for_architect_merge", "merging_into_phase"].includes(status || "")) return "ready";
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

function statusLabel(status?: string | null) {
  if (status === "ready_for_human_merge" || status === "ready_for_architect_merge") return "Merge Ready";
  if (status === "merging_into_phase") return "Merging";
  if (status === "ci_waiting") return "CI Waiting";
  return formatStatus(status);
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

function readStoredTheme(): DashboardTheme {
  if (typeof window === "undefined") return "light";

  try {
    const storedTheme = window.localStorage.getItem(DASHBOARD_THEME_KEY);
    if (isDashboardTheme(storedTheme)) return storedTheme;
  } catch {
    // Storage can be unavailable in locked-down browser contexts; fall back to the OS preference.
  }

  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function writeStoredTheme(theme: DashboardTheme) {
  if (typeof window === "undefined") return;

  try {
    window.localStorage.setItem(DASHBOARD_THEME_KEY, theme);
  } catch {
    // Theme persistence is best-effort; the class toggle still applies for the active session.
  }

  document.documentElement.classList.toggle("dark", theme === "dark");
}

function defaultRepoWorkstreamOpen(repo: Pick<RepoSummary, "requested" | "active" | "implementing" | "finished" | "guidanceCount" | "blockerCount">) {
  if (!repoWorkstreamHasActivity(repo)) return false;
  return typeof window === "undefined" ? true : window.innerWidth >= 900;
}

function repoWorkstreamStateKey(
  repo: Pick<RepoSummary, "repo" | "baseBranches" | "requested" | "active" | "implementing" | "finished" | "guidanceCount" | "blockerCount">,
) {
  const branchKey = uniqueNonEmpty(repo.baseBranches).sort().join("|") || "main";
  const activityKey = repoWorkstreamHasActivity(repo) ? "active" : "empty";
  return `${repo.repo}::${branchKey}::${activityKey}`;
}

function repoWorkstreamHasActivity(
  repo: Pick<RepoSummary, "requested" | "active" | "implementing" | "finished" | "guidanceCount" | "blockerCount">,
) {
  return repo.requested + repo.active + repo.implementing + repo.finished + repo.guidanceCount + repo.blockerCount > 0;
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

function isDashboardTheme(value: unknown): value is DashboardTheme {
  return value === "light" || value === "dark";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function topPanelDirection(from: TopPanelKey | null, to: TopPanelKey | null): TopPanelDirection {
  if (!from || !to) return "forward";
  return TOP_PANEL_ORDER.indexOf(to) > TOP_PANEL_ORDER.indexOf(from) ? "forward" : "backward";
}

function workspaceTabDirection(from: WorkspaceTab, to: WorkspaceTab): TopPanelDirection {
  return to === "solo" && from === "workstreams" ? "forward" : "backward";
}

function measureElementHeight(element: HTMLElement | null) {
  return element?.getBoundingClientRect().height || 0;
}

function measureElementWidth(element: HTMLElement | null) {
  return element?.getBoundingClientRect().width || 0;
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
