export function sortedCopy<T>(values: readonly T[], compare: (left: T, right: T) => number) {
  return [...values].sort(compare);
}
