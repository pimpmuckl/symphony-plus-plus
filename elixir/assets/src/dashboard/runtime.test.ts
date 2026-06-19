import { describe, expect, it } from "vitest";

import { mutationShouldRefreshDashboard } from "./runtime";

describe("dashboard runtime mutation helpers", () => {
  it("refreshes the board after slim mutation responses by default", () => {
    expect(mutationShouldRefreshDashboard({ ok: true, refresh: { dashboard: true, work_request_id: "wr-1" } })).toBe(true);
    expect(mutationShouldRefreshDashboard({ ok: true })).toBe(true);
  });

  it("allows a mutation response to opt out of a dashboard refresh", () => {
    expect(mutationShouldRefreshDashboard({ ok: true, refresh: { dashboard: false } })).toBe(false);
  });
});
