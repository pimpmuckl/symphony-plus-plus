import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { MarkdownBlock, safeMarkdownUrl } from "./markdown-block";

describe("MarkdownBlock", () => {
  it("renders common Markdown as React elements", () => {
    const html = renderToStaticMarkup(<MarkdownBlock value={"# Decision\n\n- **Keep** `scope`\n\n[docs](https://example.test/docs)"} />);

    expect(html).toContain("<h4>Decision</h4>");
    expect(html).toContain("<strong>Keep</strong>");
    expect(html).toContain("<code>scope</code>");
    expect(html).toContain('href="https://example.test/docs"');
  });

  it("does not emit raw HTML or unsafe link protocols", () => {
    const html = renderToStaticMarkup(
      <MarkdownBlock
        value={
          "<repo-root>\n\n<script>alert('x')</script>\n\n[run](javascript:alert('x'))\n\n[asset](data:text/html;base64,abc)\n\n![pixel](https://attacker.test/pixel.png)"
        }
      />,
    );

    expect(html).not.toContain("<script");
    expect(html).not.toContain("<img");
    expect(html).toContain("&lt;repo-root&gt;");
    expect(html).not.toContain("javascript:");
    expect(html).not.toContain("data:text/html");
    expect(html).not.toContain("attacker.test");
  });

  it("preserves angle brackets inside Markdown code", () => {
    const html = renderToStaticMarkup(
      <MarkdownBlock value={"Use `<repo-root>`.\n\n```xml\n<node />\n```\n\n~~~xml\n<tilde />\n~~~\n\nprefix ```<img src=x>``` suffix"} />,
    );

    expect(html).toContain("<code>&lt;repo-root&gt;</code>");
    expect(html).toContain("&lt;node /&gt;");
    expect(html).toContain("&lt;tilde /&gt;");
    expect(html).toContain("<code>&lt;img src=x&gt;</code>");
    expect(html).not.toContain("&amp;lt;");
  });

  it("keeps standard Markdown autolinks clickable without trusting raw HTML", () => {
    const html = renderToStaticMarkup(
      <MarkdownBlock value={"See <https://example.test/My%20Doc> and <user@example.test>.\n\n<span>raw html</span>"} />,
    );

    expect(html).toContain('href="https://example.test/My%20Doc"');
    expect(html).toContain('href="mailto:user@example.test"');
    expect(html).not.toContain("<span>raw html</span>");
    expect(html).toContain("&lt;span&gt;raw html&lt;/span&gt;");
  });

  it("rejects obfuscated unsafe link protocols", () => {
    expect(safeMarkdownUrl("java\nscript:alert(1)")).toBe("");
    expect(safeMarkdownUrl("java%0ascript:alert(1)")).toBe("");
    expect(safeMarkdownUrl("https://example.test/My%20Doc")).toBe("https://example.test/My%20Doc");
    expect(safeMarkdownUrl("https://example.test/docs")).toBe("https://example.test/docs");
    expect(safeMarkdownUrl("/relative/path")).toBe("/relative/path");
  });
});
