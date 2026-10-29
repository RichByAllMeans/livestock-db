# Required fields for record entry

This is the contract for the backend/forms. Migrations are the source of truth;
this document explains which fields a **new** record must supply, which are
recommended, and how imported/legacy rows are handled.

## Legacy policy

- New records must satisfy the required fields below.
- Imported or pre-existing rows that cannot satisfy them are written with
  `is_legacy = true` and explicit legacy defaults (e.g. `origin = 'purchased'`).
- `is_legacy` currently exists on: `animals`, `health_records`,
  `breeding_events`, `workers`, `transactions`, `invoices`.
- Analytics reports expose or exclude legacy rows where noted. Do not silently
  backfill guessed values for new records.

Every business table also has: `id uuid`, `tenant_id uuid`, `created_at
timestamptz`; mutable tables add `updated_at`. New rows must never omit
`tenant_id`.

## Animals

| Field | Required | Notes |
|-------|----------|-------|
| `tag_number` | yes | unique per tenant |
| `species` | yes | no longer defaulted |
| `sex` | yes | no longer defaulted |
| `origin` | yes | no longer defaulted |
| `date_of_birth` **or** `acquisition_date` | yes (one) | waived only when `is_legacy = true` |
| `breed_id` / `breed_name_raw` | recommended | system breed or same-tenant breed |
| `current_group_id` | recommended | same tenant |
| `rfid_code` | optional | unique per tenant when present |
| `origin_source`, `acquisition_cost`, `current_owner`, `photo_url`, `notes` | optional | |
| `date_of_birth_is_estimated` | optional | default `false` |

## Groups & per-animal history

| Table | Required fields |
|-------|-----------------|
| `groups` | `name`, `type` (`herd`/`pen`/`paddock`/`category`) |
| `animal_group_history` | `animal_id`, `group_id`, `start_date`; `end_date` NULL = current |
| `animal_history_log` | `animal_id`, `event_type`, `event_date`; `weight_kg` required when `event_type = 'weight'` |

`animal_history_log` is append-only.

## Health

| Table | Required fields |
|-------|-----------------|
| `medications` | `name`; `unit`, `withdrawal_period_*` recommended |
| `health_records` | `animal_id`, `event_type`, `occurred_at` (defaults to now) |
| `health_records` when `record_status = 'scheduled'` | `next_due_date` (enforced by CHECK) |

`record_status`: `scheduled` / `completed` / `cancelled` (default completed).
`medication_id` and `vet_id` are optional but link to `medications` and `workers`.
`health_records` is append-only; use `corrects_id` for corrections.

## Mortality

| Table | Required fields |
|-------|-----------------|
| `mortality_log` | `animal_id`, `date_of_death`; one row per animal |

Inserting mortality sets the animal's `status` to `dead` automatically.

## Breeding

| Table | Required fields |
|-------|-----------------|
| `breeding_events` | `dam_id`, `event_type`, `occurred_at`; `breeding_method` (default natural), `breeding_status` (default planned) |
| `birth_records` | `breeding_event_id`, `dam_id`, `birth_date` |
| `offspring` | `birth_record_id`, `outcome` (`live`/`stillborn`/`died_before_weaning`/`weaned`) |

`expected_due_date` is required in practice for `planned` /
`confirmed_pregnant` records so due alerts work.

## Inventory & supply

| Table | Required fields |
|-------|-----------------|
| `suppliers` | `name` |
| `inventory_categories` | `name`; `tenant_id` NULL = system category |
| `inventory_items` | `category_id`, `name`; `unit` recommended |
| `purchase_orders` | `supplier_id`, `order_date` |
| `purchase_order_items` | `purchase_order_id`, `inventory_item_id`, `quantity` (> 0) |
| `stock_transactions` | `inventory_item_id`, `transaction_type`, `quantity` |

`stock_transactions` is append-only. The trigger applies the signed effect to
`inventory_items.current_stock` (`purchase` +, `consumption`/`waste` −,
`adjustment`/`transfer` as signed).

## Finance

| Table | Required fields |
|-------|-----------------|
| `transactions` | `txn_type`, `amount`, `category_code` (default `other`), `occurred_at` |
| `invoices` | `invoice_number`, `customer_name`, `issue_date`, `due_date`; due date defaults are backfilled as issue + 30 days |
| `invoice_items` | `invoice_id`, `description`, `quantity`, `unit_price` |
| `payments` | `invoice_id`, `amount` (> 0), `payment_date` |
| `budgets` | `name`, `period_start`, `period_end`, `planned_amount`, `category_code` (default `other`) |

`transactions` and `payments` are append-only.

## Workforce

| Table | Required fields |
|-------|-----------------|
| `workers` | `full_name`, `role` (`owner`/`manager`/`worker`/`vet`) |
| `attendance` | `worker_id`, `work_date`; unique per worker/day |
| `work_schedules` | `worker_id`, `shift_date` |
| `task_assignments` | `worker_id`, `task_title`; `status` (default pending), `priority` (default medium) |

## Alerts & notifications

| Table | Required fields |
|-------|-----------------|
| `notifications` | `channel`, `body`; `type`, `title`, `priority` recommended |
| `alert_rules` | `name`, `event_type`, `channel`; `recipient_role`/`recipient_user_id` and templates recommended |

`notification_channel`: `sms`, `email`, `web_push`, `whatsapp`, `in_app`.
`notification_status`: `pending`, `sent`, `failed`, `read`, `dismissed`.

## Append-only tables

`health_records`, `stock_movements`, `transactions`, `payments`,
`stock_transactions`, `audit_log`, `animal_history_log`.

Updates/deletes are rejected by trigger. Record a correction/new row instead.

## Tenant isolation

- Every tenant table has `tenant_id` and a composite `(tenant_id, id)` target.
- Row-level security is enabled (not forced). Application connections must set
  the tenant per request:

```sql
SET app.tenant_id = '<tenant-uuid>';
```

- System reference rows (`breeds`, `roles`, `inventory_categories`) have
  `tenant_id = NULL` and are readable by all tenants, writable only by system
  migrations/seed.

## Enum reference

| Enum | Values |
|------|--------|
| `animal_origin` | purchased, local, newborn, born_on_farm, gifted, transferred_in |
| `animal_status` | active, sold, dead, archived, deceased, transferred, quarantined |
| `animal_sex` | male, female, unknown |
| `group_type` | herd, pen, paddock, category |
| `history_event_type` | health, weight, location, ownership, status_change, group_change |
| `health_event_type` | vaccination, treatment, checkup, illness, injury, deworming, vet_visit, surgery |
| `health_record_status` | scheduled, completed, cancelled |
| `breeding_event_type` | mating, insemination, pregnancy_check, birth, abortion |
| `breeding_method` | natural, artificial_insemination, embryo_transfer |
| `breeding_status` | planned, confirmed_pregnant, not_pregnant, completed, aborted |
| `offspring_outcome` | live, stillborn, died_before_weaning, weaned |
| `stock_movement_type` | in, out, adjustment |
| `stock_transaction_type` | purchase, consumption, adjustment, waste, transfer |
| `purchase_order_status` | pending, ordered, partially_received, received, cancelled |
| `txn_type` | income, expense |
| `financial_category` | animal_sale, produce_sale, byproduct_sale, feed_purchase, vet_expense, labor_expense, equipment_expense, utilities, loan_repayment, other |
| `invoice_status` | draft, sent, partial, paid, overdue, cancelled |
| `installment_status` | pending, paid, overdue |
| `worker_role` | owner, manager, worker, vet |
| `task_status` | pending, in_progress, completed, cancelled |
| `priority` | low, medium, high, critical |
| `attendance_status` | present, absent, late, excused |
| `notification_type` | health, breeding, inventory, financial, workforce, system |
| `notification_channel` | sms, email, web_push, whatsapp, in_app |
| `notification_status` | pending, sent, failed, read, dismissed |
