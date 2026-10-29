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

## Ownership

Managed by the data engineering role. Before adding tables or writing forms, read
`docs/conventions.md`, `docs/REQUIRED_FIELDS.md` and `docs/schema.dbml`.
