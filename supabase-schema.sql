-- PocketFlow Database Schema
-- Run this in your Supabase project: SQL Editor → New Query → paste → Run

-- ── accounts ────────────────────────────────────────────────────────────────
create table public.accounts (
  id          text primary key,
  user_id     uuid references auth.users(id) on delete cascade not null,
  name        text not null,
  type        text not null check (type in ('cash','bank','savings','other')),
  color       text not null default '#6366f1',
  icon        text not null default '💵',
  created_at  timestamptz not null default now(),
  archived    boolean not null default false
);

-- ── tags ────────────────────────────────────────────────────────────────────
create table public.tags (
  id             text primary key,
  user_id        uuid references auth.users(id) on delete cascade not null,
  name           text not null,
  color          text not null default '#6366f1',
  icon           text not null default '🏷️',
  type           text not null check (type in ('income','expense','both')),
  monthly_budget numeric default null,
  daily_budget   numeric default null
);

-- ── transactions ─────────────────────────────────────────────────────────────
create table public.transactions (
  id            text primary key,
  user_id       uuid references auth.users(id) on delete cascade not null,
  type          text not null check (type in ('income','expense','transfer')),
  amount        numeric(15,2) not null check (amount > 0),
  account_id    text references public.accounts(id) on delete cascade not null,
  to_account_id text references public.accounts(id) on delete set null,
  tag_id        text references public.tags(id) on delete set null,
  note          text not null default '',
  date          timestamptz not null,
  is_recurring  boolean not null default false,
  recurring_id  text,
  split_group_id text,
  external_ref  text          -- id from an external source (e.g. bank slip ref); unique per user
);

-- ── recurring ────────────────────────────────────────────────────────────────
create table public.recurring (
  id            text primary key,
  user_id       uuid references auth.users(id) on delete cascade not null,
  name          text not null,
  type          text not null check (type in ('income','expense')),
  amount        numeric(15,2) not null check (amount > 0),
  account_id    text references public.accounts(id) on delete cascade not null,
  tag_id        text references public.tags(id) on delete set null,
  frequency     text not null check (frequency in ('daily','weekly','monthly','yearly')),
  start_date    timestamptz not null,
  end_date      timestamptz,
  next_due_date timestamptz not null,
  is_active     boolean not null default true
);

-- ── user_settings ────────────────────────────────────────────────────────────
create table public.user_settings (
  user_id                 uuid primary key references auth.users(id) on delete cascade,
  discord_webhook         text default null,
  daily_summary           boolean not null default false,
  weekly_summary          boolean not null default false,
  last_daily_summary      text default null,
  last_weekly_summary     text default null,
  daily_allowance         numeric default null,
  allowance_rollover      boolean not null default false,
  allowance_reset_weekday int default null,
  groq_api_key            text default null,
  groq_model              text default null,
  monthly_advice          boolean not null default false,
  last_monthly_advice     text default null
);

-- ── Row Level Security ───────────────────────────────────────────────────────
alter table public.accounts      enable row level security;
alter table public.tags          enable row level security;
alter table public.transactions  enable row level security;
alter table public.recurring     enable row level security;
alter table public.user_settings enable row level security;

-- Each user can only see/modify their own rows
create policy "own accounts"      on public.accounts      for all using (auth.uid() = user_id);
create policy "own tags"          on public.tags          for all using (auth.uid() = user_id);
create policy "own transactions"  on public.transactions  for all using (auth.uid() = user_id);
create policy "own recurring"     on public.recurring     for all using (auth.uid() = user_id);
create policy "own user_settings" on public.user_settings for all using (auth.uid() = user_id);

-- ── Indexes for common query patterns ───────────────────────────────────────
create index on public.transactions (user_id, date desc);
create index on public.transactions (user_id, account_id);
create unique index transactions_user_external_ref_key
  on public.transactions (user_id, external_ref) where external_ref is not null;
create index on public.recurring    (user_id, is_active, next_due_date);

-- ── presets (quick-entry templates) ─────────────────────────────────────────
create table public.presets (
  id            text primary key,
  user_id       uuid references auth.users(id) on delete cascade not null,
  name          text not null,
  type          text not null check (type in ('income','expense','transfer')),
  amount        numeric(15,2) not null check (amount > 0),
  account_id    text references public.accounts(id) on delete cascade not null,
  to_account_id text references public.accounts(id) on delete set null,
  tag_id        text references public.tags(id) on delete set null,
  note          text not null default ''
);

alter table public.presets enable row level security;
create policy "own presets" on public.presets for all using (auth.uid() = user_id);

-- ── profiles (security: active flag + login attempt tracking) ───────────────
create table public.profiles (
  user_id         uuid primary key references auth.users(id) on delete cascade,
  active          boolean      not null default true,
  failed_attempts integer      not null default 0,
  locked_until    timestamptz,
  updated_at      timestamptz  not null default now()
);

alter table public.profiles enable row level security;

-- Users can read their own profile (needed for active/locked check after sign-in)
create policy "own profile read"   on public.profiles for select using (auth.uid() = user_id);
-- Active flag and locked_until are managed by security-definer RPCs only (not directly writable by users)

-- Auto-create a profile row whenever a new user signs up
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (user_id)
  values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Record a failed login attempt; auto-lock after thresholds; auto-ban after 20
-- security definer so anon role can call it without direct table access
create or replace function public.record_failed_login(p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_user_id uuid;
begin
  select id into v_user_id from auth.users where email = lower(trim(p_email));
  if v_user_id is null then return; end if;

  update public.profiles
  set
    failed_attempts = failed_attempts + 1,
    locked_until = case
      when failed_attempts + 1 >= 20 then now() + interval '24 hours'
      when failed_attempts + 1 >= 10 then now() + interval '30 minutes'
      when failed_attempts + 1 >= 5  then now() + interval '15 minutes'
      else locked_until
    end,
    active = case
      when failed_attempts + 1 >= 20 then false
      else active
    end,
    updated_at = now()
  where user_id = v_user_id;
end;
$$;

-- Reset failed attempts on successful login
create or replace function public.reset_failed_login(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.profiles
  set failed_attempts = 0, locked_until = null, updated_at = now()
  where user_id = p_user_id;
end;
$$;

-- Grant anon/authenticated roles permission to call the RPCs
grant execute on function public.record_failed_login(text) to anon, authenticated;
grant execute on function public.reset_failed_login(uuid) to authenticated;

-- ── savings_plans ────────────────────────────────────────────────────────────
create table public.savings_plans (
  id                text primary key,
  user_id           uuid references auth.users(id) on delete cascade not null,
  name              text not null,
  target_amount     numeric(15,2) not null check (target_amount > 0),
  target_date       timestamptz not null,
  initial_amount    numeric(15,2) not null default 0,
  note              text,
  linked_account_id text references public.accounts(id) on delete set null
);

-- ── savings_cash_flows ───────────────────────────────────────────────────────
create table public.savings_cash_flows (
  id             text primary key,
  user_id        uuid references auth.users(id) on delete cascade not null,
  plan_id        text references public.savings_plans(id) on delete cascade not null,
  name           text not null,
  type           text not null check (type in ('income','expense')),
  amount         numeric(15,2) not null check (amount > 0),
  frequency      text not null check (frequency in ('daily','weekly','monthly')),
  count_weekends boolean not null default true
);

-- ── scheduled_payments ───────────────────────────────────────────────────────
create table public.scheduled_payments (
  id             text primary key,
  user_id        uuid references auth.users(id) on delete cascade not null,
  type           text not null check (type in ('income','expense')),
  amount         numeric(15,2) not null check (amount > 0),
  account_id     text references public.accounts(id) on delete cascade not null,
  tag_id         text references public.tags(id) on delete set null,
  note           text not null default '',
  due_date       timestamptz not null,
  is_active      boolean not null default true,
  executed_at    timestamptz,
  transaction_id text,
  reminded_at    timestamptz
);

alter table public.savings_plans     enable row level security;
alter table public.savings_cash_flows enable row level security;
alter table public.scheduled_payments enable row level security;

create policy "own savings_plans"      on public.savings_plans      for all using (auth.uid() = user_id);
create policy "own savings_cash_flows" on public.savings_cash_flows  for all using (auth.uid() = user_id);
create policy "own scheduled_payments" on public.scheduled_payments  for all using (auth.uid() = user_id);

create index on public.scheduled_payments (user_id, is_active, due_date);
create index on public.savings_cash_flows (plan_id);

-- ── api_keys (external API access: pay / receive / transfer) ─────────────────
-- Keys are stored hashed (sha-256). The full key is shown to the user once.
-- The Edge Function "tx" looks keys up with the service-role key (bypasses RLS).
create table public.api_keys (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references auth.users(id) on delete cascade not null,
  label        text not null default '',
  prefix       text not null,          -- first chars, for display only
  key_hash     text not null unique,   -- sha-256 hex of the full key
  created_at   timestamptz not null default now(),
  last_used_at timestamptz
);

alter table public.api_keys enable row level security;
-- Users manage only their own keys; the Edge Function uses service-role to read.
create policy "own api_keys" on public.api_keys
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create index on public.api_keys (key_hash);

-- ── FitFlow (health app): weight & diet tracking ─────────────────────────────
create table public.weight_entries (
  id      text primary key,
  user_id uuid references auth.users(id) on delete cascade not null,
  date    text not null, -- yyyy-MM-dd
  weight  numeric(6,2) not null check (weight > 0),
  note    text
);

create table public.food_entries (
  id           text primary key,
  user_id      uuid references auth.users(id) on delete cascade not null,
  date         text not null, -- yyyy-MM-dd
  meal         text not null check (meal in ('breakfast','lunch','dinner','snack')),
  name         text not null,
  kcal         numeric(8,1) not null default 0 check (kcal >= 0),
  protein      numeric(7,1),
  carbs        numeric(7,1),
  fat          numeric(7,1),
  ai_estimated boolean not null default false,
  created_at   timestamptz not null default now()
);

create table public.exercise_entries (
  id          text primary key,
  user_id     uuid references auth.users(id) on delete cascade not null,
  date        text not null, -- yyyy-MM-dd
  name        text not null,
  minutes     numeric(6,1),
  kcal_burned numeric(8,1) not null default 0 check (kcal_burned >= 0),
  created_at  timestamptz not null default now()
);

create table public.water_logs (
  id      text primary key,
  user_id uuid references auth.users(id) on delete cascade not null,
  date    text not null, -- yyyy-MM-dd — one row per day
  glasses int not null default 0 check (glasses >= 0)
);

create table public.health_settings (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  daily_kcal_limit numeric default null,
  target_weight    numeric(6,2) default null,
  start_weight     numeric(6,2) default null,
  height_cm        numeric(5,1) default null,
  birth_year       int default null,
  gender           text default null check (gender in ('male','female')),
  activity_level   text default null check (activity_level in ('sedentary','light','moderate','active','veryActive')),
  water_goal       int default null,
  protein_goal     numeric default null,
  carbs_goal       numeric default null,
  fat_goal         numeric default null,
  count_exercise   boolean not null default true
);

alter table public.weight_entries   enable row level security;
alter table public.food_entries     enable row level security;
alter table public.exercise_entries enable row level security;
alter table public.water_logs       enable row level security;
alter table public.health_settings  enable row level security;

create policy "own weight_entries"   on public.weight_entries   for all using (auth.uid() = user_id);
create policy "own food_entries"     on public.food_entries     for all using (auth.uid() = user_id);
create policy "own exercise_entries" on public.exercise_entries for all using (auth.uid() = user_id);
create policy "own water_logs"       on public.water_logs       for all using (auth.uid() = user_id);
create policy "own health_settings"  on public.health_settings  for all using (auth.uid() = user_id);

create index on public.weight_entries   (user_id, date desc);
create index on public.food_entries     (user_id, date desc);
create index on public.exercise_entries (user_id, date desc);
create index on public.water_logs       (user_id, date desc);
