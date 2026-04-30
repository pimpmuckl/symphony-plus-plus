defmodule SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
  alias SymphonyElixir.SymphonyPlusPlus.Policies.Templates
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type error ::
          Repository.error()
          | StateMachine.error()
          | :unknown_policy_template

  @spec transition(Repository.repo(), String.t(), String.t(), StateMachine.actor()) ::
          {:ok, WorkPackage.t()} | {:error, error()}
  def transition(repo, work_package_id, next_status, actor)
      when is_atom(repo) and is_binary(work_package_id) and is_binary(next_status) and is_map(actor) do
    with {:ok, work_package} <- Repository.get(repo, work_package_id),
         :ok <- StateMachine.validate_transition(work_package, next_status, actor) do
      # SYMPP-P1-005 owns durable transition event recording; keep this hook narrow.
      Repository.update(repo, work_package_id, %{status: next_status})
    end
  end

  @spec policy_for(WorkPackage.t()) :: {:ok, Templates.template()} | {:error, :unknown_policy_template}
  def policy_for(%WorkPackage{kind: kind}), do: Templates.expand(kind)

  @spec policy_for(Repository.repo(), String.t()) ::
          {:ok, Templates.template()} | {:error, Repository.error() | :unknown_policy_template}
  def policy_for(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    with {:ok, work_package} <- Repository.get(repo, work_package_id) do
      policy_for(work_package)
    end
  end
end
