defmodule SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @worker_capability "worker:lifecycle.transition"
  @architect_capability "architect:lifecycle.transition"
  @standalone_kinds ["quick_fix", "hotfix", "investigation"]
  @phase_child_kind "phase_child"

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
    "merged_into_phase" => [],
    "blocked" => ["planning", "implementing", "abandoned"],
    "abandoned" => [],
    "closed" => []
  }

  @architect_only_statuses ["merging_into_phase", "merged_into_phase", "merged", "closed"]

  @type actor :: %{optional(atom() | String.t()) => term()}
  @type error ::
          :invalid_transition
          | :unknown_lifecycle_status
          | :unsupported_work_package_kind
          | :worker_cannot_mark_merged
          | :worker_cannot_advance_phase_state
          | :missing_lifecycle_capability

  @spec validate_transition(WorkPackage.t(), String.t(), actor()) :: :ok | {:error, error()}
  def validate_transition(%WorkPackage{} = work_package, next_status, actor)
      when is_binary(next_status) and is_map(actor) do
    case validate_lifecycle_shape(work_package, next_status) do
      :ok -> validate_allowed_transition(work_package, next_status, actor)
      {:error, _reason} = error -> error
    end
  end

  @spec terminal_readiness_status(WorkPackage.t()) :: String.t()
  def terminal_readiness_status(%WorkPackage{kind: @phase_child_kind}), do: "ready_for_architect_merge"
  def terminal_readiness_status(%WorkPackage{}), do: "ready_for_human_merge"

  defp validate_lifecycle_shape(%WorkPackage{} = work_package, next_status) do
    cond do
      not lifecycle_kind?(work_package.kind) -> {:error, :unsupported_work_package_kind}
      work_package.status not in WorkPackage.statuses() -> {:error, :unknown_lifecycle_status}
      next_status not in WorkPackage.statuses() -> {:error, :unknown_lifecycle_status}
      not current_status_supported?(work_package) -> {:error, :unknown_lifecycle_status}
      true -> :ok
    end
  end

  defp validate_allowed_transition(%WorkPackage{} = work_package, next_status, actor) do
    if allowed_transition?(work_package, next_status) do
      validate_actor(work_package, next_status, actor)
    else
      {:error, :invalid_transition}
    end
  end

  defp validate_actor(%WorkPackage{}, next_status, actor) when next_status in ["merged", "merged_into_phase"] do
    if role(actor) == "worker" do
      {:error, :worker_cannot_mark_merged}
    else
      require_capability(actor, @architect_capability)
    end
  end

  defp validate_actor(%WorkPackage{kind: @phase_child_kind}, next_status, actor)
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

  defp allowed_transition?(%WorkPackage{} = work_package, next_status) do
    work_package
    |> transitions()
    |> Map.fetch(work_package.status)
    |> case do
      {:ok, allowed_statuses} -> Enum.member?(allowed_statuses, next_status)
      :error -> false
    end
  end

  defp current_status_supported?(%WorkPackage{} = work_package) do
    work_package
    |> transitions()
    |> Map.has_key?(work_package.status)
  end

  defp lifecycle_kind?(@phase_child_kind), do: true
  defp lifecycle_kind?(kind), do: kind in @standalone_kinds

  defp transitions(%WorkPackage{kind: @phase_child_kind}), do: @phase_child_transitions
  defp transitions(%WorkPackage{}), do: @standalone_transitions

  defp require_capability(actor, capability) do
    if capability in capabilities(actor) do
      :ok
    else
      {:error, :missing_lifecycle_capability}
    end
  end

  defp role(actor), do: Map.get(actor, :grant_role) || Map.get(actor, "grant_role") || Map.get(actor, :role) || Map.get(actor, "role")

  defp capabilities(actor) do
    case Map.get(actor, :capabilities) || Map.get(actor, "capabilities") do
      capabilities when is_list(capabilities) -> capabilities
      _capabilities -> []
    end
  end
end
