defmodule SymphonyElixir.SymphonyPlusPlus.ReviewSuiteRounds do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.ReviewProfiles

  @green_stages ["review-green", "local-green-handoff"]
  @fallback_explicit_fields ["work_package_id", "head_sha", "status", "verdict", "suite", "anchor", "summary", "profile", "lane"]
  @cycle_key_pattern ~r/\Aorc-[A-Za-z0-9][A-Za-z0-9_-]*\z/

  @spec resolve(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve(round_id, opts \\ []) do
    with {:ok, round_id} <- required_text(round_id, :round_id),
         {:ok, state_dir} <- review_suite_state_dir(Keyword.get(opts, :state_dir)),
         {:ok, cycle, source} <- load_cycle_for_round_id(state_dir, round_id),
         {:ok, decision, round} <- clean_decision_for_round(cycle, round_id, source),
         {:ok, head_sha} <- reviewed_head(cycle, decision, round, round_id),
         {:ok, profile} <- review_profile(cycle, round_id),
         :ok <- validate_profile_hint(profile, opts, round_id) do
      {:ok,
       %{
         "head_sha" => head_sha,
         "suite" => "review-suite",
         "anchor" => Map.fetch!(decision, "round_id"),
         "summary" => "Review Suite #{profile} clean for #{short_head(head_sha)}",
         "status" => "passed",
         "verdict" => "clean",
         "lane" => profile,
         "profile" => profile,
         "reviewer" => "review-suite",
         "round_id" => Map.fetch!(decision, "round_id")
       }
       |> put_if_present("review_suite_id", public_id(cycle))
       |> put_if_present("work_package_id", text(get_in(cycle, ["identity", "work_package_id"])))
       |> put_if_present("repo", text(get_in(cycle, ["identity", "repo"])))
       |> put_if_present("base_branch", text(get_in(cycle, ["identity", "base"])))
       |> put_if_present("branch", text(get_in(cycle, ["identity", "branch"])))}
    end
  end

  defp review_suite_state_dir(nil) do
    case Application.get_env(:symphony_elixir, :sympp_review_suite_state_dir) do
      value when is_binary(value) and value != "" -> review_suite_state_dir(value)
      _value -> default_review_suite_state_dir()
    end
  end

  defp review_suite_state_dir(path) when is_binary(path) do
    path = Path.expand(path)

    if File.dir?(path) do
      {:ok, path}
    else
      unavailable("local_state", ["review-suite state directory #{path}"])
    end
  end

  defp review_suite_state_dir(_path), do: default_review_suite_state_dir()

  defp default_review_suite_state_dir do
    case System.user_home() do
      home when is_binary(home) and home != "" -> review_suite_state_dir(Path.join([home, ".codex", "state", "review-suite"]))
      _home -> unavailable("local_state", ["user home"])
    end
  end

  defp load_cycle_for_round_id(state_dir, "rvw_" <> _rest = public_id) do
    with {:ok, cycle_key} <- cycle_key_for_public_id(state_dir, public_id) do
      load_cycle(state_dir, cycle_key, :cycle)
    end
  end

  defp load_cycle_for_round_id(state_dir, "orc-" <> _rest = cycle_key), do: load_cycle(state_dir, cycle_key, :cycle)

  defp load_cycle_for_round_id(state_dir, round_id), do: load_cycle_for_actual_round_id(state_dir, round_id)

  defp load_cycle_for_actual_round_id(state_dir, round_id) do
    case matching_cycles_for_round_id(state_dir, round_id) do
      {:ok, matches} -> cycle_for_round_matches(matches, round_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp cycle_for_round_matches([{cycle, _cycle_key}], _round_id), do: {:ok, cycle, :round}

  defp cycle_for_round_matches([], round_id) do
    unavailable(round_id, ["Review Suite round #{round_id}"])
  end

  defp cycle_for_round_matches(matches, round_id) do
    cycle_keys = matches |> Enum.map(fn {_cycle, cycle_key} -> cycle_key end) |> Enum.sort()
    {:error, {:review_suite_round_ambiguous, round_id, cycle_keys, @fallback_explicit_fields}}
  end

  defp matching_cycles_for_round_id(state_dir, round_id) do
    with {:ok, paths} <- cycle_paths(state_dir) do
      {:ok, Enum.flat_map(paths, &cycle_match_for_round_id(&1, round_id))}
    end
  end

  defp cycle_match_for_round_id(path, round_id) do
    with {:ok, %{} = cycle} <- read_json_file(path),
         true <- cycle_has_round_id?(cycle, round_id) do
      [{cycle, Path.basename(path, ".json")}]
    else
      _no_match_or_unreadable_cycle -> []
    end
  end

  defp cycle_paths(state_dir) do
    cycles_dir = Path.expand(Path.join([state_dir, "orchestrator", "cycles"]))

    if File.dir?(cycles_dir) do
      paths =
        cycles_dir
        |> Path.join("orc-*.json")
        |> Path.wildcard()
        |> Enum.filter(&path_inside?(&1, cycles_dir))

      {:ok, paths}
    else
      unavailable("local_state", ["review-suite cycles directory #{cycles_dir}"])
    end
  end

  defp cycle_has_round_id?(cycle, round_id) do
    Enum.any?(list(cycle["rounds"]), fn
      %{} = round -> text(round["round_id"]) == round_id
      _round -> false
    end) or
      Enum.any?(list(cycle["decisions"]), fn
        %{} = decision -> text(decision["round_id"]) == round_id
        _decision -> false
      end)
  end

  defp cycle_key_for_public_id(state_dir, public_id) do
    index_path = Path.join([state_dir, "orchestrator", "index.json"])

    with {:ok, index} <- read_json_file(index_path) do
      cycle_key =
        get_in(index, ["public_ids", public_id]) ||
          Map.get(index, public_id) ||
          index
          |> Map.get("cycle_keys", %{})
          |> Enum.find_value(fn
            {cycle_key, ^public_id} -> cycle_key
            _entry -> nil
          end)

      case cycle_key do
        value when is_binary(value) and value != "" -> {:ok, value}
        _value -> unavailable(public_id, ["orchestrator/index.json public id #{public_id}"])
      end
    end
  end

  defp load_cycle(state_dir, cycle_key, source) do
    with :ok <- validate_cycle_key(cycle_key),
         {:ok, path} <- cycle_path(state_dir, cycle_key) do
      case read_json_file(path) do
        {:ok, %{} = cycle} -> {:ok, cycle, source}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_cycle_key(cycle_key) when is_binary(cycle_key) do
    if Regex.match?(@cycle_key_pattern, cycle_key) do
      :ok
    else
      unavailable(cycle_key, ["safe Review Suite cycle id orc-*"])
    end
  end

  defp cycle_path(state_dir, cycle_key) do
    cycles_dir = Path.expand(Path.join([state_dir, "orchestrator", "cycles"]))
    path = Path.expand(Path.join(cycles_dir, "#{cycle_key}.json"))

    if path_inside?(path, cycles_dir) do
      {:ok, path}
    else
      unavailable(cycle_key, ["safe Review Suite cycle id orc-*"])
    end
  end

  defp path_inside?(path, directory) do
    directory =
      directory
      |> Path.expand()
      |> String.trim_trailing("/")
      |> String.trim_trailing("\\")

    path = Path.expand(path)

    String.starts_with?(path, directory <> "/") or String.starts_with?(path, directory <> "\\")
  end

  defp clean_decision_for_round(cycle, requested_id, source) do
    with :ok <- require_green_cycle(cycle, requested_id),
         {:ok, decision} <- clean_decision(cycle, requested_id, source),
         {:ok, round} <- round_record(cycle, Map.fetch!(decision, "round_id")),
         :ok <- require_completed_round(round, requested_id) do
      {:ok, decision, round}
    end
  end

  defp require_green_cycle(cycle, requested_id) do
    stage = text(cycle["stage"])
    review_green = text(get_in(cycle, ["validation", "review_green"]))

    if stage in @green_stages or ReviewProfiles.passing_status?(review_green) do
      :ok
    else
      {:error, {:review_suite_round_not_green, requested_id, stage || "unknown", @fallback_explicit_fields}}
    end
  end

  defp clean_decision(cycle, requested_id, :round) do
    decision =
      cycle
      |> clean_decisions()
      |> Enum.find(&(Map.fetch!(&1, "round_id") == requested_id))

    case decision do
      %{} = decision -> {:ok, decision}
      nil -> {:error, {:review_suite_round_not_passing, requested_id, @fallback_explicit_fields}}
    end
  end

  defp clean_decision(cycle, requested_id, :cycle) do
    last_head = text(get_in(cycle, ["review_heads", "last_reviewed_head"]))

    decision =
      cycle
      |> clean_decisions()
      |> prefer_head(last_head)
      |> List.last()

    case decision do
      %{} = decision -> {:ok, decision}
      nil -> {:error, {:review_suite_round_not_passing, requested_id, @fallback_explicit_fields}}
    end
  end

  defp clean_decisions(cycle) do
    cycle
    |> Map.get("decisions", [])
    |> list()
    |> Enum.flat_map(fn
      %{} = decision ->
        round_id = text(decision["round_id"])

        if text(decision["command"]) == "clean" and is_binary(round_id) do
          [Map.put(decision, "round_id", round_id)]
        else
          []
        end

      _decision ->
        []
    end)
  end

  defp prefer_head(decisions, nil), do: decisions

  defp prefer_head(decisions, head) do
    case Enum.filter(decisions, &(text(&1["reviewed_head"]) == head)) do
      [] -> decisions
      matching -> matching
    end
  end

  defp round_record(cycle, round_id) do
    round =
      cycle
      |> Map.get("rounds", [])
      |> list()
      |> Enum.find(fn
        %{} = round -> text(round["round_id"]) == round_id
        _round -> false
      end)

    case round do
      %{} = round -> {:ok, round}
      nil -> {:error, {:review_suite_round_unavailable, round_id, ["cycle round record #{round_id}"], @fallback_explicit_fields}}
    end
  end

  defp require_completed_round(round, requested_id) do
    blocked? = round["review_blocked"] == true or Enum.any?(list(round["runs"]), &blocked_run?/1)
    status = text(round["review_status"])

    cond do
      blocked? ->
        {:error, {:review_suite_round_blocked, requested_id, @fallback_explicit_fields}}

      status in [nil, "completed"] ->
        :ok

      true ->
        {:error, {:review_suite_round_incomplete, requested_id, status, @fallback_explicit_fields}}
    end
  end

  defp blocked_run?(%{} = run), do: run["blocked"] == true or run["grade_blocked"] == true
  defp blocked_run?(_run), do: false

  defp reviewed_head(cycle, decision, round, requested_id) do
    head =
      [decision["reviewed_head"], round["reviewed_head"], get_in(cycle, ["review_heads", "last_reviewed_head"]), get_in(cycle, ["identity", "head"])]
      |> first_text()

    case head do
      head when is_binary(head) -> {:ok, head}
      nil -> {:error, {:review_suite_round_missing_head, requested_id, @fallback_explicit_fields}}
    end
  end

  defp review_profile(cycle, requested_id) do
    profile =
      [get_in(cycle, ["mode", "effective"]), get_in(cycle, ["mode", "requested"])]
      |> Enum.find_value(&ReviewProfiles.normalize_profile/1)

    case profile do
      profile when is_binary(profile) -> {:ok, profile}
      nil -> {:error, {:review_suite_round_missing_profile, requested_id, @fallback_explicit_fields}}
    end
  end

  defp validate_profile_hint(profile, opts, requested_id) do
    hints =
      [Keyword.get(opts, :profile), Keyword.get(opts, :lane)]
      |> Enum.map(&ReviewProfiles.normalize_profile/1)
      |> Enum.reject(&is_nil/1)

    case Enum.reject(hints, &ReviewProfiles.profile_satisfies?(profile, &1)) do
      [] ->
        :ok

      [mismatch | _rest] ->
        {:error, {:review_suite_round_profile_mismatch, requested_id, profile, mismatch, @fallback_explicit_fields}}
    end
  end

  defp public_id(cycle), do: text(cycle["public_id"])

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp read_json_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         %{} = payload <- decoded do
      {:ok, payload}
    else
      {:error, %Jason.DecodeError{}} -> unavailable(path, ["valid JSON at #{path}"])
      {:error, _reason} -> unavailable(path, [path])
      _value -> unavailable(path, ["JSON object at #{path}"])
    end
  end

  defp unavailable(round_id, missing), do: {:error, {:review_suite_round_unavailable, to_string(round_id), missing, @fallback_explicit_fields}}

  defp required_text(value, field) do
    case text(value) do
      value when is_binary(value) ->
        {:ok, value}

      nil ->
        field_text = Atom.to_string(field)
        {:error, {:review_suite_round_unavailable, field_text, [field_text], @fallback_explicit_fields}}
    end
  end

  defp first_text(values), do: Enum.find_value(values, &text/1)

  defp text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp text(_value), do: nil

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp short_head(head_sha) when byte_size(head_sha) >= 12, do: binary_part(head_sha, 0, 12)
  defp short_head(head_sha), do: head_sha
end
