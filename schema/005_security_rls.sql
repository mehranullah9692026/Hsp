-- 005_security_rls.sql : database-enforced tenant isolation + least-privilege application role
BEGIN;

-- The API sets these per request/transaction, after authenticating the user:
--   SELECT set_config('app.hospital_id', '<uuid>', true);
--   SELECT set_config('app.is_super_admin', 'false', true);
CREATE OR REPLACE FUNCTION app_hospital_id() RETURNS uuid AS $$
  SELECT NULLIF(current_setting('app.hospital_id', true), '')::uuid;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION app_is_super() RETURNS boolean AS $$
  SELECT COALESCE(current_setting('app.is_super_admin', true), 'false') = 'true';
$$ LANGUAGE sql STABLE;

-- Application login role is a member of hms_app. It is NOT a superuser and does NOT bypass RLS.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hms_app') THEN
    CREATE ROLE hms_app NOLOGIN;
  END IF;
END $$;

-- Auth/global tables are read by the authentication service before a tenant context exists,
-- so they are excluded from the generic policy and protected by app-layer + GRANTs instead.
-- (hospitals is handled separately below.)
DO $$
DECLARE t record;
  excluded text[] := ARRAY['users','user_roles','sessions','role_permissions','roles','permissions',
                           'audit_logs','hospitals','schema_migrations','device_tokens','drug_interactions',
                           'token_counters'];
BEGIN
  FOR t IN
    SELECT c.table_name
    FROM information_schema.columns c
    JOIN information_schema.tables tb ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
    WHERE c.table_schema = 'public' AND c.column_name = 'hospital_id' AND tb.table_type = 'BASE TABLE'
      AND c.table_name <> ALL (excluded)
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t.table_name);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t.table_name);
    EXECUTE format($p$CREATE POLICY tenant_isolation ON %I
                      USING (app_is_super() OR hospital_id = app_hospital_id())
                      WITH CHECK (app_is_super() OR hospital_id = app_hospital_id())$p$, t.table_name);
  END LOOP;
END $$;

-- hospitals: a tenant sees only itself
ALTER TABLE hospitals ENABLE ROW LEVEL SECURITY;
ALTER TABLE hospitals FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON hospitals
  USING (app_is_super() OR id = app_hospital_id())
  WITH CHECK (app_is_super());

-- audit_logs: anyone may append; tenants read only their own rows
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_insert ON audit_logs FOR INSERT WITH CHECK (true);
CREATE POLICY audit_select ON audit_logs FOR SELECT
  USING (app_is_super() OR hospital_id = app_hospital_id());

-- Privileges for the application role (least privilege)
GRANT USAGE ON SCHEMA public TO hms_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO hms_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO hms_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO hms_app;
REVOKE UPDATE, DELETE ON audit_logs, stock_movements, insurance_claim_events FROM hms_app;
REVOKE ALL ON schema_migrations FROM hms_app;

INSERT INTO schema_migrations(version) VALUES ('005_security_rls');
COMMIT;
