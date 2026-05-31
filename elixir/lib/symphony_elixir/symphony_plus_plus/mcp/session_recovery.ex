defmodule SymphonyElixir.SymphonyPlusPlus.MCP.SessionRecovery do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Auth, Config, Repository, Server, Session, SessionBinding}

  @ttl_ms 86_400_000
  @lease_stale_after_ms 86_400_000
  @local_claim_tools ["claim_local_assignment", "claim_local_architect_assignment"]
  @session_claim_tools ["claim_work_key", "claim_private_handoff" | @local_claim_tools]

  @spec remember(Config.t(), String.t(), String.t(), term(), Server.t(), term()) :: :ok
  def remember(%Config{mode: :http, repo: repo} = config, client_key, state_key, payload, %Server{} = server, response)
      when is_atom(repo) and is_binary(client_key) and is_binary(state_key) do
    case Repository.ensure_migrated(repo) do
      :ok ->
        cleanup_stale(repo)

        case remember_action(config, client_key, state_key, payload, server, response) do
          {:upsert, attrs} -> upsert(repo, attrs)
          {:touch, id, now} -> touch(repo, id, now)
          :skip -> :ok
        end

      _error ->
        :ok
    end
  rescue
    _error -> :ok
  end

  def remember(%Config{}, _client_key, _state_key, _payload, %Server{}, _response), do: :ok

  @spec rehydrate(Config.t(), String.t(), String.t()) :: {:ok, Server.t()} | :not_found
  def rehydrate(%Config{mode: :http, repo: repo} = config, client_key, state_key)
      when is_atom(repo) and is_binary(client_key) and is_binary(state_key) do
    with :ok <- Repository.ensure_migrated(repo),
         :ok <- cleanup_stale(repo),
         {:ok, %SessionBinding{} = binding} <- get_binding(repo, client_key, state_key),
         :ok <- require_fresh(binding) do
      case recover_session(repo, binding) do
        {:ok, %Session{} = session} ->
          {:ok, Server.new(config, initialized: true, local_daemon_trusted: config.local_daemon_trusted, session: session, state_key: state_key)}

        {:error, _reason} ->
          {:ok, Server.new(config, initialized: true, local_daemon_trusted: config.local_daemon_trusted, state_key: state_key)}
      end
    else
      _error -> :not_found
    end
  rescue
    _error -> :not_found
  end

  def rehydrate(%Config{}, _client_key, _state_key), do: :not_found

  defp remember_action(_config, client_key, state_key, payload, %Server{initialized: true, session: nil}, _response) do
    if initialize_request?(payload) do
      remember_unbound_initialized(client_key, state_key, nil)
    else
      {:touch, SessionBinding.binding_id(client_key, state_key), now()}
    end
  end

  defp remember_action(config, client_key, state_key, payload, %Server{initialized: true, session: %Session{} = session}, response) do
    tool_name = tool_call_name(payload)

    cond do
      tool_name in @local_claim_tools ->
        remember_local_claim(config, client_key, state_key, session, response, tool_name)

      tool_name in @session_claim_tools ->
        remember_nonrecoverable_claim(client_key, state_key, session, tool_name)

      true ->
        {:touch, SessionBinding.binding_id(client_key, state_key), now()}
    end
  end

  defp remember_action(_config, _client_key, _state_key, _payload, %Server{}, _response), do: :skip

  defp remember_local_claim(%Config{repo: repo}, client_key, state_key, %Session{} = session, response, tool_name) do
    case local_claim_lease(repo, session, response) do
      {:ok, %ClaimLease{} = lease} ->
        now = now()

        {:upsert,
         client_key
         |> session_attrs(state_key, session, now)
         |> Map.merge(%{
           recoverable: true,
           recovery_kind: tool_name,
           claim_lease_id: lease.id,
           actor_kind: lease.actor_kind,
           actor_id: lease.actor_id,
           actor_display_name: lease.actor_display_name,
           last_rehydrated_at: nil
         })}

      _error ->
        remember_unbound_initialized(client_key, state_key, tool_name)
    end
  end

  defp local_claim_lease(repo, %Session{} = session, _response), do: current_session_claim_lease(repo, session)

  defp current_session_claim_lease(repo, %Session{assignment: %{work_package_id: work_package_id, claimed_by: claimed_by}})
       when is_binary(work_package_id) and is_binary(claimed_by) do
    with {:ok, %ClaimLease{} = lease} <- ClaimLeaseService.current_for_work_package(repo, work_package_id),
         :ok <- require_lease_claimed_by(lease, claimed_by) do
      {:ok, lease}
    end
  end

  defp current_session_claim_lease(_repo, %Session{}), do: {:error, :missing_claim_lease_scope}

  defp remember_nonrecoverable_claim(client_key, state_key, %Session{} = session, tool_name) do
    now = now()

    {:upsert,
     client_key
     |> session_attrs(state_key, session, now)
     |> Map.merge(%{
       recoverable: false,
       recovery_kind: tool_name,
       claim_lease_id: nil,
       actor_kind: nil,
       actor_id: nil,
       actor_display_name: nil,
       last_rehydrated_at: nil
     })}
  end

  defp remember_unbound_initialized(client_key, state_key, recovery_kind) do
    now = now()

    {:upsert,
     client_key
     |> base_attrs(state_key, now)
     |> Map.merge(%{
       initialized: true,
       recoverable: false,
       recovery_kind: recovery_kind,
       access_grant_id: nil,
       claim_lease_id: nil,
       work_package_id: nil,
       phase_id: nil,
       grant_role: nil,
       claimed_by: nil,
       actor_kind: nil,
       actor_id: nil,
       actor_display_name: nil,
       last_rehydrated_at: nil
     })}
  end

  defp recover_session(_repo, %SessionBinding{recoverable: false}), do: {:error, :claim_required}

  defp recover_session(repo, %SessionBinding{} = binding) do
    with {:ok, %AccessGrant{} = grant} <- AccessGrantRepository.get(repo, binding.access_grant_id),
         :ok <- require_grant_matches_binding(grant, binding),
         :ok <- AccessGrantService.require_live_package_authority(repo, grant),
         {:ok, %ClaimLease{} = lease} <- recover_claim_lease(repo, binding),
         {:ok, %Session{} = session} <- Auth.session_from_grant(repo, grant, proof_hash: grant.secret_hash),
         :ok <- require_session_matches_binding(session, binding) do
      mark_rehydrated(repo, binding, lease)
      {:ok, session}
    else
      _error -> {:error, :reclaim_required}
    end
  end

  defp recover_claim_lease(repo, %SessionBinding{work_package_id: work_package_id} = binding) when is_binary(work_package_id) do
    with {:ok, %ClaimLease{} = lease} <- ClaimLeaseService.current_for_work_package(repo, work_package_id),
         :ok <- require_lease_matches_binding(lease, binding) do
      renew_or_reclaim_lease(repo, lease, binding)
    end
  end

  defp recover_claim_lease(_repo, %SessionBinding{}), do: {:error, :missing_work_package_id}

  defp renew_or_reclaim_lease(repo, %ClaimLease{status: "active"} = lease, %SessionBinding{} = binding) do
    if ClaimLease.stale?(lease, now()) do
      reclaim_lease(repo, lease.work_package_id, binding, "mcp_session_rehydrate_stale")
    else
      case ClaimLeaseService.heartbeat(repo, lease.id, stale_after_ms: @lease_stale_after_ms) do
        {:ok, %ClaimLease{} = renewed} -> {:ok, renewed}
        {:error, :claim_stale} -> reclaim_lease(repo, lease.work_package_id, binding, "mcp_session_rehydrate_stale")
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp renew_or_reclaim_lease(_repo, %ClaimLease{}, %SessionBinding{}), do: {:error, :claim_lease_not_active}

  defp reclaim_lease(repo, work_package_id, %SessionBinding{} = binding, reason) do
    ClaimLeaseService.reclaim_stale(repo, work_package_id, actor(binding),
      reason: reason,
      stale_after_ms: @lease_stale_after_ms
    )
  end

  defp require_grant_matches_binding(%AccessGrant{} = grant, %SessionBinding{} = binding) do
    cond do
      grant.id != binding.access_grant_id -> {:error, :grant_mismatch}
      grant.work_package_id != binding.work_package_id -> {:error, :work_package_mismatch}
      grant.phase_id != binding.phase_id -> {:error, :phase_mismatch}
      grant.grant_role != binding.grant_role -> {:error, :role_mismatch}
      grant.claimed_by != binding.claimed_by -> {:error, :claim_owner_mismatch}
      true -> :ok
    end
  end

  defp require_session_matches_binding(%Session{} = session, %SessionBinding{} = binding) do
    cond do
      session.assignment.grant_id != binding.access_grant_id -> {:error, :grant_mismatch}
      session.assignment.work_package_id != binding.work_package_id -> {:error, :work_package_mismatch}
      session.assignment.phase_id != binding.phase_id -> {:error, :phase_mismatch}
      session.assignment.grant_role != binding.grant_role -> {:error, :role_mismatch}
      session.assignment.claimed_by != binding.claimed_by -> {:error, :claim_owner_mismatch}
      true -> :ok
    end
  end

  defp require_lease_matches_binding(%ClaimLease{} = lease, %SessionBinding{} = binding) do
    cond do
      lease.work_package_id != binding.work_package_id -> {:error, :work_package_mismatch}
      lease.actor_kind != binding.actor_kind -> {:error, :actor_mismatch}
      lease.actor_id != binding.actor_id -> {:error, :actor_mismatch}
      lease.actor_display_name != binding.actor_display_name -> {:error, :actor_mismatch}
      true -> :ok
    end
  end

  defp require_lease_claimed_by(%ClaimLease{actor_display_name: claimed_by}, claimed_by) when is_binary(claimed_by), do: :ok
  defp require_lease_claimed_by(%ClaimLease{}, _claimed_by), do: {:error, :claim_owner_mismatch}

  defp mark_rehydrated(repo, %SessionBinding{} = binding, %ClaimLease{} = lease) do
    now = now()

    upsert(repo, %{
      id: binding.id,
      client_key_hash: binding.client_key_hash,
      initialized: true,
      recoverable: true,
      recovery_kind: binding.recovery_kind,
      access_grant_id: binding.access_grant_id,
      claim_lease_id: lease.id,
      work_package_id: binding.work_package_id,
      phase_id: binding.phase_id,
      grant_role: binding.grant_role,
      claimed_by: binding.claimed_by,
      actor_kind: lease.actor_kind,
      actor_id: lease.actor_id,
      actor_display_name: lease.actor_display_name,
      last_seen_at: now,
      last_rehydrated_at: now
    })
  end

  defp upsert(repo, attrs) do
    attrs = normalize_datetimes(attrs)

    case repo.get(SessionBinding, Map.fetch!(attrs, :id)) do
      nil -> %SessionBinding{}
      %SessionBinding{} = binding -> binding
    end
    |> SessionBinding.changeset(attrs)
    |> then(fn changeset ->
      if changeset.data.__meta__.state == :built, do: repo.insert(changeset), else: repo.update(changeset)
    end)
    |> case do
      {:ok, %SessionBinding{}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp touch(repo, id, now) do
    case repo.get(SessionBinding, id) do
      %SessionBinding{} = binding ->
        binding
        |> SessionBinding.changeset(%{last_seen_at: now})
        |> repo.update()

      nil ->
        :ok
    end

    :ok
  end

  defp get_binding(repo, client_key, state_key) do
    case repo.get(SessionBinding, SessionBinding.binding_id(client_key, state_key)) do
      %SessionBinding{} = binding -> {:ok, binding}
      nil -> {:error, :not_found}
    end
  end

  defp cleanup_stale(repo) do
    cutoff = DateTime.add(now(), -@ttl_ms, :millisecond)

    repo.delete_all(
      from(binding in SessionBinding,
        where: binding.last_seen_at < ^cutoff
      )
    )

    :ok
  rescue
    _error -> :ok
  end

  defp require_fresh(%SessionBinding{last_seen_at: %DateTime{} = last_seen_at}) do
    if DateTime.diff(now(), last_seen_at, :millisecond) <= @ttl_ms do
      :ok
    else
      {:error, :stale_binding}
    end
  end

  defp require_fresh(%SessionBinding{}), do: {:error, :stale_binding}

  defp session_attrs(client_key, state_key, %Session{} = session, %DateTime{} = now) do
    assignment = session.assignment

    base_attrs(client_key, state_key, now)
    |> Map.merge(%{
      initialized: true,
      access_grant_id: assignment.grant_id,
      work_package_id: assignment.work_package_id,
      phase_id: assignment.phase_id,
      grant_role: assignment.grant_role,
      claimed_by: assignment.claimed_by
    })
  end

  defp base_attrs(client_key, state_key, %DateTime{} = now) do
    %{
      id: SessionBinding.binding_id(client_key, state_key),
      client_key_hash: SessionBinding.client_key_hash(client_key),
      last_seen_at: now
    }
  end

  defp actor(%SessionBinding{} = binding) do
    %{
      "actor_kind" => binding.actor_kind,
      "actor_id" => binding.actor_id,
      "actor_display_name" => binding.actor_display_name
    }
  end

  defp initialize_request?(%{"method" => "initialize"}), do: true
  defp initialize_request?(_payload), do: false

  defp tool_call_name(%{"method" => "tools/call", "params" => %{"name" => name}}) when is_binary(name), do: name
  defp tool_call_name(_payload), do: nil

  defp normalize_datetimes(attrs) do
    Map.new(attrs, fn
      {key, %DateTime{} = value} -> {key, DateTime.truncate(value, :microsecond)}
      pair -> pair
    end)
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
