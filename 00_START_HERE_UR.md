# یہاں سے شروع کریں (ہسپتال مینجمنٹ سسٹم: مرحلہ 1)

یہ پیکج صرف **ڈیٹابیس کی بنیاد** ہے (PostgreSQL)۔ بیک اینڈ، ویب اور اینڈرائیڈ ایپ ابھی نہیں بنی۔
کیا بنا اور کیا باقی ہے، اس کی تفصیل `docs/STATUS.md` میں ہے۔

## 1) فائلوں کا نقشہ

```
hms/
├── 00_START_HERE_UR.md        ← یہ گائیڈ (سب سے پہلے پڑھیں)
├── README.md                  ← انگریزی تفصیل
├── .env.example               ← سیٹنگز کا نمونہ (کاپی کر کے .env بنائیں)
├── docker-compose.yml         ← مقامی PostgreSQL/Redis (ابھی چلا کر آزمایا نہیں گیا)
├── database/
│   ├── rebuild.sh             ← ایک کمانڈ جو نیچے کی ساری فائلیں صحیح ترتیب سے چلاتی ہے
│   ├── migrations/            ← ڈھانچہ بنانے والی فائلیں (ترتیب سے)
│   │   ├── 001_core.sql                         پہلی: ہسپتال، یوزر، رول، آڈٹ
│   │   ├── 002_clinical.sql                     دوسری: مریض، ڈاکٹر، اپائنٹمنٹ، وارڈ، آپریشن
│   │   ├── 003_diagnostics_pharmacy_inventory.sql  تیسری: لیب، ریڈیولوجی، فارمیسی، اسٹور
│   │   ├── 004_billing_insurance_hr.sql         چوتھی: بلنگ، انشورنس، عملہ، تنخواہ
│   │   └── 005_security_rls.sql                 پانچویں: ہسپتالوں کا ڈیٹا الگ رکھنے کی حفاظت
│   ├── seeds/                 ← ابتدائی ڈیٹا
│   │   ├── 001_reference.sql              ضروری: رولز اور اجازتیں (ہر جگہ لازمی)
│   │   └── 002_sample_data.sql            صرف آزمائش کے لیے (اصل ہسپتال میں کبھی نہ ڈالیں)
│   └── tests/
│       ├── run.sh                         ٹیسٹ چلانے کی کمانڈ
│       └── schema_tests.sql               67 خودکار جانچیں
└── docs/
    ├── ARCHITECTURE.md        ← پورے سسٹم کا ڈیزائن
    ├── RBAC_MATRIX.md         ← کس رول کو کون سی اجازت
    └── STATUS.md              ← کیا مکمل ہے، کیا باقی
```

## 2) چلانے کی ترتیب (آسان طریقہ)

**پہلے ضروری چیزیں:** کمپیوٹر پر PostgreSQL 16 اور `psql` ہو، اور `contrib` ایکسٹینشنز (pgcrypto، citext، pg_trgm، btree_gist) موجود ہوں۔

| قدم | کیا کریں | کمانڈ |
|---|---|---|
| 1 | زِپ کھولیں اور `database` فولڈر میں جائیں | `cd hms/database` |
| 2 | کنکشن بتائیں (اپنا ڈیٹا ڈالیں) | `export PGHOST=localhost PGUSER=postgres PGPASSWORD=آپ_کا_پاسورڈ` |
| 3 | آزمائشی ڈیٹابیس بنائیں (ڈھانچہ + ڈیٹا سب خود چلے گا) | `./rebuild.sh hms_dev` |
| 4 | چیک کریں کہ سب ٹھیک ہے | `tests/run.sh` |

آخر میں `ALL TESTS PASSED` لکھا آئے تو سب ٹھیک ہے۔

**`rebuild.sh` اندر سے یہ ترتیب خود چلاتا ہے:**
1. `001_core.sql` ← 2. `002_clinical.sql` ← 3. `003_...sql` ← 4. `004_...sql` ← 5. `005_security_rls.sql`
2. پھر `seeds/001_reference.sql`
3. پھر `seeds/002_sample_data.sql` (آزمائشی ڈیٹا)

**اگر ہاتھ سے ایک ایک چلانی ہو** تو بالکل اسی ترتیب سے چلائیں، آگے پیچھے نہ کریں:

```bash
psql -d mydb -v ON_ERROR_STOP=1 -f migrations/001_core.sql
psql -d mydb -v ON_ERROR_STOP=1 -f migrations/002_clinical.sql
psql -d mydb -v ON_ERROR_STOP=1 -f migrations/003_diagnostics_pharmacy_inventory.sql
psql -d mydb -v ON_ERROR_STOP=1 -f migrations/004_billing_insurance_hr.sql
psql -d mydb -v ON_ERROR_STOP=1 -f migrations/005_security_rls.sql
psql -d mydb -v ON_ERROR_STOP=1 -f seeds/001_reference.sql
psql -d mydb -v ON_ERROR_STOP=1 -f seeds/002_sample_data.sql   # صرف آزمائش
```

## 3) حقیقی (پروڈکشن) استعمال کے لیے

- **`rebuild.sh` پرانا ڈیٹابیس مٹا دیتا ہے**، یہ صرف ڈیولپمنٹ اور ٹیسٹ کے لیے ہے۔ جس نام میں `prod` ہو اسے یہ خود روک دیتا ہے۔ اصل ڈیٹا والے ڈیٹابیس پر کبھی نہ چلائیں۔
- نئے خالی ڈیٹابیس پر اصل استعمال کے لیے: `./rebuild.sh hms_live --no-sample` (اس میں آزمائشی ڈیٹا نہیں ڈلتا)۔ بعد کی تبدیلیاں مائیگریشن فائلیں ایک ایک کر کے لگا کر کریں۔
- آزمائشی یوزرز (`admin@cgh.test` وغیرہ، پاسورڈ `ChangeMe!2026`) اصل ہسپتال میں نہ رکھیں۔
- ایپ کو `hms_app` رول کے ممبر یوزر سے جوڑیں، سپر یوزر سے ہرگز نہیں (ورنہ ہسپتالوں کے ڈیٹا کی علیحدگی ختم ہو جاتی ہے)۔

## 4) عام غلطیاں اور حل

| پیغام | وجہ | حل |
|---|---|---|
| `psql is not installed` | PostgreSQL کلائنٹ نہیں | PostgreSQL انسٹال کریں |
| `missing PostgreSQL contrib extensions` | contrib پیکج نہیں | `postgresql-contrib` انسٹال کریں |
| `FAILED while running: migration ...` | کوئی فائل ٹوٹی یا ترتیب بدلی | پیغام میں فائل کا نام ہوتا ہے؛ فائلوں کے نام/ترتیب نہ بدلیں |
| `permission denied to create extension` | یوزر سپر یوزر نہیں | سپر یوزر سے چلائیں |

## 5) اگلا مرحلہ

بیک اینڈ (NestJS): لاگ اِن، ملٹی فیکٹر تصدیق، اجازتوں کی جانچ، آڈٹ لاگنگ۔
