import { Badge } from "@/components/ui/badge";
import type { CopyArchitectHandoff, GuidanceItem, PlannedSlice, SoloSession, SoloSessionDetailPayload, WorkPackageCard, WorkPackageDetailPayload, WorkRequestDetail } from "@/types/dashboard";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Loader2 } from "lucide-react";
import type * as React from "react";
import { dashboardPrefersReducedMotion } from "@/components/dashboard/motion-utils";
import { formatStatus } from "@/lib/status-labels";
import { operationalBadgeVariant, operationalLabel, sliceOperationalState } from "@/lib/operational-state";
import { useEffect, useReducer, useState } from "react";
import { CARD_DETAIL_HEIGHT_MS, CARD_DETAIL_LOADING_HOLD_MS, CARD_DETAIL_WIDTH_MS, CardDetailSelection, CardDetailStage, ResolveContextComment, SubmitContextComment, WorkPackageArchiveMutation, WorkPackageStateMutation, WorkRequestMutation, WorkRequestStateMutation, ensureDashboardRuntimeConfig, jsonHeaders, operatorApiUrl, operatorFetch, readDashboardApiResponse, withLocalOperatorReconnect } from "./runtime";
import { PackageDetailContent, SliceDetailContent } from "./package-detail";
import { RequestDetailContent } from "./request-detail";
import { SoloSessionDetailContent } from "./solo-detail";
import { repoDisplayName } from "./dashboard-persistence";
import { soloSessionStatusVariant } from "./solo-sessions";

export type DetailResourceState<T> = {
  payload: T | null;
  loading: boolean;
  error: string | null;
};

export type CardDetailDialogState = {
  package: DetailResourceState<WorkPackageDetailPayload>;
  solo: DetailResourceState<SoloSessionDetailPayload>;
};

export type CardDetailDialogAction =
  | { type: "resetPackage" }
  | { type: "loadPackage" }
  | { type: "packageSuccess"; payload: WorkPackageDetailPayload }
  | { type: "packageError"; error: string }
  | { type: "resetSolo" }
  | { type: "loadSolo" }
  | { type: "soloSuccess"; payload: SoloSessionDetailPayload }
  | { type: "soloError"; error: string };

export const emptyPackageDetailState: DetailResourceState<WorkPackageDetailPayload> = {
  payload: null,
  loading: false,
  error: null,
};

export const emptySoloDetailState: DetailResourceState<SoloSessionDetailPayload> = {
  payload: null,
  loading: false,
  error: null,
};

export const initialCardDetailDialogState: CardDetailDialogState = {
  package: emptyPackageDetailState,
  solo: emptySoloDetailState,
};

export function cardDetailDialogReducer(state: CardDetailDialogState, action: CardDetailDialogAction): CardDetailDialogState {
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

export async function loadOperatorPayload<T>(path: string, signal: AbortSignal, fallbackMessage: string): Promise<T> {
  return withLocalOperatorReconnect(async () => {
    await ensureDashboardRuntimeConfig();
    const response = await operatorFetch(operatorApiUrl(path), {
      headers: jsonHeaders(),
      signal,
    });
    const payload = await readDashboardApiResponse(response, fallbackMessage);
    return payload as T;
  });
}

export function CardDetailDialog({
  selection,
  onOpenChange,
  onSelectGuidance,
  onCopyArchitectHandoff,
  onArchiveWorkRequest,
  onChangeWorkRequestState,
  onChangeWorkPackageState,
  onArchiveWorkPackage,
  linkedWorkPackageIds,
  onSubmitComment,
  onResolveComment,
  canMutateComments,
}: {
  selection: CardDetailSelection | null;
  onOpenChange: (open: boolean) => void;
  onSelectGuidance: (item: GuidanceItem) => void;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  onArchiveWorkRequest: WorkRequestMutation;
  onChangeWorkRequestState: WorkRequestStateMutation;
  onChangeWorkPackageState: WorkPackageStateMutation;
  onArchiveWorkPackage: WorkPackageArchiveMutation;
  linkedWorkPackageIds: Set<string>;
  onSubmitComment: SubmitContextComment;
  onResolveComment: ResolveContextComment;
  canMutateComments: boolean;
}) {
  const [state, dispatch] = useReducer(cardDetailDialogReducer, initialCardDetailDialogState);
  const packageId = selection?.kind === "package" ? selection.pkg.id : null;
  const soloSessionId = selection?.kind === "solo" ? selection.session.id : null;
  const selectionIdentity = cardDetailSelectionIdentity(selection);
  const prefersReducedDetailMotion = useDashboardReducedMotionPreference();
  const [detailStage, setDetailStage] = useState<{ key: string; stage: CardDetailStage }>({ key: "closed", stage: "ready" });

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

  useEffect(() => {
    let cancelled = false;

    queueMicrotask(() => {
      if (cancelled) return;

      setDetailStage((current) => {
        if (!selection) return current.key === "closed" ? current : { key: "closed", stage: "ready" };
        return current.key === selectionIdentity ? current : { key: selectionIdentity, stage: prefersReducedDetailMotion ? "ready" : "loading" };
      });
    });

    return () => {
      cancelled = true;
    };
  }, [prefersReducedDetailMotion, selection, selectionIdentity]);

  const detailReady = cardDetailContentReady(selection, state);

  useEffect(() => {
    if (!selection || !prefersReducedDetailMotion || detailStage.key !== selectionIdentity || detailStage.stage === "ready") return;

    let cancelled = false;

    queueMicrotask(() => {
      if (!cancelled) setDetailStage((current) => (current.key === selectionIdentity ? { ...current, stage: "ready" } : current));
    });

    return () => {
      cancelled = true;
    };
  }, [detailStage, prefersReducedDetailMotion, selection, selectionIdentity]);

  useEffect(() => {
    if (prefersReducedDetailMotion || !selection || !detailReady || detailStage.key !== selectionIdentity || detailStage.stage !== "loading") return;

    const timer = window.setTimeout(() => {
      setDetailStage((current) => (current.key === selectionIdentity && current.stage === "loading" ? { ...current, stage: "width" } : current));
    }, CARD_DETAIL_LOADING_HOLD_MS);

    return () => window.clearTimeout(timer);
  }, [detailReady, detailStage, prefersReducedDetailMotion, selection, selectionIdentity]);

  useEffect(() => {
    if (prefersReducedDetailMotion || !selection || detailStage.key !== selectionIdentity) return;

    if (detailStage.stage === "width") {
      const timer = window.setTimeout(() => {
        setDetailStage((current) => (current.key === selectionIdentity && current.stage === "width" ? { ...current, stage: "height" } : current));
      }, CARD_DETAIL_WIDTH_MS);

      return () => window.clearTimeout(timer);
    }

    if (detailStage.stage === "height") {
      const timer = window.setTimeout(() => {
        setDetailStage((current) => (current.key === selectionIdentity && current.stage === "height" ? { ...current, stage: "ready" } : current));
      }, CARD_DETAIL_HEIGHT_MS);

      return () => window.clearTimeout(timer);
    }
  }, [detailStage, prefersReducedDetailMotion, selection, selectionIdentity]);

  const effectiveLoadingPackage = selection?.kind === "package" && !state.package.payload && !state.package.error ? true : state.package.loading;
  const effectiveLoadingSolo = selection?.kind === "solo" && !state.solo.payload && !state.solo.error ? true : state.solo.loading;
  const activeDetailStage = prefersReducedDetailMotion ? "ready" : detailStage.key === selectionIdentity ? detailStage.stage : "loading";
  const showStagedLoadingHeader = Boolean(selection && (activeDetailStage === "loading" || activeDetailStage === "width"));
  const detailMotionKey = cardDetailMotionKey(selection, {
    loadingPackage: selection?.kind === "package" && showStagedLoadingHeader,
    loadingSolo: selection?.kind === "solo" && showStagedLoadingHeader,
    packageDetail: state.package.payload,
    packageError: state.package.error,
    soloDetail: state.solo.payload,
    soloError: state.solo.error,
  });

  return (
    <Dialog open={Boolean(selection)} onOpenChange={onOpenChange}>
      <DialogContent className="dashboard-dialog-content card-detail-dialog" data-detail-stage={activeDetailStage} resizeKey={`${activeDetailStage}:${detailMotionKey}`}>
        <NaturalDetailBody motionKey={detailMotionKey}>
          {selection && showStagedLoadingHeader ? <CardDetailLoadingContent selection={selection} stage={activeDetailStage} /> : null}
          {selection?.kind === "request" && !showStagedLoadingHeader ? (
            <RequestDetailContent
              detail={selection.detail}
              onSelectGuidance={onSelectGuidance}
              onCopyArchitectHandoff={onCopyArchitectHandoff}
              onArchiveWorkRequest={onArchiveWorkRequest}
              onChangeWorkRequestState={onChangeWorkRequestState}
              onSubmitComment={onSubmitComment}
              onResolveComment={onResolveComment}
              canMutateComments={canMutateComments}
            />
          ) : null}
          {selection?.kind === "slice" && !showStagedLoadingHeader ? (
            <SliceDetailContent
              detail={selection.detail}
              slice={selection.slice}
              pkg={selection.pkg}
              onSubmitComment={onSubmitComment}
              onResolveComment={onResolveComment}
              canMutateComments={canMutateComments}
            />
          ) : null}
          {selection?.kind === "package" && !showStagedLoadingHeader ? (
            <PackageDetailContent
              selection={selection}
              detailPayload={state.package.payload}
              loading={effectiveLoadingPackage}
              error={state.package.error}
              onChangeWorkPackageState={onChangeWorkPackageState}
              onArchiveWorkPackage={onArchiveWorkPackage}
              linkedWorkPackageIds={linkedWorkPackageIds}
              onSubmitComment={onSubmitComment}
              onResolveComment={onResolveComment}
              canMutateComments={canMutateComments}
            />
          ) : null}
          {selection?.kind === "solo" && !showStagedLoadingHeader ? (
            <SoloSessionDetailContent session={selection.session} detailPayload={state.solo.payload} loading={effectiveLoadingSolo} error={state.solo.error} />
          ) : null}
        </NaturalDetailBody>
      </DialogContent>
    </Dialog>
  );
}

export function useDashboardReducedMotionPreference() {
  const [prefersReducedMotion, setPrefersReducedMotion] = useState(() => dashboardPrefersReducedMotion());

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return;

    const query = window.matchMedia("(prefers-reduced-motion: reduce)");
    const updatePreference = () => setPrefersReducedMotion(query.matches);

    query.addEventListener("change", updatePreference);
    return () => query.removeEventListener("change", updatePreference);
  }, []);

  return prefersReducedMotion;
}

export function cardDetailSelectionIdentity(selection: CardDetailSelection | null) {
  if (!selection) return "closed";

  switch (selection.kind) {
    case "request":
      return `request:${selection.detail.work_request.id}`;
    case "slice":
      return `slice:${selection.slice.id}:${selection.pkg?.id || "undispatched"}`;
    case "package":
      return `package:${selection.pkg.id}`;
    case "solo":
      return `solo:${selection.session.id}`;
  }
}

export function cardDetailContentReady(selection: CardDetailSelection | null, state: CardDetailDialogState) {
  if (!selection) return false;

  switch (selection.kind) {
    case "request":
    case "slice":
      return true;
    case "package": {
      if (state.package.error) return true;
      const payload = state.package.payload;
      if (!payload) return false;
      const payloadId = payload.work_package?.id;
      return !payloadId || payloadId === selection.pkg.id;
    }
    case "solo": {
      if (state.solo.error) return true;
      const payload = state.solo.payload;
      if (!payload) return false;
      const payloadId = payload.solo_session?.id;
      return !payloadId || payloadId === selection.session.id;
    }
  }
}

export function NaturalDetailBody({ motionKey, children }: { motionKey: string; children: React.ReactNode }) {
  return (
    <div className="detail-modal-natural-frame" data-detail-motion-key={motionKey}>
      <div className="detail-modal-size-inner">{children}</div>
    </div>
  );
}

export function cardDetailMotionKey(
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

export function detailLoadState(loading: boolean, payload: unknown, error: string | null) {
  if (error) return "error";
  if (payload) return "loaded";
  return loading ? "loading" : "summary";
}

export function CardDetailLoadingContent({ selection, stage }: { selection: CardDetailSelection; stage: CardDetailStage }) {
  switch (selection.kind) {
    case "request":
      return <RequestDetailLoadingContent detail={selection.detail} stage={stage} />;
    case "slice":
      return <SliceDetailLoadingContent detail={selection.detail} slice={selection.slice} pkg={selection.pkg} stage={stage} />;
    case "package":
      return <PackageDetailLoadingContent selection={selection} stage={stage} />;
    case "solo":
      return <SoloSessionDetailLoadingContent session={selection.session} stage={stage} />;
  }
}

export function DetailLoadingHeader({ title, eyebrow, badge, stage }: { title: string; eyebrow: string; badge: React.ReactNode; stage: CardDetailStage }) {
  return (
    <DialogHeader className="detail-loading-header" data-guidance-section style={{ animationDelay: "35ms" }}>
      <div className="min-w-0">
        <DialogTitle className="detail-loading-title">{title}</DialogTitle>
        <DialogDescription className="detail-loading-eyebrow">{eyebrow}</DialogDescription>
      </div>
      <div className="detail-loading-actions">
        <output
          className="detail-loading-progress"
          data-progress-state={stage === "width" ? "exiting" : "active"}
          aria-label="Loading detail"
          aria-live="polite"
          aria-atomic="true"
        >
          <Loader2 className="size-3.5" aria-hidden="true" />
        </output>
        <div className="shrink-0">{badge}</div>
      </div>
    </DialogHeader>
  );
}

export function RequestDetailLoadingContent({ detail, stage }: { detail: WorkRequestDetail; stage: CardDetailStage }) {
  const request = detail.work_request;
  const operational = request.operational_state || null;

  return (
    <DetailLoadingHeader
      title={request.title || request.id}
      eyebrow={`${repoDisplayName(request)} / ${request.base_branch || "main"} / ${request.work_type || "feature"}`}
      badge={<Badge variant={operationalBadgeVariant(operational, request.status)}>{operationalLabel(operational, request.status)}</Badge>}
      stage={stage}
    />
  );
}

export function SliceDetailLoadingContent({
  detail,
  slice,
  pkg,
  stage,
}: {
  detail: WorkRequestDetail;
  slice: PlannedSlice;
  pkg?: WorkPackageCard;
  stage: CardDetailStage;
}) {
  const request = detail.work_request;
  const operational = sliceOperationalState(slice, pkg);

  return (
    <DetailLoadingHeader
      title={slice.title || slice.id}
      eyebrow={`${repoDisplayName(request)} / ${request.base_branch || "main"} / planned slice`}
      badge={<Badge variant={operationalBadgeVariant(operational, slice.status)}>{operationalLabel(operational, slice.status)}</Badge>}
      stage={stage}
    />
  );
}

export function PackageDetailLoadingContent({ selection, stage }: { selection: Extract<CardDetailSelection, { kind: "package" }>; stage: CardDetailStage }) {
  const pkg = selection.pkg;
  const operational = pkg.operational_state || null;

  return (
    <DetailLoadingHeader
      title={pkg.title || pkg.id}
      eyebrow={`${repoDisplayName(pkg)} / ${pkg.base_branch || "main"} / ${pkg.kind || "work package"}`}
      badge={<Badge variant={operationalBadgeVariant(operational, pkg.status)}>{operationalLabel(operational, pkg.status)}</Badge>}
      stage={stage}
    />
  );
}

export function SoloSessionDetailLoadingContent({ session, stage }: { session: SoloSession; stage: CardDetailStage }) {
  return (
    <DetailLoadingHeader
      title={session.title || session.id}
      eyebrow={`${repoDisplayName(session)} / ${session.base_branch || "main"} / ${session.caller_id || "solo"}`}
      badge={<Badge variant={soloSessionStatusVariant(session.status)}>{formatStatus(session.status)}</Badge>}
      stage={stage}
    />
  );
}
