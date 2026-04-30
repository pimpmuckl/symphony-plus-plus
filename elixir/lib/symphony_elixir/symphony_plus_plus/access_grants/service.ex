defmodule SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey

  @default_lifetime_seconds 86_400
  @default_worker_capabilities ["worker:claim"]

  @type minted_grant :: %{grant: AccessGrant.t(), work_key: WorkKey.t()}
  @type error :: Repository.error()

  @spec mint_worker_grant(Repository.repo(), String.t(), keyword() | map()) ::
          {:ok, minted_grant()} | {:error, error()}
  def mint_worker_grant(repo, work_package_id, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and (is_list(opts) or is_map(opts)) do
    opts = normalize_options(opts)
    now = option(opts, :now, DateTime.utc_now(:microsecond))
    expires_at = option(opts, :expires_at, DateTime.add(now, @default_lifetime_seconds, :second))
    capabilities = option(opts, :capabilities, @default_worker_capabilities)
    work_key = WorkKey.generate()

    with :ok <- Repository.validate_work_package(repo, work_package_id),
         {:ok, grant} <-
           Repository.create(repo, %{
             work_package_id: work_package_id,
             display_key: work_key.display_key,
             secret_hash: WorkKey.secret_hash(work_key.secret),
             grant_role: "worker",
             capabilities: capabilities,
             expires_at: DateTime.truncate(expires_at, :microsecond)
           }) do
      {:ok, %{grant: grant, work_key: work_key}}
    end
  end

  @spec claim(Repository.repo(), String.t(), keyword() | map()) :: {:ok, Assignment.t()} | {:error, error()}
  def claim(repo, secret, opts \\ []) when is_atom(repo) and is_binary(secret) and (is_list(opts) or is_map(opts)) do
    opts = normalize_options(opts)
    now = option(opts, :now, DateTime.utc_now(:microsecond))

    Repository.claim(repo, secret, %{claimed_by: option(opts, :claimed_by, nil)}, now)
  end

  @spec revoke(Repository.repo(), String.t(), keyword() | map()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def revoke(repo, id, opts \\ []) when is_atom(repo) and is_binary(id) and (is_list(opts) or is_map(opts)) do
    opts = normalize_options(opts)
    Repository.revoke(repo, id, option(opts, :now, DateTime.utc_now(:microsecond)))
  end

  defp normalize_options(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_options(opts) when is_map(opts), do: opts

  defp option(opts, key, default) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key)) || default
  end
end
