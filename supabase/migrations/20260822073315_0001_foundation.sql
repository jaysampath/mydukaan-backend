-- 0001_foundation
-- Private data schema + the non-privileged role that owns every API function.
--
-- Security model (see /docs/supabase-access.md):
--   * All tables live in schema `app`, which is NOT exposed to PostgREST.
--     The client therefore cannot reach a table with .from() even if it tries.
--   * Every table has RLS ENABLED and FORCED.
--   * API functions live in schema `public` (the only exposed schema) and are
--     SECURITY DEFINER owned by `app_api` -- a NOLOGIN role WITHOUT BYPASSRLS,
--     so RLS still applies inside every function. Defense in depth: losing the
--     schema boundary does not lose tenant isolation.

create schema if not exists app;

-- app_api: owns the SECURITY DEFINER API functions.
-- Deliberately NOT superuser and NOT BYPASSRLS.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'app_api') then
    create role app_api nologin noinherit;
  end if;
end
$$;

grant usage on schema app to app_api;

-- The client roles must never see schema app.
revoke all on schema app from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Caller identity.
-- This reads the JWT claim straight out of the request GUC rather than calling
-- auth.uid(). The auth schema is owned by supabase_admin and our migration role
-- cannot grant app_api access to it, so an app_api-owned function calling
-- auth.uid() fails with "permission denied for schema auth". Reading the GUC
-- has identical semantics with no dependency on Supabase's internal ACLs.
-- ---------------------------------------------------------------------------

create or replace function app.current_user_id()
returns uuid
language sql
stable
security invoker
set search_path = ''
as $fn$
  select nullif(
    coalesce(
      current_setting('request.jwt.claim.sub', true),
      nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
    ),
    ''
  )::uuid
$fn$;

-- ---------------------------------------------------------------------------
-- Audit / sync plumbing.
-- updated_at is ALWAYS set from the server clock. Client clocks on budget
-- phones are unreliable and the sync cursor depends on this being monotonic
-- with respect to the database, not the device.
-- ---------------------------------------------------------------------------

create or replace function app.touch_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, now());
  else
    new.created_at := old.created_at;
    new.created_by := old.created_by;
  end if;
  return new;
end
$$;

-- Append-only guard for ledger tables: inserts only. Corrections are made by
-- inserting a reversing row, never by mutating or deleting history.
create or replace function app.forbid_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception '% is append-only; insert a reversing row instead of % ',
    tg_table_name, tg_op
    using errcode = '42501';
end
$$;

comment on schema app is
  'Private data schema. Not exposed to PostgREST. Reachable only through SECURITY DEFINER functions in schema public.';
