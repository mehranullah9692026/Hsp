# Architecture (target design)

Status: **design only**, apart from the database layer, which is implemented and tested.

## Components

```
 Flutter app (patients, staff)      Next.js web (all portals, RTL/LTR, light/dark)
              \                        /
               ---- HTTPS (Nginx) ----
                         |
                 NestJS REST API  (OpenAPI)  ----  Redis (sessions, rate limits, queues)
                   |         |
          PostgreSQL 16     Object storage (S3-compatible, private buckets, signed URLs)
                   |
        Workers: notifications (SMS/email/push/WhatsApp), report export, backups
```

One web app with role-based navigation serves all staff portals rather than eleven separate apps. Each "portal"
is a permission-filtered set of routes. This keeps one codebase and one design system.

## Key decisions already embodied in the schema

1. **Tenancy:** every tenant table carries `hospital_id`; Postgres row-level security enforces isolation so a
   bug in an API query cannot leak another hospital's data. Branch scoping is an application concern.
2. **Integrity in the database, not only in code:** partial unique indexes (one active admission per patient/bed,
   one active slot per doctor), exclusion constraints (no overlapping operations per theatre or surgeon),
   CHECK constraints (no negative stock, no overpayment, invoice arithmetic), and triggers (lab abnormal flags,
   invoice paid/refund sync, claim history). Concurrent requests cannot violate these.
3. **Counters** (MRN, invoice numbers, queue tokens) use `INSERT ... ON CONFLICT DO UPDATE`, which is race-safe.
4. **Audit and stock ledgers are append-only:** both a privilege revoke for the app role and a trigger that
   blocks even superusers.
5. **Sensitive fields** (`national_id_enc`, `mfa_secret_enc`) are `bytea`, to be encrypted by the application
   with a KMS-held key. Disk encryption and TLS are deployment concerns.
6. **Money** is `numeric(14,2)`; never floats.
7. **Soft delete** (`deleted_at`) on users and patients. Medical-record deletion requests go through
   `data_deletion_requests` because statutory retention may override erasure.

## Security responsibilities that live outside the database

Password hashing (argon2id/bcrypt) and MFA (TOTP) in the auth service; short-lived JWT access tokens with rotating
refresh tokens stored hashed in `sessions`; rate limiting and lockout (`failed_login_count`, `locked_until`);
input validation (DTO validation + parameterised queries only); CSRF protection for cookie-based web sessions;
secure upload pipeline (type sniffing, size limits, malware scan, private storage, SHA-256 recorded);
automated encrypted backups with periodic **restore drills**; audit-log writes on every read/write of patient data.

## Known gaps and decisions to make

- Branch-level RLS is not implemented. Decide whether branch isolation is a hard security boundary.
- Drug-interaction data in the seed is four illustrative rows. Real use needs a licensed drug database.
- DICOM/PACS: the schema stores a study UID link only; image viewing needs an external PACS/viewer.
- Online payments need a gateway chosen per country (no gateway integration exists).
- WhatsApp Business API requires Meta onboarding and approved templates.
- Regulatory review (e.g. local health-data law, HIPAA/GDPR where applicable) is required before real patient data.
