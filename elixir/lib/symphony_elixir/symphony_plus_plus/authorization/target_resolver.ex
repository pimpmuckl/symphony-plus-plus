defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.TargetResolver do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Target
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session

  @spec current_worker_package(Session.t() | Assignment.t()) ::
          {:ok, Target.t()} | {:error, :missing_work_package_scope}
  def current_worker_package(session_or_assignment), do: current_worker_package(session_or_assignment, [])

  @spec current_worker_package(Session.t() | Assignment.t(), keyword()) ::
          {:ok, Target.t()} | {:error, :missing_work_package_scope}
  def current_worker_package(%Session{assignment: %Assignment{} = assignment}, opts) do
    current_worker_package(assignment, opts)
  end

  def current_worker_package(%Assignment{work_package_id: work_package_id}, opts) when is_binary(work_package_id) do
    {:ok, Target.work_package(work_package_id, opts)}
  end

  def current_worker_package(%Assignment{}, _opts), do: {:error, :missing_work_package_scope}

  @spec architect_work_request(Session.t() | Assignment.t(), keyword()) ::
          {:ok, Target.t()} | {:error, :missing_work_request_scope}
  def architect_work_request(%Session{assignment: %Assignment{} = assignment}, opts) do
    architect_work_request(assignment, opts)
  end

  def architect_work_request(%Assignment{} = assignment, opts) do
    case Keyword.get(opts, :work_request_id) do
      work_request_id when is_binary(work_request_id) ->
        opts =
          opts
          |> Keyword.delete(:work_request_id)
          |> Keyword.put_new(:phase_id, assignment.phase_id)

        {:ok, Target.work_request(work_request_id, opts)}

      _work_request_id ->
        {:error, :missing_work_request_scope}
    end
  end

  @spec local_operator_ledger(keyword()) :: Target.t()
  def local_operator_ledger(opts \\ []), do: Target.ledger(opts)
end
