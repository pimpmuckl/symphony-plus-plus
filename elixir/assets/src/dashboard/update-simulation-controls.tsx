import { AlertTriangle, MessageSquareText, RefreshCw } from "lucide-react";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import type { DashboardUpdateAnimations } from "./runtime";

const UPDATE_SIMULATION_CONTROLS = [
  { kind: "guidance", label: "G", icon: <MessageSquareText className="size-3.5" />, tooltip: "Simulate new human guidance" },
  { kind: "blocker", label: "B", icon: <AlertTriangle className="size-3.5" />, tooltip: "Simulate a fresh blocker" },
  { kind: "changed", label: "U", icon: <RefreshCw className="size-3.5" />, tooltip: "Simulate a card update" },
] as const;

export function UpdateSimulationControls({ updateAnimations }: { updateAnimations: DashboardUpdateAnimations }) {
  return (
    <div className="update-sim-controls" aria-label="Simulate dashboard update animations">
      {UPDATE_SIMULATION_CONTROLS.map((control) => (
        <Tooltip key={control.kind}>
          <TooltipTrigger asChild>
            <button
              type="button"
              className="update-sim-button"
              onClick={() => updateAnimations.simulate(control.kind)}
              aria-label={control.tooltip}
            >
              {control.icon}
              <span className="sr-only">{control.label}</span>
            </button>
          </TooltipTrigger>
          <TooltipContent>{control.tooltip}</TooltipContent>
        </Tooltip>
      ))}
    </div>
  );
}
