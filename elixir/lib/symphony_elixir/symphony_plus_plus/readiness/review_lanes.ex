defmodule SymphonyElixir.SymphonyPlusPlus.Readiness.ReviewLanes do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.ReviewProfiles
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice

  @spec required(module() | nil, WorkPackage.t()) ::
          {:ok, {[String.t()], [map()]}} | {:error, {:storage_failed, String.t()}}
  def required(repo, %WorkPackage{} = work_package) when is_atom(repo) and not is_nil(repo) do
    with {:ok, slice_lanes} <- linked_planned_slice_review_lanes(repo, work_package.id) do
      {:ok, required_from_planned_slice_lanes(work_package, slice_lanes)}
    end
  end

  def required(_repo, %WorkPackage{} = work_package), do: {:ok, {policy_required(work_package), []}}

  @spec required_from_planned_slice_lanes(WorkPackage.t(), [String.t()] | nil) :: {[String.t()], [map()]}
  def required_from_planned_slice_lanes(%WorkPackage{} = work_package, slice_lanes) do
    policy_lanes = policy_required(work_package)

    case ReviewProfiles.normalize_profiles(slice_lanes || []) do
      [] -> {policy_lanes, []}
      planned_slice_lanes -> {planned_slice_lanes, warnings(policy_lanes, planned_slice_lanes)}
    end
  end

  @spec policy_required(WorkPackage.t()) :: [String.t()]
  def policy_required(%WorkPackage{} = work_package) do
    case LifecycleService.policy_for(work_package) do
      {:ok, policy} ->
        policy
        |> get_in([:review_suite, :required])
        |> ReviewProfiles.normalize_profiles()

      {:error, _reason} ->
        []
    end
  end

  defp linked_planned_slice_review_lanes(repo, work_package_id) when is_binary(work_package_id) do
    planned_slices =
      repo.all(
        from(planned_slice in PlannedSlice,
          where: planned_slice.work_package_id == ^work_package_id,
          order_by: [asc: planned_slice.sequence, asc: planned_slice.id],
          limit: 2
        )
      )

    case planned_slices do
      [%PlannedSlice{review_lanes: review_lanes}] -> {:ok, review_lanes || []}
      _missing_or_ambiguous -> {:ok, []}
    end
  rescue
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  defp linked_planned_slice_review_lanes(_repo, _work_package_id), do: {:ok, []}

  defp warnings(policy_lanes, planned_slice_lanes) do
    if MapSet.new(policy_lanes) == MapSet.new(planned_slice_lanes) do
      []
    else
      [
        %{
          "code" => "review_lanes_differ",
          "message" => "Using planned-slice review profiles.",
          "policy_lanes" => redacted_lanes(policy_lanes),
          "required_lanes" => redacted_lanes(planned_slice_lanes)
        }
      ]
    end
  end

  defp redacted_lanes(lanes), do: Redactor.redact_output(lanes)
end
