defmodule SymphonyElixir.SymphonyPlusPlus.AgentRuns.Service do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository

  @type error :: Repository.error()

  @spec start_dispatch(Repository.repo(), Issue.t(), keyword()) :: {:ok, AgentRun.t()} | {:error, error()}
  def start_dispatch(repo, %Issue{} = issue, opts \\ []) when is_atom(repo) and is_list(opts) do
    attrs =
      %{
        work_package_id: issue.id,
        status: Keyword.get(opts, :status, "running"),
        attempt: normalize_attempt(Keyword.get(opts, :attempt)),
        worker_host: Keyword.get(opts, :worker_host),
        worker_task_handle: Keyword.get(opts, :worker_task_handle)
      }
      |> Map.merge(grant_binding(repo, issue))

    Repository.start_run(repo, attrs,
      replace_agent_run_id: Keyword.get(opts, :replace_agent_run_id),
      replace_confirmed_dead_worker: Keyword.get(opts, :replace_confirmed_dead_worker),
      retry_recovery_base_ms: Keyword.get(opts, :retry_recovery_base_ms),
      retry_recovery_max_ms: Keyword.get(opts, :retry_recovery_max_ms),
      starting_stale_after_ms: Keyword.get(opts, :starting_stale_after_ms)
    )
  end

  @spec heartbeat(Repository.repo(), String.t(), map()) :: {:ok, AgentRun.t()} | {:error, error()}
  def heartbeat(repo, agent_run_id, attrs \\ %{}) when is_atom(repo) and is_binary(agent_run_id) and is_map(attrs) do
    Repository.heartbeat(repo, agent_run_id, compact_attrs(attrs))
  end

  @spec list_active(Repository.repo()) :: {:ok, [AgentRun.t()]} | {:error, error()}
  def list_active(repo) when is_atom(repo), do: Repository.list_active(repo)

  @spec mark_retrying(Repository.repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_retrying(repo, agent_run_id, reason \\ nil), do: Repository.mark_retrying(repo, agent_run_id, reason)

  @spec mark_running(Repository.repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_running(repo, agent_run_id, reason \\ nil), do: Repository.mark_running(repo, agent_run_id, reason)

  @spec mark_completed(Repository.repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_completed(repo, agent_run_id, reason \\ nil), do: Repository.mark_completed(repo, agent_run_id, reason)

  @spec mark_failed(Repository.repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_failed(repo, agent_run_id, reason \\ nil), do: Repository.mark_failed(repo, agent_run_id, reason)

  @spec mark_stopped(Repository.repo(), String.t(), String.t() | nil) :: {:ok, AgentRun.t()} | {:error, error()}
  def mark_stopped(repo, agent_run_id, reason \\ nil), do: Repository.mark_stopped(repo, agent_run_id, reason)

  defp grant_binding(_repo, %Issue{assigned_to_worker: assigned_to_worker}) when assigned_to_worker != true, do: %{}

  defp grant_binding(repo, %Issue{id: work_package_id, assignee_id: assignee_id}) do
    now = DateTime.utc_now(:microsecond)

    query =
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        where: not is_nil(grant.claimed_at),
        where: is_nil(grant.revoked_at),
        where: grant.expires_at > ^now,
        order_by: [desc: grant.claimed_at, asc: grant.id]
      )

    query
    |> repo.all()
    |> select_grant_for_assignee(assignee_id)
    |> case do
      %AccessGrant{} = grant ->
        %{access_grant_id: grant.id, actor_id: grant.claimed_by}

      nil ->
        %{}
    end
  end

  defp select_grant_for_assignee(grants, assignee_id) when is_list(grants) and is_binary(assignee_id) do
    normalized_assignee_id = normalize_actor_id(assignee_id)
    Enum.find(grants, &(normalize_actor_id(&1.claimed_by) == normalized_assignee_id))
  end

  defp select_grant_for_assignee(_grants, _assignee_id), do: nil

  defp normalize_actor_id(actor_id) when is_binary(actor_id) do
    actor_id
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_actor_id(_actor_id), do: ""

  defp compact_attrs(attrs) do
    attrs
    |> Map.take([:worker_host, :worker_task_handle, :workspace_path, :session_id])
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp normalize_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_attempt(_attempt), do: 0
end
