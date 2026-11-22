# RBAC Matrix (generated)

Generated from `seeds/001_reference.sql` by loading it into PostgreSQL and querying the result. Do not edit by hand; edit the seed and regenerate. Hospitals can override any cell per hospital via `role_permissions.hospital_id`.

| Role | Permissions |
|---|---|
| accountant (9) | billing.discount, billing.read, billing.refund, billing.write, hr.payroll, insurance.read, patient.read, report.export, report.read |
| doctor (20) | appointment.read, appointment.write, bed.read, doctor.read, emergency.read, emergency.write, emr.read, emr.write, ipd.read, ipd.write, lab.read, opd.read, opd.write, ot.read, ot.write, patient.read, prescription.read, prescription.write, radiology.read, referral.write |
| hospital_admin (60) | all except platform.* |
| hospital_manager (19) | ambulance.read, appointment.read, audit.read, bed.read, billing.read, branch.read, doctor.read, emergency.read, hr.read, insurance.read, inventory.read, ipd.read, opd.read, ot.read, pharmacy.read, report.export, report.read, role.read, user.read |
| hr_manager (4) | hr.payroll, hr.read, hr.write, report.read |
| insurance_officer (4) | billing.read, insurance.read, insurance.write, patient.read |
| inventory_manager (4) | inventory.read, inventory.write, pharmacy.read, report.read |
| lab_technician (4) | lab.approve, lab.read, lab.write, patient.read |
| nurse (12) | appointment.read, bed.read, bed.write, emergency.read, emergency.write, emr.read, ipd.read, ipd.write, opd.read, ot.read, patient.read, prescription.read |
| patient (7) | self.appointments, self.documents, self.history, self.invoices, self.lab_reports, self.prescriptions, self.profile |
| pharmacist (6) | inventory.read, patient.read, pharmacy.controlled, pharmacy.read, pharmacy.write, prescription.read |
| radiologist (3) | patient.read, radiology.read, radiology.write |
| receptionist (10) | appointment.read, appointment.write, bed.read, billing.read, billing.write, doctor.read, insurance.read, opd.read, patient.read, patient.write |
| specialist_doctor (20) | appointment.read, appointment.write, bed.read, doctor.read, emergency.read, emergency.write, emr.read, emr.write, ipd.read, ipd.write, lab.read, opd.read, opd.write, ot.read, ot.write, patient.read, prescription.read, prescription.write, radiology.read, referral.write |
| super_admin (61) | all |

## Schema inventory

- Base tables: 89
- Indexes: 188
- Tables with forced row-level security: 79
