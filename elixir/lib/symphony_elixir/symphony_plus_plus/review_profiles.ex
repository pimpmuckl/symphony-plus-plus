defmodule SymphonyElixir.SymphonyPlusPlus.ReviewProfiles do
  @moduledoc false

  @spec normalize_profiles(term()) :: [String.t()]
  def normalize_profiles(nil), do: []

  def normalize_profiles(profiles) when is_list(profiles) do
    profiles
    |> Enum.map(&normalize_profile/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def normalize_profiles(_profiles), do: []

  @spec normalize_profile(term()) :: String.t() | nil
  def normalize_profile(profile) when is_binary(profile) do
    case profile |> String.trim() |> String.downcase() |> String.replace("-", "_") do
      profile when profile in ["review_t1", "t1"] -> "brief"
      profile when profile in ["review_t2", "t2"] -> "normal"
      "review_brief" -> "brief"
      "review_normal" -> "normal"
      "review_deep" -> "deep"
      "review_emergency" -> "emergency"
      profile -> profile
    end
  end

  def normalize_profile(_profile), do: nil

  @spec green_statuses(String.t()) :: [String.t()]
  def green_statuses(profile), do: ["review_#{profile}_green" | legacy_green_statuses(profile)]

  @spec statuses(String.t()) :: [String.t()]
  def statuses(profile) do
    green_statuses(profile) ++
      ["review_#{profile}_red", "review_#{profile}_failed"] ++
      Enum.flat_map(legacy_status_prefixes(profile), &[&1 <> "_red", &1 <> "_failed"])
  end

  defp legacy_green_statuses(profile), do: Enum.map(legacy_status_prefixes(profile), &"#{&1}_green")

  defp legacy_status_prefixes("brief"), do: ["review_t1"]
  defp legacy_status_prefixes("normal"), do: ["review_t2"]
  defp legacy_status_prefixes(_profile), do: []
end
