defmodule SymphonyElixir.SymphonyPlusPlus.MCP.SoloTools do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Config
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository, as: SoloSessionRepository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service, as: SoloSessionService
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry

  @show_entry_limit 50

  @type result :: {:ok, map()} | {:error, integer(), String.t(), map()}
  @type error_fun :: (term(), String.t() -> result())

  @spec tool_spec(String.t()) :: map()
  def tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => description(name),
      "inputSchema" => input_schema(name)
    }
  end

  @spec input_schema(String.t()) :: map()
  def input_schema("solo_attach") do
    schema(
      %{
        "repo" => string_schema(),
        "base_branch" => string_schema(),
        "workspace_path" => string_schema(),
        "caller_id" => string_schema(),
        "title" => nullable_string_schema()
      },
      ["repo", "base_branch", "workspace_path", "caller_id"]
    )
  end

  def input_schema("solo_append") do
    schema(
      %{
        "session_id" => string_schema(),
        "entry_kind" => string_schema(),
        "title" => string_schema(),
        "body" => markdown_nullable_string_schema("Optional human-facing Markdown body."),
        "status" => nullable_string_schema(),
        "idempotency_key" => nullable_string_schema(),
        "payload" => object_schema()
      },
      ["session_id", "entry_kind", "title"]
    )
  end

  def input_schema("solo_show"), do: schema(%{"session_id" => string_schema()}, ["session_id"])

  def input_schema("solo_list") do
    schema(
      %{
        "repo" => string_schema(),
        "base_branch" => string_schema(),
        "workspace_path" => string_schema(),
        "caller_id" => string_schema(),
        "status" => string_schema()
      },
      []
    )
  end

  def input_schema("solo_update_status") do
    schema(
      %{
        "session_id" => string_schema(),
        "current_status" => string_schema(),
        "next_status" => string_schema()
      },
      ["session_id", "current_status", "next_status"]
    )
  end

  @spec call(String.t(), map(), Config.t(), error_fun()) :: result()
  def call("solo_attach", arguments, %Config{} = config, error_fun) when is_function(error_fun, 2) do
    with :ok <- prepare_repository(config.repo),
         {:ok, repo_name} <- required_argument(arguments, "repo"),
         {:ok, base_branch} <- required_argument(arguments, "base_branch"),
         {:ok, workspace_path} <- required_argument(arguments, "workspace_path"),
         {:ok, caller_id} <- required_argument(arguments, "caller_id"),
         {:ok, session} <-
           SoloSessionService.create_or_attach_current(config.repo, %{
             "repo" => repo_name,
             "base_branch" => base_branch,
             "workspace_path" => workspace_path,
             "caller_id" => caller_id,
             "title" => Map.get(arguments, "title")
           }) do
      {:ok, tool_result(%{"action" => "solo_attach", "solo_session" => solo_session_payload(session)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "solo_attach", "reason" => reason}}
      {:error, reason} -> solo_error(reason, "solo_attach", error_fun)
    end
  end

  def call("solo_append", arguments, %Config{} = config, error_fun) when is_function(error_fun, 2) do
    with :ok <- prepare_repository(config.repo),
         {:ok, session_id} <- required_argument(arguments, "session_id"),
         {:ok, entry_kind} <- required_argument(arguments, "entry_kind"),
         {:ok, title} <- required_argument(arguments, "title"),
         {:ok, payload} <- optional_object_argument(arguments, "payload"),
         attrs <-
           %{"entry_kind" => entry_kind, "title" => title}
           |> put_optional_attr(arguments, "body")
           |> put_optional_attr(arguments, "status")
           |> put_optional_attr(arguments, "idempotency_key")
           |> put_optional_payload(payload),
         {:ok, entry} <- SoloSessionService.append_entry(config.repo, session_id, attrs) do
      {:ok, tool_result(%{"action" => "solo_append", "entry" => solo_entry_payload(entry)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "solo_append", "reason" => reason}}
      {:error, reason} -> solo_error(reason, "solo_append", error_fun)
    end
  end

  def call("solo_show", arguments, %Config{} = config, error_fun) when is_function(error_fun, 2) do
    with :ok <- prepare_repository(config.repo),
         {:ok, session_id} <- required_argument(arguments, "session_id"),
         {:ok, session} <- SoloSessionService.get(config.repo, session_id),
         {:ok, entries} <- SoloSessionService.list_entries(config.repo, session_id) do
      recent_entries = recent_entries(entries)

      {:ok,
       tool_result(%{
         "action" => "solo_show",
         "solo_session" => solo_session_payload(session),
         "entries" => Enum.map(recent_entries, &solo_entry_payload/1),
         "entry_count" => length(entries),
         "entries_returned" => length(recent_entries),
         "entries_truncated" => length(entries) > length(recent_entries)
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "solo_show", "reason" => reason}}
      {:error, reason} -> solo_error(reason, "solo_show", error_fun)
    end
  end

  def call("solo_list", arguments, %Config{} = config, error_fun) when is_function(error_fun, 2) do
    with :ok <- prepare_repository(config.repo),
         {:ok, filters} <- list_filters(arguments),
         {:ok, sessions} <- SoloSessionService.list(config.repo, filters) do
      {:ok, tool_result(%{"action" => "solo_list", "solo_sessions" => Enum.map(sessions, &solo_session_payload/1)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "solo_list", "reason" => reason}}
      {:error, reason} -> solo_error(reason, "solo_list", error_fun)
    end
  end

  def call("solo_update_status", arguments, %Config{} = config, error_fun) when is_function(error_fun, 2) do
    with :ok <- prepare_repository(config.repo),
         {:ok, session_id} <- required_argument(arguments, "session_id"),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, next_status} <- required_argument(arguments, "next_status"),
         {:ok, session} <- SoloSessionService.update_status(config.repo, session_id, current_status, next_status) do
      {:ok, tool_result(%{"action" => "solo_update_status", "solo_session" => solo_session_payload(session)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "solo_update_status", "reason" => reason}}
      {:error, reason} -> solo_error(reason, "solo_update_status", error_fun)
    end
  end

  defp description("solo_attach") do
    "Create or attach a local Solo Session for a repo, base branch, absolute workspace path, and caller id."
  end

  defp description("solo_append") do
    "Append one redacted entry to a local Solo Session using the existing Solo Session service."
  end

  defp description("solo_show") do
    "Read a local Solo Session and its latest 50 ordered entries."
  end

  defp description("solo_list") do
    "List local Solo Sessions using optional repo, base branch, workspace path, caller id, and status filters."
  end

  defp description("solo_update_status") do
    "Move a local Solo Session between valid lifecycle statuses with optimistic current-status checking."
  end

  defp prepare_repository(repo), do: SoloSessionRepository.migrate(repo)

  defp recent_entries(entries), do: Enum.take(entries, -@show_entry_limit)

  defp list_filters(arguments) do
    Enum.reduce_while(["repo", "base_branch", "workspace_path", "caller_id", "status"], {:ok, %{}}, fn key, {:ok, filters} ->
      case Map.fetch(arguments, key) do
        :error -> {:cont, {:ok, filters}}
        {:ok, nil} -> {:cont, {:ok, filters}}
        {:ok, value} when is_binary(value) -> {:cont, {:ok, Map.put(filters, key, value)}}
        {:ok, _value} -> {:halt, {:tool_error, "invalid_#{key}"}}
      end
    end)
  end

  defp put_optional_attr(attrs, arguments, key) do
    case Map.fetch(arguments, key) do
      {:ok, nil} -> attrs
      {:ok, value} -> Map.put(attrs, key, value)
      :error -> attrs
    end
  end

  defp put_optional_payload(attrs, nil), do: attrs
  defp put_optional_payload(attrs, payload), do: Map.put(attrs, "payload", payload)

  defp solo_error(:not_found, tool, _error_fun), do: {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}
  defp solo_error(reason, tool, error_fun), do: error_fun.(reason, tool)

  defp solo_session_payload(%SoloSession{} = session) do
    %{
      "id" => Redactor.redact_text(session.id),
      "repo" => Redactor.redact_text(session.repo),
      "base_branch" => Redactor.redact_text(session.base_branch),
      "workspace_path" => Redactor.redact_text(session.workspace_path),
      "caller_id" => Redactor.redact_text(session.caller_id),
      "session_key" => Redactor.redact_text(session.session_key),
      "title" => Redactor.redact_text(session.title),
      "status" => Redactor.redact_text(session.status),
      "last_activity_at" => timestamp(session.last_activity_at),
      "archived_at" => timestamp(session.archived_at),
      "created_at" => timestamp(session.inserted_at),
      "updated_at" => timestamp(session.updated_at)
    }
  end

  defp solo_entry_payload(%SoloSessionEntry{} = entry) do
    %{
      "id" => Redactor.redact_text(entry.id),
      "solo_session_id" => Redactor.redact_text(entry.solo_session_id),
      "entry_kind" => Redactor.redact_text(entry.entry_kind),
      "title" => Redactor.redact_text(entry.title),
      "body" => Redactor.redact_text(entry.body),
      "status" => Redactor.redact_text(entry.status),
      "sequence" => entry.sequence,
      "idempotency_key" => Redactor.redact_text(entry.idempotency_key),
      "payload" => Redactor.redact_output(entry.payload || %{}),
      "created_at" => timestamp(entry.created_at),
      "updated_at" => timestamp(entry.updated_at)
    }
  end

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  defp timestamp(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp timestamp(nil), do: nil

  defp tool_result(payload) do
    %{
      "content" => [%{"type" => "text", "text" => WorkerContext.encode_tool_payload(payload)}],
      "structuredContent" => payload,
      "isError" => false
    }
  end

  defp schema(properties, required) do
    %{"type" => "object", "additionalProperties" => false, "properties" => properties, "required" => required}
  end

  defp string_schema, do: %{"type" => "string"}
  defp nullable_string_schema, do: %{"type" => ["string", "null"]}
  defp markdown_nullable_string_schema(description), do: Map.put(nullable_string_schema(), "description", description)
  defp object_schema, do: %{"type" => "object", "additionalProperties" => true}

  defp required_argument(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "missing_#{key}"}
    end
  end

  defp optional_object_argument(arguments, key) do
    case Map.fetch(arguments, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
    end
  end
end
