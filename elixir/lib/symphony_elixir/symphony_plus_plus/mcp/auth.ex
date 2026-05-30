defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Auth do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.GrantScope
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session

  @type denial :: :unauthorized | :forbidden | {:service_unavailable, term()} | {:unauthorized, term()}

  @spec require_session(Session.t() | nil) :: {:ok, Session.t()} | {:error, denial()}
  def require_session(%Session{} = session), do: {:ok, session}
  def require_session(nil), do: {:error, :unauthorized}
  def require_session(_session), do: {:error, {:unauthorized, :invalid_session}}

  @spec require_session(Session.t() | nil, module()) :: {:ok, Session.t()} | {:error, denial()}
  def require_session(%Session{} = session, repo) when is_atom(repo) do
    grant_id = session.assignment.grant_id

    case fetch_grant(repo, grant_id) do
      {:ok, %AccessGrant{} = grant} ->
        with :ok <- require_proof(session, grant),
             :ok <- AccessGrantService.require_live_package_authority(repo, grant),
             {:ok, scopes} <- load_grant_scopes(repo, grant),
             {:ok, live_session} <-
               Session.from_grant(grant, DateTime.utc_now(:microsecond),
                 proof_hash: session.proof_hash,
                 scopes: scopes
               ) do
          {:ok, live_session}
        else
          {:error, {:scope_lookup_failed, reason}} -> {:error, {:service_unavailable, {:scope_lookup_failed, reason}}}
          {:error, reason} -> {:error, {:unauthorized, reason}}
        end

      {:ok, unexpected} ->
        {:error, {:service_unavailable, {:unexpected_grant_lookup_result, term_type(unexpected)}}}

      {:error, :not_found} ->
        {:error, {:unauthorized, :not_found}}

      {:error, reason} ->
        {:error, {:service_unavailable, {:grant_lookup_failed, reason}}}
    end
  rescue
    error -> {:error, {:service_unavailable, {:revalidation_failed, error.__struct__}}}
  end

  def require_session(nil, repo) when is_atom(repo), do: {:error, :unauthorized}

  def require_session(_session, repo) when is_atom(repo), do: {:error, {:unauthorized, :invalid_session}}

  defp fetch_grant(repo, grant_id) do
    fetch = &AccessGrantRepository.get/2
    fetch.(repo, grant_id)
  end

  defp load_grant_scopes(repo, %AccessGrant{} = grant) do
    case AccessGrantRepository.list_scopes(repo, grant.id) do
      {:ok, scope_rows} -> {:ok, Enum.map(scope_rows, &GrantScope.to_authorization_scope/1)}
      {:error, reason} -> {:error, {:scope_lookup_failed, reason}}
    end
  end

  defp require_proof(%Session{proof_hash: proof_hash}, %AccessGrant{secret_hash: secret_hash})
       when is_binary(proof_hash) and is_binary(secret_hash) do
    if Plug.Crypto.secure_compare(proof_hash, secret_hash) do
      :ok
    else
      {:error, :invalid_session_proof}
    end
  end

  defp require_proof(_session, _grant), do: {:error, :missing_session_proof}

  defp term_type(%module{}), do: module
  defp term_type(term) when is_tuple(term), do: :tuple
  defp term_type(term) when is_map(term), do: :map
  defp term_type(term) when is_list(term), do: :list
  defp term_type(term) when is_atom(term), do: :atom
  defp term_type(term) when is_binary(term), do: :binary
  defp term_type(_term), do: :term

  @spec require_work_package(Session.t() | nil, String.t(), module()) :: {:ok, Session.t()} | {:error, denial()}
  def require_work_package(session, work_package_id, repo) when is_binary(work_package_id) and is_atom(repo) do
    with {:ok, %Session{} = session} <- require_session(session, repo) do
      if Session.work_package_id(session) == work_package_id do
        {:ok, session}
      else
        {:error, :forbidden}
      end
    end
  end
end
