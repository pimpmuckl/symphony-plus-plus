defmodule SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun

  @type repo :: module()
  @type error ::
          :active_run_exists
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

  @spec start_run(repo(), map()) :: {:ok, AgentRun.t()} | {:error, error()}
  def start_run(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs
    |> AgentRun.create_changeset()
    |> repo.insert()
    |> normalize_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
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
  def mark_retrying(repo, id, reason \\ nil), do: update_active_status(repo, id, "retrying", reason)

  @spec mark_completed(repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_completed(repo, id, reason \\ nil), do: update_terminal_status(repo, id, "completed", reason)

  @spec mark_failed(repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_failed(repo, id, reason \\ nil), do: update_terminal_status(repo, id, "failed", reason)

  @spec mark_stopped(repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_stopped(repo, id, reason \\ nil), do: update_terminal_status(repo, id, "stopped", reason)

  defp update_active_status(repo, id, status, reason) do
    update_run(repo, id, %{status: status, reason: reason, last_seen_at: DateTime.utc_now(:microsecond)})
  end

  defp update_terminal_status(repo, id, status, reason) do
    now = DateTime.utc_now(:microsecond)
    update_run(repo, id, %{status: status, reason: reason, last_seen_at: now, finished_at: now})
  end

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
