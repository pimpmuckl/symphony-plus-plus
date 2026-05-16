defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequestClarificationsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  defmodule RetryRepo do
    alias Ecto.Changeset

    def transaction(fun) do
      Process.put(:transaction_attempts, Process.get(:transaction_attempts, 0) + 1)

      if Process.get(:transient_error) == :database_busy and transient_failure?() do
        {:error, :database_busy}
      else
        {:ok, fun.()}
      end
    catch
      {:rollback, reason} -> {:error, reason}
    end

    def one(_query), do: 0

    def insert(%Changeset{} = changeset) do
      Process.put(:insert_attempts, Process.get(:insert_attempts, 0) + 1)

      if Process.get(:transient_error) == :sequence_conflict and transient_failure?() do
        raise %Ecto.ConstraintError{
          type: :unique,
          constraint: Process.get(:sequence_conflict_name),
          message: "sequence conflict"
        }
      else
        {:ok, Changeset.apply_changes(changeset)}
      end
    end

    def rollback(reason), do: throw({:rollback, reason})

    defp transient_failure? do
      failures_left = Process.get(:transient_failures_left, 0)

      if failures_left > 0 do
        Process.put(:transient_failures_left, failures_left - 1)
        true
      else
        false
      end
    end
  end

  setup_all do
    database_path = database_path()

    start_supervised!({Repo, database: database_path, pool_size: 1})
    assert :ok = Repository.migrate(Repo)

    on_exit(fn -> File.rm(database_path) end)

    {:ok, repo: Repo}
  end

  setup %{repo: repo} do
    repo.delete_all(DecisionLogEntry)
    repo.delete_all(ClarificationQuestion)
    repo.delete_all(WorkRequest)
    :ok
  end

  test "asks and lists clarification questions deterministically", %{repo: repo} do
    work_request = create_work_request!(repo)

    assert {:ok, first} =
             Service.ask_question(
               repo,
               work_request.id,
               question_attrs(
                 id: "WRQ-002",
                 category: "scope",
                 question: "Which repositories are in scope?",
                 asked_by_agent_run_id: "run-1"
               )
             )

    assert first.work_request_id == work_request.id
    assert first.sequence == 1
    assert first.status == "open"
    assert first.answer == nil
    assert first.asked_by_agent_run_id == "run-1"

    assert {:ok, second} =
             Repository.ask_question(
               repo,
               work_request.id,
               question_attrs(id: "WRQ-001", category: "acceptance", question: "What must pass?")
             )

    assert second.sequence == 2
    assert {:ok, [^first, ^second]} = Service.list_questions(repo, work_request.id)
  end

  test "asking a clarification always creates an open unanswered question", %{repo: repo} do
    work_request = create_work_request!(repo)

    assert {:ok, question} =
             Repository.ask_question(
               repo,
               work_request.id,
               question_attrs(
                 id: "WRQ-FORCE-OPEN",
                 status: "answered",
                 answer: "Do not persist this answer.",
                 answered_by: "operator-1",
                 answered_at: ~U[2026-05-11 12:00:00Z]
               )
             )

    assert question.status == "open"
    assert question.answer == nil
    assert question.answered_by == nil
    assert question.answered_at == nil
  end

  test "optional decision prompts persist normalized structured choices", %{repo: repo} do
    work_request = create_work_request!(repo)

    assert {:ok, question} =
             Repository.ask_question(
               repo,
               work_request.id,
               question_attrs(
                 id: "WRQ-DECISION-PROMPT",
                 decision_prompt: %{
                   tl_dr: "Pick the bounded path.",
                   details: "The architect needs a simple product call before slicing.",
                   options: [
                     %{
                       id: "continue",
                       label: "Continue",
                       description: "Proceed with the proposed path.",
                       pros: ["Fastest"],
                       cons: ["Less polish"],
                       answer: "Continue with the proposed path."
                     }
                   ],
                   custom_redirect_label: "No, and tell the agent what to do differently"
                 }
               )
             )

    assert question.decision_prompt == %{
             "tl_dr" => "Pick the bounded path.",
             "details" => "The architect needs a simple product call before slicing.",
             "options" => [
               %{
                 "id" => "continue",
                 "label" => "Continue",
                 "description" => "Proceed with the proposed path.",
                 "pros" => ["Fastest"],
                 "cons" => ["Less polish"],
                 "answer" => "Continue with the proposed path."
               }
             ],
             "custom_redirect_label" => "No, and tell the agent what to do differently"
           }
  end

  test "malformed decision prompts are rejected when present", %{repo: repo} do
    work_request = create_work_request!(repo)

    assert {:error, changeset} =
             Repository.ask_question(
               repo,
               work_request.id,
               question_attrs(
                 id: "WRQ-BAD-DECISION-PROMPT",
                 decision_prompt: %{"tl_dr" => "Missing options", "details" => "No choices."}
               )
             )

    assert %{decision_prompt: ["must contain 1 to 4 options"]} = errors_on(changeset)
  end

  test "decision prompt option ids cannot use the custom redirect sentinel", %{repo: repo} do
    work_request = create_work_request!(repo)

    assert {:error, changeset} =
             Repository.ask_question(
               repo,
               work_request.id,
               question_attrs(
                 id: "WRQ-RESERVED-DECISION-PROMPT",
                 decision_prompt: %{
                   "tl_dr" => "Pick one.",
                   "details" => "Avoid colliding with the freeform redirect option.",
                   "options" => [
                     %{
                       "id" => "__custom_redirect__",
                       "label" => "Use a custom path",
                       "answer" => "Use the custom path."
                     }
                   ]
                 }
               )
             )

    assert %{decision_prompt: ["contains a reserved option id"]} = errors_on(changeset)
  end

  test "answers questions optimistically without mutating WorkRequest status", %{repo: repo} do
    work_request = create_work_request!(repo, status: "clarifying")
    assert {:ok, question} = Repository.ask_question(repo, work_request.id, question_attrs(id: "WRQ-ANSWER"))

    answered_at = ~U[2026-05-11 12:00:00.123456Z]

    assert {:ok, answered} =
             Service.answer_question(repo, question.id, "open", %{
               answer: "Only elixir/lib and focused tests.",
               answered_by: "operator-1",
               answered_at: answered_at
             })

    assert answered.status == "answered"
    assert answered.answer == "Only elixir/lib and focused tests."
    assert answered.answered_by == "operator-1"
    assert DateTime.compare(answered.answered_at, answered_at) == :eq

    assert {:ok, unchanged_request} = Repository.get(repo, work_request.id)
    assert unchanged_request.status == "clarifying"

    assert {:error, :already_answered} =
             Repository.answer_question(repo, question.id, "open", %{
               answer: "Do not overwrite",
               answered_by: "operator-2"
             })

    assert {:ok, [persisted]} = Repository.list_questions(repo, work_request.id)
    assert persisted.answer == "Only elixir/lib and focused tests."
    assert persisted.answered_by == "operator-1"

    assert {:error, :not_found} =
             Repository.answer_question(repo, "WRQ-MISSING", "open", %{answer: "Nope", answered_by: "operator"})

    assert {:ok, stale_question} = Repository.ask_question(repo, work_request.id, question_attrs(id: "WRQ-STALE"))

    assert {:error, :stale_status} =
             Repository.answer_question(repo, stale_question.id, "closed", %{answer: "Stale", answered_by: "operator"})

    assert {:error, :invalid_status} =
             Repository.answer_question(repo, stale_question.id, "waiting", %{answer: "Invalid", answered_by: "operator"})
  end

  test "closes questions without recording answers", %{repo: repo} do
    work_request = create_work_request!(repo)
    assert {:ok, question} = Repository.ask_question(repo, work_request.id, question_attrs(id: "WRQ-CLOSE"))

    assert {:ok, closed} = Service.close_question(repo, question.id, "open")
    assert closed.status == "closed"
    assert closed.answer == nil
    assert closed.answered_by == nil
    assert closed.answered_at == nil

    assert {:error, :already_closed} = Repository.close_question(repo, question.id, "open")

    assert {:error, :already_closed} =
             Repository.answer_question(repo, question.id, "open", %{answer: "Too late", answered_by: "operator"})

    assert {:ok, answered_question} = Repository.ask_question(repo, work_request.id, question_attrs(id: "WRQ-ANSWERED"))

    assert {:ok, _answered} =
             Repository.answer_question(repo, answered_question.id, "open", %{answer: "Done", answered_by: "operator"})

    assert {:error, :already_answered} = Repository.close_question(repo, answered_question.id, "open")
  end

  test "records and lists decision log entries deterministically", %{repo: repo} do
    work_request = create_work_request!(repo)
    first_created_at = ~U[2026-05-11 13:00:00.000000Z]

    assert {:ok, first} =
             Service.record_decision(
               repo,
               work_request.id,
               decision_attrs(
                 id: "WRD-002",
                 source_type: "human",
                 source_id: "comment-1",
                 decision: "Keep the slice backend-only.",
                 created_at: first_created_at
               )
             )

    assert first.work_request_id == work_request.id
    assert first.sequence == 1
    assert first.source_type == "human"
    assert first.source_id == "comment-1"
    assert DateTime.compare(first.created_at, first_created_at) == :eq

    assert {:ok, second} =
             Repository.record_decision(
               repo,
               work_request.id,
               decision_attrs(id: "WRD-001", source_type: "ask_pro_advisory", decision: "Treat Ask Pro as advisory.")
             )

    assert second.sequence == 2
    assert {:ok, [^first, ^second]} = Service.list_decisions(repo, work_request.id)
  end

  test "rejects duplicate ids invalid values and missing WorkRequest foreign keys", %{repo: repo} do
    work_request = create_work_request!(repo)

    assert {:ok, question} = Repository.ask_question(repo, work_request.id, question_attrs(id: "WRQ-DUPLICATE"))
    assert question.id == "WRQ-DUPLICATE"
    assert {:error, :id_already_exists} = Repository.ask_question(repo, work_request.id, question_attrs(id: "WRQ-DUPLICATE"))

    assert {:error, {:constraint_failed, "foreign_key"}} =
             Repository.ask_question(repo, "WR-MISSING", question_attrs(id: "WRQ-MISSING-PARENT"))

    assert {:ok, decision} = Repository.record_decision(repo, work_request.id, decision_attrs(id: "WRD-DUPLICATE"))
    assert decision.id == "WRD-DUPLICATE"
    assert {:error, :id_already_exists} = Repository.record_decision(repo, work_request.id, decision_attrs(id: "WRD-DUPLICATE"))

    assert {:error, %Ecto.Changeset{} = source_type_changeset} =
             Repository.record_decision(repo, work_request.id, decision_attrs(source_type: "bot"))

    assert "is invalid" in errors_on(source_type_changeset).source_type

    assert {:error, {:constraint_failed, "foreign_key"}} =
             Repository.record_decision(repo, "WR-MISSING", decision_attrs(id: "WRD-MISSING-PARENT"))
  end

  test "retries repeated sequence conflicts and database busy responses" do
    with_sequence_retry_attempts(5, fn ->
      assert {{:ok, %ClarificationQuestion{} = question}, transaction_attempts, insert_attempts} =
               with_transient_failures(
                 :sequence_conflict,
                 3,
                 [constraint: "sympp_work_request_questions_work_request_sequence_unique_index"],
                 fn ->
                   Repository.ask_question(RetryRepo, "WR-RETRY", question_attrs(id: "WRQ-RETRY"))
                 end
               )

      assert question.id == "WRQ-RETRY"
      assert question.sequence == 1
      assert transaction_attempts == 4
      assert insert_attempts == 4

      assert {{:ok, %DecisionLogEntry{} = decision}, transaction_attempts, insert_attempts} =
               with_transient_failures(:database_busy, 2, [], fn ->
                 Repository.record_decision(RetryRepo, "WR-RETRY", decision_attrs(id: "WRD-RETRY"))
               end)

      assert decision.id == "WRD-RETRY"
      assert decision.sequence == 1
      assert transaction_attempts == 3
      assert insert_attempts == 1
    end)
  end

  test "returns explicit terminal errors after exhausting sequence retries" do
    with_sequence_retry_attempts(2, fn ->
      assert {{:error, :sequence_conflict}, transaction_attempts, insert_attempts} =
               with_transient_failures(
                 :sequence_conflict,
                 3,
                 [constraint: "sympp_work_request_questions_work_request_sequence_unique_index"],
                 fn ->
                   Repository.ask_question(RetryRepo, "WR-EXHAUSTED", question_attrs(id: "WRQ-EXHAUSTED"))
                 end
               )

      assert transaction_attempts == 3
      assert insert_attempts == 3

      assert {{:error, :database_busy}, transaction_attempts, insert_attempts} =
               with_transient_failures(:database_busy, 3, [], fn ->
                 Repository.record_decision(RetryRepo, "WR-EXHAUSTED", decision_attrs(id: "WRD-EXHAUSTED"))
               end)

      assert transaction_attempts == 3
      assert insert_attempts == 0
    end)
  end

  test "deleting a WorkRequest deletes its clarification and decision records", %{repo: repo} do
    work_request = create_work_request!(repo)
    assert {:ok, _question} = Repository.ask_question(repo, work_request.id, question_attrs())
    assert {:ok, _decision} = Repository.record_decision(repo, work_request.id, decision_attrs())

    repo.delete!(work_request)

    assert {:ok, []} = Repository.list_questions(repo, work_request.id)
    assert {:ok, []} = Repository.list_decisions(repo, work_request.id)
  end

  test "migration is idempotent and creates primary keys plus WorkRequest sequence indexes", %{repo: repo} do
    assert :ok = Repository.migrate(repo)

    assert_primary_key(repo, "sympp_work_request_clarification_questions")
    assert_primary_key(repo, "sympp_work_request_decision_logs")

    question_indexes = index_names(repo, "sympp_work_request_clarification_questions")
    decision_indexes = index_names(repo, "sympp_work_request_decision_logs")

    assert "sympp_work_request_questions_id_unique_index" in question_indexes
    assert "sympp_work_request_questions_work_request_sequence_unique_index" in question_indexes
    assert "sympp_work_request_questions_work_request_status_index" in question_indexes
    assert "sympp_work_request_decision_logs_id_unique_index" in decision_indexes
    assert "sympp_work_request_decision_logs_work_request_sequence_unique_index" in decision_indexes
    assert "sympp_work_request_decision_logs_work_request_source_index" in decision_indexes
  end

  defp create_work_request!(repo, overrides \\ []) do
    assert {:ok, work_request} = Repository.create(repo, work_request_attrs(overrides))
    work_request
  end

  defp work_request_attrs(overrides) do
    defaults = %{
      id: "WR-#{System.unique_integer([:positive])}",
      title: "Improve intake flow",
      repo: "nextide/example",
      base_branch: "main",
      work_type: "feature",
      human_description: "Record the human's desired outcome before slicing.",
      constraints: %{"allowed_paths" => ["elixir/lib"], "forbidden_paths" => [], "requires_secret" => false},
      desired_dispatch_shape: "single_package"
    }

    Enum.into(overrides, defaults)
  end

  defp question_attrs(overrides \\ []) do
    defaults = %{
      category: "scope",
      question: "Which branch should this target?",
      why_needed: "The architect needs the target before slicing."
    }

    Enum.into(overrides, defaults)
  end

  defp decision_attrs(overrides \\ []) do
    defaults = %{
      source_type: "architect",
      decision: "Keep this WorkRequest narrow.",
      rationale: "The next slice owns broader orchestration.",
      scope_impact: "No new runtime tools.",
      created_by: "architect-1"
    }

    Enum.into(overrides, defaults)
  end

  defp with_sequence_retry_attempts(attempts, fun) do
    key = :sympp_work_request_sequence_retry_attempts
    previous = Application.get_env(:symphony_elixir, key)
    Application.put_env(:symphony_elixir, key, attempts)

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, key)
      else
        Application.put_env(:symphony_elixir, key, previous)
      end
    end
  end

  defp with_transient_failures(kind, count, opts, fun) do
    Process.put(:transient_error, kind)
    Process.put(:transient_failures_left, count)
    Process.put(:sequence_conflict_name, Keyword.get(opts, :constraint))
    Process.put(:transaction_attempts, 0)
    Process.put(:insert_attempts, 0)

    try do
      {fun.(), Process.get(:transaction_attempts), Process.get(:insert_attempts)}
    after
      Process.delete(:transient_error)
      Process.delete(:transient_failures_left)
      Process.delete(:sequence_conflict_name)
      Process.delete(:transaction_attempts)
      Process.delete(:insert_attempts)
    end
  end

  defp assert_primary_key(repo, table) do
    %{rows: table_rows} = SQL.query!(repo, "PRAGMA table_info(#{table})")
    assert [_cid, "id", _type, _not_null, _default, 1] = Enum.find(table_rows, &(Enum.at(&1, 1) == "id"))
  end

  defp index_names(repo, table) do
    %{rows: index_rows} = SQL.query!(repo, "PRAGMA index_list(#{table})")
    Enum.map(index_rows, &Enum.at(&1, 1))
  end

  defp database_path do
    Path.join(
      System.tmp_dir!(),
      "sympp-work-request-clarifications-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}.sqlite3"
    )
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", inspect(value))
      end)
    end)
  end
end
