-- 002_sample_data.sql : TEST / DEMO DATA ONLY. Never load into production.
-- All people, numbers and credentials below are fictional. Every account uses the password
-- 'ChangeMe!2026' (bcrypt-hashed) so that developers can log in; rotate/delete before any real use.
BEGIN;

DO $$
DECLARE
  h uuid; b_main uuid; b_north uuid;
  d_gen uuid; d_card uuid; d_er uuid; d_lab uuid; d_rad uuid; d_surg uuid;
  u uuid; pw text := crypt('ChangeMe!2026', gen_salt('bf', 10));
  u_doc uuid; u_spec uuid; u_nurse uuid; u_pat uuid; u_admin uuid;
  doc1 uuid; doc2 uuid;
  p1 uuid; p2 uuid; p3 uuid; p4 uuid; p5 uuid; p6 uuid;
  w_gen uuid; w_icu uuid; w_priv uuid; w_iso uuid;
  ot1 uuid; sup uuid; med uuid;
  t_cbc uuid; t_glu uuid; ins_co uuid; pins uuid;
  appt uuid; enc uuid; rx uuid;
  m_para uuid; m_amox uuid; m_aspirin uuid; m_morph uuid; m_metf uuid;
  r record;
BEGIN
  INSERT INTO hospitals(code,name,legal_name,phone,email,address)
  VALUES ('CGH','City General Hospital','City General Hospital (Pvt) Ltd','+92-21-0000000','info@cgh.test','1 Test Road, Karachi')
  RETURNING id INTO h;

  INSERT INTO branches(hospital_id,code,name,address) VALUES (h,'MAIN','Main Campus','1 Test Road, Karachi') RETURNING id INTO b_main;
  INSERT INTO branches(hospital_id,code,name,address) VALUES (h,'NORTH','North Clinic','9 Sample Avenue, Karachi') RETURNING id INTO b_north;

  INSERT INTO departments(hospital_id,branch_id,code,name) VALUES (h,b_main,'GEN','General Medicine') RETURNING id INTO d_gen;
  INSERT INTO departments(hospital_id,branch_id,code,name) VALUES (h,b_main,'CARD','Cardiology') RETURNING id INTO d_card;
  INSERT INTO departments(hospital_id,branch_id,code,name) VALUES (h,b_main,'ER','Emergency') RETURNING id INTO d_er;
  INSERT INTO departments(hospital_id,branch_id,code,name,is_clinical) VALUES (h,b_main,'LAB','Laboratory',false) RETURNING id INTO d_lab;
  INSERT INTO departments(hospital_id,branch_id,code,name,is_clinical) VALUES (h,b_main,'RAD','Radiology',false) RETURNING id INTO d_rad;
  INSERT INTO departments(hospital_id,branch_id,code,name) VALUES (h,b_main,'SURG','Surgery') RETURNING id INTO d_surg;

  -- Platform super admin (no hospital)
  INSERT INTO users(hospital_id,email,full_name,password_hash,password_changed_at)
  VALUES (NULL,'superadmin@hms.test','Platform Super Admin',pw,now()) RETURNING id INTO u;
  INSERT INTO user_roles(user_id,role_id) SELECT u, id FROM roles WHERE code='super_admin';

  -- One staff user per remaining role
  FOR r IN
    SELECT * FROM (VALUES
      ('hospital_admin','admin','Amina Admin'),
      ('hospital_manager','manager','Mansoor Manager'),
      ('doctor','doctor','Dr. Daniyal Doctor'),
      ('specialist_doctor','specialist','Dr. Sana Specialist'),
      ('nurse','nurse','Nadia Nurse'),
      ('receptionist','reception','Rabia Receptionist'),
      ('pharmacist','pharmacist','Parvez Pharmacist'),
      ('lab_technician','labtech','Layla Labtech'),
      ('radiologist','radiologist','Dr. Rehan Radiologist'),
      ('accountant','accountant','Asad Accountant'),
      ('hr_manager','hr','Hina HR'),
      ('inventory_manager','inventory','Imran Inventory'),
      ('insurance_officer','insurance','Iqra Insurance')
    ) AS x(role_code, handle, full_name)
  LOOP
    INSERT INTO users(hospital_id,email,full_name,password_hash,password_changed_at)
    VALUES (h, r.handle || '@cgh.test', r.full_name, pw, now()) RETURNING id INTO u;
    INSERT INTO user_roles(user_id,role_id,hospital_id) SELECT u, id, h FROM roles WHERE code = r.role_code;
    IF r.role_code = 'doctor' THEN u_doc := u; END IF;
    IF r.role_code = 'specialist_doctor' THEN u_spec := u; END IF;
    IF r.role_code = 'nurse' THEN u_nurse := u; END IF;
    IF r.role_code = 'hospital_admin' THEN u_admin := u; END IF;
    IF r.role_code NOT IN ('doctor','specialist_doctor') THEN
      INSERT INTO employees(hospital_id,branch_id,user_id,employee_code,designation,hire_date,base_salary,department_id)
      VALUES (h,b_main,u,'EMP-'||upper(r.handle),initcap(replace(r.role_code,'_',' ')),'2024-01-01',
              CASE r.role_code WHEN 'hospital_admin' THEN 250000 ELSE 90000 END,
              CASE r.role_code WHEN 'lab_technician' THEN d_lab WHEN 'radiologist' THEN d_rad WHEN 'nurse' THEN d_gen ELSE NULL END);
    END IF;
  END LOOP;

  -- Doctors
  INSERT INTO doctors(hospital_id,branch_id,user_id,department_id,license_number,specialization,qualifications,consultation_fee,followup_fee)
  VALUES (h,b_main,u_doc,d_gen,'PMDC-TEST-1001','General Medicine','MBBS',1500,800) RETURNING id INTO doc1;
  INSERT INTO doctors(hospital_id,branch_id,user_id,department_id,license_number,specialization,qualifications,is_specialist,consultation_fee,followup_fee)
  VALUES (h,b_main,u_spec,d_card,'PMDC-TEST-2002','Cardiology','MBBS, FCPS (Cardiology)',true,3500,2000) RETURNING id INTO doc2;
  INSERT INTO employees(hospital_id,branch_id,user_id,department_id,employee_code,designation,hire_date,base_salary)
  VALUES (h,b_main,u_doc,d_gen,'EMP-DOCTOR','Doctor','2023-06-01',300000),
         (h,b_main,u_spec,d_card,'EMP-SPECIALIST','Consultant Cardiologist','2022-03-01',600000);

  -- Mon-Fri OPD schedules
  INSERT INTO doctor_schedules(hospital_id,doctor_id,branch_id,weekday,start_time,end_time)
  SELECT h, doc1, b_main, wd, '09:00', '13:00' FROM generate_series(1,5) wd;
  INSERT INTO doctor_schedules(hospital_id,doctor_id,branch_id,weekday,start_time,end_time)
  SELECT h, doc2, b_main, wd, '14:00', '18:00' FROM generate_series(1,5) wd;

  -- Patients (including one portal-linked account)
  INSERT INTO users(hospital_id,email,full_name,password_hash,password_changed_at)
  VALUES (h,'patient@cgh.test','Pervez Patient',pw,now()) RETURNING id INTO u_pat;
  INSERT INTO user_roles(user_id,role_id,hospital_id) SELECT u_pat, id, h FROM roles WHERE code='patient';

  INSERT INTO patients(hospital_id,branch_id,user_id,mrn,first_name,last_name,gender,date_of_birth,phone,blood_group,city,emergency_contact_name,emergency_contact_phone,emergency_contact_relation)
  VALUES (h,b_main,u_pat,next_mrn(h),'Pervez','Patient','male','1985-04-12','+92-300-0000001','B+','Karachi','Parveen Patient','+92-300-0000002','Spouse') RETURNING id INTO p1;
  INSERT INTO patients(hospital_id,branch_id,mrn,first_name,last_name,gender,date_of_birth,phone,blood_group,city)
  VALUES (h,b_main,next_mrn(h),'Zainab','Khan','female','1992-09-30','+92-300-0000003','O+','Karachi') RETURNING id INTO p2;
  INSERT INTO patients(hospital_id,branch_id,mrn,first_name,last_name,gender,date_of_birth,phone,blood_group,city)
  VALUES (h,b_main,next_mrn(h),'Bilal','Ahmed','male','1970-01-05','+92-300-0000004','A+','Lahore') RETURNING id INTO p3;
  INSERT INTO patients(hospital_id,branch_id,mrn,first_name,last_name,gender,date_of_birth,phone,city)
  VALUES (h,b_main,next_mrn(h),'Fatima','Siddiqui','female','2015-06-18','+92-300-0000005','Karachi') RETURNING id INTO p4;
  INSERT INTO patients(hospital_id,branch_id,mrn,first_name,last_name,gender,date_of_birth,phone,city)
  VALUES (h,b_north,next_mrn(h),'Omar','Farooq','male','1958-11-22','+92-300-0000006','Karachi') RETURNING id INTO p5;
  INSERT INTO patients(hospital_id,branch_id,mrn,first_name,last_name,gender,date_of_birth,phone,city)
  VALUES (h,b_main,next_mrn(h),'Ayesha','Malik','female','1999-02-14','+92-300-0000007','Karachi') RETURNING id INTO p6;

  INSERT INTO patient_allergies(hospital_id,patient_id,allergen,reaction,severity)
  VALUES (h,p1,'penicillin','Rash and hives','moderate'),(h,p3,'aspirin','Bronchospasm','severe');
  INSERT INTO patient_medical_history(hospital_id,patient_id,category,description,onset_date)
  VALUES (h,p3,'chronic','Type 2 diabetes mellitus','2015-03-01'),(h,p3,'chronic','Hypertension','2012-07-01');

  -- Wards & beds
  INSERT INTO wards(hospital_id,branch_id,name,ward_type,floor) VALUES (h,b_main,'General Ward A','general','1') RETURNING id INTO w_gen;
  INSERT INTO wards(hospital_id,branch_id,name,ward_type,floor) VALUES (h,b_main,'ICU','icu','2') RETURNING id INTO w_icu;
  INSERT INTO wards(hospital_id,branch_id,name,ward_type,floor) VALUES (h,b_main,'Private Rooms','private','3') RETURNING id INTO w_priv;
  INSERT INTO wards(hospital_id,branch_id,name,ward_type,floor) VALUES (h,b_main,'Isolation','isolation','1') RETURNING id INTO w_iso;
  INSERT INTO beds(hospital_id,ward_id,bed_number,daily_rate) SELECT h,w_gen,'G-'||n,3000 FROM generate_series(1,6) n;
  INSERT INTO beds(hospital_id,ward_id,bed_number,daily_rate) SELECT h,w_icu,'ICU-'||n,25000 FROM generate_series(1,2) n;
  INSERT INTO beds(hospital_id,ward_id,bed_number,daily_rate) SELECT h,w_priv,'P-'||n,12000 FROM generate_series(1,2) n;
  INSERT INTO beds(hospital_id,ward_id,bed_number,daily_rate) VALUES (h,w_iso,'ISO-1',15000);

  INSERT INTO operation_theatres(hospital_id,branch_id,name) VALUES (h,b_main,'OT-1') RETURNING id INTO ot1;

  -- Lab catalog with reference ranges and critical limits
  INSERT INTO lab_tests(hospital_id,code,name,category,sample_type,price,turnaround_hours)
  VALUES (h,'CBC','Complete Blood Count','Haematology','blood',800,4) RETURNING id INTO t_cbc;
  INSERT INTO lab_tests(hospital_id,code,name,category,sample_type,price,turnaround_hours)
  VALUES (h,'FBS','Fasting Blood Glucose','Biochemistry','blood',300,2) RETURNING id INTO t_glu;
  INSERT INTO lab_test_parameters(hospital_id,lab_test_id,name,unit,ref_low,ref_high,critical_low,critical_high,sort_order) VALUES
    (h,t_cbc,'Haemoglobin','g/dL',12.0,17.0,7.0,20.0,1),
    (h,t_cbc,'WBC','x10^9/L',4.0,11.0,2.0,30.0,2),
    (h,t_cbc,'Platelets','x10^9/L',150,450,20,1000,3),
    (h,t_glu,'Fasting glucose','mg/dL',70,100,40,500,1);

  INSERT INTO imaging_catalog(hospital_id,code,name,modality,price) VALUES
    (h,'XR-CHEST','Chest X-Ray PA','xray',1500),(h,'US-ABD','Abdominal Ultrasound','ultrasound',3000),
    (h,'CT-HEAD','CT Head (plain)','ct',12000),(h,'MRI-LS','MRI Lumbar Spine','mri',25000);

  -- Pharmacy
  INSERT INTO suppliers(hospital_id,name,contact_name,phone) VALUES (h,'Test MediSupply Co.','Sales Desk','+92-21-1111111') RETURNING id INTO sup;
  INSERT INTO medicines(hospital_id,generic_name,brand_name,form,strength,barcode,unit_price,reorder_level)
  VALUES (h,'paracetamol','Testol','tablet','500 mg','8900000000011',2,200) RETURNING id INTO m_para;
  INSERT INTO medicines(hospital_id,generic_name,brand_name,form,strength,barcode,unit_price,reorder_level)
  VALUES (h,'amoxicillin','Amoxitest','capsule','500 mg','8900000000028',12,100) RETURNING id INTO m_amox;
  INSERT INTO medicines(hospital_id,generic_name,brand_name,form,strength,barcode,unit_price,reorder_level)
  VALUES (h,'aspirin','Asprotest','tablet','75 mg','8900000000035',3,100) RETURNING id INTO m_aspirin;
  INSERT INTO medicines(hospital_id,generic_name,brand_name,form,strength,barcode,unit_price,reorder_level,is_controlled)
  VALUES (h,'morphine','Morphotest','injection','10 mg/mL','8900000000042',450,10,true) RETURNING id INTO m_morph;
  INSERT INTO medicines(hospital_id,generic_name,brand_name,form,strength,barcode,unit_price,reorder_level)
  VALUES (h,'metformin','Metotest','tablet','500 mg','8900000000059',4,150) RETURNING id INTO m_metf;

  INSERT INTO medicine_batches(hospital_id,branch_id,medicine_id,supplier_id,batch_number,expiry_date,quantity_on_hand,cost_price,sale_price) VALUES
    (h,b_main,m_para,sup,'PCM-001', current_date + 540, 1000, 1.2, 2),
    (h,b_main,m_amox,sup,'AMX-001', current_date + 400, 60,   8,   12),     -- below reorder level
    (h,b_main,m_aspirin,sup,'ASP-001', current_date + 20, 300, 1.5, 3),     -- expiring soon
    (h,b_main,m_morph,sup,'MOR-001', current_date + 300, 40, 300, 450),
    (h,b_main,m_metf,sup,'MET-001', current_date + 700, 800, 2.5, 4);

  INSERT INTO inventory_items(hospital_id,sku,name,item_type,unit,reorder_level) VALUES
    (h,'GLV-M','Examination gloves (M)','consumable','box',20),(h,'SYR-5','Syringe 5 mL','consumable','box',30),
    (h,'BP-MON','BP monitor','equipment','piece',0);

  -- Pricing, tax, shifts, insurance
  INSERT INTO service_charges(hospital_id,code,name,category,price) VALUES
    (h,'ROOM-GEN','General ward bed / day','room',3000),(h,'OT-MINOR','Minor operation theatre charge','operation',40000),
    (h,'PROC-DRESS','Wound dressing','procedure',500);
  INSERT INTO tax_rates(hospital_id,name,rate_pct,applies_to) VALUES (h,'Standard service tax',0,'all');
  INSERT INTO shifts(hospital_id,name,start_time,end_time) VALUES (h,'Morning','07:00','15:00'),(h,'Evening','15:00','23:00'),(h,'Night','23:00','07:00');

  INSERT INTO insurance_companies(hospital_id,name,contact_phone) VALUES (h,'Test Health Assurance','+92-21-2222222') RETURNING id INTO ins_co;
  INSERT INTO patient_insurance(hospital_id,patient_id,company_id,policy_number,member_id,coverage_pct,coverage_limit,valid_from,valid_to)
  VALUES (h,p3,ins_co,'POL-TEST-0001','MEM-0001',80,500000,current_date - 100,current_date + 265) RETURNING id INTO pins;

  -- A completed OPD workflow: appointment -> encounter -> vitals -> diagnosis -> prescription
  INSERT INTO appointments(hospital_id,branch_id,patient_id,doctor_id,department_id,source,scheduled_at,status,token_number,reason)
  VALUES (h,b_main,p3,doc1,d_gen,'online', date_trunc('hour', now()) - interval '2 hours','completed',
          next_token(doc1, current_date),'Persistent cough and fever') RETURNING id INTO appt;
  INSERT INTO encounters(hospital_id,branch_id,patient_id,doctor_id,appointment_id,encounter_type,status,chief_complaint,ended_at)
  VALUES (h,b_main,p3,doc1,appt,'opd','closed','Persistent cough and fever',now()) RETURNING id INTO enc;
  INSERT INTO vitals(hospital_id,encounter_id,patient_id,recorded_by,temperature_c,pulse_bpm,resp_rate,systolic_bp,diastolic_bp,spo2_pct,weight_kg,height_cm)
  VALUES (h,enc,p3,u_nurse,38.4,96,20,138,88,96,82.5,172);
  INSERT INTO diagnoses(hospital_id,encounter_id,patient_id,icd10_code,description,is_primary,diagnosed_by)
  VALUES (h,enc,p3,'J20.9','Acute bronchitis',true,u_doc);
  INSERT INTO prescriptions(hospital_id,encounter_id,patient_id,doctor_id) VALUES (h,enc,p3,doc1) RETURNING id INTO rx;
  INSERT INTO prescription_items(hospital_id,prescription_id,medicine_id,dose,frequency,duration_days,quantity)
  VALUES (h,rx,m_para,'500 mg','three times daily',5,15);

  -- Two more booked appointments for today/tomorrow
  INSERT INTO appointments(hospital_id,branch_id,patient_id,doctor_id,department_id,source,scheduled_at,status,token_number)
  VALUES (h,b_main,p2,doc2,d_card,'online', date_trunc('hour', now()) + interval '1 day','booked', next_token(doc2, (current_date+1))),
         (h,b_main,p4,doc1,d_gen,'walk_in', date_trunc('hour', now()) + interval '1 hour','checked_in', next_token(doc1, current_date));

  INSERT INTO consent_records(hospital_id,patient_id,consent_type,version,granted)
  VALUES (h,p1,'privacy_policy','2026-01',true),(h,p1,'treatment','2026-01',true);

  INSERT INTO ambulances(hospital_id,branch_id,plate_number,vehicle_type) VALUES (h,b_main,'TEST-001','Basic Life Support');
END $$;

COMMIT;
