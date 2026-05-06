defmodule SymphonyElixir.SymphonyPlusPlus.Phases.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository

  @type error :: Repository.error()

  @spec create(Repository.repo(), map()) :: {:ok, Phase.t()} | {:error, error()}
  def create(repo, attrs), do: Repository.create(repo, attrs)

  @spec get(Repository.repo(), String.t()) :: {:ok, Phase.t()} | {:error, error()}
  def get(repo, id), do: Repository.get(repo, id)

  @spec list(Repository.repo()) :: {:ok, [Phase.t()]} | {:error, error()}
  def list(repo), do: Repository.list(repo)
end
