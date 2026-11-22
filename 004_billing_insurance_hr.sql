-- 004_billing_insurance_hr.sql
BEGIN;

-- ---------- Billing ----------
CREATE TABLE tax_rates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  name        text NOT NULL,
  rate_pct    numeric(5,2) NOT NULL CHECK (rate_pct BETWEEN 0 AND 100),
  applies_to  text NOT NULL DEFAULT 'all',        -- all / pharmacy / lab / room ...
  is_active   boolean NOT NULL DEFAULT true,
  UNIQUE (hospital_id, name)
);

CREATE TABLE service_charges (          -- price list for room, procedures, OT, etc.
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  code        text NOT NULL,
  name        text NOT NULL,
  category    text NOT NULL CHECK (category IN ('consultation','lab','radiology','pharmacy','operation','room','procedure','other')),
  price       numeric(12,2) NOT NULL CHECK (price >= 0),
  is_active   boolean NOT NULL DEFAULT true,
  UNIQUE (hospital_id, code)
);

CREATE TABLE invoice_counters (
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  year        int  NOT NULL,
  last_value  bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (hospital_id, year)
);
CREATE OR REPLACE FUNCTION next_invoice_number(p_hospital uuid) RETURNS text AS $$
DECLARE v bigint; y int := extract(year FROM now())::int;
BEGIN
  INSERT INTO invoice_counters(hospital_id, year, last_value) VALUES (p_hospital, y, 1)
  ON CONFLICT (hospital_id, year) DO UPDATE SET last_value = invoice_counters.last_value + 1
  RETURNING last_value INTO v;
  RETURN 'INV-' || y || '-' || lpad(v::text, 6, '0');
END; $$ LANGUAGE plpgsql;

CREATE TABLE invoices (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id   uuid NOT NULL REFERENCES hospitals(id),
  branch_id     uuid REFERENCES branches(id),
  invoice_number text NOT NULL,
  patient_id    uuid NOT NULL REFERENCES patients(id),
  encounter_id  uuid REFERENCES encounters(id),
  admission_id  uuid REFERENCES admissions(id),
  invoice_type  text NOT NULL CHECK (invoice_type IN ('opd','ipd','emergency','pharmacy','lab','radiology','other')),
  status        text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','issued','partially_paid','paid','void','refunded')),
  subtotal      numeric(14,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  discount      numeric(14,2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  tax           numeric(14,2) NOT NULL DEFAULT 0 CHECK (tax >= 0),
  total         numeric(14,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
  amount_paid   numeric(14,2) NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  insurance_covered numeric(14,2) NOT NULL DEFAULT 0 CHECK (insurance_covered >= 0),
  due_date      date,
  created_by    uuid REFERENCES users(id),
  issued_at     timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hospital_id, invoice_number),
  CHECK (discount <= subtotal),
  CHECK (total = subtotal - discount + tax),
  CHECK (amount_paid + insurance_covered <= total)           -- cannot overpay an invoice
);
CREATE INDEX idx_inv_patient ON invoices(patient_id, created_at DESC);
CREATE INDEX idx_inv_outstanding ON invoices(hospital_id, due_date) WHERE status IN ('issued','partially_paid');

CREATE TABLE invoice_lines (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  invoice_id  uuid NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  category    text NOT NULL CHECK (category IN ('consultation','lab','radiology','pharmacy','operation','room','procedure','other')),
  description text NOT NULL,
  quantity    numeric(10,2) NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_price  numeric(12,2) NOT NULL CHECK (unit_price >= 0),
  line_total  numeric(14,2) GENERATED ALWAYS AS (round(quantity * unit_price, 2)) STORED,
  source_type text,                      -- lab_order, radiology_order, pharmacy_sale, ...
  source_id   uuid
);
CREATE INDEX idx_invline_invoice ON invoice_lines(invoice_id);

CREATE TABLE payments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  branch_id   uuid REFERENCES branches(id),
  invoice_id  uuid NOT NULL REFERENCES invoices(id),
  receipt_number text NOT NULL,
  method      text NOT NULL CHECK (method IN ('cash','card','bank_transfer','mobile_wallet','online','insurance','cheque')),
  amount      numeric(14,2) NOT NULL CHECK (amount > 0),
  reference   text,                      -- gateway transaction id / cheque number
  received_by uuid REFERENCES users(id),
  paid_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hospital_id, receipt_number)
);
CREATE INDEX idx_pay_invoice ON payments(invoice_id);
CREATE INDEX idx_pay_day ON payments(branch_id, paid_at);

CREATE TABLE refunds (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  payment_id  uuid NOT NULL REFERENCES payments(id),
  amount      numeric(14,2) NOT NULL CHECK (amount > 0),
  reason      text NOT NULL,
  approved_by uuid NOT NULL REFERENCES users(id),
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Keep invoice.amount_paid and status in sync with payments/refunds inside the database.
CREATE OR REPLACE FUNCTION recompute_invoice_paid(p_invoice uuid) RETURNS void AS $$
DECLARE paid numeric(14,2); refunded numeric(14,2); inv invoices%ROWTYPE; net numeric(14,2);
BEGIN
  SELECT * INTO inv FROM invoices WHERE id = p_invoice FOR UPDATE;
  SELECT COALESCE(sum(amount),0) INTO paid FROM payments WHERE invoice_id = p_invoice;
  SELECT COALESCE(sum(r.amount),0) INTO refunded
    FROM refunds r JOIN payments p ON p.id = r.payment_id WHERE p.invoice_id = p_invoice;
  net := paid - refunded;
  UPDATE invoices SET
    amount_paid = net,
    status = CASE
      WHEN status IN ('draft','void') THEN status
      WHEN net = 0 AND refunded > 0 THEN 'refunded'
      WHEN net + insurance_covered >= total AND total > 0 THEN 'paid'
      WHEN net > 0 THEN 'partially_paid'
      ELSE 'issued' END
  WHERE id = p_invoice;
END; $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION trg_payment_sync() RETURNS trigger AS $$
BEGIN PERFORM recompute_invoice_paid(NEW.invoice_id); RETURN NEW; END; $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_payments_sync AFTER INSERT ON payments FOR EACH ROW EXECUTE FUNCTION trg_payment_sync();

CREATE OR REPLACE FUNCTION trg_refund_sync() RETURNS trigger AS $$
DECLARE inv uuid; pay numeric; already numeric;
BEGIN
  SELECT invoice_id, amount INTO inv, pay FROM payments WHERE id = NEW.payment_id;
  SELECT COALESCE(sum(amount),0) INTO already FROM refunds WHERE payment_id = NEW.payment_id AND id <> NEW.id;
  IF already + NEW.amount > pay THEN
    RAISE EXCEPTION 'refund exceeds original payment amount';
  END IF;
  PERFORM recompute_invoice_paid(inv);
  RETURN NEW;
END; $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_refunds_sync AFTER INSERT ON refunds FOR EACH ROW EXECUTE FUNCTION trg_refund_sync();

CREATE TABLE cash_sessions (            -- cashier shift open/close for cash management
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  branch_id    uuid NOT NULL REFERENCES branches(id),
  cashier_id   uuid NOT NULL REFERENCES users(id),
  opening_float numeric(14,2) NOT NULL DEFAULT 0 CHECK (opening_float >= 0),
  closing_counted numeric(14,2),
  opened_at    timestamptz NOT NULL DEFAULT now(),
  closed_at    timestamptz
);
CREATE UNIQUE INDEX uq_cash_open ON cash_sessions(cashier_id) WHERE closed_at IS NULL;

CREATE TABLE expenses (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  branch_id   uuid REFERENCES branches(id),
  category    text NOT NULL,
  description text,
  amount      numeric(14,2) NOT NULL CHECK (amount > 0),
  incurred_on date NOT NULL DEFAULT current_date,
  recorded_by uuid REFERENCES users(id)
);
CREATE INDEX idx_expense_day ON expenses(hospital_id, incurred_on);

-- ---------- Insurance ----------
CREATE TABLE insurance_companies (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  name        text NOT NULL,
  contact_phone text,
  contact_email citext,
  is_active   boolean NOT NULL DEFAULT true,
  UNIQUE (hospital_id, name)
);

CREATE TABLE patient_insurance (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  patient_id  uuid NOT NULL REFERENCES patients(id),
  company_id  uuid NOT NULL REFERENCES insurance_companies(id),
  policy_number text NOT NULL,
  member_id   text,
  coverage_pct numeric(5,2) NOT NULL DEFAULT 100 CHECK (coverage_pct BETWEEN 0 AND 100),
  coverage_limit numeric(14,2) CHECK (coverage_limit >= 0),
  valid_from  date NOT NULL,
  valid_to    date NOT NULL,
  verified_at timestamptz,
  verified_by uuid REFERENCES users(id),
  CHECK (valid_to >= valid_from),
  UNIQUE (company_id, policy_number, patient_id)
);
CREATE INDEX idx_pins_patient ON patient_insurance(patient_id);

CREATE TABLE insurance_claims (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  claim_number text NOT NULL,
  invoice_id  uuid NOT NULL REFERENCES invoices(id),
  patient_insurance_id uuid NOT NULL REFERENCES patient_insurance(id),
  claimed_amount numeric(14,2) NOT NULL CHECK (claimed_amount > 0),
  approved_amount numeric(14,2) CHECK (approved_amount >= 0),
  status      text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','submitted','under_review','approved','partially_approved','rejected','paid')),
  rejection_reason text,
  submitted_at timestamptz,
  resolved_at  timestamptz,
  created_by  uuid REFERENCES users(id),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hospital_id, claim_number),
  CHECK (approved_amount IS NULL OR approved_amount <= claimed_amount)
);
CREATE INDEX idx_claim_status ON insurance_claims(hospital_id, status);

CREATE TABLE insurance_claim_events (     -- status history for claim tracking
  id         bigserial PRIMARY KEY,
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  claim_id   uuid NOT NULL REFERENCES insurance_claims(id) ON DELETE CASCADE,
  from_status text,
  to_status  text NOT NULL,
  note       text,
  changed_by uuid REFERENCES users(id),
  changed_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION trg_claim_history() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO insurance_claim_events(hospital_id, claim_id, from_status, to_status)
    VALUES (NEW.hospital_id, NEW.id, CASE WHEN TG_OP='UPDATE' THEN OLD.status END, NEW.status);
  END IF;
  RETURN NEW;
END; $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_claims_hist AFTER INSERT OR UPDATE ON insurance_claims FOR EACH ROW EXECUTE FUNCTION trg_claim_history();

-- ---------- HR ----------
CREATE TABLE shifts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  name        text NOT NULL,
  start_time  time NOT NULL,
  end_time    time NOT NULL,
  UNIQUE (hospital_id, name)
);

CREATE TABLE duty_roster (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  employee_id uuid NOT NULL REFERENCES employees(id),
  shift_id    uuid NOT NULL REFERENCES shifts(id),
  duty_date   date NOT NULL,
  department_id uuid REFERENCES departments(id),
  UNIQUE (employee_id, duty_date, shift_id)
);

CREATE TABLE attendance (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  employee_id uuid NOT NULL REFERENCES employees(id),
  work_date   date NOT NULL,
  check_in    timestamptz,
  check_out   timestamptz,
  status      text NOT NULL DEFAULT 'present' CHECK (status IN ('present','absent','late','half_day','on_leave')),
  UNIQUE (employee_id, work_date),
  CHECK (check_out IS NULL OR check_in IS NULL OR check_out >= check_in)
);

CREATE TABLE leave_requests (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  employee_id uuid NOT NULL REFERENCES employees(id),
  leave_type  text NOT NULL CHECK (leave_type IN ('annual','sick','casual','unpaid','maternity','other')),
  start_date  date NOT NULL,
  end_date    date NOT NULL,
  reason      text,
  status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','cancelled')),
  decided_by  uuid REFERENCES users(id),
  decided_at  timestamptz,
  CHECK (end_date >= start_date)
);

CREATE TABLE payroll_runs (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  period_month date NOT NULL CHECK (period_month = date_trunc('month', period_month)::date),
  status      text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','approved','paid')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hospital_id, period_month)
);

CREATE TABLE payslips (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  payroll_run_id uuid NOT NULL REFERENCES payroll_runs(id) ON DELETE CASCADE,
  employee_id uuid NOT NULL REFERENCES employees(id),
  base_salary numeric(12,2) NOT NULL CHECK (base_salary >= 0),
  allowances  numeric(12,2) NOT NULL DEFAULT 0 CHECK (allowances >= 0),
  deductions  numeric(12,2) NOT NULL DEFAULT 0 CHECK (deductions >= 0),
  net_pay     numeric(12,2) GENERATED ALWAYS AS (base_salary + allowances - deductions) STORED,
  UNIQUE (payroll_run_id, employee_id)
);

CREATE TABLE performance_reviews (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  employee_id uuid NOT NULL REFERENCES employees(id),
  reviewer_id uuid REFERENCES users(id),
  period_start date NOT NULL,
  period_end   date NOT NULL,
  rating      smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comments    text,
  CHECK (period_end >= period_start)
);

CREATE TRIGGER trg_invoices_upd BEFORE UPDATE ON invoices FOR EACH ROW EXECUTE FUNCTION set_updated_at();

INSERT INTO schema_migrations(version) VALUES ('004_billing_insurance_hr');
COMMIT;
