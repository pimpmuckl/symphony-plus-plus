defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.Target do
  @moduledoc false

  @enforce_keys [:type]
  defstruct [
    :type,
    :id,
    :repo,
    :base_branch,
    :phase_id,
    :work_request_id,
    :planned_slice_id,
    :work_package_id,
    resolution: :resolved,
    metadata: %{}
  ]

  @type type ::
          :ledger
          | :repo
          | :work_request
          | :planned_slice
          | :work_package
          | :task_plan
          | :progress
          | :finding
          | :validation_note
          | :review_evidence
          | :blocker
          | :comment
          | :guidance_request
          | :delivery_board
          | :delivery_closeout
          | :dashboard

  @type resolution :: :resolved | :not_found | :ambiguous | :runtime_lease_conflict

  @type t :: %__MODULE__{
          type: type(),
          id: String.t() | nil,
          repo: String.t() | nil,
          base_branch: String.t() | nil,
          phase_id: String.t() | nil,
          work_request_id: String.t() | nil,
          planned_slice_id: String.t() | nil,
          work_package_id: String.t() | nil,
          resolution: resolution(),
          metadata: map()
        }

  @spec ledger(keyword()) :: t()
  def ledger(opts \\ []), do: new(:ledger, nil, opts)

  @spec repo(String.t(), String.t() | nil, keyword()) :: t()
  def repo(repo, base_branch \\ nil, opts \\ []) when is_binary(repo) do
    new(:repo, nil, Keyword.merge(opts, repo: repo, base_branch: base_branch))
  end

  @spec work_request(String.t(), keyword()) :: t()
  def work_request(id, opts \\ []) when is_binary(id) do
    new(:work_request, id, Keyword.put(opts, :work_request_id, id))
  end

  @spec planned_slice(String.t(), String.t(), keyword()) :: t()
  def planned_slice(id, work_request_id, opts \\ []) when is_binary(id) and is_binary(work_request_id) do
    opts =
      opts
      |> Keyword.put(:work_request_id, work_request_id)
      |> Keyword.put(:planned_slice_id, id)

    new(:planned_slice, id, opts)
  end

  @spec work_package(String.t(), keyword()) :: t()
  def work_package(id, opts \\ []) when is_binary(id) do
    new(:work_package, id, Keyword.put(opts, :work_package_id, id))
  end

  @spec package_resource(type(), String.t(), keyword()) :: t()
  def package_resource(type, work_package_id, opts \\ [])
      when type in [
             :task_plan,
             :progress,
             :finding,
             :validation_note,
             :review_evidence,
             :blocker,
             :comment,
             :guidance_request
           ] and
             is_binary(work_package_id) do
    opts = Keyword.put(opts, :work_package_id, work_package_id)
    new(type, Keyword.get(opts, :id), opts)
  end

  @spec new(type(), String.t() | nil, keyword()) :: t()
  def new(type, id \\ nil, opts \\ []) do
    %__MODULE__{
      type: type,
      id: id,
      repo: Keyword.get(opts, :repo),
      base_branch: Keyword.get(opts, :base_branch),
      phase_id: Keyword.get(opts, :phase_id),
      work_request_id: Keyword.get(opts, :work_request_id),
      planned_slice_id: Keyword.get(opts, :planned_slice_id),
      work_package_id: Keyword.get(opts, :work_package_id),
      resolution: Keyword.get(opts, :resolution, :resolved),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec resolved?(t()) :: boolean()
  def resolved?(%__MODULE__{resolution: :resolved}), do: true
  def resolved?(%__MODULE__{}), do: false
end
