defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type error :: Repository.error()

  @spec create(Repository.repo(), map()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def create(repo, attrs), do: Repository.create(repo, attrs)

  @spec get(Repository.repo(), String.t()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def get(repo, id), do: Repository.get(repo, id)

  @spec list(Repository.repo()) :: {:ok, [WorkPackage.t()]} | {:error, error()}
  def list(repo), do: Repository.list(repo)

  @spec update(Repository.repo(), String.t(), map()) :: {:ok, WorkPackage.t()} | {:error, error()}
  def update(repo, id, attrs), do: Repository.update(repo, id, attrs)
end
