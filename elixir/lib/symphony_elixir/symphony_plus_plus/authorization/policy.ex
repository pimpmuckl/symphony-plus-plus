defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.Policy do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Target

  @read_actions [
    :work_request_read,
    :work_package_read,
    :task_plan_read,
    :comment_list,
    :guidance_request_read,
    :delivery_board_read,
    :dashboard_read
  ]

  @worker_package_actions [
    :work_package_read,
    :work_package_update,
    :task_plan_read,
    :task_plan_update,
    :progress_append,
    :finding_append,
    :validation_note_append,
    :review_evidence_append,
    :blocker_report,
    :blocker_resolve,
    :blocker_unblock,
    :comment_add,
    :comment_list,
    :comment_resolve,
    :guidance_request_create,
    :guidance_request_read
  ]

  @planned_slice_actions [
    :planned_slice_update,
    :planned_slice_approve,
    :planned_slice_skip,
    :planned_slice_dispatch
  ]

  @architect_work_request_actions [
    :work_request_read,
    :work_request_update,
    :question_create,
    :question_answer,
    :question_close,
    :decision_record,
    :planned_slice_create,
    :planned_slice_update,
    :planned_slice_approve,
    :planned_slice_skip,
    :planned_slice_dispatch,
    :work_package_read,
    :work_package_update,
    :work_package_repair_state,
    :task_plan_read,
    :task_plan_update,
    :progress_append,
    :finding_append,
    :validation_note_append,
    :review_evidence_append,
    :blocker_report,
    :blocker_resolve,
    :blocker_unblock,
    :comment_add,
    :comment_list,
    :comment_resolve,
    :external_comment_add,
    :guidance_request_create,
    :guidance_request_read,
    :guidance_request_answer,
    :guidance_request_escalate,
    :delivery_board_read,
    :delivery_reconcile_dry_run,
    :delivery_reconcile_apply,
    :delivery_closeout_record,
    :scope_expansion_request
  ]

  @operator_actions @architect_work_request_actions ++
                      [
                        :scope_expansion_approve,
                        :dashboard_read,
                        :dangerous_override,
                        :dangerous_rekey,
                        :dangerous_delete,
                        :dangerous_raw_repair
                      ]

  @known_actions Enum.uniq(@operator_actions ++ @worker_package_actions)
  @architect_actions Enum.uniq(@architect_work_request_actions ++ @read_actions)
  @dangerous_actions [:dangerous_override, :dangerous_rekey, :dangerous_delete, :dangerous_raw_repair]

  @spec actions() :: [atom()]
  def actions, do: @known_actions

  @spec decide(Actor.t(), atom(), Target.t(), keyword()) :: Decision.t()
  def decide(%Actor{} = actor, action, %Target{} = target, opts \\ []) when is_atom(action) do
    cond do
      lifecycle_denial = Keyword.get(opts, :lifecycle_denial) ->
        Decision.lifecycle_denied(actor, action, target, lifecycle_denial)

      not Target.resolved?(target) ->
        Decision.precondition_denied(actor, action, target, target_resolution_reason(target))

      action not in @known_actions ->
        Decision.authorization_denied(actor, action, target, :unknown_action)

      true ->
        decide_resolved(actor, action, target)
    end
  end

  defp decide_resolved(%Actor{role: :operator} = actor, action, %Target{} = target) do
    allow_with_scope(actor, action, target, [:ledger],
      audit: operator_audit(action),
      denied_reason: :operator_ledger_scope_required
    )
  end

  defp decide_resolved(%Actor{role: :architect} = actor, action, %Target{} = target) when action in @architect_actions do
    allow_with_scope(actor, action, target, architect_scope_types(action), legacy_reason: "outside_session_scope")
  end

  defp decide_resolved(%Actor{role: :worker} = actor, action, %Target{} = target) when action in @worker_package_actions do
    allow_with_scope(actor, action, target, [:work_package], legacy_reason: "outside_session_scope")
  end

  defp decide_resolved(%Actor{} = actor, action, %Target{} = target) when action in @dangerous_actions do
    Decision.authorization_denied(actor, action, target, :dangerous_action_requires_operator)
  end

  defp decide_resolved(%Actor{} = actor, action, %Target{} = target) do
    Decision.authorization_denied(actor, action, target, :insufficient_role)
  end

  defp architect_scope_types(action) when action in @read_actions, do: [:work_request, :work_package, :repo, :phase]
  defp architect_scope_types(:external_comment_add), do: [:work_request, :repo, :phase]
  defp architect_scope_types(action) when action in @planned_slice_actions, do: [:work_request, :planned_slice, :phase]
  defp architect_scope_types(action) when action in @worker_package_actions, do: [:work_request, :work_package, :phase]
  defp architect_scope_types(_action), do: [:work_request, :phase]

  defp allow_with_scope(%Actor{} = actor, action, %Target{} = target, allowed_scope_types, opts) do
    audit = Keyword.get(opts, :audit, %{})
    denied_reason = Keyword.get(opts, :denied_reason, :scope_mismatch)
    legacy_reason = Keyword.get(opts, :legacy_reason)

    case matching_scope(actor, target, allowed_scope_types) do
      %Scope{} = scope ->
        Decision.allow(actor, action, target, matched_scope: scope, audit: audit)

      nil ->
        Decision.authorization_denied(actor, action, target, denied_reason, legacy_reason: legacy_reason)
    end
  end

  defp matching_scope(%Actor{scopes: scopes}, %Target{} = target, allowed_scope_types) do
    Enum.find(scopes, fn
      %Scope{type: type} = scope -> type in allowed_scope_types and scope_matches_target?(scope, target)
      %Scope{} -> false
    end)
  end

  defp scope_matches_target?(%Scope{type: :ledger}, %Target{}), do: true

  defp scope_matches_target?(%Scope{type: :work_request, id: scope_id}, %Target{} = target) when is_binary(scope_id) do
    target.work_request_id == scope_id or (target.type == :work_request and target.id == scope_id)
  end

  defp scope_matches_target?(%Scope{type: :planned_slice, id: scope_id}, %Target{} = target) when is_binary(scope_id) do
    target.planned_slice_id == scope_id or (target.type == :planned_slice and target.id == scope_id)
  end

  defp scope_matches_target?(%Scope{type: :work_package, id: scope_id}, %Target{} = target) when is_binary(scope_id) do
    target.work_package_id == scope_id or (target.type == :work_package and target.id == scope_id)
  end

  defp scope_matches_target?(%Scope{type: :repo, repo: repo, base_branch: base_branch}, %Target{} = target) when is_binary(repo) do
    target.repo == repo and (is_nil(base_branch) or target.base_branch == base_branch)
  end

  defp scope_matches_target?(%Scope{type: :phase, id: scope_id}, %Target{} = target) when is_binary(scope_id) do
    target.phase_id == scope_id
  end

  defp scope_matches_target?(%Scope{}, %Target{}), do: false

  defp target_resolution_reason(%Target{resolution: :not_found}), do: :target_not_found
  defp target_resolution_reason(%Target{resolution: :ambiguous}), do: :target_ambiguous
  defp target_resolution_reason(%Target{resolution: :runtime_lease_conflict}), do: :runtime_lease_conflict

  defp operator_audit(action) when action in @dangerous_actions, do: %{dangerous_action: true}
  defp operator_audit(_action), do: %{}
end
