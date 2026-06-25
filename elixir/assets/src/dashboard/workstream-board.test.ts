import { describe, expect, it } from "vitest";

import type { WorkRequestDetail } from "@/types/dashboard";
import { mergeRequestDetailsWithExiting } from "./workstream-board";

describe("workstream board removal rendering", () => {
  it("keeps removed request details renderable while they exit", () => {
    const active = requestDetail("wr-active");
    const removed = requestDetail("wr-removed");

    expect(mergeRequestDetailsWithExiting([active], [removed]).map((detail) => detail.work_request.id)).toEqual(["wr-active", "wr-removed"]);
    expect(mergeRequestDetailsWithExiting([active], [active, removed]).map((detail) => detail.work_request.id)).toEqual(["wr-active", "wr-removed"]);
  });
});

function requestDetail(id: string): WorkRequestDetail {
  return {
    work_request: { id, title: id },
  };
}
