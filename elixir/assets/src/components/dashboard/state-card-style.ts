export type SignalTone = "muted" | "info" | "warning" | "danger" | "success";
export type StateCardTone = "request" | "queued" | "ready" | "slice" | "implementing" | "review" | "merge" | "guidance" | "blocked" | "finished" | "muted";

type StateToneStyle = {
  card: string;
  accent: string;
};

export const STATE_CARD_TONES: Record<StateCardTone, StateToneStyle> = {
  request: { card: "border-slate-200 bg-slate-50/80 dark:border-slate-700/80 dark:bg-slate-900/70", accent: "rgb(203 213 225)" },
  queued: { card: "border-teal-200/80 bg-teal-50/80 dark:border-teal-700/70 dark:bg-teal-950/45", accent: "rgb(45 212 191)" },
  ready: { card: "border-lime-200/80 bg-lime-50/80 dark:border-lime-700/70 dark:bg-lime-950/45", accent: "rgb(163 230 53)" },
  slice: { card: "border-cyan-200/80 bg-cyan-50/80 dark:border-cyan-700/70 dark:bg-cyan-950/45", accent: "rgb(34 211 238)" },
  implementing: { card: "border-sky-200/80 bg-sky-50/80 dark:border-sky-700/70 dark:bg-sky-950/45", accent: "rgb(56 189 248)" },
  review: { card: "border-indigo-200/80 bg-indigo-50/80 dark:border-indigo-700/70 dark:bg-indigo-950/45", accent: "rgb(129 140 248)" },
  merge: { card: "border-lime-200/80 bg-lime-50/80 dark:border-lime-700/70 dark:bg-lime-950/45", accent: "rgb(163 230 53)" },
  guidance: { card: "border-violet-200/80 bg-violet-50/80 dark:border-violet-700/70 dark:bg-violet-950/45", accent: "rgb(167 139 250)" },
  blocked: { card: "border-rose-200/80 bg-rose-50/80 dark:border-rose-700/70 dark:bg-rose-950/45", accent: "rgb(251 113 133)" },
  finished: { card: "border-emerald-200/80 bg-emerald-50/80 dark:border-emerald-700/70 dark:bg-emerald-950/45", accent: "rgb(52 211 153)" },
  muted: { card: "border-zinc-200/80 bg-zinc-50/80 dark:border-zinc-700/80 dark:bg-zinc-900/70", accent: "rgb(212 212 216)" },
};

export const CARD_SIGNAL_TONE_CLASSES: Record<SignalTone, string> = {
  muted: "border-transparent bg-muted text-foreground",
  info: "border-sky-200 bg-sky-50 text-sky-800 dark:border-sky-700/70 dark:bg-sky-950/50 dark:text-sky-200",
  warning: "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-700/70 dark:bg-amber-950/50 dark:text-amber-200",
  danger: "border-rose-200 bg-rose-50 text-rose-800 dark:border-rose-700/70 dark:bg-rose-950/50 dark:text-rose-200",
  success: "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-700/70 dark:bg-emerald-950/50 dark:text-emerald-200",
};
