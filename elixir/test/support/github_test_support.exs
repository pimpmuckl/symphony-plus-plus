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
end
