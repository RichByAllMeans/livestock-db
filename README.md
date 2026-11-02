# livestock-db

PostgreSQL schema and versioned migrations for the Livestock Management System.
This repo is the **single source of truth** for the database. Application code
(frontend/backend) must never own schema changes — migrations land here first.

## Design principles

- **Multi-tenant by default.** Every business row carries `tenant_id`; one ranch = one tenant.
- **Append-only history.** Health records and audit logs are immutable (no `UPDATE`).
  "Current state" is derived with views, so history can always be back-traced.
- **Soft references, hard constraints.** Foreign keys enforce integrity; historical
  rows are never deleted, only status-flagged.

## Layout

```
migrations/   versioned SQL migrations (dbmate format: -- migrate:up / -- migrate:down)
docs/         ERD, DBML schema, required fields, naming/constraint conventions
```

## Migrations

Migrations use [dbmate](https://github.com/amacneil/dbmate) naming and markers, so any
runner can be swapped in. Each file has a `-- migrate:up` and `-- migrate:down` block.

```bash
# against a local docker Postgres (see livestock-infra)
dbmate up
dbmate rollback
```

## Applying to a fresh DB

See `livestock-infra` for the Docker Postgres stack, then run the migrations in order.

## Application integration contract

The backend must uphold these rules; the database alone does not enforce all of
them. See `docs/REQUIRED_FIELDS.md` and `docs/conventions.md` for details.

- **Connect as a non-owner role.** RLS is enabled but not `FORCE`d on tenant
  tables, so table owners and superusers bypass it. The application must use a
  dedicated non-owner, non-superuser login, otherwise tenant isolation is
  silently disabled.
- **Set tenant context per request, inside the transaction.** Derive the tenant
  from the authenticated session, never from client input, and scope it to the
  request so pooled connections cannot leak state:

  ```sql
  BEGIN;
  SELECT set_config('app.tenant_id', $1, true);  -- true = transaction-local
  -- queries / mutations for this request
  COMMIT;
  ```

  `true` (transaction-local) is required with connection pooling. A session-level
  `SET app.tenant_id` persists on a reused connection and can leak another
  tenant's rows if a later request fails to set it.
- **Treat missing context as an error.** With no `app.tenant_id`, policies return
  zero rows and reject inserts; that looks like empty data, so fail the request
  explicitly when no tenant was established.
- **Validate required fields and legacy flags.** New records must satisfy
  `docs/REQUIRED_FIELDS.md`; only imports may set `is_legacy = true` with the
  documented defaults.
- **Respect append-only tables.** Never `UPDATE`/`DELETE` them; write corrections
  as new rows (e.g. `health_records.corrects_id`) and read current state from the
  views.
- **Enforce RBAC.** Roles exist in the schema, but route/action permission checks
  and `audit_log` writes are application responsibilities.

## Ownership

Managed by the data engineering role. Before adding tables or writing forms, read
`docs/conventions.md`, `docs/REQUIRED_FIELDS.md` and `docs/schema.dbml`.
