-- Smart Expense Agent — initial schema (migration 001)
-- Target: Supabase Postgres (PG 15+). Requires Supabase Auth (auth.users) to exist.
--
-- Apply via:
--   Supabase dashboard → SQL Editor → paste & run
--   or: psql "$DATABASE_URL" -f backend/migrations/001_initial_schema.sql
--
-- Source of truth for the schema. The Prisma schema (prisma/schema.prisma)
-- is hand-maintained to match. Keep them in sync when evolving.

-- ============================================================
-- Helper: auto-touch updated_at on UPDATE
-- ============================================================
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================
-- organizations
-- ============================================================
create table public.organizations (
  id                uuid primary key default gen_random_uuid(),
  kind              text not null check (kind in
                      ('individual','freelancer','accounting_firm','corporate')),
  display_name      text not null,
  legal_name        text,
  tax_id            text,
  vat_status        text check (vat_status in
                      ('osek_murshe','osek_patur','vat_exempt','foreign')),
  country           text not null default 'IL',
  default_currency  text not null default 'ILS',
  settings          jsonb not null default '{}'::jsonb,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  constraint organizations_tax_id_required
    check (kind not in ('freelancer','corporate') or tax_id is not null)
);

create trigger organizations_touch_updated_at
  before update on public.organizations
  for each row execute function public.touch_updated_at();

create index organizations_kind_idx on public.organizations (kind);

-- ============================================================
-- users — profile table, 1:1 with Supabase auth.users
-- (id matches auth.users.id; cascade so deleting auth user removes profile)
-- ============================================================
create table public.users (
  id              uuid primary key references auth.users(id) on delete cascade,
  email           text,
  display_name    text,
  preferred_lang  text not null default 'he',
  default_org_id  uuid references public.organizations(id) on delete set null,
  created_at      timestamptz not null default now(),
  deleted_at      timestamptz
);

create unique index users_email_lower_idx
  on public.users (lower(email))
  where email is not null and deleted_at is null;

-- Auto-create a public.users row when a new auth user signs up.
-- Pulls display_name from OAuth metadata where available.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  insert into public.users (id, email, display_name)
  values (
    new.id,
    new.email,
    coalesce(
      new.raw_user_meta_data->>'full_name',
      new.raw_user_meta_data->>'name'
    )
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- ============================================================
-- memberships — user ↔ organization with role
-- ============================================================
create table public.memberships (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.users(id) on delete cascade,
  org_id      uuid not null references public.organizations(id) on delete cascade,
  role        text not null check (role in
                ('owner','admin','accountant','employee','viewer')),
  status      text not null default 'active'
                check (status in ('active','invited','revoked')),
  created_at  timestamptz not null default now(),
  unique (user_id, org_id)
);

create index memberships_org_idx on public.memberships (org_id);

-- ============================================================
-- org_links — accounting firm "manages" client org
-- ============================================================
create table public.org_links (
  id              uuid primary key default gen_random_uuid(),
  manager_org_id  uuid not null references public.organizations(id) on delete cascade,
  managed_org_id  uuid not null references public.organizations(id) on delete cascade,
  permissions     jsonb not null default
                    '{"read":true,"export":true,"write":false}'::jsonb,
  started_at      timestamptz not null default now(),
  ended_at        timestamptz,
  unique (manager_org_id, managed_org_id),
  check (manager_org_id <> managed_org_id)
);

create index org_links_manager_active_idx
  on public.org_links (manager_org_id)
  where ended_at is null;

create index org_links_managed_active_idx
  on public.org_links (managed_org_id)
  where ended_at is null;

-- ============================================================
-- projects — the Project List fed into the Gemini prompt
-- ============================================================
create table public.projects (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id) on delete cascade,
  name        text not null,
  address     text,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (org_id, name)
);

-- ============================================================
-- vat_rate_history — date-driven VAT rate lookup
-- Source of truth for new-scan VAT calculation. Not a per-receipt audit;
-- per-receipt rate is frozen on the receipt row itself.
-- ============================================================
create table public.vat_rate_history (
  id              uuid primary key default gen_random_uuid(),
  country         text not null default 'IL',
  rate            numeric(5,4) not null,
  effective_from  date not null,
  effective_to    date,
  source_note     text,
  created_at      timestamptz not null default now(),
  unique (country, effective_from),
  check (effective_to is null or effective_to >= effective_from)
);

insert into public.vat_rate_history
  (country, rate, effective_from, effective_to, source_note)
values
  ('IL', 0.1700, '1900-01-01', '2024-12-31', 'pre-2025 rate'),
  ('IL', 0.1800, '2025-01-01', null,         'statutory_change_2025-01-01');

-- ============================================================
-- scan_jobs — one row per Gemini call (cost + debugging + audit)
-- ============================================================
create table public.scan_jobs (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations(id) on delete cascade,
  user_id           uuid not null references public.users(id) on delete restrict,
  model             text not null,
  status            text not null check (status in ('pending','succeeded','failed')),
  receipt_count     int,
  image_object_key  text,
  request_bytes     int,
  response_bytes    int,
  latency_ms        int,
  error_code        text,
  created_at        timestamptz not null default now(),
  completed_at      timestamptz
);

create index scan_jobs_org_created_idx
  on public.scan_jobs (org_id, created_at desc);

-- ============================================================
-- receipts — core domain
-- ============================================================
create table public.receipts (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations(id) on delete cascade,
  scanned_by_user_id  uuid references public.users(id) on delete set null,
  invoice_number      text,
  receipt_date        date,
  business_name       text,
  amount              numeric(12,2),
  currency            text not null default 'ILS',
  vat_amount          numeric(12,2),
  vat_rate            numeric(5,4),
  vat_source          text check (vat_source in (
                        'receipt_explicit',
                        'calculated_current',
                        'calculated_historical',
                        'vat_exempt',
                        'unknown')),
  start_time          time,
  end_time            time,
  project_id          uuid references public.projects(id) on delete set null,
  category            text,
  bounding_box        jsonb,
  confidence          numeric(3,2),
  image_object_key    text,
  scan_job_id         uuid references public.scan_jobs(id) on delete set null,
  scanned_at          timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz
);

create trigger receipts_touch_updated_at
  before update on public.receipts
  for each row execute function public.touch_updated_at();

-- Dedup within a tenant (matches Flutter's invoice-number primary-key logic).
-- Soft-deleted rows don't block reuse of the invoice number.
create unique index receipts_org_invoice_unique_idx
  on public.receipts (org_id, invoice_number)
  where invoice_number is not null and deleted_at is null;

create index receipts_org_date_idx     on public.receipts (org_id, receipt_date);
create index receipts_org_category_idx on public.receipts (org_id, category);
create index receipts_org_scanned_idx  on public.receipts (org_id, scanned_at desc);

-- ============================================================
-- receipt_items
-- ============================================================
create table public.receipt_items (
  id          uuid primary key default gen_random_uuid(),
  receipt_id  uuid not null references public.receipts(id) on delete cascade,
  ord         int not null,
  code        text,
  description text,
  quantity    numeric(10,3),
  price       numeric(12,2)
);

create index receipt_items_receipt_ord_idx
  on public.receipt_items (receipt_id, ord);

-- ============================================================
-- export_jobs — audit trail of Excel/PDF/ERP exports
-- ============================================================
create table public.export_jobs (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id) on delete cascade,
  user_id       uuid not null references public.users(id) on delete restrict,
  format        text not null check (format in ('excel','pdf','erp_csv')),
  filters       jsonb,
  object_key    text,
  status        text not null check (status in ('pending','succeeded','failed')),
  created_at    timestamptz not null default now(),
  completed_at  timestamptz
);

create index export_jobs_org_created_idx
  on public.export_jobs (org_id, created_at desc);

-- ============================================================
-- Row-Level Security
-- ============================================================
-- The Cloud Run backend uses the Supabase service-role key and BYPASSES RLS.
-- Tenancy is enforced in application code (every query filters by org_id).
-- RLS here protects direct database access (Supabase dashboard, anon key,
-- any future client that talks to Postgres directly with a user JWT).

alter table public.organizations    enable row level security;
alter table public.users            enable row level security;
alter table public.memberships      enable row level security;
alter table public.org_links        enable row level security;
alter table public.projects         enable row level security;
alter table public.receipts         enable row level security;
alter table public.receipt_items    enable row level security;
alter table public.scan_jobs        enable row level security;
alter table public.export_jobs      enable row level security;
-- vat_rate_history is global reference data — RLS off, read granted below

-- ----- helper functions for policies -----

create or replace function public.callers_orgs()
returns setof uuid
language sql stable security definer
set search_path = public
as $$
  select org_id from public.memberships
   where user_id = auth.uid() and status = 'active'
$$;

create or replace function public.callers_managed_orgs()
returns setof uuid
language sql stable security definer
set search_path = public
as $$
  select ol.managed_org_id
    from public.org_links ol
    join public.memberships m on m.org_id = ol.manager_org_id
   where m.user_id = auth.uid()
     and m.status = 'active'
     and ol.ended_at is null
     and (ol.permissions->>'read')::boolean = true
$$;

create or replace function public.callers_visible_orgs()
returns setof uuid
language sql stable security definer
set search_path = public
as $$
  select * from public.callers_orgs()
  union
  select * from public.callers_managed_orgs()
$$;

-- ----- users: only see/update own profile -----

create policy users_self_select on public.users
  for select using (id = auth.uid());

create policy users_self_update on public.users
  for update using (id = auth.uid()) with check (id = auth.uid());

-- ----- organizations -----

create policy organizations_visible on public.organizations
  for select using (id in (select public.callers_visible_orgs()));

create policy organizations_write on public.organizations
  for all
  using (id in (select public.callers_orgs()))
  with check (id in (select public.callers_orgs()));

-- ----- memberships -----

create policy memberships_visible on public.memberships
  for select using (
    user_id = auth.uid()
    or org_id in (select public.callers_visible_orgs())
  );

-- (no write policy — memberships managed by backend via service role)

-- ----- org_links -----

create policy org_links_visible on public.org_links
  for select using (
    manager_org_id in (select public.callers_visible_orgs())
    or managed_org_id in (select public.callers_visible_orgs())
  );

-- ----- projects -----

create policy projects_visible on public.projects
  for select using (org_id in (select public.callers_visible_orgs()));

create policy projects_write on public.projects
  for all
  using (org_id in (select public.callers_orgs()))
  with check (org_id in (select public.callers_orgs()));

-- ----- receipts -----

create policy receipts_visible on public.receipts
  for select using (org_id in (select public.callers_visible_orgs()));

create policy receipts_write on public.receipts
  for all
  using (org_id in (select public.callers_orgs()))
  with check (org_id in (select public.callers_orgs()));

-- ----- receipt_items (scoped through parent receipt) -----

create policy receipt_items_visible on public.receipt_items
  for select using (
    receipt_id in (
      select id from public.receipts
       where org_id in (select public.callers_visible_orgs())
    )
  );

create policy receipt_items_write on public.receipt_items
  for all using (
    receipt_id in (
      select id from public.receipts
       where org_id in (select public.callers_orgs())
    )
  ) with check (
    receipt_id in (
      select id from public.receipts
       where org_id in (select public.callers_orgs())
    )
  );

-- ----- scan_jobs / export_jobs -----

create policy scan_jobs_visible on public.scan_jobs
  for select using (org_id in (select public.callers_visible_orgs()));

create policy scan_jobs_write on public.scan_jobs
  for all
  using (org_id in (select public.callers_orgs()))
  with check (org_id in (select public.callers_orgs()));

create policy export_jobs_visible on public.export_jobs
  for select using (org_id in (select public.callers_visible_orgs()));

create policy export_jobs_write on public.export_jobs
  for all
  using (org_id in (select public.callers_orgs()))
  with check (org_id in (select public.callers_orgs()));

-- ----- vat_rate_history is public reference data -----

grant select on public.vat_rate_history to anon, authenticated;
