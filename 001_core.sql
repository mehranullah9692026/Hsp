-- 001_core.sql : tenancy, identity, RBAC, audit, consent
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE schema_migrations (
  version     text PRIMARY KEY,
  applied_at  timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$ LANGUAGE plpgsql;

-- ---------- Tenancy ----------
CREATE TABLE hospitals (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  legal_name  text,
  tax_number  text,
  phone       text,
  email       citext,
  address     text,
  country     text NOT NULL DEFAULT 'PK',
  currency    char(3) NOT NULL DEFAULT 'PKR',
  timezone    text NOT NULL DEFAULT 'Asia/Karachi',
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE branches (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  code        text NOT NULL,
  name        text NOT NULL,
  address     text,
  phone       text,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hospital_id, code),
  UNIQUE (hospital_id, id)
);

CREATE TABLE departments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  branch_id   uuid REFERENCES branches(id),
  code        text NOT NULL,
  name        text NOT NULL,
  is_clinical boolean NOT NULL DEFAULT true,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hospital_id, code)
);

-- ---------- RBAC ----------
CREATE TABLE roles (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,
  name        text NOT NULL,
  description text,
  is_system   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE permissions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,          -- e.g. patient.read
  module      text NOT NULL,
  description text
);

-- hospital_id NULL = global default; non-NULL = hospital-specific override (configurable permissions)
CREATE TABLE role_permissions (
  role_id       uuid NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  permission_id uuid NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
  hospital_id   uuid REFERENCES hospitals(id),
  granted       boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_role_permissions
  ON role_permissions (role_id, permission_id, COALESCE(hospital_id, '00000000-0000-0000-0000-000000000000'::uuid));

-- ---------- Users ----------
CREATE TABLE users (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id        uuid REFERENCES hospitals(id),     -- NULL only for super admins
  email              citext NOT NULL UNIQUE,
  phone              text,
  full_name          text NOT NULL,
  password_hash      text NOT NULL,                      -- argon2/bcrypt, never plaintext
  status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended','pending','deleted')),
  mfa_enabled        boolean NOT NULL DEFAULT false,
  mfa_secret_enc     bytea,                              -- encrypted by app layer
  failed_login_count int NOT NULL DEFAULT 0,
  locked_until       timestamptz,
  last_login_at      timestamptz,
  password_changed_at timestamptz,
  preferred_locale   text NOT NULL DEFAULT 'en' CHECK (preferred_locale IN ('en','ur','ar')),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  deleted_at         timestamptz
);
CREATE INDEX idx_users_hospital ON users(hospital_id);

CREATE TABLE user_roles (
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id     uuid NOT NULL REFERENCES roles(id),
  hospital_id uuid REFERENCES hospitals(id),
  branch_id   uuid REFERENCES branches(id),   -- NULL = all branches of the hospital
  PRIMARY KEY (user_id, role_id)
);

CREATE TABLE sessions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  refresh_token_hash text NOT NULL,
  ip_address         inet,
  user_agent         text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  expires_at         timestamptz NOT NULL,
  revoked_at         timestamptz
);
CREATE INDEX idx_sessions_user ON sessions(user_id) WHERE revoked_at IS NULL;

-- ---------- Audit (append-only) ----------
CREATE TABLE audit_logs (
  id          bigserial PRIMARY KEY,
  hospital_id uuid,
  user_id     uuid,
  action      text NOT NULL,              -- read / create / update / delete / login / export ...
  entity_type text NOT NULL,
  entity_id   text,
  ip_address  inet,
  details     jsonb NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_hospital_time ON audit_logs(hospital_id, created_at DESC);
CREATE INDEX idx_audit_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_user ON audit_logs(user_id, created_at DESC);

CREATE OR REPLACE FUNCTION audit_logs_immutable() RETURNS trigger AS $$
BEGIN RAISE EXCEPTION 'audit_logs is append-only'; END; $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_audit_no_update BEFORE UPDATE OR DELETE ON audit_logs
  FOR EACH ROW EXECUTE FUNCTION audit_logs_immutable();

-- ---------- Notifications ----------
CREATE TABLE notifications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  user_id     uuid REFERENCES users(id),
  channel     text NOT NULL CHECK (channel IN ('push','sms','email','whatsapp','in_app')),
  category    text NOT NULL,              -- appointment_reminder, lab_result, payment_due, emergency ...
  title       text NOT NULL,
  body        text NOT NULL,
  status      text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','sent','failed','read')),
  error       text,
  scheduled_at timestamptz NOT NULL DEFAULT now(),
  sent_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_notif_user ON notifications(user_id, created_at DESC);
CREATE INDEX idx_notif_queue ON notifications(scheduled_at) WHERE status = 'queued';

CREATE TABLE device_tokens (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token      text NOT NULL UNIQUE,
  platform   text NOT NULL CHECK (platform IN ('android','ios','web')),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- Privacy ----------
CREATE TABLE consent_records (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  user_id     uuid REFERENCES users(id),
  patient_id  uuid,                        -- FK added in 002 once patients exists
  consent_type text NOT NULL,              -- privacy_policy, treatment, data_sharing, marketing
  version     text NOT NULL,
  granted     boolean NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE data_deletion_requests (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  user_id     uuid NOT NULL REFERENCES users(id),
  reason      text,
  status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','completed')),
  legal_hold_note text,                    -- medical records may need statutory retention
  requested_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

CREATE TRIGGER trg_hospitals_upd BEFORE UPDATE ON hospitals FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_branches_upd  BEFORE UPDATE ON branches  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_depts_upd     BEFORE UPDATE ON departments FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_users_upd     BEFORE UPDATE ON users     FOR EACH ROW EXECUTE FUNCTION set_updated_at();

INSERT INTO schema_migrations(version) VALUES ('001_core');
COMMIT;
