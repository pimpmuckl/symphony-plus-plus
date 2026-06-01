import { AlertCircle, Loader2, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import type { CopyArchitectHandoff, DashboardPayload, GuidanceAnswerSubmission, GuidanceItem, WorkRequestCard, WorkRequestDetail } from "@/types/dashboard";
import { GuidanceDialog } from "@/components/dashboard/guidance-dialog";
import { NewRequestDialog } from "@/components/dashboard/new-request-dialog";
import type { NewRequestForm } from "@/components/dashboard/new-request-dialog";
import type * as React from "react";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { TooltipProvider } from "@/components/ui/tooltip";
import type { BoardLayoutMode as WorkstreamLayoutMode } from "@/components/dashboard/board-layout";
import { architectHandoffEligibleRequest } from "@/lib/operational-state";
import { cn } from "@/lib/utils";
import { AppDialogState, BlockerItem, FinishedHighlight } from "./dashboard-state";
import { ArchivedRequestsDialog, DashboardSettingsDialog, ThemeToggle, WorkstreamLayoutToggle } from "./dashboard-settings";
import { CardDetailDialog } from "./card-detail-dialog";
import { CardDetailSelection, DASHBOARD_LOGO_URL, DashboardConnectionIssue, DashboardTheme, DashboardUpdateAnimations, LOCAL_OPERATOR_AUTH_REQUIRED_MESSAGE, ResolveContextComment, SubmitContextComment, WorkPackageArchiveMutation, WorkPackageStateMutation, WorkRequestMutation, WorkRequestStateMutation, WorkspaceTab, isLocalOperatorAuthRequiredMessage } from "./runtime";
import { LiveLedgerBadge } from "./status-cards";
import { RepoSummary } from "./dashboard-data";
import { StatusRail, UpdateSimulationControls } from "./status-rail";
import { WorkspaceTabCarousel } from "./workspace-tabs";

export function DashboardShell({
  archiveAfterDays,
  archivedRequests,
  blockerItems,
  canMutateComments,
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
  onArchiveWorkPackage,
  onArchiveWorkRequest,
  onHideEmptyWorkstreamsChange,
  onReconnectDashboard,
  onRefreshDashboard,
  onResolveComment,
  onRestoreWorkRequest,
  onSelectCard,
  onSelectGuidance,
  onSetNewRequestOpen,
  onSubmitComment,
  onSubmitGuidanceAnswer,
  onUpdateArchiveAfterDays,
  onWorkspaceTabChange,
  onWorkstreamLayoutChange,
  refreshing,
  repos,
  showUpdateSimulationControls,
  theme,
  toggleTheme,
  updateAnimations,
  workspacePanes,
  workspaceTab,
  workstreamLayout,
}: {
  archiveAfterDays: number;
  archivedRequests: WorkRequestCard[];
  blockerItems: BlockerItem[];
  canMutateComments: boolean;
  changeWorkPackageState: WorkPackageStateMutation;
  changeWorkRequestState: WorkRequestStateMutation;
  connectionIssue: DashboardConnectionIssue | null;
  copyArchitectHandoff: CopyArchitectHandoff;
  createWorkRequest: (form: NewRequestForm) => Promise<WorkRequestDetail>;
  dashboard: DashboardPayload | null;
  dialogState: AppDialogState;
  error: string | null;
  finishedHighlights: FinishedHighlight[];
  guidanceItems: GuidanceItem[];
  hiddenWorkstreamCount: number;
  hideEmptyWorkstreams: boolean;
  linkedWorkPackageIds: Set<string>;
  loading: boolean;
  onArchiveWorkPackage: WorkPackageArchiveMutation;
  onArchiveWorkRequest: WorkRequestMutation;
  onHideEmptyWorkstreamsChange: (hide: boolean) => void;
  onReconnectDashboard: () => Promise<void>;
  onRefreshDashboard: () => Promise<void>;
  onResolveComment: ResolveContextComment;
  onRestoreWorkRequest: WorkRequestMutation;
  onSelectCard: (selection: CardDetailSelection | null) => void;
  onSelectGuidance: (item: GuidanceItem | null) => void;
  onSetNewRequestOpen: (open: boolean) => void;
  onSubmitComment: SubmitContextComment;
  onSubmitGuidanceAnswer: (item: GuidanceItem, submission: GuidanceAnswerSubmission) => Promise<void>;
  onUpdateArchiveAfterDays: (archiveAfterDays: number) => Promise<void>;
  onWorkspaceTabChange: (tab: WorkspaceTab) => void;
  onWorkstreamLayoutChange: (mode: WorkstreamLayoutMode) => void;
  refreshing: boolean;
  repos: RepoSummary[];
  showUpdateSimulationControls: boolean;
  theme: DashboardTheme;
  toggleTheme: () => void;
  updateAnimations: DashboardUpdateAnimations;
  workspacePanes: Record<WorkspaceTab, React.ReactNode>;
  workspaceTab: WorkspaceTab;
  workstreamLayout: WorkstreamLayoutMode;
}) {
  const localOperatorReconnectIssue = isLocalOperatorAuthRequiredMessage(error) || connectionIssue?.reconnectableLocalSession === true;
  const dashboardAlertMessage = error || (localOperatorReconnectIssue ? connectionIssue?.message || LOCAL_OPERATOR_AUTH_REQUIRED_MESSAGE : null);

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
              <LiveLedgerBadge error={error} connectionIssue={connectionIssue} databasePath={dashboard?.ledger?.database} />
              <ThemeToggle theme={theme} onToggle={toggleTheme} />
              <DashboardSettingsDialog
                archiveAfterDays={archiveAfterDays}
                hideEmptyWorkstreams={hideEmptyWorkstreams}
                hiddenWorkstreamCount={hiddenWorkstreamCount}
                onArchiveAfterDaysChange={onUpdateArchiveAfterDays}
                onHideEmptyWorkstreamsChange={onHideEmptyWorkstreamsChange}
              />
              <ArchivedRequestsDialog requests={archivedRequests} onRestoreWorkRequest={onRestoreWorkRequest} />
              <Button variant="outline" size="sm" onClick={() => void onRefreshDashboard()} disabled={refreshing} className="button-lift">
                {refreshing ? <Loader2 className="size-4 animate-spin" /> : <RefreshCw className="size-4" />}
                Refresh
              </Button>
              <NewRequestDialog
                canCopyArchitectHandoff={architectHandoffEligibleRequest}
                onCopyArchitectHandoff={copyArchitectHandoff}
                onCreateRequest={createWorkRequest}
                open={dialogState.newRequestOpen}
                onOpenChange={onSetNewRequestOpen}
                repos={repos}
              />
            </div>
          </div>
        </header>

        <div className="mx-auto grid max-w-[1500px] gap-5 px-4 py-5 sm:px-6 lg:px-8">
          {dashboardAlertMessage ? (
            <Card
              className={cn(
                "dashboard-glass-surface motion-card",
                localOperatorReconnectIssue
                  ? "border-amber-200 bg-amber-50 dark:border-amber-700/70 dark:bg-amber-950/45"
                  : "border-rose-200 bg-rose-50 dark:border-rose-700/70 dark:bg-rose-950/45",
              )}
            >
              <CardContent
                className={cn(
                  "flex flex-wrap items-start justify-between gap-3 p-4 text-sm",
                  localOperatorReconnectIssue ? "text-amber-900 dark:text-amber-100" : "text-rose-800 dark:text-rose-200",
                )}
              >
                <div className="flex items-start gap-3">
                  <AlertCircle className="mt-0.5 size-4 shrink-0" />
                  <div className="grid gap-1">
                    <span className="font-medium">
                      {localOperatorReconnectIssue ? "Local operator reconnect" : "Dashboard error"}
                    </span>
                    <span>{dashboardAlertMessage}</span>
                  </div>
                </div>
                {localOperatorReconnectIssue ? (
                  <Button variant="outline" size="sm" onClick={() => void onReconnectDashboard()} disabled={refreshing} className="button-lift">
                    {refreshing ? <Loader2 className="size-4 animate-spin" /> : <RefreshCw className="size-4" />}
                    Reconnect
                  </Button>
                ) : null}
              </CardContent>
            </Card>
          ) : null}

          <StatusRail
            guidanceItems={guidanceItems}
            blockerItems={blockerItems}
            finishedHighlights={finishedHighlights}
            onSelectGuidance={onSelectGuidance}
            onSelectCard={onSelectCard}
            updateAnimations={updateAnimations}
          />

          <Tabs value={workspaceTab} onValueChange={(value) => onWorkspaceTabChange(value as WorkspaceTab)} className="w-full motion-card">
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
              {workspaceTab === "workstreams" ? <WorkstreamLayoutToggle value={workstreamLayout} onChange={onWorkstreamLayoutChange} /> : null}
            </div>
            <WorkspaceTabCarousel activeTab={workspaceTab} paneContent={workspacePanes} />
          </Tabs>
        </div>

        <GuidanceDialog
          item={dialogState.selectedGuidance}
          onOpenChange={(open) => {
            if (!open) onSelectGuidance(null);
          }}
          onSubmitAnswer={onSubmitGuidanceAnswer}
        />
        <CardDetailDialog
          selection={dialogState.selectedCardDetail}
          onOpenChange={(open) => {
            if (!open) onSelectCard(null);
          }}
          onSelectGuidance={onSelectGuidance}
          onCopyArchitectHandoff={copyArchitectHandoff}
          onArchiveWorkRequest={onArchiveWorkRequest}
          onChangeWorkRequestState={changeWorkRequestState}
          onChangeWorkPackageState={changeWorkPackageState}
          onArchiveWorkPackage={onArchiveWorkPackage}
          linkedWorkPackageIds={linkedWorkPackageIds}
          onSubmitComment={onSubmitComment}
          onResolveComment={onResolveComment}
          canMutateComments={canMutateComments}
        />
      </main>
    </TooltipProvider>
  );
}
