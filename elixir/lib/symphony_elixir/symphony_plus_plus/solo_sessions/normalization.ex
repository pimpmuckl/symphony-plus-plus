defmodule SymphonyElixir.SymphonyPlusPlus.SoloSessions.Normalization do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry

  @validation_results ["passed", "failed", "skipped", "blocked", "not_run"]
  @lifecycle_actions ["pause", "resume", "complete", "archive"]

  @entry_status_aliases %{
    "recorded" => "recorded",
    "note" => "recorded",
    "pending" => "pending",
    "todo" => "pending",
    "active" => "in_progress",
    "started" => "in_progress",
    "running" => "in_progress",
    "working" => "in_progress",
    "in_progress" => "in_progress",
    "in-progress" => "in_progress",
    "in progress" => "in_progress",
    "completed" => "completed",
    "complete" => "completed",
    "done" => "completed",
    "finished" => "completed",
    "open" => "open",
    "blocked" => "blocked",
    "blocker" => "blocked",
    "resolved" => "resolved",
    "closed" => "resolved"
  }

  @validation_result_aliases %{
    "passed" => "passed",
    "pass" => "passed",
    "green" => "passed",
    "ok" => "passed",
    "failed" => "failed",
    "fail" => "failed",
    "red" => "failed",
    "skipped" => "skipped",
    "skip" => "skipped",
    "blocked" => "blocked",
    "block" => "blocked",
    "not_run" => "not_run",
    "not-run" => "not_run",
    "not run" => "not_run",
    "notrun" => "not_run",
    "not_ran" => "not_run"
  }

  @lifecycle_action_aliases %{
    "pause" => "pause",
    "paused" => "pause",
    "resume" => "resume",
    "active" => "resume",
    "complete" => "complete",
    "completed" => "complete",
    "done" => "complete",
    "archive" => "archive",
    "archived" => "archive"
  }

  @spec entry_kinds() :: [String.t()]
  def entry_kinds, do: SoloSessionEntry.entry_kinds()

  @spec entry_statuses() :: [String.t()]
  def entry_statuses, do: SoloSessionEntry.statuses()

  @spec lifecycle_actions() :: [String.t()]
  def lifecycle_actions, do: @lifecycle_actions

  @spec session_statuses() :: [String.t()]
  def session_statuses, do: SoloSession.statuses()

  @spec validation_results() :: [String.t()]
  def validation_results, do: @validation_results

  @spec normalize_friendly_entry_status(term()) :: {:ok, String.t()} | {:error, {:invalid_solo_entry_status, term()}}
  def normalize_friendly_entry_status(value), do: normalize_friendly_entry_status(value, "recorded")

  @spec normalize_friendly_entry_status(term(), String.t()) ::
          {:ok, String.t()} | {:error, {:invalid_solo_entry_status, term()}}
  def normalize_friendly_entry_status(value, default) when value in [nil, ""], do: {:ok, default}

  def normalize_friendly_entry_status(value, default) when is_binary(value) do
    case normalize_label(value) do
      "" -> {:ok, default}
      label -> normalize_entry_status_alias(label, value)
    end
  end

  def normalize_friendly_entry_status(value, _default), do: {:error, {:invalid_solo_entry_status, value}}

  defp normalize_entry_status_alias(label, value) do
    @entry_status_aliases
    |> Map.fetch(label)
    |> normalize_fetch_error(:invalid_solo_entry_status, value)
  end

  @spec normalize_lifecycle_action(term()) :: {:ok, String.t()} | {:error, {:invalid_solo_lifecycle_action, term()}}
  def normalize_lifecycle_action(value) when is_binary(value) do
    value
    |> normalize_label()
    |> then(&Map.fetch(@lifecycle_action_aliases, &1))
    |> normalize_fetch_error(:invalid_solo_lifecycle_action, value)
  end

  def normalize_lifecycle_action(value), do: {:error, {:invalid_solo_lifecycle_action, value}}

  @spec normalize_validation_result(term()) :: {:ok, String.t()} | {:error, {:invalid_solo_validation_result, term()}}
  def normalize_validation_result(value) when is_binary(value) do
    value
    |> normalize_label()
    |> then(&Map.fetch(@validation_result_aliases, &1))
    |> normalize_fetch_error(:invalid_solo_validation_result, value)
  end

  def normalize_validation_result(value), do: {:error, {:invalid_solo_validation_result, value}}

  @spec lifecycle_status_for_action(String.t()) :: String.t()
  def lifecycle_status_for_action("pause"), do: "paused"
  def lifecycle_status_for_action("resume"), do: "active"
  def lifecycle_status_for_action("complete"), do: "completed"
  def lifecycle_status_for_action("archive"), do: "archived"

  @spec validation_entry_status(String.t()) :: String.t()
  def validation_entry_status("passed"), do: "completed"
  def validation_entry_status(result) when result in ["failed", "blocked"], do: "blocked"
  def validation_entry_status(_result), do: "recorded"

  @spec error_data({atom(), term()}, String.t()) :: map()
  def error_data({:invalid_solo_entry_status, value}, tool) do
    %{
      "tool" => tool,
      "reason" => "invalid_solo_entry_status",
      "received" => printable(value),
      "allowed_values" => entry_statuses(),
      "recommended" => "Use an intent-shaped solo_* tool, or omit status for a recorded entry."
    }
  end

  def error_data({:invalid_solo_lifecycle_action, value}, tool) do
    %{
      "tool" => tool,
      "reason" => "invalid_solo_lifecycle_action",
      "received" => printable(value),
      "allowed_values" => lifecycle_actions()
    }
  end

  def error_data({:invalid_solo_validation_result, value}, tool) do
    %{
      "tool" => tool,
      "reason" => "invalid_solo_validation_result",
      "received" => printable(value),
      "allowed_values" => validation_results()
    }
  end

  def error_data({:missing_required_solo_field, field}, tool) do
    %{"tool" => tool, "reason" => "missing_#{field}", "field" => to_string(field)}
  end

  def error_data({:invalid_solo_payload, field}, tool) do
    %{"tool" => tool, "reason" => "invalid_#{field}", "field" => to_string(field)}
  end

  def error_data({:unsupported_solo_field, field}, tool) do
    %{"tool" => tool, "reason" => "unsupported_#{field}", "field" => to_string(field)}
  end

  def error_data(reason, tool), do: %{"tool" => tool, "reason" => inspect(reason)}

  @spec error_message(term()) :: String.t()
  def error_message({:invalid_solo_entry_status, value}) do
    "Solo Session entry status #{inspect(value)} is invalid. Allowed values: #{Enum.join(entry_statuses(), ", ")}."
  end

  def error_message({:invalid_solo_lifecycle_action, value}) do
    "Solo Session lifecycle action #{inspect(value)} is invalid. Allowed actions: #{Enum.join(lifecycle_actions(), ", ")}."
  end

  def error_message({:invalid_solo_validation_result, value}) do
    "Solo Session validation result #{inspect(value)} is invalid. Allowed results: #{Enum.join(validation_results(), ", ")}."
  end

  def error_message({:missing_required_solo_field, field}), do: "Solo Session command requires --#{dash(field)}."
  def error_message({:invalid_solo_payload, field}), do: "Solo Session --#{dash(field)} must be a JSON object."
  def error_message({:unsupported_solo_field, field}), do: "Solo Session command does not support --#{dash(field)}."

  defp normalize_fetch_error({:ok, value}, _reason, _original), do: {:ok, value}
  defp normalize_fetch_error(:error, reason, original), do: {:error, {reason, original}}

  defp normalize_label(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  defp printable(value) when is_binary(value), do: value
  defp printable(value), do: inspect(value)

  defp dash(field), do: field |> to_string() |> String.replace("_", "-")
end
