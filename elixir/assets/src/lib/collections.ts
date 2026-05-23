export function sortedCopy<T>(values: readonly T[], compare: (left: T, right: T) => number) {
  return [...values].sort(compare);
}

export function uniqueNonEmpty(values: Array<string | undefined | null>) {
  const unique = new Set<string>();
  values.forEach((value) => {
    const trimmed = value?.trim();
    if (trimmed) unique.add(trimmed);
  });
  return [...unique];
}
