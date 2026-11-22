-- 002_clinical.sql : patients, doctors, appointments, encounters, wards/beds, IPD, ER, OT
BEGIN;

-- ---------- MRN generation (per hospital, gap-tolerant, race-safe) ----------
CREATE TABLE mrn_counters (
  hospital_id uuid PRIMARY KEY REFERENCES hospitals(id),
  last_value  bigint NOT NULL DEFAULT 0
);
CREATE OR REPLACE FUNCTION next_mrn(p_hospital uuid) RETURNS text AS $$
DECLARE v bigint;
BEGIN
  INSERT INTO mrn_counters(hospital_id,last_value) VALUES (p_hospital,1)
  ON CONFLICT (hospital_id) DO UPDATE SET last_value = mrn_counters.last_value + 1
  RETURNING last_value INTO v;
  RETURN 'MRN-' || lpad(v::text, 8, '0');
END; $$ LANGUAGE plpgsql;

-- ---------- Patients ----------
CREATE TABLE patients (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id   uuid NOT NULL REFERENCES hospitals(id),
  branch_id     uuid REFERENCES branches(id),
  user_id       uuid REFERENCES users(id),              -- linked portal account (optional)
  mrn           text NOT NULL,
  first_name    text NOT NULL,
  last_name     text,
  gender        text NOT NULL CHECK (gender IN ('male','female','other','unknown')),
  date_of_birth date,
  national_id_enc bytea,                                -- encrypted by app layer
  phone         text,
  email         citext,
  address       text,
  city          text,
  blood_group   text CHECK (blood_group IN ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
  marital_status text,
  photo_key     text,                                   -- object-storage key
  emergency_contact_name  text,
  emergency_contact_phone text,
  emergency_contact_relation text,
  is_deceased   boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,
  UNIQUE (hospital_id, mrn)
);
CREATE INDEX idx_patients_name_trgm ON patients USING gin ((first_name || ' ' || coalesce(last_name,'')) gin_trgm_ops);
CREATE INDEX idx_patients_phone ON patients(hospital_id, phone);
CREATE INDEX idx_patients_dob ON patients(hospital_id, date_of_birth);

ALTER TABLE consent_records
  ADD CONSTRAINT fk_consent_patient FOREIGN KEY (patient_id) REFERENCES patients(id);

CREATE TABLE patient_allergies (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  patient_id  uuid NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
  allergen    text NOT NULL,                 -- free text or generic drug name
  reaction    text,
  severity    text CHECK (severity IN ('mild','moderate','severe','life_threatening')),
  recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_allergy_patient ON patient_allergies(patient_id);

CREATE TABLE patient_medical_history (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  patient_id  uuid NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
  category    text NOT NULL CHECK (category IN ('chronic','surgical','family','social','immunization','other')),
  description text NOT NULL,
  onset_date  date,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_pmh_patient ON patient_medical_history(patient_id);

CREATE TABLE patient_documents (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  patient_id  uuid NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
  uploaded_by uuid REFERENCES users(id),
  doc_type    text NOT NULL,
  file_name   text NOT NULL,
  object_key  text NOT NULL,
  mime_type   text NOT NULL,
  size_bytes  bigint NOT NULL CHECK (size_bytes > 0),
  sha256      char(64),
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_pdoc_patient ON patient_documents(patient_id);

-- ---------- Doctors & staff ----------
CREATE TABLE doctors (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id      uuid NOT NULL REFERENCES hospitals(id),
  branch_id        uuid REFERENCES branches(id),
  user_id          uuid NOT NULL UNIQUE REFERENCES users(id),
  department_id    uuid REFERENCES departments(id),
  license_number   text NOT NULL,
  specialization   text,
  qualifications   text,
  is_specialist    boolean NOT NULL DEFAULT false,
  consultation_fee numeric(12,2) NOT NULL DEFAULT 0 CHECK (consultation_fee >= 0),
  followup_fee     numeric(12,2) NOT NULL DEFAULT 0 CHECK (followup_fee >= 0),
  slot_minutes     int NOT NULL DEFAULT 15 CHECK (slot_minutes BETWEEN 5 AND 120),
  is_active        boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hospital_id, license_number)
);
CREATE INDEX idx_doctors_dept ON doctors(department_id);

CREATE TABLE doctor_schedules (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  doctor_id   uuid NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
  branch_id   uuid REFERENCES branches(id),
  weekday     smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),   -- 0 = Sunday
  start_time  time NOT NULL,
  end_time    time NOT NULL,
  max_patients int,
  CHECK (end_time > start_time)
);
CREATE INDEX idx_sched_doctor ON doctor_schedules(doctor_id, weekday);

CREATE TABLE doctor_time_off (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  doctor_id   uuid NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
  starts_at   timestamptz NOT NULL,
  ends_at     timestamptz NOT NULL,
  reason      text,
  CHECK (ends_at > starts_at)
);

CREATE TABLE employees (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id   uuid NOT NULL REFERENCES hospitals(id),
  branch_id     uuid REFERENCES branches(id),
  user_id       uuid UNIQUE REFERENCES users(id),
  department_id uuid REFERENCES departments(id),
  employee_code text NOT NULL,
  designation   text NOT NULL,
  hire_date     date NOT NULL,
  termination_date date,
  base_salary   numeric(12,2) NOT NULL DEFAULT 0 CHECK (base_salary >= 0),
  status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active','on_leave','terminated')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hospital_id, employee_code)
);

-- ---------- Appointments ----------
CREATE TABLE appointments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  branch_id    uuid REFERENCES branches(id),
  patient_id   uuid NOT NULL REFERENCES patients(id),
  doctor_id    uuid NOT NULL REFERENCES doctors(id),
  department_id uuid REFERENCES departments(id),
  source       text NOT NULL DEFAULT 'reception' CHECK (source IN ('online','walk_in','reception','phone','followup')),
  scheduled_at timestamptz NOT NULL,
  duration_min int NOT NULL DEFAULT 15 CHECK (duration_min > 0),
  status       text NOT NULL DEFAULT 'booked'
               CHECK (status IN ('booked','confirmed','checked_in','in_consultation','completed','cancelled','no_show','rescheduled')),
  token_number int,
  reason       text,
  cancel_reason text,
  rescheduled_from uuid REFERENCES appointments(id),
  created_by   uuid REFERENCES users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
-- A doctor cannot be double-booked for the same start instant while the slot is active.
CREATE UNIQUE INDEX uq_appt_doctor_slot ON appointments(doctor_id, scheduled_at)
  WHERE status IN ('booked','confirmed','checked_in','in_consultation');
CREATE INDEX idx_appt_patient ON appointments(patient_id, scheduled_at DESC);
CREATE INDEX idx_appt_doctor_day ON appointments(doctor_id, scheduled_at);
CREATE INDEX idx_appt_branch_day ON appointments(branch_id, scheduled_at);

-- Token numbers: one per doctor per local day
CREATE TABLE token_counters (
  doctor_id  uuid NOT NULL REFERENCES doctors(id),
  day        date NOT NULL,
  last_value int  NOT NULL DEFAULT 0,
  PRIMARY KEY (doctor_id, day)
);
CREATE OR REPLACE FUNCTION next_token(p_doctor uuid, p_day date) RETURNS int AS $$
DECLARE v int;
BEGIN
  INSERT INTO token_counters(doctor_id, day, last_value) VALUES (p_doctor, p_day, 1)
  ON CONFLICT (doctor_id, day) DO UPDATE SET last_value = token_counters.last_value + 1
  RETURNING last_value INTO v;
  RETURN v;
END; $$ LANGUAGE plpgsql;

-- ---------- Encounters (OPD / IPD / ER visit header) ----------
CREATE TABLE encounters (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  branch_id    uuid REFERENCES branches(id),
  patient_id   uuid NOT NULL REFERENCES patients(id),
  doctor_id    uuid REFERENCES doctors(id),
  appointment_id uuid REFERENCES appointments(id),
  encounter_type text NOT NULL CHECK (encounter_type IN ('opd','ipd','emergency')),
  status       text NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed','cancelled')),
  chief_complaint text,
  started_at   timestamptz NOT NULL DEFAULT now(),
  ended_at     timestamptz,
  CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE INDEX idx_enc_patient ON encounters(patient_id, started_at DESC);
CREATE INDEX idx_enc_open ON encounters(hospital_id, encounter_type) WHERE status = 'open';

CREATE TABLE vitals (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  encounter_id uuid NOT NULL REFERENCES encounters(id) ON DELETE CASCADE,
  patient_id   uuid NOT NULL REFERENCES patients(id),
  recorded_by  uuid REFERENCES users(id),
  recorded_at  timestamptz NOT NULL DEFAULT now(),
  temperature_c numeric(4,1) CHECK (temperature_c BETWEEN 25 AND 45),
  pulse_bpm    int CHECK (pulse_bpm BETWEEN 0 AND 300),
  resp_rate    int CHECK (resp_rate BETWEEN 0 AND 100),
  systolic_bp  int CHECK (systolic_bp BETWEEN 0 AND 350),
  diastolic_bp int CHECK (diastolic_bp BETWEEN 0 AND 250),
  spo2_pct     int CHECK (spo2_pct BETWEEN 0 AND 100),
  weight_kg    numeric(5,1) CHECK (weight_kg > 0),
  height_cm    numeric(5,1) CHECK (height_cm > 0),
  glucose_mgdl numeric(5,1)
);
CREATE INDEX idx_vitals_enc ON vitals(encounter_id, recorded_at DESC);

CREATE TABLE clinical_notes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  encounter_id uuid NOT NULL REFERENCES encounters(id) ON DELETE CASCADE,
  patient_id   uuid NOT NULL REFERENCES patients(id),
  author_id    uuid NOT NULL REFERENCES users(id),
  note_type    text NOT NULL CHECK (note_type IN ('examination','progress','nursing','doctor_round','operation','discharge','general')),
  body         text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_notes_enc ON clinical_notes(encounter_id, created_at);

CREATE TABLE diagnoses (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  encounter_id uuid NOT NULL REFERENCES encounters(id) ON DELETE CASCADE,
  patient_id   uuid NOT NULL REFERENCES patients(id),
  icd10_code   text,
  description  text NOT NULL,
  is_primary   boolean NOT NULL DEFAULT false,
  diagnosed_by uuid REFERENCES users(id),
  diagnosed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_dx_patient ON diagnoses(patient_id, diagnosed_at DESC);
CREATE UNIQUE INDEX uq_dx_one_primary ON diagnoses(encounter_id) WHERE is_primary;

CREATE TABLE treatment_plans (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  encounter_id uuid NOT NULL REFERENCES encounters(id) ON DELETE CASCADE,
  patient_id   uuid NOT NULL REFERENCES patients(id),
  plan         text NOT NULL,
  follow_up_date date,
  created_by   uuid REFERENCES users(id),
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE referrals (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  patient_id   uuid NOT NULL REFERENCES patients(id),
  encounter_id uuid REFERENCES encounters(id),
  from_doctor_id uuid NOT NULL REFERENCES doctors(id),
  to_doctor_id uuid REFERENCES doctors(id),
  to_department_id uuid REFERENCES departments(id),
  external_facility text,
  reason       text NOT NULL,
  status       text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','completed','declined')),
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------- Medicines (catalog needed by prescriptions) ----------
CREATE TABLE medicines (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id   uuid NOT NULL REFERENCES hospitals(id),
  generic_name  text NOT NULL,
  brand_name    text,
  form          text,                     -- tablet, syrup, injection...
  strength      text,
  barcode       text,
  unit_price    numeric(12,2) NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
  reorder_level int NOT NULL DEFAULT 10 CHECK (reorder_level >= 0),
  is_controlled boolean NOT NULL DEFAULT false,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_medicine_barcode ON medicines(hospital_id, barcode) WHERE barcode IS NOT NULL;
CREATE INDEX idx_medicine_generic ON medicines USING gin (generic_name gin_trgm_ops);
CREATE INDEX idx_medicine_brand ON medicines USING gin (brand_name gin_trgm_ops);

CREATE TABLE drug_interactions (
  medicine_a_generic text NOT NULL,
  medicine_b_generic text NOT NULL,
  severity text NOT NULL CHECK (severity IN ('minor','moderate','major','contraindicated')),
  note     text,
  PRIMARY KEY (medicine_a_generic, medicine_b_generic),
  CHECK (medicine_a_generic < medicine_b_generic)    -- store each pair once, alphabetically
);

CREATE TABLE prescriptions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  encounter_id uuid NOT NULL REFERENCES encounters(id),
  patient_id   uuid NOT NULL REFERENCES patients(id),
  doctor_id    uuid NOT NULL REFERENCES doctors(id),
  status       text NOT NULL DEFAULT 'active' CHECK (status IN ('active','dispensed','partially_dispensed','cancelled','expired')),
  notes        text,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_rx_patient ON prescriptions(patient_id, created_at DESC);

CREATE TABLE prescription_items (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id     uuid NOT NULL REFERENCES hospitals(id),
  prescription_id uuid NOT NULL REFERENCES prescriptions(id) ON DELETE CASCADE,
  medicine_id     uuid NOT NULL REFERENCES medicines(id),
  dose            text NOT NULL,
  frequency       text NOT NULL,
  duration_days   int CHECK (duration_days > 0),
  quantity        int NOT NULL CHECK (quantity > 0),
  quantity_dispensed int NOT NULL DEFAULT 0 CHECK (quantity_dispensed >= 0),
  instructions    text,
  CHECK (quantity_dispensed <= quantity)
);
CREATE INDEX idx_rxitem_rx ON prescription_items(prescription_id);

-- ---------- Wards & beds ----------
CREATE TABLE wards (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  branch_id   uuid NOT NULL REFERENCES branches(id),
  name        text NOT NULL,
  ward_type   text NOT NULL CHECK (ward_type IN ('general','private','icu','nicu','isolation','emergency','maternity')),
  floor       text,
  is_active   boolean NOT NULL DEFAULT true,
  UNIQUE (branch_id, name)
);

CREATE TABLE beds (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  ward_id     uuid NOT NULL REFERENCES wards(id),
  bed_number  text NOT NULL,
  daily_rate  numeric(12,2) NOT NULL DEFAULT 0 CHECK (daily_rate >= 0),
  status      text NOT NULL DEFAULT 'available'
              CHECK (status IN ('available','occupied','reserved','cleaning','maintenance')),
  is_active   boolean NOT NULL DEFAULT true,
  UNIQUE (ward_id, bed_number)
);
CREATE INDEX idx_beds_status ON beds(ward_id, status);

CREATE TABLE admissions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id    uuid NOT NULL REFERENCES hospitals(id),
  branch_id      uuid REFERENCES branches(id),
  patient_id     uuid NOT NULL REFERENCES patients(id),
  encounter_id   uuid NOT NULL REFERENCES encounters(id),
  attending_doctor_id uuid NOT NULL REFERENCES doctors(id),
  bed_id         uuid NOT NULL REFERENCES beds(id),
  admitted_at    timestamptz NOT NULL DEFAULT now(),
  admission_reason text,
  status         text NOT NULL DEFAULT 'admitted' CHECK (status IN ('admitted','discharged','transferred_out','deceased')),
  discharged_at  timestamptz,
  discharge_summary text,
  CHECK (discharged_at IS NULL OR discharged_at >= admitted_at)
);
CREATE INDEX idx_adm_patient ON admissions(patient_id, admitted_at DESC);
-- One patient cannot hold two concurrent admissions; one bed cannot hold two concurrent patients.
CREATE UNIQUE INDEX uq_adm_patient_active ON admissions(patient_id) WHERE status = 'admitted';
CREATE UNIQUE INDEX uq_adm_bed_active ON admissions(bed_id) WHERE status = 'admitted';

CREATE TABLE bed_transfers (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  admission_id uuid NOT NULL REFERENCES admissions(id),
  from_bed_id  uuid NOT NULL REFERENCES beds(id),
  to_bed_id    uuid NOT NULL REFERENCES beds(id),
  transferred_at timestamptz NOT NULL DEFAULT now(),
  transferred_by uuid REFERENCES users(id),
  reason       text,
  CHECK (from_bed_id <> to_bed_id)
);

CREATE TABLE medication_administrations (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  admission_id uuid NOT NULL REFERENCES admissions(id),
  prescription_item_id uuid NOT NULL REFERENCES prescription_items(id),
  scheduled_for timestamptz NOT NULL,
  administered_at timestamptz,
  administered_by uuid REFERENCES users(id),
  status       text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','given','held','refused','missed')),
  note         text
);
CREATE INDEX idx_mar_adm ON medication_administrations(admission_id, scheduled_for);

-- ---------- Emergency ----------
CREATE TABLE emergency_cases (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id   uuid NOT NULL REFERENCES hospitals(id),
  branch_id     uuid REFERENCES branches(id),
  patient_id    uuid REFERENCES patients(id),         -- may be unknown on arrival
  encounter_id  uuid REFERENCES encounters(id),
  temp_identity text,                                  -- "Unknown male ~40y" until identified
  arrival_mode  text CHECK (arrival_mode IN ('walk_in','ambulance','police','referral')),
  triage_level  smallint NOT NULL CHECK (triage_level BETWEEN 1 AND 5),   -- 1 = resuscitation
  complaint     text NOT NULL,
  assigned_doctor_id uuid REFERENCES doctors(id),
  is_critical   boolean NOT NULL DEFAULT false,
  disposition   text CHECK (disposition IN ('treated_discharged','admitted','transferred','referred','left_without_being_seen','deceased')),
  arrived_at    timestamptz NOT NULL DEFAULT now(),
  closed_at     timestamptz,
  CHECK (patient_id IS NOT NULL OR temp_identity IS NOT NULL)
);
CREATE INDEX idx_er_open ON emergency_cases(hospital_id, triage_level, arrived_at) WHERE closed_at IS NULL;

-- ---------- Operation theatre ----------
CREATE TABLE operation_theatres (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  branch_id   uuid NOT NULL REFERENCES branches(id),
  name        text NOT NULL,
  is_active   boolean NOT NULL DEFAULT true,
  UNIQUE (branch_id, name)
);

CREATE TABLE operations (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id    uuid NOT NULL REFERENCES hospitals(id),
  patient_id     uuid NOT NULL REFERENCES patients(id),
  admission_id   uuid REFERENCES admissions(id),
  theatre_id     uuid NOT NULL REFERENCES operation_theatres(id),
  surgeon_id     uuid NOT NULL REFERENCES doctors(id),
  anesthetist_id uuid REFERENCES doctors(id),
  procedure_name text NOT NULL,
  scheduled_start timestamptz NOT NULL,
  scheduled_end   timestamptz NOT NULL,
  actual_start   timestamptz,
  actual_end     timestamptz,
  status         text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','in_progress','completed','cancelled','postponed')),
  preop_checklist jsonb NOT NULL DEFAULT '{}',
  anesthesia_record text,
  operation_notes text,
  postop_monitoring text,
  CHECK (scheduled_end > scheduled_start)
);
-- Theatre cannot be double-booked: overlapping active time ranges are rejected by the database itself.
ALTER TABLE operations ADD CONSTRAINT ex_ot_no_overlap
  EXCLUDE USING gist (theatre_id WITH =, tstzrange(scheduled_start, scheduled_end) WITH &&)
  WHERE (status IN ('scheduled','in_progress'));
ALTER TABLE operations ADD CONSTRAINT ex_surgeon_no_overlap
  EXCLUDE USING gist (surgeon_id WITH =, tstzrange(scheduled_start, scheduled_end) WITH &&)
  WHERE (status IN ('scheduled','in_progress'));

CREATE TABLE operation_team (
  operation_id uuid NOT NULL REFERENCES operations(id) ON DELETE CASCADE,
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  user_id      uuid NOT NULL REFERENCES users(id),
  team_role    text NOT NULL,
  PRIMARY KEY (operation_id, user_id)
);

-- updated_at triggers
CREATE TRIGGER trg_patients_upd  BEFORE UPDATE ON patients  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_doctors_upd   BEFORE UPDATE ON doctors   FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_employees_upd BEFORE UPDATE ON employees FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_appt_upd      BEFORE UPDATE ON appointments FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_medicines_upd BEFORE UPDATE ON medicines FOR EACH ROW EXECUTE FUNCTION set_updated_at();

INSERT INTO schema_migrations(version) VALUES ('002_clinical');
COMMIT;
