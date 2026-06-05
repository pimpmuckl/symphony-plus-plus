import type { ActiveBlockingEdge, CopyArchitectHandoff, GuidanceItem, PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { ProductTreeCompletionMark, ProductTreeNode } from "@/types/product-tree";
import { AlertTriangle, CheckCircle2, ChevronRight, Circle, CircleDashed, ClipboardCopy, GitBranch, Info, Layers3, MessageSquareText, Package, Split } from "lucide-react";
import type { CSSProperties } from "react";
import { AnimatedBadge } from "@/components/dashboard/motion";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { operationalBadgeVariant, operationalLabel, sliceOperationalState } from "@/lib/operational-state";
import { useCallback, useMemo, useState } from "react";
import { CardDetailSelect, DashboardUpdateAnimations } from "./runtime";
import { SequenceBadge } from "./workstream-cards";
import { architectHandoffEligibleRequest } from "@/lib/operational-state";
import { clarificationGuidanceItem } from "./dashboard-data";
import { firstParagraph, stripMarkdown } from "./dashboard-text";
import { finishedRequestChildrenStorageKey, sortPackages, sortPlannedSlices, sortWorkRequestDetails } from "./workstream-data";
import { activeBlockerCounts, productTreeCounts, requestProgress, rootProductSliceIds } from "./workstream-progress";
import { packageUpdateKey, requestUpdateKey, sliceUpdateKey } from "./update-animations";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";

type TreeIndex = {
  childrenByParent: Map<string, ProductTreeNode[]>;
  rootNodes: ProductTreeNode[];
};

export function WorkstreamBoard({
  repoDetails,
  packages,
  unlinkedPackages,
  activeBlockingEdges,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  expandedFinishedRequests,
  finishedRequestScopeKey,
  onSetFinishedRequestChildrenOpen,
  updateAnimations,
}: {
  repoDetails: WorkRequestDetail[];
  packages: WorkPackageCard[];
  unlinkedPackages: WorkPackageCard[];
  activeBlockingEdges: ActiveBlockingEdge[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  expandedFinishedRequests: Record<string, boolean>;
  finishedRequestScopeKey: string;
  onSetFinishedRequestChildrenOpen: (workRequestId: string, open: boolean) => void;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const sortedDetails = useMemo(() => sortWorkRequestDetails(repoDetails), [repoDetails]);
  const sortedUnlinkedPackages = useMemo(() => sortPackages(unlinkedPackages), [unlinkedPackages]);
  const packageById = useMemo(() => new Map(packages.map((pkg) => [pkg.id, pkg])), [packages]);
  const blockerCountByRequestId = useMemo(() => activeBlockerCounts(activeBlockingEdges, repoDetails), [activeBlockingEdges, repoDetails]);

  return (
    <div className="workstream-board-shell">
      <div className="v3-workstream-board">
        {sortedDetails.map((detail, index) => {
          const stateKey = finishedRequestChildrenStorageKey(finishedRequestScopeKey, detail.work_request.id);
          const expanded = expandedFinishedRequests[stateKey] === true;

          return (
            <ProductRequestRow
              key={detail.work_request.id}
              detail={detail}
              packageById={packageById}
              activeBlockerCount={blockerCountByRequestId.get(detail.work_request.id) ?? 0}
              expanded={expanded}
              index={index}
              onToggle={() => onSetFinishedRequestChildrenOpen(detail.work_request.id, !expanded)}
              onSelectGuidance={onSelectGuidance}
              onSelectCard={onSelectCard}
              onCopyArchitectHandoff={onCopyArchitectHandoff}
              updateAnimations={updateAnimations}
            />
          );
        })}
        {sortedUnlinkedPackages.length > 0 ? (
          <UnlinkedExecutionSection packages={sortedUnlinkedPackages} onSelectCard={onSelectCard} updateAnimations={updateAnimations} />
        ) : null}
      </div>
    </div>
  );
}

function ProductRequestRow({
  detail,
  packageById,
  activeBlockerCount,
  expanded,
  index,
  onToggle,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  updateAnimations,
}: {
  detail: WorkRequestDetail;
  packageById: Map<string, WorkPackageCard>;
  activeBlockerCount: number;
  expanded: boolean;
  index: number;
  onToggle: () => void;
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const request = detail.work_request;
  const slices = sortPlannedSlices(detail.planned_slices ?? []);
  const progress = requestProgress(detail, packageById);
  const openQuestion = detail.clarification_questions?.find((question) => question.status === "open");

  return (
    <section
      className="v3-request-row stagger-item"
      data-expanded={expanded ? "true" : "false"}
      style={{ animationDelay: `${index * 30}ms` }}
      {...updateMotionAttributes(updateAnimations.motionFor(requestUpdateKey(detail)))}
    >
      <div className="v3-request-header">
        <button type="button" className="v3-request-main" aria-expanded={expanded} onClick={onToggle}>
          <span className="v3-request-chevron">
            <ChevronRight className={cn("size-4 transition-transform duration-200", expanded && "rotate-90")} />
          </span>
          <span className="v3-request-title-group">
            <span className="v3-request-title">{request.title || request.id}</span>
            <span className="v3-request-meta">
              <GitBranch className="size-3.5" />
              <span>{request.repo_display || request.repo || "repo"}</span>
              <span>{request.base_branch || "main"}</span>
            </span>
          </span>
        </button>
        <div className="v3-request-row-controls">
          <RequestHeaderActions detail={detail} onSelectCard={onSelectCard} onCopyArchitectHandoff={onCopyArchitectHandoff} />
          <RequestProgressSummary detail={detail} activeBlockerCount={activeBlockerCount} />
          <span className="v3-request-status">
            <ProgressPill progress={progress} />
            <AnimatedBadge label={operationalLabel(request.operational_state, request.status)} variant={operationalBadgeVariant(request.operational_state, request.status)} />
          </span>
        </div>
      </div>
      {expanded ? (
        <div className="v3-request-body">
          <RequestActions
            detail={detail}
            openQuestion={openQuestion}
            onSelectGuidance={onSelectGuidance}
          />
          <ProductPlanBody detail={detail} packageById={packageById} slices={slices} onSelectCard={onSelectCard} updateAnimations={updateAnimations} />
        </div>
      ) : null}
    </section>
  );
}

function RequestProgressSummary({ detail, activeBlockerCount }: { detail: WorkRequestDetail; activeBlockerCount: number }) {
  const counts = productTreeCounts(detail, activeBlockerCount);

  return (
    <span className="v3-request-summary">
      {counts.nodeCount > 0 ? <span aria-label={`${counts.nodeCount} plan nodes`} title="Plan nodes"><Layers3 className="size-3.5" />{counts.nodeCount}</span> : null}
      <span aria-label={`${counts.sliceCount} slices`} title="Slices"><Split className="size-3.5" />{counts.sliceCount}</span>
      {counts.guidanceCount > 0 ? <span className="v3-guidance-chip" aria-label={`${counts.guidanceCount} guidance needed`} title="Guidance needed"><MessageSquareText className="size-3.5" />{counts.guidanceCount}</span> : null}
      {counts.blockerCount > 0 ? <span className="v3-blocker-chip" aria-label={`${counts.blockerCount} active blockers`} title="Active blockers"><AlertTriangle className="size-3.5" />{counts.blockerCount}</span> : null}
    </span>
  );
}

function RequestHeaderActions({
  detail,
  onSelectCard,
  onCopyArchitectHandoff,
}: {
  detail: WorkRequestDetail;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
}) {
  const [copying, setCopying] = useState(false);
  const request = detail.work_request;
  const canCopyHandoff = architectHandoffEligibleRequest(request);
  const copyHandoff = useCallback(async () => {
    setCopying(true);
    try {
      await onCopyArchitectHandoff(request.id);
    } finally {
      setCopying(false);
    }
  }, [onCopyArchitectHandoff, request.id]);

  return (
    <div className="v3-request-header-actions">
      <Button
        type="button"
        variant="secondary"
        size="icon"
        className="v3-request-action-button"
        aria-label="Open request details"
        title="Request details"
        onClick={() => onSelectCard({ kind: "request", detail })}
      >
        <Info className="size-4" />
      </Button>
      {canCopyHandoff ? (
        <Button
          type="button"
          variant="outline"
          size="icon"
          className="v3-request-action-button"
          aria-label={copying ? "Copying architect handoff" : "Copy architect handoff"}
          title={copying ? "Copying architect handoff" : "Architect handoff"}
          onClick={copyHandoff}
          disabled={copying}
        >
          <ClipboardCopy className="size-4" />
        </Button>
      ) : null}
    </div>
  );
}

function RequestActions({
  detail,
  openQuestion,
  onSelectGuidance,
}: {
  detail: WorkRequestDetail;
  openQuestion?: NonNullable<WorkRequestDetail["clarification_questions"]>[number];
  onSelectGuidance: (item: GuidanceItem) => void;
}) {
  if (!openQuestion) return null;

  return (
    <div className="v3-request-actions">
      <Button type="button" variant="outline" size="sm" onClick={() => onSelectGuidance(clarificationGuidanceItem(detail, openQuestion))}>
        <AlertTriangle className="size-4" />
        <span>Open Question</span>
      </Button>
    </div>
  );
}

function ProductPlanBody({
  detail,
  packageById,
  slices,
  onSelectCard,
  updateAnimations,
}: {
  detail: WorkRequestDetail;
  packageById: Map<string, WorkPackageCard>;
  slices: PlannedSlice[];
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const treeIndex = useMemo(() => buildTreeIndex(detail.product_tree?.nodes ?? [], detail.product_tree?.root_node_ids ?? []), [detail.product_tree]);
  const slicesById = useMemo(() => new Map(slices.map((slice) => [slice.id, slice])), [slices]);
  const rootSliceIds = useMemo(() => rootProductSliceIds(detail, slices), [detail, slices]);
  const hasVisiblePlan = treeIndex.rootNodes.length > 0 || rootSliceIds.some((sliceId) => slicesById.has(sliceId));

  return (
    <div className="v3-product-plan">
      {treeIndex.rootNodes.length > 0 ? (
        <div className="v3-product-tree">
          {treeIndex.rootNodes.map((node) => (
            <ProductTreeNodeRow key={node.id} node={node} depth={0} detail={detail} treeIndex={treeIndex} slicesById={slicesById} packageById={packageById} onSelectCard={onSelectCard} updateAnimations={updateAnimations} />
          ))}
        </div>
      ) : null}
      <DirectSliceGroup detail={detail} sliceIds={rootSliceIds} slicesById={slicesById} packageById={packageById} onSelectCard={onSelectCard} updateAnimations={updateAnimations} />
      {!hasVisiblePlan ? <UnplannedRequestNote /> : null}
    </div>
  );
}

function UnplannedRequestNote() {
  return (
    <div className="v3-empty-plan-note">
      <CircleDashed className="size-4" />
      <span>No product plan or slices attached yet.</span>
    </div>
  );
}

function ProductTreeNodeRow({
  node,
  depth,
  detail,
  treeIndex,
  slicesById,
  packageById,
  onSelectCard,
  updateAnimations,
}: {
  node: ProductTreeNode;
  depth: number;
  detail: WorkRequestDetail;
  treeIndex: TreeIndex;
  slicesById: Map<string, PlannedSlice>;
  packageById: Map<string, WorkPackageCard>;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const childNodes = treeIndex.childrenByParent.get(node.id) ?? [];
  const nodeSlices = (node.slice_ids ?? []).map((sliceId) => slicesById.get(sliceId)).filter((slice): slice is PlannedSlice => Boolean(slice));
  const visibleNodeKind = node.node_kind === "product_plan_node" ? null : node.node_kind;

  return (
    <div className="v3-product-node" style={{ "--tree-depth": depth } as CSSProperties} data-mark={node.computed_completion_mark || "unknown"}>
      <div className="v3-product-node-header">
        <CompletionIcon mark={node.computed_completion_mark} />
        <span className="v3-product-node-title">{node.title || node.id}</span>
        {visibleNodeKind ? <span className="v3-node-kind">{visibleNodeKind}</span> : null}
        <span className="v3-node-counts">{node.slice_count || nodeSlices.length} slices</span>
      </div>
      {node.description ? <p className="v3-product-node-description">{stripMarkdown(firstParagraph(node.description) || node.description)}</p> : null}
      {nodeSlices.length > 0 ? (
        <div className="v3-slice-list">
          {nodeSlices.map((slice) => (
            <ProductSliceRow key={slice.id} detail={detail} slice={slice} pkg={packageById.get(slice.work_package_id || "")} onSelectCard={onSelectCard} updateAnimations={updateAnimations} />
          ))}
        </div>
      ) : null}
      {childNodes.length > 0 ? (
        <div className="v3-product-node-children">
          {childNodes.map((child) => (
            <ProductTreeNodeRow key={child.id} node={child} depth={depth + 1} detail={detail} treeIndex={treeIndex} slicesById={slicesById} packageById={packageById} onSelectCard={onSelectCard} updateAnimations={updateAnimations} />
          ))}
        </div>
      ) : null}
    </div>
  );
}

function DirectSliceGroup({
  detail,
  sliceIds,
  slicesById,
  packageById,
  onSelectCard,
  updateAnimations,
}: {
  detail: WorkRequestDetail;
  sliceIds: string[];
  slicesById: Map<string, PlannedSlice>;
  packageById: Map<string, WorkPackageCard>;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const directSlices = sliceIds.map((sliceId) => slicesById.get(sliceId)).filter((slice): slice is PlannedSlice => Boolean(slice));
  if (directSlices.length === 0) return null;

  return (
    <div className="v3-direct-slices">
      {directSlices.map((slice) => (
        <ProductSliceRow key={slice.id} detail={detail} slice={slice} pkg={packageById.get(slice.work_package_id || "")} onSelectCard={onSelectCard} updateAnimations={updateAnimations} />
      ))}
    </div>
  );
}

function ProductSliceRow({
  detail,
  slice,
  pkg,
  onSelectCard,
  updateAnimations,
}: {
  detail: WorkRequestDetail;
  slice: PlannedSlice;
  pkg?: WorkPackageCard;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const operational = sliceOperationalState(slice, pkg);
  const rawStatus = slice.work_package_status || slice.status;
  const openSliceDetail = () => onSelectCard({ kind: "slice", detail, slice, pkg });

  return (
    <div
      className="v3-slice-row stagger-item"
      {...updateMotionAttributes(updateAnimations.motionFor(sliceUpdateKey(slice)))}
    >
      <button type="button" className="v3-slice-main-button" onClick={openSliceDetail}>
        <span className="v3-slice-title">
          <SequenceBadge sequence={slice.sequence} />
          <span>{slice.title || slice.id}</span>
        </span>
        <AnimatedBadge label={operationalLabel(operational, rawStatus)} variant={operationalBadgeVariant(operational, rawStatus)} />
      </button>
      {pkg ? (
        <Button
          type="button"
          size="icon"
          variant="ghost"
          className="v3-slice-package-button"
          title={pkg.title || pkg.id}
          aria-label={`Open execution details for ${pkg.title || pkg.id}`}
          onClick={(event) => {
            event.stopPropagation();
            onSelectCard({ kind: "package", pkg, detail, slice });
          }}
        >
          <Package className="size-4" />
        </Button>
      ) : null}
    </div>
  );
}

function UnlinkedExecutionSection({
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

function CompletionIcon({ mark }: { mark?: ProductTreeCompletionMark | null }) {
  if (mark === "done") return <CheckCircle2 className="v3-completion-icon" />;
  if (mark === "partial" || mark === "deferred") return <CircleDashed className="v3-completion-icon" />;
  return <Circle className="v3-completion-icon" />;
}

function ProgressPill({ progress }: { progress: number }) {
  return (
    <span className="v3-progress-pill">
      <span className="v3-progress-bar"><span style={{ width: `${progress}%` }} /></span>
      <span>{progress}%</span>
    </span>
  );
}

function buildTreeIndex(nodes: ProductTreeNode[], rootNodeIds: string[]): TreeIndex {
  const sortedNodes = nodes.toSorted(compareProductNodes);
  const nodeById = new Map(sortedNodes.map((node) => [node.id, node]));
  const childrenByParent = new Map<string, ProductTreeNode[]>();
  const explicitRoots = rootNodeIds.map((id) => nodeById.get(id)).filter((node): node is ProductTreeNode => Boolean(node));

  sortedNodes.forEach((node) => {
    if (!node.parent_id) return;
    const children = childrenByParent.get(node.parent_id) ?? [];
    children.push(node);
    childrenByParent.set(node.parent_id, children);
  });

  return {
    childrenByParent,
    rootNodes: explicitRoots.length > 0 ? explicitRoots : sortedNodes.filter((node) => !node.parent_id),
  };
}

function compareProductNodes(left: ProductTreeNode, right: ProductTreeNode) {
  const leftPosition = Number.isFinite(left.position) ? left.position ?? 0 : 0;
  const rightPosition = Number.isFinite(right.position) ? right.position ?? 0 : 0;
  if (leftPosition !== rightPosition) return leftPosition - rightPosition;
  return (left.title || left.id).localeCompare(right.title || right.id);
}
