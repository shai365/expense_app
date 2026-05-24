# Guide for code agents

Project-specific context that isn't obvious from reading the files. See
`README.md` for user-facing setup; this file is for agents working in-repo.

## Server-authoritative principle

The Flutter client must never:

- Hold the Gemini API key, Supabase service role key, or any DB credential.
- Decide VAT rates, duplicate detection, or project mapping.
- Send `org_id` or `user_id` in a request body. Those come from `req.auth`
  (the JWT verified by `backend/src/middleware/auth.ts`).

If a change tempts you to violate any of these, push the logic into
`backend/src/`.

## Schema source of truth

- `backend/migrations/NNN_*.sql` is canonical (RLS, partial indexes,
  triggers, cross-schema FKs to `auth.users` — none of which Prisma can
  express).
- `backend/prisma/schema.prisma` is hand-maintained. When you add a SQL
  migration, mirror the column in the Prisma file and run
  `npx prisma generate`.
- Never run `prisma migrate dev` — it would try to take ownership of the
  schema and conflict with the SQL files.

## VAT (Israeli מע"מ)

- Statutory rate is **18%** effective 2025-01-01; **17%** for receipts
  dated strictly before that. The cutoff is in
  `backend/src/services/persistence.ts` (`VAT_CUTOFF`).
- An explicit VAT line on the receipt always overrides the calculated
  value. The model prompt (`backend/src/services/gemini.ts`) instructs
  Gemini to return what's printed; persistence computes a rate only when
  needed for the audit field (`vat_rate`, `vat_source`).
- Update both the prompt **and** the persistence helper if the statutory
  rate changes.

## Auth model (v1)

`POST /v1/sessions/exchange` accepts a `company_code` (case-insensitive)
and picks the earliest active `owner` membership for that org. This is a
deliberate v1 shortcut — when real per-user auth lands, replace the
exchange handler with a Supabase JWT verification and drop `company_code`
from the login flow. The Flutter side already stores a full `Session`
object, so adding `email`/`password` fields won't ripple far.

## Useful commands

```
# backend
cd backend
npm run dev               # tsx watch on :8080
npm run typecheck         # tsc --noEmit
npm run seed              # idempotent SEED-CO tenant
psql "$DATABASE_URL" -f migrations/002_organizations_company_code.sql

# client
flutter analyze
flutter test
flutter run -d <id> --dart-define=BACKEND_BASE_URL=http://...:8080
```

## Style notes

- The Gemini system prompt is duplicated nowhere now — it lives only in
  `backend/src/services/gemini.ts`. Do not reintroduce a client copy.
- Receipt deduplication is in `lib/services/receipt_dedup.dart` (client
  cross-image) and `backend/src/services/persistence.ts` (backend
  per-org by `invoice_number`). Both layers run; the client one collapses
  the same invoice appearing in multiple photos of one batch.
- `lib/services/image_optimizer.dart` (resize ≤1024px, JPEG q80) runs
  before every network call — keeps `/v1/scan` payloads well under the
  Express 15 MB limit.
