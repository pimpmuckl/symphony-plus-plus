import type { ActiveBlockingEdge, CopyArchitectHandoff, GuidanceItem, WorkRequestDetail } from "@/types/dashboard";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { AlertTriangle, ChevronRight, GitBranch, GitPullRequest, Layers3, MessageSquareText, Split } from "lucide-react";
import { Collapsible, CollapsibleContent } from "@/components/ui/collapsible";
import { cn } from "@/lib/utils";
import { dashboardPrefersReducedMotion } from "@/components/dashboard/motion-utils";
import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { CardDetailSelect, DashboardUpdateAnimations, REPO_WORKSTREAM_MOTION_MS } from "./runtime";
import { EMPTY_WORK_REQUEST_DETAILS, WorkstreamCategoryCounts } from "./dashboard-state";
import { RepoSummary } from "./dashboard-data";
import { RepoSummaryPlate } from "./dashboard-settings";
import { WorkstreamBoard } from "./workstream-board";
import { defaultRepoWorkstreamOpen, readStoredFinishedRequestChildren, readStoredRepoWorkstreamOpen, repoWorkstreamStateKey, writeStoredFinishedRequestChildren, writeStoredRepoWorkstreamOpen } from "./dashboard-persistence";
import { finishedRequestChildrenStorageKey, linkedPackageIdsForDetails, workstreamCategoryCounts } from "./workstream-data";

export function RepoWorkstream({
  repo,
  requestDetailsByRepo,
  activeBlockingEdges,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  updateAnimations,
}: {
  repo: RepoSummary;
  requestDetailsByRepo: Map<string, WorkRequestDetail[]>;
  activeBlockingEdges: ActiveBlockingEdge[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const stateKey = repoWorkstreamStateKey(repo);
  const contentId = useId();
  const repoDetails = requestDetailsByRepo.get(repo.repoKey) ?? EMPTY_WORK_REQUEST_DETAILS;
  const linkedPackageIds = useMemo(() => linkedPackageIdsForDetails(repoDetails), [repoDetails]);
  const unlinkedPackages = useMemo(() => repo.packages.filter((pkg) => !linkedPackageIds.has(pkg.id)), [repo.packages, linkedPackageIds]);
  const [expandedFinishedRequests, setExpandedFinishedRequests] = useState(() => readStoredFinishedRequestChildren());
  const setFinishedRequestChildrenOpen = useCallback((workRequestId: string, open: boolean) => {
    setExpandedFinishedRequests(() => {
      const next = { ...readStoredFinishedRequestChildren(), [finishedRequestChildrenStorageKey(stateKey, workRequestId)]: open };
      writeStoredFinishedRequestChildren(next);
      return next;
    });
  }, [stateKey]);
  const categoryCounts = useMemo(() => workstreamCategoryCounts(repoDetails), [repoDetails]);
  const [open, setOpen] = useState(() => readStoredRepoWorkstreamOpen(stateKey, defaultRepoWorkstreamOpen(repo)));
  const [openMotion, setOpenMotion] = useState(false);
  const previousOpenRef = useRef(open);
  const openMotionTimerRef = useRef<number | null>(null);
  const toggleOpen = useCallback(() => {
    setOpen((currentOpen) => !currentOpen);
  }, []);

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
      <Card
        className="dashboard-glass-surface workstream-repo-card motion-card"
        data-open={open ? "true" : "false"}
      >
        <CardHeader className="dashboard-panel-header relative space-y-0 overflow-hidden border-b">
          <button
            type="button"
            className="absolute inset-0 cursor-pointer transition-colors hover:bg-muted/25 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
            aria-label={`${open ? "Collapse" : "Open"} ${repo.repo}`}
            aria-expanded={open}
            aria-controls={contentId}
            title={repo.repoRemote || undefined}
            onClick={toggleOpen}
          />
          <div className="pointer-events-none relative flex select-none flex-col gap-3 md:flex-row md:items-center md:justify-between">
            <div className="flex min-w-0 items-center gap-3">
              <span className="flex size-8 shrink-0 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-muted hover:text-foreground">
                <ChevronRight className={cn("size-4 transition-transform duration-200", open && "rotate-90")} />
              </span>
              <div className="min-w-0">
                <CardTitle className="flex items-center gap-2">
                  <GitBranch className="size-4 text-primary" />
                  <span className="truncate" title={repo.repoRemote || undefined}>{repo.repo}</span>
                </CardTitle>
                <p className="mt-1 truncate text-sm text-muted-foreground">{repo.baseBranches.join(", ") || "main"}</p>
              </div>
            </div>
            <div className="flex min-w-0 flex-col gap-2 md:items-end">
              <RepoSummaryStrip repo={repo} categoryCounts={categoryCounts} />
            </div>
          </div>
        </CardHeader>
        <CollapsibleContent
          id={contentId}
          className="collapsible-content workstream-repo-content"
          data-board-open-motion={openMotion ? "open" : "idle"}
        >
          <CardContent className="p-3 sm:p-4" data-board-open-motion={openMotion ? "open" : "idle"}>
            <WorkstreamBoard
              repoDetails={repoDetails}
              packages={repo.packages}
              unlinkedPackages={unlinkedPackages}
              activeBlockingEdges={activeBlockingEdges}
              onSelectGuidance={onSelectGuidance}
              onSelectCard={onSelectCard}
              onCopyArchitectHandoff={onCopyArchitectHandoff}
              expandedFinishedRequests={expandedFinishedRequests}
              finishedRequestScopeKey={stateKey}
              onSetFinishedRequestChildrenOpen={setFinishedRequestChildrenOpen}
              updateAnimations={updateAnimations}
            />
          </CardContent>
        </CollapsibleContent>
      </Card>
    </Collapsible>
  );
}

export function RepoSummaryStrip({ repo, categoryCounts }: { repo: RepoSummary; categoryCounts: WorkstreamCategoryCounts }) {
  const progress = [
    { icon: <GitPullRequest className="size-3.5" />, label: "Requests", value: categoryCounts.requests, tone: "requested" },
    { icon: <Layers3 className="size-3.5" />, label: "Plan Nodes", value: categoryCounts.planNodes, tone: "implementing" },
    { icon: <Split className="size-3.5" />, label: "Slices", value: categoryCounts.slices, tone: "active" },
  ] as const;
  const attention = [
    { icon: <MessageSquareText className="size-3.5" />, label: "Guidance Needed", value: repo.guidanceCount, tone: "guidance" },
    { icon: <AlertTriangle className="size-3.5" />, label: "Active Blockers", value: repo.blockerCount, tone: "blocker" },
  ] as const;

  return (
    <div className="flex min-w-0 flex-wrap items-center gap-2 md:justify-end">
      <div className="flex flex-wrap items-center gap-1.5">
        {progress.map((item) => (
          <RepoSummaryPlate key={item.label} icon={item.icon} label={item.label} value={item.value} tone={item.tone} />
        ))}
      </div>
      <div className="hidden h-6 w-px bg-border md:block" />
      <div className="flex flex-wrap items-center gap-1.5">
        {attention.map((item) => (
          <RepoSummaryPlate key={item.label} icon={item.icon} label={item.label} value={item.value} tone={item.tone} />
        ))}
      </div>
    </div>
  );
}
