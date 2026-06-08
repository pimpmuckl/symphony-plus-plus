export type ContextPathPart = {
  id: string;
  label: string;
};

export function contextPathValue(path: ContextPathPart[]) {
  const parts: ContextPathPart[] = [];

  for (const part of path) {
    const id = part.id.trim();
    const label = part.label.trim();
    if (id && label) parts.push({ id, label });
  }

  return JSON.stringify(parts);
}
