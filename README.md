# Smart Expense Agent

A Flutter app for capturing Israeli business receipts (single or bulk), with a
TypeScript backend that proxies vision calls to Gemini, applies statutory VAT
rules, and persists receipts to Postgres (Supabase).

The mobile client never holds the Gemini API key or the database credentials —
it talks only to the backend, which is server-authoritative for every decision
that affects stored data (VAT rate, duplicate detection, project mapping).

## Architecture

```
Flutter client  ──HTTPS──▶  TS backend (Express)  ──▶  Gemini 1.5/2.5 Flash
                                  │
                                  ├──▶  Postgres (Supabase) via Prisma
                                  └──▶  Supabase Auth (auth.users)
```

- **Client** (`lib/`) — capture, optimize (≤1024px JPEG), call backend, render
  results. No third-party AI keys are bundled.
- **Backend** (`backend/`) — Express + Prisma. Endpoints: `/healthz`,
  `POST /v1/sessions/exchange`, `POST /v1/scan` (bearer-auth).
- **Database** — Schema source of truth lives in
  `backend/migrations/*.sql`. `backend/prisma/schema.prisma` is a
  hand-maintained mirror (Prisma can't represent RLS, partial indexes,
  triggers, or the cross-schema FK to `auth.users`).

## Auth & session flow

```
1. User enters Company Code on LoginScreen
2. POST /v1/sessions/exchange { company_code, device_id }
        ↓
   Backend looks up organizations.company_code (case-insensitive),
   picks the earliest active 'owner' membership, issues an HS256 JWT.
        ↓
   { org_id, user_id, token, expires_at }   (7-day TTL)
3. Client persists the Session in SharedPreferences.
4. Subsequent POST /v1/scan calls send `Authorization: Bearer <token>`.
   The middleware verifies the JWT and attaches { orgId, userId } to req.auth.
   org_id and user_id are NEVER read from the request body.
5. On 401 / expired / invalid token, the client clears the session
   and bounces back to LoginScreen.
```

Real per-user authentication (Supabase JWT exchange) replaces the company-code
flow once multi-user login lands.

## Local development

### 1. Backend

Required env in `backend/.env` (gitignored):

```
DATABASE_URL=postgresql://...                # Supabase pooler URL
SUPABASE_SERVICE_ROLE_KEY=eyJ...             # used only by the seed script
GEMINI_API_KEY=AIza...                       # server-side only
SESSION_JWT_SECRET=<≥32 chars>               # node -e "console.log(require('crypto').randomBytes(48).toString('base64'))"
GEMINI_MODEL=gemini-2.5-flash                # optional; default 1.5-flash in code, 2.5 in service
```

Apply migrations once (Supabase SQL editor or `psql -f`):

```
backend/migrations/001_initial_schema.sql
backend/migrations/002_organizations_company_code.sql
```

Then:

```
cd backend
npm install
npm run seed       # idempotent: creates SEED-CO org + owner + Project Alpha
npm run dev        # listens on 0.0.0.0:8080
```

### 2. Flutter client

```
cd <repo root>
flutter pub get
flutter run -d <device> --dart-define=BACKEND_BASE_URL=<see below>
```

#### `BACKEND_BASE_URL` per target

| Target                       | Value                                  |
| ---------------------------- | -------------------------------------- |
| Android emulator (default)   | `http://10.0.2.2:8080` (no flag needed) |
| iOS simulator                | `http://localhost:8080`                 |
| Desktop / Chrome             | `http://localhost:8080`                 |
| Physical Android on Wi-Fi    | `http://<host-LAN-IP>:8080`             |
| Cloud Run                    | `https://<service>.run.app`             |

#### Mock toggle (debug builds only)

```
flutter run --dart-define=USE_MOCK_BACKEND=true
```

Skips the network and returns the hardcoded list from
`lib/services/mock_receipts.dart`.

## Smoke test recipe

```bash
# 1) exchange a session
TOKEN=$(curl -s -X POST http://localhost:8080/v1/sessions/exchange \
  -H 'content-type: application/json' \
  -d '{"company_code":"SEED-CO","device_id":"dev-machine"}' \
  | jq -r .token)

# 2) hit /v1/scan with a base64 receipt
curl -X POST http://localhost:8080/v1/scan \
  -H "authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d @- <<EOF
{
  "company_code": "SEED-CO",
  "projects": [{"name":"Project Alpha","address":"Rothschild 1, Tel Aviv"}],
  "image": {"mime_type":"image/jpeg","data":"<base64>"}
}
EOF
```

## Statutory VAT

Server-authoritative. From `backend/src/services/persistence.ts`:

- **18%** for receipts dated 2025-01-01 onwards (current statutory rate)
- **17%** for receipts dated before 2025-01-01
- An explicit VAT line on the receipt always wins over the calculated value

See [`PRD.md`](PRD.md) for the full product brief.

## Project layout

```
backend/
  migrations/        # SQL — source of truth for schema
  prisma/            # hand-maintained Prisma mirror
  scripts/           # seed-test-tenant.ts
  src/
    middleware/      # auth (Bearer JWT)
    routes/          # /v1/scan, /v1/sessions/exchange
    services/        # gemini, persistence, session (JWT helpers)
lib/
  config/api_config.dart
  models/            # Receipt, Session
  screens/           # login, home, capture, results
  services/          # auth, backend, image_cropper, image_optimizer,
                     # mock_receipts, receipt_dedup
  theme/
test/                # widget tests
```
