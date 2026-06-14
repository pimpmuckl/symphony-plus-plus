import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";

import { Dialog } from "@/components/ui/dialog";
import { BlockerDetailContent, blockerDetailWorkPackageId, scopedBlockerDetailPayload } from "./package-detail";
import type { CardDetailSelection } from "./runtime";
import type { WorkPackageDetailPayload } from "@/types/dashboard";

describe("package detail blocker modal", () => {
  it("does not hydrate blocker detail from a different package with the same blocker id", () => {
    const selection: Extract<CardDetailSelection, { kind: "blocker" }> = {
      kind: "blocker",
      pkg: { id: "pkg-selected", title: "Selected package", status: "blocked" },
      blocker: {
        id: "edge-selected",
        blocker_id: "shared-blocker",
        from: { kind: "work_package", id: "pkg-source" },
        to: { kind: "work_package", id: "pkg-selected" },
        summary: "Selected blocker",
        body: "Selected body",
        work_package_id: "pkg-selected",
      },
    };
    const detailPayload: WorkPackageDetailPayload = {
      work_package: { id: "pkg-other", title: "Other package", status: "blocked" },
      blockers: [{ id: "shared-blocker", active: true, summary: "Stale blocker", body: "Stale body" }],
    };

    expect(scopedBlockerDetailPayload(selection, detailPayload)).toBeNull();
  });

  it("does not use blocker source packages as clear targets", () => {
    const selection: Extract<CardDetailSelection, { kind: "blocker" }> = {
      kind: "blocker",
      blocker: {
        id: "edge-source-only",
        blocker_id: "shared-blocker",
        from: { kind: "work_package", id: "pkg-source" },
        to: { kind: "slice", id: "slice-blocked" },
        summary: "Selected blocker",
      },
    };

    expect(blockerDetailWorkPackageId(selection, null)).toBeNull();
  });

  it("hides blocker clearing outside local operator mode", () => {
    const selection: Extract<CardDetailSelection, { kind: "blocker" }> = {
      kind: "blocker",
      pkg: { id: "pkg-selected", title: "Selected package", status: "blocked" },
      blocker: {
        id: "edge-selected",
        blocker_id: "scope-blocker",
        from: { kind: "work_package", id: "pkg-source" },
        to: { kind: "work_package", id: "pkg-selected" },
        summary: "Selected blocker",
        body: "Selected body",
        work_package_id: "pkg-selected",
      },
    };
    const content = (canMutateOperatorActions: boolean) => (
      <Dialog open>
        <BlockerDetailContent
          selection={selection}
          detailPayload={null}
          loading={false}
          error={null}
          onClearWorkPackageBlocker={async () => undefined}
          canMutateOperatorActions={canMutateOperatorActions}
        />
      </Dialog>
    );

    const readOnlyMarkup = renderToStaticMarkup(content(false));
    const operatorMarkup = renderToStaticMarkup(content(true));

    expect(readOnlyMarkup).not.toContain(">Clear<");
    expect(operatorMarkup).toContain(">Clear<");
  });
});
