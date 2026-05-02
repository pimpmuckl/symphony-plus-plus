# Findings & Decisions

## Requirements

- Implement only SYMPP-P3-001.
- MCP server must start locally and reach a test ledger.
- Auth/session injection path must exist.
- Missing auth must deny protected/package data.
- Do not implement P3-002 worker MCP tools/resources, P3-003 architect tools, dashboard/API, GitHub sync, or unrelated cleanup.

## Research Findings

- P1/P2 dependencies are present on the assigned base: latest commits include SYMPP-P1-004 and SYMPP-P2-003.
- Existing agent protocol code uses stdio JSON-RPC in `SymphonyElixir.Codex.AppServer`.
- MCP transport documentation describes stdio as newline-delimited JSON-RPC with diagnostics on stderr.
- The existing MCP contract defines future worker tools/resources, but P3-002 owns implementing those operations.
- Ledger reachability can be proven without exposing package data by running a simple SQL query against the configured Symphony++ repo.

## Technical Decisions

| Decision | Rationale |
|----------|-----------|
| Use STDIO MCP mode. | Matches repo protocol conventions and local MCP client launch behavior. |
| Add direct handler tests instead of process-only tests. | Keeps validation deterministic while still exercising the MCP request/response shape. |
| Return authorization errors before any package resource data. | Satisfies the no-grant/no-session boundary and leaves resource bodies for P3-002. |

## Issues Encountered

| Issue | Resolution |
|-------|------------|
| T1: unsupported notifications produced JSON-RPC errors. | All notifications without request ids now return no response. |
| T1: public MCP entrypoint had no non-test session injection path. | Added a CLI session-injection path for the stdio task. |
| T1: empty JSON-RPC batches were swallowed. | Empty batches now return `Invalid Request`. |
| T1: test harness config override eagerly required `repo`. | Switched to lazy config default and added coverage. |
| T1 rerun: session files were trusted without live grant validation. | Protected resources re-read the grant from the ledger and reject revoked, expired, unclaimed, or missing grants. |
| T1 rerun: MCP task repo startup used global app env and opaque failures. | Repo startup is task-local with `database`, `pool_size`, and `log` options, and startup/session failures surface through `Mix.raise`. |
| T1 third run: malformed non-string session `grant_id` could crash bootstrap. | Added a string guard before grant lookup so bad session files return normalized startup errors. |
| T1 third run: CRLF stdio lines could parse as invalid. | Strip both `\\n` and `\\r` before JSON decoding. |
| T1 third run: stale sessions could still list protected resources. | `resources/list` now checks live grant state before advertising current assignment. |
| T1 fourth run: malformed work-package resource URIs were auth-checked before URI validation. | Validate protected resource URI shape first and return `Invalid params` for malformed package resource URIs. |
| T1 fourth run: blank stdio lines emitted JSON-RPC parse errors. | Blank lines are ignored while preserving parse errors for malformed nonblank input. |
| T1 fifth run: structured unauthorized reasons could crash JSON-RPC error serialization. | Serialize binary, atom, and structured denial reasons without relying on `String.Chars`; unexpected grant revalidation failures remain unauthorized denials. |
| T1 sixth run: `mix sympp.mcp` auto-ran ledger migrations at startup. | Removed runtime startup migrations; callers must provide an existing ledger/schema when protected session validation is needed. |
| T1 sixth run: reviewer claimed stdio required `Content-Length` framing. | Rejected as invalid for MCP protocol version 2025-03-26, whose stdio transport specifies newline-delimited JSON-RPC messages. |
| T1 seventh run: already-started `Repo` could ignore a requested `--database` override. | Existing repo startup now verifies the running `main` database matches the requested database and fails startup on mismatch. |
| T1 eighth run: backend grant lookup failures were flattened into authorization denials. | Auth revalidation now returns a distinct service-unavailable error; protected reads and resource listing surface `ledger_unavailable` instead of hiding outage state. |
| T1 eighth run: reviewer wanted session-file schema bootstrapping on a fresh DB. | Rejected as conflicting with the explicit no-runtime-migration startup fix; grant-backed session injection requires an existing ledger/grant. |
| T1 ninth run: `--session-file` accepted public `grant_id` as the session credential. | Replaced public grant-id bootstrap with proof of possession against the live grant secret hash. |
| T1 ninth run: method-only malformed payloads could be suppressed as notifications. | Only valid JSON-RPC 2.0 method payloads without an `id` member are treated as notifications; malformed requests receive `Invalid Request`. |
| T1 ninth run: public health could return raw ledger failure details. | Health now returns stable `ledger_unavailable` without adapter details or file paths. |
| T2 first run: no-override startup could reject an already-running repo with a different configured default path. | The database mismatch check now runs only when `--database` was explicitly supplied. |
| T2 first run: non-scalar JSON-RPC ids were accepted and echoed. | Request ids are now limited to string, number, or null; object/list ids return `Invalid Request` with `id: null`. |
| T2 first run: `sympp.health` accepted arbitrary arguments despite advertising an empty schema. | Health calls now require arguments to be absent or `{}` and reject anything else with `Invalid params`. |
| T2 second run: file-backed worker-secret bootstrap violated the security invariant. | Removed session credential files; `mix sympp.mcp` now reads the work-key proof from an operator-named environment variable. |
| T2 second run: `initialize` accepted incompatible or missing MCP protocol versions. | `initialize` now requires protocol version `2025-03-26` and rejects missing/unsupported versions with `Invalid params`. |
| Post-T2 T1 rerun: reviewer claimed omitted health arguments were rejected. | Verified current code already defaults omitted arguments to `{}`; added explicit regression coverage. |
| Later T1 rerun: startup path could reuse a prestarted repo for the wrong resolved ledger and custom paths skipped parent-directory creation. | Startup now resolves and normalizes database paths before starting the repo and validates any existing repo against the resolved database. |
| Local smoke: env-backed session bootstrap against an unmigrated fresh ledger returned an adapter stacktrace. | Session env lookup now normalizes ledger lookup failures into a controlled `Mix.raise` startup error. |
| Latest T1 rerun: non-string JSON-RPC methods were reported as missing method. | Non-string method values now return `Invalid Request` with `invalid_method`. |
| Latest T1 rerun: `file:` SQLite URI paths skipped parent-directory creation. | `file:` URI database paths now prepare parent directories before repo startup. |
| Latest T1 rerun: protected service errors leaked exception class detail and malformed notification ids could echo non-scalar ids. | Protected service errors now expose only `ledger_unavailable`; invalid ids are normalized before other request classification and never echoed. |
| Latest T1 rerun: no-override startup could reject an already-running repo. | Prestarted repo identity validation is again limited to explicit `--database` overrides while retaining normalized override handling. |
| Latest T1 rerun: explicit SQLite URI overrides could pass against an already-started repo with different URI query semantics. | Already-started repos now fail closed for explicit SQLite URI overrides because PRAGMA cannot prove full URI option equality. |
| Latest T1 rerun: JSON-RPC 2.0 missing-method requests could be reported as version errors. | JSON-RPC 2.0 requests with scalar ids and no method now return `missing_method`. |
| Latest T1 rerun: nested work-package resource paths bypassed URI-shape rejection. | P3-001 scaffold now accepts only one resource file segment and rejects nested or double-slash paths. |
| Latest T1 rerun: explicit `--database` could still collide with a default `Repo` process instead of binding to the requested ledger. | `mix sympp.mcp` now starts a database-scoped repo process keyed by the resolved database and binds the task process with `Repo.put_dynamic_repo/1`; added regression coverage that proves scoped binding while the default repo is running. |
| T1 rerun on `a565351`: direct server callers rejected JSON-RPC batch payloads while STDIO accepted them. | Moved batch handling into `Server.handle/2`, simplified STDIO to delegate all decoded payloads to the server, and added direct harness batch coverage. |
| T1 rerun on `a565351`: MCP harness support was loaded globally from `test_helper.exs`. | Scoped `support/mcp_harness.exs` loading to the MCP test file while keeping it ignored as support-only. |
| T1 rerun on `29ce3c9`: nested arrays inside JSON-RPC batches produced nested response arrays. | Batch element handling now accepts only object elements; non-object elements return a flat `Invalid Request`, with nested-array regression coverage. |
| T1 rerun on `ba86eec`: non-object MCP params and notification-only direct batches had inconsistent protocol shapes. | Request params now must be objects before dispatch and notification-only direct batches return no response; added focused regressions for both. |
| T1 rerun on `fe59c92`: unexpected grant lookup results and no-version non-string methods were not classified tightly enough. | Revalidation now accepts only `AccessGrant` structs and surfaces unexpected lookup results as ledger failures; no-version non-string methods now return `invalid_method`. |
| T1 rerun on `2d7da23`: reviewer repeated the wrong-ledger concern for `mix sympp.mcp --database`. | Current code already uses a database-scoped repo process; added direct Mix task coverage proving `--database` reaches the requested ledger while the default repo is running. |
| T1 rerun on `9b315ef`: `mix sympp.mcp` left the caller process dynamic repo binding changed after server exit. | The Mix task now saves and restores the prior dynamic repo binding around setup/session/stdIO execution; direct Mix task coverage asserts the binding is restored. |
| T1 rerun on `b3a0404`: `mix sympp.mcp` still leaked its owned repo process and console logger backend setting after in-process exit. | The task now stops owned repo pools and restores the previous logger console config in cleanup; direct Mix task coverage asserts repo shutdown and logger restoration. |
| T1 rerun on `3e9b420`: startup failure paths and already-started repo reuse needed stronger fail-closed behavior. | Repo setup now returns controlled errors, cleanup wraps setup/session/run, and already-started repo reuse verifies the running ledger identity before accepting it. |
| T1 rerun on `bfe3a7e`: SQLite URI reuse still could not prove full URI semantics and logger backend mutation remained over-broad. | Already-started repo reuse now fails closed for SQLite URI databases, and the Mix task no longer mutates the console logger backend. |
| T1 rerun on `2c17cf3`: exact SQLite URI repo reuse was rejected even though the repo process name already keys full URI identity. | URI reuse now accepts the exact database-scoped process-name collision and has direct coverage for an already-started shared-memory SQLite URI. |
| T2 on `1359aa2`: malformed injected sessions could crash protected requests and repo cleanup could mask the original failure if an owned repo was already stopped. | Malformed sessions now fail closed as unauthorized/no protected listing, and owned-repo cleanup tolerates already-terminated processes. |
| T2 on `f2474ad`: no-override startup still ran explicit database identity checks on already-started repos. | Already-started repo identity checks now run only when the operator supplied `--database`; no-override startup accepts the existing repo. |
| T2 on `03c2917`: protocol-level params parsing rejected JSON-RPC array params. | Request params now accept object or array values at the JSON-RPC layer, with method dispatch owning method-specific rejection. |
| T2 on `0690089`: `tools/call` positional params were misclassified as `Method not found`. | `tools/call` now rejects non-object params as `Invalid params` with `params_must_be_object`, while object params without a tool name still report `missing_tool_name`. |
| T2 on `0690089`: injected sessions could be reconstructed from public grant metadata. | Injected sessions now carry an in-memory proof hash derived from the work-key secret, protected auth compares it to the live grant secret hash, and public session maps do not expose the proof. |
| T2 on `c4d746f`: no-override MCP startup could ignore the caller's current dynamic repo. | `mix sympp.mcp` now reuses an already-running current dynamic/default repo when `--database` is absent, and only starts database-scoped repos for explicit overrides or fresh startup. |
| T2 on `c4d746f`: object-only MCP methods accepted positional array params. | Implemented methods now reject non-object params with `params_must_be_object`, preserving protocol parsing while keeping method contracts fail-closed. |
| GitHub review on `7392eaf`: batched `initialize` requests could run alongside follow-up methods. | JSON-RPC batches containing `initialize` now fail as one invalid request with `initialize_must_be_standalone`, so no later batch element dispatches before initialization completes. |
| GitHub review on `77e175b`: MCP operations could run before initialization and partial initialize payloads were accepted. | The STDIO server now carries initialized state across requests, non-initialize requests fail before handshake, and `initialize` requires protocol version, client info, and capabilities. |
| GitHub review on `6e72c9a`: a second `initialize` could succeed after session startup. | Initialized servers now reject repeat `initialize` requests with `already_initialized` while preserving initialized state. |
| T2 on `438f6b0`: malformed non-2.0 JSON-RPC objects could fall through to unrelated shape errors. | Requests carrying `jsonrpc` values other than `"2.0"` now return `invalid_jsonrpc_version` before missing-method/catch-all handling. |
| T2 on `5f2591e`: `initialize` without an `id` was swallowed as a notification. | `initialize` notifications now fail closed with `initialize_requires_id` instead of leaving the server silently uninitialized. |
| GitHub review on `44b6b26`: `initialize` hard-failed client protocol versions other than the server-supported version. | `initialize` now negotiates by accepting any complete handshake with a binary client protocol version and responding with the server-supported `2025-03-26`. |

## Resources

- `implementation_docs_symphplusplus/work_packages/SYMPP-P3-001_mcp-server-scaffold.md`
- `implementation_docs_symphplusplus/docs/03_PERMISSION_MODEL.md`
- `implementation_docs_symphplusplus/docs/04_MCP_AND_SKILL_CONTRACT.md`
- `elixir/lib/symphony_elixir/codex/app_server.ex`
