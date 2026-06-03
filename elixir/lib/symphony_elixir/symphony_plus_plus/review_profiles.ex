defmodule SymphonyElixir.SymphonyPlusPlus.ReviewProfiles do
  @moduledoc false

  @passing_statuses ["passed", "pass", "green", "success"]
  @passing_verdicts ["green", "clean", "passed", "pass", "success", "approved"]
  @profile_order ["brief", "normal", "deep"]

  @spec passing_statuses() :: [String.t()]
  def passing_statuses, do: @passing_statuses

  @spec passing_verdicts() :: [String.t()]
  def passing_verdicts, do: @passing_verdicts

  @spec passing_status?(term()) :: boolean()
  def passing_status?(status), do: normalize_status(status) in @passing_statuses

  @spec passing_verdict?(term()) :: boolean()
  def passing_verdict?(verdict), do: normalize_status(verdict) in @passing_verdicts

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

  @spec normalize_status(term()) :: String.t()
  def normalize_status(status) when is_binary(status), do: status |> String.trim() |> String.downcase()
  def normalize_status(_status), do: ""

  @spec profile_satisfies?(term(), term()) :: boolean()
  def profile_satisfies?(provided, required) do
    provided = normalize_profile(provided)
    required = normalize_profile(required)

    cond do
      is_nil(provided) or is_nil(required) ->
        false

      provided == required ->
        true

      provided in @profile_order and required in @profile_order ->
        profile_rank(provided) >= profile_rank(required)

      true ->
        false
    end
  end

  @spec profile_verdicts_pass?(term(), map()) :: boolean()
  def profile_verdicts_pass?(required_profile, verdicts) when is_map(verdicts) do
    case normalize_profile(required_profile) do
      nil ->
        false

      profile ->
        verdicts
        |> Enum.filter(fn {provided_profile, _verdict} -> profile_satisfies?(provided_profile, profile) end)
        |> case do
          [] -> false
          satisfying_verdicts -> Enum.all?(satisfying_verdicts, fn {_provided_profile, verdict} -> passing_verdict?(verdict) end)
        end
    end
  end

  def profile_verdicts_pass?(_required_profile, _verdicts), do: false

  @spec review_suite_payload_profile_satisfies?(term(), term()) :: boolean()
  def review_suite_payload_profile_satisfies?(%{} = payload, required_profile) do
    payload
    |> review_suite_payload_profiles()
    |> Enum.any?(&profile_satisfies?(&1, required_profile))
  end

  def review_suite_payload_profile_satisfies?(_payload, _required_profile), do: false

  @spec review_suite_payload_exact_profile?(term(), term()) :: boolean()
  def review_suite_payload_exact_profile?(%{} = payload, required_profile) do
    required_profile = normalize_profile(required_profile)

    not is_nil(required_profile) and required_profile in review_suite_payload_profiles(payload)
  end

  def review_suite_payload_exact_profile?(_payload, _required_profile), do: false

  @spec review_suite_payload_passes?(term()) :: boolean()
  def review_suite_payload_passes?(%{} = payload) do
    passing_status?(Map.get(payload, "status")) and passing_verdict?(Map.get(payload, "verdict"))
  end

  def review_suite_payload_passes?(_payload), do: false

  @spec review_suite_payloads_satisfy_required_profile?([map()], term()) :: boolean()
  def review_suite_payloads_satisfy_required_profile?(payloads, required_profile) when is_list(payloads) do
    case normalize_profile(required_profile) do
      nil ->
        false

      profile ->
        case latest_review_suite_payload_for_satisfying_profile(payloads, profile) do
          nil ->
            false

          payload ->
            review_suite_payload_passes?(payload)
        end
    end
  end

  def review_suite_payloads_satisfy_required_profile?(_payloads, _required_profile), do: false

  @spec satisfying_profiles(term()) :: [String.t()]
  def satisfying_profiles(required) do
    case normalize_profile(required) do
      nil -> []
      "brief" -> ["brief", "normal", "deep"]
      "normal" -> ["normal", "deep"]
      "deep" -> ["deep"]
      profile -> [profile]
    end
  end

  @spec accepted_lane_aliases([String.t()]) :: map()
  def accepted_lane_aliases(required_profiles) when is_list(required_profiles) do
    Map.new(required_profiles, fn profile ->
      normalized = normalize_profile(profile)
      {normalized || to_string(profile), satisfying_profiles(profile)}
    end)
  end

  def accepted_lane_aliases(_required_profiles), do: %{}

  @spec green_statuses(String.t()) :: [String.t()]
  def green_statuses(profile), do: ["review_#{profile}_green" | legacy_green_statuses(profile)]

  @spec statuses(String.t()) :: [String.t()]
  def statuses(profile) do
    green_statuses(profile) ++
      ["review_#{profile}_red", "review_#{profile}_failed"] ++
      Enum.flat_map(legacy_status_prefixes(profile), &[&1 <> "_red", &1 <> "_failed"])
  end

  defp profile_rank(profile), do: Enum.find_index(@profile_order, &(&1 == profile)) || -1

  defp review_suite_payload_profiles(payload) do
    [Map.get(payload, "profile"), Map.get(payload, "lane")]
    |> Enum.map(&normalize_profile/1)
    |> Enum.reject(&is_nil/1)
  end

  defp latest_review_suite_payload_for_satisfying_profile(payloads, profile) do
    payloads
    |> Enum.filter(&review_suite_payload_profile_satisfies?(&1, profile))
    |> List.last()
  end

  defp legacy_green_statuses(profile), do: Enum.map(legacy_status_prefixes(profile), &"#{&1}_green")

  defp legacy_status_prefixes("brief"), do: ["review_t1"]
  defp legacy_status_prefixes("normal"), do: ["review_t2"]
  defp legacy_status_prefixes(_profile), do: []
end
