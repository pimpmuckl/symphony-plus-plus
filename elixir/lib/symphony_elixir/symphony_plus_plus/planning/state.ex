defmodule SymphonyElixir.SymphonyPlusPlus.Planning.State do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type t :: %__MODULE__{
          work_package: WorkPackage.t(),
          plan_nodes: [PlanNode.t()],
          findings: [Finding.t()],
          progress_events: [ProgressEvent.t()],
          artifacts: [Artifact.t()]
        }

  defstruct work_package: nil,
            plan_nodes: [],
            findings: [],
            progress_events: [],
            artifacts: []
end
