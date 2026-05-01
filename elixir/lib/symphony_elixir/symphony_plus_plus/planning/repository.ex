defmodule SymphonyElixir.SymphonyPlusPlus.Planning.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository

  @default_append_retry_attempts 200
  @default_state_read_retry_attempts 50
  @state_item_limit 100

  @type repo :: module()
  @type planning_record :: PlanNode.t() | Finding.t() | ProgressEvent.t() | Artifact.t()
  @type error ::
          :database_busy
          | :id_already_exists
          | :not_found
          | :sequence_conflict
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

  @spec append_plan_node(repo(), map()) :: {:ok, PlanNode.t()} | {:error, error()}
  def append_plan_node(repo, attrs) when is_atom(repo) and is_map(attrs) do
    insert_with_allocated_value(
      repo,
      drop_ordering(attrs, :position),
      PlanNode,
      :position,
      &PlanNode.create_changeset/1
    )
  end

  @spec append_finding(repo(), map()) :: {:ok, Finding.t()} | {:error, error()}
  def append_finding(repo, attrs) when is_atom(repo) and is_map(attrs) do
    insert_with_allocated_value(repo, drop_ordering(attrs, :sequence), Finding, :sequence, &Finding.create_changeset/1)
  end

  @spec append_progress_event(repo(), map()) :: {:ok, ProgressEvent.t()} | {:error, error()}
  def append_progress_event(repo, attrs) when is_atom(repo) and is_map(attrs) do
    insert_with_allocated_value(
      repo,
      drop_ordering(attrs, :sequence),
      ProgressEvent,
      :sequence,
      &ProgressEvent.create_changeset/1
    )
  end

  @spec append_artifact(repo(), map()) :: {:ok, Artifact.t()} | {:error, error()}
  def append_artifact(repo, attrs) when is_atom(repo) and is_map(attrs) do
    insert_with_allocated_value(
      repo,
      drop_ordering(attrs, :sequence),
      Artifact,
      :sequence,
      &Artifact.create_changeset/1
    )
  end

  @spec update_plan_node_status(repo(), String.t(), String.t()) :: {:ok, PlanNode.t()} | {:error, error()}
  def update_plan_node_status(repo, plan_node_id, status)
      when is_atom(repo) and is_binary(plan_node_id) and is_binary(status) do
    case repo.get(PlanNode, plan_node_id) do
      nil ->
        {:error, :not_found}

      %PlanNode{} = plan_node ->
        plan_node
        |> PlanNode.status_changeset(%{status: status})
        |> update(repo)
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_plan_nodes(repo(), String.t()) :: {:ok, [PlanNode.t()]} | {:error, error()}
  def list_plan_nodes(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_all(repo, fn ->
      from(plan_node in PlanNode,
        where: plan_node.work_package_id == ^work_package_id,
        order_by: [asc: plan_node.position, asc: plan_node.created_at, asc: plan_node.id]
      )
    end)
  end

  @spec list_findings(repo(), String.t()) :: {:ok, [Finding.t()]} | {:error, error()}
  def list_findings(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_all(repo, fn ->
      from(finding in Finding,
        where: finding.work_package_id == ^work_package_id,
        order_by: [asc: finding.sequence, asc: finding.id]
      )
    end)
  end

  @spec list_progress_events(repo(), String.t()) :: {:ok, [ProgressEvent.t()]} | {:error, error()}
  def list_progress_events(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_all(repo, fn ->
      from(progress_event in ProgressEvent,
        where: progress_event.work_package_id == ^work_package_id,
        order_by: [asc: progress_event.sequence, asc: progress_event.id]
      )
    end)
  end

  @spec list_artifacts(repo(), String.t()) :: {:ok, [Artifact.t()]} | {:error, error()}
  def list_artifacts(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_all(repo, fn ->
      from(artifact in Artifact,
        where: artifact.work_package_id == ^work_package_id,
        order_by: [asc: artifact.sequence, asc: artifact.id]
      )
    end)
  end

  @spec get_state(repo(), String.t()) :: {:ok, State.t()} | {:error, error()}
  def get_state(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    do_get_state(repo, work_package_id, :full, state_read_retry_attempts())
  end

  @spec get_render_state(repo(), String.t()) :: {:ok, State.t()} | {:error, error()}
  def get_render_state(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    do_get_state(repo, work_package_id, :bounded, state_read_retry_attempts())
  end

  defp do_get_state(repo, work_package_id, mode, attempts_left) do
    repo.transaction(fn ->
      case load_state(repo, work_package_id, mode) do
        {:ok, state} -> state
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> retry_get_state(repo, work_package_id, mode, attempts_left)
  rescue
    error in Exqlite.Error ->
      error
      |> normalize_exqlite_error()
      |> retry_get_state(repo, work_package_id, mode, attempts_left)
  end

  defp retry_get_state({:error, :database_busy}, _repo, _work_package_id, _mode, 0), do: {:error, :database_busy}

  defp retry_get_state({:error, :database_busy}, repo, work_package_id, mode, attempts_left) do
    Process.sleep(retry_delay_ms(attempts_left, state_read_retry_attempts()))
    do_get_state(repo, work_package_id, mode, attempts_left - 1)
  end

  defp retry_get_state(result, _repo, _work_package_id, _mode, _attempts_left), do: result

  defp load_state(repo, work_package_id, :full) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, plan_nodes} <- list_plan_nodes(repo, work_package_id),
         {:ok, findings} <- list_findings(repo, work_package_id),
         {:ok, progress_events} <- list_progress_events(repo, work_package_id),
         {:ok, artifacts} <- list_artifacts(repo, work_package_id) do
      {:ok,
       %State{
         work_package: work_package,
         plan_nodes: plan_nodes,
         findings: findings,
         progress_events: progress_events,
         artifacts: artifacts,
         plan_nodes_omitted_count: 0,
         findings_omitted_count: 0,
         progress_events_omitted_count: 0,
         artifacts_omitted_count: 0
       }}
    end
  end

  defp load_state(repo, work_package_id, :bounded) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {plan_nodes, plan_nodes_omitted_count} <- list_plan_nodes_for_render(repo, work_package_id),
         {findings, findings_omitted_count} <- list_findings_for_render(repo, work_package_id),
         {progress_events, progress_events_omitted_count} <- list_progress_events_for_render(repo, work_package_id),
         {artifacts, artifacts_omitted_count} <- list_artifacts_for_render(repo, work_package_id) do
      {:ok,
       %State{
         work_package: work_package,
         plan_nodes: plan_nodes,
         findings: findings,
         progress_events: progress_events,
         artifacts: artifacts,
         plan_nodes_omitted_count: plan_nodes_omitted_count,
         findings_omitted_count: findings_omitted_count,
         progress_events_omitted_count: progress_events_omitted_count,
         artifacts_omitted_count: artifacts_omitted_count
       }}
    end
  end

  defp list_plan_nodes_for_render(repo, work_package_id) do
    rows =
      repo.all(
        from(plan_node in PlanNode,
          where: plan_node.work_package_id == ^work_package_id,
          order_by: [asc: plan_node.position, asc: plan_node.created_at, asc: plan_node.id],
          limit: @state_item_limit
        )
      )

    {rows, omitted_count(repo, PlanNode, work_package_id, rows)}
  end

  defp list_findings_for_render(repo, work_package_id) do
    rows =
      repo.all(
        from(finding in Finding,
          where: finding.work_package_id == ^work_package_id,
          order_by: [desc: finding.sequence, desc: finding.id],
          limit: @state_item_limit
        )
      )
      |> Enum.reverse()

    {rows, omitted_count(repo, Finding, work_package_id, rows)}
  end

  defp list_progress_events_for_render(repo, work_package_id) do
    rows =
      repo.all(
        from(progress_event in ProgressEvent,
          where: progress_event.work_package_id == ^work_package_id,
          order_by: [desc: progress_event.sequence, desc: progress_event.id],
          limit: @state_item_limit
        )
      )
      |> Enum.reverse()

    {rows, omitted_count(repo, ProgressEvent, work_package_id, rows)}
  end

  defp list_artifacts_for_render(repo, work_package_id) do
    rows =
      repo.all(
        from(artifact in Artifact,
          where: artifact.work_package_id == ^work_package_id,
          order_by: [desc: artifact.sequence, desc: artifact.id],
          limit: @state_item_limit
        )
      )
      |> Enum.reverse()

    {rows, omitted_count(repo, Artifact, work_package_id, rows)}
  end

  defp safe_all(repo, query_fun) do
    {:ok, repo.all(query_fun.())}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp omitted_count(repo, schema, work_package_id, loaded_rows) do
    total =
      repo.one(
        from(row in schema,
          where: row.work_package_id == ^work_package_id,
          select: count(row.id)
        )
      )

    max((total || 0) - length(loaded_rows), 0)
  end

  defp insert_with_allocated_value(repo, attrs, schema, field, changeset_fun) do
    normalized_attrs = normalize_keys(attrs)
    string_field = Atom.to_string(field)
    auto_allocate? = Map.get(normalized_attrs, string_field) in [nil, ""]

    do_insert_with_allocated_value(
      repo,
      normalized_attrs,
      schema,
      field,
      changeset_fun,
      auto_allocate?,
      append_retry_attempts()
    )
  end

  defp do_insert_with_allocated_value(repo, attrs, schema, field, changeset_fun, auto_allocate?, attempts_left) do
    repo
    |> insert_transaction(attrs, schema, field, changeset_fun, auto_allocate?)
    |> handle_insert_result(repo, attrs, schema, field, changeset_fun, auto_allocate?, attempts_left)
  end

  defp insert_transaction(repo, attrs, schema, field, changeset_fun, auto_allocate?) do
    repo.transaction(fn ->
      attrs
      |> maybe_put_next_value(repo, schema, field, auto_allocate?)
      |> changeset_fun.()
      |> insert(repo)
      |> case do
        {:ok, row} -> row
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp handle_insert_result({:ok, row}, _repo, _attrs, _schema, _field, _changeset_fun, _auto_allocate?, _attempts_left) do
    {:ok, row}
  end

  defp handle_insert_result(
         {:error, {:constraint_failed, constraint}},
         repo,
         attrs,
         schema,
         field,
         changeset_fun,
         true,
         attempts_left
       ) do
    if append_order_constraint?(constraint) do
      retry_or_error(repo, attrs, schema, field, changeset_fun, attempts_left, :sequence_conflict)
    else
      {:error, {:constraint_failed, constraint}}
    end
  end

  defp handle_insert_result({:error, :database_busy}, repo, attrs, schema, field, changeset_fun, true, attempts_left) do
    retry_or_error(repo, attrs, schema, field, changeset_fun, attempts_left, :database_busy)
  end

  defp handle_insert_result({:error, reason}, _repo, _attrs, _schema, _field, _changeset_fun, _auto_allocate?, _attempts_left) do
    {:error, reason}
  end

  defp retry_or_error(_repo, _attrs, _schema, _field, _changeset_fun, 0, terminal_error), do: {:error, terminal_error}

  defp retry_or_error(repo, attrs, schema, field, changeset_fun, attempts_left, _terminal_error) do
    Process.sleep(retry_delay_ms(attempts_left, append_retry_attempts()))
    do_insert_with_allocated_value(repo, attrs, schema, field, changeset_fun, true, attempts_left - 1)
  end

  defp retry_delay_ms(attempts_left, total_attempts) do
    used_attempts = max(total_attempts - attempts_left, 0)
    min(100, 5 + used_attempts * 5)
  end

  defp append_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_planning_append_retry_attempts, @default_append_retry_attempts)
    |> max(0)
  end

  defp state_read_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_planning_state_read_retry_attempts, @default_state_read_retry_attempts)
    |> max(0)
  end

  defp maybe_put_next_value(attrs, repo, schema, field, true) do
    if is_binary(Map.get(attrs, "work_package_id")) do
      Map.put(attrs, Atom.to_string(field), next_value(repo, schema, field, Map.fetch!(attrs, "work_package_id")))
    else
      attrs
    end
  end

  defp maybe_put_next_value(attrs, _repo, _schema, _field, false) do
    attrs
  end

  defp next_value(repo, schema, field, work_package_id) do
    current_max =
      repo.one(
        from(row in schema,
          where: row.work_package_id == ^work_package_id,
          select: max(field(row, ^field))
        )
      )

    (current_max || 0) + 1
  end

  defp insert(changeset, repo) do
    changeset
    |> repo.insert()
    |> normalize_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp update(changeset, repo) do
    changeset
    |> repo.update()
    |> normalize_update_result()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp normalize_update_result({:ok, row}), do: {:ok, row}
  defp normalize_update_result({:error, %Changeset{} = changeset}), do: {:error, changeset}

  defp normalize_insert_result({:ok, row}), do: {:ok, row}

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

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    if String.ends_with?(constraint, "_id_unique_index") or String.ends_with?(constraint, "_id_index") or
         String.ends_with?(constraint, "_pkey") do
      {:error, :id_already_exists}
    else
      {:error, {:constraint_failed, constraint}}
    end
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp append_order_constraint?(constraint) when is_binary(constraint) do
    String.contains?(constraint, "_work_package_position_unique_index") or
      String.contains?(constraint, "_work_package_sequence_unique_index") or
      sqlite_append_order_constraint?(constraint)
  end

  defp sqlite_append_order_constraint?(constraint) do
    (String.contains?(constraint, "UNIQUE constraint failed:") and
       (String.contains?(constraint, ".sequence") or String.contains?(constraint, ".position"))) or
      (String.contains?(constraint, "work_package") and
         (String.contains?(constraint, "sequence") or String.contains?(constraint, "position")))
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

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp drop_ordering(attrs, field) do
    attrs
    |> normalize_keys()
    |> Map.drop([Atom.to_string(field)])
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)
end
