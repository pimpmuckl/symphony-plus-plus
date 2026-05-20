defmodule SymphonyElixir.SymphonyPlusPlus.GitHubGhCliClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.FakeGhCli
  alias SymphonyElixir.GitHubPullRequestFixtures
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{GhCliClient, PullRequest}

  setup do
    FakeGhCli.clear()
    :ok
  end

  test "fetches gh pr view metadata with safe argv and normalizes it for PR metadata" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/repo/pull/22"}, nil)
    FakeGhCli.put_response("nextide/repo", 22, GitHubPullRequestFixtures.gh_view(22, "head-a", merged?: true, changed_files: 3))

    assert {:ok, metadata} = GhCliClient.fetch_pull_request(ref, command_runner: &FakeGhCli.run/3)
    assert {:ok, payload} = PullRequest.metadata(metadata, ref, nil)

    assert payload["number"] == 22
    assert payload["url"] == "https://github.com/nextide/repo/pull/22"
    assert payload["head_sha"] == "head-a"
    assert payload["branch"] == "agent/SYMPP-LOCAL-OPERATOR-GH-SYNC"
    assert payload["base_branch"] == "main"
    assert payload["base_sha"] == "base-sha"
    assert payload["changed_files"] == []
    assert payload["changed_files_count"] == 3
    assert payload["changed_files_available"] == false
    assert payload["changed_files_count_available"] == true
    assert payload["review_state"] == %{"draft" => false}
    assert payload["merge_state"] == %{"mergeable" => "UNKNOWN", "mergeable_state" => "unknown", "merged" => true, "state" => "merged"}

    assert [
             %{
               executable: "gh",
               args: ["pr", "view", "22", "--repo", "nextide/repo", "--json", fields],
               opts: [timeout: 5_000]
             }
           ] = FakeGhCli.commands()

    assert fields == "number,url,headRefName,headRefOid,baseRefName,baseRefOid,changedFiles,state,isDraft,mergeable,mergeStateStatus,mergedAt,mergeCommit"
  end

  test "maps gh errors to stable client reasons without surfacing command output" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/repo/pull/404"}, nil)

    FakeGhCli.put_error("nextide/repo", 404, :gh_not_found)
    assert {:error, :gh_not_found} = GhCliClient.fetch_pull_request(ref, command_runner: &FakeGhCli.run/3)

    FakeGhCli.put_error("nextide/repo", 404, :gh_unauthorized)
    assert {:error, :gh_unauthorized} = GhCliClient.fetch_pull_request(ref, command_runner: &FakeGhCli.run/3)

    FakeGhCli.put_error("nextide/repo", 404, :gh_unavailable)
    assert {:error, :gh_unavailable} = GhCliClient.fetch_pull_request(ref, command_runner: &FakeGhCli.run/3)
  end

  test "reports gh auth availability with fake command execution" do
    FakeGhCli.authenticate(:ok)
    assert GhCliClient.auth_status(command_runner: &FakeGhCli.run/3) == :ok

    FakeGhCli.authenticate(:unauthorized)
    assert GhCliClient.auth_status(command_runner: &FakeGhCli.run/3) == {:error, :gh_unauthorized}

    FakeGhCli.authenticate(:unavailable)
    assert GhCliClient.auth_status(command_runner: &FakeGhCli.run/3) == {:error, :gh_unavailable}
  end
end
