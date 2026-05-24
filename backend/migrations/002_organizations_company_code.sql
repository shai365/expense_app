-- Smart Expense Agent — migration 002
-- Adds organizations.company_code: the short, human-typed identifier the
-- Flutter login screen collects. Used by POST /v1/sessions/exchange to map
-- a code to an (org_id, user_id) pair before issuing a session JWT.
--
-- Apply via:
--   Supabase dashboard → SQL Editor → paste & run
--   or: psql "$DATABASE_URL" -f backend/migrations/002_organizations_company_code.sql

alter table public.organizations
  add column if not exists company_code text;

-- Case-insensitive uniqueness; soft-deleted rows are excluded so a code
-- can be re-issued after an org is deleted.
create unique index if not exists organizations_company_code_lower_idx
  on public.organizations (lower(company_code))
  where company_code is not null and deleted_at is null;

-- Backfill the dev seed tenant so existing smoke tests keep working.
update public.organizations
   set company_code = 'SEED-CO'
 where display_name = 'Seed Test Org'
   and company_code is null
   and deleted_at is null;
