defmodule SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
  alias SymphonyElixir.SymphonyPlusPlus.Policies.Templates
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type error ::
          Repository.error()
          | AccessGrantRepository.error()
          | StateMachine.error()
          | :actor_scope_mismatch
          | :unknown_policy_template

  @spec transition(Repository.repo(), String.t(), String.t(), StateMachine.actor()) ::
          {:ok, WorkPackage.t()} | {:error, error()}
  def transition(repo, work_package_id, next_status, actor)
      when is_atom(repo) and is_binary(work_package_id) and is_binary(next_status) and is_map(actor) do
    with {:ok, work_package} <- Repository.get(repo, work_package_id) do
      transition(repo, work_package, next_status, actor)
    end
  end

  @spec transition(Repository.repo(), WorkPackage.t(), String.t(), StateMachine.actor()) ::
          {:ok, WorkPackage.t()} | {:error, error()}
  def transition(repo, %WorkPackage{} = work_package, next_status, actor)
      when is_atom(repo) and is_binary(next_status) and is_map(actor) do
    with {:ok, actor} <- verified_actor(repo, work_package, actor),
         :ok <- StateMachine.validate_transition(work_package, next_status, actor) do
      # SYMPP-P1-005 owns durable transition event recording; keep this hook narrow.
      Repository.update_status(repo, work_package.id, work_package.status, next_status)
    end
  end

  @spec policy_for(WorkPackage.t()) :: {:ok, Templates.template()} | {:error, :unknown_policy_template}
  def policy_for(%WorkPackage{} = work_package), do: Templates.expand(policy_key(work_package))

  defp policy_key(%WorkPackage{policy_template: policy_template}) when is_binary(policy_template) and policy_template != "" do
    policy_template
  end

  defp policy_key(%WorkPackage{kind: kind}), do: kind

  @spec policy_for(Repository.repo(), String.t()) ::
          {:ok, Templates.template()} | {:error, Repository.error() | :unknown_policy_template}
  def policy_for(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    with {:ok, work_package} <- Repository.get(repo, work_package_id) do
      policy_for(work_package)
    end
  end

  defp verified_actor(repo, %WorkPackage{} = work_package, actor) do
    case grant_id(actor) do
      grant_id when is_binary(grant_id) -> verified_grant_actor(repo, work_package, grant_id)
      _missing_grant_id -> {:error, :actor_scope_mismatch}
    end
  end

  defp verified_grant_actor(repo, %WorkPackage{} = work_package, grant_id) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id),
         :ok <- validate_grant(work_package, grant) do
      {:ok, %{grant_role: grant.grant_role, capabilities: grant.capabilities, work_package_id: grant.work_package_id}}
    end
  end

  defp validate_grant(%WorkPackage{} = work_package, %AccessGrant{} = grant) do
    cond do
      grant.work_package_id != work_package.id -> {:error, :actor_scope_mismatch}
      is_nil(grant.claimed_at) -> {:error, :actor_scope_mismatch}
      not is_nil(grant.revoked_at) -> {:error, :actor_scope_mismatch}
      expired?(grant.expires_at, DateTime.utc_now(:microsecond)) -> {:error, :actor_scope_mismatch}
      true -> :ok
    end
  end

  defp expired?(nil, %DateTime{}), do: false
  defp expired?(%DateTime{} = expires_at, %DateTime{} = now), do: DateTime.compare(expires_at, now) != :gt

  defp grant_id(actor), do: Map.get(actor, :grant_id) || Map.get(actor, "grant_id")
end
