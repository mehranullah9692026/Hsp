# Hospital Management System: Milestone 1 (Architecture + Database)

> اردو میں ترتیب اور چلانے کے مراحل کے لیے پہلے [`00_START_HERE_UR.md`](00_START_HERE_UR.md) پڑھیں۔

This package is **milestone 1 of a multi-milestone build**, not the finished system.
It contains a tested PostgreSQL foundation and the design for everything else.
See [`docs/STATUS.md`](docs/STATUS.md) for an exact, section-by-section account of what exists
and what does not. Nothing here should be described as "production ready" yet.

## What is included and verified

| Item | State |
|---|---|
| PostgreSQL 16 schema: 89 tables, 188 indexes, 5 migrations | Applied from scratch and tested |
| Multi-hospital / multi-branch tenancy with **row-level security** (79 tables) | Tested with a non-superuser app role |
| 15 roles, 61 permissions, default RBAC matrix (per-hospital overridable) | Tested; see `docs/RBAC_MATRIX.md` |
| Integrity rules enforced **by the database** (double-booking, negative stock, bed/OT overlap, overpayment, refund limits, controlled-drug witness, append-only audit) | 67 automated assertions, all passing |
| Reference seed (required) and sample data (test only) | Loads cleanly |
| Architecture and security design | Written, not yet implemented in code |

## Not included yet (be aware before planning around it)

NestJS backend, REST API and OpenAPI docs, React/Next.js web app, Flutter/Android app, Docker/Nginx/CI,
notification integrations (SMS, WhatsApp, push, email), PDF/Excel exports, Urdu/Arabic localization,
Play Store packaging, privacy-policy and user-manual documents. None of these exist yet.

## Quick start (database only)

Requirements: PostgreSQL 16 (with `pgcrypto`, `citext`, `pg_trgm`, `btree_gist` from contrib) and `psql`.

```bash
cd database
export PGHOST=localhost PGUSER=postgres PGPASSWORD=...   # a superuser, for CREATE EXTENSION
./rebuild.sh hms_dev            # DROPS and recreates hms_dev, applies migrations + seeds + sample data
./rebuild.sh hms_prod --no-sample   # reference data only. Never load sample data in production
tests/run.sh                    # rebuilds a scratch DB and runs all assertions
```

`rebuild.sh` is destructive by design and is for development. Production migrations should be applied
incrementally with a migration tool (the SQL files are ordered and idempotent per version via `schema_migrations`).

Sample accounts (test data only) use the password `ChangeMe!2026`, e.g. `admin@cgh.test`,
`doctor@cgh.test`, `patient@cgh.test`, `superadmin@hms.test`. Delete them before any real deployment.

## How tenant isolation works

The API must run every request inside a transaction as the non-superuser `hms_app` role and set:

```sql
SELECT set_config('app.hospital_id', '<hospital uuid>', true);
SELECT set_config('app.is_super_admin', 'false', true);
```

With no context set, queries return no rows. **Never** connect the application as a superuser or the table
owner: both bypass or can disable RLS. Branch-level restriction (a user limited to one branch) is *not*
enforced by RLS; the API layer must enforce it using `user_roles.branch_id`.

## Layout

```
database/migrations/   001_core ... 005_security_rls
database/seeds/        001_reference (required), 002_sample_data (test only)
database/tests/        schema_tests.sql + run.sh
docs/ARCHITECTURE.md   target architecture and key decisions
docs/RBAC_MATRIX.md    generated from the database
docs/STATUS.md         requirement-by-requirement status
docker-compose.yml     local PostgreSQL + Redis (not yet tested, see file header)
.env.example
```
