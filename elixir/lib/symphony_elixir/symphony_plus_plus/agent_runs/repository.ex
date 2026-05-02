defmodule SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun

  @type repo :: module()
  @type error ::
          :active_run_exists
          | :agent_run_work_package_mismatch
          | :id_already_exists
          | :not_found
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

  @spec start_run(repo(), map(), keyword()) :: {:ok, AgentRun.t()} | {:error, error()}
  def start_run(repo, attrs, opts \\ []) when is_atom(repo) and is_map(attrs) and is_list(opts) do
    case repo.transaction(fn -> start_run_or_rollback(repo, attrs, opts) end) do
      {:ok, agent_run} -> {:ok, agent_run}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get(repo(), String.t()) :: {:ok, AgentRun.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(AgentRun, id) do
      nil -> {:error, :not_found}
      agent_run -> {:ok, agent_run}
    end
  end

  @spec list_for_work_package(repo(), String.t()) :: {:ok, [AgentRun.t()]} | {:error, error()}
  def list_for_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    agent_runs =
      repo.all(
        from(agent_run in AgentRun,
          where: agent_run.work_package_id == ^work_package_id,
          order_by: [asc: agent_run.started_at, asc: agent_run.id]
        )
      )

    {:ok, agent_runs}
  end

  @spec active_for_work_package(repo(), String.t()) :: {:ok, AgentRun.t()} | {:error, error()}
  def active_for_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    query =
      from(agent_run in AgentRun,
        where: agent_run.work_package_id == ^work_package_id,
        where: agent_run.status in ^AgentRun.active_statuses(),
        order_by: [desc: agent_run.started_at, asc: agent_run.id],
        limit: 1
      )

    case repo.one(query) do
      nil -> {:error, :not_found}
      agent_run -> {:ok, agent_run}
    end
  end

  @spec heartbeat(repo(), String.t(), map()) :: {:ok, AgentRun.t()} | {:error, error()}
  def heartbeat(repo, id, attrs \\ %{}) when is_atom(repo) and is_binary(id) and is_map(attrs) do
    update_run(repo, id, Map.put(attrs, :last_seen_at, DateTime.utc_now(:microsecond)))
  end

  @spec mark_retrying(repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_retrying(repo, id, reason \\ nil), do: update_terminal_status(repo, id, "retrying", reason)

  @spec mark_completed(repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_completed(repo, id, reason \\ nil), do: update_terminal_status(repo, id, "completed", reason)

  @spec mark_failed(repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_failed(repo, id, reason \\ nil), do: update_terminal_status(repo, id, "failed", reason)

  @spec mark_stopped(repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_stopped(repo, id, reason \\ nil), do: update_terminal_status(repo, id, "stopped", reason)

  defp update_terminal_status(repo, id, status, reason) do
    now = DateTime.utc_now(:microsecond)
    update_run(repo, id, %{status: status, reason: reason, last_seen_at: now, finished_at: now})
  end

  defp start_run_or_rollback(repo, attrs, opts) do
    case start_run_transaction(repo, attrs, opts) do
      {:ok, agent_run} -> agent_run
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp start_run_transaction(repo, attrs, opts) do
    work_package_id = work_package_id(attrs)

    with :ok <- release_previous_attempt(repo, Keyword.get(opts, :replace_agent_run_id), work_package_id) do
      case insert_run(repo, attrs) do
        {:error, :active_run_exists} ->
          repo
          |> release_retrying_reservation(work_package_id, Keyword.get(opts, :recover_retrying, false))
          |> maybe_release_stale_active_run(repo, work_package_id, Keyword.get(opts, :stale_after_ms))
          |> maybe_insert_after_stale_release(repo, attrs)

        result ->
          result
      end
    end
  end

  defp insert_run(repo, attrs) do
    attrs
    |> AgentRun.create_changeset()
    |> repo.insert()
    |> normalize_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
  end

  defp release_previous_attempt(_repo, previous_agent_run_id, _work_package_id)
       when previous_agent_run_id in [nil, ""],
       do: :ok

  defp release_previous_attempt(repo, previous_agent_run_id, work_package_id)
       when is_binary(previous_agent_run_id) and is_binary(work_package_id) do
    case get(repo, previous_agent_run_id) do
      {:ok, %AgentRun{work_package_id: ^work_package_id, status: status}}
      when status in ["running", "retrying"] ->
        case mark_failed(repo, previous_agent_run_id, "replaced by retry dispatch") do
          {:ok, _agent_run} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, %AgentRun{work_package_id: ^work_package_id}} ->
        :ok

      {:ok, %AgentRun{}} ->
        {:error, :agent_run_work_package_mismatch}

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release_previous_attempt(_repo, _previous_agent_run_id, _work_package_id), do: :ok

  defp release_retrying_reservation(repo, work_package_id, true) when is_binary(work_package_id) do
    now = DateTime.utc_now(:microsecond)

    {updated_count, _rows} =
      repo.update_all(
        from(agent_run in AgentRun,
          where: agent_run.work_package_id == ^work_package_id,
          where: agent_run.status == "retrying"
        ),
        set: [
          status: "failed",
          reason: "retry reservation recovered by dispatch",
          last_seen_at: now,
          finished_at: now,
          updated_at: now
        ]
      )

    case updated_count do
      0 -> {:ok, :active}
      1 -> {:ok, :released}
      _count -> {:error, {:constraint_failed, "multiple_retrying_agent_runs"}}
    end
  end

  defp release_retrying_reservation(_repo, _work_package_id, _recover_retrying), do: {:ok, :active}

  defp maybe_release_stale_active_run({:ok, :released}, _repo, _work_package_id, _stale_after_ms), do: {:ok, :released}

  defp maybe_release_stale_active_run({:ok, :active}, repo, work_package_id, stale_after_ms) do
    release_stale_active_run(repo, work_package_id, stale_after_ms)
  end

  defp maybe_release_stale_active_run({:error, reason}, _repo, _work_package_id, _stale_after_ms), do: {:error, reason}

  defp release_stale_active_run(_repo, _work_package_id, stale_after_ms)
       when not is_integer(stale_after_ms) or stale_after_ms <= 0,
       do: {:ok, :active}

  defp release_stale_active_run(repo, work_package_id, stale_after_ms) when is_binary(work_package_id) do
    now = DateTime.utc_now(:microsecond)
    stale_cutoff = DateTime.add(now, -stale_after_ms, :millisecond)

    {updated_count, _rows} =
      repo.update_all(
        from(agent_run in AgentRun,
          where: agent_run.work_package_id == ^work_package_id,
          where: agent_run.status in ^AgentRun.active_statuses(),
          where: agent_run.last_seen_at <= ^stale_cutoff
        ),
        set: [
          status: "failed",
          reason: "stale active AgentRun released before dispatch",
          last_seen_at: now,
          finished_at: now,
          updated_at: now
        ]
      )

    case updated_count do
      0 -> {:ok, :active}
      1 -> {:ok, :released}
      _count -> {:error, {:constraint_failed, "multiple_active_agent_runs"}}
    end
  end

  defp release_stale_active_run(_repo, _work_package_id, _stale_after_ms), do: {:ok, :active}

  defp maybe_insert_after_stale_release({:ok, :released}, repo, attrs), do: insert_run(repo, attrs)
  defp maybe_insert_after_stale_release({:ok, :active}, _repo, _attrs), do: {:error, :active_run_exists}
  defp maybe_insert_after_stale_release({:error, reason}, _repo, _attrs), do: {:error, reason}

  defp work_package_id(attrs), do: Map.get(attrs, :work_package_id) || Map.get(attrs, "work_package_id")

  defp update_run(repo, id, attrs) do
    with {:ok, agent_run} <- get(repo, id) do
      agent_run
      |> AgentRun.update_changeset(attrs)
      |> repo.update()
    end
  end

  defp normalize_insert_result({:ok, agent_run}), do: {:ok, agent_run}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    cond do
      duplicate_id?(changeset) -> {:error, :id_already_exists}
      active_run_conflict?(changeset) -> {:error, :active_run_exists}
      true -> {:error, changeset}
    end
  end

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp active_run_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:work_package_id, {_message, options}} ->
        constraint_name = Keyword.get(options, :constraint_name)

        constraint_name in [
          "sympp_agent_runs_one_active_per_work_package_index",
          "sympp_agent_runs_work_package_id_index"
        ] or Keyword.get(options, :constraint) == :unique

      _error ->
        false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_agent_runs_id_unique_index"}) do
    {:error, :id_already_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_agent_runs_one_active_per_work_package_index"}) do
    {:error, :active_run_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_agent_runs_work_package_id_index"}) do
    {:error, :active_run_exists}
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
