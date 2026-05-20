defmodule SymphonyElixir.FakeGitHubClient do
  @moduledoc false
  @behaviour SymphonyElixir.SymphonyPlusPlus.GitHub.Client

  @responses_key {__MODULE__, :responses}

  def put_response(repository, number, response) do
    responses = Process.get(@responses_key, %{})
    Process.put(@responses_key, Map.put(responses, {String.downcase(repository), number}, response))
  end

  def clear, do: Process.delete(@responses_key)

  @impl true
  def fetch_pull_request(ref, _opts) do
    case Process.get(@responses_key, %{}) |> Map.fetch({String.downcase(ref.repository), ref.number}) do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, metadata} -> {:ok, metadata}
      :error -> {:error, :not_found}
    end
  end
end

defmodule SymphonyElixir.FakeAuthenticatedGitHubClient do
  @moduledoc false
  @behaviour SymphonyElixir.SymphonyPlusPlus.GitHub.Client

  def authenticated?, do: true

  @impl true
  def fetch_pull_request(ref, opts), do: SymphonyElixir.FakeGitHubClient.fetch_pull_request(ref, opts)
end

defmodule SymphonyElixir.GitHubTestSupport do
  @moduledoc false

  def with_github_token_env(value, fun) when is_function(fun, 0) do
    original_github_token = System.get_env("GITHUB_TOKEN")
    original_gh_token = System.get_env("GH_TOKEN")

    try do
      set_env("GITHUB_TOKEN", value)
      set_env("GH_TOKEN", value)
      fun.()
    after
      set_env("GITHUB_TOKEN", original_github_token)
      set_env("GH_TOKEN", original_gh_token)
    end
  end

  defp set_env(key, nil), do: System.delete_env(key)
  defp set_env(key, value), do: System.put_env(key, value)
end

defmodule SymphonyElixir.FakeGhCli do
  @moduledoc false

  @auth_status_key {__MODULE__, :auth_status}
  @commands_key {__MODULE__, :commands}
  @responses_key {__MODULE__, :responses}

  def authenticate(status \\ :ok), do: Process.put(@auth_status_key, status)

  def put_response(repository, number, response) do
    responses = Process.get(@responses_key, %{})
    Process.put(@responses_key, Map.put(responses, {String.downcase(repository), number}, response))
  end

  def put_error(repository, number, reason) do
    put_response(repository, number, {:error, reason})
  end

  def commands, do: Process.get(@commands_key, [])

  def clear do
    Process.delete(@auth_status_key)
    Process.delete(@commands_key)
    Process.delete(@responses_key)
  end

  def run(executable, args, opts) do
    Process.put(@commands_key, commands() ++ [%{executable: executable, args: args, opts: opts}])

    case args do
      ["auth", "status", "--hostname", "github.com"] ->
        auth_response(Process.get(@auth_status_key, :ok))

      ["pr", "view", number, "--repo", repository, "--json", _fields] ->
        pr_response(repository, number)

      _args ->
        {:error, {1, "unknown gh command"}}
    end
  end

  defp auth_response(:ok), do: {:ok, ""}
  defp auth_response(:unauthorized), do: {:error, {1, "not logged into github.com"}}
  defp auth_response(:unavailable), do: {:error, :enoent}
  defp auth_response({:error, reason}), do: error_response(reason)

  defp pr_response(repository, number) do
    with {parsed_number, ""} <- Integer.parse(number),
         {:ok, response} <- Process.get(@responses_key, %{}) |> Map.fetch({String.downcase(repository), parsed_number}) do
      case response do
        {:error, reason} -> error_response(reason)
        json when is_binary(json) -> {:ok, json}
        metadata when is_map(metadata) -> {:ok, Jason.encode!(metadata)}
      end
    else
      _missing -> {:error, {1, "could not resolve to a PullRequest"}}
    end
  end

  defp error_response(:gh_unauthorized), do: {:error, {1, "not authenticated"}}
  defp error_response(:gh_not_found), do: {:error, {1, "could not resolve to a PullRequest"}}
  defp error_response(:gh_unavailable), do: {:error, :enoent}
  defp error_response(:request_failed), do: {:error, {1, "gh request failed"}}
  defp error_response(reason), do: {:error, reason}
end

defmodule SymphonyElixir.GitHubPullRequestFixtures do
  @moduledoc false

  def metadata(number, head_sha, opts \\ []) do
    merged? = Keyword.get(opts, :merged?, false)
    base_branch = Keyword.get(opts, :base_branch, "main")

    %{
      "number" => number,
      "html_url" => "https://github.com/nextide/repo/pull/#{number}",
      "head" => %{"sha" => head_sha, "ref" => "agent/SYMPP-LOCAL-OPERATOR-GH-SYNC"},
      "base" => %{"ref" => base_branch, "sha" => "base-sha"},
      "changed_files" => [],
      "state" => if(merged?, do: "closed", else: "open"),
      "merged" => merged?,
      "mergeable" => not merged?,
      "mergeable_state" => if(merged?, do: "unknown", else: "clean"),
      "merged_at" => if(merged?, do: "2026-05-20T12:00:00Z", else: nil),
      "merge_commit_sha" => if(merged?, do: "merge-sha-#{number}", else: nil)
    }
  end

  def gh_view(number, head_sha, opts \\ []) do
    merged? = Keyword.get(opts, :merged?, false)
    base_branch = Keyword.get(opts, :base_branch, "main")
    changed_files = Keyword.get(opts, :changed_files, 2)

    %{
      "number" => number,
      "url" => "https://github.com/nextide/repo/pull/#{number}",
      "headRefName" => "agent/SYMPP-LOCAL-OPERATOR-GH-SYNC",
      "headRefOid" => head_sha,
      "baseRefName" => base_branch,
      "baseRefOid" => "base-sha",
      "changedFiles" => changed_files,
      "state" => if(merged?, do: "MERGED", else: "OPEN"),
      "isDraft" => false,
      "mergeable" => if(merged?, do: "UNKNOWN", else: "MERGEABLE"),
      "mergeStateStatus" => if(merged?, do: "UNKNOWN", else: "CLEAN"),
      "mergedAt" => if(merged?, do: "2026-05-20T12:00:00Z", else: nil),
      "mergeCommit" => if(merged?, do: %{"oid" => "merge-sha-#{number}"}, else: nil)
    }
  end
end
