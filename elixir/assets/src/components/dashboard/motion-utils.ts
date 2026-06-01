import type { MutableRefObject } from "react";

import type { UpdateMotion } from "@/components/dashboard/motion";

export function updateMotionAttributes(motion?: UpdateMotion) {
  if (motion?.kind === "settled") return { "data-update-settled": "true" };
  return motion ? { "data-update-kind": motion.kind, "data-update-token": motion.token } : {};
}

export function measureElementHeight(element: HTMLElement | null) {
  return element?.getBoundingClientRect().height || 0;
}

export function nextFrame(refs: MutableRefObject<number[]>, callback: () => void) {
  const id = window.requestAnimationFrame(callback);
  refs.current.push(id);
}

export function later(refs: MutableRefObject<number[]>, delay: number, callback: () => void) {
  const id = window.setTimeout(callback, delay);
  refs.current.push(id);
}

export function clearMotionTimers(timersRef: MutableRefObject<number[]>, framesRef: MutableRefObject<number[]>) {
  timersRef.current.forEach((id) => window.clearTimeout(id));
  framesRef.current.forEach((id) => window.cancelAnimationFrame(id));
  timersRef.current = [];
  framesRef.current = [];
}

export function dashboardPrefersReducedMotion() {
  return typeof window !== "undefined" && typeof window.matchMedia === "function" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}
