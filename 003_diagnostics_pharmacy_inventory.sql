-- 003_diagnostics_pharmacy_inventory.sql
BEGIN;

-- ---------- Suppliers ----------
CREATE TABLE suppliers (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  name        text NOT NULL,
  contact_name text,
  phone       text,
  email       citext,
  address     text,
  tax_number  text,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hospital_id, name)
);

-- ---------- Laboratory ----------
CREATE TABLE lab_tests (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  code        text NOT NULL,
  name        text NOT NULL,
  category    text,
  sample_type text,                    -- blood, urine, swab...
  price       numeric(12,2) NOT NULL DEFAULT 0 CHECK (price >= 0),
  turnaround_hours int,
  is_active   boolean NOT NULL DEFAULT true,
  UNIQUE (hospital_id, code)
);

CREATE TABLE lab_test_parameters (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id   uuid NOT NULL REFERENCES hospitals(id),
  lab_test_id   uuid NOT NULL REFERENCES lab_tests(id) ON DELETE CASCADE,
  name          text NOT NULL,
  unit          text,
  ref_low       numeric,
  ref_high      numeric,
  gender        text CHECK (gender IN ('male','female','any')) DEFAULT 'any',
  critical_low  numeric,
  critical_high numeric,
  sort_order    int NOT NULL DEFAULT 0,
  CHECK (ref_low IS NULL OR ref_high IS NULL OR ref_low <= ref_high)
);
CREATE INDEX idx_labparam_test ON lab_test_parameters(lab_test_id);

CREATE TABLE lab_orders (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  branch_id    uuid REFERENCES branches(id),
  patient_id   uuid NOT NULL REFERENCES patients(id),
  encounter_id uuid REFERENCES encounters(id),
  ordered_by   uuid REFERENCES doctors(id),
  priority     text NOT NULL DEFAULT 'routine' CHECK (priority IN ('routine','urgent','stat')),
  status       text NOT NULL DEFAULT 'ordered'
               CHECK (status IN ('ordered','sample_collected','in_progress','resulted','approved','cancelled')),
  sample_barcode text UNIQUE,
  collected_at timestamptz,
  collected_by uuid REFERENCES users(id),
  approved_by  uuid REFERENCES users(id),
  approved_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (status <> 'approved' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);
CREATE INDEX idx_laborder_patient ON lab_orders(patient_id, created_at DESC);
CREATE INDEX idx_laborder_queue ON lab_orders(hospital_id, status) WHERE status NOT IN ('approved','cancelled');

CREATE TABLE lab_order_items (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  lab_order_id uuid NOT NULL REFERENCES lab_orders(id) ON DELETE CASCADE,
  lab_test_id  uuid NOT NULL REFERENCES lab_tests(id),
  price        numeric(12,2) NOT NULL CHECK (price >= 0),
  UNIQUE (lab_order_id, lab_test_id)
);

CREATE TABLE lab_results (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id   uuid NOT NULL REFERENCES hospitals(id),
  order_item_id uuid NOT NULL REFERENCES lab_order_items(id) ON DELETE CASCADE,
  parameter_id  uuid NOT NULL REFERENCES lab_test_parameters(id),
  value_numeric numeric,
  value_text    text,
  unit          text,
  ref_low       numeric,            -- snapshot at time of result
  ref_high      numeric,
  flag          text NOT NULL DEFAULT 'normal' CHECK (flag IN ('normal','low','high','critical_low','critical_high')),
  entered_by    uuid REFERENCES users(id),
  entered_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_item_id, parameter_id),
  CHECK (value_numeric IS NOT NULL OR value_text IS NOT NULL)
);

-- Server-side flagging so abnormal-result alerts never depend on client code.
CREATE OR REPLACE FUNCTION lab_result_set_flag() RETURNS trigger AS $$
DECLARE p lab_test_parameters%ROWTYPE;
BEGIN
  SELECT * INTO p FROM lab_test_parameters WHERE id = NEW.parameter_id;
  NEW.ref_low  := COALESCE(NEW.ref_low,  p.ref_low);
  NEW.ref_high := COALESCE(NEW.ref_high, p.ref_high);
  NEW.unit     := COALESCE(NEW.unit,     p.unit);
  IF NEW.value_numeric IS NULL THEN
    NEW.flag := 'normal';
  ELSIF p.critical_low  IS NOT NULL AND NEW.value_numeric < p.critical_low  THEN NEW.flag := 'critical_low';
  ELSIF p.critical_high IS NOT NULL AND NEW.value_numeric > p.critical_high THEN NEW.flag := 'critical_high';
  ELSIF NEW.ref_low  IS NOT NULL AND NEW.value_numeric < NEW.ref_low  THEN NEW.flag := 'low';
  ELSIF NEW.ref_high IS NOT NULL AND NEW.value_numeric > NEW.ref_high THEN NEW.flag := 'high';
  ELSE NEW.flag := 'normal';
  END IF;
  RETURN NEW;
END; $$ LANGUAGE plpgsql;
CREATE TRIGGER trg_lab_result_flag BEFORE INSERT OR UPDATE ON lab_results
  FOR EACH ROW EXECUTE FUNCTION lab_result_set_flag();

-- ---------- Radiology ----------
CREATE TABLE imaging_catalog (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  code        text NOT NULL,
  name        text NOT NULL,
  modality    text NOT NULL CHECK (modality IN ('xray','ultrasound','ct','mri','other')),
  price       numeric(12,2) NOT NULL DEFAULT 0 CHECK (price >= 0),
  is_active   boolean NOT NULL DEFAULT true,
  UNIQUE (hospital_id, code)
);

CREATE TABLE radiology_orders (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  branch_id    uuid REFERENCES branches(id),
  patient_id   uuid NOT NULL REFERENCES patients(id),
  encounter_id uuid REFERENCES encounters(id),
  imaging_id   uuid NOT NULL REFERENCES imaging_catalog(id),
  ordered_by   uuid REFERENCES doctors(id),
  priority     text NOT NULL DEFAULT 'routine' CHECK (priority IN ('routine','urgent','stat')),
  clinical_info text,
  status       text NOT NULL DEFAULT 'ordered' CHECK (status IN ('ordered','scheduled','performed','reported','cancelled')),
  price        numeric(12,2) NOT NULL DEFAULT 0 CHECK (price >= 0),
  performed_at timestamptz,
  dicom_study_uid text,                 -- link to external PACS; DICOM storage itself is out of scope
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_rad_patient ON radiology_orders(patient_id, created_at DESC);

CREATE TABLE radiology_reports (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  order_id    uuid NOT NULL UNIQUE REFERENCES radiology_orders(id) ON DELETE CASCADE,
  radiologist_id uuid NOT NULL REFERENCES users(id),
  findings    text NOT NULL,
  impression  text NOT NULL,
  status      text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','final','amended')),
  reported_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE radiology_images (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  order_id    uuid NOT NULL REFERENCES radiology_orders(id) ON DELETE CASCADE,
  object_key  text NOT NULL,
  mime_type   text NOT NULL,
  size_bytes  bigint NOT NULL CHECK (size_bytes > 0),
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------- Pharmacy stock ----------
CREATE TABLE medicine_batches (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  branch_id    uuid NOT NULL REFERENCES branches(id),
  medicine_id  uuid NOT NULL REFERENCES medicines(id),
  supplier_id  uuid REFERENCES suppliers(id),
  batch_number text NOT NULL,
  expiry_date  date NOT NULL,
  quantity_on_hand int NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),   -- DB refuses negative stock
  cost_price   numeric(12,2) NOT NULL DEFAULT 0 CHECK (cost_price >= 0),
  sale_price   numeric(12,2) NOT NULL DEFAULT 0 CHECK (sale_price >= 0),
  received_at  date NOT NULL DEFAULT current_date,
  UNIQUE (branch_id, medicine_id, batch_number)
);
CREATE INDEX idx_batch_expiry ON medicine_batches(branch_id, expiry_date) WHERE quantity_on_hand > 0;
CREATE INDEX idx_batch_medicine ON medicine_batches(medicine_id);

CREATE TABLE stock_movements (
  id          bigserial PRIMARY KEY,
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  branch_id   uuid NOT NULL REFERENCES branches(id),
  batch_id    uuid NOT NULL REFERENCES medicine_batches(id),
  movement_type text NOT NULL CHECK (movement_type IN ('purchase','sale','return_in','return_out','adjustment','expired_writeoff','transfer_in','transfer_out')),
  quantity    int NOT NULL CHECK (quantity <> 0),      -- signed
  reference_type text,
  reference_id uuid,
  is_controlled boolean NOT NULL DEFAULT false,         -- controlled-drug audit trail flag
  performed_by uuid REFERENCES users(id),
  witnessed_by uuid REFERENCES users(id),               -- second signer for controlled drugs
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (NOT is_controlled OR witnessed_by IS NOT NULL OR movement_type IN ('purchase','transfer_in'))
);
CREATE INDEX idx_stockmv_batch ON stock_movements(batch_id, created_at DESC);
CREATE INDEX idx_stockmv_controlled ON stock_movements(hospital_id, created_at DESC) WHERE is_controlled;

CREATE TRIGGER trg_stockmv_immutable BEFORE UPDATE OR DELETE ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION audit_logs_immutable();

CREATE TABLE pharmacy_sales (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  branch_id    uuid NOT NULL REFERENCES branches(id),
  patient_id   uuid REFERENCES patients(id),            -- NULL = over-the-counter customer
  prescription_id uuid REFERENCES prescriptions(id),
  sold_by      uuid REFERENCES users(id),
  subtotal     numeric(12,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  discount     numeric(12,2) NOT NULL DEFAULT 0 CHECK (discount >= 0),
  tax          numeric(12,2) NOT NULL DEFAULT 0 CHECK (tax >= 0),
  total        numeric(12,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
  status       text NOT NULL DEFAULT 'completed' CHECK (status IN ('completed','partially_returned','returned','void')),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_psale_day ON pharmacy_sales(branch_id, created_at);

CREATE TABLE pharmacy_sale_items (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  sale_id     uuid NOT NULL REFERENCES pharmacy_sales(id) ON DELETE CASCADE,
  batch_id    uuid NOT NULL REFERENCES medicine_batches(id),
  medicine_id uuid NOT NULL REFERENCES medicines(id),
  prescription_item_id uuid REFERENCES prescription_items(id),
  quantity    int NOT NULL CHECK (quantity > 0),
  returned_quantity int NOT NULL DEFAULT 0 CHECK (returned_quantity >= 0),
  unit_price  numeric(12,2) NOT NULL CHECK (unit_price >= 0),
  CHECK (returned_quantity <= quantity)
);
CREATE INDEX idx_psi_sale ON pharmacy_sale_items(sale_id);

-- ---------- Procurement ----------
CREATE TABLE purchase_orders (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  branch_id    uuid NOT NULL REFERENCES branches(id),
  supplier_id  uuid NOT NULL REFERENCES suppliers(id),
  po_number    text NOT NULL,
  status       text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','approved','partially_received','received','cancelled')),
  expected_date date,
  total_amount numeric(14,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
  created_by   uuid REFERENCES users(id),
  approved_by  uuid REFERENCES users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (hospital_id, po_number)
);

CREATE TABLE inventory_items (            -- non-drug supplies and equipment
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  sku         text NOT NULL,
  name        text NOT NULL,
  item_type   text NOT NULL CHECK (item_type IN ('supply','equipment','consumable')),
  unit        text NOT NULL DEFAULT 'piece',
  reorder_level int NOT NULL DEFAULT 0 CHECK (reorder_level >= 0),
  is_active   boolean NOT NULL DEFAULT true,
  UNIQUE (hospital_id, sku)
);

CREATE TABLE purchase_order_items (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  po_id       uuid NOT NULL REFERENCES purchase_orders(id) ON DELETE CASCADE,
  medicine_id uuid REFERENCES medicines(id),
  inventory_item_id uuid REFERENCES inventory_items(id),
  quantity_ordered  int NOT NULL CHECK (quantity_ordered > 0),
  quantity_received int NOT NULL DEFAULT 0 CHECK (quantity_received >= 0),
  unit_cost   numeric(12,2) NOT NULL CHECK (unit_cost >= 0),
  CHECK ((medicine_id IS NOT NULL)::int + (inventory_item_id IS NOT NULL)::int = 1),   -- exactly one
  CHECK (quantity_received <= quantity_ordered)
);

CREATE TABLE inventory_stock (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  branch_id   uuid NOT NULL REFERENCES branches(id),
  item_id     uuid NOT NULL REFERENCES inventory_items(id),
  quantity    int NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  expiry_date date,
  UNIQUE (branch_id, item_id)
);

CREATE TABLE goods_receipts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id uuid NOT NULL REFERENCES hospitals(id),
  po_id       uuid NOT NULL REFERENCES purchase_orders(id),
  received_by uuid REFERENCES users(id),
  received_at timestamptz NOT NULL DEFAULT now(),
  note        text
);

CREATE TABLE stock_transfers (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  from_branch_id uuid NOT NULL REFERENCES branches(id),
  to_branch_id   uuid NOT NULL REFERENCES branches(id),
  status       text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested','in_transit','received','cancelled')),
  requested_by uuid REFERENCES users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (from_branch_id <> to_branch_id)
);

-- ---------- Ambulances ----------
CREATE TABLE ambulances (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  branch_id    uuid REFERENCES branches(id),
  plate_number text NOT NULL,
  vehicle_type text,
  status       text NOT NULL DEFAULT 'available' CHECK (status IN ('available','on_trip','maintenance','out_of_service')),
  UNIQUE (hospital_id, plate_number)
);

CREATE TABLE ambulance_drivers (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  employee_id  uuid REFERENCES employees(id),
  full_name    text NOT NULL,
  license_number text NOT NULL,
  phone        text,
  is_active    boolean NOT NULL DEFAULT true
);

CREATE TABLE ambulance_trips (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  ambulance_id uuid NOT NULL REFERENCES ambulances(id),
  driver_id    uuid REFERENCES ambulance_drivers(id),
  patient_id   uuid REFERENCES patients(id),
  requester_name text,
  requester_phone text,
  pickup_address text NOT NULL,
  destination    text,
  status       text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested','dispatched','en_route','arrived','completed','cancelled')),
  requested_at timestamptz NOT NULL DEFAULT now(),
  dispatched_at timestamptz,
  completed_at timestamptz,
  distance_km  numeric(7,1) CHECK (distance_km >= 0)
);
CREATE INDEX idx_trip_ambulance ON ambulance_trips(ambulance_id, requested_at DESC);
-- An ambulance can only be on one active trip at a time
CREATE UNIQUE INDEX uq_trip_active ON ambulance_trips(ambulance_id) WHERE status IN ('dispatched','en_route','arrived');

CREATE TABLE ambulance_maintenance (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hospital_id  uuid NOT NULL REFERENCES hospitals(id),
  ambulance_id uuid NOT NULL REFERENCES ambulances(id),
  record_type  text NOT NULL CHECK (record_type IN ('fuel','service','repair','inspection')),
  amount       numeric(12,2) CHECK (amount >= 0),
  litres       numeric(7,2) CHECK (litres >= 0),
  odometer_km  int CHECK (odometer_km >= 0),
  note         text,
  recorded_on  date NOT NULL DEFAULT current_date
);

INSERT INTO schema_migrations(version) VALUES ('003_diagnostics_pharmacy_inventory');
COMMIT;
