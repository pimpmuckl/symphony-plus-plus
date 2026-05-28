defmodule SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  @type repo :: module()

  @type error ::
          :already_claimed
          | :architect_grant_required
          | :database_busy
          | :display_key_only
          | :expired
          | :id_already_exists
          | :invalid_scope
          | :invalid_secret
          | :missing_claim_identity
          | :not_found
          | :revoked
          | :worker_grant_required
          | :work_package_terminal
          | {:constraint_failed, String.t()}
          | {:migration_failed, term()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec migrate(repo()) :: :ok | {:error, error()}
  def migrate(repo) when is_atom(repo) do
    Ecto.Migrator.run(repo, migrations_path(), :up, all: true, log: false)
    :ok
  rescue
    error -> {:error, {:migration_failed, error}}
  end

  @spec create(repo(), map()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def create(repo, attrs) when is_atom(repo) and is_map(attrs) do
    changeset = AccessGrant.create_changeset(attrs)

    with {:ok, changeset} <- validate_architect_phase_anchor(repo, changeset) do
      changeset
      |> repo.insert()
      |> normalize_insert_result()
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get(repo(), String.t()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(AccessGrant, id) do
      nil -> {:error, :not_found}
      access_grant -> {:ok, access_grant}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_for_work_package(repo(), String.t()) :: {:ok, [AccessGrant.t()]} | {:error, error()}
  def list_for_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    grants =
      repo.all(
        from(access_grant in AccessGrant,
          where: access_grant.work_package_id == ^work_package_id,
          order_by: [asc: access_grant.inserted_at, asc: access_grant.id]
        )
      )

    {:ok, grants}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_for_phase(repo(), String.t()) :: {:ok, [AccessGrant.t()]} | {:error, error()}
  def list_for_phase(repo, phase_id) when is_atom(repo) and is_binary(phase_id) do
    grants =
      repo.all(
        from(access_grant in AccessGrant,
          where: access_grant.phase_id == ^phase_id,
          order_by: [asc: access_grant.inserted_at, asc: access_grant.id]
        )
      )

    {:ok, grants}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec find_by_secret_hash(repo(), String.t()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def find_by_secret_hash(repo, secret_hash) when is_atom(repo) and is_binary(secret_hash) do
    query = from(access_grant in AccessGrant, where: access_grant.secret_hash == ^secret_hash, limit: 1)

    case repo.one(query) do
      nil -> {:error, :invalid_secret}
      access_grant -> {:ok, access_grant}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec claim(repo(), String.t(), map(), DateTime.t()) :: {:ok, Assignment.t()} | {:error, error()}
  def claim(repo, secret, attrs, now)
      when is_atom(repo) and is_binary(secret) and is_map(attrs) and is_struct(now, DateTime) do
    claim(repo, secret, attrs, now, [])
  end

  @spec claim(repo(), String.t(), map(), DateTime.t(), keyword()) :: {:ok, Assignment.t()} | {:error, error()}
  def claim(repo, secret, attrs, now, opts)
      when is_atom(repo) and is_binary(secret) and is_map(attrs) and is_struct(now, DateTime) and is_list(opts) do
    normalized_now = DateTime.truncate(now, :microsecond)
    secret_hash = WorkKey.secret_hash(secret)
    terminal_statuses = Keyword.get(opts, :terminal_work_package_statuses, [])

    with :ok <- reject_display_key_only(secret),
         {:ok, access_grant} <- find_by_secret_hash(repo, secret_hash),
         true <- secure_equal?(secret_hash, access_grant.secret_hash),
         :ok <- claimable?(access_grant, normalized_now),
         {:ok, claimed_by} <- claimed_by(attrs),
         {:ok, claimed} <- persist_claim(repo, access_grant, claimed_by, normalized_now, terminal_statuses) do
      {:ok, assignment(claimed)}
    else
      false -> {:error, :invalid_secret}
      {:error, _reason} = error -> error
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec claim_local_worker_grant(repo(), String.t(), map(), DateTime.t(), keyword()) ::
          {:ok, AccessGrant.t()} | {:error, error()}
  def claim_local_worker_grant(repo, work_package_id, attrs, now, opts)
      when is_atom(repo) and is_binary(work_package_id) and is_map(attrs) and is_struct(now, DateTime) and
             is_list(opts) do
    normalized_now = DateTime.truncate(now, :microsecond)
    terminal_statuses = Keyword.get(opts, :terminal_work_package_statuses, [])

    with {:ok, claimed_by} <- claimed_by(attrs),
         :ok <- reject_other_local_claim_owner(repo, work_package_id, claimed_by, normalized_now, terminal_statuses) do
      reconnect_or_claim_local_worker_grant(repo, work_package_id, claimed_by, normalized_now, terminal_statuses)
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec claim_local_architect_grant(repo(), String.t(), String.t(), map(), DateTime.t(), keyword()) ::
          {:ok, AccessGrant.t()} | {:error, error()}
  def claim_local_architect_grant(repo, work_package_id, phase_id, attrs, now, opts)
      when is_atom(repo) and is_binary(work_package_id) and is_binary(phase_id) and is_map(attrs) and
             is_struct(now, DateTime) and is_list(opts) do
    normalized_now = DateTime.truncate(now, :microsecond)
    terminal_statuses = Keyword.get(opts, :terminal_work_package_statuses, [])

    with {:ok, claimed_by} <- claimed_by(attrs),
         {:ok, scope_repo} <- claim_scope(attrs, :scope_repo),
         {:ok, scope_base_branch} <- claim_scope(attrs, :scope_base_branch),
         :ok <-
           reject_other_local_architect_claim_owner(
             repo,
             work_package_id,
             phase_id,
             scope_repo,
             scope_base_branch,
             claimed_by,
             normalized_now,
             terminal_statuses
           ) do
      reconnect_or_claim_local_architect_grant(
        repo,
        work_package_id,
        phase_id,
        scope_repo,
        scope_base_branch,
        claimed_by,
        normalized_now,
        terminal_statuses
      )
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec revoke(repo(), String.t(), DateTime.t()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def revoke(repo, id, now) when is_atom(repo) and is_binary(id) and is_struct(now, DateTime) do
    with {:ok, access_grant} <- get(repo, id) do
      access_grant
      |> AccessGrant.revoke_changeset(now)
      |> repo.update()
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec validate_work_package(repo(), String.t()) :: :ok | {:error, error()}
  def validate_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, _work_package} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec validate_phase(repo(), String.t()) :: :ok | {:error, error()}
  def validate_phase(repo, phase_id) when is_atom(repo) and is_binary(phase_id) do
    case PhaseRepository.get(repo, phase_id) do
      {:ok, _phase} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_display_key_only(secret) do
    if String.length(secret) == 4 do
      {:error, :display_key_only}
    else
      :ok
    end
  end

  defp claimable?(%AccessGrant{revoked_at: %DateTime{}}, _now), do: {:error, :revoked}
  defp claimable?(%AccessGrant{claimed_at: %DateTime{}}, _now), do: {:error, :already_claimed}
  defp claimable?(%AccessGrant{expires_at: nil}, _now), do: :ok

  defp claimable?(%AccessGrant{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt do
      :ok
    else
      {:error, :expired}
    end
  end

  defp persist_claim(repo, access_grant, claimed_by, now, terminal_statuses) do
    query =
      from(grant in AccessGrant,
        where:
          grant.id == ^access_grant.id and is_nil(grant.claimed_at) and is_nil(grant.revoked_at) and
            (is_nil(grant.expires_at) or grant.expires_at > ^now)
      )
      |> scope_live_package_authority(terminal_statuses)

    repo.transaction(fn ->
      case repo.update_all(query, set: [claimed_at: now, claimed_by: claimed_by, updated_at: now]) do
        {1, _rows} ->
          repo
          |> get(access_grant.id)
          |> clear_completion_after_grant(repo)
          |> return_claim_or_rollback(repo)

        {0, _rows} ->
          repo
          |> reload_claim_error(access_grant.id, now, terminal_statuses)
          |> rollback_claim_error(repo)
      end
    end)
    |> case do
      {:ok, grant} -> {:ok, grant}
      {:error, reason} -> {:error, reason}
    end
  end

  defp return_claim_or_rollback({:ok, %AccessGrant{} = grant}, _repo), do: grant
  defp return_claim_or_rollback({:error, reason}, repo), do: repo.rollback(reason)

  defp rollback_claim_error({:error, reason}, repo), do: repo.rollback(reason)

  defp clear_completion_after_grant({:ok, %AccessGrant{work_package_id: work_package_id} = grant}, repo)
       when is_binary(work_package_id) do
    case WorkRequestRepository.clear_completion_for_work_package(repo, work_package_id) do
      :ok -> {:ok, grant}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_completion_after_grant(result, _repo), do: result

  defp scope_live_package_authority(query, []), do: query

  defp scope_live_package_authority(query, terminal_statuses) do
    terminal_package_ids =
      from(work_package in WorkPackage,
        where: work_package.status in ^terminal_statuses,
        select: work_package.id
      )

    from(grant in query,
      where: is_nil(grant.work_package_id) or grant.work_package_id not in subquery(terminal_package_ids)
    )
  end

  defp local_worker_grant_missing_reason(repo, work_package_id, terminal_statuses) do
    if terminal_work_package?(repo, work_package_id, terminal_statuses) do
      {:error, :work_package_terminal}
    else
      {:error, inactive_worker_grant_reason(repo, work_package_id)}
    end
  end

  defp terminal_work_package?(_repo, _work_package_id, []), do: false

  defp terminal_work_package?(repo, work_package_id, terminal_statuses) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %{status: status}} -> status in terminal_statuses
      {:error, _reason} -> false
    end
  end

  defp inactive_worker_grant_reason(repo, work_package_id) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        select: {count(grant.id), count(grant.revoked_at)}
      )

    case repo.one(query) do
      {0, _revoked_count} -> :worker_grant_required
      {grant_count, grant_count} -> :revoked
      {_grant_count, _revoked_count} -> :expired
    end
  end

  defp reject_other_local_claim_owner(repo, work_package_id, claimed_by, now, terminal_statuses) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        where: not is_nil(grant.claimed_at),
        where: grant.claimed_by != ^claimed_by,
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        select: 1,
        limit: 1
      )
      |> scope_live_package_authority(terminal_statuses)

    case repo.one(query) do
      nil -> :ok
      1 -> {:error, :already_claimed}
    end
  end

  defp reject_other_local_architect_claim_owner(
         repo,
         work_package_id,
         phase_id,
         scope_repo,
         scope_base_branch,
         claimed_by,
         now,
         terminal_statuses
       ) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.phase_id == ^phase_id,
        where: grant.grant_role == "architect",
        where: grant.scope_repo == ^scope_repo,
        where: grant.scope_base_branch == ^scope_base_branch,
        where: not is_nil(grant.claimed_at),
        where: grant.claimed_by != ^claimed_by,
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        select: 1,
        limit: 1
      )
      |> scope_live_package_authority(terminal_statuses)

    case repo.one(query) do
      nil -> :ok
      1 -> {:error, :already_claimed}
    end
  end

  defp local_reconnect_grant(repo, work_package_id, claimed_by, now, terminal_statuses) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        where: grant.claimed_by == ^claimed_by,
        where: not is_nil(grant.claimed_at),
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        order_by: [desc: grant.claimed_at, desc: grant.updated_at, asc: grant.id],
        limit: 1
      )
      |> scope_live_package_authority(terminal_statuses)

    case repo.one(query) do
      %AccessGrant{} = grant -> {:ok, grant}
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp reconnect_or_claim_local_worker_grant(repo, work_package_id, claimed_by, now, terminal_statuses) do
    case local_reconnect_grant(repo, work_package_id, claimed_by, now, terminal_statuses) do
      {:ok, grant} ->
        {:ok, grant}

      {:error, :not_found} ->
        claim_unclaimed_local_worker_grant(repo, work_package_id, claimed_by, now, terminal_statuses)

      {:error, _reason} = error ->
        error
    end
  end

  defp reconnect_or_claim_local_architect_grant(
         repo,
         work_package_id,
         phase_id,
         scope_repo,
         scope_base_branch,
         claimed_by,
         now,
         terminal_statuses
       ) do
    case local_reconnect_architect_grant(
           repo,
           work_package_id,
           phase_id,
           scope_repo,
           scope_base_branch,
           claimed_by,
           now,
           terminal_statuses
         ) do
      {:ok, grant} ->
        {:ok, grant}

      {:error, :not_found} ->
        claim_unclaimed_local_architect_grant(
          repo,
          work_package_id,
          phase_id,
          scope_repo,
          scope_base_branch,
          claimed_by,
          now,
          terminal_statuses
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp local_reconnect_architect_grant(repo, work_package_id, phase_id, scope_repo, scope_base_branch, claimed_by, now, terminal_statuses) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.phase_id == ^phase_id,
        where: grant.grant_role == "architect",
        where: grant.scope_repo == ^scope_repo,
        where: grant.scope_base_branch == ^scope_base_branch,
        where: grant.claimed_by == ^claimed_by,
        where: not is_nil(grant.claimed_at),
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        order_by: [desc: grant.claimed_at, desc: grant.updated_at, asc: grant.id],
        limit: 1
      )
      |> scope_live_package_authority(terminal_statuses)

    case repo.one(query) do
      %AccessGrant{} = grant -> {:ok, grant}
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp claim_unclaimed_local_worker_grant(repo, work_package_id, claimed_by, now, terminal_statuses) do
    with {:ok, grant} <- local_unclaimed_worker_grant(repo, work_package_id, now, terminal_statuses) do
      persist_claim(repo, grant, claimed_by, now, terminal_statuses)
    end
  end

  defp claim_unclaimed_local_architect_grant(
         repo,
         work_package_id,
         phase_id,
         scope_repo,
         scope_base_branch,
         claimed_by,
         now,
         terminal_statuses
       ) do
    with {:ok, grant} <-
           local_unclaimed_architect_grant(
             repo,
             work_package_id,
             phase_id,
             scope_repo,
             scope_base_branch,
             now,
             terminal_statuses
           ) do
      persist_claim(repo, grant, claimed_by, now, terminal_statuses)
    end
  end

  defp local_unclaimed_worker_grant(repo, work_package_id, now, terminal_statuses) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        where: is_nil(grant.claimed_at),
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        order_by: [desc: grant.inserted_at, desc: grant.id],
        limit: 1
      )
      |> scope_live_package_authority(terminal_statuses)

    case repo.one(query) do
      %AccessGrant{} = grant -> {:ok, grant}
      nil -> local_worker_grant_missing_reason(repo, work_package_id, terminal_statuses)
    end
  end

  defp local_unclaimed_architect_grant(
         repo,
         work_package_id,
         phase_id,
         scope_repo,
         scope_base_branch,
         now,
         terminal_statuses
       ) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.phase_id == ^phase_id,
        where: grant.grant_role == "architect",
        where: grant.scope_repo == ^scope_repo,
        where: grant.scope_base_branch == ^scope_base_branch,
        where: is_nil(grant.claimed_at),
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        order_by: [desc: grant.inserted_at, desc: grant.id],
        limit: 1
      )
      |> scope_live_package_authority(terminal_statuses)

    case repo.one(query) do
      %AccessGrant{} = grant ->
        {:ok, grant}

      nil ->
        local_architect_grant_missing_reason(
          repo,
          work_package_id,
          phase_id,
          scope_repo,
          scope_base_branch,
          terminal_statuses
        )
    end
  end

  defp local_architect_grant_missing_reason(repo, work_package_id, phase_id, scope_repo, scope_base_branch, terminal_statuses) do
    if terminal_work_package?(repo, work_package_id, terminal_statuses) do
      {:error, :work_package_terminal}
    else
      {:error, inactive_architect_grant_reason(repo, work_package_id, phase_id, scope_repo, scope_base_branch)}
    end
  end

  defp inactive_architect_grant_reason(repo, work_package_id, phase_id, scope_repo, scope_base_branch) do
    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.phase_id == ^phase_id,
        where: grant.grant_role == "architect",
        where: grant.scope_repo == ^scope_repo,
        where: grant.scope_base_branch == ^scope_base_branch,
        select: {count(grant.id), count(grant.revoked_at)}
      )

    case repo.one(query) do
      {0, _revoked_count} -> :architect_grant_required
      {grant_count, grant_count} -> :revoked
      {_grant_count, _revoked_count} -> :expired
    end
  end

  defp reload_claim_error(repo, grant_id, now, terminal_statuses) do
    with {:ok, access_grant} <- get(repo, grant_id) do
      case claimable?(access_grant, now) do
        :ok -> package_authority_claim_error(repo, access_grant, terminal_statuses)
        {:error, _reason} = error -> error
      end
    end
  end

  defp package_authority_claim_error(_repo, _access_grant, []), do: {:error, :already_claimed}

  defp package_authority_claim_error(repo, %AccessGrant{work_package_id: work_package_id}, terminal_statuses)
       when is_binary(work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %{status: status}} ->
        if Enum.member?(terminal_statuses, status) do
          {:error, :work_package_terminal}
        else
          {:error, :already_claimed}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp package_authority_claim_error(_repo, %AccessGrant{}, _terminal_statuses), do: {:error, :already_claimed}

  defp claimed_by(attrs) do
    case Map.get(attrs, :claimed_by) || Map.get(attrs, "claimed_by") do
      claimed_by when is_binary(claimed_by) ->
        if String.trim(claimed_by) == "" do
          {:error, :missing_claim_identity}
        else
          {:ok, claimed_by}
        end

      _claimed_by ->
        {:error, :missing_claim_identity}
    end
  end

  defp claim_scope(attrs, key) when is_atom(key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :invalid_scope}, else: {:ok, value}

      _value ->
        {:error, :invalid_scope}
    end
  end

  defp assignment(%AccessGrant{} = access_grant) do
    %Assignment{
      grant_id: access_grant.id,
      work_package_id: access_grant.work_package_id,
      phase_id: access_grant.phase_id,
      display_key: access_grant.display_key,
      grant_role: access_grant.grant_role,
      capabilities: access_grant.capabilities,
      claimed_at: access_grant.claimed_at,
      claimed_by: access_grant.claimed_by
    }
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {left_byte, right_byte}, diff ->
      Bitwise.bor(diff, Bitwise.bxor(left_byte, right_byte))
    end)
    |> Kernel.==(0)
  end

  defp secure_equal?(_left, _right), do: false

  defp normalize_insert_result({:ok, access_grant}), do: {:ok, access_grant}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    if duplicate_id?(changeset) do
      {:error, :id_already_exists}
    else
      {:error, changeset}
    end
  end

  defp validate_architect_phase_anchor(_repo, %Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp validate_architect_phase_anchor(repo, %Changeset{} = changeset) do
    if architect_phase_grant?(changeset) do
      phase_id = Changeset.get_field(changeset, :phase_id)
      work_package_id = Changeset.get_field(changeset, :work_package_id)

      with :ok <- validate_phase_anchor_phase(repo, changeset, phase_id),
           {:ok, anchor} <- validate_phase_anchor_work_package(repo, changeset, work_package_id, phase_id) do
        {:ok, freeze_architect_anchor_scope(changeset, anchor)}
      else
        {:error, %Changeset{} = changeset} -> {:error, changeset}
      end
    else
      {:ok, changeset}
    end
  end

  defp architect_phase_grant?(%Changeset{} = changeset) do
    Changeset.get_field(changeset, :grant_role) == "architect" and
      explicit_phase_id?(Changeset.get_field(changeset, :phase_id))
  end

  defp explicit_phase_id?(phase_id) when is_binary(phase_id), do: String.trim(phase_id) != ""
  defp explicit_phase_id?(_phase_id), do: false

  defp validate_phase_anchor_phase(repo, changeset, phase_id) do
    case PhaseRepository.get(repo, phase_id) do
      {:ok, _phase} -> :ok
      {:error, :not_found} -> {:error, Changeset.add_error(changeset, :phase_id, "does not exist")}
      {:error, reason} -> {:error, Changeset.add_error(changeset, :phase_id, inspect(reason))}
    end
  end

  defp validate_phase_anchor_work_package(_repo, changeset, work_package_id, _phase_id)
       when not is_binary(work_package_id) do
    {:error, Changeset.add_error(changeset, :work_package_id, "architect phase grants require work package anchor")}
  end

  defp validate_phase_anchor_work_package(repo, changeset, work_package_id, phase_id) do
    if String.trim(work_package_id) == "" do
      {:error, Changeset.add_error(changeset, :work_package_id, "architect phase grants require work package anchor")}
    else
      validate_phase_anchor_work_package_id(repo, changeset, work_package_id, phase_id)
    end
  end

  defp validate_phase_anchor_work_package_id(repo, changeset, work_package_id, phase_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %{phase_id: ^phase_id} = work_package} -> {:ok, work_package}
      {:ok, _work_package} -> {:error, Changeset.add_error(changeset, :work_package_id, "must belong to architect phase")}
      {:error, :not_found} -> {:error, Changeset.add_error(changeset, :work_package_id, "does not exist")}
      {:error, reason} -> {:error, Changeset.add_error(changeset, :work_package_id, inspect(reason))}
    end
  end

  defp freeze_architect_anchor_scope(%Changeset{} = changeset, %{repo: repo, base_branch: base_branch}) do
    changeset
    |> Changeset.put_change(:scope_repo, repo)
    |> Changeset.put_change(:scope_base_branch, base_branch)
  end

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_access_grants_id_unique_index"}) do
    {:error, :id_already_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    {:error, {:constraint_failed, constraint}}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    if String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end

  defp migrations_path do
    Application.app_dir(:symphony_elixir, "priv/symphony_plus_plus/repo/migrations")
  end
end
