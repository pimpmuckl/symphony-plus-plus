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

  @type repo :: module()
  @type planning_record :: PlanNode.t() | Finding.t() | ProgressEvent.t() | Artifact.t()
  @type error ::
          :database_busy
          | :id_already_exists
          | :not_found
          | :sequence_conflict
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

  @spec append_plan_node(repo(), map()) :: {:ok, PlanNode.t()} | {:error, error()}
  def append_plan_node(repo, attrs) when is_atom(repo) and is_map(attrs) do
    insert_with_allocated_value(repo, attrs, PlanNode, :position, &PlanNode.create_changeset/1)
  end

  @spec append_finding(repo(), map()) :: {:ok, Finding.t()} | {:error, error()}
  def append_finding(repo, attrs) when is_atom(repo) and is_map(attrs) do
    insert_with_allocated_value(repo, attrs, Finding, :sequence, &Finding.create_changeset/1)
  end

  @spec append_progress_event(repo(), map()) :: {:ok, ProgressEvent.t()} | {:error, error()}
  def append_progress_event(repo, attrs) when is_atom(repo) and is_map(attrs) do
    insert_with_allocated_value(repo, attrs, ProgressEvent, :sequence, &ProgressEvent.create_changeset/1)
  end

  @spec append_artifact(repo(), map()) :: {:ok, Artifact.t()} | {:error, error()}
  def append_artifact(repo, attrs) when is_atom(repo) and is_map(attrs) do
    insert_with_allocated_value(repo, attrs, Artifact, :sequence, &Artifact.create_changeset/1)
  end

  @spec list_plan_nodes(repo(), String.t()) :: {:ok, [PlanNode.t()]}
  def list_plan_nodes(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    rows =
      repo.all(
        from(plan_node in PlanNode,
          where: plan_node.work_package_id == ^work_package_id,
          order_by: [asc: plan_node.position, asc: plan_node.created_at, asc: plan_node.id]
        )
      )

    {:ok, rows}
  end

  @spec list_findings(repo(), String.t()) :: {:ok, [Finding.t()]}
  def list_findings(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    rows =
      repo.all(
        from(finding in Finding,
          where: finding.work_package_id == ^work_package_id,
          order_by: [asc: finding.sequence, asc: finding.id]
        )
      )

    {:ok, rows}
  end

  @spec list_progress_events(repo(), String.t()) :: {:ok, [ProgressEvent.t()]}
  def list_progress_events(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    rows =
      repo.all(
        from(progress_event in ProgressEvent,
          where: progress_event.work_package_id == ^work_package_id,
          order_by: [asc: progress_event.sequence, asc: progress_event.id]
        )
      )

    {:ok, rows}
  end

  @spec list_artifacts(repo(), String.t()) :: {:ok, [Artifact.t()]}
  def list_artifacts(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    rows =
      repo.all(
        from(artifact in Artifact,
          where: artifact.work_package_id == ^work_package_id,
          order_by: [asc: artifact.sequence, asc: artifact.id]
        )
      )

    {:ok, rows}
  end

  @spec get_state(repo(), String.t()) :: {:ok, State.t()} | {:error, error()}
  def get_state(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
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
         artifacts: artifacts
       }}
    end
  end

  defp insert_with_allocated_value(repo, attrs, schema, field, changeset_fun) do
    normalized_attrs = normalize_keys(attrs)
    string_field = Atom.to_string(field)
    auto_allocate? = Map.get(normalized_attrs, string_field) in [nil, ""]

    do_insert_with_allocated_value(repo, normalized_attrs, schema, field, changeset_fun, auto_allocate?, 20)
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
      retry_or_conflict(repo, attrs, schema, field, changeset_fun, attempts_left)
    else
      {:error, {:constraint_failed, constraint}}
    end
  end

  defp handle_insert_result({:error, :database_busy}, repo, attrs, schema, field, changeset_fun, true, attempts_left) do
    retry_or_conflict(repo, attrs, schema, field, changeset_fun, attempts_left)
  end

  defp handle_insert_result({:error, reason}, _repo, _attrs, _schema, _field, _changeset_fun, _auto_allocate?, _attempts_left) do
    {:error, reason}
  end

  defp retry_or_conflict(_repo, _attrs, _schema, _field, _changeset_fun, 0), do: {:error, :sequence_conflict}

  defp retry_or_conflict(repo, attrs, schema, field, changeset_fun, attempts_left) do
    Process.sleep(10)
    do_insert_with_allocated_value(repo, attrs, schema, field, changeset_fun, true, attempts_left - 1)
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
      {:error, {:constraint_failed, message}}
    end
  end

  defp migrations_path do
    Application.app_dir(:symphony_elixir, "priv/symphony_plus_plus/repo/migrations")
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)
end
