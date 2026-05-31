defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.Decision do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Actor
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Target

  @enforce_keys [:allowed?, :actor, :action, :target, :reason, :reason_code]
  defstruct [
    :allowed?,
    :actor,
    :action,
    :target,
    :reason,
    :reason_code,
    :matched_scope,
    requirements: [],
    audit: %{},
    redactions: [],
    legacy_reason: nil
  ]

  @type reason :: :allowed | :authorization_denied | :precondition_denied | :lifecycle_denied

  @type t :: %__MODULE__{
          allowed?: boolean(),
          actor: Actor.t(),
          action: atom(),
          target: Target.t(),
          reason: reason(),
          reason_code: String.t(),
          matched_scope: Scope.t() | nil,
          requirements: list(),
          audit: map(),
          redactions: list(),
          legacy_reason: String.t() | nil
        }

  @spec allow(Actor.t(), atom(), Target.t(), keyword()) :: t()
  def allow(%Actor{} = actor, action, %Target{} = target, opts \\ []) when is_atom(action) do
    %__MODULE__{
      allowed?: true,
      actor: actor,
      action: action,
      target: target,
      reason: :allowed,
      reason_code: "allowed",
      matched_scope: Keyword.get(opts, :matched_scope),
      requirements: Keyword.get(opts, :requirements, []),
      audit: Keyword.get(opts, :audit, %{}),
      redactions: Keyword.get(opts, :redactions, []),
      legacy_reason: Keyword.get(opts, :legacy_reason)
    }
  end

  @spec authorization_denied(Actor.t(), atom(), Target.t(), atom() | String.t(), keyword()) :: t()
  def authorization_denied(%Actor{} = actor, action, %Target{} = target, reason_code, opts \\ []) when is_atom(action) do
    deny(:authorization_denied, actor, action, target, reason_code, opts)
  end

  @spec precondition_denied(Actor.t(), atom(), Target.t(), atom() | String.t(), keyword()) :: t()
  def precondition_denied(%Actor{} = actor, action, %Target{} = target, reason_code, opts \\ []) when is_atom(action) do
    deny(:precondition_denied, actor, action, target, reason_code, opts)
  end

  @spec lifecycle_denied(Actor.t(), atom(), Target.t(), atom() | String.t(), keyword()) :: t()
  def lifecycle_denied(%Actor{} = actor, action, %Target{} = target, reason_code, opts \\ []) when is_atom(action) do
    deny(:lifecycle_denied, actor, action, target, reason_code, opts)
  end

  defp deny(reason, actor, action, target, reason_code, opts) do
    %__MODULE__{
      allowed?: false,
      actor: actor,
      action: action,
      target: target,
      reason: reason,
      reason_code: normalize_reason_code(reason_code),
      matched_scope: Keyword.get(opts, :matched_scope),
      requirements: Keyword.get(opts, :requirements, []),
      audit: Keyword.get(opts, :audit, %{}),
      redactions: Keyword.get(opts, :redactions, []),
      legacy_reason: Keyword.get(opts, :legacy_reason)
    }
  end

  defp normalize_reason_code(reason_code) when is_atom(reason_code), do: Atom.to_string(reason_code)
  defp normalize_reason_code(reason_code) when is_binary(reason_code), do: reason_code
end
