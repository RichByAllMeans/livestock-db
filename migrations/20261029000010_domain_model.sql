-- migrate:up

-- ---------------------------------------------------------------------------
-- Port of the standalone domain model: groups, per-animal history, richer
-- animal attributes.  Additive only: existing tenants/rows are untouched.
-- ---------------------------------------------------------------------------

-- Extend existing enums.  New values cannot be removed again in PostgreSQL,
-- so the down migration intentionally leaves them in place.
ALTER TYPE animal_origin ADD VALUE IF NOT EXISTS 'born_on_farm';
ALTER TYPE animal_origin ADD VALUE IF NOT EXISTS 'gifted';
ALTER TYPE animal_origin ADD VALUE IF NOT EXISTS 'transferred_in';
ALTER TYPE animal_status ADD VALUE IF NOT EXISTS 'deceased';
ALTER TYPE animal_status ADD VALUE IF NOT EXISTS 'transferred';
ALTER TYPE animal_status ADD VALUE IF NOT EXISTS 'quarantined';

CREATE TYPE group_type AS ENUM ('herd', 'pen', 'paddock', 'category');

CREATE TYPE history_event_type AS ENUM (
  'health',
  'weight',
  'location',
  'ownership',
  'status_change',
  'group_change'
);

-- Generic immutability guard.  Corrections are new rows, never UPDATE/DELETE.
CREATE OR REPLACE FUNCTION forbid_mutation() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'table % is append-only; insert a correction row instead',
    TG_TABLE_NAME
    USING ERRCODE = 'restrict_violation';
END;
$$ LANGUAGE plpgsql;

-- A breed may be a system breed (tenant_id IS NULL) or belong to the same
-- tenant as the animal.  Composite FKs cannot express the NULL-system case.
CREATE OR REPLACE FUNCTION assert_breed_tenant() RETURNS trigger AS $$
DECLARE
  breed_tenant uuid;
BEGIN
  IF NEW.breed_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT tenant_id INTO breed_tenant FROM breeds WHERE id = NEW.breed_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'breed % does not exist', NEW.breed_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF breed_tenant IS NOT NULL AND breed_tenant <> NEW.tenant_id THEN
    RAISE EXCEPTION 'breed % belongs to another tenant', NEW.breed_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Groups (herds, pens, paddocks, categories); supports nesting. -------------
CREATE TABLE groups (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  name            text NOT NULL,
  type            group_type NOT NULL,
  parent_group_id uuid,
  capacity        integer CHECK (capacity IS NULL OR capacity >= 0),
  location        text,
  description     text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, name)
);

ALTER TABLE groups
  ADD CONSTRAINT groups_tenant_parent_fk
  FOREIGN KEY (tenant_id, parent_group_id)
  REFERENCES groups (tenant_id, id);

CREATE TRIGGER trg_groups_updated BEFORE UPDATE ON groups
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Composite tenant target needed by the history tables below.
ALTER TABLE animals
  ADD CONSTRAINT animals_tenant_id_id_key UNIQUE (tenant_id, id);

-- Which group an animal belonged to, and when.  end_date NULL = current.
CREATE TABLE animal_group_history (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  animal_id   uuid NOT NULL,
  group_id    uuid NOT NULL,
  start_date  date NOT NULL,
  end_date    date,
  reason      text,
  recorded_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  CHECK (end_date IS NULL OR end_date >= start_date),
  FOREIGN KEY (tenant_id, animal_id) REFERENCES animals (tenant_id, id),
  FOREIGN KEY (tenant_id, group_id) REFERENCES groups (tenant_id, id)
);

CREATE INDEX idx_animal_group_history_animal ON animal_group_history (tenant_id, animal_id, start_date DESC);
CREATE INDEX idx_animal_group_history_group ON animal_group_history (tenant_id, group_id, start_date DESC);

-- Consolidated, append-only per-animal timeline (weight/location/ownership/...).
CREATE TABLE animal_history_log (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  animal_id      uuid NOT NULL,
  event_type     history_event_type NOT NULL,
  event_date     timestamptz NOT NULL DEFAULT now(),
  weight_kg      numeric(8,2) CHECK (weight_kg IS NULL OR weight_kg > 0),
  location_from  text,
  location_to    text,
  previous_owner text,
  new_owner      text,
  previous_value text,
  new_value      text,
  recorded_by    uuid REFERENCES users(id) ON DELETE SET NULL,
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  CHECK (event_type <> 'weight' OR weight_kg IS NOT NULL),
  FOREIGN KEY (tenant_id, animal_id) REFERENCES animals (tenant_id, id)
);

CREATE INDEX idx_animal_history_animal ON animal_history_log (tenant_id, animal_id, event_date DESC);
CREATE INDEX idx_animal_history_type ON animal_history_log (tenant_id, event_type, event_date DESC);

CREATE TRIGGER trg_animal_history_immutable
  BEFORE UPDATE OR DELETE ON animal_history_log
  FOR EACH ROW EXECUTE FUNCTION forbid_mutation();

-- Richer animal record. -----------------------------------------------------
ALTER TABLE animals
  ADD COLUMN rfid_code                  text,
  ADD COLUMN breed_name_raw             text,
  ADD COLUMN origin_source              text,
  ADD COLUMN current_group_id           uuid,
  ADD COLUMN acquisition_date           date,
  ADD COLUMN acquisition_cost           numeric(14,2) CHECK (acquisition_cost IS NULL OR acquisition_cost >= 0),
  ADD COLUMN sale_date                  date,
  ADD COLUMN sale_price                 numeric(14,2) CHECK (sale_price IS NULL OR sale_price >= 0),
  ADD COLUMN current_owner              text,
  ADD COLUMN photo_url                  text,
  ADD COLUMN notes                      text,
  ADD COLUMN date_of_birth_is_estimated boolean NOT NULL DEFAULT false,
  ADD COLUMN is_legacy                  boolean NOT NULL DEFAULT false;

ALTER TABLE animals
  ADD CONSTRAINT animals_tenant_rfid_key UNIQUE (tenant_id, rfid_code),
  ADD CONSTRAINT animals_dob_or_acquisition_chk
    CHECK (date_of_birth IS NOT NULL OR acquisition_date IS NOT NULL OR is_legacy),
  ADD CONSTRAINT animals_tenant_dam_fk
    FOREIGN KEY (tenant_id, dam_id) REFERENCES animals (tenant_id, id),
  ADD CONSTRAINT animals_tenant_sire_fk
    FOREIGN KEY (tenant_id, sire_id) REFERENCES animals (tenant_id, id),
  ADD CONSTRAINT animals_tenant_group_fk
    FOREIGN KEY (tenant_id, current_group_id) REFERENCES groups (tenant_id, id);

-- Required for new records: callers must state species/sex/origin explicitly.
ALTER TABLE animals ALTER COLUMN species DROP DEFAULT;
ALTER TABLE animals ALTER COLUMN sex DROP DEFAULT;
ALTER TABLE animals ALTER COLUMN origin DROP DEFAULT;

CREATE TRIGGER trg_animals_breed_tenant
  BEFORE INSERT OR UPDATE OF breed_id, tenant_id ON animals
  FOR EACH ROW EXECUTE FUNCTION assert_breed_tenant();

CREATE INDEX idx_animals_group ON animals (tenant_id, current_group_id);
CREATE INDEX idx_animals_rfid ON animals (tenant_id, rfid_code) WHERE rfid_code IS NOT NULL;

-- Latest recorded weight per animal.
CREATE VIEW v_animal_current_weight AS
SELECT DISTINCT ON (animal_id)
       animal_id, tenant_id, event_date, weight_kg
FROM animal_history_log
WHERE event_type = 'weight'
  AND weight_kg IS NOT NULL
ORDER BY animal_id, event_date DESC;

-- migrate:down

DROP VIEW IF EXISTS v_animal_current_weight;

DROP TRIGGER IF EXISTS trg_animals_breed_tenant ON animals;
DROP INDEX IF EXISTS idx_animals_rfid;
DROP INDEX IF EXISTS idx_animals_group;

-- Drop dependants before the composite tenant target on animals.
DROP INDEX IF EXISTS idx_animal_history_type;
DROP INDEX IF EXISTS idx_animal_history_animal;
DROP TABLE IF EXISTS animal_history_log;
DROP INDEX IF EXISTS idx_animal_group_history_group;
DROP INDEX IF EXISTS idx_animal_group_history_animal;
DROP TABLE IF EXISTS animal_group_history;

ALTER TABLE animals
  DROP CONSTRAINT IF EXISTS animals_tenant_group_fk,
  DROP CONSTRAINT IF EXISTS animals_tenant_sire_fk,
  DROP CONSTRAINT IF EXISTS animals_tenant_dam_fk,
  DROP CONSTRAINT IF EXISTS animals_dob_or_acquisition_chk,
  DROP CONSTRAINT IF EXISTS animals_tenant_rfid_key,
  DROP CONSTRAINT IF EXISTS animals_tenant_id_id_key;

ALTER TABLE animals
  DROP COLUMN IF EXISTS is_legacy,
  DROP COLUMN IF EXISTS date_of_birth_is_estimated,
  DROP COLUMN IF EXISTS notes,
  DROP COLUMN IF EXISTS photo_url,
  DROP COLUMN IF EXISTS current_owner,
  DROP COLUMN IF EXISTS sale_price,
  DROP COLUMN IF EXISTS sale_date,
  DROP COLUMN IF EXISTS acquisition_cost,
  DROP COLUMN IF EXISTS acquisition_date,
  DROP COLUMN IF EXISTS current_group_id,
  DROP COLUMN IF EXISTS origin_source,
  DROP COLUMN IF EXISTS breed_name_raw,
  DROP COLUMN IF EXISTS rfid_code;

ALTER TABLE animals ALTER COLUMN origin SET DEFAULT 'newborn';
ALTER TABLE animals ALTER COLUMN sex SET DEFAULT 'unknown';
ALTER TABLE animals ALTER COLUMN species SET DEFAULT 'cattle';

DROP TRIGGER IF EXISTS trg_groups_updated ON groups;
DROP TABLE IF EXISTS groups;

DROP FUNCTION IF EXISTS assert_breed_tenant();
DROP FUNCTION IF EXISTS forbid_mutation();
DROP TYPE IF EXISTS history_event_type;
DROP TYPE IF EXISTS group_type;

-- animal_origin / animal_status values added above are intentionally retained;
-- PostgreSQL has no DROP VALUE for enums.
