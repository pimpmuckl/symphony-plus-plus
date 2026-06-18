import type { TopPanelKey } from "./runtime";
import { TopPanelCarousel } from "./top-panel-carousel";
import type { TopPanelContentProps } from "./status-rail-types";

export function StatusRail({
  openPanel,
  guidanceItems,
  blockerItems,
  onSelectGuidance,
  onSelectCard,
  updateAnimations,
}: Omit<TopPanelContentProps, "panel" | "interactive"> & {
  openPanel: TopPanelKey | null;
}) {
  const panelContentProps = {
    blockerItems,
    guidanceItems,
    onSelectCard,
    onSelectGuidance,
    updateAnimations,
  };

  return (
    <section className="dashboard-top-panel-anchor top-panel-inline" data-open-panel={openPanel ?? "none"}>
      <TopPanelCarousel activePanel={openPanel} {...panelContentProps} />
    </section>
  );
}
