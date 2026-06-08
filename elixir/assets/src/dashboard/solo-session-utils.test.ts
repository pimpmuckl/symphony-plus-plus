import { describe, expect, it } from "vitest";

import type { SoloSession, SoloSessionEntry } from "@/types/dashboard";

import { activeSoloBlockerEntries, soloSessionAttention } from "./solo-session-utils";

describe("solo session blocker entries", () => {
  it("uses the newest typed blocker state", () => {
    const entries: SoloSessionEntry[] = [
      blockerEntry("open-entry", 1, "blocked", { blocker_id: "scope-review", blocker_status: "open" }),
      blockerEntry("resolved-entry", 2, "resolved", { blocker_id: "scope-review", blocker_status: "resolved" }),
    ];

    expect(activeSoloBlockerEntries(entries)).toEqual([]);
  });

  it("resolves legacy blocker rows by their entry id", () => {
    const entries: SoloSessionEntry[] = [
      blockerEntry("legacy-entry", 1, "blocked"),
      blockerEntry("legacy-resolution", 2, "resolved", { blocker_id: "legacy-entry", blocker_status: "resolved" }),
    ];

    expect(activeSoloBlockerEntries(entries)).toEqual([]);
  });

  it("keeps unresolved blockers visible", () => {
    const entries: SoloSessionEntry[] = [
      blockerEntry("old-entry", 1, "blocked", { blocker_id: "old", blocker_status: "open" }),
      blockerEntry("active-entry", 2, "blocked", { blocker_id: "active", blocker_status: "open" }),
      blockerEntry("old-resolution", 3, "resolved", { blocker_id: "old", blocker_status: "resolved" }),
    ];

    expect(activeSoloBlockerEntries(entries).map((entry) => entry.id)).toEqual(["active-entry"]);
  });

  it("uses active blocker counts before historical blocker entry counts", () => {
    const session: SoloSession = {
      id: "solo-session",
      status: "active",
      active_blocker_count: 0,
      entry_counts: [{ kind: "blocker", label: "Blockers", count: 2 }],
    };

    expect(soloSessionAttention(session).blockerCount).toBe(0);
  });
});

function blockerEntry(id: string, sequence: number, status: string, payload?: Record<string, unknown>): SoloSessionEntry {
  return {
    id,
    sequence,
    kind: "blocker",
    status,
    title: id,
    payload,
    created_at: `2026-06-08T00:00:${String(sequence).padStart(2, "0")}Z`,
  };
}
