export function contextPathValue(path: string[]) {
  const parts: string[] = [];

  for (const part of path) {
    const trimmed = part.trim();
    if (trimmed) parts.push(trimmed);
  }

  return JSON.stringify(parts);
}
