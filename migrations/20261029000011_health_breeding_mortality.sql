-- migrate:up

-- ---------------------------------------------------------------------------
-- Health scheduling/compliance, medication catalogue, mortality, and the
-- full breeding lifecycle (method/status/births/offspring).
-- ---------------------------------------------------------------------------

ALTER TYPE health_event_type ADD VALUE IF NOT EXISTS 'vet_visit';
ALTER TYPE health_event_type ADD VALUE IF NOT EXISTS 'surgery';

CREATE TYPE health_record_status AS ENUM ('scheduled', 'completed', 'cancelled');

CREATE TYPE breeding_method AS ENUM (
  'natural',
  'artificial_insemination',
  'embryo_transfer'
);

CREATE TYPE breeding_status AS ENUM (
  'planned',
  'confirmed_pregnant',
  'not_pregnant',
  'completed',
  'aborted'
);

CREATE TYPE offspring_outcome AS ENUM (
  'live',
  'stillborn',
  'died_before_weaning',
  'weaned'
);

-- health_records/mortality reference workers; make (tenant_id, id) a target.
ALTER TABLE workers
  ADD CONSTRAINT workers_tenant_id_id_key UNIQUE (tenant_id, id);

-- Medication catalogue (withdrawal periods for food-safety compliance). ------
CREATE TABLE medications (
  id                            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id                     uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  name                          text NOT NULL,
  type                          text,
  manufacturer                  text,
  unit                          text,
  cost_per_unit                 numeric(14,2) CHECK (cost_per_unit IS NULL OR cost_per_unit >= 0),
  withdrawal_period_meat_days   integer CHECK (withdrawal_period_meat_days IS NULL OR withdrawal_period_meat_days >= 0),
  withdrawal_period_milk_days   integer CHECK (withdrawal_period_milk_days IS NULL OR withdrawal_period_milk_days >= 0),
  current_stock                 numeric(14,2) NOT NULL DEFAULT 0,
  notes                         text,
  created_at                    timestamptz NOT NULL DEFAULT now(),
  updated_at                    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, name)
);

CREATE TRIGGER trg_medications_updated BEFORE UPDATE ON medications
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Health records: scheduled vs completed, next due, withdrawal end. ----------
ALTER TABLE health_records
  ADD COLUMN record_status       health_record_status NOT NULL DEFAULT 'completed',
  ADD COLUMN next_due_date       date,
  ADD COLUMN withdrawal_end_date date,
  ADD COLUMN medication_id       uuid,
  ADD COLUMN vet_id              uuid,
  ADD COLUMN is_legacy           boolean NOT NULL DEFAULT false;

ALTER TABLE health_records
  ADD CONSTRAINT health_records_tenant_id_id_key UNIQUE (tenant_id, id),
  ADD CONSTRAINT health_records_tenant_animal_fk
    FOREIGN KEY (tenant_id, animal_id) REFERENCES animals (tenant_id, id),
  ADD CONSTRAINT health_records_tenant_medication_fk
    FOREIGN KEY (tenant_id, medication_id) REFERENCES medications (tenant_id, id),
  ADD CONSTRAINT health_records_tenant_vet_fk
    FOREIGN KEY (tenant_id, vet_id) REFERENCES workers (tenant_id, id),
  ADD CONSTRAINT health_records_scheduled_due_chk
    CHECK (record_status <> 'scheduled' OR next_due_date IS NOT NULL);

CREATE INDEX idx_health_due ON health_records (tenant_id, next_due_date)
  WHERE next_due_date IS NOT NULL;

CREATE VIEW v_health_due AS
SELECT h.id AS health_record_id,
       h.tenant_id,
       h.animal_id,
       a.tag_number,
       a.name AS animal_name,
       h.event_type,
       h.record_status,
       h.next_due_date,
       (h.next_due_date - CURRENT_DATE) AS days_until_due,
       h.vet_id,
       h.medication_id
FROM health_records h
JOIN animals a ON a.id = h.animal_id
WHERE h.record_status = 'scheduled'
  AND h.next_due_date IS NOT NULL
  AND a.status NOT IN ('dead', 'deceased', 'sold', 'transferred', 'archived');

-- Mortality (one row per animal). -------------------------------------------
CREATE TABLE mortality_log (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  animal_id          uuid NOT NULL,
  date_of_death      date NOT NULL,
  cause_of_death     text,
  diagnosed_by       uuid,
  necropsy_performed boolean NOT NULL DEFAULT false,
  disposal_method    text,
  notes              text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, animal_id),
  FOREIGN KEY (tenant_id, animal_id) REFERENCES animals (tenant_id, id),
  FOREIGN KEY (tenant_id, diagnosed_by) REFERENCES workers (tenant_id, id)
);

CREATE INDEX idx_mortality_date ON mortality_log (tenant_id, date_of_death DESC);

CREATE OR REPLACE FUNCTION mark_animal_dead() RETURNS trigger AS $$
BEGIN
  UPDATE animals
     SET status = 'dead'
   WHERE tenant_id = NEW.tenant_id
     AND id = NEW.animal_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mortality_mark_dead
  AFTER INSERT ON mortality_log
  FOR EACH ROW EXECUTE FUNCTION mark_animal_dead();

CREATE VIEW v_mortality_summary AS
SELECT tenant_id,
       date_trunc('month', date_of_death)::date AS month,
       count(*) AS deaths,
       count(*) FILTER (WHERE necropsy_performed) AS necropsies
FROM mortality_log
GROUP BY tenant_id, date_trunc('month', date_of_death);

-- Breeding lifecycle. -------------------------------------------------------
ALTER TABLE breeding_events
  ADD COLUMN breeding_method   breeding_method NOT NULL DEFAULT 'natural',
  ADD COLUMN breeding_status   breeding_status NOT NULL DEFAULT 'planned',
  ADD COLUMN actual_birth_date date,
  ADD COLUMN is_legacy         boolean NOT NULL DEFAULT false;

ALTER TABLE breeding_events
  ADD CONSTRAINT breeding_events_tenant_id_id_key UNIQUE (tenant_id, id),
  ADD CONSTRAINT breeding_events_tenant_dam_fk
    FOREIGN KEY (tenant_id, dam_id) REFERENCES animals (tenant_id, id),
  ADD CONSTRAINT breeding_events_tenant_sire_fk
    FOREIGN KEY (tenant_id, sire_id) REFERENCES animals (tenant_id, id);

CREATE INDEX idx_breeding_due ON breeding_events (tenant_id, expected_due_date)
  WHERE expected_due_date IS NOT NULL;

CREATE VIEW v_breeding_due AS
SELECT b.id AS breeding_event_id,
       b.tenant_id,
       b.dam_id,
       d.tag_number AS dam_tag_number,
       b.sire_id,
       b.breeding_method,
       b.breeding_status,
       b.occurred_at::date AS breeding_date,
       b.expected_due_date,
       (b.expected_due_date - CURRENT_DATE) AS days_until_due
FROM breeding_events b
JOIN animals d ON d.id = b.dam_id
WHERE b.expected_due_date IS NOT NULL
  AND b.breeding_status IN ('planned', 'confirmed_pregnant');

CREATE TABLE birth_records (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  breeding_event_id uuid NOT NULL,
  dam_id            uuid NOT NULL,
  birth_date        date NOT NULL,
  total_offspring   integer CHECK (total_offspring IS NULL OR total_offspring >= 0),
  live_births       integer CHECK (live_births IS NULL OR live_births >= 0),
  stillbirths       integer CHECK (stillbirths IS NULL OR stillbirths >= 0),
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  UNIQUE (tenant_id, breeding_event_id),
  CHECK (total_offspring IS NULL
         OR COALESCE(live_births, 0) + COALESCE(stillbirths, 0) <= total_offspring),
  FOREIGN KEY (tenant_id, breeding_event_id) REFERENCES breeding_events (tenant_id, id),
  FOREIGN KEY (tenant_id, dam_id) REFERENCES animals (tenant_id, id)
);

CREATE INDEX idx_birth_records_dam ON birth_records (tenant_id, dam_id, birth_date DESC);

CREATE TABLE offspring (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  birth_record_id    uuid NOT NULL,
  animal_id          uuid,
  outcome            offspring_outcome NOT NULL,
  birth_weight_kg    numeric(8,2) CHECK (birth_weight_kg IS NULL OR birth_weight_kg > 0),
  weaning_date       date,
  weaning_weight_kg  numeric(8,2) CHECK (weaning_weight_kg IS NULL OR weaning_weight_kg > 0),
  notes              text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, birth_record_id) REFERENCES birth_records (tenant_id, id) ON DELETE CASCADE,
  FOREIGN KEY (tenant_id, animal_id) REFERENCES animals (tenant_id, id)
);

CREATE INDEX idx_offspring_birth ON offspring (tenant_id, birth_record_id);
CREATE INDEX idx_offspring_animal ON offspring (tenant_id, animal_id) WHERE animal_id IS NOT NULL;

-- migrate:down

DROP INDEX IF EXISTS idx_offspring_animal;
DROP INDEX IF EXISTS idx_offspring_birth;
DROP TABLE IF EXISTS offspring;
DROP INDEX IF EXISTS idx_birth_records_dam;
DROP TABLE IF EXISTS birth_records;

DROP VIEW IF EXISTS v_breeding_due;
DROP INDEX IF EXISTS idx_breeding_due;
ALTER TABLE breeding_events
  DROP CONSTRAINT IF EXISTS breeding_events_tenant_sire_fk,
  DROP CONSTRAINT IF EXISTS breeding_events_tenant_dam_fk,
  DROP CONSTRAINT IF EXISTS breeding_events_tenant_id_id_key;
ALTER TABLE breeding_events
  DROP COLUMN IF EXISTS is_legacy,
  DROP COLUMN IF EXISTS actual_birth_date,
  DROP COLUMN IF EXISTS breeding_status,
  DROP COLUMN IF EXISTS breeding_method;

DROP VIEW IF EXISTS v_mortality_summary;
DROP TRIGGER IF EXISTS trg_mortality_mark_dead ON mortality_log;
DROP FUNCTION IF EXISTS mark_animal_dead();
DROP INDEX IF EXISTS idx_mortality_date;
DROP TABLE IF EXISTS mortality_log;

DROP VIEW IF EXISTS v_health_due;
DROP INDEX IF EXISTS idx_health_due;
ALTER TABLE health_records
  DROP CONSTRAINT IF EXISTS health_records_scheduled_due_chk,
  DROP CONSTRAINT IF EXISTS health_records_tenant_vet_fk,
  DROP CONSTRAINT IF EXISTS health_records_tenant_medication_fk,
  DROP CONSTRAINT IF EXISTS health_records_tenant_animal_fk,
  DROP CONSTRAINT IF EXISTS health_records_tenant_id_id_key;
ALTER TABLE health_records
  DROP COLUMN IF EXISTS is_legacy,
  DROP COLUMN IF EXISTS vet_id,
  DROP COLUMN IF EXISTS medication_id,
  DROP COLUMN IF EXISTS withdrawal_end_date,
  DROP COLUMN IF EXISTS next_due_date,
  DROP COLUMN IF EXISTS record_status;

DROP TRIGGER IF EXISTS trg_medications_updated ON medications;
DROP TABLE IF EXISTS medications;

ALTER TABLE workers DROP CONSTRAINT IF EXISTS workers_tenant_id_id_key;

DROP TYPE IF EXISTS offspring_outcome;
DROP TYPE IF EXISTS breeding_status;
DROP TYPE IF EXISTS breeding_method;
DROP TYPE IF EXISTS health_record_status;

-- health_event_type values added above are intentionally retained.
