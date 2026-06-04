# V3 Product Tree Cutover Runbook

## Goal

Validate the v3 cockpit against a migrated copy of the current Symphony++
ledger before touching the live local database.

## Preview Procedure

1. Create a migrated copied-ledger preview from `elixir/`:

```powershell
cd elixir
mix run scripts/sympp_v3_preview.exs
```

The helper snapshots the default local ledger with SQLite `VACUUM INTO`, runs
the current Symphony++ migrations against the copy, and prints the preview
database path. To seed a representative product tree for one larger
WorkRequest, pass its id:

```powershell
cd elixir
mix run scripts/sympp_v3_preview.exs -- --seed_work_request <work-request-id>
```

Use `--source <sqlite>` or `--target <sqlite>` only for explicit alternate
ledger experiments.

2. Start the cockpit API bridge against the copied DB:

```powershell
cd elixir
mix sympp.cockpit --database ..\tmp\v3-preview\symphony_plus_plus_v3_preview.sqlite3 --port 20000 --dashboard-origin http://127.0.0.1:20001
```

Ports `20000/20001` are preview-only overrides; the standard local operator
defaults remain `19998/19999`.

3. Start the Vite cockpit against that API:

```powershell
cd elixir\assets
$env:SYMPP_API_ORIGIN = "http://127.0.0.1:20000"
$env:SYMPP_DASHBOARD_PORT = "20001"
npm run dev
```

4. Open:

```text
http://127.0.0.1:20001/sympp/board
```

## Acceptance Checks

- The live database path is not the same as the preview database path.
- The preview database has all four `sympp_product_tree_*` tables.
- The cockpit renders one collapsed row per WorkRequest.
- Expanding a WorkRequest renders product plan nodes when present.
- A `--seed_work_request` preview shows nested product plan nodes linked to
  planned slices for that request.
- WorkRequests without product plan nodes render direct slice rows.
- Package detail remains reachable from linked slice rows.
- Existing WorkRequest detail drawers still open.
- No work keys, raw grants, private handoff payloads, tokens, or secret-bearing
  commands appear in the payload or UI.

## Live Cutover

After preview acceptance:

1. Stop old local cockpit servers.
2. Back up the live ledger.
3. Run the same migration against the live ledger through `mix sympp.cockpit`.
4. Start Vite/API with the standard operator ports.
5. Seed product plan nodes only for large WorkRequests that benefit from the
   product tree.
6. Leave small hotfix WorkRequests as direct-slice rows.

## Rollback

If the preview fails, discard `tmp\v3-preview/symphony_plus_plus_v3_preview.sqlite3`
and fix the branch. No live database action is required.

If live cutover fails after migration, stop the cockpit, restore the backed-up
SQLite file, and reopen the previous branch.
