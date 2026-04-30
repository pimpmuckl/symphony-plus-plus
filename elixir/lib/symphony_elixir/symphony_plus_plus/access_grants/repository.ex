defmodule SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository

  @type repo :: module()

  @type error ::
          :already_claimed
          | :display_key_only
          | :expired
          | :id_already_exists
          | :invalid_secret
          | :not_found
          | :revoked
          | {:constraint_failed, String.t()}
          | {:migration_failed, term()}
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
    attrs
    |> AccessGrant.create_changeset()
    |> repo.insert()
    |> normalize_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
  end

  @spec get(repo(), String.t()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(AccessGrant, id) do
      nil -> {:error, :not_found}
      access_grant -> {:ok, access_grant}
    end
  end

  @spec find_by_secret_hash(repo(), String.t()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def find_by_secret_hash(repo, secret_hash) when is_atom(repo) and is_binary(secret_hash) do
    query = from(access_grant in AccessGrant, where: access_grant.secret_hash == ^secret_hash, limit: 1)

    case repo.one(query) do
      nil -> {:error, :invalid_secret}
      access_grant -> {:ok, access_grant}
    end
  end

  @spec claim(repo(), String.t(), map(), DateTime.t()) :: {:ok, Assignment.t()} | {:error, error()}
  def claim(repo, secret, attrs, now)
      when is_atom(repo) and is_binary(secret) and is_map(attrs) and is_struct(now, DateTime) do
    normalized_now = DateTime.truncate(now, :microsecond)
    secret_hash = WorkKey.secret_hash(secret)

    with :ok <- reject_display_key_only(secret),
         {:ok, access_grant} <- find_by_secret_hash(repo, secret_hash),
         true <- secure_equal?(secret_hash, access_grant.secret_hash),
         :ok <- claimable?(access_grant, normalized_now),
         {:ok, claimed} <- persist_claim(repo, access_grant, attrs, normalized_now) do
      {:ok, assignment(claimed)}
    else
      false -> {:error, :invalid_secret}
      {:error, _reason} = error -> error
    end
  end

  @spec revoke(repo(), String.t(), DateTime.t()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def revoke(repo, id, now) when is_atom(repo) and is_binary(id) and is_struct(now, DateTime) do
    with {:ok, access_grant} <- get(repo, id) do
      access_grant
      |> AccessGrant.revoke_changeset(now)
      |> repo.update()
    end
  end

  @spec validate_work_package(repo(), String.t()) :: :ok | {:error, error()}
  def validate_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, _work_package} -> :ok
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

  defp claimable?(%AccessGrant{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt do
      :ok
    else
      {:error, :expired}
    end
  end

  defp persist_claim(repo, access_grant, attrs, now) do
    claimed_by = Map.get(attrs, :claimed_by) || Map.get(attrs, "claimed_by")

    query =
      from(grant in AccessGrant,
        where:
          grant.id == ^access_grant.id and is_nil(grant.claimed_at) and is_nil(grant.revoked_at) and
            grant.expires_at > ^now
      )

    case repo.update_all(query, set: [claimed_at: now, claimed_by: claimed_by, updated_at: now]) do
      {1, _rows} -> get(repo, access_grant.id)
      {0, _rows} -> reload_claim_error(repo, access_grant.id, now)
    end
  end

  defp reload_claim_error(repo, grant_id, now) do
    with {:ok, access_grant} <- get(repo, grant_id) do
      case claimable?(access_grant, now) do
        :ok -> {:error, :already_claimed}
        {:error, _reason} = error -> error
      end
    end
  end

  defp assignment(%AccessGrant{} = access_grant) do
    %Assignment{
      grant_id: access_grant.id,
      work_package_id: access_grant.work_package_id,
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

  defp migrations_path do
    Application.app_dir(:symphony_elixir, "priv/symphony_plus_plus/repo/migrations")
  end
end
