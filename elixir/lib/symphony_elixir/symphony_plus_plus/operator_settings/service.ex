defmodule SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings

  @type error :: Repository.error()

  @spec get(Repository.repo()) :: {:ok, Settings.t()} | {:error, error()}
  def get(repo), do: Repository.get(repo)

  @spec update(Repository.repo(), map()) :: {:ok, Settings.t()} | {:error, error()}
  def update(repo, attrs), do: Repository.update(repo, attrs)
end
