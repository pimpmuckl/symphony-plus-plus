defmodule SymphonyElixir.SymphonyPlusPlus.Planning.Service do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Timeline

  @type error ::
          Repository.error()
          | :assignment_mismatch
          | :assignment_not_claimed
          | :assignment_revoked
          | :conflicting_key_forms
          | :idempotency_key_conflict
          | :idempotency_scope_conflict
          | :missing_idempotency_key
          | :unauthenticated
          | :work_package_scope_mismatch

  @spec append_plan_node(Repository.repo(), map()) :: {:ok, PlanNode.t()} | {:error, error()}
  def append_plan_node(repo, attrs), do: Repository.append_plan_node(repo, attrs)

  @spec append_finding(Repository.repo(), map()) :: {:ok, Finding.t()} | {:error, error()}
  def append_finding(repo, attrs), do: Repository.append_finding(repo, attrs)

  @spec append_progress_event(Repository.repo(), map()) :: {:ok, ProgressEvent.t()} | {:error, error()}
  def append_progress_event(repo, attrs), do: Repository.append_progress_event(repo, attrs)

  @spec append_authenticated_progress_event(Repository.repo(), Assignment.t(), map(), keyword()) ::
          {:ok, ProgressEvent.t()} | {:error, error()}
  @spec append_authenticated_progress_event(Repository.repo(), Assignment.t(), map()) ::
          {:ok, ProgressEvent.t()} | {:error, error()}
  def append_authenticated_progress_event(repo, assignment, attrs) do
    append_authenticated_progress_event(repo, assignment, attrs, [])
  end

  @spec append_authenticated_progress_event(Repository.repo(), Assignment.t(), map(), keyword()) ::
          {:ok, ProgressEvent.t()} | {:error, error()}
  def append_authenticated_progress_event(repo, %Assignment{} = assignment, attrs, opts)
      when is_atom(repo) and is_map(attrs) and is_list(opts) do
    with {:ok, idempotency_key} <- idempotency_key(attrs),
         {:ok, work_package_id} <- scoped_work_package_id(assignment, attrs),
         :ok <- reject_duplicate_caller_keys(attrs, [:summary, :body, :status, :payload]) do
      attrs = normalize_keys(attrs)
      payload = Map.get(attrs, "payload", %{})

      insert_attrs =
        attrs
        |> Map.take(["summary", "body", "status"])
        |> Map.put("work_package_id", work_package_id)
        |> Map.put("idempotency_key", idempotency_key)
        |> Map.put("payload", payload)

      Repository.append_audit_progress_event(repo, assignment, insert_attrs, agent_run_id: Keyword.get(opts, :agent_run_id))
    end
  end

  def append_authenticated_progress_event(repo, _assignment, attrs, _opts) when is_atom(repo) and is_map(attrs) do
    {:error, :unauthenticated}
  end

  @spec require_valid_assignment(Repository.repo(), Assignment.t()) :: :ok | {:error, error()}
  def require_valid_assignment(repo, %Assignment{} = assignment) when is_atom(repo) do
    lock_valid_assignment(repo, assignment)
  end

  def require_valid_assignment(repo, _assignment) when is_atom(repo), do: {:error, :unauthenticated}

  @spec append_artifact(Repository.repo(), map()) :: {:ok, Artifact.t()} | {:error, error()}
  def append_artifact(repo, attrs), do: Repository.append_artifact(repo, attrs)

  @spec update_plan_node_status(Repository.repo(), String.t(), String.t()) :: {:ok, PlanNode.t()} | {:error, error()}
  def update_plan_node_status(repo, plan_node_id, status), do: Repository.update_plan_node_status(repo, plan_node_id, status)

  @spec update_plan_node(Repository.repo(), String.t(), map()) :: {:ok, PlanNode.t()} | {:error, Repository.error()}
  def update_plan_node(repo, plan_node_id, attrs), do: Repository.update_plan_node(repo, plan_node_id, attrs)

  @spec get_state(Repository.repo(), String.t()) :: {:ok, State.t()} | {:error, error()}
  def get_state(repo, work_package_id), do: Repository.get_state(repo, work_package_id)

  @spec fetch_timeline(Repository.repo(), Assignment.t()) :: {:ok, [Timeline.item()]} | {:error, error()}
  def fetch_timeline(repo, %Assignment{} = assignment) when is_atom(repo) do
    case repo.transaction(fn -> fetch_timeline_transaction(repo, assignment) end) do
      {:ok, timeline} -> {:ok, timeline}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_timeline(repo, _assignment) when is_atom(repo), do: {:error, :unauthenticated}

  @spec redact_payload(term()) :: term()
  def redact_payload(payload), do: Redactor.redact(payload)

  defp idempotency_key(attrs) do
    values =
      attrs
      |> protected_values(:idempotency_key)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()

    case values do
      [] ->
        {:error, :missing_idempotency_key}

      [""] ->
        {:error, :missing_idempotency_key}

      [value] ->
        {:ok, value}

      _values ->
        {:error, :idempotency_key_conflict}
    end
  end

  defp scoped_work_package_id(%Assignment{work_package_id: assignment_work_package_id}, attrs) do
    case protected_values(attrs, :work_package_id) do
      [] ->
        {:ok, assignment_work_package_id}

      [^assignment_work_package_id] ->
        {:ok, assignment_work_package_id}

      _values ->
        {:error, :work_package_scope_mismatch}
    end
  end

  defp protected_values(attrs, key) do
    [Map.get(attrs, key), Map.get(attrs, Atom.to_string(key))]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp reject_duplicate_caller_keys(attrs, keys) do
    if Enum.any?(keys, &duplicate_key_form?(attrs, &1)) do
      {:error, :conflicting_key_forms}
    else
      :ok
    end
  end

  defp duplicate_key_form?(attrs, key) do
    Map.has_key?(attrs, key) and Map.has_key?(attrs, Atom.to_string(key))
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp fetch_timeline_transaction(repo, %Assignment{} = assignment) do
    with :ok <- lock_valid_assignment(repo, assignment),
         {:ok, timeline} <- Timeline.fetch(repo, assignment.work_package_id) do
      Enum.map(timeline, &scope_timeline_item(&1, assignment))
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp lock_valid_assignment(repo, %Assignment{} = assignment) do
    if is_nil(assignment.claimed_at) or is_nil(assignment.claimed_by) do
      {:error, :assignment_mismatch}
    else
      case repo.update_all(valid_assignment_query(assignment), set: [claimed_by: assignment.claimed_by]) do
        {1, _rows} -> :ok
        {0, _rows} -> assignment_error(repo, assignment.grant_id)
      end
    end
  end

  defp valid_assignment_query(%Assignment{} = assignment) do
    from(grant in AccessGrant,
      where: grant.id == ^assignment.grant_id,
      where: grant.work_package_id == ^assignment.work_package_id,
      where: grant.display_key == ^assignment.display_key,
      where: grant.grant_role == ^assignment.grant_role,
      where: grant.capabilities == ^assignment.capabilities,
      where: grant.claimed_at == ^assignment.claimed_at,
      where: grant.claimed_by == ^assignment.claimed_by,
      where: not is_nil(grant.claimed_at),
      where: not is_nil(grant.claimed_by),
      where: is_nil(grant.revoked_at)
    )
  end

  defp assignment_error(repo, grant_id) do
    case AccessGrantRepository.get(repo, grant_id) do
      {:ok, %AccessGrant{revoked_at: %DateTime{}}} -> {:error, :assignment_revoked}
      _grant -> {:error, :assignment_mismatch}
    end
  end

  defp scope_timeline_item(%{actor: %{access_grant_id: access_grant_id}} = item, %Assignment{} = assignment)
       when access_grant_id == assignment.grant_id do
    item
  end

  defp scope_timeline_item(%{actor: %{access_grant_id: nil}} = item, %Assignment{}), do: item

  defp scope_timeline_item(item, %Assignment{}) do
    %{
      item
      | actor: %{id: nil, type: nil, access_grant_id: nil},
        agent_run_id: nil,
        idempotency_key: nil,
        status: "[redacted]",
        summary: "[redacted]",
        body: nil,
        payload: %{}
    }
  end
end
