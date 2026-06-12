defmodule SymphonyElixir.SymphonyPlusPlus.AgentFormat.LifecycleVocabulary do
  @moduledoc false

  @presentations %{
    "ready" => {"ready", "Ready"},
    "working" => {"working", "Working"},
    "blocked" => {"blocked", "Blocked"},
    "needs_review" => {"needs_review", "Needs Review"},
    "delivered" => {"delivered", "Delivered"},
    "stale_recoverable" => {"stale_recoverable", "Stale / Recoverable"},
    "operator_action" => {"operator_action", "Operator Action"}
  }

  @source_to_presentation %{
    "abandoned" => "delivered",
    "active" => "working",
    "blocked" => "blocked",
    "ci_waiting" => "needs_review",
    "clarifying" => "operator_action",
    "closed" => "delivered",
    "completed" => "delivered",
    "completed_no_pr" => "delivered",
    "created" => "ready",
    "delivered" => "delivered",
    "dispatched" => "ready",
    "draft" => "ready",
    "human_info_needed" => "operator_action",
    "idle" => "ready",
    "merge_ready" => "needs_review",
    "merged" => "delivered",
    "merging" => "working",
    "needs_attention" => "operator_action",
    "needs_closeout" => "operator_action",
    "needs_review" => "needs_review",
    "not_started" => "ready",
    "operator_action" => "operator_action",
    "paused" => "operator_action",
    "planned" => "ready",
    "prepared" => "ready",
    "pr_merged" => "delivered",
    "ready" => "ready",
    "ready_for_slicing" => "ready",
    "ready_for_worker" => "ready",
    "recycled" => "stale_recoverable",
    "reviewing" => "needs_review",
    "skipped" => "delivered",
    "sliced" => "ready",
    "stale" => "stale_recoverable",
    "stale_recoverable" => "stale_recoverable",
    "started_paused" => "stale_recoverable",
    "superseded" => "delivered",
    "terminal" => "delivered",
    "unknown" => "operator_action",
    "working" => "working"
  }

  @doc false
  @spec present(String.t() | nil, String.t() | nil) :: %{key: String.t(), label: String.t(), source_key: String.t()}
  def present(source_key, _source_label \\ nil) do
    source_key = normalized_source_key(source_key)
    presentation_key = Map.get(@source_to_presentation, source_key, "operator_action")
    {key, label} = Map.fetch!(@presentations, presentation_key)

    %{key: key, label: label, source_key: source_key}
  end

  @doc false
  @spec source_key(map()) :: String.t() | nil
  def source_key(%{} = state), do: map_value(state, :source_key) || map_value(state, :key)
  def source_key(_state), do: nil

  defp normalized_source_key(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "unknown"
      trimmed -> trimmed
    end
  end

  defp normalized_source_key(_value), do: "unknown"

  defp map_value(%{} = map, key) when is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
