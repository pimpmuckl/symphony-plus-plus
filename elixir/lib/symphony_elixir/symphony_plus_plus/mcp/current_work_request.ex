defmodule SymphonyElixir.SymphonyPlusPlus.MCP.CurrentWorkRequest do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session

  @spec id_argument(map(), Session.t()) :: {:ok, String.t()} | {:tool_error, String.t()}
  def id_argument(arguments, %Session{} = session) when is_map(arguments) do
    case Map.fetch(arguments, "work_request_id") do
      :error -> current_id(session)
      {:ok, value} -> explicit_id(value)
    end
  end

  @spec single_scope?(Session.t()) :: boolean()
  def single_scope?(%Session{assignment: %Assignment{grant_role: "architect", scopes: scopes}}) do
    match?([_id], work_request_scope_ids(scopes))
  end

  def single_scope?(%Session{}), do: false

  defp explicit_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:tool_error, "missing_work_request_id"}
      id -> {:ok, id}
    end
  end

  defp explicit_id(_value), do: {:tool_error, "missing_work_request_id"}

  defp current_id(%Session{assignment: %Assignment{grant_role: "architect", scopes: scopes}}) do
    case work_request_scope_ids(scopes) do
      [id] -> {:ok, id}
      [] -> {:tool_error, "missing_work_request_id"}
      _ids -> {:tool_error, "ambiguous_work_request_id"}
    end
  end

  defp current_id(%Session{}), do: {:tool_error, "missing_work_request_id"}

  defp work_request_scope_ids(scopes) when is_list(scopes) do
    scopes
    |> Enum.flat_map(fn
      %Scope{type: :work_request, id: id} when is_binary(id) -> [String.trim(id)]
      _scope -> []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp work_request_scope_ids(_scopes), do: []
end
