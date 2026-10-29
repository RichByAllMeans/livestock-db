# Database conventions

## Naming

- Tables: `snake_case`, **plural** (`animals`, `health_records`).
- Columns: `snake_case`, singular (`tag_number`, `date_of_birth`).
- Primary key: always `id uuid` (`gen_random_uuid()`).
- Foreign keys: `<referenced_singular>_id` (`animal_id`, `tenant_id`).
- Timestamps: `created_at`, `updated_at`, `occurred_at`, `recorded_at` — all `timestamptz`.
- Booleans: `is_*` / `has_*` (`is_active`, `is_resolved`, `is_legacy`).
- Enums: `snake_case` type names; lowercase values (`animal_origin = purchased|local|newborn`).

## Required columns

Every business table has:

| column       | type          | notes                                    |
|--------------|---------------|------------------------------------------|
| `id`         | `uuid`        | PK, `gen_random_uuid()`                  |
| `tenant_id`  | `uuid`        | FK `tenants(id)`, indexed; NULL only for system reference rows |
| `created_at` | `timestamptz` | `default now()`                          |
| `updated_at` | `timestamptz` | only on mutable tables (trigger-managed) |

Parent tables used by composite tenant FKs also carry a unique `(tenant_id, id)`
constraint (e.g. `animals_tenant_id_id_key`, `groups_tenant_id_id_key`).

## Enums

- Enums are additive: `ALTER TYPE ... ADD VALUE` can add values but PostgreSQL
  cannot remove them in a down migration.
- Down migrations must not "remove" enum values; leave them in place.
- New enum values must not be consumed in the same transaction that adds them.

## Append-only tables

`health_records`, `stock_movements`, `transactions`, `payments`,
`stock_transactions`, `audit_log`, `animal_history_log` are **immutable**.
- No `updated_at`, no `UPDATE`/`DELETE` from application code.
- Corrections are new rows referencing the original (`health_records.corrects_id`,
  `animal_history_log` for weight/location/ownership/status changes).
- Read "current state" from the views in the migrations that define them
  (`v_herd_summary`, `v_invoice_balance`, `v_animal_current_weight`, etc.).

## Tenant isolation

- Every tenant table has `tenant_id` and an index starting with `tenant_id`.
- Composite FKs (`(tenant_id, animal_id) -> animals(tenant_id, id)`) prevent
  cross-tenant references where added.
- Row-level security is **enabled** on tenant tables but not `FORCE`d; owners
  (migrations/seed) bypass it. Application connections must run:

```sql
SET app.tenant_id = '<tenant-uuid>';
```

- Policies use `current_tenant_id()` from migration `00015`; system rows with
  `tenant_id IS NULL` are readable by all tenants.

## Legacy imports

- New records must satisfy `docs/REQUIRED_FIELDS.md`.
- Imported/old rows may set `is_legacy = true` with documented defaults
  (`origin = 'purchased'`, no invented birth date).
- Do not silently guess required data for new records.

## Money & quantities

- Money: `numeric(14,2)`, always paired with a `currency` (`char(3)`, default `KES`).
- Feed quantities: `numeric(14,3)` for partial units (kg, bales, litres).
- General inventory quantities: `numeric(14,2)`.

## Indexing

- Always index `tenant_id` and every FK.
- Unique constraints are scoped per tenant, e.g. `unique (tenant_id, tag_number)`.
- Reference tables use `NULLS NOT DISTINCT` where a system row and tenant row may
  share a name (`breeds`, `roles`).

## Migrations

- dbmate format: every file has `-- migrate:up` and `-- migrate:down`.
- Each migration runs in its own transaction; do not mix `ALTER TYPE ... ADD
  VALUE` with usage of the new value in the same file.
- Additive changes only: add tables/columns/constraints; never rewrite or drop
  business columns in place. Down migrations restore the prior schema shape.
