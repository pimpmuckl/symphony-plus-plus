defmodule SymphonyElixir.SymphonyPlusPlus.AgentFormat.ToolReceipt do
  @moduledoc false

  @redacted "[REDACTED]"
  @ok "ok"

  @spec payload(map()) :: map() | String.t()
  def payload(payload) when is_map(payload) do
    first_receipt(payload) || payload
  end

  defp first_receipt(payload), do: first_receipt(receipt_presenters(), payload)

  defp first_receipt([{predicate, builder} | rest], payload) do
    if predicate.(payload), do: builder.(payload), else: first_receipt(rest, payload)
  end

  defp first_receipt([], _payload), do: nil

  defp receipt_presenters do
    [
      {&worktree_lifecycle?/1, &worktree_payload/1},
      {&release_current_assignment?/1, &release_payload/1},
      {&local_assignment_claim?/1, &local_assignment_payload/1},
      {&current_assignment?/1, &current_assignment_payload/1},
      {&progress_event?/1, &progress_event_payload/1},
      {&finding?/1, &finding_payload/1},
      {&comment?/1, &comment_payload/1},
      {&question?/1, &question_payload/1},
      {&decision?/1, &decision_payload/1},
      {&planned_slice_delivery?/1, &planned_slice_delivery_payload/1},
      {&planned_slice_dispatch?/1, &planned_slice_dispatch_payload/1},
      {&solo_entry?/1, &solo_entry_payload/1},
      {&solo_show?/1, &solo_show_payload/1},
      {&solo_session?/1, &solo_session_payload/1},
      {&solo_list?/1, &solo_list_payload/1}
    ]
  end

  defp worktree_lifecycle?(payload), do: map?(map_value(payload, "worktree")) and map?(map_value(payload, "work_package"))
  defp release_current_assignment?(payload), do: map_value(payload, "action") == "release_current_assignment"
  defp local_assignment_claim?(payload), do: map?(map_value(payload, "assignment")) and map?(map_value(payload, "local_claim"))
  defp current_assignment?(payload), do: map?(map_value(payload, "assignment"))
  defp progress_event?(payload), do: map?(map_value(payload, "progress_event"))
  defp finding?(payload), do: map?(map_value(payload, "finding"))
  defp comment?(payload), do: map?(map_value(payload, "comment"))
  defp decision?(payload), do: map?(map_value(payload, "decision_log_entry"))
  defp question?(payload), do: map?(map_value(payload, "clarification_question"))
  defp planned_slice_delivery?(payload), do: map?(map_value(payload, "planned_slice_delivery"))

  defp planned_slice_dispatch?(payload) do
    map?(map_value(payload, "planned_slice")) and map?(map_value(payload, "work_package")) and
      not is_nil(map_value(payload, "worker_bootstrap"))
  end

  defp solo_entry?(payload), do: is_binary(map_value(payload, "action")) and map?(map_value(payload, "entry"))

  defp solo_show?(payload) do
    is_binary(map_value(payload, "action")) and map?(map_value(payload, "solo_session")) and
      not is_nil(map_value(payload, "entries_returned"))
  end

  defp solo_session?(payload), do: is_binary(map_value(payload, "action")) and map?(map_value(payload, "solo_session"))
  defp solo_list?(payload), do: map_value(payload, "action") == "solo_list" and is_list(map_value(payload, "solo_sessions"))

  defp worktree_payload(payload) do
    worktree = map_value(payload, "worktree")
    worker_launch = map_value(payload, "worker_launch")
    status = text_value(map_value(worktree, "status"))

    if status in ["prepared", "already_prepared"] do
      @ok
      |> append_line("workspace_path", visible_text(first_present([map_value(worker_launch, "workspace_path"), map_value(worktree, "path")])))
      |> append_line("branch", visible_text(first_present([map_value(worker_launch, "branch"), map_value(worktree, "branch")])))
    else
      @ok
    end
  end

  defp release_payload(payload) do
    payload
    |> map_value("recovery")
    |> map_value("next_action")
    |> release_next_action()
    |> ok()
  end

  defp local_assignment_payload(payload) do
    assignment = map_value(payload, "assignment")
    role = text_value(map_value(assignment, "grant_role"))

    role
    |> local_assignment_next_action()
    |> ok()
  end

  defp current_assignment_payload(payload) do
    assignment = map_value(payload, "assignment")

    %{
      "current_assignment" =>
        [
          {"role", text_value(first_present([map_value(assignment, "role"), map_value(assignment, "grant_role")]))},
          {"work_package_id", text_value(map_value(assignment, "work_package_id"))},
          {"claimed_by", visible_text(map_value(assignment, "claimed_by"))}
        ]
        |> compact_map()
    }
  end

  defp progress_event_payload(payload) do
    event = map_value(payload, "progress_event")
    event_payload = map_value(event, "payload")
    source_tool = text_value(map_value(event_payload, "source_tool"))

    source_tool
    |> progress_event_next_action()
    |> ok()
  end

  defp finding_payload(_payload), do: @ok
  defp comment_payload(_payload), do: @ok
  defp decision_payload(_payload), do: @ok
  defp question_payload(_payload), do: @ok
  defp planned_slice_delivery_payload(_payload), do: @ok
  defp planned_slice_dispatch_payload(_payload), do: ok("launch worker from handoff")
  defp solo_entry_payload(_payload), do: @ok
  defp solo_session_payload(_payload), do: @ok

  defp solo_show_payload(payload) do
    solo_session = map_value(payload, "solo_session")
    entries = map_value(payload, "entries") || []

    %{
      "solo_session" => solo_session_summary_payload(solo_session),
      "entries" => Enum.map(entries, &solo_entry_summary_payload/1),
      "entry_count" => map_value(payload, "entry_count"),
      "entries_returned" => map_value(payload, "entries_returned"),
      "entries_truncated" => map_value(payload, "entries_truncated")
    }
  end

  defp solo_list_payload(payload) do
    sessions = map_value(payload, "solo_sessions") || []

    %{
      "solo_sessions" => Enum.map(sessions, &solo_session_list_payload/1)
    }
  end

  defp release_next_action("retry_solo_tool"), do: "use Solo tools or claim another assignment"
  defp release_next_action("start_fresh_mcp_session"), do: "start a fresh MCP session before retrying"
  defp release_next_action("retry_release_current_assignment"), do: "retry release or start a fresh MCP session"
  defp release_next_action(_next_action), do: nil

  defp local_assignment_next_action("architect"), do: "read WorkRequest and delivery board"
  defp local_assignment_next_action(_role), do: "read context and task plan"

  defp progress_event_next_action("report_blocker"), do: "resolve blocker before marking ready"
  defp progress_event_next_action("request_scope_expansion"), do: "wait for scope approval"
  defp progress_event_next_action("submit_review_package"), do: "mark ready when gates are satisfied"
  defp progress_event_next_action("attach_review_suite_result"), do: "continue validation or mark ready"
  defp progress_event_next_action(_source_tool), do: nil

  defp ok(nil), do: @ok
  defp ok(action), do: @ok <> "\nnext: " <> action

  defp append_line(text, _key, nil), do: text
  defp append_line(text, key, value), do: text <> "\n" <> key <> ": " <> value

  defp solo_session_summary_payload(session) do
    [
      {"title", visible_text(map_value(session, "title"))},
      {"status", text_value(map_value(session, "status"))}
    ]
    |> compact_map()
  end

  defp solo_session_list_payload(session) do
    [
      {"session_id", text_value(map_value(session, "id"))},
      {"title", visible_text(map_value(session, "title"))},
      {"status", text_value(map_value(session, "status"))}
    ]
    |> compact_map()
  end

  defp solo_entry_summary_payload(entry) do
    [
      {"entry_kind", text_value(map_value(entry, "entry_kind"))},
      {"title", visible_text(map_value(entry, "title"))},
      {"status", text_value(map_value(entry, "status"))}
    ]
    |> compact_map()
  end

  defp compact_map(pairs) do
    pairs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp visible_text(value) do
    case text_value(value) do
      nil -> nil
      "" -> nil
      @redacted -> nil
      text -> text
    end
  end

  defp first_present(values) when is_list(values), do: Enum.find(values, &present?/1)

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?([]), do: false
  defp present?(%{} = map), do: map_size(map) > 0
  defp present?(_value), do: true

  defp map?(%{}), do: true
  defp map?(_value), do: false

  defp map_value(%{} = map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> find_atom_key_value(map, key)
    end
  end

  defp map_value(_value, _key), do: nil

  defp find_atom_key_value(map, key) do
    Enum.find_value(map, fn
      {map_key, value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: value

      _entry ->
        nil
    end)
  end

  defp text_value(nil), do: nil
  defp text_value(value) when is_binary(value), do: value
  defp text_value(value) when is_atom(value), do: Atom.to_string(value)
  defp text_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp text_value(value), do: inspect(value)
end
