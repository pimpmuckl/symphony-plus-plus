defmodule SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor

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
        parse_url(Map.get(arguments, "url"))

      Map.has_key?(arguments, "number") ->
        parse_number(Map.get(arguments, "number"), Map.get(arguments, "repository") || package_repo)

      true ->
        {:error, :missing_pr_reference}
    end
  end

  @spec parse_url(String.t()) :: {:ok, ref()} | {:error, atom()}
  def parse_url(url) when is_binary(url) do
    trimmed = String.trim(url)
    uri = URI.parse(trimmed)
    path_segments = uri.path |> to_string() |> String.split("/", trim: true)

    case {uri.scheme, uri.host, path_segments} do
      {scheme, "github.com", [owner, repo, "pull", number]} when scheme in ["http", "https"] ->
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
    with {:ok, head_sha} <- metadata_head_sha(metadata, fallback_head_sha),
         {:ok, branch} <- metadata_branch(metadata),
         {:ok, changed_files} <- metadata_changed_files(metadata),
         {:ok, check_summary} <- metadata_map(metadata, "check_summary"),
         {:ok, review_state} <- metadata_map(metadata, "review_state"),
         {:ok, merge_state} <- metadata_map(metadata, "merge_state") do
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
         "head_sha" => head_sha,
         "changed_files" => changed_files,
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
    case Map.get(metadata, "head_sha") || get_in(metadata, ["head", "sha"]) || fallback_head_sha do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_head_sha}, else: {:ok, value}

      _value ->
        {:error, :missing_head_sha}
    end
  end

  defp metadata_branch(metadata) do
    case Map.get(metadata, "branch") || get_in(metadata, ["head", "ref"]) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_branch}, else: {:ok, value}

      _value ->
        {:ok, nil}
    end
  end

  defp metadata_changed_files(metadata) do
    case Map.get(metadata, "changed_files", []) do
      values when is_list(values) ->
        {:ok, Enum.map(values, &changed_file/1)}

      count when is_integer(count) and count >= 0 ->
        {:ok, []}

      _value ->
        {:error, :invalid_changed_files}
    end
  end

  defp changed_file(path) when is_binary(path), do: %{"path" => String.trim(path)}

  defp changed_file(%{} = value) do
    value
    |> Map.take(["path", "filename", "status", "additions", "deletions", "changes"])
    |> normalize_file_path()
  end

  defp changed_file(_value), do: %{}

  defp normalize_file_path(%{"path" => path} = value) when is_binary(path), do: Map.put(value, "path", String.trim(path))
  defp normalize_file_path(%{"filename" => path} = value) when is_binary(path), do: value |> Map.put("path", String.trim(path)) |> Map.delete("filename")
  defp normalize_file_path(value), do: value

  defp metadata_map(metadata, key) do
    case Map.get(metadata, key, %{}) do
      value when is_map(value) -> {:ok, value}
      nil -> {:ok, %{}}
      _value -> {:error, :"invalid_#{key}"}
    end
  end

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp head_sha_matches?(left, right) when is_binary(left) and is_binary(right) do
    left = String.trim(left)
    right = String.trim(right)

    cond do
      left == "" or right == "" -> false
      left == right -> true
      hex_sha?(left) and hex_sha?(right) -> String.starts_with?(left, right) or String.starts_with?(right, left)
      true -> false
    end
  end

  defp head_sha_matches?(_left, _right), do: false

  defp hex_sha?(value), do: String.match?(value, ~r/^[0-9a-fA-F]{7,40}$/)
end
