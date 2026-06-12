defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ClaimToolText do
  @moduledoc false

  @spec claim(map()) :: String.t()
  def claim(payload) when is_map(payload) do
    assignment = Map.get(payload, "assignment", %{})
    local_claim = Map.get(payload, "local_claim", %{})

    [
      {"status", "ok"},
      {"tool", Map.get(local_claim, "tool")},
      {"role", Map.get(assignment, "grant_role")},
      {"work_package_id", Map.get(assignment, "work_package_id") || Map.get(local_claim, "work_package_id")},
      {"work_request_id", Map.get(local_claim, "work_request_id")},
      {"lease", Map.get(local_claim, "claim_lease_action")},
      {"warning", claim_warning(local_claim)}
    ]
    |> compact_text_lines()
  end

  @spec release(map()) :: String.t()
  def release(payload) when is_map(payload) do
    release = Map.get(payload, "claim_lease_release", %{})
    recovery = Map.get(payload, "recovery", %{})

    [
      {"status", Map.get(payload, "status") || "ok"},
      {"tool", Map.get(payload, "action")},
      {"binding_cleared", Map.get(payload, "binding_cleared")},
      {"solo_tools_available", Map.get(payload, "solo_tools_available")},
      {"claim_lease_release", Map.get(release, "status")},
      {"recovery", Map.get(recovery, "next_action")}
    ]
    |> compact_text_lines()
  end

  defp claim_warning(%{"claim_lease_action" => "reclaimed"}), do: "stale_claim_reclaimed"
  defp claim_warning(_local_claim), do: nil

  defp compact_text_lines(lines) do
    lines
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{compact_text_value(value)}" end)
  end

  defp compact_text_value(value) when is_boolean(value), do: to_string(value)
  defp compact_text_value(value) when is_binary(value), do: value
  defp compact_text_value(value), do: inspect(value)
end
