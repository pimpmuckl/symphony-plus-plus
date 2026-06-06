import type { ActiveBlockingEdge, CopyArchitectHandoff, GuidanceItem, PlannedSlice, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import type { ProductTreeNode } from "@/types/product-tree";
import { AlertTriangle, ChevronRight, CircleDashed, GitBranch, Layers3, MessageSquareText, Split } from "lucide-react";
import type { CSSProperties } from "react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { operationalBadgeVariant, operationalLabel, requestStateCardTone, sliceCardTone, sliceLane, sliceOperationalState } from "@/lib/operational-state";
import { useId, useMemo, useState } from "react";
import { CardDetailSelect, DashboardUpdateAnimations } from "./runtime";
import { clarificationGuidanceItem } from "./dashboard-data";
import { firstParagraph, stripMarkdown } from "./dashboard-text";
import { finishedRequestChildrenStorageKey, sortPackages, sortPlannedSlices, sortWorkRequestDetails } from "./workstream-data";
import { activeBlockerEntityCounts, productTreeCounts, requestProgress, rootProductSliceIds } from "./workstream-progress";
import { productNodeState, rowProgressAttentionState, rowProgressIconState, sliceBlockerCount, sliceGuidanceCount } from "./workstream-row-state";
import { EntityCountChips, EntityKindSlot, ProductNodeHeader, ProgressPill, ProgressStateIcon, RequestHeaderActions, RowBadgeSlot, SliceKindSlot } from "./workstream-row-ui";
import { openBlockersForRequest, openBlockersForSlices, openGuidanceForSlice, openGuidanceForSlices, productNodeSubtreeSlices, requestGuidanceItem } from "./workstream-board-actions";
import { requestUpdateKey, sliceUpdateKey } from "./update-animations";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";
import { UnlinkedExecutionSection } from "./workstream-unlinked-section";

type TreeIndex = {
  childrenByParent: Map<string, ProductTreeNode[]>;
  rootNodes: ProductTreeNode[];
};

type ProductTreeRenderContext = {
  detail: WorkRequestDetail;
  treeIndex: TreeIndex;
  slicesById: Map<string, PlannedSlice>;
  packageById: Map<string, WorkPackageCard>;
  activeBlockerCountBySliceId: Map<string, number>;
  activeBlockerKeysBySliceId: Map<string, Set<string>>;
  guidanceItems: GuidanceItem[];
  onSelectCard: CardDetailSelect;
  onSelectGuidance: (item: GuidanceItem) => void;
  updateAnimations: DashboardUpdateAnimations;
};

export function WorkstreamBoard({
  repoDetails,
  packages,
  unlinkedPackages,
  activeBlockingEdges,
  guidanceItems,
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
  guidanceItems: GuidanceItem[];
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
  const blockerCounts = useMemo(() => activeBlockerEntityCounts(activeBlockingEdges, repoDetails), [activeBlockingEdges, repoDetails]);

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
              activeBlockerCount={blockerCounts.requests.get(detail.work_request.id) ?? 0}
              activeBlockingEdges={activeBlockingEdges}
              activeBlockerCountBySliceId={blockerCounts.slices}
              activeBlockerKeysBySliceId={blockerCounts.sliceBlockerKeys}
              guidanceItems={guidanceItems}
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
  activeBlockingEdges,
  activeBlockerCountBySliceId,
  activeBlockerKeysBySliceId,
  guidanceItems,
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
  activeBlockingEdges: ActiveBlockingEdge[];
  activeBlockerCountBySliceId: Map<string, number>;
  activeBlockerKeysBySliceId: Map<string, Set<string>>;
  guidanceItems: GuidanceItem[];
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
  const counts = productTreeCounts(detail, activeBlockerCount);
  const openQuestion = detail.clarification_questions?.find((question) => question.status === "open");
  const openGuidance = () => {
    const item = requestGuidanceItem(detail, guidanceItems) ?? (openQuestion ? clarificationGuidanceItem(detail, openQuestion) : null);
    if (item) {
      onSelectGuidance(item);
      return;
    }

    onSelectCard({ kind: "request", detail });
  };
  const openBlockers = () => openBlockersForRequest(detail, slices, packageById, activeBlockerCountBySliceId, activeBlockingEdges, onSelectCard);
  const tone = requestStateCardTone(detail);
  const requestLabel = operationalLabel(request.operational_state, request.status);
  const rowStyle = {
    animationDelay: `${index * 30}ms`,
  } as CSSProperties;

  return (
    <section
      className="v3-request-row stagger-item"
      data-expanded={expanded ? "true" : "false"}
      data-tone={tone}
      style={rowStyle}
      {...updateMotionAttributes(updateAnimations.motionFor(requestUpdateKey(detail)))}
    >
      <div className="v3-request-header v3-entity-row" data-tone={tone}>
        <button type="button" className="v3-request-chevron-button" aria-expanded={expanded} aria-label={`${expanded ? "Collapse" : "Expand"} ${request.title || request.id}`} onClick={onToggle}>
          <ChevronRight className={cn("size-4 transition-transform duration-200", expanded && "rotate-90")} />
        </button>
        <RequestHeaderActions
          detail={detail}
          progress={progress}
          progressAttentionState={rowProgressAttentionState({ blockerCount: counts.blockerCount, guidanceCount: counts.guidanceCount, tone })}
          progressIconState={rowProgressIconState({ blockerCount: counts.blockerCount, guidanceCount: counts.guidanceCount, progress, tone })}
          progressLabel={requestLabel}
          onSelectCard={onSelectCard}
          onCopyArchitectHandoff={onCopyArchitectHandoff}
        />
        <button type="button" className="v3-request-main" aria-expanded={expanded} onClick={onToggle}>
          <span className="v3-request-title-group">
            <span className="v3-request-title">{request.title || request.id}</span>
            <span className="v3-request-meta">
              <GitBranch className="size-3.5" />
              <span>{request.repo_display || request.repo || "repo"}</span>
              <span>{request.base_branch || "main"}</span>
            </span>
          </span>
        </button>
        <RequestProgressSummary counts={counts} onOpenGuidance={openGuidance} onOpenBlockers={openBlockers} />
        <span className="v3-row-status">
          <ProgressPill progress={progress} />
          <RowBadgeSlot label={requestLabel} variant={operationalBadgeVariant(request.operational_state, request.status)} />
        </span>
        <RequestScopeSlot counts={counts} />
      </div>
      {expanded ? (
        <div className="v3-request-body">
          <RequestActions
            detail={detail}
            openQuestion={openQuestion}
            onSelectGuidance={onSelectGuidance}
          />
          <ProductPlanBody
            detail={detail}
            packageById={packageById}
            slices={slices}
            activeBlockerCountBySliceId={activeBlockerCountBySliceId}
            activeBlockerKeysBySliceId={activeBlockerKeysBySliceId}
            guidanceItems={guidanceItems}
            onSelectGuidance={onSelectGuidance}
            onSelectCard={onSelectCard}
            updateAnimations={updateAnimations}
          />
        </div>
      ) : null}
    </section>
  );
}

function RequestProgressSummary({
  counts,
  onOpenGuidance,
  onOpenBlockers,
}: {
  counts: ReturnType<typeof productTreeCounts>;
  onOpenGuidance: () => void;
  onOpenBlockers: () => void;
}) {
  return (
    <EntityCountChips
      className="v3-request-summary"
      items={[
        { key: "nodes", icon: <Layers3 className="size-3.5" />, count: counts.nodeCount, label: "plan nodes", showZero: true },
        { key: "slices", icon: <Split className="size-3.5" />, count: counts.sliceCount, label: "slices", showZero: true },
        { key: "guidance", icon: <MessageSquareText className="size-3.5" />, count: counts.guidanceCount, label: "guidance needed", onClick: counts.guidanceCount > 0 ? onOpenGuidance : undefined, tone: "guidance", showZero: true },
        { key: "blockers", icon: <AlertTriangle className="size-3.5" />, count: counts.blockerCount, label: "active blockers", onClick: counts.blockerCount > 0 ? onOpenBlockers : undefined, tone: "blocker", showZero: true },
      ]}
    />
  );
}

function RequestScopeSlot({ counts }: { counts: ReturnType<typeof productTreeCounts> }) {
  if (counts.nodeCount > 0) {
    return <EntityKindSlot icon={<Layers3 className="size-3.5" />} value={counts.nodeCount} title={`${counts.nodeCount} plan nodes`} />;
  }

  if (counts.sliceCount > 0) {
    return <EntityKindSlot icon={<Split className="size-3.5" />} value={counts.sliceCount} title={`${counts.sliceCount} slices`} />;
  }

  return <EntityKindSlot icon={<CircleDashed className="size-3.5" />} title="No product plan or slices attached" muted />;
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
  guidanceItems,
  onSelectGuidance,
  onSelectCard,
  updateAnimations,
  activeBlockerCountBySliceId,
  activeBlockerKeysBySliceId,
}: {
  detail: WorkRequestDetail;
  packageById: Map<string, WorkPackageCard>;
  slices: PlannedSlice[];
  guidanceItems: GuidanceItem[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
  activeBlockerCountBySliceId: Map<string, number>;
  activeBlockerKeysBySliceId: Map<string, Set<string>>;
}) {
  const treeIndex = useMemo(() => buildTreeIndex(detail.product_tree?.nodes ?? [], detail.product_tree?.root_node_ids ?? []), [detail.product_tree]);
  const slicesById = useMemo(() => new Map(slices.map((slice) => [slice.id, slice])), [slices]);
  const rootSliceIds = useMemo(() => rootProductSliceIds(detail, slices), [detail, slices]);
  const hasVisiblePlan = treeIndex.rootNodes.length > 0 || rootSliceIds.some((sliceId) => slicesById.has(sliceId));
  const treeContext: ProductTreeRenderContext = {
    detail,
    treeIndex,
    slicesById,
    packageById,
    activeBlockerCountBySliceId,
    activeBlockerKeysBySliceId,
    guidanceItems,
    onSelectCard,
    onSelectGuidance,
    updateAnimations,
  };

  return (
    <div className="v3-product-plan">
      {treeIndex.rootNodes.length > 0 ? (
        <div className="v3-product-tree">
          {treeIndex.rootNodes.map((node) => (
            <ProductTreeNodeRow
              key={node.id}
              node={node}
              depth={0}
              context={treeContext}
            />
          ))}
        </div>
      ) : null}
      <DirectSliceGroup
        detail={detail}
        sliceIds={rootSliceIds}
        slicesById={slicesById}
        packageById={packageById}
        activeBlockerCountBySliceId={activeBlockerCountBySliceId}
        guidanceItems={guidanceItems}
        onSelectGuidance={onSelectGuidance}
        onSelectCard={onSelectCard}
        updateAnimations={updateAnimations}
      />
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
  context,
}: {
  node: ProductTreeNode;
  depth: number;
  context: ProductTreeRenderContext;
}) {
  const { activeBlockerCountBySliceId, activeBlockerKeysBySliceId, detail, guidanceItems, onSelectCard, onSelectGuidance, packageById, treeIndex, slicesById } = context;
  const childNodes = treeIndex.childrenByParent.get(node.id) ?? [];
  const nodeSlices = (node.slice_ids ?? []).map((sliceId) => slicesById.get(sliceId)).filter((slice): slice is PlannedSlice => Boolean(slice));
  const nodeSubtreeSlices = productNodeSubtreeSlices(node, treeIndex, slicesById);
  const nodeState = productNodeState(node, nodeSlices.length, treeIndex, activeBlockerCountBySliceId, activeBlockerKeysBySliceId);
  const contentId = useId();
  const hasDisclosureContent = productNodeHasDisclosureContent(node, nodeSlices, childNodes);
  const [expanded, setExpanded] = useState(true);
  const openGuidance = () => openGuidanceForSlices(detail, nodeSubtreeSlices, packageById, guidanceItems, onSelectGuidance, onSelectCard);
  const openBlockers = () => openBlockersForSlices(detail, nodeSubtreeSlices, packageById, activeBlockerCountBySliceId, onSelectCard);

  return (
    <div className="v3-product-node" style={{ "--tree-depth": depth } as CSSProperties} data-mark={nodeState.mark} data-tone={nodeState.tone}>
      <ProductNodeHeader
        node={node}
        nodeSliceCount={nodeState.nodeSliceCount}
        visibleNodeKind={nodeState.visibleNodeKind}
        mark={nodeState.mark}
        tone={nodeState.tone}
        statusLabel={nodeState.statusLabel}
        guidanceCount={nodeState.guidanceCount}
        blockerCount={nodeState.blockerCount}
        collapsible={hasDisclosureContent}
        expanded={expanded}
        contentId={hasDisclosureContent ? contentId : undefined}
        onOpenGuidance={openGuidance}
        onOpenBlockers={openBlockers}
        onToggle={() => setExpanded((open) => !open)}
      />
      {hasDisclosureContent ? (
        <ProductTreeNodeContent
          contentId={contentId}
          hidden={!expanded}
          node={node}
          nodeSlices={nodeSlices}
          childNodes={childNodes}
          depth={depth}
          context={context}
        />
      ) : null}
    </div>
  );
}

function productNodeHasDisclosureContent(node: ProductTreeNode, nodeSlices: PlannedSlice[], childNodes: ProductTreeNode[]) {
  return Boolean(node.description) || nodeSlices.length > 0 || childNodes.length > 0;
}

function ProductTreeNodeContent({
  contentId,
  hidden,
  node,
  nodeSlices,
  childNodes,
  depth,
  context,
}: {
  contentId: string;
  hidden: boolean;
  node: ProductTreeNode;
  nodeSlices: PlannedSlice[];
  childNodes: ProductTreeNode[];
  depth: number;
  context: ProductTreeRenderContext;
}) {
  const { activeBlockerCountBySliceId, detail, guidanceItems, packageById, onSelectCard, onSelectGuidance, updateAnimations } = context;

  return (
    <div id={contentId} className="v3-product-node-content" hidden={hidden}>
      {node.description ? <p className="v3-product-node-description">{stripMarkdown(firstParagraph(node.description) || node.description)}</p> : null}
      {nodeSlices.length > 0 ? (
        <div className="v3-slice-list">
          {nodeSlices.map((slice) => (
            <ProductSliceRow
              key={slice.id}
              detail={detail}
              slice={slice}
              pkg={packageById.get(slice.work_package_id || "")}
              activeBlockerCountBySliceId={activeBlockerCountBySliceId}
              guidanceItems={guidanceItems}
              onSelectGuidance={onSelectGuidance}
              onSelectCard={onSelectCard}
              updateAnimations={updateAnimations}
            />
          ))}
        </div>
      ) : null}
      {childNodes.length > 0 ? (
        <div className="v3-product-node-children">
          {childNodes.map((child) => (
            <ProductTreeNodeRow
              key={child.id}
              node={child}
              depth={depth + 1}
              context={context}
            />
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
  activeBlockerCountBySliceId,
  guidanceItems,
  onSelectGuidance,
  onSelectCard,
  updateAnimations,
}: {
  detail: WorkRequestDetail;
  sliceIds: string[];
  slicesById: Map<string, PlannedSlice>;
  packageById: Map<string, WorkPackageCard>;
  activeBlockerCountBySliceId: Map<string, number>;
  guidanceItems: GuidanceItem[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const directSlices = sliceIds.map((sliceId) => slicesById.get(sliceId)).filter((slice): slice is PlannedSlice => Boolean(slice));
  if (directSlices.length === 0) return null;

  return (
    <div className="v3-direct-slices">
      {directSlices.map((slice) => (
        <ProductSliceRow
          key={slice.id}
          detail={detail}
          slice={slice}
          pkg={packageById.get(slice.work_package_id || "")}
          activeBlockerCountBySliceId={activeBlockerCountBySliceId}
          guidanceItems={guidanceItems}
          onSelectGuidance={onSelectGuidance}
          onSelectCard={onSelectCard}
          updateAnimations={updateAnimations}
        />
      ))}
    </div>
  );
}

function ProductSliceRow({
  detail,
  slice,
  pkg,
  activeBlockerCountBySliceId,
  guidanceItems,
  onSelectGuidance,
  onSelectCard,
  updateAnimations,
}: {
  detail: WorkRequestDetail;
  slice: PlannedSlice;
  pkg?: WorkPackageCard;
  activeBlockerCountBySliceId: Map<string, number>;
  guidanceItems: GuidanceItem[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const operational = sliceOperationalState(slice, pkg);
  const rawStatus = slice.work_package_status || slice.status;
  const lane = sliceLane(slice, pkg);
  const tone = sliceCardTone(slice, pkg, lane);
  const blockerCount = sliceBlockerCount(slice, pkg, activeBlockerCountBySliceId);
  const guidanceCount = sliceGuidanceCount(slice, pkg);
  const sliceLabel = operationalLabel(operational, rawStatus);
  const progress = sliceProgressPercent(pkg, lane, tone);
  const progressIconState = rowProgressIconState({ blockerCount, guidanceCount, progress, tone });
  const progressAttentionState = rowProgressAttentionState({ blockerCount, guidanceCount, tone });
  const openSliceDetail = () => onSelectCard({ kind: "slice", detail, slice, pkg });
  const openGuidance = () => openGuidanceForSlice(detail, slice, pkg, guidanceItems, onSelectGuidance, onSelectCard);
  const openBlockers = () => onSelectCard(pkg ? { kind: "package", pkg, detail, slice } : { kind: "slice", detail, slice, pkg });

  return (
    <div
      className="v3-slice-row v3-entity-row stagger-item"
      data-tone={tone}
      {...updateMotionAttributes(updateAnimations.motionFor(sliceUpdateKey(slice)))}
    >
      <ProgressStateIcon state={progressIconState} attentionState={progressAttentionState} progress={progress} label={sliceLabel} />
      <button type="button" className="v3-slice-main-button" onClick={openSliceDetail}>
        <span>{slice.title || slice.id}</span>
      </button>
      <EntityCountChips
        reserveEmpty
        items={[
          { key: "guidance", icon: <MessageSquareText className="size-3.5" />, count: guidanceCount, label: "guidance needed", onClick: guidanceCount > 0 ? openGuidance : undefined, tone: "guidance" },
          { key: "blockers", icon: <AlertTriangle className="size-3.5" />, count: blockerCount, label: "active blockers", onClick: blockerCount > 0 ? openBlockers : undefined, tone: "blocker" },
        ]}
      />
      <span className="v3-row-status v3-slice-status">
        <RowBadgeSlot label={sliceLabel} variant={operationalBadgeVariant(operational, rawStatus)} />
      </span>
      <SliceKindSlot detail={detail} slice={slice} pkg={pkg} onSelectCard={onSelectCard} />
    </div>
  );
}

function sliceProgressPercent(pkg: WorkPackageCard | undefined, lane: ReturnType<typeof sliceLane>, tone: string) {
  const completed = pkg?.plan?.completed_count ?? 0;
  const total = pkg?.plan?.total_count ?? 0;
  if (total > 0) return Math.round((completed / total) * 100);
  if (lane === "finished" || tone === "finished") return 100;
  if (lane === "implementing" || ["implementing", "review", "merge"].includes(tone)) return 50;
  return 0;
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
