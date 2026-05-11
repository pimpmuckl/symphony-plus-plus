defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type error :: Repository.error()

  @spec create(Repository.repo(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def create(repo, attrs), do: Repository.create(repo, attrs)

  @spec get(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def get(repo, id), do: Repository.get(repo, id)

  @spec list(Repository.repo()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  @spec list(Repository.repo(), map()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  def list(repo, filters \\ %{}), do: Repository.list(repo, filters)

  @spec update(Repository.repo(), String.t(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def update(repo, id, attrs), do: Repository.update(repo, id, attrs)

  @spec update_status(Repository.repo(), String.t(), String.t(), String.t()) ::
          {:ok, WorkRequest.t()} | {:error, error()}
  def update_status(repo, id, current_status, next_status), do: Repository.update_status(repo, id, current_status, next_status)
end
