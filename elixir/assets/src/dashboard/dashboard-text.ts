export function firstParagraph(value?: string | null) {
  return stripMarkdown(value?.split(/\n\s*\n/)[0]?.trim() || "");
}

export function stripMarkdown(value?: string | null) {
  return (value || "")
    .replace(/```[\s\S]*?```/g, "")
    .replace(/^>\s?/gm, "")
    .replace(/^\s*[-*_]{3,}\s*$/gm, "")
    .replace(/^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/gm, "")
    .replace(/^\s*\|(.+)\|\s*$/gm, (_match, row: string) => row.replace(/\|/g, " "))
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/~~([^~]+)~~/g, "$1")
    .replace(/(\*\*\*|___)(.+?)\1/g, "$2")
    .replace(/(\*\*|__)(.+?)\1/g, "$2")
    .replace(/(^|[\s([{])\*([^*\s][^*]*?)\*(?=$|[\s)\]},.!?:;])/g, "$1$2")
    .replace(/(^|[\s([{])_([^_\s][^_]*?)_(?=$|[\s)\]},.!?:;])/g, "$1$2")
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/^\s*[-*+]\s+/gm, "")
    .replace(/^\s*\d+[.)]\s+/gm, "")
    .replace(/\s+/g, " ")
    .trim();
}
