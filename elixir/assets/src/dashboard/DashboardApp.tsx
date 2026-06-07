import type { ArchitectHandoffPayload, ContextComment, CopyArchitectHandoff, CreateWorkRequestPayload, DashboardPayload, GuidanceAnswerSubmission, GuidanceItem } from "@/types/dashboard";
import type { NewRequestForm } from "@/components/dashboard/new-request-dialog";
import type * as React from "react";
import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
import { CardDetailSelection, DASHBOARD_POLL_INTERVAL_MS, DASHBOARD_RECONNECT_GRACE_MS, DashboardConnectionIssue, DashboardResponseSelector, DashboardRuntimeConfig, PR_SYNC_INTERVAL_MS, ResolveContextComment, SubmitContextComment, WorkPackageArchiveMutation, WorkPackageBlockerClearMutation, WorkPackageStateMutation, WorkRequestMutation, WorkRequestStateMutation, WorkspaceTab, copyTextToClipboard, dashboardCaughtMessage, dashboardFromEnvelope, dashboardRuntimeConfig, ensureDashboardRuntimeConfig, isReconnectableLocalOperatorError, jsonHeaders, mutationHeaders, operatorApiUrl, operatorFetch, readDashboardApiResponse, reconnectLocalOperatorSession, withLocalOperatorReconnect } from "./runtime";
import { DashboardShell } from "./dashboard-shell";
import { SoloSessions } from "./solo-sessions";
import { WorkstreamsPane } from "./workspace-tabs";
import {
  FINISHED_HIGHLIGHT_LIMIT,
  activeBlockerItems,
  allGuidanceItems,
  allPackages,
  dashboardContentFingerprint,
  guidanceAnswerUrl,
  recentFinishedHighlights,
  repoSummaries,
} from "./dashboard-data";
import { appDialogReducer, appStateReducer, createInitialAppState, initialAppDialogState } from "./dashboard-state";
import { applyDashboardTheme, repoWorkstreamHasWorkItems, shouldShowUpdateSimulationControls, writeDashboardUiStateValue, writeStoredTheme } from "./dashboard-persistence";
import { canMutateDashboardComments } from "./detail-utils";
import { packageSelectionIndex, requestDetailsByRepoKey } from "./workstream-data";
import { useDashboardUpdateAnimations } from "./update-animations";

export function DashboardApp() {
  const shellProps = useDashboardController();
  return <DashboardShell {...shellProps} />;
}

function useDashboardController() {
  const [appState, dispatchApp] = useReducer(appStateReducer, null, createInitialAppState);
  const { dashboard, error, hideEmptyWorkstreams, loading, refreshing, theme, workspaceTab } = appState;
  const [dialogState, dispatchDialog] = useReducer(appDialogReducer, initialAppDialogState);
  const [connectionIssue, setConnectionIssue] = useState<DashboardConnectionIssue | null>(null);
  const showUpdateSimulationControls = useMemo(() => shouldShowUpdateSimulationControls(), []);
  const [runtimeConfig, setRuntimeConfig] = useState<DashboardRuntimeConfig | undefined>(() => dashboardRuntimeConfig);
  const dashboardRef = useRef<DashboardPayload | null>(dashboard);
  const initialDashboardFingerprint = useMemo(() => dashboardContentFingerprint(dashboard), [dashboard]);
  const dashboardFingerprintRef = useRef(initialDashboardFingerprint);
  const connectionIssueRef = useRef<DashboardConnectionIssue | null>(null);
  const loadInFlightRef = useRef(false);
  const prSyncInFlightRef = useRef(false);
  const lastPrSyncAtRef = useRef(0);
  const setDashboard = useCallback((nextDashboard: DashboardPayload | null) => {
    const nextFingerprint = dashboardContentFingerprint(nextDashboard);
    if (dashboardFingerprintRef.current === nextFingerprint) return;

    dashboardFingerprintRef.current = nextFingerprint;
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

  useEffect(() => {
    dashboardRef.current = dashboard;
  }, [dashboard]);

  useEffect(() => {
    connectionIssueRef.current = connectionIssue;
  }, [connectionIssue]);

  const recordConnectionFailure = useCallback(
    (message: string, immediate = false, reconnectableLocalSession = false) => {
      const now = Date.now();
      const canGrace = !immediate && Boolean(dashboardRef.current);

      if (!canGrace) {
        setConnectionIssue(null);
        setError(message);
        return;
      }

      const currentIssue = connectionIssueRef.current;
      const firstFailedAt = currentIssue?.firstFailedAt ?? now;
      const nextIssue = { firstFailedAt, lastFailedAt: now, message, reconnectableLocalSession };

      setConnectionIssue(nextIssue);

      if (now - firstFailedAt >= DASHBOARD_RECONNECT_GRACE_MS) {
        setError(message);
      } else {
        setError(null);
      }
    },
    [setError],
  );

  useEffect(() => {
    let cancelled = false;

    void ensureDashboardRuntimeConfig().then((config) => {
      if (!cancelled) setRuntimeConfig(config);
    });

    return () => {
      cancelled = true;
    };
  }, []);

  const applyDashboardResponse = useCallback(
    async (response: Response, fallbackMessage: string, selectDashboard: DashboardResponseSelector = (payload) => payload as DashboardPayload) => {
      const payload = await readDashboardApiResponse(response, fallbackMessage);

      const nextDashboard = selectDashboard(payload);
      if (!nextDashboard) {
        throw new Error(fallbackMessage);
      }

      setDashboard(nextDashboard);
      setConnectionIssue(null);
      setError(null);
      return nextDashboard;
    },
    [setDashboard, setError],
  );

  const submitGuidanceAnswer = useCallback(async (item: GuidanceItem, submission: GuidanceAnswerSubmission) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(guidanceAnswerUrl(item), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify(submission),
      });
      await applyDashboardResponse(response, "Answer was not recorded", dashboardFromEnvelope);
    });
    setSelectedGuidance(null);
  }, [applyDashboardResponse, setSelectedGuidance]);

  const createWorkRequest = useCallback(async (form: NewRequestForm) => {
    const payload = (await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl("/work-requests"), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify(form),
      });
      return readDashboardApiResponse(response, "Request was not created");
    })) as CreateWorkRequestPayload;

    if (!payload.dashboard || !payload.work_request) {
      throw new Error("Request was created, but the dashboard response was incomplete");
    }

    setDashboard(payload.dashboard);
    setConnectionIssue(null);
    setError(null);
    return payload.work_request;
  }, [setDashboard, setError]);

  const submitComment = useCallback<SubmitContextComment>(async (target, body) => {
    const payload = (await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl("/comments"), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({
          target_kind: target.target_kind,
          target_id: target.target_id,
          body,
        }),
      });
      return readDashboardApiResponse(response, "Comment was not recorded");
    })) as { comment?: ContextComment; dashboard?: DashboardPayload };

    if (!payload.dashboard || !payload.comment) {
      throw new Error("Comment was recorded, but the dashboard response was incomplete");
    }

    setDashboard(payload.dashboard);
    setConnectionIssue(null);
    setError(null);
    return payload.comment;
  }, [setDashboard, setError]);

  const resolveComment = useCallback<ResolveContextComment>(async (commentId, resolutionNote) => {
    const payload = (await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl(`/comments/${encodeURIComponent(commentId)}/resolve`), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({
          resolution_note: resolutionNote || "",
        }),
      });
      return readDashboardApiResponse(response, "Comment was not resolved");
    })) as { comment?: ContextComment; dashboard?: DashboardPayload };

    if (!payload.dashboard || !payload.comment) {
      throw new Error("Comment was resolved, but the dashboard response was incomplete");
    }

    setDashboard(payload.dashboard);
    setConnectionIssue(null);
    setError(null);
    return payload.comment;
  }, [setDashboard, setError]);

  const loadDashboard = useCallback(async (mode: "initial" | "refresh" | "silent" | "reconnect" = "refresh") => {
    if (loadInFlightRef.current && mode === "silent") return;
    loadInFlightRef.current = true;

    if (mode === "initial") {
      setLoading(true);
    } else if (mode === "refresh" || mode === "reconnect") {
      setRefreshing(true);
    }

    try {
      await withLocalOperatorReconnect(async () => {
        const config = mode === "reconnect" ? await reconnectLocalOperatorSession() : await ensureDashboardRuntimeConfig();
        setRuntimeConfig(config);
        const response = await operatorFetch(operatorApiUrl("/dashboard"), { headers: jsonHeaders() });
        await applyDashboardResponse(response, "Dashboard API unavailable");
      });
    } catch (caught) {
      recordConnectionFailure(
        dashboardCaughtMessage(caught, "Dashboard API unavailable"),
        mode === "initial" || mode === "reconnect",
        isReconnectableLocalOperatorError(caught),
      );
    } finally {
      loadInFlightRef.current = false;
      setLoading(false);
      if (mode === "refresh" || mode === "reconnect") setRefreshing(false);
    }
  }, [applyDashboardResponse, recordConnectionFailure, setLoading, setRefreshing]);

  const syncPullRequests = useCallback(async () => {
    if (prSyncInFlightRef.current) return;
    prSyncInFlightRef.current = true;

    try {
      await withLocalOperatorReconnect(async () => {
        const headers = await mutationHeaders();
        const response = await operatorFetch(operatorApiUrl("/github/sync-prs"), {
          method: "POST",
          headers,
          body: JSON.stringify({ mode: "auto" }),
        });
        await applyDashboardResponse(response, "GitHub PR sync unavailable", dashboardFromEnvelope);
      });
    } catch (caught) {
      recordConnectionFailure(
        dashboardCaughtMessage(caught, "GitHub PR sync unavailable"),
        false,
        isReconnectableLocalOperatorError(caught),
      );
    } finally {
      prSyncInFlightRef.current = false;
    }
  }, [applyDashboardResponse, recordConnectionFailure]);

  const copyArchitectHandoff = useCallback<CopyArchitectHandoff>(async (workRequestId, cachedHandoff) => {
    let handoff = cachedHandoff || null;

    if (!handoff) {
      const payload = (await withLocalOperatorReconnect(async () => {
        const response = await operatorFetch(operatorApiUrl(`/work-requests/${encodeURIComponent(workRequestId)}/architect-handoff`), {
          method: "POST",
          headers: await mutationHeaders(),
          body: JSON.stringify({}),
        });
        return readDashboardApiResponse(response, "Architect handoff unavailable");
      })) as ArchitectHandoffPayload;

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

  const updateArchiveAfterDays = useCallback(async (archiveAfterDays: number) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl("/settings"), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({ work_request_archive_after_days: archiveAfterDays }),
      });
      await applyDashboardResponse(response, "Settings were not saved", dashboardFromEnvelope);
    });
  }, [applyDashboardResponse]);

  const archiveWorkRequest = useCallback<WorkRequestMutation>(async (workRequestId) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl(`/work-requests/${encodeURIComponent(workRequestId)}/archive`), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({}),
      });
      await applyDashboardResponse(response, "WorkRequest was not archived", dashboardFromEnvelope);
    });
    setSelectedCardDetail(null);
  }, [applyDashboardResponse, setSelectedCardDetail]);

  const restoreWorkRequest = useCallback<WorkRequestMutation>(async (workRequestId) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl(`/work-requests/${encodeURIComponent(workRequestId)}/restore`), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({}),
      });
      await applyDashboardResponse(response, "WorkRequest was not restored", dashboardFromEnvelope);
    });
  }, [applyDashboardResponse]);

  const changeWorkRequestState = useCallback<WorkRequestStateMutation>(async (workRequestId, nextState) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl(`/work-requests/${encodeURIComponent(workRequestId)}/state`), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({ state: nextState }),
      });
      await applyDashboardResponse(response, "WorkRequest state was not changed", dashboardFromEnvelope);
    });
    setSelectedCardDetail(null);
  }, [applyDashboardResponse, setSelectedCardDetail]);

  const changeWorkPackageState = useCallback<WorkPackageStateMutation>(async (workPackageId, action, options) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl(`/work-packages/${encodeURIComponent(workPackageId)}/state`), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({ status: action, no_pr_evidence: options?.noPrEvidence }),
      });
      await applyDashboardResponse(response, "WorkPackage state was not changed", dashboardFromEnvelope);
    });
    setSelectedCardDetail(null);
  }, [applyDashboardResponse, setSelectedCardDetail]);

  const archiveWorkPackage = useCallback<WorkPackageArchiveMutation>(async (workPackageId) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl(`/work-packages/${encodeURIComponent(workPackageId)}/archive`), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({}),
      });
      await applyDashboardResponse(response, "WorkPackage was not archived", dashboardFromEnvelope);
    });
    setSelectedCardDetail(null);
  }, [applyDashboardResponse, setSelectedCardDetail]);

  const clearWorkPackageBlocker = useCallback<WorkPackageBlockerClearMutation>(async (workPackageId, blockerId) => {
    await withLocalOperatorReconnect(async () => {
      const response = await operatorFetch(operatorApiUrl(`/work-packages/${encodeURIComponent(workPackageId)}/blockers/${encodeURIComponent(blockerId)}/clear`), {
        method: "POST",
        headers: await mutationHeaders(),
        body: JSON.stringify({}),
      });
      await applyDashboardResponse(response, "Blocker was not cleared", dashboardFromEnvelope);
    });
    setSelectedCardDetail(null);
  }, [applyDashboardResponse, setSelectedCardDetail]);

  useEffect(() => {
    let cancelled = false;

    queueMicrotask(() => {
      if (!cancelled) void loadDashboard("initial");
    });

    return () => {
      cancelled = true;
    };
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
  const archivedRequests = useMemo(() => dashboard?.archived_work_requests?.work_requests ?? [], [dashboard]);
  const requestDetails = useMemo(() => dashboard?.work_request_details ?? [], [dashboard]);
  const linkedWorkPackageIds = useMemo(() => new Set(dashboard?.linked_work_package_ids ?? []), [dashboard]);
  const requestDetailsByRepo = useMemo(() => requestDetailsByRepoKey(requestDetails), [requestDetails]);
  const packageSelections = useMemo(() => packageSelectionIndex(requestDetails, packages), [packages, requestDetails]);
  const archiveAfterDays = dashboard?.settings?.work_request_archive_after_days ?? 14;
  const guidanceItems = useMemo(() => allGuidanceItems(dashboard), [dashboard]);
  const blockerItems = useMemo(() => activeBlockerItems(packages, packageSelections, dashboard?.active_blocking_edges ?? []), [dashboard?.active_blocking_edges, packages, packageSelections]);
  const finishedPackageLimit = dashboard?.board?.package_limits?.finished_work_packages?.limit;
  const finishedHighlightLimit = finishedPackageLimit === undefined ? FINISHED_HIGHLIGHT_LIMIT : finishedPackageLimit;
  const finishedHighlights = useMemo(() => recentFinishedHighlights(packages, requests, requestDetails, packageSelections, finishedHighlightLimit), [
    finishedHighlightLimit,
    packages,
    packageSelections,
    requests,
    requestDetails,
  ]);
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
  const reconnectDashboard = useCallback(() => loadDashboard("reconnect"), [loadDashboard]);
  const workspacePanes = useMemo<Record<WorkspaceTab, React.ReactNode>>(
    () => ({
      workstreams: (
        <WorkstreamsPane
          repos={workstreamRepos}
          hiddenRepoCount={hiddenWorkstreamCount}
          requestDetailsByRepo={requestDetailsByRepo}
          activeBlockingEdges={dashboard?.active_blocking_edges ?? []}
          guidanceItems={guidanceItems}
          onSelectGuidance={setSelectedGuidance}
          onSelectCard={setSelectedCardDetail}
          onCopyArchitectHandoff={copyArchitectHandoff}
          updateAnimations={updateAnimations}
        />
      ),
      solo: <SoloSessions sessions={soloSessions} onSelectCard={setSelectedCardDetail} updateAnimations={updateAnimations} />,
    }),
    [
      copyArchitectHandoff,
      dashboard?.active_blocking_edges,
      guidanceItems,
      hiddenWorkstreamCount,
      requestDetailsByRepo,
      setSelectedCardDetail,
      setSelectedGuidance,
      soloSessions,
      updateAnimations,
      workstreamRepos,
    ],
  );

  return {
    archiveAfterDays,
    archivedRequests,
    blockerItems,
    canMutateComments: canMutateDashboardComments(runtimeConfig),
    changeWorkPackageState,
    changeWorkRequestState,
    connectionIssue,
    copyArchitectHandoff,
    createWorkRequest,
    dashboard,
    dialogState,
    error,
    finishedHighlights,
    guidanceItems,
    hiddenWorkstreamCount,
    hideEmptyWorkstreams,
    linkedWorkPackageIds,
    loading,
    onArchiveWorkPackage: archiveWorkPackage,
    onClearWorkPackageBlocker: clearWorkPackageBlocker,
    onArchiveWorkRequest: archiveWorkRequest,
    onHideEmptyWorkstreamsChange: setHideEmptyWorkstreams,
    onReconnectDashboard: reconnectDashboard,
    onRefreshDashboard: loadDashboard,
    onRestoreWorkRequest: restoreWorkRequest,
    onResolveComment: resolveComment,
    onSelectCard: setSelectedCardDetail,
    onSelectGuidance: setSelectedGuidance,
    onSetNewRequestOpen: setNewRequestOpen,
    onSubmitComment: submitComment,
    onSubmitGuidanceAnswer: submitGuidanceAnswer,
    onUpdateArchiveAfterDays: updateArchiveAfterDays,
    onWorkspaceTabChange: setWorkspaceTab,
    refreshing,
    repos,
    showUpdateSimulationControls,
    theme,
    toggleTheme,
    updateAnimations,
    workspacePanes,
    workspaceTab,
  };
}
