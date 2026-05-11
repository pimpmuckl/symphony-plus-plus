defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository do
  @moduledoc false

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @default_sequence_retry_attempts 200
  @question_create_ignored_attrs [
    "answer",
    "answered_at",
    "answered_by",
    "created_at",
    "inserted_at",
    "sequence",
    "status",
    "updated_at"
  ]
  @planned_slice_create_ignored_attrs [
    "created_at",
    "dispatched_at",
    "inserted_at",
    "sequence",
    "updated_at",
    "work_package_id"
  ]

  @type repo :: module()
  @type error ::
          :already_answered
          | :already_closed
          | :database_busy
          | :not_found
          | :id_already_exists
          | :invalid_status
          | :sequence_conflict
          | :stale_status
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

  @spec create(repo(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def create(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs
    |> WorkRequest.create_changeset()
    |> repo.insert()
    |> normalize_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get(repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(WorkRequest, id) do
      nil -> {:error, :not_found}
      work_request -> {:ok, work_request}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list(repo()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  @spec list(repo(), map()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  def list(repo, filters \\ %{}) when is_atom(repo) and is_map(filters) do
    work_requests =
      repo.all(
        filters
        |> normalize_keys()
        |> list_query()
      )

    {:ok, work_requests}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update(repo(), String.t(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def update(repo, id, attrs) when is_atom(repo) and is_binary(id) and is_map(attrs) do
    with {:ok, work_request} <- get(repo, id) do
      work_request
      |> WorkRequest.update_changeset(attrs)
      |> repo.update()
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update_status(repo(), String.t(), String.t(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def update_status(repo, id, current_status, next_status)
      when is_atom(repo) and is_binary(id) and is_binary(current_status) and is_binary(next_status) do
    with :ok <- validate_status(current_status),
         :ok <- validate_status(next_status) do
      update_valid_status(repo, id, current_status, next_status)
    end
  end

  @spec ask_question(repo(), String.t(), map()) :: {:ok, ClarificationQuestion.t()} | {:error, error()}
  def ask_question(repo, work_request_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_map(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.drop(@question_create_ignored_attrs)
      |> Map.put("work_request_id", work_request_id)
      |> Map.put("status", "open")

    insert_with_sequence(repo, attrs, &next_question_sequence/2, &ClarificationQuestion.create_changeset/1)
  end

  @spec list_questions(repo(), String.t()) :: {:ok, [ClarificationQuestion.t()]} | {:error, error()}
  def list_questions(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    questions =
      repo.all(
        from(question in ClarificationQuestion,
          where: question.work_request_id == ^work_request_id,
          order_by: [asc: question.sequence, asc: question.id]
        )
      )

    {:ok, questions}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec answer_question(repo(), String.t(), String.t(), map()) :: {:ok, ClarificationQuestion.t()} | {:error, error()}
  def answer_question(repo, id, current_status, attrs)
      when is_atom(repo) and is_binary(id) and is_binary(current_status) and is_map(attrs) do
    with :ok <- validate_question_status(current_status),
         {:ok, answer} <- normalize_answer(attrs) do
      answer_valid_question(repo, id, current_status, answer)
    end
  end

  @spec close_question(repo(), String.t(), String.t()) :: {:ok, ClarificationQuestion.t()} | {:error, error()}
  def close_question(repo, id, current_status)
      when is_atom(repo) and is_binary(id) and is_binary(current_status) do
    with :ok <- validate_question_status(current_status) do
      close_valid_question(repo, id, current_status)
    end
  end

  @spec record_decision(repo(), String.t(), map()) :: {:ok, DecisionLogEntry.t()} | {:error, error()}
  def record_decision(repo, work_request_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_map(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.drop(["sequence", "inserted_at", "updated_at"])
      |> Map.put("work_request_id", work_request_id)

    insert_with_sequence(repo, attrs, &next_decision_sequence/2, &DecisionLogEntry.create_changeset/1)
  end

  @spec add_planned_slice(repo(), String.t(), map()) :: {:ok, PlannedSlice.t()} | {:error, error()}
  def add_planned_slice(repo, work_request_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_map(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.drop(@planned_slice_create_ignored_attrs)
      |> Map.put("work_request_id", work_request_id)

    insert_with_sequence(repo, attrs, &next_planned_slice_sequence/2, &PlannedSlice.create_changeset/1)
  end

  @spec list_planned_slices(repo(), String.t()) :: {:ok, [PlannedSlice.t()]} | {:error, error()}
  def list_planned_slices(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    planned_slices =
      repo.all(
        from(planned_slice in PlannedSlice,
          where: planned_slice.work_request_id == ^work_request_id,
          order_by: [asc: planned_slice.sequence, asc: planned_slice.id]
        )
      )

    {:ok, planned_slices}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_decisions(repo(), String.t()) :: {:ok, [DecisionLogEntry.t()]} | {:error, error()}
  def list_decisions(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    decisions =
      repo.all(
        from(decision in DecisionLogEntry,
          where: decision.work_request_id == ^work_request_id,
          order_by: [asc: decision.sequence, asc: decision.id]
        )
      )

    {:ok, decisions}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp list_query(filters) do
    base_query =
      from(work_request in WorkRequest,
        order_by: [asc: work_request.inserted_at, asc: work_request.id]
      )

    Enum.reduce(filters, base_query, fn
      {"status", status}, query when is_binary(status) and status != "" ->
        from(work_request in query, where: work_request.status == ^status)

      {"repo", repo}, query when is_binary(repo) and repo != "" ->
        from(work_request in query, where: work_request.repo == ^repo)

      {"base_branch", base_branch}, query when is_binary(base_branch) and base_branch != "" ->
        from(work_request in query, where: work_request.base_branch == ^base_branch)

      _filter, query ->
        query
    end)
  end

  defp update_valid_status(repo, id, current_status, next_status) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      id
      |> status_update_query(current_status)
      |> repo.update_all(set: [status: next_status, updated_at: now])
      |> case do
        {1, _rows} -> repo.get!(WorkRequest, id)
        {0, _rows} -> repo.rollback(stale_status_error(repo, id))
      end
    end)
    |> case do
      {:ok, work_request} -> {:ok, work_request}
      {:error, error} -> error
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp validate_status(status) do
    if status in WorkRequest.statuses() do
      :ok
    else
      {:error, :invalid_status}
    end
  end

  defp validate_question_status(status) do
    if status in ClarificationQuestion.statuses() do
      :ok
    else
      {:error, :invalid_status}
    end
  end

  defp stale_status_error(repo, id) do
    case get(repo, id) do
      {:ok, _work_request} -> {:error, :stale_status}
      {:error, :not_found} = error -> error
      {:error, reason} -> {:error, reason}
    end
  end

  defp status_update_query(id, current_status) do
    from(work_request in WorkRequest,
      where: work_request.id == ^id and work_request.status == ^current_status
    )
  end

  defp insert_with_sequence(repo, attrs, next_sequence, changeset_fun) do
    do_insert_with_sequence(repo, attrs, next_sequence, changeset_fun, sequence_retry_attempts())
  end

  defp do_insert_with_sequence(repo, attrs, next_sequence, changeset_fun, attempts_left) do
    repo
    |> insert_sequence_transaction(attrs, next_sequence, changeset_fun)
    |> handle_sequence_insert_result(repo, attrs, next_sequence, changeset_fun, attempts_left)
  end

  defp insert_sequence_transaction(repo, attrs, next_sequence, changeset_fun) do
    repo.transaction(fn ->
      attrs = Map.put(attrs, "sequence", next_sequence.(repo, Map.fetch!(attrs, "work_request_id")))

      attrs
      |> changeset_fun.()
      |> repo.insert()
      |> normalize_insert_result()
      |> case do
        {:ok, record} -> record
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp handle_sequence_insert_result({:ok, record}, _repo, _attrs, _next_sequence, _changeset_fun, _attempts_left) do
    {:ok, record}
  end

  defp handle_sequence_insert_result(
         {:error, {:constraint_failed, constraint}},
         repo,
         attrs,
         next_sequence,
         changeset_fun,
         attempts_left
       ) do
    if sequence_constraint?(constraint) do
      retry_or_error(repo, attrs, next_sequence, changeset_fun, attempts_left, :sequence_conflict)
    else
      {:error, {:constraint_failed, constraint}}
    end
  end

  defp handle_sequence_insert_result({:error, :database_busy}, repo, attrs, next_sequence, changeset_fun, attempts_left) do
    retry_or_error(repo, attrs, next_sequence, changeset_fun, attempts_left, :database_busy)
  end

  defp handle_sequence_insert_result({:error, reason}, _repo, _attrs, _next_sequence, _changeset_fun, _attempts_left) do
    {:error, reason}
  end

  defp retry_or_error(_repo, _attrs, _next_sequence, _changeset_fun, 0, terminal_error), do: {:error, terminal_error}

  defp retry_or_error(repo, attrs, next_sequence, changeset_fun, attempts_left, _terminal_error) do
    Process.sleep(retry_delay_ms(attempts_left, sequence_retry_attempts()))
    do_insert_with_sequence(repo, attrs, next_sequence, changeset_fun, attempts_left - 1)
  end

  defp retry_delay_ms(attempts_left, total_attempts) do
    used_attempts = max(total_attempts - attempts_left, 0)
    min(100, 5 + used_attempts * 5)
  end

  defp sequence_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_work_request_sequence_retry_attempts, @default_sequence_retry_attempts)
    |> max(0)
  end

  defp next_question_sequence(repo, work_request_id) do
    next_sequence(repo, ClarificationQuestion, work_request_id)
  end

  defp next_decision_sequence(repo, work_request_id) do
    next_sequence(repo, DecisionLogEntry, work_request_id)
  end

  defp next_planned_slice_sequence(repo, work_request_id) do
    next_sequence(repo, PlannedSlice, work_request_id)
  end

  defp next_sequence(repo, schema, work_request_id) do
    max_sequence =
      repo.one(
        from(record in schema,
          where: record.work_request_id == ^work_request_id,
          select: max(record.sequence)
        )
      )

    (max_sequence || 0) + 1
  end

  defp normalize_answer(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("answered_at", DateTime.utc_now(:microsecond))

    attrs
    |> ClarificationQuestion.answer_changeset()
    |> Changeset.apply_action(:update)
  end

  defp answer_valid_question(repo, id, current_status, answer) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      id
      |> answer_question_query(current_status)
      |> repo.update_all(
        set: [
          status: "answered",
          answer: answer.answer,
          answered_by: answer.answered_by,
          answered_at: answer.answered_at,
          updated_at: now
        ]
      )
      |> case do
        {1, _rows} -> repo.get!(ClarificationQuestion, id)
        {0, _rows} -> repo.rollback(question_terminal_error(repo, id, current_status))
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp close_valid_question(repo, id, current_status) do
    now = DateTime.utc_now(:microsecond)

    repo.transaction(fn ->
      id
      |> close_question_query(current_status)
      |> repo.update_all(set: [status: "closed", updated_at: now])
      |> case do
        {1, _rows} -> repo.get!(ClarificationQuestion, id)
        {0, _rows} -> repo.rollback(question_terminal_error(repo, id, current_status))
      end
    end)
    |> normalize_transaction_result()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp answer_question_query(id, current_status) do
    from(question in ClarificationQuestion,
      where:
        question.id == ^id and question.status == ^current_status and question.status == "open" and
          is_nil(question.answer)
    )
  end

  defp close_question_query(id, current_status) do
    from(question in ClarificationQuestion,
      where:
        question.id == ^id and question.status == ^current_status and question.status == "open" and
          is_nil(question.answer)
    )
  end

  defp question_terminal_error(repo, id, current_status) do
    case repo.get(ClarificationQuestion, id) do
      nil -> :not_found
      %ClarificationQuestion{status: "closed"} -> :already_closed
      %ClarificationQuestion{status: "answered"} -> :already_answered
      %ClarificationQuestion{answer: answer} when not is_nil(answer) -> :already_answered
      %ClarificationQuestion{status: status} when status != current_status -> :stale_status
      %ClarificationQuestion{} -> :stale_status
    end
  end

  defp normalize_insert_result({:ok, work_request}), do: {:ok, work_request}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    if duplicate_id?(changeset) do
      {:error, :id_already_exists}
    else
      {:error, changeset}
    end
  end

  defp normalize_transaction_result({:ok, record}), do: {:ok, record}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    if duplicate_id_constraint?(constraint) do
      {:error, :id_already_exists}
    else
      {:error, {:constraint_failed, constraint}}
    end
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

  defp duplicate_id_constraint?(constraint) do
    constraint in [
      "sympp_work_requests_id_unique_index",
      "sympp_work_requests_id_index",
      "sympp_work_request_questions_id_unique_index",
      "sympp_work_request_clarification_questions_id_index",
      "sympp_work_request_decision_logs_id_unique_index",
      "sympp_work_request_decision_logs_id_index",
      "sympp_work_request_planned_slices_id_unique_index",
      "sympp_work_request_planned_slices_id_index"
    ] or
      (String.contains?(constraint, "sympp_work_requests") and String.contains?(constraint, ".id")) or
      (String.contains?(constraint, "sympp_work_request_clarification_questions") and
         String.contains?(constraint, ".id")) or
      (String.contains?(constraint, "sympp_work_request_decision_logs") and String.contains?(constraint, ".id")) or
      (String.contains?(constraint, "sympp_work_request_planned_slices") and String.contains?(constraint, ".id"))
  end

  defp sequence_constraint?(constraint) do
    constraint in [
      "sympp_work_request_questions_work_request_sequence_unique_index",
      "sympp_work_request_decision_logs_work_request_sequence_unique_index",
      "sympp_work_request_planned_slices_work_request_sequence_unique_index"
    ] or
      (String.contains?(constraint, "sympp_work_request_clarification_questions") and
         String.contains?(constraint, "sequence")) or
      (String.contains?(constraint, "sympp_work_request_decision_logs") and String.contains?(constraint, "sequence")) or
      (String.contains?(constraint, "sympp_work_request_planned_slices") and String.contains?(constraint, "sequence"))
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp put_new_value(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""] do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  @doc false
  @spec migrations_path() :: Path.t()
  def migrations_path do
    Application.app_dir(:symphony_elixir, "priv/symphony_plus_plus/repo/migrations")
  end
end
