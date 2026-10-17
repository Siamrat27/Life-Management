-- External API (tx function): optional transaction date + duplicate protection.
-- "external_ref" holds an id from the source (e.g. a bank slip's transaction ref)
-- so the same slip can never be recorded twice for one user.
-- Safe to run more than once.
alter table public.transactions add column if not exists external_ref text;

create unique index if not exists transactions_user_external_ref_key
  on public.transactions (user_id, external_ref) where external_ref is not null;
