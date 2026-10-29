-- migrate:up

-- ---------------------------------------------------------------------------
-- General inventory/supply chain: suppliers, categories, items, purchase
-- orders and a signed stock ledger.  Feed tables are retained and backfilled
-- into the general model so existing reports keep working.
-- ---------------------------------------------------------------------------

CREATE TYPE purchase_order_status AS ENUM (
  'pending',
  'ordered',
  'partially_received',
  'received',
  'cancelled'
);

CREATE TYPE stock_transaction_type AS ENUM (
  'purchase',
  'consumption',
  'adjustment',
  'waste',
  'transfer'
);

CREATE TABLE suppliers (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  name           text NOT NULL,
  contact_person text,
  phone          text,
  email          citext,
  address        text,
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, name)
);

CREATE TRIGGER trg_suppliers_updated BEFORE UPDATE ON suppliers
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- tenant_id NULL = system category shared by every tenant.
CREATE TABLE inventory_categories (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid REFERENCES tenants(id) ON DELETE CASCADE,
  name        text NOT NULL,
  description text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  CONSTRAINT inventory_categories_tenant_name_key
    UNIQUE NULLS NOT DISTINCT (tenant_id, name)
);

CREATE TABLE inventory_items (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  category_id           uuid NOT NULL REFERENCES inventory_categories(id) ON DELETE RESTRICT,
  name                  text NOT NULL,
  sku                   text,
  unit                  text,
  current_stock         numeric(14,2) NOT NULL DEFAULT 0,
  reorder_level         numeric(14,2) NOT NULL DEFAULT 0 CHECK (reorder_level >= 0),
  reorder_quantity      numeric(14,2) CHECK (reorder_quantity IS NULL OR reorder_quantity >= 0),
  unit_cost             numeric(14,2) CHECK (unit_cost IS NULL OR unit_cost >= 0),
  preferred_supplier_id uuid,
  storage_location      text,
  expiry_date           date,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, name),
  UNIQUE (tenant_id, sku),
  FOREIGN KEY (tenant_id, preferred_supplier_id) REFERENCES suppliers (tenant_id, id)
);

CREATE TRIGGER trg_inventory_items_updated BEFORE UPDATE ON inventory_items
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_inventory_items_category ON inventory_items (tenant_id, category_id);
CREATE INDEX idx_inventory_items_low
  ON inventory_items (tenant_id)
  WHERE current_stock <= reorder_level;

-- Category may be a system category (tenant NULL) or the item's own tenant.
CREATE OR REPLACE FUNCTION assert_category_tenant() RETURNS trigger AS $$
DECLARE
  category_tenant uuid;
BEGIN
  SELECT tenant_id INTO category_tenant
    FROM inventory_categories WHERE id = NEW.category_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'inventory category % does not exist', NEW.category_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF category_tenant IS NOT NULL AND category_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION 'inventory category % belongs to another tenant', NEW.category_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_inventory_items_category_tenant
  BEFORE INSERT OR UPDATE OF category_id, tenant_id ON inventory_items
  FOR EACH ROW EXECUTE FUNCTION assert_category_tenant();

CREATE TABLE purchase_orders (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id              uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  supplier_id            uuid NOT NULL,
  order_date             date NOT NULL DEFAULT CURRENT_DATE,
  expected_delivery_date date,
  received_date          date,
  status                 purchase_order_status NOT NULL DEFAULT 'pending',
  total_cost             numeric(14,2) CHECK (total_cost IS NULL OR total_cost >= 0),
  created_by             uuid REFERENCES users(id) ON DELETE SET NULL,
  notes                  text,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, supplier_id) REFERENCES suppliers (tenant_id, id)
);

CREATE TRIGGER trg_purchase_orders_updated BEFORE UPDATE ON purchase_orders
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_purchase_orders_supplier ON purchase_orders (tenant_id, supplier_id);
CREATE INDEX idx_purchase_orders_status ON purchase_orders (tenant_id, status);

CREATE TABLE purchase_order_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  purchase_order_id uuid NOT NULL,
  inventory_item_id uuid NOT NULL,
  quantity          numeric(14,2) NOT NULL CHECK (quantity > 0),
  unit_cost         numeric(14,2) CHECK (unit_cost IS NULL OR unit_cost >= 0),
  subtotal          numeric(14,2) GENERATED ALWAYS AS
                      (round(quantity * COALESCE(unit_cost, 0), 2)) STORED,
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, purchase_order_id) REFERENCES purchase_orders (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, inventory_item_id) REFERENCES inventory_items (tenant_id, id)
);

CREATE INDEX idx_purchase_order_items_order ON purchase_order_items (tenant_id, purchase_order_id);

-- Signed ledger.  quantity is always stored positive for purchase/consumption/
-- waste; the trigger interprets the direction from transaction_type.
CREATE TABLE stock_transactions (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  inventory_item_id uuid NOT NULL,
  transaction_type  stock_transaction_type NOT NULL,
  quantity          numeric(14,2) NOT NULL,
  transaction_date  timestamptz NOT NULL DEFAULT now(),
  related_animal_id uuid,
  related_group_id  uuid,
  performed_by      uuid REFERENCES users(id) ON DELETE SET NULL,
  notes             text,
  source_system     text,
  source_id         text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, inventory_item_id) REFERENCES inventory_items (tenant_id, id),
  FOREIGN KEY (tenant_id, related_animal_id) REFERENCES animals (tenant_id, id),
  FOREIGN KEY (tenant_id, related_group_id) REFERENCES groups (tenant_id, id)
);

CREATE INDEX idx_stock_transactions_item
  ON stock_transactions (tenant_id, inventory_item_id, transaction_date DESC);
CREATE INDEX idx_stock_transactions_date
  ON stock_transactions (tenant_id, transaction_date DESC);
CREATE UNIQUE INDEX idx_stock_transactions_source
  ON stock_transactions (tenant_id, source_system, source_id)
  WHERE source_system IS NOT NULL AND source_id IS NOT NULL;

-- Backfill the general model from the feed-only tables. ---------------------
INSERT INTO inventory_categories (id, tenant_id, name, description)
VALUES ('00000000-0000-0000-0000-000000000901', NULL, 'Feed',
        'System category: feed, forage and supplements')
ON CONFLICT DO NOTHING;

INSERT INTO inventory_items
  (id, tenant_id, category_id, name, unit, current_stock, reorder_level, unit_cost, created_at)
SELECT fi.id,
       fi.tenant_id,
       '00000000-0000-0000-0000-000000000901',
       fi.name,
       fi.unit,
       COALESCE(inv.quantity_on_hand, 0),
       COALESCE(inv.reorder_level, 0),
       inv.unit_cost,
       fi.created_at
FROM feed_items fi
LEFT JOIN feed_inventory inv
       ON inv.feed_item_id = fi.id
      AND inv.tenant_id = fi.tenant_id
ON CONFLICT DO NOTHING;

INSERT INTO stock_transactions
  (id, tenant_id, inventory_item_id, transaction_type, quantity,
   transaction_date, performed_by, notes, source_system, source_id, created_at)
SELECT sm.id,
       sm.tenant_id,
       sm.feed_item_id,
       CASE sm.movement_type
         WHEN 'in'  THEN 'purchase'
         WHEN 'out' THEN 'consumption'
         ELSE 'adjustment'
       END::stock_transaction_type,
       CASE sm.movement_type
         WHEN 'in'  THEN abs(sm.quantity)
         WHEN 'out' THEN -abs(sm.quantity)
         ELSE sm.quantity
       END,
       sm.occurred_at,
       sm.recorded_by,
       sm.reason,
       'feed',
       sm.id::text,
       sm.created_at
FROM stock_movements sm
ON CONFLICT DO NOTHING;

-- Ledger -> current stock.  Created after the backfill so historical rows are
-- not applied twice (feed_inventory already holds the rolled-up balance).
CREATE OR REPLACE FUNCTION apply_stock_transaction() RETURNS trigger AS $$
DECLARE
  delta numeric(14,2);
BEGIN
  delta := CASE NEW.transaction_type
    WHEN 'purchase'    THEN  abs(NEW.quantity)
    WHEN 'consumption' THEN -abs(NEW.quantity)
    WHEN 'waste'       THEN -abs(NEW.quantity)
    WHEN 'adjustment'  THEN  NEW.quantity
    WHEN 'transfer'    THEN  NEW.quantity
  END;

  UPDATE inventory_items
     SET current_stock = current_stock + delta
   WHERE tenant_id = NEW.tenant_id
     AND id = NEW.inventory_item_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_stock_transactions_apply
  AFTER INSERT ON stock_transactions
  FOR EACH ROW EXECUTE FUNCTION apply_stock_transaction();

-- Replace the feed-only low-stock view with the general inventory view. ------
DROP VIEW IF EXISTS v_low_stock;
CREATE VIEW v_low_stock AS
SELECT ii.tenant_id,
       ii.id AS inventory_item_id,
       ii.name,
       ii.unit,
       ii.current_stock,
       ii.reorder_level,
       ii.reorder_quantity,
       (ii.reorder_level - ii.current_stock) AS shortfall,
       ii.unit_cost
FROM inventory_items ii
WHERE ii.current_stock <= ii.reorder_level;

CREATE VIEW v_reorder_recommendations AS
SELECT ii.tenant_id,
       ii.id AS inventory_item_id,
       ii.name,
       ii.unit,
       ii.current_stock,
       ii.reorder_level,
       GREATEST(COALESCE(ii.reorder_quantity, ii.reorder_level - ii.current_stock), 0)
         AS suggested_quantity,
       ii.unit_cost,
       GREATEST(COALESCE(ii.reorder_quantity, ii.reorder_level - ii.current_stock), 0)
         * COALESCE(ii.unit_cost, 0) AS estimated_cost,
       ii.preferred_supplier_id
FROM inventory_items ii
WHERE ii.current_stock <= ii.reorder_level;

-- migrate:down

DROP VIEW IF EXISTS v_reorder_recommendations;
DROP VIEW IF EXISTS v_low_stock;

CREATE VIEW v_low_stock AS
SELECT fi.tenant_id, fi.feed_item_id, f.name, fi.quantity_on_hand, fi.reorder_level
FROM feed_inventory fi
JOIN feed_items f ON f.id = fi.feed_item_id
WHERE fi.quantity_on_hand <= fi.reorder_level;

DROP TRIGGER IF EXISTS trg_stock_transactions_apply ON stock_transactions;
DROP FUNCTION IF EXISTS apply_stock_transaction();

DROP TRIGGER IF EXISTS trg_inventory_items_category_tenant ON inventory_items;
DROP FUNCTION IF EXISTS assert_category_tenant();

DROP INDEX IF EXISTS idx_stock_transactions_source;
DROP INDEX IF EXISTS idx_stock_transactions_date;
DROP INDEX IF EXISTS idx_stock_transactions_item;
DROP TABLE IF EXISTS stock_transactions;
DROP INDEX IF EXISTS idx_purchase_order_items_order;
DROP TABLE IF EXISTS purchase_order_items;
DROP INDEX IF EXISTS idx_purchase_orders_status;
DROP INDEX IF EXISTS idx_purchase_orders_supplier;
DROP TRIGGER IF EXISTS trg_purchase_orders_updated ON purchase_orders;
DROP TABLE IF EXISTS purchase_orders;
DROP INDEX IF EXISTS idx_inventory_items_low;
DROP INDEX IF EXISTS idx_inventory_items_category;
DROP TRIGGER IF EXISTS trg_inventory_items_updated ON inventory_items;
DROP TABLE IF EXISTS inventory_items;
DROP TABLE IF EXISTS inventory_categories;
DROP TRIGGER IF EXISTS trg_suppliers_updated ON suppliers;
DROP TABLE IF EXISTS suppliers;

DROP TYPE IF EXISTS stock_transaction_type;
DROP TYPE IF EXISTS purchase_order_status;
