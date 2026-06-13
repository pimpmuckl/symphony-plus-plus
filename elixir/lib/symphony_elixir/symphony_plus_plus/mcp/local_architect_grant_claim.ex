defmodule SymphonyElixir.SymphonyPlusPlus.MCP.LocalArchitectGrantClaim do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  @type grant_action :: :claimed | :reconnected | :recovered
  @type grant_validator :: (AccessGrant.t() -> :ok | {:error, term()})

  @spec claim(module(), WorkPackage.t(), map(), :created | :heartbeat | :reclaimed, grant_validator()) ::
          {:ok, AccessGrant.t(), grant_action()} | {:error, term()}
  def claim(repo, %WorkPackage{} = anchor, claim, lease_action, validate_grant)
      when is_atom(repo) and is_map(claim) and lease_action in [:created, :heartbeat, :reclaimed] and
             is_function(validate_grant, 1) do
    now = DateTime.utc_now(:microsecond)
    do_claim(repo, anchor, claim, now, active_grant_ids(repo, anchor, claim, now), lease_action, validate_grant)
  end

  @spec claim(module(), WorkPackage.t(), map(), :created | :heartbeat | :reclaimed) ::
          {:ok, AccessGrant.t(), :claimed | :reconnected | :recovered} | {:error, term()}
  def claim(repo, %WorkPackage{} = anchor, claim, lease_action)
      when is_atom(repo) and is_map(claim) and lease_action in [:created, :heartbeat, :reclaimed] do
    claim(repo, anchor, claim, lease_action, fn _grant -> :ok end)
  end

  defp do_claim(repo, %WorkPackage{} = anchor, claim, %DateTime{} = now, existing_grant_ids, lease_action, validate_grant) do
    case claim_grant(repo, anchor, claim, now) do
      {:ok, %AccessGrant{} = grant} ->
        {:ok, grant, grant_action(grant, existing_grant_ids)}

      {:error, :already_claimed} when lease_action in [:created, :reclaimed] ->
        recover_released_handoff_owner(repo, anchor, claim, now, validate_grant)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_grant(repo, %WorkPackage{} = anchor, claim, %DateTime{} = now) do
    AccessGrantService.claim_local_architect_grant(repo, anchor.id, anchor.phase_id,
      claimed_by: claim.claimed_by,
      scope_repo: claim.repo,
      scope_base_branch: claim.base_branch,
      work_request_id: claim.work_request_id,
      now: now
    )
  end

  defp active_grant_ids(repo, %WorkPackage{} = anchor, claim, %DateTime{} = now) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^anchor.id,
        where: grant.phase_id == ^anchor.phase_id,
        where: grant.grant_role == "architect",
        where: grant.scope_repo == ^claim.repo,
        where: grant.scope_base_branch == ^claim.base_branch,
        where: grant.claimed_by == ^claim.claimed_by,
        where: not is_nil(grant.claimed_at),
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        select: grant.id
      )

    repo.all(query)
  end

  defp recover_released_handoff_owner(repo, %WorkPackage{} = anchor, claim, %DateTime{} = now, validate_grant) do
    repo.transaction(fn ->
      with id when is_binary(id) <- released_handoff_owner_candidate_id(repo, anchor, claim, now),
           {1, _rows} <- recover_released_handoff_owner_id(repo, id, claim, now),
           {:ok, %AccessGrant{} = grant} <- claim_grant(repo, anchor, claim, now),
           :ok <- validate_grant.(grant),
           :ok <- WorkRequestRepository.clear_completion_for_work_package(repo, anchor.id) do
        {:ok, grant, :recovered}
      else
        nil -> repo.rollback(:already_claimed)
        {0, _rows} -> repo.rollback(:already_claimed)
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:ok, %AccessGrant{} = grant, action}} -> {:ok, grant, action}
      {:error, reason} -> {:error, reason}
    end
  end

  defp released_handoff_owner_candidate_id(repo, %WorkPackage{} = anchor, claim, %DateTime{} = now) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^anchor.id,
        where: grant.phase_id == ^anchor.phase_id,
        where: grant.grant_role == "architect",
        where: grant.scope_repo == ^claim.repo,
        where: grant.scope_base_branch == ^claim.base_branch,
        where: not is_nil(grant.claimed_at),
        where: grant.claimed_by != ^claim.claimed_by,
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        order_by: [desc: grant.claimed_at, desc: grant.updated_at, asc: grant.id],
        select: grant.id,
        limit: 1
      )

    repo.one(query)
  end

  defp recover_released_handoff_owner_id(repo, id, claim, %DateTime{} = now) when is_binary(id) do
    query = from(grant in AccessGrant, where: grant.id == ^id, where: grant.claimed_by != ^claim.claimed_by)

    repo.update_all(query, set: [claimed_at: now, claimed_by: claim.claimed_by, updated_at: now])
  end

  defp grant_action(%AccessGrant{id: id}, existing_grant_ids) when is_binary(id) do
    if id in existing_grant_ids, do: :reconnected, else: :claimed
  end
end
