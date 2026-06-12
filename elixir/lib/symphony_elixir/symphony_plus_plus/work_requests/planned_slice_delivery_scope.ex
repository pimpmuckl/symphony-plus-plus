defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDeliveryScope do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.RepoScope
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @spec normalize_explicit(module(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_explicit(repo, work_request_id, attrs) when is_atom(repo) and is_binary(work_request_id) and is_map(attrs) do
    case nonblank_or_nil(Map.get(attrs, "delivery_repo")) do
      nil ->
        {:ok, Map.delete(attrs, "delivery_repo")}

      delivery_repo ->
        with {:ok, work_request} <- Repository.get(repo, work_request_id),
             attrs = Map.put(attrs, "delivery_repo", delivery_repo),
             :ok <- validate(repo, work_request, attrs) do
          {:ok, attrs}
        end
    end
  end

  @spec validate(module(), WorkRequest.t(), PlannedSlice.t() | map()) :: :ok | {:error, term()}
  def validate(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice) do
    validate(repo, work_request, %{
      "delivery_repo" => PlannedSlice.delivery_repo(work_request, planned_slice),
      "target_base_branch" => planned_slice.target_base_branch
    })
  end

  def validate(repo, %WorkRequest{} = work_request, attrs) when is_atom(repo) and is_map(attrs) do
    case {nonblank_or_nil(Map.get(attrs, "delivery_repo")), nonblank_or_nil(Map.get(attrs, "target_base_branch"))} do
      {nil, _target_base_branch} ->
        :ok

      {delivery_repo, _target_base_branch} when delivery_repo == work_request.repo ->
        :ok

      {delivery_repo, target_base_branch} when is_binary(delivery_repo) and is_binary(target_base_branch) ->
        validate_secondary_delivery_scope(repo, work_request, delivery_repo, target_base_branch)

      {_delivery_repo, _target_base_branch} ->
        :ok
    end
  end

  defp validate_secondary_delivery_scope(repo, %WorkRequest{} = work_request, delivery_repo, target_base_branch) do
    with {:ok, repo_scopes} <- Repository.list_repo_scopes(repo, work_request.id) do
      if Enum.any?(repo_scopes, &repo_scope_matches_delivery?(&1, delivery_repo, target_base_branch)) do
        :ok
      else
        {:error, :planned_slice_delivery_scope_out_of_scope}
      end
    end
  end

  defp repo_scope_matches_delivery?(%RepoScope{repo: repo, base_branch: nil}, delivery_repo, _target_base_branch),
    do: repo == delivery_repo

  defp repo_scope_matches_delivery?(%RepoScope{repo: repo, base_branch: base_branch}, delivery_repo, target_base_branch),
    do: repo == delivery_repo and base_branch == target_base_branch

  defp nonblank_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp nonblank_or_nil(_value), do: nil
end
