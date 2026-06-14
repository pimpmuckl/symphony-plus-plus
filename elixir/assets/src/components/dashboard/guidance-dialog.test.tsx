import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";

import { Dialog } from "@/components/ui/dialog";
import { GuidanceDialogBody } from "./guidance-dialog";
import type { GuidanceItem } from "@/types/dashboard";

describe("GuidanceDialog", () => {
  it("hides guidance answer submission outside local operator mode", () => {
    const item: GuidanceItem = {
      source: "guidance",
      id: "gr-read-only",
      repo: "symphony-plus-plus",
      repoKey: "symphony-plus-plus",
      title: "Pick a path",
      packageId: "wp-guidance",
      detail: "Choose one direction.",
      prompt: null,
      guidance: {
        id: "gr-read-only",
        work_package_id: "wp-guidance",
        repo: "symphony-plus-plus",
        repo_key: "symphony-plus-plus",
      },
    };
    const content = (canSubmitAnswer: boolean) => (
      <Dialog open>
        <GuidanceDialogBody canSubmitAnswer={canSubmitAnswer} item={item} onOpenChange={() => undefined} onSubmitAnswer={async () => undefined} />
      </Dialog>
    );

    expect(renderToStaticMarkup(content(false))).not.toContain(">Answer<");
    expect(renderToStaticMarkup(content(true))).toContain(">Answer<");
  });
});
