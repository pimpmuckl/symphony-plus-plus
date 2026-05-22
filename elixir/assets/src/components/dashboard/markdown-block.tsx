type MarkdownNode =
  | { key: string; type: "heading"; depth: number; text: string }
  | { key: string; type: "paragraph"; text: string }
  | { key: string; type: "list"; ordered: boolean; items: MarkdownListItem[] }
  | { key: string; type: "code"; text: string };

type MarkdownListItem = {
  key: string;
  text: string;
};

type MarkdownInlineNode =
  | { key: string; type: "code"; text: string }
  | { key: string; type: "strong"; text: string }
  | { key: string; type: "text"; text: string };

export function MarkdownBlock({ value }: { value?: string | null }) {
  const nodes = markdownNodes(value);

  if (nodes.length === 0) {
    return <p className="solo-markdown-empty">No details recorded.</p>;
  }

  return (
    <div className="solo-markdown">
      {nodes.map((node) => (
        <MarkdownNodeView key={node.key} node={node} />
      ))}
    </div>
  );
}

function MarkdownNodeView({ node }: { node: MarkdownNode }) {
  if (node.type === "heading") {
    if (node.depth === 1) return <h4><MarkdownInline text={node.text} /></h4>;
    if (node.depth === 2) return <h5><MarkdownInline text={node.text} /></h5>;
    return <h6><MarkdownInline text={node.text} /></h6>;
  }

  if (node.type === "list") {
    const List = node.ordered ? "ol" : "ul";
    return (
      <List>
        {node.items.map((item) => (
          <li key={item.key}><MarkdownInline text={item.text} /></li>
        ))}
      </List>
    );
  }

  if (node.type === "code") {
    return <pre>{node.text}</pre>;
  }

  return <p><MarkdownInline text={node.text} /></p>;
}

function MarkdownInline({ text }: { text: string }) {
  return markdownInlineNodes(text).map((part) => {
    if (part.type === "code") return <code key={part.key}>{part.text}</code>;
    if (part.type === "strong") return <strong key={part.key}>{part.text}</strong>;
    return <span key={part.key}>{part.text}</span>;
  });
}

function markdownInlineNodes(text: string): MarkdownInlineNode[] {
  const nodes: MarkdownInlineNode[] = [];
  const pattern = /(`[^`]+`|\*\*[^*]+\*\*)/g;
  let offset = 0;

  for (const match of text.matchAll(pattern)) {
    const index = match.index ?? 0;
    if (index > offset) {
      nodes.push(markdownInlineNode("text", text.slice(offset, index), offset));
    }

    const token = match[0];
    if (token.startsWith("`") && token.endsWith("`")) {
      nodes.push(markdownInlineNode("code", token.slice(1, -1), index));
    } else {
      nodes.push(markdownInlineNode("strong", token.slice(2, -2), index));
    }
    offset = index + token.length;
  }

  if (offset < text.length) {
    nodes.push(markdownInlineNode("text", text.slice(offset), offset));
  }

  return nodes;
}

function markdownInlineNode(type: MarkdownInlineNode["type"], text: string, offset: number): MarkdownInlineNode {
  return { key: `${type}:${offset}`, type, text } as MarkdownInlineNode;
}

function markdownNodes(value?: string | null): MarkdownNode[] {
  if (!value?.trim()) return [];

  const nodes: MarkdownNode[] = [];
  const lines = value.replace(/\r\n/g, "\n").split("\n");
  let paragraph: string[] = [];
  let list: { ordered: boolean; items: MarkdownListItem[] } | null = null;
  let code: string[] | null = null;

  const flushParagraph = () => {
    if (paragraph.length > 0) {
      const text = paragraph.join(" ").trim();
      nodes.push({ key: markdownNodeKey("paragraph", nodes.length), type: "paragraph", text });
      paragraph = [];
    }
  };

  const flushList = () => {
    if (list) {
      nodes.push({ key: markdownNodeKey("list", nodes.length), type: "list", ordered: list.ordered, items: list.items });
      list = null;
    }
  };

  for (const [lineNumber, line] of lines.entries()) {
    if (line.trim().startsWith("```")) {
      if (code) {
        const text = code.join("\n").trimEnd();
        nodes.push({ key: markdownNodeKey("code", nodes.length), type: "code", text });
        code = null;
      } else {
        flushParagraph();
        flushList();
        code = [];
      }
      continue;
    }

    if (code) {
      code.push(line);
      continue;
    }

    if (line.trim() === "") {
      flushParagraph();
      flushList();
      continue;
    }

    const heading = line.match(/^(#{1,3})\s+(.+)$/);
    if (heading) {
      flushParagraph();
      flushList();
      const text = heading[2].trim();
      nodes.push({ key: markdownNodeKey("heading", nodes.length), type: "heading", depth: heading[1].length, text });
      continue;
    }

    const bullet = line.match(/^\s*[-*]\s+(.+)$/);
    const ordered = line.match(/^\s*\d+[.)]\s+(.+)$/);
    if (bullet || ordered) {
      flushParagraph();
      const orderedList = Boolean(ordered);
      if (!list || list.ordered !== orderedList) {
        flushList();
        list = { ordered: orderedList, items: [] };
      }
      const text = (bullet?.[1] || ordered?.[1] || "").trim();
      list.items.push({ key: `item:${lineNumber}`, text });
      continue;
    }

    flushList();
    paragraph.push(line.trim());
  }

  flushParagraph();
  flushList();
  if (code) {
    const text = code.join("\n").trimEnd();
    nodes.push({ key: markdownNodeKey("code", nodes.length), type: "code", text });
  }

  return nodes;
}

function markdownNodeKey(type: MarkdownNode["type"], ordinal: number) {
  return `${type}:${ordinal}`;
}
