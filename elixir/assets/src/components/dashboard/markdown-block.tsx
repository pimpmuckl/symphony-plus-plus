import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";

import { cn } from "@/lib/utils";

const markdownComponents: Components = {
  h1({ children }) {
    return <h4>{children}</h4>;
  },
  h2({ children }) {
    return <h5>{children}</h5>;
  },
  h3({ children }) {
    return <h6>{children}</h6>;
  },
  h4({ children }) {
    return <h6>{children}</h6>;
  },
  h5({ children }) {
    return <h6>{children}</h6>;
  },
  h6({ children }) {
    return <h6>{children}</h6>;
  },
  a({ children, href }) {
    if (!href) return <span>{children}</span>;

    return (
      <a href={href} rel="noreferrer" target="_blank">
        {children}
      </a>
    );
  },
  img({ alt }) {
    return alt ? <span>{alt}</span> : null;
  },
};

export function MarkdownBlock({
  className,
  empty = "No details recorded.",
  value,
}: {
  className?: string;
  empty?: string;
  value?: string | null;
}) {
  const markdown = escapeRawHtml(value?.trim() || "");

  if (!markdown) {
    return <p className={cn("solo-markdown-empty", className)}>{empty}</p>;
  }

  return (
    <div className={cn("solo-markdown", className)}>
      <ReactMarkdown components={markdownComponents} remarkPlugins={[remarkGfm]} skipHtml urlTransform={safeMarkdownUrl}>
        {markdown}
      </ReactMarkdown>
    </div>
  );
}

export function safeMarkdownUrl(url: string) {
  const value = url.trim();
  if (!value || value.startsWith("//")) return "";
  if (hasUnsafeUrlControl(value) || /%(?:0[0-9a-f]|1[0-9a-f]|7f)/i.test(value)) return "";

  const protocolMatch = value.match(/^[A-Za-z][A-Za-z\d+.-]*:/);
  if (!protocolMatch) return value;

  return ["http:", "https:", "mailto:"].includes(protocolMatch[0].toLowerCase()) ? value : "";
}

function hasUnsafeUrlControl(value: string) {
  return Array.from(value).some((char) => {
    const code = char.charCodeAt(0);
    return code <= 32 || code === 127;
  });
}

function escapeRawHtml(value: string) {
  let fence: { char: "`" | "~"; length: number } | null = null;

  return value
    .split("\n")
    .map((line) => {
      const fenceMatch = line.match(/^\s{0,3}(`{3,}|~{3,})/);
      if (fenceMatch) {
        const marker = fenceMatch[1];
        const char = marker[0] as "`" | "~";
        if (!fence) {
          fence = { char, length: marker.length };
        } else if (fence.char === char && marker.length >= fence.length) {
          fence = null;
        }
        return line;
      }

      if (fence) return line;

      return escapeRawHtmlOutsideInlineCode(line);
    })
    .join("\n")
    .trim();
}

function escapeRawHtmlOutsideInlineCode(value: string) {
  const parts: string[] = [];
  const codeSpan = /(`+)([^`\n]*?)\1/g;
  let offset = 0;

  for (const match of value.matchAll(codeSpan)) {
    const index = match.index ?? 0;
    parts.push(escapeAngleBrackets(value.slice(offset, index)), match[0]);
    offset = index + match[0].length;
  }

  parts.push(escapeAngleBrackets(value.slice(offset)));
  return parts.join("");
}

function escapeAngleBrackets(value: string) {
  const parts: string[] = [];
  const angleSpan = /<([^<>\s]+)>/g;
  let offset = 0;

  for (const match of value.matchAll(angleSpan)) {
    const index = match.index ?? 0;
    parts.push(escapeLooseAngleBrackets(value.slice(offset, index)));
    parts.push(isMarkdownAutolinkCandidate(match[1]) ? match[0] : escapeLooseAngleBrackets(match[0]));
    offset = index + match[0].length;
  }

  parts.push(escapeLooseAngleBrackets(value.slice(offset)));
  return parts.join("");
}

function isMarkdownAutolinkCandidate(value: string) {
  return /^[A-Za-z][A-Za-z\d+.-]{1,31}:[^\s<>]*$/.test(value) || /^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(value);
}

function escapeLooseAngleBrackets(value: string) {
  return value.replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
