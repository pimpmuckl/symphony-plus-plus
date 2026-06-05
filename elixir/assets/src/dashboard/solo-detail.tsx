import { Badge } from "@/components/ui/badge";
import { ChevronRight } from "lucide-react";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible";
import { DetailDisclosure, DetailFacts, DetailHeader, DetailStatGrid } from "@/components/dashboard/detail-layout";
import { MarkdownBlock } from "@/components/dashboard/markdown-block";
import type { SoloSession, SoloSessionDetailPayload, SoloSessionEntry } from "@/types/dashboard";
import { formatStatus } from "@/lib/status-labels";
import { repoDisplayName } from "./dashboard-persistence";
import { DetailActivityList } from "./detail-extras";
import { detailDate } from "./detail-utils";
import { latestSoloEntries, soloBlockerMeta, soloEntriesByKind, soloEntrySummary, soloPlanningGroups, soloPlanningMeta, soloProgressMeta, soloSessionAttention, soloSessionAttentionText, soloSessionPurpose, soloSessionStatusVariant, sortSoloEntries } from "./solo-session-utils";

export function SoloSessionDetailContent({
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
      <div className="detail-modal-reveal-body grid gap-4">
        <DetailStatGrid
          stats={[
            { label: "Status", value: formatStatus(detailSession.status) },
            { label: "Last Activity", value: detailDate(detailSession.last_activity_at || detailSession.updated_at || detailSession.inserted_at) },
            { label: "Entries", value: String(detailPayload?.entry_count ?? entries.length) },
            { label: "Attention", value: soloSessionAttentionText(attention) },
          ]}
        />
        <DetailDisclosure title="What It Does" meta="Summary">
          <p>{soloSessionPurpose(detailSession, entries)}</p>
        </DetailDisclosure>
        <DetailDisclosure title="Progress" meta={soloProgressMeta(latestEntries, loading, error)}>
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
        </DetailDisclosure>
        <DetailDisclosure title="Blocked By" meta={soloBlockerMeta(activeBlockers, attention)}>
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
        </DetailDisclosure>
        <DetailDisclosure title="Planning Files" meta={soloPlanningMeta(planningGroups, loading, error)}>
          {loading ? (
            <p className="text-sm text-muted-foreground">Loading planning entries&hellip;</p>
          ) : error ? (
            <p className="text-sm text-muted-foreground">{error}</p>
          ) : planningGroups.length > 0 ? (
            <div className="grid gap-2">
              {planningGroups.map((group) => (
                <SoloPlanningGroup key={group.kind} group={group} defaultOpen={false} />
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
