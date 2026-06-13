defmodule SymphonyElixir.SymphonyPlusPlus.MCP.LocalClaimLeases do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService

  @spec ensure(module(), String.t(), map(), pos_integer(), String.t()) ::
          {:ok, ClaimLease.t(), :created | :heartbeat | :reclaimed} | {:error, term()}
  def ensure(repo, work_package_id, actor, stale_after_ms, stale_reason)
      when is_atom(repo) and is_binary(work_package_id) and is_map(actor) and is_integer(stale_after_ms) and
             is_binary(stale_reason) do
    case ClaimLeaseService.current_for_work_package(repo, work_package_id) do
      {:ok, %ClaimLease{} = lease} -> renew(repo, work_package_id, lease, actor, stale_after_ms, stale_reason)
      {:error, :not_found} -> claim_new(repo, work_package_id, actor, stale_after_ms, stale_reason)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec worker_actor(map()) :: map()
  def worker_actor(claim) when is_map(claim) do
    owner_id = actor_hash(["worker", claim.work_package_id, claim.claimed_by] |> Enum.join("\0"))
    actor(claim.claimed_by, owner_id)
  end

  @spec architect_actor(map()) :: map()
  def architect_actor(claim) when is_map(claim) do
    owner_id =
      ["architect", claim.work_request_id, claim.architect_anchor_work_package_id, claim.claimed_by]
      |> Enum.join("\0")
      |> actor_hash()

    actor(claim.claimed_by, owner_id)
  end

  @spec reclaim_opts(String.t(), pos_integer()) :: keyword()
  def reclaim_opts(reason, stale_after_ms) when is_binary(reason) and is_integer(stale_after_ms) do
    [
      reason: reason,
      current_stale_after_ms: stale_after_ms,
      inherit_access_grant?: false,
      stale_after_ms: stale_after_ms
    ]
  end

  @spec actor_hash(iodata()) :: String.t()
  def actor_hash(material), do: Base.url_encode64(:crypto.hash(:sha256, material), padding: false)

  defp renew(repo, work_package_id, %ClaimLease{} = lease, actor, stale_after_ms, stale_reason) do
    now = DateTime.utc_now(:microsecond)

    cond do
      lease.status == "paused" ->
        {:error, :claim_lease_paused}

      ClaimLease.stale?(lease, now, stale_after_ms) ->
        reclaim(repo, work_package_id, actor, stale_after_ms, stale_reason)

      same_owner?(lease, actor) and lease.status == "active" ->
        heartbeat(repo, work_package_id, lease, actor, stale_after_ms, stale_reason)

      same_owner?(lease, actor) ->
        {:error, :claim_lease_not_active}

      true ->
        {:error, :claim_lease_active_for_other_actor}
    end
  end

  defp heartbeat(repo, work_package_id, %ClaimLease{} = lease, actor, stale_after_ms, stale_reason) do
    case ClaimLeaseService.heartbeat(repo, lease.id, stale_after_ms: stale_after_ms) do
      {:ok, %ClaimLease{} = renewed} -> {:ok, renewed, :heartbeat}
      {:error, :claim_stale} -> reclaim(repo, work_package_id, actor, stale_after_ms, stale_reason)
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_new(repo, work_package_id, actor, stale_after_ms, stale_reason) do
    case ClaimLeaseService.claim(repo, work_package_id, actor, stale_after_ms: stale_after_ms) do
      {:ok, %ClaimLease{} = lease} -> {:ok, lease, :created}
      {:error, :active_claim_exists} -> renew_current(repo, work_package_id, actor, stale_after_ms, stale_reason)
      {:error, reason} -> {:error, reason}
    end
  end

  defp renew_current(repo, work_package_id, actor, stale_after_ms, stale_reason) do
    case ClaimLeaseService.current_for_work_package(repo, work_package_id) do
      {:ok, %ClaimLease{} = lease} ->
        if same_owner?(lease, actor),
          do: renew(repo, work_package_id, lease, actor, stale_after_ms, stale_reason),
          else: {:error, :active_claim_exists}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reclaim(repo, work_package_id, actor, stale_after_ms, stale_reason) do
    case ClaimLeaseService.reclaim_stale(repo, work_package_id, actor, reclaim_opts(stale_reason, stale_after_ms)) do
      {:ok, %ClaimLease{} = lease} -> {:ok, lease, :reclaimed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp same_owner?(%ClaimLease{} = lease, actor) when is_map(actor) do
    lease.actor_kind == Map.get(actor, "actor_kind") and
      lease.actor_display_name == Map.get(actor, "actor_display_name") and
      actor_id_match?(lease.actor_id, Map.get(actor, "actor_id"))
  end

  defp actor(display_name, owner_id) do
    %{
      "actor_kind" => "agent",
      "actor_id" => "local:" <> owner_id,
      "actor_display_name" => display_name
    }
  end

  defp actor_id_match?(actor_id, actor_id) when is_binary(actor_id), do: true

  defp actor_id_match?(lease_actor_id, actor_id) when is_binary(lease_actor_id) and is_binary(actor_id) do
    String.starts_with?(lease_actor_id, actor_id <> ":")
  end

  defp actor_id_match?(_lease_actor_id, _actor_id), do: false
end
