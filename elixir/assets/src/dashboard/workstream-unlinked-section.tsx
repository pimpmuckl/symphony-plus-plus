import type { WorkPackageCard } from "@/types/dashboard";
import { GitBranch, Package } from "lucide-react";
import { AnimatedBadge } from "@/components/dashboard/motion";
import { operationalBadgeVariant, operationalLabel } from "@/lib/operational-state";
import type { CardDetailSelect, DashboardUpdateAnimations } from "./runtime";
import { packageUpdateKey } from "./update-animations";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";

export function UnlinkedExecutionSection({
  packages,
  onSelectCard,
  updateAnimations,
}: {
  packages: WorkPackageCard[];
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  return (
    <section className="v3-unlinked-execution-section">
      <div className="v3-unlinked-execution-header">
        <span><Package className="size-4" />Execution records</span>
        <span>{packages.length}</span>
      </div>
      <div className="v3-unlinked-execution-list">
        {packages.map((pkg) => (
          <UnlinkedPackageRow key={pkg.id} pkg={pkg} onSelectCard={onSelectCard} updateAnimations={updateAnimations} />
        ))}
      </div>
    </section>
  );
}

function UnlinkedPackageRow({
  pkg,
  onSelectCard,
  updateAnimations,
}: {
  pkg: WorkPackageCard;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const operational = pkg.operational_state || null;

  return (
    <button
      type="button"
      className="v3-unlinked-package-row stagger-item"
      onClick={() => onSelectCard({ kind: "package", pkg })}
      {...updateMotionAttributes(updateAnimations.motionFor(packageUpdateKey(pkg)))}
    >
      <span className="v3-unlinked-package-title-group">
        <span className="v3-unlinked-package-title">
          <Package className="size-4" />
          <span>{pkg.title || pkg.id}</span>
        </span>
        <span className="v3-request-meta">
          <GitBranch className="size-3.5" />
          <span>{pkg.repo_display || pkg.repo || "repo"}</span>
          <span>{pkg.base_branch || "main"}</span>
        </span>
      </span>
      <AnimatedBadge label={operationalLabel(operational, pkg.status)} variant={operationalBadgeVariant(operational, pkg.status)} />
    </button>
  );
}
