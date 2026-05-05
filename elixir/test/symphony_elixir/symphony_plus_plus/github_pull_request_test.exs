defmodule SymphonyElixir.SymphonyPlusPlus.GitHubPullRequestTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Client, DryClient, PullRequest}

  test "parses GitHub PR URLs" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/42"}, nil)

    assert ref.owner == "nextide"
    assert ref.repo == "symphony-plus-plus"
    assert ref.repository == "nextide/symphony-plus-plus"
    assert ref.number == 42
    assert ref.url == "https://github.com/nextide/symphony-plus-plus/pull/42"
  end

  test "parses PR numbers against package repository" do
    assert {:ok, ref} = PullRequest.parse(%{"number" => 77}, "nextide/symphony-plus-plus")

    assert ref.repository == "nextide/symphony-plus-plus"
    assert ref.number == 77
    assert ref.url == "https://github.com/nextide/symphony-plus-plus/pull/77"
  end

  test "rejects malformed PR references" do
    assert {:error, :invalid_pr_url} = PullRequest.parse(%{"url" => "https://example.com/nextide/repo/pull/1"}, nil)
    assert {:error, :missing_repository} = PullRequest.parse(%{"number" => 1}, nil)
    assert {:error, :invalid_pr_number} = PullRequest.parse(%{"number" => 0}, "nextide/repo")
  end

  test "maps dry metadata into a redaction-friendly PR payload" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/42"}, nil)

    metadata = %{
      "head_sha" => "abc123",
      "branch" => "agent/SYMPP-P6-001/github-pr-attachment-sync",
      "changed_files" => [%{"filename" => "elixir/lib/example.ex", "status" => "modified"}],
      "check_summary" => %{"state" => "success", "token" => "ghp_should_not_surface"},
      "review_state" => %{"state" => "approved", "authorization" => "Bearer secret"},
      "merge_state" => %{"state" => "clean", "client_secret" => "secret"}
    }

    assert {:ok, fetched} = Client.fetch_pull_request(DryClient, ref, metadata: metadata)
    assert {:ok, payload} = PullRequest.metadata(fetched, ref, nil)

    assert payload["repository"] == "nextide/symphony-plus-plus"
    assert payload["number"] == 42
    assert payload["head_sha"] == "abc123"
    assert payload["changed_files"] == [%{"path" => "elixir/lib/example.ex", "status" => "modified"}]
    assert payload["check_summary"] == %{"state" => "success", "token" => "[REDACTED]"}
    assert payload["review_state"] == %{"state" => "approved", "authorization" => "[REDACTED]"}
    assert payload["merge_state"] == %{"state" => "clean", "client_secret" => "[REDACTED]"}
    refute Map.has_key?(payload, "authorization")
  end

  test "maps standard GitHub head object into PR head metadata" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/42"}, nil)

    metadata = %{
      "head" => %{"sha" => "abc123", "ref" => "agent/SYMPP-P6-001/github-pr-attachment-sync"},
      "changed_files" => []
    }

    assert {:ok, payload} = PullRequest.metadata(metadata, ref, nil)

    assert payload["head_sha"] == "abc123"
    assert payload["branch"] == "agent/SYMPP-P6-001/github-pr-attachment-sync"
  end

  test "detects stale PR metadata by head sha" do
    refute PullRequest.stale?(%{"head_sha" => "abc123"}, "abc123")
    assert PullRequest.stale?(%{"head_sha" => "abc123"}, "def456")
  end

  test "dry client requires explicit metadata" do
    assert {:ok, ref} = PullRequest.parse(%{"url" => "https://github.com/nextide/symphony-plus-plus/pull/42"}, nil)

    assert {:error, :metadata_required} = Client.fetch_pull_request(DryClient, ref)
  end
end
