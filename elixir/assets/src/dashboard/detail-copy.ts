import type { DecisionOption, GuidanceItem, WorkPackageCard, WorkPackageDetailPayload } from "@/types/dashboard";

type WorkPackageBlocker = NonNullable<WorkPackageDetailPayload["blockers"]>[number];

export function guidanceCopyText(item: GuidanceItem, options: DecisionOption[]) {
  const details = item.prompt?.details || item.detail;
  const target = item.source === "guidance" ? `Work Package: ${item.packageId}` : `Work Request: ${item.workRequestId}`;

  return [
    line("Guidance", item.prompt?.tl_dr || item.title),
    line("Repository", item.repo),
    target,
    section("Details", details),
    section("Options", decisionOptionsCopyText(options)),
  ]
    .filter(Boolean)
    .join("\n\n");
}

export function packageBlockerCopyText({
  blockerCount,
  blockers,
  operationalTruth,
  pkg,
  repo,
  state,
}: {
  blockerCount: number;
  blockers: WorkPackageBlocker[];
  operationalTruth: string;
  pkg: WorkPackageCard;
  repo: string;
  state: string;
}) {
  return [
    line("Blockers", pkg.title || pkg.id),
    line("Repository", repo),
    line("Work Package", pkg.id),
    line("State", state),
    line("Active blockers", String(blockerCount)),
    section("Operational Truth", operationalTruth),
    section("Blocked By", blockers.length > 0 ? blockers.map(blockerCopyText).join("\n\n") : "No blocker detail was included in the board summary."),
  ].join("\n\n");
}

function decisionOptionsCopyText(options: DecisionOption[]) {
  return options
    .filter((option) => option.id)
    .map((option, index) =>
      [
        `${index + 1}. ${option.label || option.id}`,
        option.description ? `Description: ${option.description}` : "",
        option.answer ? `Answer: ${option.answer}` : "",
        option.pros?.length ? `Pros: ${option.pros.join("; ")}` : "",
        option.cons?.length ? `Cons: ${option.cons.join("; ")}` : "",
      ]
        .filter(Boolean)
        .join("\n"),
    )
    .join("\n\n");
}

function blockerCopyText(blocker: WorkPackageBlocker, index: number) {
  return [
    `${index + 1}. ${blocker.summary || blocker.status || blocker.id || "Blocker"}`,
    blocker.body ? section("Body", blocker.body) : "",
    blocker.resolution ? section("Resolution", blocker.resolution) : "",
    blocker.updated_at ? line("Updated", blocker.updated_at) : "",
  ]
    .filter(Boolean)
    .join("\n");
}

function line(label: string, value?: string | null) {
  const text = value?.trim();
  return text ? `${label}: ${text}` : "";
}

function section(label: string, value?: string | null) {
  const text = value?.trim();
  return text ? `${label}\n${text}` : "";
}
