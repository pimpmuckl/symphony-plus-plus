import type { ActiveBlockingEdge, CopyArchitectHandoff, GuidanceItem, WorkPackageCard, WorkRequestDetail } from "@/types/dashboard";
import { AlignedCardSlot, BoardLaneColumn, FeatureLaneRow, LaneGroupLabel } from "@/components/dashboard/board-lanes";
import type { BoardLayoutMeasurementRow, BoardLayoutMode as WorkstreamLayoutMode } from "@/components/dashboard/board-layout";
import { BoardWireLayer, useBoardWirePaths } from "@/components/dashboard/board-wires";
import type * as React from "react";
import { cn } from "@/lib/utils";
import { packageLane, sliceLane } from "@/lib/operational-state";
import { useAlignedBoardLayout, useBoardLayoutMotion } from "@/components/dashboard/board-layout";
import { useMemo, useRef } from "react";
import { CardDetailSelect, DashboardUpdateAnimations } from "./runtime";
import { PackageCard, RequestCard, SliceCard } from "./workstream-cards";
import { SliceEntry, WorkstreamRow } from "./dashboard-state";
import { detailsWithVisibleSlices, packageNodeId, requestChildCount, requestChildrenVisible, requestNodeId, sliceNodeId, sortPackages, sortPlannedSlices, sortSliceEntries, sortWorkRequestDetails, workstreamRowKey, workstreamRows, workstreamWires } from "./workstream-data";
import { packageUpdateKey, requestUpdateKey, sliceUpdateKey } from "./update-animations";

export function WorkstreamBoard({
  repoDetails,
  packages,
  unlinkedPackages,
  activeBlockingEdges,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  layoutMode,
  expandedFinishedRequests,
  finishedRequestScopeKey,
  onSetFinishedRequestChildrenOpen,
  updateAnimations,
  measureKey,
}: {
  repoDetails: WorkRequestDetail[];
  packages: WorkPackageCard[];
  unlinkedPackages: WorkPackageCard[];
  activeBlockingEdges: ActiveBlockingEdge[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  layoutMode: WorkstreamLayoutMode;
  expandedFinishedRequests: Record<string, boolean>;
  finishedRequestScopeKey: string;
  onSetFinishedRequestChildrenOpen: (workRequestId: string, open: boolean) => void;
  updateAnimations: DashboardUpdateAnimations;
  measureKey: string;
}) {
  const shellRef = useRef<HTMLDivElement | null>(null);
  const boardRef = useRef<HTMLDivElement | null>(null);
  const sortedDetails = useMemo(() => sortWorkRequestDetails(repoDetails), [repoDetails]);
  const requested = sortedDetails;
  const packageById = useMemo(() => new Map(packages.map((pkg) => [pkg.id, pkg])), [packages]);
  const sliceEntries = useMemo(
    () =>
      sortedDetails.flatMap((detail, requestIndex) =>
        sortPlannedSlices(detail.planned_slices ?? []).map((slice) => ({
          detail,
          slice,
          pkg: slice.work_package_id ? packageById.get(slice.work_package_id) : undefined,
          requestIndex,
        })),
      ),
    [packageById, sortedDetails],
  );
  const visibleSliceEntries = useMemo(
    () => sliceEntries.filter((entry) => requestChildrenVisible(entry.detail, expandedFinishedRequests, finishedRequestScopeKey)),
    [expandedFinishedRequests, finishedRequestScopeKey, sliceEntries],
  );
  const visibleWireDetails = useMemo(() => detailsWithVisibleSlices(sortedDetails, visibleSliceEntries), [sortedDetails, visibleSliceEntries]);
  const active = visibleSliceEntries;
  const packageEntries = useMemo(() => visibleSliceEntries.filter((entry) => entry.pkg), [visibleSliceEntries]);
  const implementing = useMemo(() => packageEntries.filter((entry) => sliceLane(entry.slice, entry.pkg) !== "finished"), [packageEntries]);
  const finished = useMemo(() => packageEntries.filter((entry) => sliceLane(entry.slice, entry.pkg) === "finished"), [packageEntries]);
  const sortedUnlinkedPackages = useMemo(() => sortPackages(unlinkedPackages), [unlinkedPackages]);
  const activePackages = useMemo<WorkPackageCard[]>(() => [], []);
  const implementingPackages = useMemo(() => sortedUnlinkedPackages.filter((pkg) => packageLane(pkg) !== "finished"), [sortedUnlinkedPackages]);
  const finishedPackages = useMemo(() => sortedUnlinkedPackages.filter((pkg) => packageLane(pkg) === "finished"), [sortedUnlinkedPackages]);
  const alignedRows = useMemo(
    () => workstreamRows(sortedDetails, visibleSliceEntries, activePackages, implementingPackages, finishedPackages),
    [activePackages, finishedPackages, implementingPackages, visibleSliceEntries, sortedDetails],
  );
  const alignedMeasurementRows = useMemo<BoardLayoutMeasurementRow[]>(
    () =>
      alignedRows.map((row, index) => ({
        activeSlotKeys: row.active.map(({ slice }) => slice.id),
        minHeight: row.minHeight,
        rowKey: workstreamRowKey(row, index),
      })),
    [alignedRows],
  );
  const {
    rowTemplate,
    slotTemplates: alignedSlotTemplates,
  } = useAlignedBoardLayout(boardRef, alignedMeasurementRows, layoutMode);
  const wires = useMemo(() => workstreamWires(visibleWireDetails, active, packages, activeBlockingEdges), [active, activeBlockingEdges, visibleWireDetails, packages]);
  const { paths: wirePaths, size: wireSize } = useBoardWirePaths(boardRef, wires, `${layoutMode}:${measureKey}`);
  const layoutMotion = useBoardLayoutMotion(shellRef, boardRef, layoutMode);

  return (
    <div ref={shellRef} className="workstream-board-shell">
      <div
        ref={boardRef}
        className={cn("jira-board workstream-board", layoutMode === "aligned" && "workstream-board-aligned")}
        data-layout={layoutMode}
        data-board-motion={layoutMotion ? "layout" : "idle"}
      >
        <BoardWireLayer paths={wirePaths} width={wireSize.width} height={wireSize.height} />
        {layoutMode === "aligned" ? (
          <AlignedWorkstreamColumns
            rows={alignedRows}
            rowTemplate={rowTemplate}
            requestedCount={requested.length}
            sliceCount={active.length + activePackages.length}
            workPackageCount={implementing.length + finished.length + implementingPackages.length + finishedPackages.length}
            onSelectGuidance={onSelectGuidance}
            onSelectCard={onSelectCard}
            onCopyArchitectHandoff={onCopyArchitectHandoff}
            expandedFinishedRequests={expandedFinishedRequests}
            finishedRequestScopeKey={finishedRequestScopeKey}
            packageById={packageById}
            onSetFinishedRequestChildrenOpen={onSetFinishedRequestChildrenOpen}
            updateAnimations={updateAnimations}
            slotTemplates={alignedSlotTemplates}
          />
        ) : (
          <StackedWorkstreamColumns
            requested={requested}
            active={active}
            implementing={implementing}
            finished={finished}
            activePackages={activePackages}
            implementingPackages={implementingPackages}
            finishedPackages={finishedPackages}
            onSelectGuidance={onSelectGuidance}
            onSelectCard={onSelectCard}
            onCopyArchitectHandoff={onCopyArchitectHandoff}
            expandedFinishedRequests={expandedFinishedRequests}
            finishedRequestScopeKey={finishedRequestScopeKey}
            packageById={packageById}
            onSetFinishedRequestChildrenOpen={onSetFinishedRequestChildrenOpen}
            updateAnimations={updateAnimations}
          />
        )}
      </div>
    </div>
  );
}

export function StackedWorkstreamColumns({
  requested,
  active,
  implementing,
  finished,
  activePackages,
  implementingPackages,
  finishedPackages,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  expandedFinishedRequests,
  finishedRequestScopeKey,
  packageById,
  onSetFinishedRequestChildrenOpen,
  updateAnimations,
}: {
  requested: WorkRequestDetail[];
  active: SliceEntry[];
  implementing: SliceEntry[];
  finished: SliceEntry[];
  activePackages: WorkPackageCard[];
  implementingPackages: WorkPackageCard[];
  finishedPackages: WorkPackageCard[];
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  expandedFinishedRequests: Record<string, boolean>;
  finishedRequestScopeKey: string;
  packageById: Map<string, WorkPackageCard>;
  onSetFinishedRequestChildrenOpen: (workRequestId: string, open: boolean) => void;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const workPackageEntries = sortSliceEntries([...implementing, ...finished]);

  return (
    <>
      <BoardLaneColumn title="Requests" count={requested.length} emptyLabel="No requested work">
        {requested.map((detail, index) => (
          <RequestCard
            key={detail.work_request.id}
            detail={detail}
            onSelectGuidance={onSelectGuidance}
            onSelectCard={() => onSelectCard({ kind: "request", detail })}
            onCopyArchitectHandoff={onCopyArchitectHandoff}
            index={index}
            nodeId={requestNodeId(detail)}
            childrenExpanded={requestChildrenVisible(detail, expandedFinishedRequests, finishedRequestScopeKey)}
            childCount={requestChildCount(detail, packageById)}
            onToggleChildren={() =>
              onSetFinishedRequestChildrenOpen(detail.work_request.id, !requestChildrenVisible(detail, expandedFinishedRequests, finishedRequestScopeKey))
            }
            motion={updateAnimations.motionFor(requestUpdateKey(detail))}
          />
        ))}
      </BoardLaneColumn>
      <BoardLaneColumn title="Slices" count={active.length + activePackages.length} emptyLabel="No slices ready">
        {active.map(({ detail, slice, pkg }, index) => (
          <SliceCard
            key={slice.id}
            slice={slice}
            pkg={pkg}
            lane="slices"
            index={index}
            nodeId={sliceNodeId(slice)}
            onSelectCard={() => onSelectCard({ kind: "slice", detail, slice, pkg })}
            motion={updateAnimations.motionFor(sliceUpdateKey(slice))}
          />
        ))}
        {activePackages.length > 0 ? <LaneGroupLabel label="Standalone packages" /> : null}
        {activePackages.map((pkg, index) => (
          <PackageCard
            key={pkg.id}
            pkg={pkg}
            lane="slices"
            index={active.length + index}
            nodeId={packageNodeId(pkg)}
            onSelectCard={() => onSelectCard({ kind: "package", pkg })}
            motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
          />
        ))}
      </BoardLaneColumn>
      <BoardLaneColumn title="Work Packages" count={implementing.length + finished.length + implementingPackages.length + finishedPackages.length} emptyLabel="No work packages yet">
        {workPackageEntries.map(({ detail, slice, pkg }, index) => (
          pkg ? <PackageCard
            key={pkg.id}
            pkg={pkg}
            lane={sliceLane(slice, pkg)}
            index={index}
            nodeId={packageNodeId(pkg)}
            sequence={slice.sequence}
            onSelectCard={() => onSelectCard({ kind: "package", pkg, detail, slice })}
            motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
          /> : null
        ))}
        {implementingPackages.length + finishedPackages.length > 0 ? <LaneGroupLabel label="Standalone packages" /> : null}
        {implementingPackages.map((pkg, index) => (
          <PackageCard
            key={pkg.id}
            pkg={pkg}
            lane="implementing"
            index={implementing.length + finished.length + index}
            nodeId={packageNodeId(pkg)}
            onSelectCard={() => onSelectCard({ kind: "package", pkg })}
            motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
          />
        ))}
        {finishedPackages.map((pkg, index) => (
          <PackageCard
            key={pkg.id}
            pkg={pkg}
            lane="finished"
            index={implementing.length + finished.length + implementingPackages.length + index}
            nodeId={packageNodeId(pkg)}
            onSelectCard={() => onSelectCard({ kind: "package", pkg })}
            motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
          />
        ))}
      </BoardLaneColumn>
    </>
  );
}

export function AlignedWorkstreamColumns({
  rows,
  rowTemplate,
  slotTemplates,
  requestedCount,
  sliceCount,
  workPackageCount,
  onSelectGuidance,
  onSelectCard,
  onCopyArchitectHandoff,
  expandedFinishedRequests,
  finishedRequestScopeKey,
  packageById,
  onSetFinishedRequestChildrenOpen,
  updateAnimations,
}: {
  rows: WorkstreamRow[];
  rowTemplate: string;
  slotTemplates: Record<string, string>;
  requestedCount: number;
  sliceCount: number;
  workPackageCount: number;
  onSelectGuidance: (item: GuidanceItem) => void;
  onSelectCard: CardDetailSelect;
  onCopyArchitectHandoff: CopyArchitectHandoff;
  expandedFinishedRequests: Record<string, boolean>;
  finishedRequestScopeKey: string;
  packageById: Map<string, WorkPackageCard>;
  onSetFinishedRequestChildrenOpen: (workRequestId: string, open: boolean) => void;
  updateAnimations: DashboardUpdateAnimations;
}) {
  const rowStyle = { gridTemplateRows: rowTemplate } as React.CSSProperties;

  return (
    <>
      <BoardLaneColumn title="Requests" count={requestedCount} emptyLabel="No requested work" bodyStyle={rowStyle} aligned>
        {rows.map((row, index) => {
          const rowKey = workstreamRowKey(row, index);

          return (
            <FeatureLaneRow key={rowKey} rowKey={rowKey} lane="requested">
              {row.detail ? (
                <RequestCard
                  detail={row.detail}
                  onSelectGuidance={onSelectGuidance}
                  onSelectCard={() => onSelectCard({ kind: "request", detail: row.detail! })}
                  onCopyArchitectHandoff={onCopyArchitectHandoff}
                  index={index}
                  nodeId={requestNodeId(row.detail)}
                  childrenExpanded={requestChildrenVisible(row.detail, expandedFinishedRequests, finishedRequestScopeKey)}
                  childCount={requestChildCount(row.detail, packageById)}
                  onToggleChildren={() =>
                    onSetFinishedRequestChildrenOpen(row.detail!.work_request.id, !requestChildrenVisible(row.detail!, expandedFinishedRequests, finishedRequestScopeKey))
                  }
                  motion={updateAnimations.motionFor(requestUpdateKey(row.detail))}
                />
              ) : null}
            </FeatureLaneRow>
          );
        })}
      </BoardLaneColumn>
      <BoardLaneColumn title="Slices" count={sliceCount} emptyLabel="No slices ready" bodyStyle={rowStyle} aligned>
        {rows.map((row, index) => {
          const rowKey = workstreamRowKey(row, index);

          return (
            <FeatureLaneRow key={rowKey} rowKey={rowKey} lane="slices" slotTemplate={slotTemplates[rowKey]}>
              {row.active.map(({ detail, slice, pkg }, sliceIndex) => (
                <AlignedCardSlot key={slice.id} rowKey={rowKey} slotKey={slice.id} lane="slices">
                  <SliceCard
                    slice={slice}
                    pkg={pkg}
                    lane="slices"
                    index={sliceIndex}
                    nodeId={sliceNodeId(slice)}
                    onSelectCard={() => onSelectCard({ kind: "slice", detail, slice, pkg })}
                    motion={updateAnimations.motionFor(sliceUpdateKey(slice))}
                  />
                </AlignedCardSlot>
              ))}
              {row.activePackages.length > 0 ? <LaneGroupLabel label="Standalone packages" /> : null}
              {row.activePackages.map((pkg, packageIndex) => (
                <PackageCard
                  key={pkg.id}
                  pkg={pkg}
                  lane="slices"
                  index={row.active.length + packageIndex}
                  nodeId={packageNodeId(pkg)}
                  onSelectCard={() => onSelectCard({ kind: "package", pkg })}
                  motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
                />
              ))}
            </FeatureLaneRow>
          );
        })}
      </BoardLaneColumn>
      <BoardLaneColumn title="Work Packages" count={workPackageCount} emptyLabel="No work packages yet" bodyStyle={rowStyle} aligned>
        {rows.map((row, index) => {
          const rowKey = workstreamRowKey(row, index);

          return (
            <FeatureLaneRow
              key={rowKey}
              rowKey={rowKey}
              lane="packages"
              slotTemplate={slotTemplates[rowKey]}
              emptyOverride={!row.active.some(({ pkg }) => pkg) && row.implementingPackages.length + row.finishedPackages.length === 0}
            >
              {row.active.map(({ detail, slice, pkg }, sliceIndex) => (
                <AlignedCardSlot key={slice.id} rowKey={rowKey} slotKey={slice.id} lane="packages" empty={!pkg}>
                  {pkg ? (
                    <PackageCard
                      pkg={pkg}
                      lane={sliceLane(slice, pkg)}
                      index={sliceIndex}
                      nodeId={packageNodeId(pkg)}
                      sequence={slice.sequence}
                      onSelectCard={() => onSelectCard({ kind: "package", pkg, detail, slice })}
                      motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
                    />
                  ) : null}
                </AlignedCardSlot>
              ))}
              {row.implementingPackages.length + row.finishedPackages.length > 0 ? <LaneGroupLabel label="Standalone packages" /> : null}
              {row.implementingPackages.map((pkg, packageIndex) => (
                <PackageCard
                  key={pkg.id}
                  pkg={pkg}
                  lane="implementing"
                  index={row.implementing.length + row.finished.length + packageIndex}
                  nodeId={packageNodeId(pkg)}
                  onSelectCard={() => onSelectCard({ kind: "package", pkg })}
                  motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
                />
              ))}
              {row.finishedPackages.map((pkg, packageIndex) => (
                <PackageCard
                  key={pkg.id}
                  pkg={pkg}
                  lane="finished"
                  index={row.implementing.length + row.finished.length + row.implementingPackages.length + packageIndex}
                  nodeId={packageNodeId(pkg)}
                  onSelectCard={() => onSelectCard({ kind: "package", pkg })}
                  motion={updateAnimations.motionFor(packageUpdateKey(pkg))}
                />
              ))}
            </FeatureLaneRow>
          );
        })}
      </BoardLaneColumn>
    </>
  );
}
