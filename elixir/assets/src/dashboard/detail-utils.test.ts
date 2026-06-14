import { describe, expect, it } from "vitest";

import { canMutateDashboardComments, canMutateDashboardOperatorActions } from "./detail-utils";

describe("dashboard mutation gates", () => {
  it("allows local mutations only for operator-mode dashboard config", () => {
    expect(canMutateDashboardOperatorActions({ operatorMode: true })).toBe(true);
    expect(canMutateDashboardOperatorActions({ operatorMode: false })).toBe(false);
    expect(canMutateDashboardOperatorActions()).toBe(false);
  });

  it("keeps comment mutation aligned with local operator actions", () => {
    expect(canMutateDashboardComments({ operatorMode: true })).toBe(true);
    expect(canMutateDashboardComments({ operatorMode: false })).toBe(false);
  });
});
