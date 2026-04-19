-- Run this in your Supabase SQL editor (Dashboard → SQL Editor → New query)

-- ── Orgs ─────────────────────────────────────────────────────────────────────
create table if not exists public.orgs (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  slug         text not null unique,
  owner_id     uuid not null references auth.users(id) on delete cascade,
  framework    text not null default 'HIPAA',
  created_at   timestamptz not null default now()
);

alter table public.orgs enable row level security;

create policy "owner can manage org"
  on public.orgs for all
  using (auth.uid() = owner_id);

-- ── API Keys ──────────────────────────────────────────────────────────────────
create table if not exists public.api_keys (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.orgs(id) on delete cascade,
  label        text not null,
  key_hash     text not null,          -- sha256 of the full key, never stored plain
  prefix       text not null,          -- e.g. msk_live_a3f9
  permissions  text[] not null default '{}',
  environment  text not null default 'production',
  status       text not null default 'active' check (status in ('active','revoked')),
  last_used_at timestamptz,
  created_at   timestamptz not null default now()
);

alter table public.api_keys enable row level security;

create policy "org members can manage api keys"
  on public.api_keys for all
  using (org_id in (select id from public.orgs where owner_id = auth.uid()));

-- ── KMS Keys ──────────────────────────────────────────────────────────────────
create table if not exists public.kms_keys (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.orgs(id) on delete cascade,
  alias             text not null,
  scope             text not null default 'All sessions',
  region            text not null default 'us-east-1',
  rotation_cadence  text not null default '90 days',
  last_rotated_at   timestamptz not null default now(),
  status            text not null default 'active' check (status in ('active','rotating','disabled')),
  provider          text not null default 'masker' check (provider in ('masker','byok')),
  created_at        timestamptz not null default now()
);

alter table public.kms_keys enable row level security;

create policy "org members can manage kms keys"
  on public.kms_keys for all
  using (org_id in (select id from public.orgs where owner_id = auth.uid()));

-- ── Audit Logs ────────────────────────────────────────────────────────────────
create table if not exists public.audit_logs (
  id                   uuid primary key default gen_random_uuid(),
  org_id               uuid not null references public.orgs(id) on delete cascade,
  session_id           text not null,
  channel              text not null,
  use_case             text not null,
  policy_version       text not null,
  status               text not null,
  risk_level           text not null,
  entities_detected    int not null default 0,
  duration             text not null,
  raw_hash             text not null,
  redacted_transcript  text not null default '',
  entity_spans         jsonb not null default '[]',
  created_at           timestamptz not null default now()
);

alter table public.audit_logs enable row level security;

create policy "org members can read audit logs"
  on public.audit_logs for select
  using (org_id in (select id from public.orgs where owner_id = auth.uid()));

create policy "service role can insert audit logs"
  on public.audit_logs for insert
  with check (true);

-- ── Indexes ───────────────────────────────────────────────────────────────────
create index if not exists audit_logs_org_id_idx on public.audit_logs(org_id);
create index if not exists audit_logs_created_at_idx on public.audit_logs(created_at desc);
create index if not exists api_keys_org_id_idx on public.api_keys(org_id);
create index if not exists kms_keys_org_id_idx on public.kms_keys(org_id);
