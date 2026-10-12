# Local homolog mirror preparation

## Identity and scope

- Branch: `codex/security-single-session-homolog`.
- Worktree: `C:/Users/deivi/OneDrive/Documentos/New project/.worktrees/security-single-session-homolog`.
- Repository: `C:/Users/deivi/OneDrive/Documentos/New project/crm-autopecas-supabase-homolog`.
- Base: local `origin/main` at `e150724eed280008ca701b68b3e8eecc077ab3d0`; no fetch or remote Git mutation.
- Canonical source: parent-owned `security-single-session`, mapping frontend `public/` to homolog root.
- Worker actions are local preparation only: no commit, push, PR, publish, Edge deploy, database mutation or migration application. The parent reports PR 11 head `4d23a17` committed and CI passed; follow-up commits remain parent-owned.

## Preservation and adaptation

The three environment files are byte-identical to the homolog base:
- `js/config.js`: SHA-256 `4d114c2775bb6f99248495019c8cad8314cd84f1aaf2150464b492acb75bc22c`.
- `b2b/js/config.js`: SHA-256 `8c40efee7da25fef6be785aa68e4c3a2fbdb6ce7c36a002d30d3f51a44cc2467`.
- `cadastro-publico/js/config.js`: SHA-256 `7d12c613e6b0ec31cdc8aa419ec0f66bb4a2bf5c6795c2ed330cdb0aab11e494`.

All 52 pre-existing homolog migrations remain byte-identical, including 090.
Only missing history was restored: 001-042 (including four 001 historical files),
091-094 and 098. New 100-104 source files are included without worker application.
Only obsolete local unapplied activation files were removed, not applied SQL.
Preserve applied 100-102; 103 fixes B2B replacement auditing with a nullable
internal `logs.user_id` actor and `dados_novos.auth_user_id`. The parent reports
103 applied in homologacao after B2B regression PASS. Stage 100-103 before
activation 104. Claim upsert accepts the same active ID or a newer Auth creation
timestamp, rejecting a losing write with PT401. Activation 104 retains the
inactive internal/B2B/client membership guard and
advances seed rows only for a strictly newer timestamp. Pause source is
`supabase/rollback/104_single_session_pause.sql`; it disables enforcement without
reopening resolver grants or deleting state. The parent reports homolog review
remains `enforced=false`; this sidecar did not query or modify remote state.

Regression source `supabase/tests/103_b2b_app_session_regression.sql` requires an
existing B2B account without an internal profile and an explicit outer
`BEGIN`/`ROLLBACK`. The worker does not create production fixtures or execute
this regression remotely. Production application and admin-key retrieval remain
blocked pending the required explicit approval, as recorded in the canonical
rollout document.

The IPS fallback PNG is copied byte-for-byte. Frontend text matches canonical
with line endings normalized. No `.env`, `.temp`, private secret, or source
temporary payload was copied. Existing homolog Edge sources, Python integration
code/tests and Excel scheduler workflow are unchanged.

Canonical static contracts are adapted for root-layout paths and retain
homolog's existing OneDrive scheduler contract test rather than asserting that
its scheduler is absent. Missing SQL regression sources 090/093 support static
inspection, not execution. The copied session test supports both layouts.
The dependency-free homolog package includes `test:session` in `npm test`.
The syntax checker scans root frontend/scripts/tests, excluding vendored JS.

## CI and Pages

Security triggers, permissions, matrix, concurrency and secret scan are preserved;
regression now installs Python requirements and runs `npm test`. Dependabot
retains its existing PR limits with weekly Actions/Python updates.

The added Pages workflow uses official full-SHA pins matching the reviewed
canonical gate. `deploy` depends on successful full regression and stages only
the root frontend allowlist (assets, b2b, cadastro-publico, css, js, index.html,
app.html, manifest.webmanifest) into `.pages-artifact`. Tests, migrations, Git
metadata and temporary files are not published. No `public/` layout assumption
or migration/function deployment is added to CI.

There was no custom Pages workflow in the base. The parent must inspect the
actual remote publishing source and environment protections before release:
a local Actions gate does not disable an existing branch/root Pages publisher.
No remote source/environment setting was changed. Node uses the hosted runner
default. Structural assertions do not replace actionlint/YAML parsing or the
first real GitHub run.

## Local verification

Python: `C:/Users/deivi/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe`
(3.12.14 AMD64, openpyxl 3.1.5), first on shell-local PATH with
`PYTHONDONTWRITEBYTECODE=1`.

The prior full `npm test` passed: 36 static, 16 session and 25 existing homolog
Python tests, plus migration continuity 001-103 (106 files) and syntax for 38
JavaScript files. Config/migration preservation, exact file inventory, workflow
structural checks and `git diff --check` passed. The private-secret assignment
scan found no matches. No actionlint/YAML parser was available locally.
No live browser, SQL, Edge or remote deployment tests were performed here.
The parent separately owns homolog SQL/backend validation and release approvals.
For this source-only follow-up, migration continuity now passes 001-104 (107
files); canonical source parity and diff checks are rerun without remote SQL.

## Exact changed files

83 changed/added files relative to the original homolog base, including this document.
Files outside this inventory are not edited.

```text
.github/dependabot.yml
.github/workflows/security.yml
.github/workflows/static.yml
app.html
assets/logo-ips-yokomitsu.png
b2b/index.html
b2b/js/app.js
b2b/js/config.homolog.template.js
css/app.css
css/login.css
docs/SECURITY_SINGLE_SESSION_HOMOLOG_PREPARATION.md
index.html
js/auth.js
js/company_settings.js
js/dashboard.js
js/data_sync.js
js/import_batches.js
js/session_guard.js
js/supabase_store.js
package.json
scripts/check_javascript_syntax.mjs
scripts/check_migration_sequence.mjs
supabase/migrations/001_part1.sql
supabase/migrations/001_part2.sql
supabase/migrations/001_part3.sql
supabase/migrations/001_schema.sql
supabase/migrations/002_cadastros_clientes.sql
supabase/migrations/003_fix_cadastros_clientes_minimal.sql
supabase/migrations/004_cadastros_clientes_uploads.sql
supabase/migrations/005_cadastros_clientes_vendedor.sql
supabase/migrations/006_cadastros_clientes_codigo_sap.sql
supabase/migrations/007_portal_cadastros_settings.sql
supabase/migrations/008_business_partners.sql
supabase/migrations/009_quotations.sql
supabase/migrations/010_update_document_items.sql
supabase/migrations/011_dashboard_status_rpc.sql
supabase/migrations/012_resolve_login_email.sql
supabase/migrations/013_import_products_transactional.sql
supabase/migrations/014_admin_cadastros_permission.sql
supabase/migrations/015_cadastros_clientes_anexos_crm.sql
supabase/migrations/016_fix_create_quotation_number.sql
supabase/migrations/017_check_existing_product_codes.sql
supabase/migrations/018_products_import_staging.sql
supabase/migrations/019_fix_commit_products_import_batch.sql
supabase/migrations/020_import_stability_v2.sql
supabase/migrations/021_import_batches_reporting.sql
supabase/migrations/022_dashboard_comercial_v21.sql
supabase/migrations/023_company_settings.sql
supabase/migrations/024_products_experience.sql
supabase/migrations/025_commercial_flow.sql
supabase/migrations/026_dashboard_commercial.sql
supabase/migrations/027_branch_stock_foundation.sql
supabase/migrations/028_branch_imports.sql
supabase/migrations/029_branch_order_contract.sql
supabase/migrations/030_commercial_dashboard_supervisor_scope.sql
supabase/migrations/031_enable_legacy_snapshot_rls.sql
supabase/migrations/032_billing_region_by_customer_uf.sql
supabase/migrations/033_stock_transfer_requests.sql
supabase/migrations/034_stock_transfer_requests_ops.sql
supabase/migrations/035_order_transfer_visibility.sql
supabase/migrations/036_dashboard_transfer_summary.sql
supabase/migrations/037_fiscal_tax_rules.sql
supabase/migrations/038_order_fiscal_tax_calculation.sql
supabase/migrations/039_document_fiscal_update_flow.sql
supabase/migrations/040_import_product_ncm_and_images.sql
supabase/migrations/041_prospecting_foundation.sql
supabase/migrations/042_prospecting_owner_access.sql
supabase/migrations/091_repair_legacy_stock_timestamp_for_first_sync.sql
supabase/migrations/092_avoid_same_batch_stock_insert_conflicts.sql
supabase/migrations/093_pr_sp_uses_pr_sc_route.sql
supabase/migrations/094_block_sp_ipi_without_excel_match.sql
supabase/migrations/098_confirm_additional_sp_ncm_ipi_rates.sql
supabase/migrations/100_security_and_single_session_foundation.sql
supabase/migrations/101_single_session_cutover_guards.sql
supabase/migrations/102_monotonic_app_session_claim.sql
supabase/migrations/103_b2b_app_session_audit.sql
supabase/migrations/104_activate_single_session.sql
supabase/rollback/104_single_session_pause.sql
supabase/tests/090_sp_ipi_only_from_2026_10_01_regression.sql
supabase/tests/093_pr_sp_uses_pr_sc_route_regression.sql
supabase/tests/103_b2b_app_session_regression.sql
tests/single-session-frontend.test.cjs
tests/static-ui-contracts.test.cjs
```

