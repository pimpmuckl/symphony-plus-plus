defmodule SymphonyElixir.SymphonyPlusPlus.Comments.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Repository

  @type error :: Repository.error()

  @spec create(Repository.repo(), map()) :: {:ok, Comment.t()} | {:error, error()}
  def create(repo, attrs), do: Repository.create(repo, attrs)

  @spec get(Repository.repo(), String.t()) :: {:ok, Comment.t()} | {:error, error()}
  def get(repo, id), do: Repository.get(repo, id)

  @spec list_for_target(Repository.repo(), String.t(), String.t()) :: {:ok, [Comment.t()]} | {:error, error()}
  def list_for_target(repo, target_kind, target_id), do: Repository.list_for_target(repo, target_kind, target_id)

  @spec list_for_targets(Repository.repo(), [Repository.target()]) :: {:ok, %{Repository.target() => [Comment.t()]}} | {:error, error()}
  def list_for_targets(repo, targets), do: Repository.list_for_targets(repo, targets)

  @spec counts_for_targets(Repository.repo(), [Repository.target()]) ::
          {:ok, %{Repository.target() => %{comment_count: non_neg_integer(), open_comment_count: non_neg_integer()}}} | {:error, error()}
  def counts_for_targets(repo, targets), do: Repository.counts_for_targets(repo, targets)

  @spec resolve(Repository.repo(), String.t(), map()) :: {:ok, Comment.t()} | {:error, error()}
  def resolve(repo, id, attrs), do: Repository.resolve(repo, id, attrs)
end
