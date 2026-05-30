defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.PolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Policy
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Target

  test "worker can use package-scoped planning and evidence actions for its exact package" do
    actor = Actor.new(:worker, scopes: [Scope.work_package("wp-1")])
    target = Target.package_resource(:task_plan, "wp-1")

    assert %Decision{allowed?: true, reason_code: "allowed", matched_scope: %Scope{type: :work_package, id: "wp-1"}} =
             Policy.decide(actor, :task_plan_update, target)
  end

  test "worker cannot mutate sibling package targets" do
    actor = Actor.new(:worker, scopes: [Scope.work_package("wp-1")])
    target = Target.package_resource(:review_evidence, "wp-2")

    assert %Decision{
             allowed?: false,
             reason: :authorization_denied,
             reason_code: "scope_mismatch",
             legacy_reason: "outside_session_scope"
           } = Policy.decide(actor, :review_evidence_append, target)
  end

  test "worker package scope does not allow dispatch or dangerous actions" do
    actor = Actor.new(:worker, scopes: [Scope.work_package("wp-1")])
    target = Target.planned_slice("wrs-1", "wr-1", work_package_id: "wp-1")

    assert %Decision{allowed?: false, reason_code: "insufficient_role"} =
             Policy.decide(actor, :planned_slice_dispatch, target)

    assert %Decision{allowed?: false, reason_code: "dangerous_action_requires_operator"} =
             Policy.decide(actor, :dangerous_delete, Target.ledger())
  end

  test "architect can read scoped operational state but writes only claimed work request lineage" do
    actor = Actor.new(:architect, scopes: [Scope.work_request("wr-1"), Scope.repo("nextide/symphony-plus-plus", "main")])
    sibling_target = Target.work_request("wr-2", repo: "nextide/symphony-plus-plus", base_branch: "main")
    child_target = Target.planned_slice("wrs-1", "wr-1", work_package_id: "wp-1")

    assert %Decision{allowed?: true} = Policy.decide(actor, :work_request_read, sibling_target)

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :work_request, id: "wr-1"}} =
             Policy.decide(actor, :planned_slice_update, child_target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch", legacy_reason: "outside_session_scope"} =
             Policy.decide(actor, :work_request_update, sibling_target)
  end

  test "architect reads and external comments deny without a matching scope" do
    actor = Actor.new(:architect, scopes: [Scope.work_request("wr-1")])
    sibling_target = Target.work_request("wr-2")

    assert %Decision{allowed?: false, reason_code: "scope_mismatch", legacy_reason: "outside_session_scope"} =
             Policy.decide(actor, :work_request_read, sibling_target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch", legacy_reason: "outside_session_scope"} =
             Policy.decide(actor, :external_comment_add, sibling_target)
  end

  test "repo scope alone does not authorize work request mutation" do
    actor = Actor.new(:architect, scopes: [Scope.repo("nextide/symphony-plus-plus", "main")])
    target = Target.work_request("wr-1", repo: "nextide/symphony-plus-plus", base_branch: "main")

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :repo}} = Policy.decide(actor, :work_request_read, target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_update, target)
  end

  test "repo scope base branch must match when scope is branch pinned" do
    actor = Actor.new(:architect, scopes: [Scope.repo("nextide/symphony-plus-plus", "main")])

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_read, Target.work_request("wr-1", repo: "nextide/symphony-plus-plus"))

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_read, Target.work_request("wr-1", repo: "nextide/symphony-plus-plus", base_branch: "dev"))
  end

  test "explicit planned slice scope authorizes planned slice actions only" do
    actor = Actor.new(:architect, scopes: [Scope.planned_slice("wrs-1")])
    target = Target.planned_slice("wrs-1", "wr-1")

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :planned_slice, id: "wrs-1"}} =
             Policy.decide(actor, :planned_slice_update, target)

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_update, Target.work_request("wr-1"))
  end

  test "architect work package anchor authorizes package-scoped actions only" do
    actor = Actor.new(:architect, scopes: [Scope.work_package("wp-anchor")])

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :work_package, id: "wp-anchor"}} =
             Policy.decide(actor, :task_plan_update, Target.package_resource(:task_plan, "wp-anchor"))

    assert %Decision{allowed?: false, reason_code: "scope_mismatch"} =
             Policy.decide(actor, :work_request_update, Target.work_request("wr-1"))
  end

  test "phase scope authorizes migration-era architect targets with phase identity" do
    actor = Actor.new(:architect, scopes: [Scope.phase("phase-1")])

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :phase, id: "phase-1"}} =
             Policy.decide(actor, :work_request_update, Target.work_request("wr-1", phase_id: "phase-1"))

    assert %Decision{allowed?: true, matched_scope: %Scope{type: :phase, id: "phase-1"}} =
             Policy.decide(actor, :planned_slice_dispatch, Target.planned_slice("wrs-1", "wr-1", phase_id: "phase-1"))
  end

  test "operator ledger scope allows dangerous actions with audit marker" do
    actor = Actor.new(:operator, scopes: [Scope.ledger()])

    assert %Decision{
             allowed?: true,
             matched_scope: %Scope{type: :ledger},
             audit: %{dangerous_action: true}
           } = Policy.decide(actor, :dangerous_rekey, Target.ledger())
  end

  test "policy represents precondition and lifecycle denials with stable reason codes" do
    actor = Actor.new(:architect, scopes: [Scope.work_request("wr-1")])

    assert %Decision{allowed?: false, reason: :precondition_denied, reason_code: "target_not_found"} =
             Policy.decide(actor, :work_request_update, Target.new(:work_request, "wr-missing", resolution: :not_found))

    assert %Decision{allowed?: false, reason: :precondition_denied, reason_code: "runtime_lease_conflict"} =
             Policy.decide(actor, :work_package_update, Target.new(:work_package, "wp-1", resolution: :runtime_lease_conflict))

    assert %Decision{allowed?: false, reason: :lifecycle_denied, reason_code: "invalid_transition"} =
             Policy.decide(actor, :work_package_update, Target.work_package("wp-1"), lifecycle_denial: :invalid_transition)
  end
end
