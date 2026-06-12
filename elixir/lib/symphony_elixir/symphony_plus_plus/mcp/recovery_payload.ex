defmodule SymphonyElixir.SymphonyPlusPlus.MCP.RecoveryPayload do
  @moduledoc false

  @assignment_release_tool "release_current_assignment"
  @local_assignment_claim_tool "claim_local_assignment"
  @local_architect_assignment_claim_tool "claim_local_architect_assignment"

  def compact(reason, category, recoverability, next_action, opts \\ []) do
    %{
      "reason" => reason,
      "category" => category,
      "recoverability" => recoverability,
      "next_action" => next_action
    }
    |> optional_put("tool", Keyword.get(opts, :tool))
    |> optional_put("retry", Keyword.get(opts, :retry))
    |> optional_put("ignored_optional_scope_hints", Keyword.get(opts, :ignored_optional_scope_hints))
    |> optional_put("fresh_mcp_session_required", Keyword.get(opts, :fresh_mcp_session_required))
    |> optional_put("protected_boundary", Keyword.get(opts, :protected_boundary))
    |> optional_put("fallback", Keyword.get(opts, :fallback))
  end

  def maybe_claim_hint_mismatch_data(tool, reason, durable_id_field) do
    base = %{"tool" => tool, "reason" => reason}

    if optional_claim_hint_mismatch?(reason) do
      Map.merge(base, %{
        "classification" => "optional_scope_hint_mismatch",
        "can_retry_with_id_only" => true,
        "safe_next_tool" => tool,
        "recovery" =>
          compact(reason, "optional_scope_hint", "recoverable_with_id_only", "retry_with_durable_id_only", retry: %{"tool" => tool, "arguments" => %{durable_id_field => "<#{durable_id_field}>"}}),
        "hint" => "Normal claims use #{durable_id_field} plus optional claimed_by. Omit repo/base/phase/branch/worktree/caller hints unless an operator asks for an explicit scope check.",
        "operator_action" => "If id-only retry still fails, inspect the ledger assignment scope before weakening authority checks."
      })
    else
      base
    end
  end

  def maybe_put_claim_failure_recovery(%{"recovery" => _recovery} = data), do: data
  def maybe_put_claim_failure_recovery(%{"reason" => reason} = data), do: Map.put(data, "recovery", claim_failure_recovery(reason))

  def maybe_put_optional_scope_hint_recovery(payload, [], _tool, _retry_arguments), do: payload

  def maybe_put_optional_scope_hint_recovery(payload, warnings, tool, retry_arguments) when is_list(warnings) do
    Map.put(
      payload,
      "recovery",
      compact("optional_scope_hints_ignored", "session_recovery", "recovered", "continue_with_current_assignment",
        ignored_optional_scope_hints: warnings,
        retry: %{"tool" => tool, "arguments" => retry_arguments}
      )
    )
  end

  def claim_required_data(resource, claim_tool, retry_arguments) do
    %{
      "resource" => resource,
      "reason" => "claim_required",
      "action" => claim_tool,
      "recovery" => compact("claim_required", "session_binding", "recoverable_with_claim", claim_tool, retry: %{"tool" => claim_tool, "arguments" => retry_arguments})
    }
  end

  def architect_handoff_state_mismatch_data(reason) do
    %{
      "reason" => reason,
      "classification" => "architect_handoff_state_mismatch",
      "can_retry_with_id_only" => false,
      "recovery" =>
        compact(reason, "authority_boundary", "operator_repair_required", "repair_architect_handoff_state",
          protected_boundary: "WorkRequest architect authority must match the prepared handoff anchor and phase."
        ),
      "hint" =>
        "The durable work_request_id resolved, but the persisted architect handoff anchor no longer matches the WorkRequest or phase. This protects WorkRequest authority and data integrity; id-only retry cannot repair ledger drift.",
      "operator_action" => "Ask the operator to inspect or recreate the WorkRequest architect handoff before retrying."
    }
  end

  def claim_lease_active_for_other_actor_data(tool, hint) do
    %{
      "tool" => tool,
      "reason" => "claim_lease_active_for_other_actor",
      "action" => "reuse_claim_identity_or_recycle_stale_claim",
      "recovery" =>
        compact("claim_lease_active_for_other_actor", "claim_lease", "blocked_by_active_owner", "reuse_claim_identity_or_wait_for_stale_reclaim",
          protected_boundary: "An active local claim lease for another owner still controls this assignment."
        ),
      "hint" => hint
    }
  end

  def architect_handoff_not_prepared_data(work_request_id, expected_anchor_id, expected_phase_id) do
    %{
      "tool" => @local_architect_assignment_claim_tool,
      "reason" => "architect_handoff_not_prepared",
      "action" => "prepare_architect_handoff",
      "work_request_id" => work_request_id,
      "expected_architect_anchor_work_package_id" => expected_anchor_id,
      "expected_phase_id" => expected_phase_id,
      "recovery" =>
        compact("architect_handoff_not_prepared", "handoff", "operator_repair_required", "prepare_architect_handoff",
          retry: %{"tool" => @local_architect_assignment_claim_tool, "arguments" => %{"work_request_id" => work_request_id}},
          protected_boundary: "Architect authority must be backed by a prepared local handoff anchor."
        ),
      "message" => "This WorkRequest exists, but its local architect handoff anchor has not been prepared.",
      "hint" => "Ask the local operator to prepare the architect handoff, then retry claim_local_architect_assignment."
    }
  end

  def session_already_bound_data(tool, current_assignment \\ nil)

  def session_already_bound_data(tool, current_assignment) when is_map(current_assignment) do
    tool
    |> session_already_bound_data(nil)
    |> Map.put("current_assignment", current_assignment)
  end

  def session_already_bound_data(tool, _current_assignment) do
    %{
      "tool" => tool,
      "reason" => "session_already_bound",
      "action" => "use_fresh_mcp_session_or_release_current_assignment",
      "recovery" =>
        compact("session_already_bound", "session_binding", "recoverable_with_fresh_session_or_release", "use_fresh_mcp_session_or_release_current_assignment",
          retry: %{"tool" => @assignment_release_tool, "arguments" => %{"reason" => "abandon current binding"}},
          protected_boundary: "One MCP session can hold authority for only one active assignment at a time."
        ),
      "hint" => "This MCP session is already bound. Start a fresh MCP session for a different assignment, or call release_current_assignment only if abandoning the current binding."
    }
  end

  def solo_tools_require_unbound_session_data(tool, current_assignment) do
    %{
      "tool" => tool,
      "reason" => "solo_tools_require_unbound_session",
      "action" => @assignment_release_tool,
      "current_assignment" => current_assignment,
      "recovery" =>
        compact("solo_tools_require_unbound_session", "session_binding", "recoverable_with_release", "call_release_current_assignment_then_retry_solo_tool",
          tool: @assignment_release_tool,
          retry: %{"tool" => @assignment_release_tool, "arguments" => %{"reason" => "switch to Solo tools"}},
          fresh_mcp_session_required: false,
          fallback: "If release_current_assignment is unavailable or returns fresh_mcp_session_required=true, start a fresh MCP session before using Solo tools."
        )
    }
  end

  def auth_recovery(reason) when reason in ["expired", "revoked", "not_found"] do
    compact(reason, "assignment_authority", "recoverable_with_claim_or_operator_repair", "reclaim_assignment_or_start_fresh_session")
  end

  def auth_recovery(reason) when reason in ["assignment_mismatch", "worker_grant_required", "architect_grant_required"] do
    compact(reason, "authority_boundary", "operator_repair_required", "ask_operator_to_repair_assignment_scope",
      protected_boundary: "The live grant no longer matches the authority this MCP session needs."
    )
  end

  def auth_recovery("insufficient_capability") do
    compact("insufficient_capability", "authority_boundary", "not_recoverable_without_scope_change", "request_scope_expansion_or_use_scoped_tool",
      protected_boundary: "The current grant lacks the capability required for this tool."
    )
  end

  def auth_recovery(reason), do: claim_session_recovery(reason)

  def claim_session_recovery(reason) do
    compact(reason, "session_binding", "recoverable_with_claim", @local_assignment_claim_tool,
      retry: %{"tool" => @local_assignment_claim_tool, "arguments" => %{"work_package_id" => "<work_package_id>"}},
      fallback: %{"tool" => @local_architect_assignment_claim_tool, "arguments" => %{"work_request_id" => "<work_request_id>"}}
    )
  end

  defp claim_failure_recovery(reason) when reason in ["local_mcp_session_required", "local_daemon_trust_required"] do
    compact(reason, "session_binding", "recoverable_with_trusted_local_session", "start_trusted_local_mcp_session")
  end

  defp claim_failure_recovery(reason) when reason in ["claim_lease_paused", "claim_lease_not_active"] do
    compact(reason, "claim_lease", "operator_repair_required", "ask_operator_to_resume_or_recycle_claim_lease",
      protected_boundary: "Paused or inactive claim leases are explicit operator control points."
    )
  end

  defp claim_failure_recovery("work_package_terminal") do
    compact("work_package_terminal", "authority_boundary", "not_recoverable_for_assignment", "ask_architect_for_active_assignment",
      protected_boundary: "Terminal WorkPackages cannot receive new local assignment authority."
    )
  end

  defp claim_failure_recovery(reason) when reason in ["package_delivery_base_mismatch", "work_request_package_link_mismatch"] do
    compact(reason, "authority_boundary", "operator_repair_required", "repair_work_request_package_link",
      protected_boundary: "The ledger's WorkRequest planned-slice link must match the claimed WorkPackage before authority is granted."
    )
  end

  defp claim_failure_recovery(reason)
       when reason in ["recorded_worktree_branch_scope_mismatch", "recorded_worktree_git_metadata_missing", "unsupported_branch_pattern_wildcard"] do
    compact(reason, "authority_boundary", "operator_repair_required", "inspect_or_reprepare_recorded_worktree",
      protected_boundary: "The recorded WorkPackage worktree must still resolve to the package branch scope before local authority is granted."
    )
  end

  defp claim_failure_recovery(reason), do: compact(reason, "claim", "operator_repair_required", "inspect_assignment_scope")

  defp optional_claim_hint_mismatch?(reason)
       when reason in [
              "repo_scope_mismatch",
              "base_branch_scope_mismatch",
              "work_request_scope_mismatch",
              "work_request_repo_scope_mismatch",
              "work_request_package_link_mismatch",
              "branch_scope_mismatch",
              "worktree_scope_mismatch",
              "phase_scope_mismatch",
              "architect_anchor_scope_mismatch"
            ],
       do: true

  defp optional_claim_hint_mismatch?(_reason), do: false

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)
end
