import {
  AlertCircle,
  AlertTriangle,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Clock3,
  Copy,
  GitBranch,
  Loader2,
  MessageSquareText,
  Moon,
  RefreshCw,
  Route,
  Settings2,
  Sun,
} from "lucide-react";
import type * as React from "react";
import { useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState } from "react";

import { Badge } from "@/components/ui/badge";
import {
  AlignedCardSlot,
  BoardLaneColumn,
  FeatureLaneRow,
  LaneGroupLabel,
} from "@/components/dashboard/board-lanes";
import {
  ALIGNED_ROW_MIN_HEIGHT,
  useAlignedBoardLayout,
  useBoardLayoutMotion,
} from "@/components/dashboard/board-layout";
import type {
  BoardLayoutMeasurementRow,
  BoardLayoutMode as WorkstreamLayoutMode,
} from "@/components/dashboard/board-layout";
import {
  DetailDisclosure,
  DetailFacts,
  DetailHeader,
  DetailList,
  DetailSection,
  DetailStatGrid,
  JsonDetail,
} from "@/components/dashboard/detail-layout";
import { GuidanceDialog } from "@/components/dashboard/guidance-dialog";
import { NewRequestDialog } from "@/components/dashboard/new-request-dialog";
import type { NewRequestForm } from "@/components/dashboard/new-request-dialog";
import {
  BoardWireLayer,
  useBoardWirePaths,
} from "@/components/dashboard/board-wires";
import type { BoardWire } from "@/components/dashboard/board-wires";
import { MarkdownBlock } from "@/components/dashboard/markdown-block";
import {
  AnimatedBadge,
  AnimatedCardBody,
  AnimatedTopGrid,
  NumberWheel,
  TOP_PANEL_RESIZE_MS,
  TOP_PANEL_SLIDE_MS,
  UPDATE_ANIMATION_TTL_MS,
  WORKSPACE_TAB_SLIDE_MS,
  clearMotionTimers,
  dashboardPrefersReducedMotion,
  later,
  measureElementHeight,
  nextFrame,
  updateMotionAttributes,
  useCountMotion,
  useFlipList,
} from "@/components/dashboard/motion";
import type { UpdateMotion, UpdateMotionKind } from "@/components/dashboard/motion";
import {
  CardSignalFrame,
  CardSignal,
  StateCard,
} from "@/components/dashboard/state-card";
import type { SignalTone, StateCardTone } from "@/components/dashboard/state-card";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Separator } from "@/components/ui/separator";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";
import { sortedCopy, uniqueNonEmpty } from "@/lib/collections";
import {
  architectHandoffEligibleRequest,
  attentionTone,
  isFinishedBoardStatus,
  operationalBadgeVariant,
  operationalLabel,
  packageAttentionSignal,
  packageBlockerSignal,
  packageCardTone,
  packageLane,
  requestStateCardTone,
  sliceCardTone,
  sliceLane,
  sliceOperationalState,
  workRequestLane,
} from "@/lib/operational-state";
import type { BadgeTone, BoardLane } from "@/lib/operational-state";
import { packageReviewLabel, planProgressLabel, reviewLaneLabel } from "@/lib/review-signals";
import { formatStatus, statusLabel } from "@/lib/status-labels";
import { cn } from "@/lib/utils";
import type {
  ActiveBlockingEdge,
  ArchitectHandoff,
  ArchitectHandoffCopyResult,
  ArchitectHandoffPayload,
  ClarificationQuestion,
  ContextComment,
  CopyArchitectHandoff,
  CreateWorkRequestPayload,
  DashboardPayload,
  GuidanceAnswerSubmission,
  GuidanceItem,
  HandoffCopyState,
  PackageAlertIndicator,
  PackageOperationalAttention,
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
      operatorMode?: boolean;
    };
  }
}

const DASHBOARD_UI_STATE_KEY = "symphony-plus-plus.dashboard.ui-state.v1";
const DASHBOARD_THEME_KEY = "symphony-plus-plus.dashboard.theme.v1";
const DASHBOARD_DEBUG_ANIMATIONS_KEY = "symphony-plus-plus.dashboard.debug-animations";
const REPO_WORKSTREAM_MOTION_MS = 360;
const DASHBOARD_POLL_INTERVAL_MS = 7000;
const LOCAL_DATE_FORMATTER = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
const TOP_PANEL_ORDER: TopPanelKey[] = ["guidance", "blockers", "finished"];
const DEFAULT_DASHBOARD_API_BASE = "/api/v1/sympp/operator";
const PR_SYNC_INTERVAL_MS = 60_000;
const COMMENT_BODY_MAX_LENGTH = 4000;

type DashboardRuntimeConfig = {
  apiBase?: string;
  basePath?: string;
  csrfToken?: string;
  logoUrl?: string;
  operatorMode?: boolean;
};
type DashboardApiResponse = unknown;
type DashboardResponseSelector = (payload: DashboardApiResponse) => DashboardPayload | null | undefined;

let dashboardRuntimeConfig: DashboardRuntimeConfig | undefined = typeof window === "undefined" ? undefined : window.SYMPP_DASHBOARD_CONFIG;
let dashboardRuntimeConfigPromise: Promise<DashboardRuntimeConfig | undefined> | null = null;
const DASHBOARD_LOGO_URL = dashboardRuntimeConfig?.logoUrl || "/splusplus-logo.png";

type TopPanelKey = "guidance" | "blockers" | "finished";
type TopPanelDirection = "forward" | "backward";
type TopPanelPhase = "idle" | "opening" | "closing" | "pre-resize" | "swapping" | "post-resize";
type PackageLineageProjection = NonNullable<WorkPackageCard["lineage"]>;
type WorkspaceTab = "workstreams" | "solo";
type WorkspaceTabPhase = "idle" | "swapping";
type DashboardTheme = "light" | "dark";
type CommentCardSignal = { open: number; total: number };
type UpdateMotionsAction =
  | { type: "clear" }
  | { type: "merge"; motions: Record<string, UpdateMotion> }
  | { type: "settle"; entries: [string, UpdateMotion][] };
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
type CommentTargetKind = "work_request" | "planned_slice" | "work_package";
type CommentTarget = { target_kind: CommentTargetKind; target_id: string };
type SubmitContextComment = (target: CommentTarget, body: string) => Promise<ContextComment>;
type ResolveContextComment = (commentId: string, resolutionNote?: string) => Promise<ContextComment>;
type CommentStats = { comment_count: number; open_comment_count: number };
type ScopedHandoffCopy = {
  error: string | null;
  identity: string;
  state: HandoffCopyState;
};
type DashboardUiState = {
  workspaceTab?: WorkspaceTab;
  topPanel?: TopPanelKey | null;
  repoWorkstreams?: Record<string, boolean>;
  workstreamLayout?: WorkstreamLayoutMode;
  hideEmptyWorkstreams?: boolean;
  theme?: DashboardTheme;
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

function dashboardErrorMessage(payload: DashboardApiResponse) {
  if (!isRecord(payload) || !isRecord(payload.error)) return null;
  return typeof payload.error.message === "string" ? payload.error.message : null;
}

function dashboardFromEnvelope(payload: DashboardApiResponse) {
  if (!isRecord(payload) || !isRecord(payload.dashboard)) return null;
  return payload.dashboard as DashboardPayload;
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

async function copyTextToClipboard(value: string) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }

  const textArea = document.createElement("textarea");
  textArea.value = value;
  textArea.setAttribute("readonly", "");
  textArea.style.cssText = "position: fixed; left: -9999px; top: 0;";
  document.body.appendChild(textArea);
  textArea.select();

  try {
    const copied = document.execCommand("copy");
    if (!copied) throw new Error("Clipboard copy unavailable");
  } finally {
    document.body.removeChild(textArea);
  }
}

function useScopedHandoffCopy(identity: string) {
  const [copy, setCopy] = useState<ScopedHandoffCopy>({ error: null, identity, state: "idle" });
  const handoffRef = useRef<{ handoff: ArchitectHandoff | null; identity: string }>({ handoff: null, identity: "" });

  const current = copy.identity === identity ? copy : { error: null, identity, state: "idle" as const };
  const cachedHandoff = useCallback(() => (handoffRef.current.identity === identity ? handoffRef.current.handoff : null), [identity]);
  const startCopy = useCallback(() => setCopy({ error: null, identity, state: "copying" }), [identity]);
  const recordCopyResult = useCallback(
    (result: ArchitectHandoffCopyResult) => {
      handoffRef.current = { handoff: result.handoff, identity };
      setCopy({
        error: result.copyError ? `Handoff is ready, but clipboard copy failed: ${result.copyError}` : null,
        identity,
        state: result.copied ? "copied" : "error",
      });
    },
    [identity],
  );
  const recordCopyError = useCallback((error: string) => setCopy({ error, identity, state: "error" }), [identity]);

  return {
    cachedHandoff,
    error: current.error,
    recordCopyError,
    recordCopyResult,
    startCopy,
    state: current.state,
  };
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
  state?: string | null;
  at?: string | null;
  selection: CardDetailSelection;
};

type FinishedHighlightKind = "Request" | "Slice" | "Work Package";

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

type AppState = {
  dashboard: DashboardPayload | null;
  loading: boolean;
  refreshing: boolean;
  error: string | null;
  workspaceTab: WorkspaceTab;
  workstreamLayout: WorkstreamLayoutMode;
  hideEmptyWorkstreams: boolean;
  theme: DashboardTheme;
};

type AppStateAction = {
  type: "patch";
  state: Partial<AppState>;
};

function createInitialAppState(): AppState {
  return {
    dashboard: null,
    loading: true,
    refreshing: false,
    error: null,
    workspaceTab: readStoredWorkspaceTab(),
    workstreamLayout: readStoredWorkstreamLayout(),
    hideEmptyWorkstreams: readStoredHideEmptyWorkstreams(),
    theme: readStoredTheme(),
  };
}

function appStateReducer(state: AppState, action: AppStateAction): AppState {
  return { ...state, ...action.state };
}

type AppDialogState = {
  selectedGuidance: GuidanceItem | null;
  selectedCardDetail: CardDetailSelection | null;
  newRequestOpen: boolean;
};

type AppDialogAction =
  | { type: "guidance"; selectedGuidance: GuidanceItem | null }
  | { type: "cardDetail"; selectedCardDetail: CardDetailSelection | null }
  | { type: "newRequest"; open: boolean };

const initialAppDialogState: AppDialogState = {
  selectedGuidance: null,
  selectedCardDetail: null,
  newRequestOpen: false,
};

function appDialogReducer(state: AppDialogState, action: AppDialogAction): AppDialogState {
  switch (action.type) {
    case "guidance":
      return { ...state, selectedGuidance: action.selectedGuidance };
    case "cardDetail":
      return { ...state, selectedCardDetail: action.selectedCardDetail };
    case "newRequest":
      return { ...state, newRequestOpen: action.open };
  }
}

function updateMotionsReducer(current: Record<string, UpdateMotion>, action: UpdateMotionsAction): Record<string, UpdateMotion> {
  switch (action.type) {
    case "clear":
      return Object.keys(current).length === 0 ? current : {};
    case "merge":
      return { ...current, ...action.motions };
    case "settle": {
      let changed = false;
      const next = { ...current };

      action.entries.forEach(([key, motion]) => {
        if (next[key]?.token === motion.token) {
          next[key] = { kind: "settled", token: motion.token };
          changed = true;
        }
      });

      return changed ? next : current;
    }
  }
}

export default function App() {
  const [appState, dispatchApp] = useReducer(appStateReducer, null, createInitialAppState);
  const { dashboard, error, hideEmptyWorkstreams, loading, refreshing, theme, workspaceTab, workstreamLayout } = appState;
  const [dialogState, dispatchDialog] = useReducer(appDialogReducer, initialAppDialogState);
  const showUpdateSimulationControls = useMemo(() => shouldShowUpdateSimulationControls(), []);
  const loadInFlightRef = useRef(false);
  const prSyncInFlightRef = useRef(false);
  const lastPrSyncAtRef = useRef(0);
  const setDashboard = useCallback((nextDashboard: DashboardPayload | null) => {
    dispatchApp({ type: "patch", state: { dashboard: nextDashboard } });
  }, []);
  const setLoading = useCallback((nextLoading: boolean) => {
    dispatchApp({ type: "patch", state: { loading: nextLoading } });
  }, []);
  const setRefreshing = useCallback((nextRefreshing: boolean) => {
    dispatchApp({ type: "patch", state: { refreshing: nextRefreshing } });
  }, []);
  const setError = useCallback((nextError: string | null) => {
    dispatchApp({ type: "patch", state: { error: nextError } });
  }, []);
  const setWorkspaceTab = useCallback((nextWorkspaceTab: WorkspaceTab) => {
    dispatchApp({ type: "patch", state: { workspaceTab: nextWorkspaceTab } });
  }, []);
  const setWorkstreamLayout = useCallback((nextWorkstreamLayout: WorkstreamLayoutMode) => {
    dispatchApp({ type: "patch", state: { workstreamLayout: nextWorkstreamLayout } });
  }, []);
  const setHideEmptyWorkstreams = useCallback((nextHideEmptyWorkstreams: boolean) => {
    dispatchApp({ type: "patch", state: { hideEmptyWorkstreams: nextHideEmptyWorkstreams } });
  }, []);
  const setSelectedGuidance = useCallback((selectedGuidance: GuidanceItem | null) => {
    dispatchDialog({ type: "guidance", selectedGuidance });
  }, []);
  const setSelectedCardDetail = useCallback((selectedCardDetail: CardDetailSelection | null) => {
    dispatchDialog({ type: "cardDetail", selectedCardDetail });
  }, []);
  const setNewRequestOpen = useCallback((open: boolean) => {
    dispatchDialog({ type: "newRequest", open });
  }, []);

  const applyDashboardResponse = useCallback(
    async (response: Response, fallbackMessage: string, selectDashboard: DashboardResponseSelector = (payload) => payload as DashboardPayload) => {
      const payload = (await response.json()) as DashboardApiResponse;

      if (!response.ok) {
        throw new Error(dashboardErrorMessage(payload) || fallbackMessage);
      }

      const nextDashboard = selectDashboard(payload);
      if (!nextDashboard) {
        throw new Error(fallbackMessage);
      }

      setDashboard(nextDashboard);
      setError(null);
      return nextDashboard;
    },
    [setDashboard, setError],
  );

  const submitGuidanceAnswer = useCallback(async (item: GuidanceItem, submission: GuidanceAnswerSubmission) => {
    const response = await fetch(guidanceAnswerUrl(item), {
      method: "POST",
      headers: await mutationHeaders(),
      body: JSON.stringify(submission),
    });
    await applyDashboardResponse(response, "Answer was not recorded", dashboardFromEnvelope);
    setSelectedGuidance(null);
  }, [applyDashboardResponse, setSelectedGuidance]);

  const createWorkRequest = useCallback(async (form: NewRequestForm) => {
    const response = await fetch(operatorApiUrl("/work-requests"), {
      method: "POST",
      headers: await mutationHeaders(),
      body: JSON.stringify(form),
    });
    const payload = (await response.json()) as CreateWorkRequestPayload & { error?: { message?: string } };

    if (!response.ok) {
      throw new Error(payload?.error?.message || "Request was not created");
    }
    if (!payload.dashboard || !payload.work_request) {
      throw new Error("Request was created, but the dashboard response was incomplete");
    }

    setDashboard(payload.dashboard);
    setError(null);
    return payload.work_request;
  }, [setDashboard, setError]);

  const submitComment = useCallback<SubmitContextComment>(async (target, body) => {
    const response = await fetch(operatorApiUrl("/comments"), {
      method: "POST",
      headers: await mutationHeaders(),
      body: JSON.stringify({
        target_kind: target.target_kind,
        target_id: target.target_id,
        body,
      }),
    });
    const payload = (await response.json()) as { comment?: ContextComment; dashboard?: DashboardPayload; error?: { message?: string } };

    if (!response.ok) {
      throw new Error(payload?.error?.message || "Comment was not recorded");
    }
    if (!payload.dashboard || !payload.comment) {
      throw new Error("Comment was recorded, but the dashboard response was incomplete");
    }

    setDashboard(payload.dashboard);
    setError(null);
    return payload.comment;
  }, [setDashboard, setError]);

  const resolveComment = useCallback<ResolveContextComment>(async (commentId, resolutionNote) => {
    const response = await fetch(operatorApiUrl(`/comments/${encodeURIComponent(commentId)}/resolve`), {
      method: "POST",
      headers: await mutationHeaders(),
      body: JSON.stringify({
        resolution_note: resolutionNote || "",
      }),
    });
    const payload = (await response.json()) as { comment?: ContextComment; dashboard?: DashboardPayload; error?: { message?: string } };

    if (!response.ok) {
      throw new Error(payload?.error?.message || "Comment was not resolved");
    }
    if (!payload.dashboard || !payload.comment) {
      throw new Error("Comment was resolved, but the dashboard response was incomplete");
    }

    setDashboard(payload.dashboard);
    setError(null);
    return payload.comment;
  }, [setDashboard, setError]);

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
      await applyDashboardResponse(response, "Dashboard API unavailable");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Dashboard API unavailable");
    } finally {
      loadInFlightRef.current = false;
      setLoading(false);
      if (mode === "refresh") setRefreshing(false);
    }
  }, [applyDashboardResponse, setError, setLoading, setRefreshing]);

  const syncPullRequests = useCallback(async () => {
    if (prSyncInFlightRef.current) return;
    prSyncInFlightRef.current = true;

    try {
      const headers = await mutationHeaders();
      const response = await fetch(operatorApiUrl("/github/sync-prs"), {
        method: "POST",
        headers,
        body: JSON.stringify({ mode: "auto" }),
      });
      await applyDashboardResponse(response, "GitHub PR sync unavailable", dashboardFromEnvelope);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "GitHub PR sync unavailable");
    } finally {
      prSyncInFlightRef.current = false;
    }
  }, [applyDashboardResponse, setError]);

  const copyArchitectHandoff = useCallback<CopyArchitectHandoff>(async (workRequestId, cachedHandoff) => {
    let handoff = cachedHandoff || null;

    if (!handoff) {
      const response = await fetch(operatorApiUrl(`/work-requests/${encodeURIComponent(workRequestId)}/architect-handoff`), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({}),
      });
      const payload: ArchitectHandoffPayload & { error?: { message?: string } } = await response.json();

      if (!response.ok) {
        throw new Error(payload?.error?.message || "Architect handoff unavailable");
      }

      handoff = payload.architect_handoff || null;

      if (payload.dashboard) {
        setDashboard(payload.dashboard);
      }
    }

    const prompt = handoff?.prompt?.trim();
    if (!handoff || !prompt) {
      throw new Error("Architect handoff did not include a copyable prompt");
    }

    try {
      await copyTextToClipboard(prompt);
      return { handoff, copied: true };
    } catch (caught) {
      return {
        handoff,
        copied: false,
        copyError: caught instanceof Error ? caught.message : "Clipboard copy unavailable",
      };
    }
  }, [setDashboard]);

  useEffect(() => {
    void loadDashboard("initial");
  }, [loadDashboard]);

  useEffect(() => {
    lastPrSyncAtRef.current = Date.now();
  }, []);

  useEffect(() => {
    const interval = window.setInterval(() => {
      if (document.visibilityState !== "visible" || loadInFlightRef.current || prSyncInFlightRef.current) {
        return;
      }

      const now = Date.now();
      if (now - lastPrSyncAtRef.current >= PR_SYNC_INTERVAL_MS) {
        lastPrSyncAtRef.current = now;
        void syncPullRequests();
      } else {
        void loadDashboard("silent");
      }
    }, DASHBOARD_POLL_INTERVAL_MS);

    return () => window.clearInterval(interval);
  }, [loadDashboard, syncPullRequests]);

  useEffect(() => {
    writeDashboardUiStateValue("workspaceTab", workspaceTab);
  }, [workspaceTab]);

  useEffect(() => {
    writeDashboardUiStateValue("workstreamLayout", workstreamLayout);
  }, [workstreamLayout]);

  useEffect(() => {
    writeDashboardUiStateValue("hideEmptyWorkstreams", hideEmptyWorkstreams);
  }, [hideEmptyWorkstreams]);

  useEffect(() => {
    applyDashboardTheme(theme);
  }, [theme]);

  const toggleTheme = useCallback(() => {
    const nextTheme = theme === "dark" ? "light" : "dark";
    writeStoredTheme(nextTheme);
    dispatchApp({ type: "patch", state: { theme: nextTheme } });
  }, [theme]);

  const packages = useMemo(() => allPackages(dashboard), [dashboard]);
  const requests = useMemo(() => dashboard?.work_requests?.work_requests ?? [], [dashboard]);
  const requestDetails = useMemo(() => dashboard?.work_request_details ?? [], [dashboard]);
  const guidanceItems = useMemo(() => allGuidanceItems(dashboard), [dashboard]);
  const blockerItems = useMemo(() => activeBlockerItems(packages, requestDetails), [packages, requestDetails]);
  const finishedHighlights = useMemo(() => recentFinishedHighlights(packages, requests, requestDetails), [packages, requests, requestDetails]);
  const soloSessions = useMemo(() => dashboard?.solo_sessions?.solo_sessions ?? [], [dashboard]);
  const repos = useMemo(() => repoSummaries(packages, requests, guidanceItems, soloSessions, requestDetails), [
    packages,
    requests,
    guidanceItems,
    soloSessions,
    requestDetails,
  ]);
  const workstreamRepos = useMemo(
    () => (hideEmptyWorkstreams ? repos.filter(repoWorkstreamHasWorkItems) : repos),
    [hideEmptyWorkstreams, repos],
  );
  const hiddenWorkstreamCount = repos.length - workstreamRepos.length;
  const updateAnimations = useDashboardUpdateAnimations({
    blockerItems,
    finishedHighlights,
    guidanceItems,
    packages,
    requestDetails,
    ready: dashboard !== null,
    soloSessions,
  });
  const workspacePanes = useMemo<Record<WorkspaceTab, React.ReactNode>>(
    () => ({
      workstreams: (
        <WorkstreamsPane
          repos={workstreamRepos}
          hiddenRepoCount={hiddenWorkstreamCount}
          requestDetails={requestDetails}
          activeBlockingEdges={dashboard?.active_blocking_edges ?? []}
          onSelectGuidance={setSelectedGuidance}
          onSelectCard={setSelectedCardDetail}
          onCopyArchitectHandoff={copyArchitectHandoff}
          layoutMode={workstreamLayout}
          updateAnimations={updateAnimations}
        />
      ),
      solo: <SoloSessions sessions={soloSessions} onSelectCard={setSelectedCardDetail} updateAnimations={updateAnimations} />,
    }),
    [
      copyArchitectHandoff,
      dashboard?.active_blocking_edges,
      hiddenWorkstreamCount,
      requestDetails,
      setSelectedCardDetail,
      setSelectedGuidance,
      soloSessions,
      updateAnimations,
      workstreamRepos,
      workstreamLayout,
    ],
  );

  if (loading) {
    return (
      <main className="flex min-h-screen items-center justify-center">
        <div className="flex items-center gap-3 rounded-lg border bg-card px-5 py-4 text-sm text-muted-foreground shadow-sm">
          <Loader2 className="size-4 animate-spin" />
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
              <div className="flex size-10 items-center justify-center overflow-hidden rounded-lg border bg-card shadow-sm motion-pop">
                <img src={DASHBOARD_LOGO_URL} alt="Symphony++" className="h-full w-full scale-[1.34] object-contain" />
              </div>
              <div>
                <h1 className="text-xl font-semibold">Symphony++</h1>
                <p className="text-sm text-muted-foreground">Operator cockpit</p>
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-2">
              {showUpdateSimulationControls ? <UpdateSimulationControls updateAnimations={updateAnimations} /> : null}
              <LiveLedgerBadge error={error} databasePath={dashboard?.ledger?.database} />
              <ThemeToggle theme={theme} onToggle={toggleTheme} />
              <DashboardSettingsDialog
                hideEmptyWorkstreams={hideEmptyWorkstreams}
                hiddenWorkstreamCount={hiddenWorkstreamCount}
                onHideEmptyWorkstreamsChange={setHideEmptyWorkstreams}
              />
              <Button variant="outline" size="sm" onClick={() => void loadDashboard()} disabled={refreshing} className="button-lift">
                {refreshing ? <Loader2 className="size-4 animate-spin" /> : <RefreshCw className="size-4" />}
                Refresh
              </Button>
              <NewRequestDialog
                canCopyArchitectHandoff={architectHandoffEligibleRequest}
                onCopyArchitectHandoff={copyArchitectHandoff}
                onCreateRequest={createWorkRequest}
                open={dialogState.newRequestOpen}
                onOpenChange={setNewRequestOpen}
                repos={repos}
              />
            </div>
          </div>
        </header>

        <div className="mx-auto grid max-w-[1500px] gap-5 px-4 py-5 sm:px-6 lg:px-8">
          {error ? (
            <Card className="dashboard-glass-surface border-rose-200 bg-rose-50 motion-card dark:border-rose-700/70 dark:bg-rose-950/45">
              <CardContent className="flex items-center gap-3 p-4 text-sm text-rose-800 dark:text-rose-200">
                <AlertCircle className="size-4" />
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
            <WorkspaceTabCarousel activeTab={workspaceTab} paneContent={workspacePanes} />
          </Tabs>
        </div>

        <GuidanceDialog
          item={dialogState.selectedGuidance}
          onOpenChange={(open) => {
            if (!open) setSelectedGuidance(null);
          }}
          onSubmitAnswer={submitGuidanceAnswer}
        />
        <CardDetailDialog
          selection={dialogState.selectedCardDetail}
          onOpenChange={(open) => {
            if (!open) setSelectedCardDetail(null);
          }}
          onSelectGuidance={setSelectedGuidance}
          onCopyArchitectHandoff={copyArchitectHandoff}
          onSubmitComment={submitComment}
          onResolveComment={resolveComment}
          canMutateComments={canMutateDashboardComments()}
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
  const [motions, dispatchMotions] = useReducer(updateMotionsReducer, {});
  const [countPulses, setCountPulses] = useState<Record<TopPanelKey, number>>({ blockers: 0, finished: 0, guidance: 0 });

  const applyMotions = useCallback((nextMotions: Record<string, UpdateMotion>) => {
    const motionEntries = Object.entries(nextMotions);
    if (motionEntries.length === 0) return;

    dispatchMotions({ type: "merge", motions: nextMotions });

    const timer = window.setTimeout(() => {
      dispatchMotions({ type: "settle", entries: motionEntries });
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
      dispatchMotions({ type: "clear" });
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

  const motionFor = useCallback((key?: string | null) => (ready && key ? motions[key] : undefined), [motions, ready]);
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
  const operational = request.operational_state || null;
  const openQuestions = detail.clarification_questions?.filter((question) => question.status === "open") ?? [];
  const guidanceCount = Math.max(openQuestions.length, request.open_question_count || 0, request.status === "human_info_needed" ? 1 : 0);

  return {
    signature: stableSignature([
      request.status,
      request.operational_state,
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
    status: operational?.key || request.status,
    guidanceCount,
    blockerCount: 0,
    finished: workRequestLane(request) === "finished",
  };
}

function sliceAnimationEntity(slice: PlannedSlice, pkg?: WorkPackageCard): UpdateAnimationEntity {
  const operational = sliceOperationalState(slice, pkg);
  const status = operational?.key || slice.work_package_status || slice.status;
  const blockerCount = pkg?.active_blocker_count || (pkg?.status === "blocked" || operational?.key === "blocked" ? 1 : 0);

  return {
    signature: stableSignature([
      slice.status,
      slice.work_package_id,
      slice.work_package_status,
      slice.operational_state,
      slice.updated_at,
      slice.dispatched_at,
      pkg?.status,
      pkg?.operational_state,
      pkg?.lineage,
      pkg?.active_blocker_count,
      pkg?.latest_progress_at,
      pkg?.updated_at,
      pkg?.plan,
    ]),
    status,
    guidanceCount: 0,
    blockerCount,
    finished: sliceLane(slice, pkg) === "finished" || Boolean(pkg && packageLane(pkg) === "finished"),
  };
}

function packageAnimationEntity(pkg: WorkPackageCard): UpdateAnimationEntity {
  const operational = pkg.operational_state || null;
  const blockerCount = pkg.active_blocker_count || (pkg.status === "blocked" || operational?.key === "blocked" ? 1 : 0);

  return {
    signature: stableSignature([
      pkg.status,
      pkg.operational_state,
      pkg.lineage,
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
    status: operational?.key || pkg.status,
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
    signature: stableSignature([item.state, item.at, item.title, item.kind]),
    status: item.state,
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

function WorkstreamsPane({
  repos,
  hiddenRepoCount,
  requestDetails,
  activeBlockingEdges,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  layoutMode,
  updateAnimations,
}: {
  repos: RepoSummary[];
  hiddenRepoCount: number;
  requestDetails: WorkRequestDetail[];
  activeBlockingEdges: ActiveBlockingEdge[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  layoutMode: WorkstreamLayoutMode;
  updateAnimations: DashboardUpdateAnimations;
}) {
  if (repos.length === 0) {
    return <EmptyPanel title={hiddenRepoCount > 0 ? "No active workstreams" : "No workstreams yet"} />;
  }

  return (
    <div className="grid gap-5">
      {repos.map((repo) => (
        <RepoWorkstream
          key={repoWorkstreamStateKey(repo)}
          repo={repo}
          requestDetails={requestDetails}
          activeBlockingEdges={activeBlockingEdges}
          onSelectGuidance={onSelectGuidance}
          onSelectCard={onSelectCard}
          onCopyArchitectHandoff={onCopyArchitectHandoff}
          layoutMode={layoutMode}
          updateAnimations={updateAnimations}
        />
      ))}
    </div>
  );
}

type WorkspaceTabCarouselState = {
  visibleTab: WorkspaceTab;
  previousTab: WorkspaceTab | null;
  phase: WorkspaceTabPhase;
  direction: TopPanelDirection;
  height: number | "auto";
};

type WorkspaceTabCarouselAction =
  | { type: "start"; from: WorkspaceTab; to: WorkspaceTab; height: number }
  | { type: "height"; height: number | "auto" }
  | { type: "finish" };

function initialWorkspaceTabCarouselState(activeTab: WorkspaceTab): WorkspaceTabCarouselState {
  return {
    visibleTab: activeTab,
    previousTab: null,
    phase: "idle",
    direction: "forward",
    height: "auto",
  };
}

function workspaceTabCarouselReducer(state: WorkspaceTabCarouselState, action: WorkspaceTabCarouselAction): WorkspaceTabCarouselState {
  switch (action.type) {
    case "start":
      return {
        visibleTab: action.to,
        previousTab: action.from,
        phase: "swapping",
        direction: workspaceTabDirection(action.from, action.to),
        height: action.height,
      };
    case "height":
      return { ...state, height: action.height };
    case "finish":
      return { ...state, previousTab: null, phase: "idle", height: "auto" };
  }
}

function WorkspaceTabCarousel({
  activeTab,
  paneContent,
}: {
  activeTab: WorkspaceTab;
  paneContent: Record<WorkspaceTab, React.ReactNode>;
}) {
  const [state, dispatch] = useReducer(workspaceTabCarouselReducer, activeTab, initialWorkspaceTabCarouselState);
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const visibleRef = useRef<HTMLDivElement | null>(null);
  const latestTabRef = useRef<WorkspaceTab>(activeTab);
  const transitionTokenRef = useRef(0);
  const timersRef = useRef<number[]>([]);
  const framesRef = useRef<number[]>([]);

  useEffect(
    () => () => {
      clearMotionTimers(timersRef, framesRef);
    },
    [],
  );

  useLayoutEffect(() => {
    const oldTab = latestTabRef.current;
    if (oldTab === activeTab) return;

    clearMotionTimers(timersRef, framesRef);

    latestTabRef.current = activeTab;
    transitionTokenRef.current += 1;

    dispatch({
      type: "start",
      from: oldTab,
      to: activeTab,
      height: measureElementHeight(visibleRef.current) || measureElementHeight(viewportRef.current),
    });
  }, [activeTab]);

  useLayoutEffect(() => {
    if (state.phase !== "swapping") return;

    const token = transitionTokenRef.current;
    const nextHeight = measureElementHeight(visibleRef.current);

    nextFrame(framesRef, () => {
      if (transitionTokenRef.current === token) {
        dispatch({ type: "height", height: nextHeight });
      }
    });

    later(timersRef, WORKSPACE_TAB_SLIDE_MS, () => {
      if (transitionTokenRef.current !== token) return;

      dispatch({ type: "finish" });
    });
  }, [state.phase, state.visibleTab]);

  const showSwapping = state.phase === "swapping" && state.previousTab !== null;
  const panes =
    showSwapping && state.previousTab !== null
      ? state.direction === "forward"
        ? [
            { tab: state.previousTab, current: false },
            { tab: state.visibleTab, current: true },
          ]
        : [
            { tab: state.visibleTab, current: true },
            { tab: state.previousTab, current: false },
          ]
      : [{ tab: state.visibleTab, current: true }];
  const viewportStyle = {
    height: state.height === "auto" ? undefined : `${Math.max(state.height, 0)}px`,
  } as React.CSSProperties;

  return (
    <div ref={viewportRef} className="workspace-tab-viewport" data-phase={state.phase} style={viewportStyle}>
      <div className="workspace-tab-track" data-direction={state.direction} data-phase={showSwapping ? "swapping" : "idle"}>
        {panes.map(({ tab, current }) => (
          <div
            key={tab}
            ref={current ? visibleRef : undefined}
            className="workspace-tab-pane"
            data-pane={current ? "current" : "previous"}
            aria-hidden={!current}
          >
            <div className="workspace-tab-pane-inner">{paneContent[tab]}</div>
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
          icon={<MessageSquareText className="size-6" />}
          tone="violet"
          openPanel={openPanel}
          onToggle={setOpenPanel}
          pulseToken={updateAnimations.countPulseFor("guidance")}
        />
        <StatusTile
          panel="blockers"
          title="Active Blockers"
          value={blockerItems.length}
          icon={<AlertTriangle className="size-6" />}
          tone="amber"
          openPanel={openPanel}
          onToggle={setOpenPanel}
          pulseToken={updateAnimations.countPulseFor("blockers")}
        />
        <StatusTile
          panel="finished"
          title="Finished"
          value={finishedHighlights.length}
          icon={<CheckCircle2 className="size-6" />}
          tone="emerald"
          openPanel={openPanel}
          onToggle={setOpenPanel}
          pulseToken={updateAnimations.countPulseFor("finished")}
        />
      </div>

      <TopPanelCarousel
        activePanel={openPanel}
        guidanceItems={guidanceItems}
        blockerItems={blockerItems}
        finishedHighlights={finishedHighlights}
        onSelectGuidance={onSelectGuidance}
        onSelectCard={selectCardFromPanel}
        updateAnimations={updateAnimations}
      />
    </section>
  );
}

type TopPanelContentProps = {
  panel: TopPanelKey;
  interactive?: boolean;
  guidanceItems: GuidanceItem[];
  blockerItems: BlockerItem[];
  finishedHighlights: FinishedHighlight[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
};

function TopPanelContent({
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
    <TopTray title="Recently finished requests, slices, and work packages">
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

type TopPanelCarouselState = {
  visiblePanel: TopPanelKey | null;
  previousPanel: TopPanelKey | null;
  phase: TopPanelPhase;
  direction: TopPanelDirection;
  height: number | "auto";
  transitionHeights: { from: number; to: number };
};

type TopPanelCarouselAction =
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
        dispatch({ type: "patch", state: { visiblePanel: null, phase: "idle" } });
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
    height: state.height === "auto" ? undefined : `${Math.max(state.height, 0)}px`,
    "--top-panel-next-height": `${Math.max(state.transitionHeights.to, 0)}px`,
  } as React.CSSProperties;

  return (
    <>
      <div className="top-panel-measure" ref={measureRef} aria-hidden="true">
        {activePanel ? <TopPanelContent {...contentProps} panel={activePanel} interactive={false} /> : null}
      </div>
      <div
        ref={viewportRef}
        className="top-panel-viewport"
        data-phase={state.phase}
        data-resize={resizeMode}
        style={viewportStyle}
      >
        {showStaticPrevious ? (
          <div ref={visibleRef} className="top-panel-static" data-motion="hold">
            <div className="top-panel-pane-inner">
              {state.previousPanel ? <TopPanelContent {...contentProps} panel={state.previousPanel} /> : null}
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
                <div className="top-panel-pane-inner">
                  <TopPanelContent {...contentProps} panel={panel} />
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
            <div className="top-panel-pane-inner">
              {state.visiblePanel ? <TopPanelContent {...contentProps} panel={state.visiblePanel} /> : null}
            </div>
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
        <div className={cn("flex size-12 items-center justify-center rounded-full border", tones[tone].icon)}>{icon}</div>
        <div>
          <p className="text-base font-semibold">{title}</p>
          <p className={cn("mt-2 text-3xl font-semibold", tones[tone].value)}>
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
    { kind: "guidance", label: "G", icon: <MessageSquareText className="size-3.5" />, tooltip: "Simulate new human guidance" },
    { kind: "blocker", label: "B", icon: <AlertTriangle className="size-3.5" />, tooltip: "Simulate a fresh blocker" },
    { kind: "finished", label: "F", icon: <CheckCircle2 className="size-3.5" />, tooltip: "Simulate finished work" },
    { kind: "changed", label: "U", icon: <RefreshCw className="size-3.5" />, tooltip: "Simulate a card update" },
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

function LiveLedgerBadge({ error, databasePath }: { error: string | null; databasePath?: string | null }) {
  const label = error ? "API unavailable" : "Live ledger";
  const tooltip = error ? "Dashboard API unavailable." : databasePath || "Database path unavailable.";

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Badge variant={error ? "danger" : "success"} className="cursor-help">
          {label}
        </Badge>
      </TooltipTrigger>
      <TooltipContent className="max-w-[min(34rem,calc(100vw-2rem))]">
        <div className="grid gap-1">
          <span className="text-xs font-medium">{error ? "Status" : "Database"}</span>
          <span className="break-all font-mono text-[11px] leading-relaxed text-muted-foreground">{tooltip}</span>
        </div>
      </TooltipContent>
    </Tooltip>
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
    <StateCard
      as="button"
      tone={tone}
      className="stagger-item grid gap-4 p-4 text-left hover:border-primary/50 hover:shadow-dashboard focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      style={{ animationDelay: `${index * 45}ms` }}
      onClick={() => onSelect(item)}
      data-flip-id={guidanceUpdateKey(item)}
      {...updateMotionAttributes(motion)}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <div className="flex size-8 shrink-0 items-center justify-center rounded-md bg-violet-50 text-violet-700 dark:bg-violet-950/70 dark:text-violet-200">
              <Route className="size-4" />
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
          label={item.source === "guidance" ? "Guidance Needed" : "Clarify"}
          variant={item.source === "guidance" ? "danger" : "warning"}
        />
      </div>
    </StateCard>
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
    <StateCard
      tone="blocked"
      className={cn("stagger-item p-4", onSelectCard && "card-detail-trigger")}
      style={{ animationDelay: `${index * 45}ms` }}
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
        <AlertTriangle className="size-4" />
        {item.blockerCount} active blocker{item.blockerCount === 1 ? "" : "s"}
      </div>
    </StateCard>
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
    <StateCard
      tone="finished"
      className={cn("stagger-item p-3", onSelectCard && "card-detail-trigger")}
      style={{ animationDelay: `${index * 30}ms` }}
      data-flip-id={finishedHighlightUpdateKey(item)}
      data-card-detail-kind={cardDetailDataKind(item.selection)}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start gap-2">
        <CheckCircle2 className="mt-0.5 size-4 shrink-0 text-emerald-600" />
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{item.title}</p>
          <p className="mt-1 truncate text-xs text-muted-foreground">{item.repo}</p>
        </div>
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <AnimatedBadge label={item.state || "Finished"} variant="success" />
        {item.at ? (
          <span className="flex items-center gap-1 text-xs text-muted-foreground">
            <Clock3 className="size-3.5" />
            {formatDate(item.at)}
          </span>
        ) : null}
      </div>
    </StateCard>
  );
}

function RepoWorkstream({
  repo,
  requestDetails,
  activeBlockingEdges,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  layoutMode,
  updateAnimations,
}: {
  repo: RepoSummary;
  requestDetails: WorkRequestDetail[];
  activeBlockingEdges: ActiveBlockingEdge[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  layoutMode: WorkstreamLayoutMode;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const stateKey = repoWorkstreamStateKey(repo);
  const [open, setOpen] = useState(() => readStoredRepoWorkstreamOpen(stateKey, defaultRepoWorkstreamOpen(repo)));
  const repoDetails = useMemo(
    () => requestDetails.filter((detail) => repoIdentityKey(detail.work_request) === repo.repoKey),
    [repo.repoKey, requestDetails],
  );
  const unlinkedPackages = useMemo(
    () => repo.packages.filter((pkg) => !packageLinkedToRequest(pkg, requestDetails)),
    [repo.packages, requestDetails],
  );
  const [openMotion, setOpenMotion] = useState(false);
  const previousOpenRef = useRef(open);
  const openMotionTimerRef = useRef<number | null>(null);

  useEffect(
    () => () => {
      if (openMotionTimerRef.current !== null) {
        window.clearTimeout(openMotionTimerRef.current);
      }
    },
    [],
  );

  useLayoutEffect(() => {
    if (dashboardPrefersReducedMotion()) {
      previousOpenRef.current = open;
      return;
    }

    if (open && !previousOpenRef.current) {
      if (openMotionTimerRef.current !== null) {
        window.clearTimeout(openMotionTimerRef.current);
      }
      setOpenMotion(true);
      openMotionTimerRef.current = window.setTimeout(() => {
        setOpenMotion(false);
        openMotionTimerRef.current = null;
      }, REPO_WORKSTREAM_MOTION_MS + 120);
    }
    previousOpenRef.current = open;
  }, [open]);

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
                <Button variant="ghost" size="icon" className="size-8 shrink-0" aria-label={`${open ? "Collapse" : "Open"} ${repo.repo}`}>
                  <ChevronRight className={cn("size-4 transition-transform duration-200", open && "rotate-90")} />
                </Button>
              </CollapsibleTrigger>
              <div className="min-w-0">
                <CardTitle className="flex items-center gap-2">
                  <GitBranch className="size-4 text-primary" />
                  <span className="truncate" title={repo.repoRemote || undefined}>{repo.repo}</span>
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
          <CardContent className="p-3 sm:p-4" data-board-open-motion={openMotion ? "open" : "idle"}>
            <WorkstreamBoard
              repoDetails={repoDetails}
              packages={repo.packages}
              unlinkedPackages={unlinkedPackages}
              activeBlockingEdges={activeBlockingEdges}
              onSelectGuidance={onSelectGuidance}
              onSelectCard={onSelectCard}
              onCopyArchitectHandoff={onCopyArchitectHandoff}
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
              "absolute size-4 transition-all duration-200",
              dark ? "rotate-45 scale-0 opacity-0" : "rotate-0 scale-100 opacity-100",
            )}
          />
          <Moon
            className={cn(
              "absolute size-4 transition-all duration-200",
              dark ? "rotate-0 scale-100 opacity-100" : "-rotate-45 scale-0 opacity-0",
            )}
          />
        </Button>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  );
}

function DashboardSettingsDialog({
  hideEmptyWorkstreams,
  hiddenWorkstreamCount,
  onHideEmptyWorkstreamsChange,
}: {
  hideEmptyWorkstreams: boolean;
  hiddenWorkstreamCount: number;
  onHideEmptyWorkstreamsChange: (value: boolean) => void;
}) {
  const [open, setOpen] = useState(false);
  const visibilityLabel = hideEmptyWorkstreams
    ? workstreamHiddenSummary(hiddenWorkstreamCount)
    : "Showing repos even when they have no requests, slices, or work packages.";

  return (
    <>
      <Tooltip>
        <TooltipTrigger asChild>
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="button-lift"
            aria-label="Dashboard settings"
            onClick={() => setOpen(true)}
          >
            <Settings2 className="size-4" />
          </Button>
        </TooltipTrigger>
        <TooltipContent>Settings</TooltipContent>
      </Tooltip>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="dashboard-dialog-content max-w-md">
          <DialogHeader>
            <DialogTitle>Settings</DialogTitle>
            <DialogDescription>Dashboard display preferences</DialogDescription>
          </DialogHeader>

          <div className="flex items-center justify-between gap-4 rounded-md border bg-card/60 p-3">
            <div className="min-w-0">
              <span className="block text-sm font-medium">Hide empty workstreams</span>
              <span className="mt-1 block text-xs text-muted-foreground">{visibilityLabel}</span>
            </div>
            <button
              type="button"
              role="switch"
              aria-checked={hideEmptyWorkstreams}
              aria-label="Hide empty workstreams"
              className={cn(
                "relative h-6 w-11 shrink-0 rounded-full bg-muted transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                hideEmptyWorkstreams && "bg-primary",
              )}
              onClick={() => onHideEmptyWorkstreamsChange(!hideEmptyWorkstreams)}
            >
              <span
                className={cn(
                  "absolute left-1 top-1 size-4 rounded-full bg-background shadow transition-transform",
                  hideEmptyWorkstreams && "translate-x-5",
                )}
              />
            </button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}

function workstreamHiddenSummary(hiddenWorkstreamCount: number) {
  if (hiddenWorkstreamCount <= 0) return "Only repos with requests, slices, or work packages appear.";
  return hiddenWorkstreamCount === 1 ? "1 empty repo hidden" : `${hiddenWorkstreamCount} empty repos hidden`;
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

function WorkstreamBoard({
  repoDetails,
  packages,
  unlinkedPackages,
  activeBlockingEdges,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  layoutMode,
  updateAnimations,
}: {
  repoDetails: WorkRequestDetail[];
  packages: WorkPackageCard[];
  unlinkedPackages: WorkPackageCard[];
  activeBlockingEdges: ActiveBlockingEdge[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  layoutMode: WorkstreamLayoutMode;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const shellRef = useRef<HTMLDivElement | null>(null);
  const boardRef = useRef<HTMLDivElement | null>(null);
  const sortedDetails = useMemo(() => sortWorkRequestDetails(repoDetails), [repoDetails]);
  const requested = sortedDetails;
  const packageById = useMemo(() => new Map(packages.map((pkg) => [pkg.id, pkg])), [packages]);
  const sliceEntries = useMemo(
    () =>
      sortedDetails.flatMap((detail, requestIndex) =>
        sortPlannedSlices(detail.planned_slices ?? []).map((slice) => ({
          detail,
          slice,
          pkg: slice.work_package_id ? packageById.get(slice.work_package_id) : undefined,
          requestIndex,
        })),
      ),
    [packageById, sortedDetails],
  );
  const active = useMemo(() => sortSliceEntries(sliceEntries), [sliceEntries]);
  const packageEntries = useMemo(() => sortSliceEntries(sliceEntries.filter((entry) => entry.pkg)), [sliceEntries]);
  const implementing = useMemo(() => packageEntries.filter((entry) => sliceLane(entry.slice, entry.pkg) !== "finished"), [packageEntries]);
  const finished = useMemo(() => packageEntries.filter((entry) => sliceLane(entry.slice, entry.pkg) === "finished"), [packageEntries]);
  const sortedUnlinkedPackages = useMemo(() => sortPackages(unlinkedPackages), [unlinkedPackages]);
  const activePackages = useMemo<WorkPackageCard[]>(() => [], []);
  const implementingPackages = useMemo(() => sortedUnlinkedPackages.filter((pkg) => packageLane(pkg) !== "finished"), [sortedUnlinkedPackages]);
  const finishedPackages = useMemo(() => sortedUnlinkedPackages.filter((pkg) => packageLane(pkg) === "finished"), [sortedUnlinkedPackages]);
  const alignedRows = useMemo(
    () => workstreamRows(sortedDetails, sliceEntries, activePackages, implementingPackages, finishedPackages),
    [activePackages, finishedPackages, implementingPackages, sliceEntries, sortedDetails],
  );
  const alignedMeasurementRows = useMemo<BoardLayoutMeasurementRow[]>(
    () =>
      alignedRows.map((row, index) => ({
        activeSlotKeys: row.active.map(({ slice }) => slice.id),
        minHeight: row.minHeight,
        rowKey: workstreamRowKey(row, index),
      })),
    [alignedRows],
  );
  const {
    rowTemplate,
    slotTemplates: alignedSlotTemplates,
  } = useAlignedBoardLayout(boardRef, alignedMeasurementRows, layoutMode);
  const wires = useMemo(() => workstreamWires(sortedDetails, packages, activeBlockingEdges), [activeBlockingEdges, sortedDetails, packages]);
  const { paths: wirePaths, size: wireSize } = useBoardWirePaths(boardRef, wires, layoutMode);
  const layoutMotion = useBoardLayoutMotion(shellRef, boardRef, layoutMode);

  return (
    <div ref={shellRef} className="workstream-board-shell">
      <div
        ref={boardRef}
        className={cn("jira-board workstream-board", layoutMode === "aligned" && "workstream-board-aligned")}
        data-layout={layoutMode}
        data-board-motion={layoutMotion ? "layout" : "idle"}
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
            onCopyArchitectHandoff={onCopyArchitectHandoff}
            updateAnimations={updateAnimations}
            slotTemplates={alignedSlotTemplates}
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
            onCopyArchitectHandoff={onCopyArchitectHandoff}
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
  onCopyArchitectHandoff,
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
  onCopyArchitectHandoff: CopyArchitectHandoff;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const workPackageEntries = sortSliceEntries([...implementing, ...finished]);

  return (
    <>
      <BoardLaneColumn title="Requests" count={requested.length} emptyLabel="No requested work">
        {requested.map((detail, index) => (
          <RequestCard
            key={detail.work_request.id}
            detail={detail}
            onSelectGuidance={onSelectGuidance}
            onSelectCard={() => onSelectCard({ kind: "request", detail })}
            onCopyArchitectHandoff={onCopyArchitectHandoff}
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
        {workPackageEntries.map(({ detail, slice, pkg }, index) => (
          pkg ? <PackageCard
            key={pkg.id}
            pkg={pkg}
            lane={sliceLane(slice, pkg)}
            index={index}
            nodeId={packageNodeId(pkg)}
            sequence={slice.sequence}
            onSelectCard={() => onSelectCard({ kind: "package", pkg, detail, slice })}
            motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
          /> : null
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
  slotTemplates,
  requestedCount,
  sliceCount,
  workPackageCount,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  updateAnimations,
}: {
  rows: WorkstreamRow[];
  rowTemplate: string;
  slotTemplates: Record<string, string>;
  requestedCount: number;
  sliceCount: number;
  workPackageCount: number;
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const rowStyle = { gridTemplateRows: rowTemplate } as React.CSSProperties;

  return (
    <>
      <BoardLaneColumn title="Requests" count={requestedCount} emptyLabel="No requested work" bodyStyle={rowStyle} aligned>
        {rows.map((row, index) => {
          const rowKey = workstreamRowKey(row, index);

          return (
            <FeatureLaneRow key={rowKey} rowKey={rowKey} lane="requested">
              {row.detail ? (
                <RequestCard
                  detail={row.detail}
                  onSelectGuidance={onSelectGuidance}
                  onSelectCard={() => onSelectCard({ kind: "request", detail: row.detail! })}
                  onCopyArchitectHandoff={onCopyArchitectHandoff}
                  index={index}
                  nodeId={requestNodeId(row.detail)}
                  motion={updateAnimations.motionFor(requestUpdateKey(row.detail))}
                />
              ) : null}
            </FeatureLaneRow>
          );
        })}
      </BoardLaneColumn>
      <BoardLaneColumn title="Slices" count={sliceCount} emptyLabel="No slices ready" bodyStyle={rowStyle} aligned>
        {rows.map((row, index) => {
          const rowKey = workstreamRowKey(row, index);

          return (
            <FeatureLaneRow key={rowKey} rowKey={rowKey} lane="slices" slotTemplate={slotTemplates[rowKey]}>
              {row.active.map(({ detail, slice, pkg }, sliceIndex) => (
                <AlignedCardSlot key={slice.id} rowKey={rowKey} slotKey={slice.id} lane="slices">
                  <SliceCard
                    slice={slice}
                    pkg={pkg}
                    lane="slices"
                    index={sliceIndex}
                    nodeId={sliceNodeId(slice)}
                    onSelectCard={() => onSelectCard({ kind: "slice", detail, slice, pkg })}
                    motion={updateAnimations.motionFor(sliceUpdateKey(slice))}
                  />
                </AlignedCardSlot>
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
          );
        })}
      </BoardLaneColumn>
      <BoardLaneColumn title="Work Packages" count={workPackageCount} emptyLabel="No work packages yet" bodyStyle={rowStyle} aligned>
        {rows.map((row, index) => {
          const rowKey = workstreamRowKey(row, index);

          return (
            <FeatureLaneRow
              key={rowKey}
              rowKey={rowKey}
              lane="packages"
              slotTemplate={slotTemplates[rowKey]}
              emptyOverride={!row.active.some(({ pkg }) => pkg) && row.implementingPackages.length + row.finishedPackages.length === 0}
            >
              {row.active.map(({ detail, slice, pkg }, sliceIndex) => (
                <AlignedCardSlot key={slice.id} rowKey={rowKey} slotKey={slice.id} lane="packages" empty={!pkg}>
                  {pkg ? (
                    <PackageCard
                      pkg={pkg}
                      lane={sliceLane(slice, pkg)}
                      index={sliceIndex}
                      nodeId={packageNodeId(pkg)}
                      sequence={slice.sequence}
                      onSelectCard={() => onSelectCard({ kind: "package", pkg, detail, slice })}
                      motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
                    />
                  ) : null}
                </AlignedCardSlot>
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
          );
        })}
      </BoardLaneColumn>
    </>
  );
}

function stateCardBodyMotionKey(...parts: Array<string | number | boolean | null | undefined>) {
  return parts.map((part) => (part === null || part === undefined ? "" : String(part))).join("|");
}

function interactiveCardProps(onActivate?: () => void): React.HTMLAttributes<HTMLDivElement> {
  if (!onActivate) return {};

  return {
    role: "button",
    tabIndex: 0,
    onClick: onActivate,
    onKeyDown: (event) => {
      if (event.defaultPrevented || event.target !== event.currentTarget) return;
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        onActivate();
      }
    },
  };
}

function SequenceBadge({ sequence }: { sequence?: number | null }) {
  if (!sequence) return null;

  return (
    <span
      className="inline-flex h-5 shrink-0 items-center rounded-md border border-border/70 bg-background/70 px-1.5 text-[11px] font-semibold leading-none text-muted-foreground shadow-sm"
      title={`Slice ${sequence}`}
    >
      S{sequence}
    </span>
  );
}

function RequestCard({
  detail,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  index = 0,
  nodeId,
  motion,
}: {
  detail: WorkRequestDetail;
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard?: () => void;
  onCopyArchitectHandoff?: CopyArchitectHandoff;
  index?: number;
  nodeId?: string;
  motion?: UpdateMotion;
}) {
  const request = detail.work_request;
  const openQuestions = detail.clarification_questions?.filter((question) => question.status === "open") ?? [];
  const questionCount = openQuestions.length || request.open_question_count || 0;
  const operational = request.operational_state || null;
  const quietMerged = [operational?.key, request.status].some(isFinishedBoardStatus);
  const question = quietMerged ? undefined : openQuestions[0];
  const description = quietMerged ? null : firstParagraph(request.human_description);
  const handoffEligible = architectHandoffEligibleRequest(request);
  const handoffHasOpenQuestions = !quietMerged && questionCount > 0;
  const handoffIdentity = `${questionCount}:${request.id}:${request.status || ""}:${request.updated_at || ""}`;
  const commentSignal = cardCommentSignal(request.open_comment_count, request.comment_count);
  const {
    cachedHandoff,
    recordCopyError,
    recordCopyResult,
    startCopy,
    state: handoffCopyState,
  } = useScopedHandoffCopy(handoffIdentity);

  const answerQuestion = question
    ? () => {
        onSelectGuidance(clarificationGuidanceItem(detail, question));
      }
    : undefined;
  const canCopyHandoff = !quietMerged && handoffEligible && Boolean(onCopyArchitectHandoff);
  const handoffSignalValue =
    handoffCopyState === "copying"
      ? "Copying..."
      : handoffCopyState === "copied"
        ? "Copied"
        : handoffCopyState === "error"
          ? "Try again"
          : handoffHasOpenQuestions
            ? "Resume prompt"
            : "Copy prompt";
  const copyHandoff = useCallback(
    async () => {
      if (!onCopyArchitectHandoff) return;

      startCopy();

      try {
        recordCopyResult(await onCopyArchitectHandoff(request.id, cachedHandoff()));
      } catch {
        recordCopyError("Architect handoff could not be copied");
      }
    },
    [cachedHandoff, onCopyArchitectHandoff, recordCopyError, recordCopyResult, request.id, startCopy],
  );
  const tone = requestStateCardTone(detail);
  const bodyMotionKey = stateCardBodyMotionKey(
    "request",
    request.id,
    quietMerged,
    description,
    questionCount,
    question?.id,
    question?.question,
    canCopyHandoff,
    handoffHasOpenQuestions,
    handoffCopyState,
    commentSignal ? `${commentSignal.open}:${commentSignal.total}` : null,
  );

  return (
    <StateCard
      tone={tone}
      className={cn("stagger-item p-3", onSelectCard && "card-detail-trigger")}
      data-wire-id={nodeId}
      data-card-detail-kind="request"
      style={{ animationDelay: `${index * 30}ms` }}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{request.title || request.id}</p>
          {!quietMerged ? <p className="mt-1 text-xs text-muted-foreground">{request.work_type || "feature"}</p> : null}
        </div>
        <AnimatedBadge
          label={operationalLabel(operational, request.status)}
          variant={operationalBadgeVariant(operational, request.status)}
          className="shrink-0"
        />
      </div>
      <AnimatedCardBody motionKey={bodyMotionKey}>
        {description ? <p className="request-card-description mt-3 text-xs leading-relaxed text-muted-foreground">{description}</p> : null}
        {!quietMerged && questionCount > 0 ? (
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
        {canCopyHandoff || commentSignal ? (
          <div className="mt-3 flex min-w-0 items-stretch gap-2">
            {canCopyHandoff ? (
              <CardSignal
                className="min-h-12 flex-1"
                label={handoffHasOpenQuestions ? "Architect Handoff" : "Agent Handoff"}
                value={handoffSignalValue}
                tone={handoffHasOpenQuestions ? "muted" : "info"}
                onClick={copyHandoff}
                ariaLabel={`Copy agent handoff for ${request.title || request.id}`}
              />
            ) : null}
            {commentSignal ? (
              <CommentCardSignalButton
                signal={commentSignal}
                title={request.title || request.id}
                onClick={onSelectCard}
                expanded={!canCopyHandoff}
              />
            ) : null}
          </div>
        ) : null}
      </AnimatedCardBody>
    </StateCard>
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
  const operational = sliceOperationalState(slice, pkg);
  const rawStatus = lane === "slices" ? slice.status : slice.work_package_status || slice.status;
  const tone = sliceCardTone(slice, pkg, lane);
  const detail = slice.status === "skipped" ? null : sliceCardSubtitle(slice, pkg, operational, rawStatus);
  const blockerSignal = lane === "slices" ? null : packageBlockerSignal(pkg, operational);
  const commentSignal = cardCommentSignal(slice.open_comment_count, slice.comment_count);
  const bodyMotionKey = stateCardBodyMotionKey(
    "slice",
    slice.id,
    lane,
    detail,
    blockerSignal?.label,
    blockerSignal?.value,
    blockerSignal?.tone,
    commentSignal ? `${commentSignal.open}:${commentSignal.total}` : null,
  );

  return (
    <StateCard
      tone={tone}
      className={cn("stagger-item p-3", onSelectCard && "card-detail-trigger")}
      data-wire-id={nodeId}
      data-card-detail-kind={pkg && lane !== "slices" ? "package" : "slice"}
      style={{ animationDelay: `${index * 30}ms` }}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <div className="flex min-w-0 items-center gap-2">
          <SequenceBadge sequence={slice.sequence} />
          <p className="min-w-0 truncate text-sm font-medium">{slice.title || pkg?.title || slice.id}</p>
        </div>
        <AnimatedBadge
          label={operationalLabel(operational, rawStatus)}
          variant={operationalBadgeVariant(operational, rawStatus)}
          className="shrink-0"
        />
      </div>
      <AnimatedCardBody motionKey={bodyMotionKey}>
        {detail ? <p className="mt-2 line-clamp-2 text-xs text-muted-foreground">{detail}</p> : null}
        {blockerSignal || commentSignal ? (
          <div className="mt-3 flex min-w-0 items-stretch gap-2">
            {blockerSignal ? (
              <CardSignal
                className="min-h-12 flex-1"
                label={blockerSignal.label}
                value={blockerSignal.value}
                tone={blockerSignal.tone}
                onClick={onSelectCard}
                ariaLabel={`Open blockers for ${slice.title || pkg?.title || slice.id}`}
              />
            ) : null}
            {commentSignal ? (
              <CommentCardSignalButton
                signal={commentSignal}
                title={slice.title || pkg?.title || slice.id}
                onClick={onSelectCard}
                expanded={!blockerSignal}
              />
            ) : null}
          </div>
        ) : null}
      </AnimatedCardBody>
    </StateCard>
  );
}

function sliceCardSubtitle(
  slice: PlannedSlice,
  pkg: WorkPackageCard | undefined,
  operational: WorkPackageCard["operational_state"],
  status?: string | null,
) {
  const terminal = [operational?.key, status, pkg?.status].some((key) => key === "blocked" || isFinishedBoardStatus(key));
  if (terminal) return null;
  if (pkg) return `Linked package: ${operationalLabel(pkg.operational_state, pkg.status)}.`;
  return slice.goal || slice.work_package_kind;
}

function cardCommentSignal(openCount?: number | null, totalCount?: number | null): CommentCardSignal | null {
  const open = openCount ?? 0;
  if (open <= 0) return null;

  const total = totalCount ?? open;
  return { open, total };
}

function CommentCardSignalButton({
  signal,
  title,
  onClick,
  expanded = false,
  className,
}: {
  signal: CommentCardSignal;
  title: string;
  onClick?: () => void;
  expanded?: boolean;
  className?: string;
}) {
  const summary = totalCommentSignalLabel(signal);
  const ariaLabel = `Open comments for ${title}: ${summary}`;
  const signalClassName = cn("comment-card-signal", expanded && "comment-card-signal-expanded", className);

  return (
    <CardSignalFrame
      tone="warning"
      className={signalClassName}
      title={summary}
      ariaLabel={ariaLabel}
      onClick={onClick}
    >
      <MessageSquareText className="size-4" />
      {expanded ? <span className="comment-card-signal-label">Unresolved Comments</span> : null}
      <span className="comment-card-signal-count">{signal.open}</span>
    </CardSignalFrame>
  );
}

function totalCommentSignalLabel(signal: CommentCardSignal) {
  const totalSuffix = signal.total > signal.open ? `, ${signal.total} total` : "";
  return `${signal.open} unresolved ${plural("comment", signal.open)}${totalSuffix}`;
}

function plural(word: string, count: number) {
  return count === 1 ? word : `${word}s`;
}

function PackageCard({
  pkg,
  lane,
  index = 0,
  nodeId,
  sequence,
  onSelectCard,
  motion,
}: {
  pkg: WorkPackageCard;
  lane: BoardLane;
  index?: number;
  nodeId?: string;
  sequence?: number | null;
  onSelectCard?: () => void;
  motion?: UpdateMotion;
}) {
  const tone = packageCardTone(pkg, lane);
  const attention = packageAttentionSignal(pkg);
  const commentSignal = cardCommentSignal(pkg.open_comment_count, pkg.comment_count);
  const operational = pkg.operational_state || null;
  const bodyMotionKey = stateCardBodyMotionKey(
    "package",
    pkg.id,
    attention?.label,
    attention?.value,
    attention?.tone,
    commentSignal ? `${commentSignal.open}:${commentSignal.total}` : null,
  );

  return (
    <StateCard
      tone={tone}
      className={cn("stagger-item p-3", onSelectCard && "card-detail-trigger")}
      data-wire-id={nodeId}
      data-card-detail-kind="package"
      style={{ animationDelay: `${index * 30}ms` }}
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <div className="flex min-w-0 items-center gap-2">
          <SequenceBadge sequence={sequence} />
          <p className="min-w-0 truncate text-sm font-medium">{pkg.title || pkg.id}</p>
        </div>
        <AnimatedBadge label={operationalLabel(operational, pkg.status)} variant={operationalBadgeVariant(operational, pkg.status)} className="shrink-0" />
      </div>
      <AnimatedCardBody motionKey={bodyMotionKey}>
        {attention || commentSignal ? (
          <div className="mt-3 flex min-w-0 items-stretch gap-2">
            {attention ? <CardSignal className="min-h-12 flex-1" label={attention.label} value={attention.value} tone={attention.tone} /> : null}
            {commentSignal ? (
              <CommentCardSignalButton
                signal={commentSignal}
                title={pkg.title || pkg.id}
                onClick={onSelectCard}
                expanded={!attention}
              />
            ) : null}
          </div>
        ) : null}
      </AnimatedCardBody>
    </StateCard>
  );
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
        <SoloSessionGroup key={`${group.repoKey}:${group.baseBranch}`} group={group} onSelectCard={onSelectCard} updateAnimations={updateAnimations} />
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
    repoKey: string;
    repo: string;
    repoRemote?: string | null;
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
              <GitBranch className="size-4 text-primary" />
              <span className="truncate" title={group.repoRemote || undefined}>{group.repo}</span>
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
  const bodyMotionKey = stateCardBodyMotionKey(
    "solo",
    session.id,
    attention.guidanceCount,
    attention.blockerCount,
    latestSignalValue,
    showLatest,
    latest?.kind_label,
    latest?.kind,
    latestText,
    session.last_activity_at,
    session.updated_at,
  );

  return (
    <StateCard
      tone={tone}
      className="stagger-item card-detail-trigger p-3"
      style={{ animationDelay: `${index * 35}ms` }}
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

      <AnimatedCardBody motionKey={bodyMotionKey}>
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
      </AnimatedCardBody>
    </StateCard>
  );
}

function soloSessionGroups(sessions: SoloSession[]) {
  const groups = new Map<
    string,
    {
      repoKey: string;
      repo: string;
      repoRemote?: string | null;
      baseBranch: string;
      active: SoloSession[];
      finished: SoloSession[];
      guidanceCount: number;
      blockerCount: number;
    }
  >();

  sessions.forEach((session) => {
    const repoKey = repoIdentityKey(session);
    const repo = repoDisplayName(session);
    const baseBranch = session.base_branch?.trim() || "main";
    const key = `${repoKey}:${baseBranch}`;
    const group =
      groups.get(key) ||
      ({
        repoKey,
        repo,
        repoRemote: repoRemoteName(session),
        baseBranch,
        active: [],
        finished: [],
        guidanceCount: 0,
        blockerCount: 0,
      } satisfies {
        repo: string;
        repoKey: string;
        repoRemote?: string | null;
        baseBranch: string;
        active: SoloSession[];
        finished: SoloSession[];
        guidanceCount: number;
        blockerCount: number;
      });

    const attention = soloSessionAttention(session);
    group.repoRemote ||= repoRemoteName(session);
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
  return sortedCopy(sessions, (left, right) => soloSessionTime(right) - soloSessionTime(left));
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
  return sortedCopy(entries, (left, right) => {
    const leftSequence = left.sequence ?? 0;
    const rightSequence = right.sequence ?? 0;
    if (leftSequence !== rightSequence) return leftSequence - rightSequence;
    return sortableTime(left.created_at || left.updated_at) - sortableTime(right.created_at || right.updated_at);
  });
}

function latestSoloEntries(entries: SoloSessionEntry[]) {
  return sortedCopy(entries, (left, right) => {
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

  return sortedCopy([...grouped.entries()], ([left], [right]) => soloEntryKindRank(left) - soloEntryKindRank(right))
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

type DetailResourceState<T> = {
  payload: T | null;
  loading: boolean;
  error: string | null;
};

type CardDetailDialogState = {
  package: DetailResourceState<WorkPackageDetailPayload>;
  solo: DetailResourceState<SoloSessionDetailPayload>;
};

type CardDetailDialogAction =
  | { type: "resetPackage" }
  | { type: "loadPackage" }
  | { type: "packageSuccess"; payload: WorkPackageDetailPayload }
  | { type: "packageError"; error: string }
  | { type: "resetSolo" }
  | { type: "loadSolo" }
  | { type: "soloSuccess"; payload: SoloSessionDetailPayload }
  | { type: "soloError"; error: string };

const emptyPackageDetailState: DetailResourceState<WorkPackageDetailPayload> = {
  payload: null,
  loading: false,
  error: null,
};
const emptySoloDetailState: DetailResourceState<SoloSessionDetailPayload> = {
  payload: null,
  loading: false,
  error: null,
};
const initialCardDetailDialogState: CardDetailDialogState = {
  package: emptyPackageDetailState,
  solo: emptySoloDetailState,
};

function cardDetailDialogReducer(state: CardDetailDialogState, action: CardDetailDialogAction): CardDetailDialogState {
  switch (action.type) {
    case "resetPackage":
      return { ...state, package: emptyPackageDetailState };
    case "loadPackage":
      return { ...state, package: { payload: null, loading: true, error: null } };
    case "packageSuccess":
      return { ...state, package: { payload: action.payload, loading: false, error: null } };
    case "packageError":
      return { ...state, package: { payload: null, loading: false, error: action.error } };
    case "resetSolo":
      return { ...state, solo: emptySoloDetailState };
    case "loadSolo":
      return { ...state, solo: { payload: null, loading: true, error: null } };
    case "soloSuccess":
      return { ...state, solo: { payload: action.payload, loading: false, error: null } };
    case "soloError":
      return { ...state, solo: { payload: null, loading: false, error: action.error } };
  }
}

async function loadOperatorPayload<T>(path: string, signal: AbortSignal, fallbackMessage: string): Promise<T> {
  const response = await fetch(operatorApiUrl(path), {
    headers: jsonHeaders(),
    signal,
  });
  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload?.error?.message || fallbackMessage);
  }
  return payload;
}

function CardDetailDialog({
  selection,
  onOpenChange,
  onSelectGuidance,
  onCopyArchitectHandoff,
  onSubmitComment,
  onResolveComment,
  canMutateComments,
}: {
  selection: CardDetailSelection | null;
  onOpenChange: (open: boolean) => void;
  onSelectGuidance: (item: GuidanceItem) => void;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
  canMutateComments: boolean;
}) {
  const [state, dispatch] = useReducer(cardDetailDialogReducer, initialCardDetailDialogState);
  const packageId = selection?.kind === "package" ? selection.pkg.id : null;
  const soloSessionId = selection?.kind === "solo" ? selection.session.id : null;

  useEffect(() => {
    if (!packageId) {
      dispatch({ type: "resetPackage" });
      return;
    }

    const controller = new AbortController();
    dispatch({ type: "loadPackage" });

    loadOperatorPayload<WorkPackageDetailPayload>(`/work-packages/${encodeURIComponent(packageId)}`, controller.signal, "Package detail unavailable")
      .then((payload) => {
        if (!controller.signal.aborted) dispatch({ type: "packageSuccess", payload });
      })
      .catch((caught) => {
        if (caught instanceof DOMException && caught.name === "AbortError") return;
        if (!controller.signal.aborted) dispatch({ type: "packageError", error: caught instanceof Error ? caught.message : "Package detail unavailable" });
      });

    return () => controller.abort();
  }, [packageId]);

  useEffect(() => {
    if (!soloSessionId) {
      dispatch({ type: "resetSolo" });
      return;
    }

    const controller = new AbortController();
    dispatch({ type: "loadSolo" });

    loadOperatorPayload<SoloSessionDetailPayload>(`/solo-sessions/${encodeURIComponent(soloSessionId)}`, controller.signal, "Solo Session detail unavailable")
      .then((payload) => {
        if (!controller.signal.aborted) dispatch({ type: "soloSuccess", payload });
      })
      .catch((caught) => {
        if (caught instanceof DOMException && caught.name === "AbortError") return;
        if (!controller.signal.aborted) dispatch({ type: "soloError", error: caught instanceof Error ? caught.message : "Solo Session detail unavailable" });
      });

    return () => controller.abort();
  }, [soloSessionId]);

  const effectiveLoadingPackage = selection?.kind === "package" && !state.package.payload && !state.package.error ? true : state.package.loading;
  const effectiveLoadingSolo = selection?.kind === "solo" && !state.solo.payload && !state.solo.error ? true : state.solo.loading;
  const detailMotionKey = cardDetailMotionKey(selection, {
    loadingPackage: effectiveLoadingPackage,
    loadingSolo: effectiveLoadingSolo,
    packageDetail: state.package.payload,
    packageError: state.package.error,
    soloDetail: state.solo.payload,
    soloError: state.solo.error,
  });

  return (
    <Dialog open={Boolean(selection)} onOpenChange={onOpenChange}>
      <DialogContent className="dashboard-dialog-content card-detail-dialog">
        <NaturalDetailBody motionKey={detailMotionKey}>
          {selection?.kind === "request" ? (
            <RequestDetailContent
              detail={selection.detail}
              onSelectGuidance={onSelectGuidance}
              onCopyArchitectHandoff={onCopyArchitectHandoff}
              onSubmitComment={onSubmitComment}
              onResolveComment={onResolveComment}
              canMutateComments={canMutateComments}
            />
          ) : null}
          {selection?.kind === "slice" ? (
            <SliceDetailContent
              detail={selection.detail}
              slice={selection.slice}
              pkg={selection.pkg}
              onSubmitComment={onSubmitComment}
              onResolveComment={onResolveComment}
              canMutateComments={canMutateComments}
            />
          ) : null}
          {selection?.kind === "package" ? (
            <PackageDetailContent
              selection={selection}
              detailPayload={state.package.payload}
              loading={effectiveLoadingPackage}
              error={state.package.error}
              onSubmitComment={onSubmitComment}
              onResolveComment={onResolveComment}
              canMutateComments={canMutateComments}
            />
          ) : null}
          {selection?.kind === "solo" ? (
            <SoloSessionDetailContent session={selection.session} detailPayload={state.solo.payload} loading={effectiveLoadingSolo} error={state.solo.error} />
          ) : null}
        </NaturalDetailBody>
      </DialogContent>
    </Dialog>
  );
}

function NaturalDetailBody({ motionKey, children }: { motionKey: string; children: React.ReactNode }) {
  return (
    <div className="detail-modal-natural-frame" data-detail-motion-key={motionKey}>
      <div className="detail-modal-size-inner">{children}</div>
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

function RequestDetailContent({
  detail,
  onSelectGuidance,
  onCopyArchitectHandoff,
  onSubmitComment,
  onResolveComment,
  canMutateComments,
}: {
  detail: WorkRequestDetail;
  onSelectGuidance: (item: GuidanceItem) => void;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
  canMutateComments: boolean;
}) {
  const request = detail.work_request;
  const [requestComments, setRequestComments] = useState(detail.comments || []);
  const [commentsOpen, setCommentsOpen] = useState(false);
  const commentTextareaRef = useRef<HTMLTextAreaElement | null>(null);
  const requestCommentsKey = `${request.id}:${(detail.comments || []).map((comment) => `${comment.id}:${comment.status}:${comment.updated_at || ""}`).join("|")}`;
  const operational = request.operational_state || null;
  const openQuestions = requestOpenQuestions(detail);
  const sliceCounts = requestSliceCounts(detail);
  const currentCommentStats = requestCommentStats(detail, requestComments);
  const requestOnlyCommentStats = commentStats(requestComments);
  const handoffEligible = architectHandoffEligibleRequest(request);
  const handoffHasOpenQuestions = (openQuestions.length || request.open_question_count || 0) > 0;
  const handoffButtonLabel = handoffHasOpenQuestions ? "Copy Resume Handoff Prompt" : "Copy Agent Handoff Prompt";
  const handoffIdentity = `${handoffHasOpenQuestions}:${request.id}:${request.status || ""}:${request.updated_at || ""}`;
  const {
    cachedHandoff,
    error: handoffError,
    recordCopyError,
    recordCopyResult,
    startCopy,
    state: handoffCopyState,
  } = useScopedHandoffCopy(handoffIdentity);

  useEffect(() => {
    setRequestComments(detail.comments || []);
  }, [requestCommentsKey, detail.comments]);

  async function copyHandoff() {
    startCopy();

    try {
      recordCopyResult(await onCopyArchitectHandoff(request.id, cachedHandoff()));
    } catch (caught) {
      recordCopyError(caught instanceof Error ? caught.message : "Architect handoff could not be copied");
    }
  }

  const openCommentComposer = useCallback(() => {
    setCommentsOpen(true);
    window.setTimeout(() => commentTextareaRef.current?.focus(), 80);
  }, []);

  return (
    <>
      <DetailHeader
        title={request.title || request.id}
        eyebrow={`${repoDisplayName(request)} / ${request.base_branch || "main"} / ${request.work_type || "feature"}`}
        badge={<Badge variant={operationalBadgeVariant(operational, request.status)}>{operationalLabel(operational, request.status)}</Badge>}
      />
      <div className="grid gap-4">
        {handoffEligible || canMutateComments ? (
          <div className={cn("handoff-action-panel", handoffHasOpenQuestions && "handoff-action-panel-muted")} data-guidance-section style={{ animationDelay: "58ms" }}>
            <div className="handoff-action-row">
              {handoffEligible ? (
                <Button type="button" size="sm" variant={handoffHasOpenQuestions ? "outline" : "default"} onClick={() => void copyHandoff()} disabled={handoffCopyState === "copying"}>
                  {handoffCopyState === "copying" ? <Loader2 className="size-4 animate-spin" /> : handoffCopyState === "copied" ? <CheckCircle2 className="size-4" /> : <Copy className="size-4" />}
                  {handoffCopyState === "copied" ? "Copied" : handoffButtonLabel}
                </Button>
              ) : null}
              {canMutateComments ? (
                <Button type="button" size="sm" variant="outline" onClick={openCommentComposer}>
                  <MessageSquareText className="size-4" />
                  Add Comment
                </Button>
              ) : null}
            </div>
            {handoffError ? <p className="text-xs text-destructive">{handoffError}</p> : null}
          </div>
        ) : null}
        <DetailStatGrid
          stats={[
            { label: "Open Questions", value: String(openQuestions.length || request.open_question_count || 0) },
            { label: "Slices", value: String(sliceCounts.total) },
            { label: "Decisions", value: String(detail.decision_logs?.length || detail.summary?.decision_count || 0) },
            { label: "Comments", value: commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count) },
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
        <DetailDisclosure
          title="Comments"
          meta={commentStatLabel(requestOnlyCommentStats.open_comment_count, requestOnlyCommentStats.comment_count)}
          open={commentsOpen}
          onOpenChange={setCommentsOpen}
        >
          <CommentsPanel
            target={{ target_kind: "work_request", target_id: request.id }}
            comments={requestComments}
            onCommentsChange={setRequestComments}
            onSubmitComment={onSubmitComment}
            onResolveComment={onResolveComment}
            canMutate={canMutateComments}
            textareaRef={commentTextareaRef}
          />
        </DetailDisclosure>
        <RecentDecisionsDisclosure detail={detail} />
        <DetailDisclosure title="Details" meta="IDs, constraints, and slice plan">
          <DetailFacts
            facts={[
              ["Request ID", request.id],
              ["Dispatch Shape", formatStatus(request.desired_dispatch_shape)],
              ["Raw Lifecycle", statusLabel(request.status)],
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

function SliceDetailContent({
  detail,
  slice,
  pkg,
  onSubmitComment,
  onResolveComment,
  canMutateComments,
}: {
  detail: WorkRequestDetail;
  slice: PlannedSlice;
  pkg?: WorkPackageCard;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
  canMutateComments: boolean;
}) {
  const [sliceComments, setSliceComments] = useState(slice.comments || []);
  const sliceCommentsKey = `${slice.id}:${(slice.comments || []).map((comment) => `${comment.id}:${comment.status}:${comment.updated_at || ""}`).join("|")}`;
  const status = slice.work_package_status || slice.status;
  const operational = sliceOperationalState(slice, pkg);
  const blockerCount = Math.max(pkg?.active_blocker_count || 0, pkg?.status === "blocked" || operational?.key === "blocked" ? 1 : 0);
  const reviewLanes = slice.review_lanes || [];
  const attentionItems = operational?.attention_items || [];
  const currentCommentStats = targetCommentStats(slice, slice.comments || [], sliceComments);

  useEffect(() => {
    setSliceComments(slice.comments || []);
  }, [sliceCommentsKey, slice.comments]);

  return (
    <>
      <DetailHeader
        title={slice.title || pkg?.title || slice.id}
        eyebrow={`${repoDisplayName(detail.work_request)} / ${detail.work_request.title || detail.work_request.id}`}
        badge={<Badge variant={operationalBadgeVariant(operational, status)}>{operationalLabel(operational, status)}</Badge>}
      />
      <div className="grid gap-4">
        <DetailStatGrid
          stats={[
            { label: "State", value: operationalLabel(operational, status) },
            { label: "Package", value: pkg ? operationalLabel(pkg.operational_state || null, pkg.status) : "Not dispatched" },
            { label: "Review", value: reviewLanes.length > 0 ? reviewLanes.map(reviewLaneLabel).join(", ") : "Not recorded" },
            { label: "Blockers", value: String(blockerCount) },
            { label: "Comments", value: commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count) },
            { label: "Updated", value: detailDate(slice.updated_at || slice.dispatched_at || slice.inserted_at) },
          ]}
        />
        <DetailSection title="What It Does">
          <p>{slice.goal || pkg?.kind || "No slice goal has been recorded yet."}</p>
        </DetailSection>
        <DetailSection title="Progress">
          <div className="grid gap-2">
            <p>{operational?.reason || sliceProgressText(slice, pkg)}</p>
            {attentionItems.length > 0 ? <DetailAttentionList items={attentionItems} /> : null}
          </div>
        </DetailSection>
        <DetailSection title="Blocked By">
          {blockerCount > 0 ? (
            <p>{blockerCount} active blocker{blockerCount === 1 ? "" : "s"} on the linked work package.</p>
          ) : (
            <p>No blocker surfaced for this slice.</p>
          )}
        </DetailSection>
        <DetailDisclosure title="Comments" meta={commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count)}>
          <CommentsPanel
            target={{ target_kind: "planned_slice", target_id: slice.id }}
            comments={sliceComments}
            onCommentsChange={setSliceComments}
            onSubmitComment={onSubmitComment}
            onResolveComment={onResolveComment}
            canMutate={canMutateComments}
          />
        </DetailDisclosure>
        <RecentDecisionsDisclosure detail={detail} />
        <DetailDisclosure title="Details" meta="Branch, files, and acceptance">
          <DetailFacts
            facts={[
              ["Slice ID", slice.id],
              ["Work Package", slice.work_package_id || "Not dispatched"],
              ["Raw Lifecycle", statusLabel(slice.status)],
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
  onSubmitComment,
  onResolveComment,
  canMutateComments,
}: {
  selection: Extract<CardDetailSelection, { kind: "package" }>;
  detailPayload: WorkPackageDetailPayload | null;
  loading: boolean;
  error: string | null;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
  canMutateComments: boolean;
}) {
  const [packageComments, setPackageComments] = useState(detailPayload?.comments || []);
  const packageCommentsKey = `${selection.pkg.id}:${(detailPayload?.comments || []).map((comment) => `${comment.id}:${comment.status}:${comment.updated_at || ""}`).join("|")}`;
  const pkg = { ...selection.pkg, ...(detailPayload?.work_package || {}) } as WorkPackageCard & {
    branch_pattern?: string | null;
    product_description?: string | null;
    engineering_scope?: string | null;
    acceptance_criteria?: string[];
    policy_template?: string | null;
  };
  const summary = detailPayload?.summary;
  const blockers = (detailPayload?.blockers || []).filter((blocker) => blocker.active !== false);
  const progress = latestPackageProgress(detailPayload);
  const plan = summary?.plan || pkg.plan;
  const operational = pkg.operational_state || null;
  const lineage = detailPayload?.lineage || pkg.lineage || null;
  const attentionItems = operational?.attention_items || [];
  const blockerCount = blockers.length || summary?.active_blocker_count || pkg.active_blocker_count || (operational?.key === "blocked" || pkg.status === "blocked" ? 1 : 0);
  const currentCommentStats = targetCommentStats(summary || pkg, detailPayload?.comments || [], packageComments);

  useEffect(() => {
    setPackageComments(detailPayload?.comments || []);
  }, [packageCommentsKey, detailPayload?.comments]);

  return (
    <>
      <DetailHeader
        title={pkg.title || pkg.id}
        eyebrow={`${repoDisplayName(pkg)} / ${pkg.base_branch || "main"} / ${pkg.kind || "work package"}`}
        badge={<Badge variant={operationalBadgeVariant(operational, pkg.status)}>{operationalLabel(operational, pkg.status)}</Badge>}
      />
      <div className="grid gap-4">
        <DetailStatGrid
          stats={[
            { label: "State", value: operationalLabel(operational, pkg.status) },
            { label: "Plan", value: planSummaryText(plan) },
            { label: "Runtime", value: packageRuntimeText(summary, pkg) },
            { label: "Blockers", value: String(blockerCount) },
            { label: "Comments", value: commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count) },
            { label: "Updated", value: detailDate(summary?.latest_progress_at || pkg.latest_progress_at || pkg.updated_at || pkg.inserted_at) },
          ]}
        />
        <DetailSection title="What It Does">
          <p>{packagePurpose(pkg)}</p>
        </DetailSection>
        <DetailSection title="Operational Truth">
          <div className="grid gap-2">
            <p>{operational?.reason || packageOperationalFallbackText(pkg)}</p>
            {attentionItems.length > 0 ? <DetailAttentionList items={attentionItems} /> : null}
          </div>
        </DetailSection>
        <DetailSection title="Progress">
          {loading ? (
            <p>Loading latest package activity&hellip;</p>
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
        <DetailDisclosure title="Comments" meta={commentStatLabel(currentCommentStats.open_comment_count, currentCommentStats.comment_count)}>
          <CommentsPanel
            target={{ target_kind: "work_package", target_id: pkg.id }}
            comments={packageComments}
            onCommentsChange={setPackageComments}
            onSubmitComment={onSubmitComment}
            onResolveComment={onResolveComment}
            canMutate={canMutateComments}
          />
        </DetailDisclosure>
        {selection.detail ? <RecentDecisionsDisclosure detail={selection.detail} /> : null}
        {lineageHasSignal(lineage) ? <LineageDisclosure lineage={lineage} /> : null}
        <DetailDisclosure title="Details" meta="PR, review, artifacts, and raw identifiers">
          <DetailFacts
            facts={[
              ["Package ID", pkg.id],
              ["Parent", pkg.parent_id || selection.slice?.work_request_id || "Not linked"],
              ["Raw Status", statusLabel(operational?.raw_status || pkg.status)],
              ["Policy", pkg.policy_template || pkg.kind || "Not recorded"],
              ["Branch", pkg.metadata?.branch?.branch || pkg.branch_pattern || "Not recorded"],
              ["PR", pkg.metadata?.pr?.number ? `PR #${pkg.metadata.pr.number}` : pkg.metadata?.pr?.url ? "PR attached" : "Not attached"],
              [
                "Review",
                packageReviewLabel(pkg) || (pkg.status === "reviewing" ? "Reviewing" : "Not recorded"),
              ],
              ["Artifacts", String(summary?.artifact_count ?? pkg.artifact_count ?? 0)],
              ["Findings", String(summary?.finding_count ?? pkg.finding_count ?? 0)],
            ]}
          />
          <DetailList title="Acceptance" items={pkg.acceptance_criteria || selection.slice?.acceptance_criteria || []} empty="No acceptance criteria recorded." />
          <DetailList title="Alerts" items={activeAlertLabels(detailPayload?.alert_indicators || pkg.alert_indicators || [])} empty="No active alerts." />
        </DetailDisclosure>
      </div>
    </>
  );
}

function CommentsPanel({
  target,
  comments,
  onCommentsChange,
  onSubmitComment,
  onResolveComment,
  canMutate,
  textareaRef,
}: {
  target: CommentTarget;
  comments: ContextComment[];
  onCommentsChange: React.Dispatch<React.SetStateAction<ContextComment[]>>;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
  canMutate: boolean;
  textareaRef?: React.Ref<HTMLTextAreaElement>;
}) {
  const [draft, setDraft] = useState("");
  const [pending, setPending] = useState(false);
  const [resolvingId, setResolvingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const targetKey = `${target.target_kind}:${target.target_id}`;

  useEffect(() => {
    setDraft("");
    setPending(false);
    setResolvingId(null);
    setError(null);
  }, [targetKey]);

  const orderedComments = useMemo(() => {
    return sortedCopy(comments, (left, right) => {
      const leftTime = Date.parse(left.inserted_at || "");
      const rightTime = Date.parse(right.inserted_at || "");
      if (Number.isFinite(leftTime) && Number.isFinite(rightTime) && leftTime !== rightTime) return leftTime - rightTime;
      return left.id.localeCompare(right.id);
    });
  }, [comments]);
  const openCount = orderedComments.filter((comment) => comment.status !== "resolved").length;

  async function submit() {
    const body = draft.trim();
    if (!body) return;

    setPending(true);
    setError(null);

    try {
      const comment = await onSubmitComment(target, body);
      onCommentsChange((current) => [...current.filter((item) => item.id !== comment.id), comment]);
      setDraft("");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Comment was not recorded");
    } finally {
      setPending(false);
    }
  }

  async function resolve(comment: ContextComment) {
    setResolvingId(comment.id);
    setError(null);

    try {
      const resolved = await onResolveComment(comment.id);
      onCommentsChange((current) => current.map((item) => (item.id === resolved.id ? resolved : item)));
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Comment was not resolved");
    } finally {
      setResolvingId(null);
    }
  }

  return (
    <div className="grid gap-3">
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant={openCount > 0 ? "warning" : "outline"}>{openCount} open</Badge>
        <span className="text-xs text-muted-foreground">{orderedComments.length} total</span>
      </div>
      {orderedComments.length > 0 ? (
        <div className="grid gap-2">
          {orderedComments.map((comment) => {
            const resolved = comment.status === "resolved";

            return (
              <div key={comment.id} className={cn("detail-list-item", resolved && "opacity-75")}>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="text-xs font-medium text-muted-foreground">
                    {comment.author_name || comment.source_type || "comment"} / {detailDate(comment.inserted_at)}
                  </span>
                  <div className="flex items-center gap-2">
                    <Badge variant={resolved ? "secondary" : "info"}>{resolved ? "Resolved" : "Open"}</Badge>
                    {canMutate && !resolved ? (
                      <Button type="button" size="sm" variant="outline" onClick={() => void resolve(comment)} disabled={resolvingId === comment.id}>
                        {resolvingId === comment.id ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}
                        Resolve
                      </Button>
                    ) : null}
                  </div>
                </div>
                <p className="mt-2 whitespace-pre-wrap text-sm">{comment.body || "No comment body recorded."}</p>
                {resolved && comment.resolved_by ? <p className="mt-2 text-xs text-muted-foreground">Resolved by {comment.resolved_by}</p> : null}
              </div>
            );
          })}
        </div>
      ) : (
        <p>No comments yet.</p>
      )}
      {canMutate ? (
        <div className="grid gap-2">
          <Textarea ref={textareaRef} value={draft} onChange={(event) => setDraft(event.target.value)} placeholder="Add a note..." disabled={pending} maxLength={COMMENT_BODY_MAX_LENGTH} />
          <div className="flex flex-wrap items-center justify-between gap-2">
            {error ? <p className="text-xs text-destructive">{error}</p> : <span />}
            <Button type="button" size="sm" onClick={() => void submit()} disabled={pending || draft.trim() === ""}>
              {pending ? <Loader2 className="size-4 animate-spin" /> : <MessageSquareText className="size-4" />}
              Add Comment
            </Button>
          </div>
        </div>
      ) : null}
    </div>
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
        eyebrow={`${repoDisplayName(detailSession)} / ${detailSession.base_branch || "main"} / ${detailSession.caller_id || "solo"}`}
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
            <p>Loading the Solo Session ledger&hellip;</p>
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
            <p className="text-sm text-muted-foreground">Loading planning entries&hellip;</p>
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
          <ChevronRight className="solo-planning-chevron size-4 shrink-0 transition-transform duration-150" />
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
  const rows = detailActivityRows(items);

  return (
    <div className="grid gap-2">
      {rows.map(({ item, key }) => (
        <div key={key} className="detail-list-item">
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

function detailActivityRows(items: Array<{ title?: string | null; body?: string | null; at?: string | null }>) {
  const seen = new Map<string, number>();

  return items.slice(0, 3).map((item) => {
    const baseKey = detailActivityKey(item);
    const occurrence = seen.get(baseKey) || 0;
    seen.set(baseKey, occurrence + 1);
    return { item, key: occurrence === 0 ? baseKey : `${baseKey}:${occurrence}` };
  });
}

function detailActivityKey(item: { title?: string | null; body?: string | null; at?: string | null }) {
  return `activity:${hashText([item.title, item.body, item.at].filter(Boolean).join("|"))}`;
}

function DetailAttentionList({ items }: { items: PackageOperationalAttention[] }) {
  const visibleItems = items.slice(0, 3);

  return (
    <div className="grid gap-2">
      {visibleItems.map((item) => (
        <div key={item.key || item.label || item.reason} className={cn("detail-list-item border-l-4", attentionBorderClassName(item))}>
          <div className="flex min-w-0 items-center justify-between gap-3">
            <span className="min-w-0 text-sm font-medium">{item.label || formatStatus(item.key)}</span>
            {item.missing?.length ? <span className="shrink-0 text-xs text-muted-foreground">{item.missing.length} missing</span> : null}
          </div>
          {item.reason ? <p className="mt-1 text-xs text-muted-foreground">{item.reason}</p> : null}
        </div>
      ))}
      {items.length > visibleItems.length ? <p className="text-xs text-muted-foreground">+{items.length - visibleItems.length} more attention item{items.length - visibleItems.length === 1 ? "" : "s"}</p> : null}
    </div>
  );
}

function LineageDisclosure({ lineage }: { lineage: WorkPackageCard["lineage"] }) {
  const entries = lineageDetailRows(lineage);
  const attentionItems = lineage?.cleanup_attention || [];

  return (
    <DetailDisclosure title="Operational Lineage" meta={lineageSummary(lineage)} defaultOpen={Boolean(lineage?.unavailable || attentionItems.length)}>
      <div className="grid gap-3">
        {lineage?.unavailable ? <p className="text-sm text-muted-foreground">Lineage could not be read{lineage.error ? `: ${lineage.error}` : "."}</p> : null}
        {entries.length > 0 ? (
          <DetailActivityList
            items={entries.map((entry) => ({
              title: entry.title,
              body: entry.body,
              at: entry.at,
            }))}
          />
        ) : lineage?.unavailable ? null : (
          <p className="text-sm text-muted-foreground">No lineage relationships recorded.</p>
        )}
        {attentionItems.length > 0 ? <DetailAttentionList items={attentionItems} /> : null}
      </div>
    </DetailDisclosure>
  );
}

function hashText(text: string) {
  let hash = 0;
  for (let index = 0; index < text.length; index += 1) {
    hash = (hash * 31 + text.charCodeAt(index)) | 0;
  }
  return Math.abs(hash).toString(36);
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

function commentStatLabel(openCount?: number | null, totalCount?: number | null) {
  const open = openCount ?? 0;
  const total = totalCount ?? open;
  return open > 0 ? `${open} open / ${total} total` : String(total);
}

function commentStats(comments: ContextComment[]): CommentStats {
  const commentCount = comments.length;
  const openCommentCount = comments.filter((comment) => comment.status !== "resolved").length;
  return { comment_count: commentCount, open_comment_count: openCommentCount };
}

function serverCommentStats(counts: { comment_count?: number | null; open_comment_count?: number | null } | null | undefined, fallbackComments: ContextComment[]): CommentStats {
  const fallbackStats = commentStats(fallbackComments);

  return {
    comment_count: counts?.comment_count ?? fallbackStats.comment_count,
    open_comment_count: counts?.open_comment_count ?? fallbackStats.open_comment_count,
  };
}

function targetCommentStats(
  counts: { comment_count?: number | null; open_comment_count?: number | null } | null | undefined,
  initialComments: ContextComment[],
  currentComments: ContextComment[],
): CommentStats {
  const base = serverCommentStats(counts, initialComments);
  const initialStats = commentStats(initialComments);
  const currentStats = commentStats(currentComments);

  return {
    comment_count: Math.max(0, base.comment_count + currentStats.comment_count - initialStats.comment_count),
    open_comment_count: Math.max(0, base.open_comment_count + currentStats.open_comment_count - initialStats.open_comment_count),
  };
}

function requestCommentStats(detail: WorkRequestDetail, requestComments: ContextComment[]): CommentStats {
  const sliceComments = (detail.planned_slices || []).flatMap((slice) => slice.comments || []);
  const base = serverCommentStats(detail.summary || detail.work_request, [...(detail.comments || []), ...sliceComments]);
  const initialRequestStats = commentStats(detail.comments || []);
  const currentRequestStats = commentStats(requestComments);

  return {
    comment_count: Math.max(0, base.comment_count + currentRequestStats.comment_count - initialRequestStats.comment_count),
    open_comment_count: Math.max(0, base.open_comment_count + currentRequestStats.open_comment_count - initialRequestStats.open_comment_count),
  };
}

function canMutateDashboardComments() {
  return dashboardRuntimeConfig?.operatorMode === true;
}

function requestProgressText(detail: WorkRequestDetail) {
  const request = detail.work_request;
  const operational = request.operational_state || null;
  const questions = requestOpenQuestions(detail);
  const slices = requestSliceCounts(detail);

  if (questions.length > 0) {
    return `${questions.length} open human question${questions.length === 1 ? "" : "s"} before the architect can continue.`;
  }

  if (request.status === "sliced" || slices.total > 0) {
    const state = operational?.key && operational.key !== request.status ? `${operational.label || statusLabel(operational.key)}. ` : "";
    return `${state}${slices.total} slice${slices.total === 1 ? "" : "s"} recorded: ${slices.approved} approved, ${slices.dispatched} dispatched, ${slices.skipped} skipped.`;
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
    const progress = planProgressLabel(pkg.plan);
    const label = operationalLabel(pkg.operational_state || null, pkg.status);
    return progress ? `Linked work package is ${label} with ${progress.toLowerCase()}.` : `Linked work package is ${label}.`;
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
  return sortedCopy(payload?.progress || [], (left, right) => {
    const sequenceDelta = (right.sequence || 0) - (left.sequence || 0);
    if (sequenceDelta !== 0) return sequenceDelta;
    return sortableTime(right.created_at) - sortableTime(left.created_at);
  });
}

function planSummaryText(plan?: WorkPackageCard["plan"] | null) {
  return planProgressLabel(plan) || "No plan";
}

function packageRuntimeText(summary: WorkPackageDetailPayload["summary"] | undefined, pkg: WorkPackageCard) {
  if (summary?.stale_agent_run_count) return `${summary.stale_agent_run_count} stale`;
  if (summary?.failed_agent_run_count) return `${summary.failed_agent_run_count} failed`;
  if (summary?.active_agent_run_count) return `${summary.active_agent_run_count} active`;
  if (summary?.queued_agent_run_count) return `${summary.queued_agent_run_count} queued`;
  if (pkg.active_agent_run?.stale) return "Stale run";
  if (pkg.active_agent_run?.runtime_state === "queued") return "Queued";
  if (pkg.active_agent_run || (typeof pkg.runtime?.active_count === "number" && pkg.runtime.active_count > 0)) return "Active";
  return "No active run";
}

function packagePurpose(pkg: WorkPackageCard | NonNullable<WorkPackageDetailPayload["work_package"]>) {
  const richPackage = pkg as NonNullable<WorkPackageDetailPayload["work_package"]>;
  return firstParagraph(richPackage.engineering_scope) || firstParagraph(richPackage.product_description) || pkg.kind || "No package description has been recorded yet.";
}

function packageOperationalFallbackText(pkg: WorkPackageCard) {
  const review = packageReviewLabel(pkg);
  if (review) return `Review signal: ${review}.`;

  const progress = planProgressLabel(pkg.plan);
  if (progress) return `Plan is ${progress.toLowerCase()}.`;

  return `Raw lifecycle status is ${statusLabel(pkg.status)}.`;
}

function attentionBorderClassName(attention: PackageOperationalAttention) {
  switch (attentionTone(attention)) {
    case "danger":
      return "border-l-rose-400";
    case "warning":
      return "border-l-amber-400";
    case "success":
      return "border-l-emerald-400";
    case "info":
      return "border-l-sky-400";
    default:
      return "border-l-slate-300";
  }
}

function activeAlertLabels(alerts: PackageAlertIndicator[]) {
  return alerts.reduce<string[]>((items, item) => {
    if (item.active !== false) items.push(item.detail || item.label || item.type || "Alert");
    return items;
  }, []);
}

function lineageHasSignal(lineage?: WorkPackageCard["lineage"] | null) {
  if (!lineage) return false;
  const rows = lineageDetailRows(lineage);
  return (
    Boolean(lineage.unavailable) ||
    (lineage.cleanup_attention || []).length > 0 ||
    rows.length > 0 ||
    Boolean(lineage.oracle_status?.preserved || lineage.oracle_status?.has_oracle)
  );
}

function lineageSummary(lineage?: WorkPackageCard["lineage"] | null) {
  if (!lineage) return "None recorded";
  if (lineage.unavailable) return lineage.error ? `Unavailable: ${lineage.error}` : "Unavailable";

  const rows = lineageDetailRows(lineage);
  if (rows.length === 0) return "None recorded";

  const parts = [
    lineage.recut_as?.length ? `${lineage.recut_as.length} recut` : null,
    lineage.superseded_by?.length ? `${lineage.superseded_by.length} superseded` : null,
    lineage.original_work?.length ? `${lineage.original_work.length} original` : null,
    lineage.oracle_for?.length || lineage.oracle_work?.length ? "oracle" : null,
  ].filter(Boolean);

  return parts.length > 0 ? parts.join(" / ") : `${rows.length} relationship${rows.length === 1 ? "" : "s"}`;
}

function lineageDetailRows(lineage?: WorkPackageCard["lineage"] | null) {
  if (!lineage) return [];
  const explicitSuccessorKeys = new Set([...(lineage.recut_as || []), ...(lineage.superseded_by || [])].map(lineageEntryKey));
  const genericSuccessors = (lineage.successor_work || []).filter((entry) => !explicitSuccessorKeys.has(lineageEntryKey(entry)));

  return [
    ...lineageEntries("Recut as", lineage.recut_as),
    ...lineageEntries("Superseded by", lineage.superseded_by),
    ...lineageEntries("Successor work", genericSuccessors),
    ...lineageEntries("Original work", lineage.original_work),
    ...lineageEntries("Oracle for", lineage.oracle_for),
    ...lineageEntries("Oracle work", lineage.oracle_work),
  ];
}

function lineageEntryKey(entry: NonNullable<PackageLineageProjection["successor_work"]>[number]) {
  return [entry.relationship, entry.work_package_id, entry.target_work_package_id, entry.source_work_package_id, entry.event_id].filter(Boolean).join(":");
}

function lineageEntries(label: string, entries?: PackageLineageProjection["successor_work"]) {
  return (entries || []).map((entry) => ({
    title: `${label} ${entry.work_package_id || entry.target_work_package_id || entry.source_work_package_id || "work package"}`,
    body: lineageEntryBody(entry),
    at: entry.recorded_at,
  }));
}

function lineageEntryBody(entry: NonNullable<PackageLineageProjection["successor_work"]>[number]) {
  const status = entry.status || entry.target_status || entry.source_status;
  const branch = entry.branch || entry.target_branch || entry.source_branch;
  const details = [status ? statusLabel(status) : null, branch, entry.oracle_preserved ? "oracle preserved" : null, entry.reason].filter(Boolean);
  return details.join(" / ");
}

function latestDecisionLogs(detail: WorkRequestDetail) {
  return sortedCopy(detail.decision_logs || [], (left, right) => {
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
  repoKey: string;
  repo: string;
  repoRemote?: string | null;
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
    repo: repoDisplayName(item),
    repoKey: repoIdentityKey(item),
    repoRemote: repoRemoteName(item),
    title: item.decision_prompt?.tl_dr || item.summary || item.question || item.id,
    packageId: item.work_package_id,
    prompt: item.decision_prompt,
    detail: item.decision_prompt?.details || item.context || item.question || "",
    guidance: item,
  }));

  const details = dashboard?.work_request_details || [];
  const clarifications = details.flatMap<GuidanceItem>((detail) => {
    const items: GuidanceItem[] = [];
    (detail.clarification_questions || []).forEach((question) => {
      if (question.status === "open") items.push(clarificationGuidanceItem(detail, question));
    });
    return items;
  });

  return [...guidance, ...clarifications];
}

function clarificationGuidanceItem(detail: WorkRequestDetail, question: ClarificationQuestion): GuidanceItem {
  return {
    source: "clarification",
    id: question.id,
    repo: repoDisplayName(detail.work_request),
    repoKey: repoIdentityKey(detail.work_request),
    repoRemote: repoRemoteName(detail.work_request),
    title: question.decision_prompt?.tl_dr || question.question || question.id,
    workRequestId: detail.work_request.id,
    prompt: question.decision_prompt,
    detail: question.decision_prompt?.details || question.why_needed || question.question || "",
    question,
    request: detail.work_request,
  };
}

function activeBlockerItems(packages: WorkPackageCard[], details: WorkRequestDetail[] = []): BlockerItem[] {
  return packages.reduce<BlockerItem[]>((items, pkg) => {
    const operational = pkg.operational_state || null;
    if (operational?.key === "blocked" || pkg.status === "blocked" || (pkg.active_blocker_count || 0) > 0) {
      items.push({
        id: pkg.id,
        title: pkg.title || pkg.id,
        repo: repoDisplayName(pkg),
        status: operational?.key || pkg.status,
        blockerCount: Math.max(pkg.active_blocker_count || 0, pkg.status === "blocked" || operational?.key === "blocked" ? 1 : 0),
        detail:
          operational?.reason ||
          (pkg.status === "blocked"
            ? "This work package is blocked and needs another condition or dependency cleared before it can move."
            : "This work package has active blockers attached to its execution path."),
        selection: packageBoardSelection(pkg, details),
      });
    }

    return items;
  }, []);
}

function recentFinishedHighlights(
  packages: WorkPackageCard[],
  requests: WorkRequestCard[],
  details: WorkRequestDetail[],
): FinishedHighlight[] {
  const detailByRequestId = new Map(details.map((detail) => [detail.work_request.id, detail]));
  const packageById = new Map(packages.map((pkg) => [pkg.id, pkg]));

  const packageHighlights = packages.reduce<FinishedHighlight[]>((items, pkg) => {
    if (packageLane(pkg) === "finished") {
      const operational = pkg.operational_state || null;
      items.push({
        id: pkg.id,
        title: pkg.title || pkg.id,
        repo: repoDisplayName(pkg),
        kind: "Work Package",
        state: operationalLabel(operational, pkg.status),
        at: pkg.latest_progress_at,
        selection: packageBoardSelection(pkg, details),
      });
    }

    return items;
  }, []);

  const requestHighlights = requests.reduce<FinishedHighlight[]>((items, request) => {
    if (workRequestLane(request) === "finished") {
      const detail = detailByRequestId.get(request.id);
      if (!detail) return items;

      const operational = request.operational_state || null;
      items.push({
        id: request.id,
        title: request.title || request.id,
        repo: repoDisplayName(request),
        kind: "Request",
        state: operationalLabel(operational, request.status),
        at: request.updated_at || request.inserted_at,
        selection: { kind: "request", detail },
      });
    }

    return items;
  }, []);

  const sliceHighlights = details.flatMap<FinishedHighlight>((detail) => {
    const items: FinishedHighlight[] = [];
    (detail.planned_slices || []).forEach((slice) => {
      const pkg = slice.work_package_id ? packageById.get(slice.work_package_id) : undefined;

      if (sliceLane(slice, pkg) === "finished") {
        const operational = sliceOperationalState(slice, pkg);
        items.push({
          id: slice.id,
          title: slice.title || slice.id,
          repo: repoDisplayName(detail.work_request),
          kind: "Slice",
          state: operationalLabel(operational, slice.work_package_status || slice.status),
          at: detail.work_request.updated_at || detail.work_request.inserted_at,
          selection: pkg ? { kind: "package", pkg, detail, slice } : { kind: "slice", detail, slice },
        });
      }
    });
    return items;
  });

  return sortedCopy([...packageHighlights, ...requestHighlights, ...sliceHighlights], (a, b) => {
    const left = a.at ? Date.parse(a.at) : 0;
    const right = b.at ? Date.parse(b.at) : 0;
    return right - left;
  });
}

function packageBoardSelection(pkg: WorkPackageCard, details: WorkRequestDetail[]): CardDetailSelection {
  for (const detail of details) {
    for (const slice of detail.planned_slices || []) {
      if (slice.work_package_id === pkg.id) {
        return sliceLane(slice, pkg) === "slices" ? { kind: "slice", detail, slice, pkg } : { kind: "package", pkg, detail, slice };
      }
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
  const packageById = new Map(packages.map((pkg) => [pkg.id, pkg]));

  const ensure = (identity: RepoIdentitySource): RepoSummary => {
    const repoKey = repoIdentityKey(identity);
    const repo = repoDisplayName(identity);
    if (!repos.has(repoKey)) {
      repos.set(repoKey, {
        repoKey,
        repo,
        repoRemote: repoRemoteName(identity),
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
    const summary = repos.get(repoKey)!;
    summary.repoRemote ||= repoRemoteName(identity);
    return summary;
  };

  requests.forEach((request) => {
    const summary = ensure(request);
    summary.requests.push(request);
    addBranch(summary, request.base_branch);
  });

  packages.forEach((pkg) => {
    const summary = ensure(pkg);
    summary.packages.push(pkg);
    addBranch(summary, pkg.base_branch);
  });

  sessions.forEach((session) => {
    const summary = ensure(session);
    addBranch(summary, session.base_branch);
  });

  guidance.forEach((item) => {
    ensure({ repo: item.repo, repo_key: item.repoKey, repo_display: item.repo, repo_remote: item.repoRemote }).guidanceCount += 1;
  });

  repos.forEach((summary) => {
    summary.requested = summary.requests.filter((request) => workRequestLane(request) === "requested").length;
    summary.active =
      summary.requests.filter((request) => workRequestLane(request) === "slices").length +
      summary.packages.filter((pkg) => packageLane(pkg) === "slices").length;
    summary.implementing = summary.packages.filter((pkg) => packageLane(pkg) === "implementing").length;
    summary.finished = summary.packages.filter((pkg) => packageLane(pkg) === "finished").length;
    summary.blockerCount = activeBlockerItems(summary.packages).length;
    details.forEach((detail) => {
      if (repoIdentityKey(detail.work_request) !== summary.repoKey) return;
      (detail.planned_slices || []).forEach((slice) => {
        const lane = sliceLane(slice, slice.work_package_id ? packageById.get(slice.work_package_id) : undefined);
        if (lane === "slices") summary.active += 1;
        if (lane === "implementing") summary.implementing += 1;
        if (lane === "finished") summary.finished += 1;
      });
    });
  });

  return sortedCopy([...repos.values()], (a, b) => a.repo.localeCompare(b.repo));
}

function guidanceAnswerUrl(item: GuidanceItem) {
  if (item.source === "guidance") {
    return operatorApiUrl(`/work-packages/${encodeURIComponent(item.packageId)}/guidance/${encodeURIComponent(item.id)}/answer`);
  }

  return operatorApiUrl(`/work-requests/${encodeURIComponent(item.workRequestId)}/questions/${encodeURIComponent(item.id)}/answer`);
}

function packageLinkedToRequest(pkg: WorkPackageCard, details: WorkRequestDetail[]) {
  return details.some((detail) => (detail.planned_slices || []).some((slice) => slice.work_package_id === pkg.id));
}

function sortWorkRequestDetails(details: WorkRequestDetail[]) {
  return sortedCopy(details, (left, right) => {
    const leftTime = sortableTime(left.work_request.inserted_at || left.work_request.updated_at);
    const rightTime = sortableTime(right.work_request.inserted_at || right.work_request.updated_at);
    if (leftTime !== rightTime) return leftTime - rightTime;
    return (left.work_request.title || left.work_request.id).localeCompare(right.work_request.title || right.work_request.id);
  });
}

function sortPackages(packages: WorkPackageCard[]) {
  return sortedCopy(packages, (left, right) => {
    const leftTime = sortableTime(left.latest_progress_at || left.updated_at);
    const rightTime = sortableTime(right.latest_progress_at || right.updated_at);
    if (leftTime !== rightTime) return rightTime - leftTime;
    return (left.title || left.id).localeCompare(right.title || right.id);
  });
}

function sortPlannedSlices(slices: PlannedSlice[]) {
  return sortedCopy(slices, comparePlannedSlices);
}

function sortSliceEntries(entries: SliceEntry[]) {
  return sortedCopy(entries, (left, right) => {
    const requestDelta = left.requestIndex - right.requestIndex;
    if (requestDelta !== 0) return requestDelta;
    return comparePlannedSlices(left.slice, right.slice);
  });
}

function comparePlannedSlices(left: PlannedSlice, right: PlannedSlice) {
  const sequenceDelta = sortableSequence(left.sequence) - sortableSequence(right.sequence);
  if (sequenceDelta !== 0) return sequenceDelta;

  const leftTime = sortableTime(left.inserted_at || left.updated_at);
  const rightTime = sortableTime(right.inserted_at || right.updated_at);
  if (leftTime !== rightTime) return leftTime - rightTime;

  return (left.title || left.id).localeCompare(right.title || right.id);
}

function sortableSequence(sequence?: number | null) {
  return typeof sequence === "number" && Number.isFinite(sequence) ? sequence : Number.MAX_SAFE_INTEGER;
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
    const active = sortSliceEntries(entries);
    const packageEntries = sortSliceEntries(entries.filter((entry) => entry.pkg));
    const implementing = packageEntries.filter((entry) => sliceLane(entry.slice, entry.pkg) !== "finished");
    const finished = packageEntries.filter((entry) => sliceLane(entry.slice, entry.pkg) === "finished");

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
    const source = requestNodeId(detail);
    const sourceTone = requestStateCardTone(detail);
    const slices = sortPlannedSlices(detail.planned_slices || []);

    return slices.flatMap((target, index) => {
      const pkg = packageMap.get(target.work_package_id || "");
      const targetNode = sliceNodeId(target);
      const targetTone = sliceCardTone(target, pkg, "slices");
      const wires: BoardWire[] = [{
        id: `${source}->${targetNode}:${index}:slice`,
        from: source,
        to: targetNode,
        sourceTone,
        tone: targetTone,
      }];

      if (pkg) {
        const packageTargetNode = packageNodeId(pkg);
        wires.push({
          id: `${targetNode}->${packageTargetNode}:${index}:package`,
          from: targetNode,
          to: packageTargetNode,
          sourceTone: targetTone,
          tone: packageCardTone(pkg, sliceLane(target, pkg)),
        });
      }

      return wires;
    });
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
    const target = blockerEndpoint(edge.to, context, "target");
    if (!target) return [];

    const source = blockerEndpoint(edge.from, context, "source") || blockerFallbackSourceEndpoint(edge, context);
    if (!source || source === target) return [];

    return [
      {
        id: `blocker:${edge.id}`,
        from: source,
        to: target,
        sourceTone: "blocked",
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

function blockerEndpoint(
  endpoint: ActiveBlockingEdge["from"],
  context: ReturnType<typeof blockerWireContext>,
  role: "source" | "target",
): string | undefined {
  if (endpoint.kind === "work_package") {
    return context.packageById.has(endpoint.id) ? packageNodeId(endpoint.id) : undefined;
  }

  const slice = context.sliceById.get(endpoint.id);
  if (!slice) return undefined;

  const pkg = context.packageById.get(slice.work_package_id || "");
  if (pkg) return packageNodeId(pkg);

  if (sliceLane(slice, pkg) === "slices") return sliceNodeId(slice);
  return role === "target" ? sliceNodeId(slice) : undefined;
}

function blockerFallbackSourceEndpoint(edge: ActiveBlockingEdge, context: ReturnType<typeof blockerWireContext>) {
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

function formatDate(value: string) {
  const timestamp = Date.parse(value);

  if (Number.isNaN(timestamp)) {
    return "recent";
  }

  return LOCAL_DATE_FORMATTER.format(timestamp);
}

function repoName(value?: string | null) {
  const trimmed = value?.trim();
  return trimmed || "Unscoped";
}

type RepoIdentitySource = {
  repo?: string | null;
  repo_key?: string | null;
  repo_display?: string | null;
  repo_remote?: string | null;
  repo_aliases?: string[];
};

function repoIdentityKey(item?: RepoIdentitySource | null) {
  return item?.repo_key?.trim() || item?.repo?.trim() || "Unscoped";
}

function repoDisplayName(item?: RepoIdentitySource | null) {
  return repoName(item?.repo_display || item?.repo);
}

function repoRemoteName(item?: RepoIdentitySource | null) {
  return item?.repo_remote?.trim() || null;
}

function addBranch(summary: RepoSummary, branch?: string | null) {
  const value = branch?.trim();
  if (value && !summary.baseBranches.includes(value)) {
    summary.baseBranches.push(value);
  }
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

function readStoredHideEmptyWorkstreams() {
  const storedValue = readDashboardUiState().hideEmptyWorkstreams;
  return typeof storedValue === "boolean" ? storedValue : true;
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

  const storedUiTheme = readDashboardUiState().theme;
  if (isDashboardTheme(storedUiTheme)) return storedUiTheme;

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

  updateDashboardUiState((state) => ({ ...state, theme }));

  try {
    window.localStorage.setItem(DASHBOARD_THEME_KEY, theme);
  } catch {
    // Theme persistence is best-effort; the class toggle still applies for the active session.
  }

  applyDashboardTheme(theme);
}

function applyDashboardTheme(theme: DashboardTheme) {
  if (typeof document === "undefined") return;
  document.documentElement.classList.toggle("dark", theme === "dark");
}

function shouldShowUpdateSimulationControls() {
  if (typeof window === "undefined") return false;

  try {
    const params = new URLSearchParams(window.location.search);
    return params.get("debugAnimations") === "1" || window.localStorage.getItem(DASHBOARD_DEBUG_ANIMATIONS_KEY) === "true";
  } catch {
    return false;
  }
}

function defaultRepoWorkstreamOpen(repo: Pick<RepoSummary, "requested" | "active" | "implementing" | "finished" | "guidanceCount" | "blockerCount">) {
  if (!repoWorkstreamHasActivity(repo)) return false;
  return typeof window === "undefined" ? true : window.innerWidth >= 900;
}

function repoWorkstreamStateKey(
  repo: Pick<RepoSummary, "repoKey" | "baseBranches" | "requested" | "active" | "implementing" | "finished" | "guidanceCount" | "blockerCount">,
) {
  const branchKey = uniqueNonEmpty(repo.baseBranches).sort().join("|") || "main";
  const activityKey = repoWorkstreamHasActivity(repo) ? "active" : "empty";
  return `${repo.repoKey}::${branchKey}::${activityKey}`;
}

function repoWorkstreamHasActivity(
  repo: Pick<RepoSummary, "requested" | "active" | "implementing" | "finished" | "guidanceCount" | "blockerCount">,
) {
  return repo.requested + repo.active + repo.implementing + repo.finished + repo.guidanceCount + repo.blockerCount > 0;
}

function repoWorkstreamHasWorkItems(
  repo: Pick<RepoSummary, "requested" | "active" | "implementing" | "finished" | "packages" | "requests">,
) {
  return repo.requests.length + repo.packages.length + repo.requested + repo.active + repo.implementing + repo.finished > 0;
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
