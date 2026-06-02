import { Archive, CheckCircle2, Loader2, Moon, RotateCcw, Settings2, Sun } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { NumberWheel, useCountMotion } from "@/components/dashboard/motion";
import type * as React from "react";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import type { WorkRequestCard } from "@/types/dashboard";
import type { BoardLayoutMode as WorkstreamLayoutMode } from "@/components/dashboard/board-layout";
import { cn } from "@/lib/utils";
import { sortedCopy } from "@/lib/collections";
import { useMemo, useRef, useState } from "react";
import { DashboardTheme, REPO_SUMMARY_PLATE_TONES, RepoSummaryPlateTone, WorkRequestMutation } from "./runtime";
import { detailDate } from "./detail-extras";
import { repoDisplayName } from "./dashboard-persistence";
import { sortableTime } from "./workstream-data";

export function WorkstreamLayoutToggle({ value, onChange }: { value: WorkstreamLayoutMode; onChange: (mode: WorkstreamLayoutMode) => void }) {
  return (
    <fieldset className="workstream-layout-toggle">
      <legend className="sr-only">Workstream layout</legend>
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
    </fieldset>
  );
}

export function ThemeToggle({ theme, onToggle }: { theme: DashboardTheme; onToggle: () => void }) {
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

export function DashboardSettingsDialog({
  archiveAfterDays,
  hideEmptyWorkstreams,
  hideUnlinkedWorkPackages,
  hiddenWorkstreamCount,
  hiddenUnlinkedWorkPackageCount,
  onArchiveAfterDaysChange,
  onHideEmptyWorkstreamsChange,
  onHideUnlinkedWorkPackagesChange,
}: {
  archiveAfterDays: number;
  hideEmptyWorkstreams: boolean;
  hideUnlinkedWorkPackages: boolean;
  hiddenWorkstreamCount: number;
  hiddenUnlinkedWorkPackageCount: number;
  onArchiveAfterDaysChange: (value: number) => Promise<void>;
  onHideEmptyWorkstreamsChange: (value: boolean) => void;
  onHideUnlinkedWorkPackagesChange: (value: boolean) => void;
}) {
  const [open, setOpen] = useState(false);
  const initialFocusRef = useRef<HTMLDivElement | null>(null);
  const [archiveDaysDraftState, setArchiveDaysDraftState] = useState({
    source: archiveAfterDays,
    value: String(archiveAfterDays),
  });
  const [archiveDaysPending, setArchiveDaysPending] = useState(false);
  const [archiveDaysErrorState, setArchiveDaysErrorState] = useState<{ source: number; message: string | null }>({
    source: archiveAfterDays,
    message: null,
  });
  const visibilityLabel = hideEmptyWorkstreams
    ? workstreamHiddenSummary(hiddenWorkstreamCount)
    : "Showing repos even when they have no requests, slices, or work packages.";
  const unlinkedVisibilityLabel = hideUnlinkedWorkPackages
    ? unlinkedWorkPackageHiddenSummary(hiddenUnlinkedWorkPackageCount)
    : "Showing unlinked work packages in the main board.";
  const archiveDaysDraft =
    archiveDaysDraftState.source === archiveAfterDays ? archiveDaysDraftState.value : String(archiveAfterDays);
  const archiveDaysError = archiveDaysErrorState.source === archiveAfterDays ? archiveDaysErrorState.message : null;
  const archiveDaysDraftValue = archiveDaysDraft.trim();
  const archiveDaysValue = Number(archiveDaysDraftValue);
  const archiveDaysValid =
    /^\d+$/.test(archiveDaysDraftValue) && Number.isInteger(archiveDaysValue) && archiveDaysValue >= 1 && archiveDaysValue <= 3650;
  const archiveDaysChanged = archiveDaysValid && archiveDaysValue !== archiveAfterDays;

  function setArchiveDaysDraft(value: string) {
    setArchiveDaysDraftState({ source: archiveAfterDays, value });
  }

  function setArchiveDaysError(message: string | null) {
    setArchiveDaysErrorState({ source: archiveAfterDays, message });
  }

  async function saveArchiveDays(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!archiveDaysValid) {
      setArchiveDaysError("Use a whole number from 1 to 3650.");
      return;
    }

    setArchiveDaysPending(true);
    setArchiveDaysError(null);

    try {
      await onArchiveAfterDaysChange(archiveDaysValue);
    } catch (caught) {
      setArchiveDaysError(caught instanceof Error ? caught.message : "Archive cutoff was not saved");
    } finally {
      setArchiveDaysPending(false);
    }
  }

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
            onClick={() => {
              setArchiveDaysError(null);
              setOpen(true);
            }}
          >
            <Settings2 className="size-4" />
          </Button>
        </TooltipTrigger>
        <TooltipContent>Settings</TooltipContent>
      </Tooltip>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent
          className="dashboard-dialog-content max-w-md"
          onOpenAutoFocus={(event) => {
            event.preventDefault();
            initialFocusRef.current?.focus();
          }}
        >
          <DialogHeader>
            <DialogTitle>Settings</DialogTitle>
            <DialogDescription>Dashboard display preferences</DialogDescription>
          </DialogHeader>

          <div ref={initialFocusRef} tabIndex={-1} className="grid gap-3 rounded-md border bg-card/60 p-3 outline-none">
            <div>
              <span className="block text-sm font-medium">Archive cutoff</span>
              <span className="mt-1 block text-xs text-muted-foreground">Delivered WorkRequests auto-archive after {archiveAfterDays} days.</span>
            </div>
            <form className="flex items-start gap-2" onSubmit={(event) => void saveArchiveDays(event)}>
              <Input
                aria-label="Archive cutoff days"
                min={1}
                max={3650}
                step={1}
                type="number"
                value={archiveDaysDraft}
                onChange={(event) => setArchiveDaysDraft(event.target.value)}
              />
              <Button type="submit" size="sm" disabled={archiveDaysPending || !archiveDaysChanged}>
                {archiveDaysPending ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}
                Save
              </Button>
            </form>
            {archiveDaysError ? <p className="text-xs text-destructive">{archiveDaysError}</p> : null}
          </div>

          <SettingsSwitch
            checked={hideEmptyWorkstreams}
            label="Hide empty workstreams"
            description={visibilityLabel}
            onChange={onHideEmptyWorkstreamsChange}
          />

          <SettingsSwitch
            checked={hideUnlinkedWorkPackages}
            label="Hide unlinked work packages"
            description={unlinkedVisibilityLabel}
            onChange={onHideUnlinkedWorkPackagesChange}
          />
        </DialogContent>
      </Dialog>
    </>
  );
}

export function workstreamHiddenSummary(hiddenWorkstreamCount: number) {
  if (hiddenWorkstreamCount <= 0) return "Only repos with requests, slices, or work packages appear.";
  return hiddenWorkstreamCount === 1 ? "1 empty repo hidden" : `${hiddenWorkstreamCount} empty repos hidden`;
}

export function unlinkedWorkPackageHiddenSummary(hiddenUnlinkedWorkPackageCount: number) {
  if (hiddenUnlinkedWorkPackageCount <= 0) return "No unlinked work packages are currently hidden.";
  return hiddenUnlinkedWorkPackageCount === 1
    ? "1 unlinked work package hidden from the main board."
    : `${hiddenUnlinkedWorkPackageCount} unlinked work packages hidden from the main board.`;
}

function SettingsSwitch({
  checked,
  description,
  label,
  onChange,
}: {
  checked: boolean;
  description: string;
  label: string;
  onChange: (checked: boolean) => void;
}) {
  return (
    <div className="flex items-center justify-between gap-4 rounded-md border bg-card/60 p-3">
      <div className="min-w-0">
        <span className="block text-sm font-medium">{label}</span>
        <span className="mt-1 block text-xs text-muted-foreground">{description}</span>
      </div>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        aria-label={label}
        className={cn(
          "relative h-6 w-11 shrink-0 rounded-full bg-muted transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ring",
          checked && "bg-primary",
        )}
        onClick={() => onChange(!checked)}
      >
        <span
          className={cn(
            "absolute left-1 top-1 size-4 rounded-full bg-background shadow transition-transform",
            checked && "translate-x-5",
          )}
        />
      </button>
    </div>
  );
}

export function ArchivedRequestsDialog({ requests, onRestoreWorkRequest }: { requests: WorkRequestCard[]; onRestoreWorkRequest: WorkRequestMutation }) {
  const [open, setOpen] = useState(false);
  const [pendingId, setPendingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const sortedRequests = useMemo(() => sortedCopy(requests, (left, right) => sortableTime(right.archived_at) - sortableTime(left.archived_at)), [requests]);

  async function restoreRequest(workRequestId: string) {
    setPendingId(workRequestId);
    setError(null);

    try {
      await onRestoreWorkRequest(workRequestId);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "WorkRequest was not restored");
    } finally {
      setPendingId(null);
    }
  }

  return (
    <>
      <Tooltip>
        <TooltipTrigger asChild>
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="button-lift relative"
            aria-label="Archived requests"
            onClick={() => {
              setError(null);
              setOpen(true);
            }}
          >
            <Archive className="size-4" />
            {requests.length > 0 ? (
              <span className="absolute -right-1 -top-1 min-w-4 rounded-full bg-primary px-1 text-[10px] font-semibold leading-4 text-primary-foreground">
                {requests.length}
              </span>
            ) : null}
          </Button>
        </TooltipTrigger>
        <TooltipContent>Archived requests</TooltipContent>
      </Tooltip>

      <Dialog
        open={open}
        onOpenChange={(nextOpen) => {
          if (nextOpen) setError(null);
          setOpen(nextOpen);
        }}
      >
        <DialogContent className="dashboard-dialog-content max-w-lg">
          <DialogHeader>
            <DialogTitle>Archived Requests</DialogTitle>
            <DialogDescription>Delivered WorkRequests hidden from the active cockpit</DialogDescription>
          </DialogHeader>

          {error ? <p className="rounded-md border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive">{error}</p> : null}

          {sortedRequests.length > 0 ? (
            <ScrollArea className="max-h-[55vh] pr-3">
              <div className="grid gap-2">
                {sortedRequests.map((request) => (
                  <div key={request.id} className="detail-list-item flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <span className="block truncate text-sm font-medium">{request.title || request.id}</span>
                      <span className="mt-1 block text-xs text-muted-foreground">
                        {repoDisplayName(request)} / {request.base_branch || "main"} / archived {detailDate(request.archived_at)}
                      </span>
                    </div>
                    <Button
                      type="button"
                      size="sm"
                      variant="outline"
                      disabled={pendingId === request.id}
                      onClick={() => void restoreRequest(request.id)}
                    >
                      {pendingId === request.id ? <Loader2 className="size-4 animate-spin" /> : <RotateCcw className="size-4" />}
                      Restore
                    </Button>
                  </div>
                ))}
              </div>
            </ScrollArea>
          ) : (
            <p className="rounded-md border bg-card/60 px-3 py-6 text-center text-sm text-muted-foreground">No archived requests.</p>
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}

export function RepoSummaryPlate({
  label,
  value,
  tone,
}: {
  label: string;
  value: number;
  tone: RepoSummaryPlateTone;
}) {
  const countMotion = useCountMotion(value);

  return (
    <div className={cn("inline-flex items-center gap-1.5 rounded-md border px-2 py-1 text-xs font-medium", REPO_SUMMARY_PLATE_TONES[tone])}>
      <span className="font-semibold tabular-nums">
        <NumberWheel value={value} motion={countMotion} compact />
      </span>
      <span className="whitespace-nowrap">{label}</span>
    </div>
  );
}
