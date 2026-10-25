# Environment Security Alignment

## Contract

- Keep application functionality and security code equivalent; retain separate project URLs, keys, scheduler secrets, accounts and operational data.
- Never promote customers, users/passwords, orders, quotations, manual product activity decisions or REVIEW_REQUIRED tax rules from homologation into production.
- CRM login is rate limited in crm-login. B2B administrative/password operations and interactive Excel synchronization require an active single-device application session.
- Excel dispatch is restricted to the existing private executor, main ref and excel-sync.yml workflow. DATA_SYNC_TARGET must match the Supabase project URL, including scheduler operations. Unknown projects or crossed targets fail closed.
- The scheduler continues using its own environment-specific secret; never place that credential in browser code. Preserve verify_jwt=false for these existing adapters because they authenticate the scheduler/user inside the function; this is not an anonymous mutation grant.
- Edge function metadata/version numbers can differ across projects. Compare deployed source/bundle hashes, not just version numbers or repository files.

## Migration 115

Adds/validates the existing registration-status CHECK constraint in production, while verifying the equivalent constraint in homologation. It does not rewrite statuses or delete rows. Unexpected existing definitions or invalid records stop the transaction. Each application records SECURITY_SCHEMA_ALIGNED in logs with system actor MIGRATION.

The migration is compatible with both current schemas and preserves RLS, policies and RPC grants. SQL regression tests create synthetic registrations inside a rollback-only transaction, accepting the six existing statuses and rejecting an invalid status.

## Validation And Release

1. Export each database using PostgreSQL 17 pg_dump custom format, export roles without passwords and verify file hashes and TOC. Back up deployed Edge sources separately. A dump does not include Storage object bodies and is not a restore drill.
2. Run npm test in both repositories. CI pins Node 24 for the executable TypeScript security tests. Check sessions, permissions, scheduler authentication, exact project/target binding and the dispatch destination without invoking the real workflow.
3. Dry-run migration 115 and SQL regressions 113/114/115 inside a transaction, then roll back. Compare protected data hashes.
4. Apply in homologation, deploy only excel-sync, verify unauthorized and foreign-origin rejection, then repeat in production. Do not trigger a real synchronization merely to validate deployment.
5. Require green security/CodeQL and deployment checks before completing the release. Confirm the public frontend has not changed and all six deployed Edge functions have equivalent bundle hashes.

## Migration 116

Removes TRUNCATE, TRIGGER and REFERENCES privileges from browser roles on current public tables and postgres-owned future table defaults. TRUNCATE bypasses row-level policies, so enabling RLS alone is insufficient protection against an overprivileged database role. SELECT/INSERT/UPDATE/DELETE, function execution, server roles and existing RLS policies are preserved. The release compares effective CRUD grants before/after and verifies that both current and rollback-only future tables have no administrative browser privileges. Every application records SECURITY_CLIENT_PRIVILEGES_RESTRICTED.

## Remaining Operational Differences

- Production's installed catalog worker remains NOLOGIN until the locally installed catalog.db and manifest.json are available and verified. Do not use a test database, copy homologation metadata or silently fall back to an online catalog.
- Homologation tax rules in REVIEW_REQUIRED are not approved production rules. Promotion needs separate fiscal review and explicit selection, not an automatic table copy.
- Historical migration records and previously applied sources remain as recorded. Equivalent current schema is not justification for db reset, blind db push or rewriting applied migrations. Prepare any baseline normalization as a separate verified procedure.
- The temporary rollback-years Edge operation formerly present only in the deployed homologation adapter is archived with the pre-release source backup, not promoted. This release performs no year rollback and leaves corrected product years unchanged.
- This focused hardening is not a penetration test or a guarantee of absolute security. Auth configuration, provider/MFA policies, storage contents, credential rotation and restore drills require their own verified operational review.
