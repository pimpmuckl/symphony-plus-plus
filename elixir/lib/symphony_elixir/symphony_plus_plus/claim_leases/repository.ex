defmodule SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease

  @type repo :: module()
  @type error ::
          atom()
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

  @spec claim(repo(), map(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def claim(repo, attrs, opts \\ []) when is_atom(repo) and is_map(attrs) and is_list(opts) do
    attrs
    |> ClaimLease.create_changeset(now: now(opts))
    |> repo.insert()
    |> normalize_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get(repo(), String.t()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(ClaimLease, id) do
      nil -> {:error, :not_found}
      claim_lease -> {:ok, claim_lease}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec current_for_work_package(repo(), String.t()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def current_for_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    query =
      from(claim_lease in ClaimLease,
        where: claim_lease.work_package_id == ^work_package_id,
        where: claim_lease.status in ^ClaimLease.active_statuses(),
        order_by: [desc: claim_lease.inserted_at, desc: claim_lease.lease_started_at, asc: claim_lease.id],
        limit: 1
      )

    case repo.one(query) do
      nil -> {:error, :not_found}
      claim_lease -> {:ok, claim_lease}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec heartbeat(repo(), String.t(), map(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def heartbeat(repo, id, attrs \\ %{}, opts \\ []) when is_atom(repo) and is_binary(id) and is_map(attrs) and is_list(opts) do
    with {:ok, %ClaimLease{} = claim_lease} <- get(repo, id),
         :ok <- require_status(claim_lease, ["active"]) do
      update_claim_lease(
        repo,
        claim_lease,
        attrs
        |> Map.take([:lease_expires_at, "lease_expires_at", :stale_after_ms, "stale_after_ms"])
        |> Map.put(:last_seen_at, now(opts)),
        ["active"]
      )
    end
  end

  @spec pause(repo(), String.t(), map(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def pause(repo, id, attrs, opts \\ []) when is_atom(repo) and is_binary(id) and is_map(attrs) and is_list(opts) do
    with {:ok, %ClaimLease{} = claim_lease} <- get(repo, id),
         :ok <- require_status(claim_lease, ["active"]) do
      now = now(opts)

      update_claim_lease(
        repo,
        claim_lease,
        attrs
        |> Map.take([:paused_by_actor_id, "paused_by_actor_id", :pause_reason, "pause_reason"])
        |> Map.merge(%{status: "paused", paused_at: now, last_seen_at: now}),
        ["active"]
      )
    end
  end

  @spec release(repo(), String.t(), map(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def release(repo, id, attrs \\ %{}, opts \\ []) when is_atom(repo) and is_binary(id) and is_map(attrs) and is_list(opts) do
    with {:ok, %ClaimLease{} = claim_lease} <- get(repo, id),
         :ok <- require_status(claim_lease, ClaimLease.active_statuses()) do
      now = now(opts)

      update_claim_lease(
        repo,
        claim_lease,
        attrs
        |> Map.take([:release_reason, "release_reason"])
        |> Map.merge(%{status: "released", released_at: now, last_seen_at: now}),
        ClaimLease.active_statuses()
      )
    end
  end

  @spec reclaim_stale(repo(), String.t(), map(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def reclaim_stale(repo, work_package_id, attrs, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_map(attrs) and is_list(opts) do
    repo.transaction(fn ->
      case reclaim_stale_transaction(repo, work_package_id, attrs, opts) do
        {:ok, claim_lease} -> claim_lease
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, claim_lease} -> {:ok, claim_lease}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec stale?(ClaimLease.t(), DateTime.t()) :: boolean()
  def stale?(%ClaimLease{} = claim_lease, %DateTime{} = now) do
    expired?(claim_lease, now) or heartbeat_stale?(claim_lease, now)
  end

  defp reclaim_stale_transaction(repo, work_package_id, attrs, opts) do
    now = now(opts)

    with {:ok, current} <- current_for_work_package(repo, work_package_id),
         :ok <- require_stale(current, now),
         {:ok, _reclaimed} <- reclaim_current(repo, current, attrs, now) do
      claim(repo, replacement_attrs(current, attrs), Keyword.put(opts, :now, now))
    end
  end

  defp reclaim_current(repo, %ClaimLease{} = current, attrs, now) do
    actor_id = Map.get(attrs, :actor_id) || Map.get(attrs, "actor_id")
    reason = Map.get(attrs, :reclaim_reason) || Map.get(attrs, "reclaim_reason")

    update_claim_lease(
      repo,
      current,
      %{
        status: "reclaimed",
        stale_checked_at: now,
        stale_at: now,
        stale_reason: Map.get(attrs, :stale_reason) || Map.get(attrs, "stale_reason") || reason,
        reclaimed_at: now,
        reclaimed_by_actor_id: actor_id,
        reclaim_reason: reason,
        last_seen_at: now
      },
      ClaimLease.active_statuses()
    )
  end

  defp replacement_attrs(%ClaimLease{} = current, attrs) do
    attrs
    |> normalize_keys()
    |> Map.put_new("access_grant_id", current.access_grant_id)
    |> Map.put_new("stale_after_ms", current.stale_after_ms)
    |> Map.put("work_package_id", current.work_package_id)
    |> Map.put("claim_group_id", current.claim_group_id || current.id)
    |> Map.put("previous_claim_id", current.id)
  end

  defp require_status(%ClaimLease{status: status}, statuses) do
    if status in statuses do
      :ok
    else
      status_error(statuses)
    end
  end

  defp status_error(["active"]), do: {:error, :not_active}
  defp status_error(_statuses), do: {:error, :claim_not_current}

  defp require_stale(%ClaimLease{} = claim_lease, now) do
    if stale?(claim_lease, now), do: :ok, else: {:error, :claim_not_stale}
  end

  defp update_claim_lease(repo, %ClaimLease{} = claim_lease, attrs, allowed_statuses) do
    changeset = ClaimLease.update_changeset(claim_lease, attrs)

    if changeset.valid? do
      changes =
        changeset.changes
        |> Map.put(:updated_at, Map.get(changeset.changes, :last_seen_at, now([])))
        |> Map.to_list()

      query =
        from(stored in ClaimLease,
          where: stored.id == ^claim_lease.id,
          where: stored.status in ^allowed_statuses
        )

      case repo.update_all(query, set: changes) do
        {1, _rows} -> get(repo, claim_lease.id)
        {0, _rows} -> status_error(allowed_statuses)
      end
    else
      {:error, changeset}
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp expired?(%ClaimLease{lease_expires_at: %DateTime{} = expires_at}, now), do: DateTime.compare(expires_at, now) != :gt
  defp expired?(%ClaimLease{}, %DateTime{}), do: false

  defp heartbeat_stale?(%ClaimLease{last_seen_at: %DateTime{} = last_seen_at, stale_after_ms: stale_after_ms}, now)
       when is_integer(stale_after_ms) and stale_after_ms > 0 do
    last_seen_at
    |> DateTime.add(stale_after_ms, :millisecond)
    |> DateTime.compare(now)
    |> Kernel.!==(:gt)
  end

  defp heartbeat_stale?(%ClaimLease{}, %DateTime{}), do: false

  defp normalize_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp normalize_insert_result({:ok, claim_lease}), do: {:ok, claim_lease}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    cond do
      duplicate_id?(changeset) -> {:error, :id_already_exists}
      active_claim_conflict?(changeset) -> {:error, :active_claim_exists}
      true -> {:error, changeset}
    end
  end

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp active_claim_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:work_package_id, {_message, options}} ->
        Keyword.get(options, :constraint_name) in [
          "sympp_claim_leases_one_current_per_work_package_index",
          "sympp_claim_leases_work_package_id_index"
        ] or
          Keyword.get(options, :constraint) == :unique

      _error ->
        false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_claim_leases_id_unique_index"}) do
    {:error, :id_already_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_claim_leases_one_current_per_work_package_index"}) do
    {:error, :active_claim_exists}
  end

  # SQLite reports the partial unique index by Ecto's generated column index name.
  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_claim_leases_work_package_id_index"}) do
    {:error, :active_claim_exists}
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

  defp now(opts), do: opts |> Keyword.get(:now, DateTime.utc_now(:microsecond)) |> DateTime.truncate(:microsecond)

  defp migrations_path do
    Application.app_dir(:symphony_elixir, "priv/symphony_plus_plus/repo/migrations")
  end
end
