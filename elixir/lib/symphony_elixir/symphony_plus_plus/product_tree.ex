defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Projection
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Repository

  @spec tree_for_work_request(module(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate tree_for_work_request(repo, work_request_id), to: Repository

  @spec create_node(module(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate create_node(repo, attrs), to: Repository

  @spec upsert_node(module(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate upsert_node(repo, attrs), to: Repository

  @spec create_slice_link(module(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate create_slice_link(repo, attrs), to: Repository

  @spec move_slice_link(module(), map()) :: {:ok, term() | nil} | {:error, term()}
  defdelegate move_slice_link(repo, attrs), to: Repository

  @spec create_dependency_edge(module(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate create_dependency_edge(repo, attrs), to: Repository

  @spec record_revision(module(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate record_revision(repo, work_request_id, attrs), to: Repository

  @spec project(module(), String.t(), [map()]) :: map()
  defdelegate project(repo, work_request_id, planned_slice_payloads), to: Projection
end
