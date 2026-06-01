export function firstParagraph(value?: string | null) {
  return value?.split(/\n\s*\n/)[0]?.trim() || "";
}
