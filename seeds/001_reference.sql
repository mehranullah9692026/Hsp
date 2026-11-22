-- 001_reference.sql : REQUIRED in every environment (roles, permissions, default role matrix)
BEGIN;

INSERT INTO roles(code, name, description) VALUES
 ('super_admin','Super Administrator','Platform-wide administration across all hospitals'),
 ('hospital_admin','Hospital Administrator','Full administration within one hospital'),
 ('hospital_manager','Hospital Manager','Operational oversight and reporting'),
 ('doctor','Doctor','General physician'),
 ('specialist_doctor','Specialist Doctor','Consultant / specialist physician'),
 ('nurse','Nurse','Ward, triage and nursing care'),
 ('receptionist','Receptionist','Registration, appointments and front-desk billing'),
 ('pharmacist','Pharmacist','Dispensing and pharmacy stock'),
 ('lab_technician','Laboratory Technician','Sample handling and result entry'),
 ('radiologist','Radiologist','Imaging and radiology reports'),
 ('accountant','Accountant','Billing, payments and financial reports'),
 ('hr_manager','HR Manager','Staff, attendance, leave and payroll'),
 ('inventory_manager','Inventory Manager','Supplies, procurement and stock'),
 ('patient','Patient','Self-service portal access to own records'),
 ('insurance_officer','Insurance Officer','Coverage verification and claims');

INSERT INTO permissions(code, module, description) VALUES
 ('platform.manage_hospitals','platform','Create and manage hospitals and branches across the platform'),
 ('user.read','user','View users'), ('user.write','user','Create and edit users'),
 ('role.read','role','View roles and permissions'), ('role.write','role','Configure role permissions'),
 ('branch.read','branch','View branches/departments'), ('branch.write','branch','Manage branches/departments'),
 ('patient.read','patient','View patient demographics'), ('patient.write','patient','Register and edit patients'),
 ('emr.read','emr','View medical records, history and documents'), ('emr.write','emr','Write clinical records'),
 ('doctor.read','doctor','View doctors and schedules'), ('doctor.write','doctor','Manage doctors and schedules'),
 ('appointment.read','appointment','View appointments'), ('appointment.write','appointment','Book, reschedule, cancel'),
 ('opd.read','opd','View OPD encounters'), ('opd.write','opd','Conduct OPD consultations'),
 ('ipd.read','ipd','View admissions'), ('ipd.write','ipd','Admit, transfer, discharge, nursing notes'),
 ('emergency.read','emergency','View ER cases'), ('emergency.write','emergency','Register and treat ER cases'),
 ('prescription.read','prescription','View prescriptions'), ('prescription.write','prescription','Issue prescriptions'),
 ('referral.write','referral','Create referrals'),
 ('pharmacy.read','pharmacy','View pharmacy stock and sales'), ('pharmacy.write','pharmacy','Dispense and sell'),
 ('pharmacy.controlled','pharmacy','Handle controlled medicines'),
 ('lab.read','lab','View lab orders and results'), ('lab.write','lab','Collect samples and enter results'),
 ('lab.approve','lab','Approve lab reports for release'),
 ('radiology.read','radiology','View imaging orders and reports'), ('radiology.write','radiology','Perform imaging and write reports'),
 ('ot.read','ot','View operation theatre schedule'), ('ot.write','ot','Schedule and record operations'),
 ('bed.read','bed','View wards and beds'), ('bed.write','bed','Manage beds and cleaning status'),
 ('billing.read','billing','View invoices and payments'), ('billing.write','billing','Create invoices, take payments'),
 ('billing.discount','billing','Apply discounts'), ('billing.refund','billing','Approve refunds'),
 ('insurance.read','insurance','View insurance data'), ('insurance.write','insurance','Manage policies and claims'),
 ('hr.read','hr','View staff data'), ('hr.write','hr','Manage staff, attendance, leave'),
 ('hr.payroll','hr','Run payroll and view salaries'),
 ('inventory.read','inventory','View inventory'), ('inventory.write','inventory','Manage stock and purchase orders'),
 ('ambulance.read','ambulance','View ambulances and trips'), ('ambulance.write','ambulance','Dispatch and manage ambulances'),
 ('report.read','report','View dashboards and reports'), ('report.export','report','Export PDF/Excel/CSV'),
 ('audit.read','audit','View audit logs'),
 ('notification.write','notification','Send notifications'),
 ('consent.manage','consent','Manage consent and deletion requests'),
 ('self.profile','self','Patient: own profile'),
 ('self.appointments','self','Patient: book/view own appointments'),
 ('self.prescriptions','self','Patient: own prescriptions'),
 ('self.lab_reports','self','Patient: own lab reports'),
 ('self.history','self','Patient: own medical history'),
 ('self.invoices','self','Patient: own invoices and online payment'),
 ('self.documents','self','Patient: download own documents');

-- Default matrix. '*' = everything (hospital_admin: everything except platform.*).
CREATE TEMP TABLE role_patterns(role_code text, pattern text);
INSERT INTO role_patterns VALUES
 ('super_admin','*'),
 ('hospital_admin','*'),
 ('hospital_manager','%.read'),('hospital_manager','report.export'),
 ('doctor','patient.read'),('doctor','emr.%'),('doctor','doctor.read'),('doctor','appointment.%'),
 ('doctor','opd.%'),('doctor','ipd.%'),('doctor','emergency.%'),('doctor','prescription.%'),
 ('doctor','referral.write'),('doctor','lab.read'),('doctor','radiology.read'),('doctor','ot.%'),('doctor','bed.read'),
 ('specialist_doctor','patient.read'),('specialist_doctor','emr.%'),('specialist_doctor','doctor.read'),
 ('specialist_doctor','appointment.%'),('specialist_doctor','opd.%'),('specialist_doctor','ipd.%'),
 ('specialist_doctor','emergency.%'),('specialist_doctor','prescription.%'),('specialist_doctor','referral.write'),
 ('specialist_doctor','lab.read'),('specialist_doctor','radiology.read'),('specialist_doctor','ot.%'),('specialist_doctor','bed.read'),
 ('nurse','patient.read'),('nurse','emr.read'),('nurse','ipd.%'),('nurse','emergency.%'),('nurse','bed.%'),
 ('nurse','appointment.read'),('nurse','prescription.read'),('nurse','opd.read'),('nurse','ot.read'),
 ('receptionist','patient.%'),('receptionist','appointment.%'),('receptionist','doctor.read'),('receptionist','opd.read'),
 ('receptionist','billing.read'),('receptionist','billing.write'),('receptionist','bed.read'),('receptionist','insurance.read'),
 ('pharmacist','pharmacy.%'),('pharmacist','prescription.read'),('pharmacist','patient.read'),('pharmacist','inventory.read'),
 ('lab_technician','lab.%'),('lab_technician','patient.read'),
 ('radiologist','radiology.%'),('radiologist','patient.read'),
 ('accountant','billing.%'),('accountant','insurance.read'),('accountant','report.%'),('accountant','hr.payroll'),('accountant','patient.read'),
 ('hr_manager','hr.%'),('hr_manager','report.read'),
 ('inventory_manager','inventory.%'),('inventory_manager','pharmacy.read'),('inventory_manager','report.read'),
 ('patient','self.%'),
 ('insurance_officer','insurance.%'),('insurance_officer','billing.read'),('insurance_officer','patient.read');

INSERT INTO role_permissions(role_id, permission_id)
SELECT DISTINCT r.id, p.id
FROM role_patterns rp
JOIN roles r ON r.code = rp.role_code
JOIN permissions p ON (rp.pattern = '*' OR p.code LIKE rp.pattern)
WHERE rp.pattern <> '*'
   OR rp.role_code = 'super_admin'
   OR p.code NOT LIKE 'platform.%';

-- Least privilege: managers see aggregates via report.read, not individual clinical records.
DELETE FROM role_permissions rp USING roles r, permissions p
WHERE rp.role_id = r.id AND rp.permission_id = p.id AND r.code = 'hospital_manager'
  AND p.code IN ('emr.read','patient.read','prescription.read','lab.read','radiology.read');

-- Starter drug-interaction pairs (illustrative only; production must use a licensed drug database)
INSERT INTO drug_interactions VALUES
 ('aspirin','warfarin','major','Increased bleeding risk'),
 ('clarithromycin','simvastatin','contraindicated','Risk of rhabdomyolysis'),
 ('ibuprofen','warfarin','major','Increased bleeding risk'),
 ('lisinopril','spironolactone','moderate','Risk of hyperkalaemia');

COMMIT;
