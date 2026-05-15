defmodule SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry

  @type error :: Repository.error()

  @spec create_or_attach_current(Repository.repo(), map()) :: {:ok, SoloSession.t()} | {:error, error()}
  def create_or_attach_current(repo, attrs), do: Repository.create_or_attach_current(repo, attrs)

  @spec get(Repository.repo(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def get(repo, id), do: Repository.get(repo, id)

  @spec list(Repository.repo()) :: {:ok, [SoloSession.t()]} | {:error, error()}
  @spec list(Repository.repo(), map()) :: {:ok, [SoloSession.t()]} | {:error, error()}
  def list(repo, filters \\ %{}), do: Repository.list(repo, filters)

  @spec update_status(Repository.repo(), String.t(), String.t(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def update_status(repo, id, current_status, next_status), do: Repository.update_status(repo, id, current_status, next_status)

  @spec pause(Repository.repo(), String.t(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def pause(repo, solo_session_id, current_status), do: Repository.update_status(repo, solo_session_id, current_status, "paused")

  @spec resume(Repository.repo(), String.t(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def resume(repo, solo_session_id, current_status), do: Repository.update_status(repo, solo_session_id, current_status, "active")

  @spec complete(Repository.repo(), String.t(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def complete(repo, solo_session_id, current_status), do: Repository.update_status(repo, solo_session_id, current_status, "completed")

  @spec archive(Repository.repo(), String.t(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def archive(repo, solo_session_id, current_status), do: Repository.update_status(repo, solo_session_id, current_status, "archived")

  @spec archive_stale(Repository.repo()) :: {:ok, non_neg_integer()} | {:error, error()}
  def archive_stale(repo), do: Repository.archive_stale(repo)

  @spec archive_stale(Repository.repo(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, error()}
  def archive_stale(repo, now), do: Repository.archive_stale(repo, now)

  @spec archive_stale(Repository.repo(), DateTime.t(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, error()}
  def archive_stale(repo, now, stale_after_days), do: Repository.archive_stale(repo, now, stale_after_days)

  @spec append_entry(Repository.repo(), String.t(), map()) :: {:ok, SoloSessionEntry.t()} | {:error, error()}
  def append_entry(repo, solo_session_id, attrs), do: Repository.append_entry(repo, solo_session_id, attrs)

  @spec get_entry(Repository.repo(), String.t(), String.t()) :: {:ok, SoloSessionEntry.t()} | {:error, error()}
  def get_entry(repo, solo_session_id, entry_id), do: Repository.get_entry(repo, solo_session_id, entry_id)

  @spec list_entries(Repository.repo(), String.t()) :: {:ok, [SoloSessionEntry.t()]} | {:error, error()}
  def list_entries(repo, solo_session_id), do: Repository.list_entries(repo, solo_session_id)
end
