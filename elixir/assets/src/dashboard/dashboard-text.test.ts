import { describe, expect, it } from "vitest";

import { firstParagraph, stripMarkdown } from "./dashboard-text";

describe("dashboard text helpers", () => {
  it("strips common Markdown markers for compact previews", () => {
    const preview = stripMarkdown(
      [
        "# Heading",
        "> *Italic* and _emphasis_ with ~~struck~~ text.",
        "Keep KRAKEN_BATCH_SERVICE_MAX_JOBS and work_package_id intact.",
        "| State | Note |",
        "| --- | --- |",
        "| **Done** | [docs](https://example.test) and `code` |",
      ].join("\n"),
    );

    expect(preview).toBe(
      "Heading Italic and emphasis with struck text. Keep KRAKEN_BATCH_SERVICE_MAX_JOBS and work_package_id intact. State Note Done docs and code",
    );
  });

  it("uses the first Markdown paragraph as plain text", () => {
    expect(firstParagraph("## Summary\n\nSecond paragraph")).toBe("Summary");
  });
});
