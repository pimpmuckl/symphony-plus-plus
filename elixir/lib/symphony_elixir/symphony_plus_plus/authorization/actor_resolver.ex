defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.ActorResolver do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session

  @spec from_session(Session.t() | nil) :: {:ok, Actor.t()} | {:error, :missing_session | :invalid_session}
  def from_session(session), do: from_session(session, [])

  @spec from_session(Session.t() | nil, keyword()) :: {:ok, Actor.t()} | {:error, :missing_session | :invalid_session}
  def from_session(%Session{assignment: %Assignment{} = assignment}, opts) do
    {:ok, from_assignment(assignment, opts)}
  end

  def from_session(nil, _opts), do: {:error, :missing_session}
  def from_session(_session, _opts), do: {:error, :invalid_session}

  @spec from_assignment(Assignment.t(), keyword()) :: Actor.t()
  def from_assignment(%Assignment{} = assignment, opts \\ []) do
    assignment.grant_role
    |> Actor.normalize_role()
    |> actor_from_assignment(assignment, opts)
  end

  @spec local_operator(String.t(), keyword()) :: Actor.t()
  def local_operator(id \\ "local_operator", opts \\ []) when is_binary(id) do
    Actor.new(:operator,
      id: id,
      scopes: [Scope.ledger(metadata: %{trusted_local: true})],
      capabilities: Keyword.get(opts, :capabilities, []),
      source: :local_operator,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp actor_from_assignment(:worker, %Assignment{} = assignment, opts) do
    Actor.new(:worker,
      id: assignment.claimed_by,
      scopes: assignment_scopes(assignment) || worker_scopes(assignment, opts),
      capabilities: assignment.capabilities || [],
      source: :mcp_assignment,
      metadata: assignment_metadata(assignment)
    )
  end

  defp actor_from_assignment(:architect, %Assignment{} = assignment, opts) do
    Actor.new(:architect,
      id: assignment.claimed_by,
      scopes: architect_assignment_scopes(assignment, opts),
      capabilities: assignment.capabilities || [],
      source: :mcp_assignment,
      metadata: assignment_metadata(assignment)
    )
  end

  defp actor_from_assignment(:operator, %Assignment{} = assignment, _opts) do
    Actor.new(:operator,
      id: assignment.claimed_by,
      scopes: operator_scopes(assignment),
      capabilities: assignment.capabilities || [],
      source: :mcp_assignment,
      metadata: assignment_metadata(assignment)
    )
  end

  defp actor_from_assignment(role, %Assignment{} = assignment, _opts) do
    Actor.new(role,
      id: assignment.claimed_by,
      scopes: assignment_scopes(assignment) || [],
      capabilities: assignment.capabilities || [],
      source: :mcp_assignment,
      metadata: assignment_metadata(assignment)
    )
  end

  defp assignment_scopes(%Assignment{scopes: scopes}) when is_list(scopes) and scopes != [], do: scopes
  defp assignment_scopes(%Assignment{}), do: nil

  defp worker_scopes(%Assignment{work_package_id: work_package_id}, _opts) when is_binary(work_package_id) do
    [Scope.work_package(work_package_id)]
  end

  defp worker_scopes(%Assignment{}, _opts), do: []

  defp operator_scopes(%Assignment{} = assignment) do
    ledger_scopes = [Scope.ledger(metadata: %{source: :mcp_assignment})]

    case assignment_scopes(assignment) do
      nil -> ledger_scopes
      scopes -> merge_scopes(ledger_scopes, scopes)
    end
  end

  defp architect_assignment_scopes(%Assignment{} = assignment, opts) do
    persisted_scopes = assignment_scopes(assignment)
    fallback_scopes = architect_scopes(assignment, opts)

    cond do
      is_nil(persisted_scopes) -> fallback_scopes
      Enum.any?(persisted_scopes, &match?(%Scope{type: :work_request}, &1)) -> persisted_scopes
      true -> merge_scopes(persisted_scopes, fallback_scopes)
    end
  end

  defp architect_scopes(%Assignment{} = assignment, opts) do
    [
      optional_work_request_scope(Keyword.get(opts, :work_request_id)),
      optional_work_package_scope(assignment.work_package_id),
      optional_repo_scope(Keyword.get(opts, :repo), Keyword.get(opts, :base_branch)),
      optional_phase_scope(assignment.phase_id, Keyword.get(opts, :repo), Keyword.get(opts, :base_branch))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp optional_work_request_scope(work_request_id) when is_binary(work_request_id), do: Scope.work_request(work_request_id)
  defp optional_work_request_scope(_work_request_id), do: nil

  defp optional_work_package_scope(work_package_id) when is_binary(work_package_id) do
    Scope.work_package(work_package_id, metadata: %{anchor: true})
  end

  defp optional_work_package_scope(_work_package_id), do: nil

  defp optional_repo_scope(repo, base_branch) when is_binary(repo), do: Scope.repo(repo, base_branch)
  defp optional_repo_scope(_repo, _base_branch), do: nil

  defp optional_phase_scope(phase_id, repo, base_branch)
       when is_binary(phase_id) and is_binary(repo) and is_binary(base_branch) do
    Scope.phase(phase_id, repo: repo, base_branch: base_branch, metadata: %{migration_only: true})
  end

  defp optional_phase_scope(_phase_id, _repo, _base_branch), do: nil

  defp merge_scopes(scopes, fallback_scopes) do
    scope_keys = MapSet.new(Enum.map(scopes, &scope_key/1))
    scopes ++ Enum.reject(fallback_scopes, &(scope_key(&1) in scope_keys))
  end

  defp scope_key(%Scope{type: :repo, repo: repo, base_branch: base_branch}), do: {:repo, repo, base_branch}
  defp scope_key(%Scope{type: type, id: id}), do: {type, id}

  defp assignment_metadata(%Assignment{} = assignment) do
    %{
      grant_id: assignment.grant_id,
      display_key: assignment.display_key,
      phase_id: assignment.phase_id,
      work_package_id: assignment.work_package_id
    }
  end
end
