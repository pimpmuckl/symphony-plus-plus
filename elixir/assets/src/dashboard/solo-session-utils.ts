import type { BadgeTone } from "@/lib/operational-state";
import { sortedCopy } from "@/lib/collections";
import { formatStatus } from "@/lib/status-labels";
import type { SoloSession, SoloSessionEntry } from "@/types/dashboard";

import { stripMarkdown } from "./dashboard-text";
import { sortableTime } from "./workstream-data";

export function soloSessionLane(session: SoloSession): "active" | "finished" {
  return ["completed", "archived", "finished", "closed"].includes(session.status || "") ? "finished" : "active";
}

export function soloSessionUpdateKey(session: SoloSession) {
  return `solo:${session.id}`;
}

export function soloSessionAttention(session: SoloSession) {
  const entryCounts = session.entry_counts || [];
  const text = [session.status, session.latest_entry?.kind, session.latest_entry?.kind_label, session.latest_entry?.status, session.latest_entry?.title, session.latest_entry?.body]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  return {
    guidanceCount: soloGuidanceAttention(entryCounts, text),
    blockerCount: soloBlockerAttention(session, entryCounts, text),
  };
}

function soloEntryMentions(entry: NonNullable<SoloSession["entry_counts"]>[number], needles: string[]) {
  const text = [entry.kind, entry.label].filter(Boolean).join(" ").toLowerCase();
  return needles.some((needle) => text.includes(needle));
}

function soloGuidanceAttention(entryCounts: NonNullable<SoloSession["entry_counts"]>, text: string) {
  return (
    entryCounts.reduce((count, entry) => count + (soloEntryMentions(entry, ["guidance", "human_info", "human info", "question"]) ? entry.count || 0 : 0), 0) ||
    (/(guidance|human info|human_info|question)/.test(text) ? 1 : 0)
  );
}

function soloBlockerAttention(session: SoloSession, entryCounts: NonNullable<SoloSession["entry_counts"]>, text: string) {
  return (
    soloActiveBlockerCount(session) ??
    (entryCounts.reduce((count, entry) => count + (soloEntryMentions(entry, ["blocker", "blocked"]) ? entry.count || 0 : 0), 0) ||
      (/(blocker|blocked)/.test(text) ? 1 : 0))
  );
}

function soloActiveBlockerCount(session: SoloSession) {
  return typeof session.active_blocker_count === "number" && Number.isFinite(session.active_blocker_count) ? session.active_blocker_count : null;
}

export function soloSessionStatusVariant(status?: string | null): BadgeTone {
  if (["completed", "archived", "finished", "closed"].includes(status || "")) return "success";
  if (["blocked", "human_info_needed"].includes(status || "")) return "danger";
  if (status === "paused") return "warning";
  return "info";
}

export function sortSoloEntries(entries: SoloSessionEntry[]) {
  return sortedCopy(entries, (left, right) => {
    const leftSequence = left.sequence ?? 0;
    const rightSequence = right.sequence ?? 0;
    if (leftSequence !== rightSequence) return leftSequence - rightSequence;
    return sortableTime(left.created_at || left.updated_at) - sortableTime(right.created_at || right.updated_at);
  });
}

export function latestSoloEntries(entries: SoloSessionEntry[]) {
  return sortedCopy(entries, (left, right) => {
    const timeDelta = sortableTime(right.created_at || right.updated_at) - sortableTime(left.created_at || left.updated_at);
    if (timeDelta !== 0) return timeDelta;
    return (right.sequence ?? 0) - (left.sequence ?? 0);
  }).slice(0, 3);
}

export function soloEntriesByKind(entries: SoloSessionEntry[], kinds: string[]) {
  return entries.filter((entry) => kinds.includes(entry.kind || ""));
}

export function activeSoloBlockerEntries(entries: SoloSessionEntry[]) {
  const latestByBlockerId = new Map<string, { entry: SoloSessionEntry; status: string }>();

  sortSoloEntries(entries)
    .filter((entry) => entry.kind === "blocker")
    .forEach((entry) => {
      latestByBlockerId.set(soloBlockerId(entry), {
        entry,
        status: soloBlockerStatus(entry),
      });
    });

  return Array.from(latestByBlockerId.values())
    .filter(({ status }) => status !== "resolved")
    .map(({ entry }) => entry);
}

function soloBlockerId(entry: SoloSessionEntry) {
  const blockerId = entry.payload?.blocker_id;
  if (typeof blockerId === "string" && blockerId.trim()) return blockerId.trim();
  return entry.id || `solo-blocker:${entry.sequence ?? "unknown"}`;
}

function soloBlockerStatus(entry: SoloSessionEntry) {
  const status = entry.payload?.blocker_status;
  if (status === "open" || status === "resolved") return status;
  return ["resolved", "completed"].includes(entry.status || "") ? "resolved" : "open";
}

export function soloPlanningGroups(entries: SoloSessionEntry[]) {
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

export function soloPlanningMeta(groups: Array<{ entries: SoloSessionEntry[] }>, loading: boolean, error: string | null) {
  if (loading) return "Loading";
  if (error) return "Unavailable";

  const count = groups.reduce((total, group) => total + group.entries.length, 0);
  return count === 1 ? "1 entry" : `${count} entries`;
}

export function soloProgressMeta(entries: SoloSessionEntry[], loading: boolean, error: string | null) {
  if (loading) return "Loading";
  if (error) return "Unavailable";
  return entries.length === 1 ? "1 latest entry" : `${entries.length} latest entries`;
}

export function soloBlockerMeta(blockers: SoloSessionEntry[], attention: { guidanceCount: number; blockerCount: number }) {
  if (blockers.length > 0) return blockers.length === 1 ? "1 blocker" : `${blockers.length} blockers`;
  if (attention.guidanceCount > 0) return `${attention.guidanceCount} guidance`;
  return "Clear";
}

export function soloSessionAttentionText(attention: { guidanceCount: number; blockerCount: number }) {
  const parts = [];
  if (attention.blockerCount > 0) parts.push(`${attention.blockerCount} blocker${attention.blockerCount === 1 ? "" : "s"}`);
  if (attention.guidanceCount > 0) parts.push(`${attention.guidanceCount} guidance`);
  return parts.length > 0 ? parts.join(" / ") : "Clear";
}

export function soloSessionPurpose(session: SoloSession, entries: SoloSessionEntry[]) {
  const planEntry = soloEntriesByKind(entries, ["task_plan"])[0];
  const planBody = markdownSummary(planEntry?.body);
  const latestBody = markdownSummary(session.latest_entry?.body);

  return firstSentence(planBody) || firstSentence(latestBody) || session.title || "No Solo Session purpose has been recorded yet.";
}

export function soloEntrySummary(entry: SoloSessionEntry) {
  const validationResult = typeof entry.payload?.result === "string" ? formatStatus(entry.payload.result) : "";
  const resolution = typeof entry.payload?.resolution === "string" ? entry.payload.resolution : "";
  return firstSentence(markdownSummary(entry.body)) || firstSentence(resolution) || validationResult;
}

function markdownSummary(value?: string | null) {
  if (!value?.trim()) return "";

  const meaningfulLine =
    value
      .replace(/\r\n/g, "\n")
      .split("\n")
      .map((line) => line.trim())
      .find((line) => line && !line.startsWith("#") && !line.startsWith("```")) || "";

  return stripMarkdown(meaningfulLine || value).replace(/\s+/g, " ");
}

function firstSentence(value: string) {
  return value.match(/^(.+?[.!?])(?:\s|$)/)?.[1] || value;
}
