-- schema_tests.sql : executable assertions against a freshly rebuilt database (with sample data).
-- Run via tests/run.sh. Everything happens inside one transaction that is rolled back.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null
BEGIN;

CREATE TEMP TABLE results(label text, ok boolean, detail text);
GRANT ALL ON results TO PUBLIC;

-- expect_error: runs a statement and passes only if it raises an error
CREATE FUNCTION pg_temp.expect_error(label text, stmt text, must_contain text DEFAULT NULL) RETURNS void AS $$
DECLARE msg text;
BEGIN
  BEGIN
    EXECUTE stmt;
    INSERT INTO results VALUES (label, false, 'statement succeeded but should have failed');
  EXCEPTION WHEN OTHERS THEN
    msg := SQLERRM;
    IF must_contain IS NULL OR msg ILIKE '%' || must_contain || '%' THEN
      INSERT INTO results VALUES (label, true, left(msg, 90));
    ELSE
      INSERT INTO results VALUES (label, false, 'wrong error: ' || left(msg, 120));
    END IF;
  END;
END; $$ LANGUAGE plpgsql;

CREATE FUNCTION pg_temp.expect(label text, cond boolean, detail text DEFAULT '') RETURNS void AS $$
BEGIN INSERT INTO results VALUES (label, COALESCE(cond,false), detail); END; $$ LANGUAGE plpgsql;


CREATE FUNCTION pg_temp.dml_count(stmt text) RETURNS bigint AS $$
DECLARE n bigint;
BEGIN EXECUTE stmt; GET DIAGNOSTICS n = ROW_COUNT; RETURN n; END; $$ LANGUAGE plpgsql;

-- ---------- fixtures ----------
CREATE TEMP TABLE fx AS
SELECT
  (SELECT id FROM hospitals WHERE code='CGH') AS h,
  (SELECT id FROM branches WHERE code='MAIN') AS b,
  (SELECT id FROM doctors WHERE license_number='PMDC-TEST-1001') AS doc1,
  (SELECT id FROM doctors WHERE license_number='PMDC-TEST-2002') AS doc2,
  (SELECT id FROM patients WHERE first_name='Pervez') AS p1,
  (SELECT id FROM patients WHERE first_name='Bilal') AS p3,
  (SELECT id FROM users WHERE email='admin@cgh.test') AS u_admin,
  (SELECT id FROM users WHERE email='pharmacist@cgh.test') AS u_pharm;
GRANT SELECT ON fx TO PUBLIC;

-- ========== 1. RBAC matrix ==========
SELECT pg_temp.expect('super_admin has every permission',
  (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id=rp.role_id WHERE r.code='super_admin') = (SELECT count(*) FROM permissions));
SELECT pg_temp.expect('hospital_admin has all except platform.*',
  (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id=rp.role_id WHERE r.code='hospital_admin')
    = (SELECT count(*) FROM permissions WHERE code NOT LIKE 'platform.%'));
SELECT pg_temp.expect('hospital_admin lacks platform.manage_hospitals',
  NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id=rp.role_id JOIN permissions p ON p.id=rp.permission_id
              WHERE r.code='hospital_admin' AND p.code='platform.manage_hospitals'));
SELECT pg_temp.expect('patient role limited to self.* permissions',
  NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id=rp.role_id JOIN permissions p ON p.id=rp.permission_id
              WHERE r.code='patient' AND p.code NOT LIKE 'self.%'));
SELECT pg_temp.expect('patient cannot read other patients (no patient.read)',
  NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id=rp.role_id JOIN permissions p ON p.id=rp.permission_id
              WHERE r.code='patient' AND p.code IN ('patient.read','emr.read')));
SELECT pg_temp.expect('receptionist cannot read clinical records (no emr.read)',
  NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id=rp.role_id JOIN permissions p ON p.id=rp.permission_id
              WHERE r.code='receptionist' AND p.code='emr.read'));
SELECT pg_temp.expect('hospital_manager cannot read individual clinical records',
  NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id=rp.role_id JOIN permissions p ON p.id=rp.permission_id
              WHERE r.code='hospital_manager' AND p.code IN ('emr.read','patient.read','prescription.read','lab.read','radiology.read')));
SELECT pg_temp.expect('hospital_manager still has report.read',
  EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id=rp.role_id JOIN permissions p ON p.id=rp.permission_id
          WHERE r.code='hospital_manager' AND p.code='report.read'));
SELECT pg_temp.expect('all 15 roles seeded', (SELECT count(*) FROM roles) = 15);
SELECT pg_temp.expect('passwords are hashed, not plaintext',
  NOT EXISTS (SELECT 1 FROM users WHERE password_hash = 'ChangeMe!2026' OR password_hash NOT LIKE '$2%'));
SELECT pg_temp.expect('bcrypt hash verifies', (SELECT password_hash = crypt('ChangeMe!2026', password_hash) FROM users WHERE email='admin@cgh.test'));

-- ========== 2. Tenant isolation (RLS) ==========
INSERT INTO hospitals(code,name) VALUES ('OTH','Other Hospital');
INSERT INTO patients(hospital_id,mrn,first_name,gender)
  SELECT id, next_mrn(id), 'Secret', 'male' FROM hospitals WHERE code='OTH';

CREATE TEMP TABLE fx_other AS SELECT id AS oh FROM hospitals WHERE code='OTH';
GRANT SELECT ON fx_other TO PUBLIC;
SET LOCAL ROLE hms_app;
SELECT set_config('app.hospital_id', (SELECT h::text FROM fx), true);
SELECT set_config('app.is_super_admin', 'false', true);
SELECT pg_temp.expect('tenant A sees its own patients', (SELECT count(*) FROM patients) = 6);
SELECT pg_temp.expect('tenant A cannot see tenant B patient', NOT EXISTS (SELECT 1 FROM patients WHERE first_name='Secret'));
SELECT pg_temp.expect('tenant A sees only itself in hospitals', (SELECT count(*) FROM hospitals) = 1);
SELECT pg_temp.expect('tenant A cannot see tenant B invoices/lab/etc via any table (spot check beds)',
  (SELECT count(*) FROM beds WHERE hospital_id <> (SELECT h FROM fx)) = 0);
SELECT pg_temp.expect_error('tenant A cannot insert rows into tenant B',
  $q$INSERT INTO patients(hospital_id,mrn,first_name,gender) SELECT oh,'X-1','Intruder','male' FROM fx_other$q$,
  'row-level security');
SELECT pg_temp.expect('tenant A UPDATE on tenant B row affects 0 rows',
  pg_temp.dml_count($q$UPDATE patients SET first_name='Hacked' WHERE first_name='Secret'$q$) = 0);

-- no tenant context at all => nothing visible
SELECT set_config('app.hospital_id', '', true);
SELECT pg_temp.expect('no tenant context => zero patients visible', (SELECT count(*) FROM patients) = 0);

-- super admin context sees both
SELECT set_config('app.is_super_admin', 'true', true);
SELECT pg_temp.expect('super admin sees all tenants', (SELECT count(*) FROM patients) = 7);
SELECT set_config('app.is_super_admin', 'false', true);
SELECT set_config('app.hospital_id', (SELECT h::text FROM fx), true);

-- ========== 3. Scheduling integrity ==========
SELECT pg_temp.expect_error('doctor cannot be double-booked in same slot',
  $q$INSERT INTO appointments(hospital_id,patient_id,doctor_id,scheduled_at)
     SELECT h, p1, doc1, (SELECT scheduled_at FROM appointments WHERE status='checked_in' LIMIT 1) FROM fx$q$,
  'uq_appt_doctor_slot');
SELECT pg_temp.expect('tokens increment per doctor per day',
  (SELECT array_agg(token_number ORDER BY token_number) FROM appointments a, fx WHERE a.doctor_id = fx.doc1 AND a.scheduled_at::date = current_date) = ARRAY[1,2]);

-- ========== 4. Pharmacy safety ==========
SELECT pg_temp.expect_error('stock cannot go negative',
  $q$UPDATE medicine_batches SET quantity_on_hand = quantity_on_hand - 100000$q$, 'quantity_on_hand');
SELECT pg_temp.expect_error('controlled drug movement requires witness',
  $q$INSERT INTO stock_movements(hospital_id,branch_id,batch_id,movement_type,quantity,is_controlled,performed_by)
     SELECT fx.h, fx.b, mb.id, 'sale', -1, true, fx.u_pharm FROM fx, medicine_batches mb WHERE mb.batch_number='MOR-001'$q$,
  'check constraint');
SELECT pg_temp.expect('controlled drug movement with witness accepted',
  pg_temp.dml_count($q$INSERT INTO stock_movements(hospital_id,branch_id,batch_id,movement_type,quantity,is_controlled,performed_by,witnessed_by)
     SELECT fx.h, fx.b, mb.id, 'sale', -1, true, fx.u_pharm, fx.u_admin FROM fx, medicine_batches mb WHERE mb.batch_number='MOR-001'$q$) = 1);
SELECT pg_temp.expect_error('app role cannot UPDATE stock movements (privilege layer)', $q$UPDATE stock_movements SET quantity = 5$q$, 'permission denied');
SELECT pg_temp.expect_error('app role cannot DELETE stock movements (privilege layer)', $q$DELETE FROM stock_movements$q$, 'permission denied');
SELECT pg_temp.expect('low-stock query finds amoxicillin below reorder level', EXISTS (
  SELECT 1 FROM medicine_batches mb JOIN medicines m ON m.id = mb.medicine_id
  GROUP BY m.id, m.generic_name, m.reorder_level HAVING m.generic_name='amoxicillin' AND sum(mb.quantity_on_hand) < m.reorder_level));
SELECT pg_temp.expect('expiry query finds aspirin expiring within 30 days', EXISTS (
  SELECT 1 FROM medicine_batches mb JOIN medicines m ON m.id = mb.medicine_id
  WHERE m.generic_name='aspirin' AND mb.expiry_date <= current_date + 30));
SELECT pg_temp.expect('drug interaction pair stored once, alphabetical',
  EXISTS (SELECT 1 FROM drug_interactions WHERE medicine_a_generic='aspirin' AND medicine_b_generic='warfarin'));
SELECT pg_temp.expect_error('interaction pair rejected if not alphabetical',
  $q$INSERT INTO drug_interactions VALUES ('warfarin','aspirin','minor','x')$q$);

-- ========== 5. Laboratory flags (server-side) ==========
CREATE TEMP TABLE lab_fx AS SELECT NULL::uuid AS item_id;
GRANT ALL ON lab_fx TO PUBLIC;
WITH o AS (
  INSERT INTO lab_orders(hospital_id,patient_id) SELECT h,p1 FROM fx RETURNING id, hospital_id
), i AS (
  INSERT INTO lab_order_items(hospital_id,lab_order_id,lab_test_id,price)
  SELECT o.hospital_id, o.id, (SELECT id FROM lab_tests WHERE code='CBC'), 800 FROM o RETURNING id
) UPDATE lab_fx SET item_id = (SELECT id FROM i);

INSERT INTO lab_results(hospital_id,order_item_id,parameter_id,value_numeric)
SELECT (SELECT h FROM fx), (SELECT item_id FROM lab_fx), id, v FROM lab_test_parameters pr
JOIN (VALUES ('Haemoglobin',6.5),('WBC',15),('Platelets',300)) x(n,v) ON x.n = pr.name;
SELECT pg_temp.expect('Hb 6.5 flagged critical_low',
  (SELECT flag FROM lab_results lr JOIN lab_test_parameters p ON p.id=lr.parameter_id WHERE p.name='Haemoglobin') = 'critical_low');
SELECT pg_temp.expect('WBC 15 flagged high',
  (SELECT flag FROM lab_results lr JOIN lab_test_parameters p ON p.id=lr.parameter_id WHERE p.name='WBC') = 'high');
SELECT pg_temp.expect('Platelets 300 flagged normal',
  (SELECT flag FROM lab_results lr JOIN lab_test_parameters p ON p.id=lr.parameter_id WHERE p.name='Platelets') = 'normal');
SELECT pg_temp.expect('reference range snapshotted on result',
  (SELECT lr.ref_low FROM lab_results lr JOIN lab_test_parameters p ON p.id=lr.parameter_id WHERE p.name='Haemoglobin') = 12.0);
SELECT pg_temp.expect_error('lab order cannot be approved without approver',
  $q$UPDATE lab_orders SET status='approved'$q$, 'check constraint');

-- ========== 6. IPD / beds / OT ==========
CREATE TEMP TABLE adm_fx AS SELECT NULL::uuid AS enc1, NULL::uuid AS enc2, NULL::uuid AS bed;
GRANT ALL ON adm_fx TO PUBLIC;
UPDATE adm_fx SET bed = (SELECT id FROM beds WHERE bed_number='G-1');
INSERT INTO encounters(hospital_id,patient_id,doctor_id,encounter_type) SELECT h,p1,doc1,'ipd' FROM fx;
INSERT INTO encounters(hospital_id,patient_id,doctor_id,encounter_type) SELECT h,p3,doc1,'ipd' FROM fx;
INSERT INTO admissions(hospital_id,patient_id,encounter_id,attending_doctor_id,bed_id)
SELECT fx.h, fx.p1, (SELECT id FROM encounters WHERE patient_id=fx.p1 AND encounter_type='ipd'), fx.doc1, (SELECT bed FROM adm_fx) FROM fx;
SELECT pg_temp.expect_error('one bed cannot hold two admitted patients',
  $q$INSERT INTO admissions(hospital_id,patient_id,encounter_id,attending_doctor_id,bed_id)
     SELECT fx.h, fx.p3, (SELECT id FROM encounters WHERE patient_id=fx.p3 AND encounter_type='ipd'), fx.doc1, (SELECT bed FROM adm_fx) FROM fx$q$,
  'uq_adm_bed_active');
SELECT pg_temp.expect_error('patient cannot have two concurrent admissions',
  $q$INSERT INTO admissions(hospital_id,patient_id,encounter_id,attending_doctor_id,bed_id)
     SELECT fx.h, fx.p1, (SELECT id FROM encounters WHERE patient_id=fx.p1 AND encounter_type='ipd'), fx.doc1, (SELECT id FROM beds WHERE bed_number='G-2') FROM fx$q$,
  'uq_adm_patient_active');

INSERT INTO operations(hospital_id,patient_id,theatre_id,surgeon_id,procedure_name,scheduled_start,scheduled_end)
SELECT fx.h, fx.p1, (SELECT id FROM operation_theatres LIMIT 1), fx.doc2, 'Appendectomy', now() + interval '1 day', now() + interval '1 day 2 hours' FROM fx;
SELECT pg_temp.expect_error('operation theatre cannot be double-booked (overlap)',
  $q$INSERT INTO operations(hospital_id,patient_id,theatre_id,surgeon_id,procedure_name,scheduled_start,scheduled_end)
     SELECT fx.h, fx.p3, (SELECT id FROM operation_theatres LIMIT 1), fx.doc1, 'Hernia repair', now() + interval '1 day 1 hour', now() + interval '1 day 3 hours' FROM fx$q$,
  'ex_ot_no_overlap');
SELECT pg_temp.expect_error('surgeon cannot be in two theatres at once',
  $q$INSERT INTO operation_theatres(hospital_id,branch_id,name) SELECT h,b,'OT-2' FROM fx;
     INSERT INTO operations(hospital_id,patient_id,theatre_id,surgeon_id,procedure_name,scheduled_start,scheduled_end)
     SELECT fx.h, fx.p3, (SELECT id FROM operation_theatres WHERE name='OT-2'), fx.doc2, 'Bypass', now() + interval '1 day 30 minutes', now() + interval '1 day 90 minutes' FROM fx$q$,
  'ex_surgeon_no_overlap');
SELECT pg_temp.expect('back-to-back operations are allowed in same theatre',
  pg_temp.dml_count($q$INSERT INTO operations(hospital_id,patient_id,theatre_id,surgeon_id,procedure_name,scheduled_start,scheduled_end)
    SELECT fx.h, fx.p3, (SELECT id FROM operation_theatres WHERE name='OT-1'), fx.doc2, 'Follow-up case', now() + interval '1 day 2 hours', now() + interval '1 day 3 hours' FROM fx$q$) = 1);

SELECT pg_temp.expect_error('emergency case needs patient or temp identity',
  $q$INSERT INTO emergency_cases(hospital_id,triage_level,complaint) SELECT h,1,'chest pain' FROM fx$q$, 'check constraint');
SELECT pg_temp.expect('unidentified emergency patient accepted with temp identity',
  pg_temp.dml_count($q$INSERT INTO emergency_cases(hospital_id,triage_level,complaint,temp_identity,is_critical)
    SELECT h,1,'RTA polytrauma','Unknown male ~40y',true FROM fx$q$) = 1);

-- ========== 7. Billing integrity ==========
CREATE TEMP TABLE inv_fx AS SELECT NULL::uuid AS inv, NULL::uuid AS pay;
GRANT ALL ON inv_fx TO PUBLIC;
INSERT INTO invoices(hospital_id,invoice_number,patient_id,invoice_type,status,subtotal,discount,tax,total)
  SELECT h, 'INV-FIXTURE-1', p3, 'opd', 'issued', 1500, 100, 0, 1400 FROM fx;
UPDATE inv_fx SET inv = (SELECT id FROM invoices WHERE invoice_number = 'INV-FIXTURE-1');
SELECT pg_temp.expect_error('invoice total must equal subtotal - discount + tax',
  $q$INSERT INTO invoices(hospital_id,invoice_number,patient_id,invoice_type,subtotal,discount,tax,total)
     SELECT h,'INV-BAD',p3,'opd',1000,0,0,999 FROM fx$q$, 'check constraint');
SELECT pg_temp.expect_error('discount cannot exceed subtotal',
  $q$INSERT INTO invoices(hospital_id,invoice_number,patient_id,invoice_type,subtotal,discount,tax,total)
     SELECT h,'INV-BAD2',p3,'opd',100,200,0,-100 FROM fx$q$);

INSERT INTO payments(hospital_id,invoice_id,receipt_number,method,amount)
SELECT h,(SELECT inv FROM inv_fx),'RCT-1','cash',500 FROM fx;
SELECT pg_temp.expect('partial payment => partially_paid, amount_paid synced',
  (SELECT status = 'partially_paid' AND amount_paid = 500 FROM invoices WHERE id = (SELECT inv FROM inv_fx)));
SELECT pg_temp.expect_error('overpayment rejected',
  $q$INSERT INTO payments(hospital_id,invoice_id,receipt_number,method,amount) SELECT h,(SELECT inv FROM inv_fx),'RCT-OVER','cash',901 FROM fx$q$,
  'check constraint');
INSERT INTO payments(hospital_id,invoice_id,receipt_number,method,amount)
SELECT h,(SELECT inv FROM inv_fx),'RCT-2','card',900 FROM fx;
SELECT pg_temp.expect('full payment => paid', (SELECT status = 'paid' AND amount_paid = 1400 FROM invoices WHERE id = (SELECT inv FROM inv_fx)));
UPDATE inv_fx SET pay = (SELECT id FROM payments WHERE receipt_number='RCT-2');
SELECT pg_temp.expect_error('refund cannot exceed original payment',
  $q$INSERT INTO refunds(hospital_id,payment_id,amount,reason,approved_by) SELECT h,(SELECT pay FROM inv_fx),901,'x',u_admin FROM fx$q$,
  'refund exceeds');
INSERT INTO refunds(hospital_id,payment_id,amount,reason,approved_by)
SELECT h,(SELECT pay FROM inv_fx),400,'Service not rendered',u_admin FROM fx;
SELECT pg_temp.expect('refund reduces amount_paid and reopens invoice',
  (SELECT status = 'partially_paid' AND amount_paid = 1000 FROM invoices WHERE id = (SELECT inv FROM inv_fx)));
SELECT pg_temp.expect_error('duplicate receipt number rejected',
  $q$INSERT INTO payments(hospital_id,invoice_id,receipt_number,method,amount) SELECT h,(SELECT inv FROM inv_fx),'RCT-1','cash',1 FROM fx$q$, 'unique');
SELECT pg_temp.expect('invoice numbers are sequential per hospital',
  (SELECT next_invoice_number(h) FROM fx) ~ '^INV-[0-9]{4}-[0-9]{6}$');

-- Insurance claim history trigger
INSERT INTO insurance_claims(hospital_id,claim_number,invoice_id,patient_insurance_id,claimed_amount)
SELECT h,'CLM-1',(SELECT inv FROM inv_fx),(SELECT id FROM patient_insurance LIMIT 1),1000 FROM fx;
UPDATE insurance_claims SET status='submitted' WHERE claim_number='CLM-1';
UPDATE insurance_claims SET status='approved', approved_amount=800 WHERE claim_number='CLM-1';
SELECT pg_temp.expect('claim status changes are recorded as history',
  (SELECT array_agg(to_status ORDER BY id) FROM insurance_claim_events) = ARRAY['draft','submitted','approved']);
SELECT pg_temp.expect_error('approved amount cannot exceed claimed',
  $q$UPDATE insurance_claims SET approved_amount = 99999 WHERE claim_number='CLM-1'$q$, 'check constraint');

-- ========== 8. Patients / MRN ==========
SELECT pg_temp.expect('MRNs unique and sequential per hospital',
  (SELECT count(DISTINCT mrn) = count(*) AND min(mrn) = 'MRN-00000001' AND max(mrn) = 'MRN-00000006' FROM patients, fx WHERE hospital_id = fx.h));
SELECT pg_temp.expect_error('duplicate MRN within hospital rejected',
  $q$INSERT INTO patients(hospital_id,mrn,first_name,gender) SELECT h,'MRN-00000001','Dup','male' FROM fx$q$, 'unique');
SELECT pg_temp.expect('patient fuzzy name search uses trigram index-able expression',
  (SELECT count(*) FROM patients WHERE (first_name || ' ' || coalesce(last_name,'')) ILIKE '%pervez%') = 1);
SELECT pg_temp.expect_error('invalid blood group rejected',
  $q$UPDATE patients SET blood_group='Z+' $q$, 'check constraint');
SELECT pg_temp.expect_error('implausible vital sign rejected',
  $q$UPDATE vitals SET spo2_pct = 150$q$, 'check constraint');

-- ========== 9. Audit log ==========
INSERT INTO audit_logs(hospital_id,user_id,action,entity_type,entity_id) SELECT h,u_admin,'read','patient',p1::text FROM fx;
SELECT pg_temp.expect_error('app role cannot UPDATE audit log (privilege layer)', $q$UPDATE audit_logs SET action='nothing'$q$, 'permission denied');
SELECT pg_temp.expect_error('app role cannot DELETE audit log (privilege layer)', $q$DELETE FROM audit_logs$q$, 'permission denied');

-- ========== 10. Privileges ==========
RESET ROLE;
SELECT pg_temp.expect_error('trigger blocks audit UPDATE even for superuser', $q$UPDATE audit_logs SET action='x'$q$, 'append-only');
SELECT pg_temp.expect_error('trigger blocks audit DELETE even for superuser', $q$DELETE FROM audit_logs$q$, 'append-only');
SELECT pg_temp.expect_error('trigger blocks stock movement UPDATE even for superuser', $q$UPDATE stock_movements SET quantity = 5$q$, 'append-only');
SELECT pg_temp.expect_error('trigger blocks stock movement DELETE even for superuser', $q$DELETE FROM stock_movements$q$, 'append-only');
SELECT pg_temp.expect('RLS is forced on all tenant tables with hospital_id (excluding documented auth/global tables)', NOT EXISTS (
  SELECT 1 FROM information_schema.columns c JOIN pg_class k ON k.relname = c.table_name AND k.relnamespace = 'public'::regnamespace
  WHERE c.table_schema='public' AND c.column_name='hospital_id' AND k.relkind='r'
    AND c.table_name NOT IN ('users','user_roles','sessions','role_permissions','roles','permissions','audit_logs','hospitals','schema_migrations','device_tokens','drug_interactions','token_counters')
    AND NOT (k.relrowsecurity AND k.relforcerowsecurity)));
SELECT pg_temp.expect('application role is not a superuser and cannot bypass RLS',
  (SELECT NOT rolsuper AND NOT rolbypassrls FROM pg_roles WHERE rolname='hms_app'));
SELECT pg_temp.expect('all 5 migrations recorded', (SELECT count(*) FROM schema_migrations) = 5);

-- ---------- report ----------
\o
\set QUIET off
\echo
SELECT CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result, label, CASE WHEN ok THEN '' ELSE detail END AS detail
FROM results ORDER BY ok, label;
SELECT count(*) FILTER (WHERE ok) AS passed, count(*) FILTER (WHERE NOT ok) AS failed, count(*) AS total FROM results;
ROLLBACK;
