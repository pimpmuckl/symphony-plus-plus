defmodule SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @gate "scope_guard"

  @spec gate() :: String.t()
  def gate, do: @gate

  @spec required?(WorkPackage.t()) :: boolean()
  def required?(%WorkPackage{} = work_package) do
    case LifecycleService.policy_for(work_package) do
      {:ok, policy} -> @gate in Map.get(policy, :required_gates, [])
      {:error, _reason} -> false
    end
  end

  @spec missing?(WorkPackage.t(), [ProgressEvent.t()]) :: boolean()
  def missing?(%WorkPackage{} = work_package, progress_events) when is_list(progress_events) do
    failure_reasons(work_package, progress_events) != []
  end

  @spec failure_reasons(WorkPackage.t(), [ProgressEvent.t()]) :: [map()]
  def failure_reasons(%WorkPackage{} = work_package, progress_events) when is_list(progress_events) do
    if required?(work_package) do
      progress_events = chronological_progress_events(progress_events)
      current_head_sha = latest_current_head_sha(progress_events)

      case current_pr_metadata(progress_events, current_head_sha) do
        {:ok, pr_payload} ->
          pr_payload
          |> evaluate_pr_payload(work_package)
          |> Enum.map(&redacted_reason/1)

        {:error, reason} ->
          [reason(reason)]
      end
    else
      []
    end
  end

  @spec approve_file_globs(WorkPackage.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def approve_file_globs(%WorkPackage{} = work_package, globs) when is_list(globs) do
    case normalize_globs(globs) do
      [] ->
        {:error, "missing_allowed_file_globs"}

      approved_globs ->
        if Enum.any?(approved_globs, &overbroad_glob?/1) do
          {:error, "overbroad_allowed_file_globs"}
        else
          current_globs = normalize_globs(work_package.allowed_file_globs || [])
          {:ok, Enum.uniq(current_globs ++ approved_globs)}
        end
    end
  end

  def approve_file_globs(%WorkPackage{}, _globs), do: {:error, "invalid_allowed_file_globs"}

  @spec glob_match?(String.t(), String.t()) :: boolean()
  def glob_match?(glob, path) when is_binary(glob) and is_binary(path) do
    normalized_glob = normalize_path(glob)
    normalized_path = normalize_path(path)

    case Regex.compile(glob_regex_source(normalized_glob)) do
      {:ok, regex} -> Regex.match?(regex, normalized_path)
      {:error, _reason} -> false
    end
  end

  def glob_match?(_glob, _path), do: false

  defp evaluate_pr_payload(pr_payload, %WorkPackage{} = work_package) do
    []
    |> add_base_branch_failure(pr_payload, work_package)
    |> add_allowed_file_failures(pr_payload, work_package)
  end

  defp add_base_branch_failure(reasons, pr_payload, %WorkPackage{base_branch: expected}) do
    actual = clean_string(Map.get(pr_payload, "base_branch"))
    expected = clean_string(expected)

    cond do
      is_nil(expected) ->
        reasons

      is_nil(actual) ->
        [reason("missing_base_branch", %{"expected_base_branch" => expected}) | reasons]

      actual != expected ->
        [reason("wrong_base_branch", %{"expected_base_branch" => expected, "actual_base_branch" => actual}) | reasons]

      true ->
        reasons
    end
  end

  defp add_allowed_file_failures(reasons, pr_payload, %WorkPackage{} = work_package) do
    allowed_file_globs = normalize_globs(work_package.allowed_file_globs || [])
    {changed_file_paths, changed_file_failures} = changed_file_paths(pr_payload)

    reasons =
      case {allowed_file_globs, changed_file_paths} do
        {[], _paths} ->
          [reason("scope_constraints_missing") | reasons]

        {_globs, []} ->
          reasons

        {globs, paths} ->
          out_of_scope_paths = Enum.reject(paths, &allowed_path?(&1, globs))

          if out_of_scope_paths == [] do
            reasons
          else
            [
              reason("out_of_scope_files", %{
                "files" => out_of_scope_paths,
                "allowed_file_globs" => globs
              })
              | reasons
            ]
          end
      end

    changed_file_failures ++ reasons
  end

  defp changed_file_paths(%{"changed_files_available" => false, "changed_files_count_available" => true, "changed_files_count" => 0}) do
    {[], []}
  end

  defp changed_file_paths(%{"changed_files_available" => false} = pr_payload) do
    count = Map.get(pr_payload, "changed_files_count", 0)
    detail = if is_integer(count) and count > 0, do: %{"changed_files_count" => count}, else: %{}
    {[], [reason("changed_files_unavailable", detail)]}
  end

  defp changed_file_paths(%{"changed_files" => changed_files} = pr_payload) when is_list(changed_files) do
    raw_paths = Enum.map(changed_files, &changed_file_path/1)
    paths = raw_paths |> Enum.reject(&is_nil/1) |> Enum.uniq()
    changed_files_count = Map.get(pr_payload, "changed_files_count", 0)

    failures =
      cond do
        changed_files == [] and is_integer(changed_files_count) and changed_files_count > 0 ->
          [reason("changed_files_unavailable", %{"changed_files_count" => changed_files_count})]

        Enum.any?(raw_paths, &is_nil/1) ->
          [reason("invalid_changed_file_paths")]

        true ->
          []
      end

    {paths, failures}
  end

  defp changed_file_paths(%{"changed_files_count" => count}) when is_integer(count) and count > 0 do
    {[], [reason("changed_files_unavailable", %{"changed_files_count" => count})]}
  end

  defp changed_file_paths(_pr_payload), do: {[], [reason("changed_files_unavailable")]}

  defp changed_file_path(%{"path" => path}), do: clean_file_path(path)
  defp changed_file_path(path), do: clean_file_path(path)

  defp clean_file_path(path) when is_binary(path) do
    path
    |> normalize_path()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp clean_file_path(_path), do: nil

  defp allowed_path?(path, allowed_file_globs) do
    Enum.any?(allowed_file_globs, &glob_match?(&1, path))
  end

  defp current_pr_metadata(_progress_events, nil), do: {:error, "missing_current_head"}

  defp current_pr_metadata(progress_events, current_head_sha) do
    with {:ok, attached_ref, attach_sequence} <- latest_attached_pr_ref_with_sequence(progress_events),
         %ProgressEvent{payload: payload} <-
           latest_current_pr_metadata_event(progress_events, current_head_sha, attached_ref, attach_sequence) do
      {:ok, payload}
    else
      {:error, :not_found} -> {:error, "missing_attached_pr"}
      nil -> {:error, "missing_current_pr_metadata"}
    end
  end

  defp latest_current_pr_metadata_event(progress_events, current_head_sha, attached_ref, attach_sequence) do
    progress_events
    |> Enum.reverse()
    |> Enum.find(fn
      %ProgressEvent{payload: payload} = event when is_map(payload) ->
        payload_type?(event, "pr", "sync_pr") and progress_after_pr_attach_boundary?(event, attach_sequence) and
          PullRequest.head_sha_matches?(Map.get(payload, "head_sha"), current_head_sha) and pr_payload_ref(payload) == attached_ref

      %ProgressEvent{} ->
        false
    end)
  end

  defp latest_current_head_sha(progress_events) do
    progress_events
    |> Enum.filter(&payload_type?(&1, "branch", "attach_branch"))
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{payload: payload} -> clean_string(Map.get(payload, "head_sha"))
      _event -> nil
    end)
  end

  defp latest_attached_pr_ref_with_sequence(progress_events) do
    progress_events
    |> Enum.reverse()
    |> Enum.find_value(&attached_pr_ref_with_sequence/1)
    |> case do
      nil -> {:error, :not_found}
      {ref, sequence} -> {:ok, ref, sequence}
    end
  end

  defp attached_pr_ref_with_sequence(%ProgressEvent{payload: payload, sequence: sequence}) when is_map(payload) do
    if payload_type?(%ProgressEvent{payload: payload}, "pr", "attach_pr") do
      case pr_payload_ref(payload) do
        nil -> nil
        ref -> {ref, sequence}
      end
    end
  end

  defp attached_pr_ref_with_sequence(%ProgressEvent{}), do: nil

  defp pr_payload_ref(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_integer(number) do
    {String.downcase(repository), number}
  end

  defp pr_payload_ref(%{"url" => url}) when is_binary(url) do
    case PullRequest.parse_url(url) do
      {:ok, ref} -> {String.downcase(ref.repository), ref.number}
      {:error, _reason} -> legacy_url_ref(url)
    end
  end

  defp pr_payload_ref(_payload), do: nil

  defp legacy_url_ref(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        if String.downcase(host) == "github.com", do: nil, else: {:url, url}

      _uri ->
        {:url, url}
    end
  rescue
    _error in URI.Error -> {:url, url}
  end

  defp progress_after_pr_attach_boundary?(%ProgressEvent{}, nil), do: true
  defp progress_after_pr_attach_boundary?(%ProgressEvent{sequence: sequence}, attach_sequence) when is_integer(sequence), do: sequence > attach_sequence
  defp progress_after_pr_attach_boundary?(%ProgressEvent{}, _attach_sequence), do: false

  defp payload_type?(%ProgressEvent{payload: payload}, type, source_tool) when is_map(payload) do
    Map.get(payload, "type") == type and Map.get(payload, "source_tool") == source_tool
  end

  defp payload_type?(%ProgressEvent{}, _type, _source_tool), do: false

  defp chronological_progress_events(progress_events) do
    Enum.sort_by(progress_events, fn %ProgressEvent{created_at: created_at, sequence: sequence, id: id} ->
      {created_at || DateTime.from_unix!(0), sequence || 0, id || ""}
    end)
  end

  defp normalize_globs(globs) when is_list(globs) do
    globs
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_path/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_globs(_globs), do: []

  defp overbroad_glob?(glob) do
    glob
    |> normalize_path()
    |> String.trim_leading("/")
    |> then(&(&1 in ["*", "**", "**/*"]))
  end

  defp normalize_path(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.replace(~r/\A\.\//, "")
  end

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp glob_regex_source(glob) do
    "^" <> glob_regex(glob) <> "$"
  end

  defp glob_regex(glob) do
    glob
    |> String.graphemes()
    |> glob_regex([])
    |> Enum.reverse()
    |> Enum.join()
  end

  defp glob_regex([], acc), do: acc

  defp glob_regex(["*", "*", "/" | rest], acc), do: glob_regex(rest, ["(?:.*/)?" | acc])
  defp glob_regex(["*", "*" | rest], acc), do: glob_regex(rest, [".*" | acc])
  defp glob_regex(["*" | rest], acc), do: glob_regex(rest, ["[^/]*" | acc])
  defp glob_regex(["?" | rest], acc), do: glob_regex(rest, ["[^/]" | acc])

  defp glob_regex(["[" | rest], acc) do
    case take_character_class(rest, []) do
      {:ok, character_class, rest} -> glob_regex(rest, [character_class | acc])
      :error -> glob_regex(rest, ["\\[" | acc])
    end
  end

  defp glob_regex([char | rest], acc), do: glob_regex(rest, [Regex.escape(char) | acc])

  defp take_character_class([], _acc), do: :error
  defp take_character_class(["]" | _rest], []), do: :error

  defp take_character_class(["]" | rest], acc) do
    {:ok, "[" <> (acc |> Enum.reverse() |> Enum.join()) <> "]", rest}
  end

  defp take_character_class(["!" | rest], []), do: take_character_class(rest, ["^"])
  defp take_character_class(["^" | rest], []), do: take_character_class(rest, ["\\^"])
  defp take_character_class(["\\" | rest], acc), do: take_character_class(rest, ["\\\\" | acc])
  defp take_character_class([char | rest], acc), do: take_character_class(rest, [char | acc])

  defp reason(code), do: reason(code, %{})

  defp reason(code, detail) do
    Map.merge(
      %{
        "gate" => @gate,
        "code" => code,
        "message" => message(code)
      },
      detail
    )
  end

  defp message("missing_current_head"), do: "Scope guard requires an attached branch head."
  defp message("missing_attached_pr"), do: "Scope guard requires an attached PR."
  defp message("missing_current_pr_metadata"), do: "Scope guard requires current synced PR metadata."
  defp message("missing_base_branch"), do: "Current PR metadata is missing the base branch."
  defp message("wrong_base_branch"), do: "Current PR targets the wrong base branch."
  defp message("scope_constraints_missing"), do: "Scope guard has no allowed file globs configured."
  defp message("changed_files_unavailable"), do: "Current PR metadata does not include changed-file paths."
  defp message("invalid_changed_file_paths"), do: "Current PR metadata includes invalid changed-file paths."
  defp message("out_of_scope_files"), do: "Current PR changes files outside the allowed globs."
  defp message(_code), do: "Scope guard failed."

  defp redacted_reason(reason) do
    reason
    |> Redactor.redact()
    |> Redactor.json_safe()
  end
end
