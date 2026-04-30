defmodule SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @worker_capability "worker:lifecycle.transition"
  @architect_capability "architect:lifecycle.transition"

  @standalone_transitions %{
    "created" => ["ready_for_worker", "blocked", "abandoned"],
    "ready_for_worker" => ["claimed", "blocked", "abandoned"],
    "claimed" => ["planning", "blocked", "abandoned"],
    "planning" => ["implementing", "blocked", "abandoned"],
    "implementing" => ["reviewing", "blocked", "abandoned"],
    "reviewing" => ["ci_waiting", "implementing", "blocked", "abandoned"],
    "ci_waiting" => ["ready_for_human_merge", "reviewing", "blocked", "abandoned"],
    "ready_for_human_merge" => ["merged", "closed"],
    "blocked" => ["planning", "implementing", "abandoned"],
    "abandoned" => [],
    "closed" => [],
    "merged" => []
  }

  @phase_child_transitions %{
    "created" => ["ready_for_worker", "blocked", "abandoned"],
    "ready_for_worker" => ["claimed", "blocked", "abandoned"],
    "claimed" => ["planning", "blocked", "abandoned"],
    "planning" => ["implementing", "blocked", "abandoned"],
    "implementing" => ["reviewing", "blocked", "abandoned"],
    "reviewing" => ["ci_waiting", "implementing", "blocked", "abandoned"],
    "ci_waiting" => ["ready_for_architect_merge", "reviewing", "blocked", "abandoned"],
    "ready_for_architect_merge" => ["merging_into_phase", "closed"],
    "merging_into_phase" => ["merged_into_phase", "blocked"],
    "merged_into_phase" => ["merged"],
    "blocked" => ["planning", "implementing", "abandoned"],
    "abandoned" => [],
    "closed" => [],
    "merged" => []
  }

  @architect_only_statuses ["merging_into_phase", "merged_into_phase", "merged", "closed"]

  @type actor :: %{optional(atom() | String.t()) => term()}
  @type error ::
          :invalid_transition
          | :worker_cannot_mark_merged
          | :worker_cannot_advance_phase_state
          | :missing_lifecycle_capability

  @spec validate_transition(WorkPackage.t(), String.t(), actor()) :: :ok | {:error, error()}
  def validate_transition(%WorkPackage{} = work_package, next_status, actor)
      when is_binary(next_status) and is_map(actor) do
    case validate_allowed_transition(work_package, next_status) do
      :ok -> validate_actor(work_package, next_status, actor)
      {:error, _reason} = error -> error
    end
  end

  @spec terminal_readiness_status(WorkPackage.t()) :: String.t()
  def terminal_readiness_status(%WorkPackage{kind: "phase_child"}), do: "ready_for_architect_merge"
  def terminal_readiness_status(%WorkPackage{}), do: "ready_for_human_merge"

  defp validate_allowed_transition(%WorkPackage{} = work_package, next_status) do
    work_package
    |> transitions()
    |> Map.get(work_package.status, [])
    |> Enum.member?(next_status)
    |> then(fn
      true -> :ok
      false -> {:error, :invalid_transition}
    end)
  end

  defp validate_actor(%WorkPackage{}, next_status, actor) when next_status in ["merged", "merged_into_phase"] do
    if role(actor) == "worker" do
      {:error, :worker_cannot_mark_merged}
    else
      require_capability(actor, @architect_capability)
    end
  end

  defp validate_actor(%WorkPackage{kind: "phase_child"}, next_status, actor)
       when next_status in @architect_only_statuses do
    if role(actor) == "worker" do
      {:error, :worker_cannot_advance_phase_state}
    else
      require_capability(actor, @architect_capability)
    end
  end

  defp validate_actor(%WorkPackage{}, _next_status, actor) do
    case role(actor) do
      "architect" -> require_capability(actor, @architect_capability)
      "worker" -> require_capability(actor, @worker_capability)
      _role -> {:error, :missing_lifecycle_capability}
    end
  end

  defp transitions(%WorkPackage{kind: "phase_child"}), do: @phase_child_transitions
  defp transitions(%WorkPackage{}), do: @standalone_transitions

  defp require_capability(actor, capability) do
    if capability in capabilities(actor) do
      :ok
    else
      {:error, :missing_lifecycle_capability}
    end
  end

  defp role(actor), do: Map.get(actor, :grant_role) || Map.get(actor, "grant_role") || Map.get(actor, :role) || Map.get(actor, "role")

  defp capabilities(actor), do: Map.get(actor, :capabilities) || Map.get(actor, "capabilities") || []
end
