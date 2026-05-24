defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type error :: Repository.error()

  @spec create(Repository.repo(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def create(repo, attrs), do: Repository.create(repo, attrs)

  @spec get(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def get(repo, id), do: Repository.get(repo, id)

  @spec list(Repository.repo()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  @spec list(Repository.repo(), map()) :: {:ok, [WorkRequest.t()]} | {:error, error()}
  def list(repo, filters \\ %{}), do: Repository.list(repo, filters)

  @spec update(Repository.repo(), String.t(), map()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def update(repo, id, attrs), do: Repository.update(repo, id, attrs)

  @spec update_status(Repository.repo(), String.t(), String.t(), String.t()) ::
          {:ok, WorkRequest.t()} | {:error, error()}
  def update_status(repo, id, current_status, next_status), do: Repository.update_status(repo, id, current_status, next_status)

  @spec ask_question(Repository.repo(), String.t(), map()) :: {:ok, ClarificationQuestion.t()} | {:error, error()}
  def ask_question(repo, work_request_id, attrs), do: Repository.ask_question(repo, work_request_id, attrs)

  @spec list_questions(Repository.repo(), String.t()) :: {:ok, [ClarificationQuestion.t()]} | {:error, error()}
  def list_questions(repo, work_request_id), do: Repository.list_questions(repo, work_request_id)

  @spec answer_question(Repository.repo(), String.t(), String.t(), map()) ::
          {:ok, ClarificationQuestion.t()} | {:error, error()}
  def answer_question(repo, id, current_status, attrs), do: Repository.answer_question(repo, id, current_status, attrs)

  @spec close_question(Repository.repo(), String.t(), String.t()) :: {:ok, ClarificationQuestion.t()} | {:error, error()}
  def close_question(repo, id, current_status), do: Repository.close_question(repo, id, current_status)

  @spec record_decision(Repository.repo(), String.t(), map()) :: {:ok, DecisionLogEntry.t()} | {:error, error()}
  def record_decision(repo, work_request_id, attrs), do: Repository.record_decision(repo, work_request_id, attrs)

  @spec add_planned_slice(Repository.repo(), String.t(), map()) :: {:ok, PlannedSlice.t()} | {:error, error()}
  def add_planned_slice(repo, work_request_id, attrs), do: Repository.add_planned_slice(repo, work_request_id, attrs)

  @spec list_planned_slices(Repository.repo(), String.t()) :: {:ok, [PlannedSlice.t()]} | {:error, error()}
  def list_planned_slices(repo, work_request_id), do: Repository.list_planned_slices(repo, work_request_id)

  @spec get_planned_slice(Repository.repo(), String.t(), String.t()) :: {:ok, PlannedSlice.t()} | {:error, error()}
  def get_planned_slice(repo, work_request_id, id), do: Repository.get_planned_slice(repo, work_request_id, id)

  @spec approve_planned_slice(Repository.repo(), String.t(), String.t(), String.t()) ::
          {:ok, PlannedSlice.t()} | {:error, error()}
  def approve_planned_slice(repo, work_request_id, id, current_status),
    do: Repository.approve_planned_slice(repo, work_request_id, id, current_status)

  @spec skip_planned_slice(Repository.repo(), String.t(), String.t(), String.t()) ::
          {:ok, PlannedSlice.t()} | {:error, error()}
  def skip_planned_slice(repo, work_request_id, id, current_status),
    do: Repository.skip_planned_slice(repo, work_request_id, id, current_status)

  @spec dispatch_planned_slice(Repository.repo(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, PlannedSlice.t()} | {:error, error()}
  def dispatch_planned_slice(repo, work_request_id, id, current_status, work_package_id),
    do: Repository.dispatch_planned_slice(repo, work_request_id, id, current_status, work_package_id)

  @spec mark_sliced(Repository.repo(), String.t(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def mark_sliced(repo, id, current_status), do: Repository.mark_sliced(repo, id, current_status)

  @spec list_decisions(Repository.repo(), String.t()) :: {:ok, [DecisionLogEntry.t()]} | {:error, error()}
  def list_decisions(repo, work_request_id), do: Repository.list_decisions(repo, work_request_id)

  @spec refresh_completion(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def refresh_completion(repo, work_request_id), do: Completion.refresh(repo, work_request_id)

  @spec force_complete(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def force_complete(repo, work_request_id), do: Completion.force_complete(repo, work_request_id)

  @spec archive(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error() | :not_completed}
  def archive(repo, work_request_id), do: Completion.archive(repo, work_request_id)

  @spec restore(Repository.repo(), String.t()) :: {:ok, WorkRequest.t()} | {:error, error()}
  def restore(repo, work_request_id), do: Completion.restore(repo, work_request_id)

  @spec retention_pass(Repository.repo()) ::
          {:ok, Completion.retention_summary()} | {:error, error() | :invalid_archive_after_days | :not_completed}
  @spec retention_pass(Repository.repo(), keyword()) ::
          {:ok, Completion.retention_summary()} | {:error, error() | :invalid_archive_after_days | :not_completed}
  def retention_pass(repo, opts \\ []), do: Completion.retention_pass(repo, opts)
end
