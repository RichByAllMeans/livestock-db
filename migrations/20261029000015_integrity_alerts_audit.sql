-- migrate:up

-- ---------------------------------------------------------------------------
-- Cross-cutting integrity: remaining tenant targets, reference uniqueness,
-- richer alerts/notifications, UUID audit ids, append-only guards and RLS.
-- ---------------------------------------------------------------------------

ALTER TYPE notification_status ADD VALUE IF NOT EXISTS 'read';
ALTER TYPE notification_status ADD VALUE IF NOT EXISTS 'dismissed';
ALTER TYPE notification_channel ADD VALUE IF NOT EXISTS 'in_app';

CREATE TYPE notification_type AS ENUM (
  'health',
  'breeding',
  'inventory',
  'financial',
  'workforce',
  'system'
);

-- Remaining (tenant_id, id) targets for composite FKs / consistency checks. --
ALTER TABLE users              ADD CONSTRAINT users_tenant_id_id_key UNIQUE (tenant_id, id);
ALTER TABLE feed_items         ADD CONSTRAINT feed_items_tenant_id_id_key UNIQUE (tenant_id, id);
ALTER TABLE feed_inventory     ADD CONSTRAINT feed_inventory_tenant_id_id_key UNIQUE (tenant_id, id);
ALTER TABLE stock_movements    ADD CONSTRAINT stock_movements_tenant_id_id_key UNIQUE (tenant_id, id);
ALTER TABLE stock_alerts       ADD CONSTRAINT stock_alerts_tenant_id_id_key UNIQUE (tenant_id, id);
ALTER TABLE reorder_suggestions ADD CONSTRAINT reorder_suggestions_tenant_id_id_key UNIQUE (tenant_id, id);
ALTER TABLE installments       ADD CONSTRAINT installments_tenant_id_id_key UNIQUE (tenant_id, id);
ALTER TABLE budgets            ADD CONSTRAINT budgets_tenant_id_id_key UNIQUE (tenant_id, id);
ALTER TABLE attendance         ADD CONSTRAINT attendance_tenant_id_id_key UNIQUE (tenant_id, id);
ALTER TABLE notifications      ADD CONSTRAINT notifications_tenant_id_id_key UNIQUE (tenant_id, id);
ALTER TABLE alert_rules        ADD CONSTRAINT alert_rules_tenant_id_id_key UNIQUE (tenant_id, id);

-- Reference data: NULL tenant means a system row.  Treat NULLs as equal so
-- idempotent seed upserts cannot create duplicates.
CREATE UNIQUE INDEX breeds_tenant_name_uq
  ON breeds (tenant_id, name) NULLS NOT DISTINCT;

ALTER TABLE roles DROP CONSTRAINT IF EXISTS roles_tenant_id_name_key;
CREATE UNIQUE INDEX roles_tenant_name_uq
  ON roles (tenant_id, name) NULLS NOT DISTINCT;

-- Alert rules: recipients, message templates, severity, last run. -----------
ALTER TABLE alert_rules
  ADD COLUMN recipient_role    worker_role,
  ADD COLUMN recipient_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN title_template    text,
  ADD COLUMN body_template     text,
  ADD COLUMN severity          priority NOT NULL DEFAULT 'medium',
  ADD COLUMN last_run_at       timestamptz,
  ADD COLUMN updated_at        timestamptz NOT NULL DEFAULT now();

CREATE TRIGGER trg_alert_rules_updated BEFORE UPDATE ON alert_rules
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_alert_rules_active
  ON alert_rules (tenant_id) WHERE is_active;

-- Notifications: typed, prioritised, with delivery bookkeeping. ------------
ALTER TABLE notifications
  ADD COLUMN type          notification_type NOT NULL DEFAULT 'system',
  ADD COLUMN title         text,
  ADD COLUMN priority      priority NOT NULL DEFAULT 'medium',
  ADD COLUMN read_at       timestamptz,
  ADD COLUMN dismissed_at  timestamptz,
  ADD COLUMN error_message text,
  ADD COLUMN attempts      integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  ADD COLUMN updated_at    timestamptz NOT NULL DEFAULT now();

CREATE TRIGGER trg_notifications_updated BEFORE UPDATE ON notifications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_notifications_recipient
  ON notifications (tenant_id, recipient_user_id, created_at DESC);

-- audit_log: bigserial -> uuid (consistent with every other table). ---------
ALTER TABLE audit_log DROP CONSTRAINT IF EXISTS audit_log_pkey;
ALTER TABLE audit_log DROP COLUMN IF EXISTS id;
ALTER TABLE audit_log
  ADD COLUMN id uuid PRIMARY KEY DEFAULT gen_random_uuid();

-- Append-only guards. -------------------------------------------------------
CREATE TRIGGER trg_health_records_immutable
  BEFORE UPDATE OR DELETE ON health_records
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER trg_stock_movements_immutable
  BEFORE UPDATE OR DELETE ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER trg_transactions_immutable
  BEFORE UPDATE OR DELETE ON transactions
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER trg_payments_immutable
  BEFORE UPDATE OR DELETE ON payments
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER trg_stock_transactions_immutable
  BEFORE UPDATE OR DELETE ON stock_transactions
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();
CREATE TRIGGER trg_audit_log_immutable
  BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- Row-level security.  NOT FORCE: migrations/seed run as table owner and
-- therefore bypass it; application roles must set app.tenant_id per request.
CREATE OR REPLACE FUNCTION current_tenant_id() RETURNS uuid AS $$
  SELECT nullif(current_setting('app.tenant_id', true), '')::uuid;
$$ LANGUAGE sql STABLE;

ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenants_self ON tenants
  USING (id = current_tenant_id())
  WITH CHECK (id = current_tenant_id());

-- Standard tenant-scoped tables.
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
CREATE POLICY users_tenant_isolation ON users
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE animals ENABLE ROW LEVEL SECURITY;
CREATE POLICY animals_tenant_isolation ON animals
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE groups ENABLE ROW LEVEL SECURITY;
CREATE POLICY groups_tenant_isolation ON groups
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE animal_group_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY animal_group_history_tenant_isolation ON animal_group_history
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE animal_history_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY animal_history_log_tenant_isolation ON animal_history_log
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE health_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY health_records_tenant_isolation ON health_records
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE medications ENABLE ROW LEVEL SECURITY;
CREATE POLICY medications_tenant_isolation ON medications
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE mortality_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY mortality_log_tenant_isolation ON mortality_log
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE breeding_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY breeding_events_tenant_isolation ON breeding_events
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE birth_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY birth_records_tenant_isolation ON birth_records
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE offspring ENABLE ROW LEVEL SECURITY;
CREATE POLICY offspring_tenant_isolation ON offspring
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;
CREATE POLICY suppliers_tenant_isolation ON suppliers
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE inventory_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY inventory_items_tenant_isolation ON inventory_items
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE purchase_orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY purchase_orders_tenant_isolation ON purchase_orders
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE purchase_order_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY purchase_order_items_tenant_isolation ON purchase_order_items
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE stock_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY stock_transactions_tenant_isolation ON stock_transactions
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE feed_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY feed_items_tenant_isolation ON feed_items
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE feed_inventory ENABLE ROW LEVEL SECURITY;
CREATE POLICY feed_inventory_tenant_isolation ON feed_inventory
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE stock_movements ENABLE ROW LEVEL SECURITY;
CREATE POLICY stock_movements_tenant_isolation ON stock_movements
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE stock_alerts ENABLE ROW LEVEL SECURITY;
CREATE POLICY stock_alerts_tenant_isolation ON stock_alerts
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE reorder_suggestions ENABLE ROW LEVEL SECURITY;
CREATE POLICY reorder_suggestions_tenant_isolation ON reorder_suggestions
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY transactions_tenant_isolation ON transactions
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;
CREATE POLICY invoices_tenant_isolation ON invoices
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE installments ENABLE ROW LEVEL SECURITY;
CREATE POLICY installments_tenant_isolation ON installments
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY payments_tenant_isolation ON payments
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE budgets ENABLE ROW LEVEL SECURITY;
CREATE POLICY budgets_tenant_isolation ON budgets
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE workers ENABLE ROW LEVEL SECURITY;
CREATE POLICY workers_tenant_isolation ON workers
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE attendance ENABLE ROW LEVEL SECURITY;
CREATE POLICY attendance_tenant_isolation ON attendance
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE work_schedules ENABLE ROW LEVEL SECURITY;
CREATE POLICY work_schedules_tenant_isolation ON work_schedules
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE task_assignments ENABLE ROW LEVEL SECURITY;
CREATE POLICY task_assignments_tenant_isolation ON task_assignments
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY notifications_tenant_isolation ON notifications
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE alert_rules ENABLE ROW LEVEL SECURITY;
CREATE POLICY alert_rules_tenant_isolation ON alert_rules
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_log_tenant_isolation ON audit_log
  USING (tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

-- Reference tables may expose system rows (tenant_id IS NULL) to everyone.
ALTER TABLE breeds ENABLE ROW LEVEL SECURITY;
CREATE POLICY breeds_tenant_isolation ON breeds
  USING (tenant_id IS NULL OR tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY roles_tenant_isolation ON roles
  USING (tenant_id IS NULL OR tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

ALTER TABLE inventory_categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY inventory_categories_tenant_isolation ON inventory_categories
  USING (tenant_id IS NULL OR tenant_id = current_tenant_id())
  WITH CHECK (tenant_id = current_tenant_id());

-- Child tables without tenant_id: inherit visibility from their parent.
ALTER TABLE invoice_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY invoice_items_tenant_isolation ON invoice_items
  USING (EXISTS (
    SELECT 1 FROM invoices i
     WHERE i.id = invoice_items.invoice_id
       AND i.tenant_id = current_tenant_id()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM invoices i
     WHERE i.id = invoice_items.invoice_id
       AND i.tenant_id = current_tenant_id()
  ));

ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
CREATE POLICY user_roles_tenant_isolation ON user_roles
  USING (EXISTS (
    SELECT 1 FROM users u
     WHERE u.id = user_roles.user_id
       AND u.tenant_id = current_tenant_id()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM users u
     WHERE u.id = user_roles.user_id
       AND u.tenant_id = current_tenant_id()
  ));

ALTER TABLE role_permissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY role_permissions_tenant_isolation ON role_permissions
  USING (EXISTS (
    SELECT 1 FROM roles r
     WHERE r.id = role_permissions.role_id
       AND (r.tenant_id IS NULL OR r.tenant_id = current_tenant_id())
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM roles r
     WHERE r.id = role_permissions.role_id
       AND (r.tenant_id IS NULL OR r.tenant_id = current_tenant_id())
  ));

-- migrate:down

DROP TRIGGER IF EXISTS trg_audit_log_immutable ON audit_log;
DROP TRIGGER IF EXISTS trg_stock_transactions_immutable ON stock_transactions;
DROP TRIGGER IF EXISTS trg_payments_immutable ON payments;
DROP TRIGGER IF EXISTS trg_transactions_immutable ON transactions;
DROP TRIGGER IF EXISTS trg_stock_movements_immutable ON stock_movements;
DROP TRIGGER IF EXISTS trg_health_records_immutable ON health_records;

DROP POLICY IF EXISTS role_permissions_tenant_isolation ON role_permissions;
ALTER TABLE role_permissions DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS user_roles_tenant_isolation ON user_roles;
ALTER TABLE user_roles DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS invoice_items_tenant_isolation ON invoice_items;
ALTER TABLE invoice_items DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS inventory_categories_tenant_isolation ON inventory_categories;
ALTER TABLE inventory_categories DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS roles_tenant_isolation ON roles;
ALTER TABLE roles DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS breeds_tenant_isolation ON breeds;
ALTER TABLE breeds DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS audit_log_tenant_isolation ON audit_log;
ALTER TABLE audit_log DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS alert_rules_tenant_isolation ON alert_rules;
ALTER TABLE alert_rules DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS notifications_tenant_isolation ON notifications;
ALTER TABLE notifications DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS task_assignments_tenant_isolation ON task_assignments;
ALTER TABLE task_assignments DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS work_schedules_tenant_isolation ON work_schedules;
ALTER TABLE work_schedules DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS attendance_tenant_isolation ON attendance;
ALTER TABLE attendance DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS workers_tenant_isolation ON workers;
ALTER TABLE workers DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS budgets_tenant_isolation ON budgets;
ALTER TABLE budgets DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS payments_tenant_isolation ON payments;
ALTER TABLE payments DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS installments_tenant_isolation ON installments;
ALTER TABLE installments DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS invoices_tenant_isolation ON invoices;
ALTER TABLE invoices DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS transactions_tenant_isolation ON transactions;
ALTER TABLE transactions DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reorder_suggestions_tenant_isolation ON reorder_suggestions;
ALTER TABLE reorder_suggestions DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS stock_alerts_tenant_isolation ON stock_alerts;
ALTER TABLE stock_alerts DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS stock_movements_tenant_isolation ON stock_movements;
ALTER TABLE stock_movements DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS feed_inventory_tenant_isolation ON feed_inventory;
ALTER TABLE feed_inventory DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS feed_items_tenant_isolation ON feed_items;
ALTER TABLE feed_items DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS stock_transactions_tenant_isolation ON stock_transactions;
ALTER TABLE stock_transactions DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS purchase_order_items_tenant_isolation ON purchase_order_items;
ALTER TABLE purchase_order_items DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS purchase_orders_tenant_isolation ON purchase_orders;
ALTER TABLE purchase_orders DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS inventory_items_tenant_isolation ON inventory_items;
ALTER TABLE inventory_items DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS suppliers_tenant_isolation ON suppliers;
ALTER TABLE suppliers DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS offspring_tenant_isolation ON offspring;
ALTER TABLE offspring DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS birth_records_tenant_isolation ON birth_records;
ALTER TABLE birth_records DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS breeding_events_tenant_isolation ON breeding_events;
ALTER TABLE breeding_events DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mortality_log_tenant_isolation ON mortality_log;
ALTER TABLE mortality_log DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS medications_tenant_isolation ON medications;
ALTER TABLE medications DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS health_records_tenant_isolation ON health_records;
ALTER TABLE health_records DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS animal_history_log_tenant_isolation ON animal_history_log;
ALTER TABLE animal_history_log DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS animal_group_history_tenant_isolation ON animal_group_history;
ALTER TABLE animal_group_history DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS groups_tenant_isolation ON groups;
ALTER TABLE groups DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS animals_tenant_isolation ON animals;
ALTER TABLE animals DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS users_tenant_isolation ON users;
ALTER TABLE users DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenants_self ON tenants;
ALTER TABLE tenants DISABLE ROW LEVEL SECURITY;
DROP FUNCTION IF EXISTS current_tenant_id();

ALTER TABLE audit_log DROP CONSTRAINT IF EXISTS audit_log_pkey;
ALTER TABLE audit_log DROP COLUMN IF EXISTS id;
ALTER TABLE audit_log ADD COLUMN id bigserial PRIMARY KEY;

DROP INDEX IF EXISTS idx_notifications_recipient;
DROP TRIGGER IF EXISTS trg_notifications_updated ON notifications;
ALTER TABLE notifications
  DROP COLUMN IF EXISTS updated_at,
  DROP COLUMN IF EXISTS attempts,
  DROP COLUMN IF EXISTS error_message,
  DROP COLUMN IF EXISTS dismissed_at,
  DROP COLUMN IF EXISTS read_at,
  DROP COLUMN IF EXISTS priority,
  DROP COLUMN IF EXISTS title,
  DROP COLUMN IF EXISTS type;

DROP INDEX IF EXISTS idx_alert_rules_active;
DROP TRIGGER IF EXISTS trg_alert_rules_updated ON alert_rules;
ALTER TABLE alert_rules
  DROP COLUMN IF EXISTS updated_at,
  DROP COLUMN IF EXISTS last_run_at,
  DROP COLUMN IF EXISTS severity,
  DROP COLUMN IF EXISTS body_template,
  DROP COLUMN IF EXISTS title_template,
  DROP COLUMN IF EXISTS recipient_user_id,
  DROP COLUMN IF EXISTS recipient_role;

ALTER TABLE alert_rules DROP CONSTRAINT IF EXISTS alert_rules_tenant_id_id_key;
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_tenant_id_id_key;
ALTER TABLE attendance DROP CONSTRAINT IF EXISTS attendance_tenant_id_id_key;
ALTER TABLE budgets DROP CONSTRAINT IF EXISTS budgets_tenant_id_id_key;
ALTER TABLE installments DROP CONSTRAINT IF EXISTS installments_tenant_id_id_key;
ALTER TABLE reorder_suggestions DROP CONSTRAINT IF EXISTS reorder_suggestions_tenant_id_id_key;
ALTER TABLE stock_alerts DROP CONSTRAINT IF EXISTS stock_alerts_tenant_id_id_key;
ALTER TABLE stock_movements DROP CONSTRAINT IF EXISTS stock_movements_tenant_id_id_key;
ALTER TABLE feed_inventory DROP CONSTRAINT IF EXISTS feed_inventory_tenant_id_id_key;
ALTER TABLE feed_items DROP CONSTRAINT IF EXISTS feed_items_tenant_id_id_key;
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_tenant_id_id_key;

DROP INDEX IF EXISTS roles_tenant_name_uq;
ALTER TABLE roles ADD CONSTRAINT roles_tenant_id_name_key UNIQUE (tenant_id, name);
DROP INDEX IF EXISTS breeds_tenant_name_uq;

DROP TYPE IF EXISTS notification_type;

-- notification_status / notification_channel values added above are retained.
