defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor

  @minimum_sha_prefix_length 7

  @type ref :: %{
          owner: String.t(),
          repo: String.t(),
          repository: String.t(),
          number: pos_integer(),
          url: String.t()
        }

  @spec parse(map(), String.t() | nil) :: {:ok, ref()} | {:error, atom()}
  def parse(arguments, package_repo) when is_map(arguments) do
    cond do
      filled_string?(Map.get(arguments, "url")) ->
        with {:ok, ref} <- parse_url(Map.get(arguments, "url")),
             :ok <- validate_number_ref(arguments, ref),
             :ok <- validate_repository_ref(arguments, ref) do
          {:ok, ref}
        end

      Map.has_key?(arguments, "number") ->
        parse_number(Map.get(arguments, "number"), repository_input(arguments, package_repo))

      true ->
        {:error, :missing_pr_reference}
    end
  end

  @spec parse_url(String.t()) :: {:ok, ref()} | {:error, atom()}
  def parse_url(url) when is_binary(url) do
    trimmed = String.trim(url)
    uri = URI.parse(trimmed)
    host = uri.host |> to_string() |> String.downcase()
    path_segments = uri.path |> to_string() |> String.split("/", trim: true)

    case {uri.scheme, host, path_segments} do
      {scheme, "github.com", [owner, repo, "pull", number | _rest]} when scheme in ["http", "https"] ->
        with {:ok, number} <- parse_positive_number(number),
             :ok <- validate_repo_part(owner),
             :ok <- validate_repo_part(repo) do
          {:ok, ref(owner, repo, number, "https://github.com/#{owner}/#{repo}/pull/#{number}")}
        end

      _value ->
        {:error, :invalid_pr_url}
    end
  rescue
    _error in URI.Error -> {:error, :invalid_pr_url}
  end

  @spec parse_number(term(), String.t() | nil) :: {:ok, ref()} | {:error, atom()}
  def parse_number(number, repository) do
    with {:ok, number} <- parse_positive_number(number),
         {:ok, {owner, repo}} <- parse_repository(repository) do
      {:ok, ref(owner, repo, number, "https://github.com/#{owner}/#{repo}/pull/#{number}")}
    end
  end

  @spec metadata(map(), ref(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def metadata(metadata, ref, fallback_head_sha) when is_map(metadata) and is_map(ref) do
    with :ok <- validate_metadata_ref(metadata, ref),
         {:ok, head_sha} <- metadata_head_sha(metadata, fallback_head_sha),
         {:ok, branch} <- metadata_branch(metadata),
         {:ok, base_branch} <- metadata_base_branch(metadata),
         {:ok, changed_file_metadata} <- metadata_changed_files(metadata),
         {:ok, check_summary} <- metadata_map(metadata, "check_summary", %{}),
         {:ok, review_state} <- metadata_map(metadata, "review_state", github_review_state(metadata)),
         {:ok, merge_state} <- metadata_map(metadata, "merge_state", github_merge_state(metadata)) do
      {:ok,
       %{
         "type" => "pr",
         "source_tool" => "attach_pr",
         "url" => ref.url,
         "repository" => ref.repository,
         "owner" => ref.owner,
         "repo" => ref.repo,
         "number" => ref.number,
         "branch" => branch,
         "base_branch" => base_branch,
         "head_sha" => head_sha,
         "changed_files" => changed_file_metadata.files,
         "changed_files_count" => changed_file_metadata.count,
         "changed_files_available" => changed_file_metadata.files_available,
         "changed_files_count_available" => changed_file_metadata.count_available,
         "check_summary" => Redactor.redact(check_summary),
         "review_state" => Redactor.redact(review_state),
         "merge_state" => Redactor.redact(merge_state)
       }}
    end
  end

  def metadata(_metadata, _ref, _fallback_head_sha), do: {:error, :missing_pr_metadata}

  @spec stale?(map() | nil, String.t() | nil) :: boolean()
  def stale?(%{} = pr_metadata, current_head_sha) when is_binary(current_head_sha) do
    not head_sha_matches?(Map.get(pr_metadata, "head_sha"), current_head_sha)
  end

  def stale?(_pr_metadata, _current_head_sha), do: false

  @spec head_sha_matches?(term(), term()) :: boolean()
  def head_sha_matches?(left, right) when is_binary(left) and is_binary(right) do
    left = String.trim(left)
    right = String.trim(right)

    left != "" and right != "" and (left == right or sha_prefix_match?(left, right))
  end

  def head_sha_matches?(_left, _right), do: false

  defp ref(owner, repo, number, url) do
    %{owner: owner, repo: repo, repository: "#{owner}/#{repo}", number: number, url: url}
  end

  defp parse_repository(repository) when is_binary(repository) do
    case repository |> String.trim() |> String.split("/", parts: 2) do
      [owner, repo] ->
        with :ok <- validate_repo_part(owner),
             :ok <- validate_repo_part(repo) do
          {:ok, {owner, repo}}
        end

      _parts ->
        {:error, :missing_repository}
    end
  end

  defp parse_repository(_repository), do: {:error, :missing_repository}

  defp repository_input(arguments, package_repo) do
    Map.get(arguments, "repository") || full_repository(package_repo) || metadata_repository(Map.get(arguments, "metadata")) || package_repo
  end

  defp full_repository(repository) do
    case parse_repository(repository) do
      {:ok, {_owner, _repo}} -> repository
      {:error, _reason} -> nil
    end
  end

  defp metadata_repository(%{} = metadata) do
    repository_full_name(Map.get(metadata, "repository")) ||
      get_in(metadata, ["base", "repo", "full_name"]) ||
      get_in(metadata, ["head", "repo", "full_name"]) ||
      repository_from_url(Map.get(metadata, "html_url") || Map.get(metadata, "url"))
  end

  defp metadata_repository(_metadata), do: nil

  defp repository_full_name(value) when is_binary(value), do: value
  defp repository_full_name(%{"full_name" => full_name}) when is_binary(full_name), do: full_name
  defp repository_full_name(_value), do: nil

  defp repository_from_url(url) when is_binary(url) do
    case parse_url(url) do
      {:ok, ref} -> ref.repository
      {:error, _reason} -> nil
    end
  end

  defp repository_from_url(_url), do: nil

  defp validate_number_ref(%{"number" => number}, ref) do
    case parse_positive_number(number) do
      {:ok, number} when number == ref.number -> :ok
      {:ok, _number} -> {:error, :pr_reference_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_number_ref(_arguments, _ref), do: :ok

  defp validate_repository_ref(%{"repository" => repository}, ref) do
    case parse_repository(repository) do
      {:ok, {owner, repo}} -> validate_repository_parts(owner, repo, ref)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_repository_ref(_arguments, _ref), do: :ok

  defp validate_metadata_ref(metadata, ref) do
    case validate_metadata_repository_ref(metadata, ref) do
      :ok -> validate_metadata_number_ref(metadata, ref)
      error -> error
    end
  end

  defp validate_metadata_repository_ref(metadata, ref) do
    case metadata_repository(metadata) do
      nil ->
        :ok

      repository ->
        case parse_repository(repository) do
          {:ok, {owner, repo}} -> validate_repository_parts(owner, repo, ref)
          {:error, _reason} -> :ok
        end
    end
  end

  defp validate_repository_parts(owner, repo, ref) do
    if same_repository_part?(owner, ref.owner) and same_repository_part?(repo, ref.repo) do
      :ok
    else
      {:error, :pr_reference_mismatch}
    end
  end

  defp same_repository_part?(left, right), do: String.downcase(left) == String.downcase(right)

  defp validate_metadata_number_ref(metadata, ref) do
    case metadata_number(metadata) do
      nil ->
        :ok

      number ->
        case parse_positive_number(number) do
          {:ok, parsed} when parsed == ref.number -> :ok
          {:ok, _parsed} -> {:error, :pr_reference_mismatch}
          {:error, _reason} -> :ok
        end
    end
  end

  defp metadata_number(metadata) do
    Map.get(metadata, "number") || metadata_url_number(Map.get(metadata, "html_url") || Map.get(metadata, "url"))
  end

  defp metadata_url_number(url) when is_binary(url) do
    case parse_url(url) do
      {:ok, ref} -> ref.number
      {:error, _reason} -> nil
    end
  end

  defp metadata_url_number(_url), do: nil

  defp parse_positive_number(number) when is_integer(number) and number > 0, do: {:ok, number}

  defp parse_positive_number(number) when is_binary(number) do
    case Integer.parse(String.trim(number)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _value -> {:error, :invalid_pr_number}
    end
  end

  defp parse_positive_number(_number), do: {:error, :invalid_pr_number}

  defp validate_repo_part(value) when is_binary(value) do
    if String.match?(value, ~r/^[A-Za-z0-9_.-]+$/), do: :ok, else: {:error, :invalid_repository}
  end

  defp validate_repo_part(_value), do: {:error, :invalid_repository}

  defp metadata_head_sha(metadata, fallback_head_sha) do
    explicit_head_sha = clean_head_sha(fallback_head_sha)
    metadata_head_sha = clean_head_sha(Map.get(metadata, "head_sha") || get_in(metadata, ["head", "sha"]))

    case {explicit_head_sha, metadata_head_sha} do
      {nil, nil} ->
        {:error, :missing_head_sha}

      {explicit, nil} ->
        {:ok, explicit}

      {nil, metadata} ->
        {:ok, metadata}

      {explicit, metadata} ->
        if head_sha_matches?(explicit, metadata), do: {:ok, explicit}, else: {:error, :head_sha_mismatch}
    end
  end

  defp clean_head_sha(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_head_sha(_value), do: nil

  defp metadata_branch(metadata) do
    case Map.get(metadata, "branch") || get_in(metadata, ["head", "ref"]) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_branch}, else: {:ok, value}

      _value ->
        {:ok, nil}
    end
  end

  defp metadata_base_branch(metadata) do
    case Map.get(metadata, "base_branch") || get_in(metadata, ["base", "ref"]) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:ok, nil}, else: {:ok, value}

      _value ->
        {:ok, nil}
    end
  end

  defp metadata_changed_files(metadata) do
    with {:ok, reported_count} <- metadata_changed_files_count(metadata) do
      case Map.get(metadata, "changed_files", :missing) do
        values when is_list(values) ->
          changed_files = Enum.map(values, &changed_file/1)
          changed_file_count_metadata(changed_files, reported_count)

        count when is_integer(count) and count >= 0 ->
          {:ok, changed_file_metadata([], count, false, true)}

        :missing ->
          missing_changed_file_count_metadata(reported_count)

        _value ->
          {:error, :invalid_changed_files}
      end
    end
  end

  defp metadata_changed_files_count(metadata) do
    case Map.get(metadata, "changed_files_count") do
      nil -> {:ok, nil}
      count when is_integer(count) and count >= 0 -> {:ok, count}
      _value -> {:error, :invalid_changed_files_count}
    end
  end

  defp changed_file_count_metadata([], nil), do: {:ok, changed_file_metadata([], 0, false, false)}

  defp changed_file_count_metadata(changed_files, nil) do
    count = length(changed_files)
    {:ok, changed_file_metadata(changed_files, count, true, true)}
  end

  defp changed_file_count_metadata(changed_files, reported_count) do
    count = max(reported_count, length(changed_files))
    {:ok, changed_file_metadata(changed_files, count, reported_count <= length(changed_files), true)}
  end

  defp missing_changed_file_count_metadata(nil), do: {:ok, changed_file_metadata([], 0, false, false)}
  defp missing_changed_file_count_metadata(reported_count), do: {:ok, changed_file_metadata([], reported_count, false, true)}

  defp changed_file_metadata(files, count, files_available, count_available) do
    %{
      files: files,
      count: count,
      files_available: files_available,
      count_available: count_available
    }
  end

  defp changed_file(path) when is_binary(path), do: %{"path" => String.trim(path)}

  defp changed_file(%{} = value) do
    value
    |> Map.take(["path", "filename", "previous_path", "previous_filename", "status", "additions", "deletions", "changes"])
    |> normalize_file_path()
    |> normalize_previous_file_path()
  end

  defp changed_file(_value), do: %{}

  defp normalize_file_path(%{"path" => path} = value) when is_binary(path), do: Map.put(value, "path", String.trim(path))
  defp normalize_file_path(%{"filename" => path} = value) when is_binary(path), do: value |> Map.put("path", String.trim(path)) |> Map.delete("filename")
  defp normalize_file_path(value), do: value

  defp normalize_previous_file_path(%{"previous_path" => path} = value) when is_binary(path), do: Map.put(value, "previous_path", String.trim(path))

  defp normalize_previous_file_path(%{"previous_filename" => path} = value) when is_binary(path) do
    value
    |> Map.put("previous_path", String.trim(path))
    |> Map.delete("previous_filename")
  end

  defp normalize_previous_file_path(value), do: value

  defp metadata_map(metadata, key, fallback) do
    case Map.get(metadata, key, fallback) do
      value when is_map(value) -> {:ok, value}
      nil -> {:ok, %{}}
      _value -> {:error, :"invalid_#{key}"}
    end
  end

  defp github_review_state(metadata) do
    metadata
    |> Map.take(["draft"])
    |> reject_nil_values()
  end

  defp github_merge_state(metadata) do
    metadata
    |> Map.take(["state", "mergeable", "mergeable_state", "merged"])
    |> reject_nil_values()
  end

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp sha_prefix_match?(left, right) do
    sha_abbreviation?(left) and sha_abbreviation?(right) and
      (String.starts_with?(left, right) or String.starts_with?(right, left))
  end

  defp sha_abbreviation?(value) do
    String.length(value) >= @minimum_sha_prefix_length and String.match?(value, ~r/\A[0-9a-fA-F]+\z/)
  end
end
