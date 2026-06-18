export type SignalTone = "muted" | "info" | "warning" | "danger" | "success";
export type StateCardTone = "request" | "queued" | "ready" | "slice" | "implementing" | "review" | "merge" | "guidance" | "blocked" | "finished" | "muted";

type StateToneStyle = {
  accent: string;
  card: string;
};

export const STATE_CARD_TONES: Record<StateCardTone, StateToneStyle> = {
  request: { accent: "rgb(203 213 225)", card: "border-slate-200 bg-slate-50/80 dark:border-slate-700/80 dark:bg-slate-900/70" },
  queued: { accent: "rgb(45 212 191)", card: "border-teal-200/80 bg-teal-50/80 dark:border-teal-700/70 dark:bg-teal-950/45" },
  ready: { accent: "rgb(163 230 53)", card: "border-lime-200/80 bg-lime-50/80 dark:border-lime-700/70 dark:bg-lime-950/45" },
  slice: { accent: "rgb(34 211 238)", card: "border-cyan-200/80 bg-cyan-50/80 dark:border-cyan-700/70 dark:bg-cyan-950/45" },
  implementing: { accent: "rgb(56 189 248)", card: "border-sky-200/80 bg-sky-50/80 dark:border-sky-700/70 dark:bg-sky-950/45" },
  review: { accent: "rgb(129 140 248)", card: "border-indigo-200/80 bg-indigo-50/80 dark:border-indigo-700/70 dark:bg-indigo-950/45" },
  merge: { accent: "rgb(163 230 53)", card: "border-lime-200/80 bg-lime-50/80 dark:border-lime-700/70 dark:bg-lime-950/45" },
  guidance: { accent: "rgb(167 139 250)", card: "border-violet-200/80 bg-violet-50/80 dark:border-violet-700/70 dark:bg-violet-950/45" },
  blocked: { accent: "rgb(251 113 133)", card: "border-rose-200/80 bg-rose-50/80 dark:border-rose-700/70 dark:bg-rose-950/45" },
  finished: { accent: "rgb(52 211 153)", card: "border-emerald-200/80 bg-emerald-50/80 dark:border-emerald-700/70 dark:bg-emerald-950/45" },
  muted: { accent: "rgb(212 212 216)", card: "border-zinc-200/80 bg-zinc-50/80 dark:border-zinc-700/80 dark:bg-zinc-900/70" },
};

export const CARD_SIGNAL_TONE_CLASSES: Record<SignalTone, string> = {
  muted: "border-transparent bg-muted text-foreground",
  info: "border-sky-200 bg-sky-50 text-sky-800 dark:border-sky-700/70 dark:bg-sky-950/50 dark:text-sky-200",
  warning: "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-700/70 dark:bg-amber-950/50 dark:text-amber-200",
  danger: "border-rose-200 bg-rose-50 text-rose-800 dark:border-rose-700/70 dark:bg-rose-950/50 dark:text-rose-200",
  success: "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-700/70 dark:bg-emerald-950/50 dark:text-emerald-200",
};
