defmodule SymphonyElixir.SymphonyPlusPlus.CreateWork do
  @moduledoc false

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Policies.Templates
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.SecretHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  import Ecto.Query, only: [from: 2]

  @default_kind "quick_fix"
  @required_fields ["repo", "base_branch", "title"]
  @scope_guard_gate "scope_guard"

  @type request :: map()
  @type creation :: %{
          work_package: WorkPackage.t(),
          worker_grant: map(),
          virtual_files: %{String.t() => String.t()},
          policy: Templates.template()
        }

  @type error ::
          :empty_request_file
          | :invalid_acceptance_criteria
          | :invalid_allowed_file_globs
          | :invalid_kind
          | :invalid_policy_template
          | :invalid_request
          | :invalid_work_package_id
          | :missing_acceptance_criteria
          | :missing_allowed_file_globs
          | :overbroad_allowed_file_globs
          | :parent_not_supported
          | :policy_template_mismatch
          | :standalone_kind_not_supported
          | :unknown_policy_template
          | {:invalid_json, term()}
          | {:invalid_yaml, term()}
          | {:missing_required_field, String.t()}
          | {:read_failed, Path.t(), File.posix()}
          | Changeset.t()
          | WorkPackageRepository.error()
          | PlanningRepository.error()
          | AccessGrantService.error()
          | Renderer.error()
          | SecretHandoff.error()
          | {:handoff_cleanup_failed, SecretHandoff.error(), term()}
          | {:handoff_cleanup_failed, SecretHandoff.error(), term(), map()}
          | {:handoff_ready_cleanup_failed, term(), term()}

  @spec parse_request(term()) :: {:ok, request()} | {:error, error()}
  def parse_request(raw_request) when is_map(raw_request) do
    attrs = normalize_keys(raw_request)

    with {:ok, attrs} <- require_standalone(attrs),
         {:ok, attrs} <- normalize_required_fields(attrs),
         {:ok, attrs} <- normalize_optional_id(attrs),
         {:ok, policy_templates} <- explicit_policy_templates(attrs),
         {:ok, kind} <- normalize_kind(attrs, policy_templates),
         {:ok, policy_key, policy} <- policy_for(kind, policy_templates),
         {:ok, acceptance_criteria} <- normalize_acceptance_criteria(Map.get(attrs, "acceptance_criteria", [])),
         {:ok, allowed_file_globs} <- normalize_allowed_file_globs(Map.get(attrs, "allowed_file_globs", [])),
         :ok <- require_acceptance_criteria(policy, acceptance_criteria),
         :ok <- require_scope_guard_constraints(policy, allowed_file_globs) do
      {:ok,
       attrs
       |> Map.take([
         "id",
         "repo",
         "base_branch",
         "title",
         "product_description",
         "engineering_scope",
         "branch_pattern",
         "owner_id"
       ])
       |> Map.put("kind", kind)
       |> Map.put("policy_template", policy_key)
       |> Map.put("acceptance_criteria", acceptance_criteria)
       |> Map.put("allowed_file_globs", allowed_file_globs)
       |> Map.put("parent_id", nil)
       |> Map.put("status", "ready_for_worker")
       |> Map.put("policy", policy)}
    end
  end

  def parse_request(_raw_request), do: {:error, :invalid_request}

  @spec parse_file(Path.t()) :: {:ok, request()} | {:error, error()}
  def parse_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> parse_content(content, path)
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  @spec parse_content(String.t(), Path.t() | nil) :: {:ok, request()} | {:error, error()}
  def parse_content(content, path \\ nil) when is_binary(content) do
    if String.trim(content) == "" do
      {:error, :empty_request_file}
    else
      content
      |> decode_content(path)
      |> case do
        {:ok, decoded} -> parse_request(decoded)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec create(module(), map()) :: {:ok, creation()} | {:error, error()}
  def create(repo, request) when is_atom(repo) and is_map(request) do
    with {:ok, request} <- parse_request(request) do
      create_parsed_request(repo, request)
    end
  end

  @spec create_with_worker_secret_handoff(module(), map(), keyword()) ::
          {:ok, {creation(), map()}} | {:error, error()}
  def create_with_worker_secret_handoff(repo, request, handoff_opts)
      when is_atom(repo) and is_map(request) and is_list(handoff_opts) do
    with {:ok, request} <- parse_request(request),
         {:ok, creation} <- create_parsed_request(repo, Map.put(request, "status", "created")),
         {:ok, {creation, worker_secret_handoff}} <- store_worker_secret_handoff(repo, creation, handoff_opts),
         {:ok, ready_creation} <- mark_worker_handoff_ready(repo, creation, worker_secret_handoff, handoff_opts) do
      {:ok, {ready_creation, worker_secret_handoff}}
    end
  end

  @spec response_payload(creation(), keyword()) :: map()
  def response_payload(%{work_package: work_package, worker_grant: worker_grant, virtual_files: virtual_files, policy: policy}, opts \\ []) do
    worker_secret_handoff = Keyword.get(opts, :worker_secret_handoff)

    %{
      work_package: work_package_payload(work_package),
      worker_grant: worker_grant_payload_for_response(worker_grant, worker_secret_handoff),
      policy: policy_payload(policy),
      virtual_files: virtual_files,
      secret_returned_once: is_nil(worker_secret_handoff),
      secret_not_persisted: is_nil(worker_secret_handoff),
      secret_in_stdout: is_nil(worker_secret_handoff),
      ledger_secret_not_persisted: true
    }
    |> maybe_put_worker_secret_handoff(worker_secret_handoff)
  end

  @spec error_message(term()) :: String.t()
  def error_message({:missing_required_field, field}), do: "Missing required create-work field: #{field}"
  def error_message(:empty_request_file), do: "Create-work request file is empty"
  def error_message(:invalid_acceptance_criteria), do: "acceptance_criteria must be a list of nonblank strings"
  def error_message(:invalid_allowed_file_globs), do: "allowed_file_globs must be a list of nonblank strings"
  def error_message(:invalid_kind), do: "kind must be a nonblank string when provided"
  def error_message(:invalid_policy_template), do: "policy_template/review_suite_template must be nonblank strings when provided"
  def error_message(:invalid_request), do: "Create-work request must be a JSON/YAML object"
  def error_message(:invalid_work_package_id), do: "id must be a nonblank string when provided"
  def error_message(:missing_acceptance_criteria), do: "acceptance_criteria is required for this work kind"
  def error_message(:missing_allowed_file_globs), do: "allowed_file_globs is required for scope-guard policy templates"
  def error_message(:overbroad_allowed_file_globs), do: "allowed_file_globs cannot contain repo-wide catch-all globs"
  def error_message(:parent_not_supported), do: "Standalone create-work does not accept parent_id"
  def error_message(:policy_template_mismatch), do: "policy_template/review_suite_template must select the same policy"

  def error_message(:standalone_kind_not_supported),
    do: "Standalone create-work supports quick_fix, hotfix, investigation, adapter, mcp, skill, and hooks work only"

  def error_message(:unknown_policy_template), do: "No policy template exists for requested kind"
  def error_message({:invalid_json, reason}), do: "Invalid JSON create-work request: #{inspect(reason)}"
  def error_message({:invalid_yaml, reason}), do: "Invalid YAML create-work request: #{inspect(reason)}"
  def error_message({:read_failed, path, reason}), do: "Failed to read create-work request #{path}: #{reason}"

  def error_message({:handoff_cleanup_failed, handoff_reason, cleanup_reason}) do
    "Failed to store worker secret handoff: #{SecretHandoff.error_message(handoff_reason)}; cleanup failed: #{inspect(cleanup_reason)}"
  end

  def error_message({:handoff_cleanup_failed, handoff_reason, cleanup_reason, recovery}) do
    "#{error_message({:handoff_cleanup_failed, handoff_reason, cleanup_reason})}; recovery: #{inspect(recovery)}"
  end

  def error_message({:handoff_ready_cleanup_failed, reason, cleanup_reason}) do
    "Failed to mark worker secret handoff ready after storing the secret: #{error_message(reason)}; cleanup failed: #{inspect(cleanup_reason)}"
  end

  def error_message(%Changeset{} = changeset), do: "Invalid create-work request: #{inspect(changeset.errors)}"
  def error_message(reason), do: "Failed to create standalone work: #{inspect(reason)}"

  defp create_parsed_request(repo, request) do
    repo.transaction(fn ->
      case create_transaction(repo, request) do
        {:ok, creation} -> creation
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  defp store_worker_secret_handoff(repo, creation, handoff_opts) do
    case SecretHandoff.store_worker_secret(creation, handoff_opts) do
      {:ok, worker_secret_handoff} ->
        store_worker_secret_handoff_metadata(repo, creation, worker_secret_handoff, handoff_opts)

      {:error, reason} ->
        handle_worker_secret_handoff_error(repo, creation, reason)
    end
  end

  defp store_worker_secret_handoff_metadata(
         repo,
         %{work_package: %WorkPackage{} = work_package, worker_grant: worker_grant} = creation,
         worker_secret_handoff,
         handoff_opts
       ) do
    metadata_grant = worker_secret_metadata_grant(worker_grant)

    case SecretHandoff.store_worker_secret_metadata(
           work_package,
           metadata_grant,
           worker_secret_handoff,
           handoff_opts
         ) do
      :ok ->
        {:ok, {creation, worker_secret_handoff}}

      {:error, reason} ->
        handle_worker_secret_handoff_metadata_error(repo, creation, worker_secret_handoff, handoff_opts, reason)
    end
  end

  defp mark_worker_handoff_ready(
         repo,
         %{work_package: %WorkPackage{} = work_package} = creation,
         worker_secret_handoff,
         handoff_opts
       ) do
    case WorkPackageRepository.update_status(repo, work_package.id, "created", "ready_for_worker") do
      {:ok, ready_work_package} ->
        ready_creation = %{creation | work_package: ready_work_package}

        renderer = Keyword.get(handoff_opts, :renderer, Renderer)

        case renderer.render_all(repo, ready_work_package.id) do
          {:ok, virtual_files} ->
            {:ok, %{ready_creation | virtual_files: virtual_files}}

          {:error, reason} ->
            handle_worker_secret_handoff_ready_error(repo, ready_creation, worker_secret_handoff, handoff_opts, reason)
        end

      {:error, reason} ->
        handle_worker_secret_handoff_ready_error(repo, creation, worker_secret_handoff, handoff_opts, reason)
    end
  end

  defp handle_worker_secret_handoff_error(repo, %{work_package: %WorkPackage{} = work_package} = creation, reason) do
    work_package_id = work_package.id

    case cleanup_created_work_package(repo, work_package_id) do
      :ok ->
        {:error, reason}

      {:error, cleanup_reason} ->
        {:error, {:handoff_cleanup_failed, reason, cleanup_reason, recovery_metadata(creation)}}
    end
  end

  defp handle_worker_secret_handoff_metadata_error(
         repo,
         %{work_package: %WorkPackage{} = work_package} = creation,
         worker_secret_handoff,
         handoff_opts,
         reason
       ) do
    recovery = recovery_metadata(creation, worker_secret_handoff)

    case cleanup_created_work_package(repo, work_package.id) do
      :ok ->
        case SecretHandoff.delete_worker_secret(worker_secret_handoff, handoff_opts) do
          :ok ->
            {:error, reason}

          {:error, handoff_cleanup_reason} ->
            cleanup_reason = %{
              recovery: recovery,
              secret_handoff: {:secret_handoff_cleanup_failed, handoff_cleanup_reason}
            }

            {:error, {:handoff_cleanup_failed, reason, cleanup_reason}}
        end

      {:error, ledger_cleanup_reason} ->
        cleanup_reason = %{
          ledger: ledger_cleanup_reason,
          recovery: recovery,
          secret_handoff: :skipped_to_preserve_recovery_secret
        }

        {:error, {:handoff_cleanup_failed, reason, cleanup_reason}}
    end
  end

  defp handle_worker_secret_handoff_ready_error(
         repo,
         %{work_package: %WorkPackage{} = work_package} = creation,
         worker_secret_handoff,
         handoff_opts,
         reason
       ) do
    work_package_id = work_package.id
    recovery = recovery_metadata(creation, worker_secret_handoff)

    case cleanup_created_work_package(repo, work_package_id) do
      :ok ->
        case delete_worker_secret_handoff_by_grant(creation, worker_secret_handoff, handoff_opts) do
          :ok ->
            {:error, reason}

          {:error, handoff_cleanup_reason} ->
            cleanup_reason = %{
              recovery: recovery,
              secret_handoff: {:secret_handoff_cleanup_failed, handoff_cleanup_reason}
            }

            {:error, {:handoff_ready_cleanup_failed, reason, cleanup_reason}}
        end

      {:error, ledger_cleanup_reason} ->
        cleanup_reason = %{
          ledger: ledger_cleanup_reason,
          recovery: recovery,
          secret_handoff: :skipped_to_preserve_recovery_secret
        }

        {:error, {:handoff_ready_cleanup_failed, reason, cleanup_reason}}
    end
  end

  defp delete_worker_secret_handoff_by_grant(
         %{work_package: %WorkPackage{} = work_package, worker_grant: worker_grant},
         worker_secret_handoff,
         handoff_opts
       ) do
    metadata_grant = worker_secret_metadata_grant(worker_grant)

    case SecretHandoff.delete_worker_secret_by_grant(work_package, metadata_grant, handoff_opts) do
      :ok ->
        :ok

      {:error, metadata_cleanup_reason} ->
        case SecretHandoff.delete_worker_secret(worker_secret_handoff, handoff_opts) do
          :ok ->
            {:error, managed_secret_handoff_cleanup_failed(metadata_cleanup_reason, :deleted)}

          {:error, secret_cleanup_reason} ->
            {:error, managed_secret_handoff_cleanup_failed(metadata_cleanup_reason, secret_cleanup_reason)}
        end
    end
  end

  defp managed_secret_handoff_cleanup_failed(metadata_cleanup_reason, fallback_reason) do
    {:managed_secret_handoff_cleanup_failed, metadata_cleanup_reason, fallback_secret_handoff: fallback_reason}
  end

  @doc false
  @spec cleanup_created_work_package(module(), String.t()) :: :ok | {:error, term()}
  def cleanup_created_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    repo.transaction(fn ->
      delete_by_work_package_id(repo, AgentRun, work_package_id)
      delete_by_work_package_id(repo, Artifact, work_package_id)
      delete_by_work_package_id(repo, ProgressEvent, work_package_id)
      delete_by_work_package_id(repo, Finding, work_package_id)
      delete_by_work_package_id(repo, PlanNode, work_package_id)
      delete_by_work_package_id(repo, AccessGrant, work_package_id)

      repo.delete_all(from(work_package in WorkPackage, where: work_package.id == ^work_package_id))
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Exqlite.Error -> {:error, {:storage_failed, Exception.message(error)}}
  end

  defp delete_by_work_package_id(repo, schema, work_package_id) do
    repo.delete_all(from(row in schema, where: row.work_package_id == ^work_package_id))
  end

  defp recovery_metadata(%{work_package: %WorkPackage{} = work_package, worker_grant: worker_grant}, worker_secret_handoff \\ nil) do
    %{
      work_package_id: work_package.id,
      worker_grant_id: Map.get(worker_grant, :id) || Map.get(worker_grant, "id"),
      worker_grant_display_key: Map.get(worker_grant, :display_key) || Map.get(worker_grant, "display_key")
    }
    |> maybe_put_recovery_handoff(worker_secret_handoff)
  end

  defp maybe_put_recovery_handoff(recovery, nil), do: recovery
  defp maybe_put_recovery_handoff(recovery, worker_secret_handoff), do: Map.put(recovery, :worker_secret_handoff, worker_secret_handoff)

  defp worker_secret_metadata_grant(worker_grant) when is_map(worker_grant) do
    worker_grant
    |> Map.delete(:secret)
    |> Map.delete("secret")
  end

  defp create_transaction(repo, request) do
    policy = Map.fetch!(request, "policy")
    work_package_attrs = Map.drop(request, ["policy"])

    with {:ok, work_package} <- WorkPackageRepository.create(repo, work_package_attrs),
         {:ok, _scope_node} <- append_scope_plan_node(repo, work_package),
         {:ok, _review_node} <- append_review_plan_node(repo, work_package, policy),
         {:ok, minted} <- mint_worker_grant(repo, work_package.id, policy),
         {:ok, virtual_files} <- Renderer.render_all(repo, work_package.id) do
      {:ok,
       %{
         work_package: work_package,
         worker_grant: worker_grant_payload(minted),
         virtual_files: virtual_files,
         policy: policy
       }}
    end
  end

  defp append_scope_plan_node(repo, %WorkPackage{} = work_package) do
    PlanningRepository.append_plan_node(repo, %{
      work_package_id: work_package.id,
      title: initial_scope_title(work_package),
      body: nonblank_or(work_package.engineering_scope, "Use the engineering scope from context.md."),
      status: "pending"
    })
  end

  defp initial_scope_title(%WorkPackage{kind: "investigation"}), do: "Investigate requested scope"
  defp initial_scope_title(%WorkPackage{}), do: "Implement requested scope"

  defp append_review_plan_node(repo, %WorkPackage{} = work_package, policy) do
    PlanningRepository.append_plan_node(repo, %{
      work_package_id: work_package.id,
      title: "Complete acceptance and review gates",
      body: review_plan_body(policy),
      status: "pending"
    })
  end

  defp review_plan_body(policy) do
    [
      acceptance_plan_line(policy),
      "Required gates:",
      gates_line(policy.required_gates),
      "",
      "Required review lanes:",
      gates_line(policy.review_suite.required)
    ]
    |> Enum.join("\n")
  end

  defp acceptance_plan_line(%{required_gates: required_gates}) do
    if "package_acceptance" in required_gates do
      "Acceptance criteria:\n- Satisfy the package acceptance criteria in acceptance.md.\n"
    else
      ""
    end
  end

  defp gates_line([]), do: "- None."
  defp gates_line(gates), do: Enum.map_join(gates, "\n", &("- " <> &1))

  defp nonblank_or(value, fallback) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: fallback, else: value
  end

  defp nonblank_or(_value, fallback), do: fallback

  defp mint_worker_grant(repo, work_package_id, _policy) do
    AccessGrantService.mint_worker_grant(repo, work_package_id)
  end

  defp worker_grant_payload(%{grant: grant, work_key: work_key}) do
    %{
      id: grant.id,
      display_key: grant.display_key,
      role: grant.grant_role,
      capabilities: grant.capabilities,
      expires_at: timestamp(grant.expires_at),
      secret: work_key.secret
    }
  end

  defp timestamp(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp timestamp(nil), do: nil

  defp worker_grant_payload_for_response(worker_grant, nil), do: worker_grant

  defp worker_grant_payload_for_response(worker_grant, worker_secret_handoff) do
    SecretHandoff.redacted_worker_grant(worker_grant, worker_secret_handoff)
  end

  defp maybe_put_worker_secret_handoff(payload, nil), do: payload
  defp maybe_put_worker_secret_handoff(payload, handoff), do: Map.put(payload, :worker_secret_handoff, handoff)

  defp work_package_payload(%WorkPackage{} = work_package) do
    %{
      id: work_package.id,
      kind: work_package.kind,
      title: work_package.title,
      repo: work_package.repo,
      base_branch: work_package.base_branch,
      branch_pattern: work_package.branch_pattern,
      product_description: work_package.product_description,
      engineering_scope: work_package.engineering_scope,
      allowed_file_globs: work_package.allowed_file_globs,
      policy_template: work_package.policy_template,
      acceptance_criteria: work_package.acceptance_criteria,
      status: work_package.status,
      parent_id: work_package.parent_id,
      owner_id: work_package.owner_id
    }
  end

  defp policy_payload(policy) do
    %{
      template: policy.template,
      constraints: policy.constraints,
      required_gates: policy.required_gates,
      readiness_requirements: policy.readiness_requirements,
      review_suite: policy.review_suite
    }
  end

  defp decode_content(content, path) do
    if json_path?(path) do
      decode_json(content)
    else
      decode_yaml(content)
    end
  end

  defp decode_json(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp decode_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_yaml, reason}}
    end
  end

  defp json_path?(path) when is_binary(path), do: path |> Path.extname() |> String.downcase() == ".json"
  defp json_path?(_path), do: false

  defp normalize_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp require_standalone(attrs) do
    if present?(Map.get(attrs, "parent_id")) do
      {:error, :parent_not_supported}
    else
      {:ok, attrs}
    end
  end

  defp normalize_required_fields(attrs) do
    Enum.reduce_while(@required_fields, {:ok, attrs}, fn field, {:ok, current_attrs} ->
      case normalize_nonblank_string(Map.get(current_attrs, field)) do
        {:ok, value} -> {:cont, {:ok, Map.put(current_attrs, field, value)}}
        {:error, :blank} -> {:halt, {:error, {:missing_required_field, field}}}
      end
    end)
  end

  defp normalize_optional_id(attrs) do
    case Map.fetch(attrs, "id") do
      :error ->
        {:ok, attrs}

      {:ok, id} ->
        case normalize_nonblank_string(id) do
          {:ok, id} -> {:ok, Map.put(attrs, "id", id)}
          {:error, :blank} -> {:error, :invalid_work_package_id}
        end
    end
  end

  defp normalize_kind(attrs, policy_templates) do
    case Map.fetch(attrs, "kind") do
      :error ->
        default_kind(policy_templates)

      {:ok, kind} ->
        case normalize_nonblank_string(kind) do
          {:ok, "phase_child"} -> {:error, :standalone_kind_not_supported}
          {:ok, kind} -> ensure_standalone_kind(kind)
          {:error, :blank} -> {:error, :invalid_kind}
        end
    end
  end

  defp ensure_standalone_kind(kind) do
    if StateMachine.supported_kind?(kind) do
      {:ok, kind}
    else
      {:error, :standalone_kind_not_supported}
    end
  end

  defp default_kind([]), do: {:ok, @default_kind}

  defp default_kind(policy_templates) do
    with {:ok, policy_key, policy} <- default_policy_key(policy_templates),
         {:ok, kind} <- Templates.work_package_kind(policy_key),
         :ok <- reject_phase_child_policy(policy) do
      {:ok, kind}
    end
  end

  defp default_policy_key(policy_templates) do
    case exact_policy_key(nil, policy_templates) do
      {:ok, policy_key} ->
        with {:ok, policy} <- Templates.expand(policy_key),
             true <- Enum.all?(policy_templates, &Templates.matches?(policy_key, &1)) do
          {:ok, policy_key, policy}
        else
          false -> {:error, :policy_template_mismatch}
          {:error, reason} -> {:error, reason}
        end

      :none ->
        Templates.resolve_key(policy_templates)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp policy_for(kind, []) do
    with {:ok, policy} <- Templates.expand(kind),
         :ok <- reject_phase_child_policy(policy) do
      {:ok, kind, policy}
    else
      {:error, :unknown_policy_template} -> {:error, :unknown_policy_template}
      {:error, reason} -> {:error, reason}
    end
  end

  defp policy_for(kind, policy_templates) do
    with {:ok, policy_key, policy} <- policy_key_for(kind, policy_templates),
         :ok <- reject_phase_child_policy(policy) do
      {:ok, policy_key, policy}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp policy_key_for(kind, policy_templates) do
    case exact_policy_key(kind, policy_templates) do
      {:ok, policy_key} ->
        with {:ok, policy} <- Templates.expand(policy_key),
             true <- Templates.compatible_kind?(kind, policy_key),
             :ok <- reject_exact_policy_alias_mismatch(kind, policy_key, policy, policy_templates),
             true <- Enum.all?(policy_templates, &Templates.matches?(policy_key, &1)) do
          {:ok, policy_key, policy}
        else
          false -> {:error, :policy_template_mismatch}
          {:error, reason} -> {:error, reason}
        end

      :none ->
        with {:ok, policy_key, policy} <- Templates.resolve_key([kind | policy_templates]),
             true <- Templates.compatible_kind?(kind, policy_key) do
          {:ok, policy_key, policy}
        else
          false -> {:error, :policy_template_mismatch}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exact_policy_key(_kind, policy_templates) do
    exact_keys = policy_templates |> Enum.filter(&Templates.key?/1) |> Enum.uniq()

    case exact_keys do
      [] -> :none
      [policy_key] -> {:ok, policy_key}
      _multiple -> exact_policy_key_with_kind_aliases(exact_keys)
    end
  end

  defp exact_policy_key_with_kind_aliases(exact_keys) do
    candidates =
      Enum.filter(exact_keys, fn policy_key ->
        case Templates.work_package_kind(policy_key) do
          {:ok, kind} -> Enum.all?(exact_keys -- [policy_key], &(&1 == kind))
          {:error, _reason} -> false
        end
      end)

    case candidates do
      [policy_key] -> {:ok, policy_key}
      _candidates -> {:error, :policy_template_mismatch}
    end
  end

  defp reject_exact_policy_alias_mismatch(kind, policy_key, policy, policy_templates) do
    template_alias = Map.get(policy, :template)

    if policy_key != kind and template_alias != policy_key and template_alias in policy_templates and
         not explicit_policy_with_alias?(policy_templates, policy_key, template_alias) do
      {:error, :policy_template_mismatch}
    else
      :ok
    end
  end

  defp explicit_policy_with_alias?(policy_templates, policy_key, template_alias) do
    with {:ok, %{template: ^template_alias}} <- Templates.expand(policy_key),
         policy_index when is_integer(policy_index) <- Enum.find_index(policy_templates, &(&1 == policy_key)),
         alias_index when is_integer(alias_index) <- Enum.find_index(policy_templates, &(&1 == template_alias)) do
      policy_index < alias_index
    else
      _reason -> false
    end
  end

  defp reject_phase_child_policy(%{template: "phase_child"}), do: {:error, :standalone_kind_not_supported}
  defp reject_phase_child_policy(_policy), do: :ok

  defp explicit_policy_templates(attrs) do
    ["policy_template", "review_suite_template"]
    |> Enum.reduce_while({:ok, []}, fn field, {:ok, templates} ->
      case normalize_policy_template(Map.get(attrs, field)) do
        {:ok, nil} -> {:cont, {:ok, templates}}
        {:ok, template} -> {:cont, {:ok, [template | templates]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, templates} -> {:ok, Enum.reverse(templates)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_policy_template(value) when is_binary(value) do
    case normalize_nonblank_string(value) do
      {:ok, value} -> {:ok, value}
      {:error, :blank} -> {:error, :invalid_policy_template}
    end
  end

  defp normalize_policy_template(nil), do: {:ok, nil}
  defp normalize_policy_template(_value), do: {:error, :invalid_policy_template}

  defp require_acceptance_criteria(%{required_gates: required_gates}, []) do
    if "package_acceptance" in required_gates do
      {:error, :missing_acceptance_criteria}
    else
      :ok
    end
  end

  defp require_acceptance_criteria(_policy, _acceptance_criteria), do: :ok

  defp require_scope_guard_constraints(%{required_gates: required_gates}, allowed_file_globs) do
    if @scope_guard_gate in required_gates do
      cond do
        allowed_file_globs == [] -> {:error, :missing_allowed_file_globs}
        Enum.any?(allowed_file_globs, &ScopeGuard.overbroad_glob?/1) -> {:error, :overbroad_allowed_file_globs}
        true -> :ok
      end
    else
      :ok
    end
  end

  defp normalize_acceptance_criteria(criteria) when is_list(criteria) do
    criteria = Enum.map(criteria, &normalize_acceptance_criterion/1)

    if Enum.all?(criteria, &valid_acceptance_criterion?/1) do
      {:ok, criteria}
    else
      {:error, :invalid_acceptance_criteria}
    end
  end

  defp normalize_acceptance_criteria(nil), do: {:ok, []}
  defp normalize_acceptance_criteria(_criteria), do: {:error, :invalid_acceptance_criteria}

  defp normalize_allowed_file_globs(globs), do: normalize_string_list(globs, :invalid_allowed_file_globs)

  defp normalize_acceptance_criterion(value) when is_binary(value), do: String.trim(value)
  defp normalize_acceptance_criterion(_value), do: :invalid

  defp valid_acceptance_criterion?(value) when is_binary(value), do: value != ""
  defp valid_acceptance_criterion?(_value), do: false

  defp normalize_string_list(nil, _error), do: {:ok, []}

  defp normalize_string_list(values, error) when is_list(values) do
    values = Enum.map(values, &normalize_acceptance_criterion/1)

    if Enum.all?(values, &valid_acceptance_criterion?/1) do
      {:ok, values}
    else
      {:error, error}
    end
  end

  defp normalize_string_list(_values, error), do: {:error, error}

  defp normalize_nonblank_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, :blank}, else: {:ok, value}
  end

  defp normalize_nonblank_string(_value), do: {:error, :blank}

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true
end
