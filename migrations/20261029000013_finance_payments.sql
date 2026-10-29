-- migrate:up

-- ---------------------------------------------------------------------------
-- Finance: categorised ledger, invoice payments, budget variance.  A payment
-- is now the canonical money-received record; legacy installments are copied.
-- ---------------------------------------------------------------------------

CREATE TYPE financial_category AS ENUM (
  'animal_sale',
  'produce_sale',
  'byproduct_sale',
  'feed_purchase',
  'vet_expense',
  'labor_expense',
  'equipment_expense',
  'utilities',
  'loan_repayment',
  'other'
);

-- Invoices: contact + explicit tenant target + due date always present. ------
ALTER TABLE invoices
  ADD COLUMN customer_contact text,
  ADD COLUMN is_legacy        boolean NOT NULL DEFAULT false;

ALTER TABLE invoices
  ADD CONSTRAINT invoices_tenant_id_id_key UNIQUE (tenant_id, id);

UPDATE invoices
   SET due_date = issue_date + 30
 WHERE due_date IS NULL;

ALTER TABLE invoices
  ADD CONSTRAINT invoices_due_date_chk
    CHECK (due_date IS NOT NULL AND due_date >= issue_date);

CREATE INDEX idx_invoices_due ON invoices (tenant_id, due_date);

-- Budgets gain the shared category vocabulary. ------------------------------
ALTER TABLE budgets
  ADD COLUMN category_code financial_category,
  ADD COLUMN notes         text;

UPDATE budgets
   SET category_code = CASE
     WHEN category ILIKE '%animal%' OR category ILIKE '%livestock%' THEN 'animal_sale'::financial_category
     WHEN category ILIKE '%milk%' OR category ILIKE '%produce%'      THEN 'produce_sale'::financial_category
     WHEN category ILIKE '%byproduct%'                               THEN 'byproduct_sale'::financial_category
     WHEN category ILIKE '%feed%'                                    THEN 'feed_purchase'::financial_category
     WHEN category ILIKE '%vet%' OR category ILIKE '%health%'        THEN 'vet_expense'::financial_category
     WHEN category ILIKE '%labour%' OR category ILIKE '%labor%'
       OR category ILIKE '%wage%'                                    THEN 'labor_expense'::financial_category
     WHEN category ILIKE '%equipment%'                               THEN 'equipment_expense'::financial_category
     WHEN category ILIKE '%utilit%'                                  THEN 'utilities'::financial_category
     WHEN category ILIKE '%loan%'                                    THEN 'loan_repayment'::financial_category
     ELSE 'other'::financial_category
   END
 WHERE category_code IS NULL;

ALTER TABLE budgets
  ALTER COLUMN category_code SET DEFAULT 'other',
  ALTER COLUMN category_code SET NOT NULL;

-- Ledger: category code + links back to the operational records. ------------
ALTER TABLE transactions
  ADD COLUMN category_code           financial_category,
  ADD COLUMN related_animal_id       uuid,
  ADD COLUMN related_group_id        uuid,
  ADD COLUMN related_invoice_id      uuid,
  ADD COLUMN related_purchase_order_id uuid,
  ADD COLUMN payment_method          text,
  ADD COLUMN is_legacy               boolean NOT NULL DEFAULT false;

ALTER TABLE transactions
  ADD CONSTRAINT transactions_tenant_id_id_key UNIQUE (tenant_id, id);

UPDATE transactions
   SET category_code = CASE
     WHEN category ILIKE '%animal%' OR category ILIKE '%livestock%' THEN 'animal_sale'::financial_category
     WHEN category ILIKE '%milk%' OR category ILIKE '%produce%'      THEN 'produce_sale'::financial_category
     WHEN category ILIKE '%byproduct%'                               THEN 'byproduct_sale'::financial_category
     WHEN category ILIKE '%feed%'                                    THEN 'feed_purchase'::financial_category
     WHEN category ILIKE '%vet%' OR category ILIKE '%health%'        THEN 'vet_expense'::financial_category
     WHEN category ILIKE '%labour%' OR category ILIKE '%labor%'
       OR category ILIKE '%wage%'                                    THEN 'labor_expense'::financial_category
     WHEN category ILIKE '%equipment%'                               THEN 'equipment_expense'::financial_category
     WHEN category ILIKE '%utilit%'                                  THEN 'utilities'::financial_category
     WHEN category ILIKE '%loan%'                                    THEN 'loan_repayment'::financial_category
     ELSE 'other'::financial_category
   END
 WHERE category_code IS NULL;

ALTER TABLE transactions
  ALTER COLUMN category_code SET DEFAULT 'other',
  ALTER COLUMN category_code SET NOT NULL;

ALTER TABLE transactions
  ADD CONSTRAINT transactions_tenant_animal_fk
    FOREIGN KEY (tenant_id, related_animal_id) REFERENCES animals (tenant_id, id),
  ADD CONSTRAINT transactions_tenant_group_fk
    FOREIGN KEY (tenant_id, related_group_id) REFERENCES groups (tenant_id, id),
  ADD CONSTRAINT transactions_tenant_invoice_fk
    FOREIGN KEY (tenant_id, related_invoice_id) REFERENCES invoices (tenant_id, id),
  ADD CONSTRAINT transactions_tenant_purchase_order_fk
    FOREIGN KEY (tenant_id, related_purchase_order_id) REFERENCES purchase_orders (tenant_id, id);

CREATE INDEX idx_transactions_category
  ON transactions (tenant_id, category_code, occurred_at DESC);
CREATE INDEX idx_transactions_animal
  ON transactions (tenant_id, related_animal_id) WHERE related_animal_id IS NOT NULL;

-- Payments. -----------------------------------------------------------------
CREATE TABLE payments (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id        uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  invoice_id       uuid NOT NULL,
  payment_date     date NOT NULL DEFAULT CURRENT_DATE,
  amount           numeric(14,2) NOT NULL CHECK (amount > 0),
  payment_method   text,
  reference_number text,
  recorded_by      uuid REFERENCES users(id) ON DELETE SET NULL,
  notes            text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, invoice_id) REFERENCES invoices (tenant_id, id)
);

CREATE INDEX idx_payments_invoice ON payments (tenant_id, invoice_id, payment_date DESC);
CREATE INDEX idx_payments_date ON payments (tenant_id, payment_date DESC);

-- Legacy installments marked paid become payments.
INSERT INTO payments
  (tenant_id, invoice_id, payment_date, amount, payment_method, reference_number, notes)
SELECT tenant_id,
       invoice_id,
       COALESCE(paid_date, due_date, created_at::date),
       amount,
       method,
       reference,
       'Backfilled from paid installment'
FROM installments
WHERE status = 'paid';

-- Read models. --------------------------------------------------------------
DROP VIEW IF EXISTS v_invoice_balance;
CREATE VIEW v_invoice_balance AS
SELECT i.id AS invoice_id,
       i.tenant_id,
       i.invoice_number,
       i.total_amount,
       COALESCE(sum(p.amount), 0) AS amount_paid,
       i.total_amount - COALESCE(sum(p.amount), 0) AS balance
FROM invoices i
LEFT JOIN payments p ON p.invoice_id = i.id
GROUP BY i.id;

CREATE VIEW v_invoice_totals AS
SELECT i.id AS invoice_id,
       i.tenant_id,
       i.invoice_number,
       i.total_amount,
       COALESCE(sum(ii.quantity * ii.unit_price), 0) AS items_total,
       i.total_amount - COALESCE(sum(ii.quantity * ii.unit_price), 0) AS difference
FROM invoices i
LEFT JOIN invoice_items ii ON ii.invoice_id = i.id
GROUP BY i.id;

CREATE VIEW v_budget_variance AS
SELECT b.id AS budget_id,
       b.tenant_id,
       b.name,
       b.category_code,
       b.period_start,
       b.period_end,
       b.planned_amount,
       COALESCE(sum(t.amount) FILTER (WHERE t.txn_type = 'expense'), 0) AS actual_expense,
       b.planned_amount
         - COALESCE(sum(t.amount) FILTER (WHERE t.txn_type = 'expense'), 0) AS variance
FROM budgets b
LEFT JOIN transactions t
       ON t.tenant_id = b.tenant_id
      AND t.category_code = b.category_code
      AND t.txn_type = 'expense'
      AND t.occurred_at::date BETWEEN b.period_start AND b.period_end
GROUP BY b.id;

-- migrate:down

DROP VIEW IF EXISTS v_budget_variance;
DROP VIEW IF EXISTS v_invoice_totals;
DROP VIEW IF EXISTS v_invoice_balance;

CREATE VIEW v_invoice_balance AS
SELECT i.id AS invoice_id, i.tenant_id, i.invoice_number, i.total_amount,
       COALESCE(sum(ins.amount) FILTER (WHERE ins.status = 'paid'), 0) AS amount_paid,
       i.total_amount - COALESCE(sum(ins.amount) FILTER (WHERE ins.status = 'paid'), 0) AS balance
FROM invoices i
LEFT JOIN installments ins ON ins.invoice_id = i.id
GROUP BY i.id;

DROP INDEX IF EXISTS idx_payments_date;
DROP INDEX IF EXISTS idx_payments_invoice;
DROP TABLE IF EXISTS payments;

DROP INDEX IF EXISTS idx_transactions_animal;
DROP INDEX IF EXISTS idx_transactions_category;
ALTER TABLE transactions
  DROP CONSTRAINT IF EXISTS transactions_tenant_purchase_order_fk,
  DROP CONSTRAINT IF EXISTS transactions_tenant_invoice_fk,
  DROP CONSTRAINT IF EXISTS transactions_tenant_group_fk,
  DROP CONSTRAINT IF EXISTS transactions_tenant_animal_fk,
  DROP CONSTRAINT IF EXISTS transactions_tenant_id_id_key;
ALTER TABLE transactions
  DROP COLUMN IF EXISTS is_legacy,
  DROP COLUMN IF EXISTS payment_method,
  DROP COLUMN IF EXISTS related_purchase_order_id,
  DROP COLUMN IF EXISTS related_invoice_id,
  DROP COLUMN IF EXISTS related_group_id,
  DROP COLUMN IF EXISTS related_animal_id,
  DROP COLUMN IF EXISTS category_code;

ALTER TABLE budgets
  DROP COLUMN IF EXISTS notes,
  DROP COLUMN IF EXISTS category_code;

DROP INDEX IF EXISTS idx_invoices_due;
ALTER TABLE invoices
  DROP CONSTRAINT IF EXISTS invoices_due_date_chk,
  DROP CONSTRAINT IF EXISTS invoices_tenant_id_id_key;
ALTER TABLE invoices
  DROP COLUMN IF EXISTS is_legacy,
  DROP COLUMN IF EXISTS customer_contact;

DROP TYPE IF EXISTS financial_category;
