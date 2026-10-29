-- migrate:up

-- ---------------------------------------------------------------------------
-- Workforce: typed roles, schedules and task assignments.
-- ---------------------------------------------------------------------------

CREATE TYPE worker_role AS ENUM ('owner', 'manager', 'worker', 'vet');

CREATE TYPE task_status AS ENUM ('pending', 'in_progress', 'completed', 'cancelled');

CREATE TYPE priority AS ENUM ('low', 'medium', 'high', 'critical');

ALTER TABLE workers
  ADD COLUMN email      citext,
  ADD COLUMN role       worker_role,
  ADD COLUMN salary     numeric(14,2) CHECK (salary IS NULL OR salary >= 0),
  ADD COLUMN notes      text,
  ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN is_legacy  boolean NOT NULL DEFAULT false;

-- Derive a role for existing rows from the legacy free-text title.
UPDATE workers
   SET role = CASE
     WHEN role_title ILIKE '%vet%'     THEN 'vet'::worker_role
     WHEN role_title ILIKE '%owner%'   THEN 'owner'::worker_role
     WHEN role_title ILIKE '%manager%' THEN 'manager'::worker_role
     ELSE 'worker'::worker_role
   END
 WHERE role IS NULL;

UPDATE workers
   SET hired_date = created_at::date
 WHERE hired_date IS NULL;

UPDATE workers
   SET is_legacy = true
 WHERE role_title IS NOT NULL;

ALTER TABLE workers
  ALTER COLUMN role SET NOT NULL,
  ADD CONSTRAINT workers_tenant_email_key UNIQUE (tenant_id, email);

CREATE TRIGGER trg_workers_updated BEFORE UPDATE ON workers
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_workers_role ON workers (tenant_id, role);

-- Attendance is tenant-consistent with its worker.
ALTER TABLE attendance
  ADD CONSTRAINT attendance_tenant_worker_fk
    FOREIGN KEY (tenant_id, worker_id) REFERENCES workers (tenant_id, id) ON DELETE CASCADE;

CREATE TABLE work_schedules (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  worker_id      uuid NOT NULL,
  shift_date     date NOT NULL,
  start_time     time,
  end_time       time,
  role_for_shift text,
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  CHECK (end_time IS NULL OR start_time IS NULL OR end_time > start_time),
  FOREIGN KEY (tenant_id, worker_id) REFERENCES workers (tenant_id, id) ON DELETE CASCADE
);

CREATE INDEX idx_work_schedules_worker
  ON work_schedules (tenant_id, worker_id, shift_date DESC);

CREATE TABLE task_assignments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  worker_id         uuid NOT NULL,
  task_title        text NOT NULL,
  description       text,
  related_animal_id uuid,
  related_group_id  uuid,
  assigned_by       uuid REFERENCES users(id) ON DELETE SET NULL,
  due_date          date,
  status            task_status NOT NULL DEFAULT 'pending',
  priority          priority NOT NULL DEFAULT 'medium',
  completed_at      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, id),
  FOREIGN KEY (tenant_id, worker_id) REFERENCES workers (tenant_id, id),
  FOREIGN KEY (tenant_id, related_animal_id) REFERENCES animals (tenant_id, id),
  FOREIGN KEY (tenant_id, related_group_id) REFERENCES groups (tenant_id, id)
);

CREATE TRIGGER trg_task_assignments_updated BEFORE UPDATE ON task_assignments
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_task_assignments_worker
  ON task_assignments (tenant_id, worker_id, status);
CREATE INDEX idx_task_assignments_due
  ON task_assignments (tenant_id, due_date) WHERE status IN ('pending', 'in_progress');

-- migrate:down

DROP INDEX IF EXISTS idx_task_assignments_due;
DROP INDEX IF EXISTS idx_task_assignments_worker;
DROP TRIGGER IF EXISTS trg_task_assignments_updated ON task_assignments;
DROP TABLE IF EXISTS task_assignments;
DROP INDEX IF EXISTS idx_work_schedules_worker;
DROP TABLE IF EXISTS work_schedules;

ALTER TABLE attendance DROP CONSTRAINT IF EXISTS attendance_tenant_worker_fk;

DROP INDEX IF EXISTS idx_workers_role;
DROP TRIGGER IF EXISTS trg_workers_updated ON workers;
ALTER TABLE workers
  DROP CONSTRAINT IF EXISTS workers_tenant_email_key;
ALTER TABLE workers
  DROP COLUMN IF EXISTS is_legacy,
  DROP COLUMN IF EXISTS updated_at,
  DROP COLUMN IF EXISTS notes,
  DROP COLUMN IF EXISTS salary,
  DROP COLUMN IF EXISTS role,
  DROP COLUMN IF EXISTS email;

DROP TYPE IF EXISTS priority;
DROP TYPE IF EXISTS task_status;
DROP TYPE IF EXISTS worker_role;
