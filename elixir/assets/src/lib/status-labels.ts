export function formatStatus(status?: string | null) {
  return status ? status.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase()) : "Unknown";
}

export function statusLabel(status?: string | null) {
  if (status === "active") return "Active";
  if (status === "merge_ready") return "Ready For Merge";
  if (status === "in_progress") return "Active";
  if (status === "needs_attention") return "Needs Attention";
  if (status === "started_paused") return "Started / Paused";
  if (status === "merging") return "Merging";
  if (status === "ready_for_human_merge" || status === "ready_for_architect_merge") return "Merge Ready";
  if (status === "merging_into_phase") return "Merging";
  if (status === "ci_waiting") return "CI Waiting";
  return formatStatus(status);
}
