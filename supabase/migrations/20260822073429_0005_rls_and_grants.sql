-- 0005_rls_and_grants
-- Tenant isolation. Two independent layers:
--   1. Reachability -- anon/authenticated have no privileges on schema app at
--      all, and app is not in PostgREST's exposed schemas, so .from('orders')
--      cannot resolve. This is the layer requirement #2 asks for.
--   2. Row-level security -- every app table has RLS ENABLED and FORCED with a
--      business_id policy, evaluated even inside SECURITY DEFINER functions
--      because those are owned by app_api, which has no BYPASSRLS.
-- Layer 2 is what keeps tenants isolated if layer 1 is ever misconfigured.

-- ---------------------------------------------------------------------------
-- Identity helpers (profiles now exists, so these can be created).
-- business_id is derived from the JWT subject. It is NEVER read from a
-- client-supplied argument anywhere in this codebase.
-- ---------------------------------------------------------------------------

create or replace function app.current_business_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.business_id
  from app.profiles p
  where p.id = app.current_user_id()
    and p.is_active
    and p.deleted_at is null
$$;

create or replace function app.current_member_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select p.role
  from app.profiles p
  where p.id = app.current_user_id()
    and p.is_active
    and p.deleted_at is null
$$;

create or replace function app.require_role(variadic allowed text[])
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r text := app.current_member_role();
begin
  if r is null then
    raise exception 'caller is not an active member of any business'
      using errcode = '42501';
  end if;
  if not (r = any(allowed)) then
    raise exception 'role % may not perform this operation', r
      using errcode = '42501';
  end if;
end
$$;

comment on function app.current_business_id() is
  'Single source of tenant scope. SECURITY DEFINER so RLS policies that call it do not recurse through app.profiles.';

-- ---------------------------------------------------------------------------
-- Server-authoritative timestamps on every mutable table.
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array[
    'businesses','profiles','raw_materials','packed_skus','customers','suppliers',
    'purchases','purchase_items','packing_runs','orders','order_items',
    'stock_ledger','payments'
  ] loop
    execute format(
      'create trigger %I_touch before insert or update on app.%I
         for each row execute function app.touch_updated_at()', t, t);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- RLS. Driven by a loop over the catalog rather than a hand-written list, so a
-- table added later without a policy fails the assertion at the bottom instead
-- of silently shipping unprotected.
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  for t in
    select tablename from pg_tables where schemaname = 'app'
  loop
    execute format('alter table app.%I enable row level security', t);
    execute format('alter table app.%I force row level security', t);
  end loop;
end
$$;

-- Standard tenant policy for every table whose scope is plain business_id.
-- No DELETE policy anywhere: deletion is soft (deleted_at), so a hard DELETE
-- is denied by the absence of a policy.
do $$
declare t text;
begin
  foreach t in array array[
    'businesses','profiles','raw_materials','packed_skus','customers','suppliers',
    'purchases','purchase_items','packing_runs','orders','order_items',
    'stock_ledger','payments','business_counters'
  ] loop
    execute format($f$
      create policy tenant_select on app.%I for select
        using (business_id = app.current_business_id())
    $f$, t);
    execute format($f$
      create policy tenant_insert on app.%I for insert
        with check (business_id = app.current_business_id())
    $f$, t);
    execute format($f$
      create policy tenant_update on app.%I for update
        using (business_id = app.current_business_id())
        with check (business_id = app.current_business_id())
    $f$, t);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- Privileges.
-- app_api (the function owner) is the only role that may touch app tables.
-- anon and authenticated get nothing -- not even USAGE on the schema.
-- ---------------------------------------------------------------------------

grant select, insert, update on all tables in schema app to app_api;
grant usage on all sequences in schema app to app_api;
-- Needed so the RLS policies -- which call app.current_business_id() -- can be
-- evaluated while running as app_api.
grant execute on all functions in schema app to app_api;

alter default privileges in schema app
  grant select, insert, update on tables to app_api;
alter default privileges in schema app
  grant execute on routines to app_api;

revoke all on all tables in schema app from public, anon, authenticated;
revoke all on all routines in schema app from public, anon, authenticated;
revoke all on schema app from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Assertions. The migration fails rather than leaving a gap.
-- ---------------------------------------------------------------------------

do $$
declare bad text;
begin
  select string_agg(c.relname, ', ')
    into bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'app' and c.relkind = 'r'
    and (not c.relrowsecurity or not c.relforcerowsecurity);
  if bad is not null then
    raise exception 'tables in schema app without ENABLE+FORCE RLS: %', bad;
  end if;

  select string_agg(c.relname, ', ')
    into bad
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'app' and c.relkind = 'r'
    and not exists (select 1 from pg_policy p where p.polrelid = c.oid);
  if bad is not null then
    raise exception 'tables in schema app with RLS but no policy: %', bad;
  end if;

  if exists (select 1 from pg_roles where rolname = 'app_api' and rolbypassrls) then
    raise exception 'app_api must not have BYPASSRLS';
  end if;
end
$$;
