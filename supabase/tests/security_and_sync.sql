-- security_and_sync.sql
--
-- The checks that must pass before any schema change is considered done.
-- Run against DEV only. Each block is independent; run the file top to bottom.
--
--   npx supabase db execute --file supabase/tests/security_and_sync.sql
--
-- The privilege and lint sections need no fixtures. The behavioural section
-- assumes the three seeded test users in supabase/seed/dev_seed.sql.

\echo '== 1. Privilege boundary =================================================='

select * from (
  select 'schema usage on app for authenticated' as what,
         case when has_schema_privilege('authenticated','app','USAGE')
              then 'ALLOWED (BAD)' else 'DENIED (good)' end as result
  union all
  select 'select on app.businesses for authenticated',
         case when has_table_privilege('authenticated','app.businesses','SELECT')
              then 'ALLOWED (BAD)' else 'DENIED (good)' end
  union all
  select 'insert on app.stock_ledger for authenticated',
         case when has_table_privilege('authenticated','app.stock_ledger','INSERT')
              then 'ALLOWED (BAD)' else 'DENIED (good)' end
  union all
  select 'select on app.orders for anon',
         case when has_table_privilege('anon','app.orders','SELECT')
              then 'ALLOWED (BAD)' else 'DENIED (good)' end
  union all
  select 'execute sync_pull for authenticated',
         case when has_function_privilege('authenticated','public.sync_pull(bigint)','EXECUTE')
              then 'ALLOWED (good)' else 'DENIED (BAD)' end
  union all
  select 'execute sync_push for anon',
         case when has_function_privilege('anon','public.sync_push(jsonb,bigint)','EXECUTE')
              then 'ALLOWED (BAD)' else 'DENIED (good)' end
  union all
  select 'execute dispatch_order for anon',
         case when has_function_privilege('anon','public.dispatch_order(uuid)','EXECUTE')
              then 'ALLOWED (BAD)' else 'DENIED (good)' end
  union all
  select 'app_api can select app.orders',
         case when has_table_privilege('app_api','app.orders','SELECT')
              then 'ALLOWED (good)' else 'DENIED (BAD)' end
  union all
  select 'app_api can delete app.orders',
         case when has_table_privilege('app_api','app.orders','DELETE')
              then 'ALLOWED (BAD)' else 'DENIED (good)' end
  union all
  -- The price-correction log is append-only (0025).
  select 'app_api can update app.order_price_changes',
         case when has_table_privilege('app_api','app.order_price_changes','UPDATE')
              then 'ALLOWED (BAD)' else 'DENIED (good)' end
  union all
  -- Supplier payments are append-only (0026). 0005's `alter default
  -- privileges` grants app_api UPDATE on every new app table, so this asserts
  -- the migration took it back.
  select 'app_api can update app.purchase_payments',
         case when has_table_privilege('app_api','app.purchase_payments','UPDATE')
              then 'ALLOWED (BAD)' else 'DENIED (good)' end
  union all
  select 'app_api can delete app.purchase_payments',
         case when has_table_privilege('app_api','app.purchase_payments','DELETE')
              then 'ALLOWED (BAD)' else 'DENIED (good)' end
  union all
  select 'app_api has BYPASSRLS',
         case when exists (select 1 from pg_roles where rolname='app_api' and rolbypassrls)
              then 'YES (BAD)' else 'NO (good)' end
) t order by what;

\echo '== 2. Advisor-equivalent lints (must return zero rows) ===================='

-- Mirrors the rules Supabase's security advisor applies, plus two of our own:
-- no table may sit in an exposed schema, and no SECURITY DEFINER function in
-- public may be owned by a BYPASSRLS role (which would make RLS decorative).
-- bootstrap_business is the one sanctioned exception -- it necessarily runs
-- before the caller has a profile for RLS to match on.
with
rls_missing as (
  select 'rls_disabled' as lint, n.nspname||'.'||c.relname as object
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind='r' and n.nspname in ('public','app') and not c.relrowsecurity
),
rls_not_forced as (
  select 'rls_not_forced', n.nspname||'.'||c.relname
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind='r' and n.nspname='app' and not c.relforcerowsecurity
),
rls_no_policy as (
  select 'rls_enabled_no_policy', n.nspname||'.'||c.relname
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind='r' and n.nspname in ('public','app') and c.relrowsecurity
    and not exists (select 1 from pg_policy p where p.polrelid=c.oid)
),
mutable_search_path as (
  select 'function_search_path_mutable', n.nspname||'.'||p.proname
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname in ('public','app') and p.prokind='f'
    and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) cfg
                    where cfg like 'search_path=%')
),
secdef_view as (
  select 'security_definer_view', n.nspname||'.'||c.relname
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind='v' and n.nspname in ('public','app')
    and not coalesce((select option_value::boolean
                      from pg_options_to_table(c.reloptions)
                      where option_name='security_invoker'), false)
),
table_in_exposed_schema as (
  select 'table_in_exposed_schema', n.nspname||'.'||c.relname
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind='r' and n.nspname='public'
),
client_reachable as (
  select 'client_role_has_table_privilege',
         table_schema||'.'||table_name||' -> '||grantee||':'||privilege_type
  from information_schema.role_table_grants
  where grantee in ('anon','authenticated') and table_schema in ('app','public')
),
secdef_owner as (
  select 'security_definer_owned_by_bypassrls_role',
         n.nspname||'.'||p.proname||' owner='||pg_get_userbyid(p.proowner)
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  join pg_roles o on o.oid=p.proowner
  where n.nspname='public' and p.prosecdef and o.rolbypassrls
    and p.prokind='f'
    -- The sanctioned exceptions. Each one necessarily runs before the caller
    -- has a profile for RLS to match on, or is deliberately cross-tenant.
    -- Kept in step with the same allowlist in admin_security.sql; a function
    -- added here without being added there (or vice versa) is a review smell.
    and p.proname <> 'bootstrap_business'   -- sanctioned, see 0007
    and p.proname <> 'claim_invite'         -- sanctioned, see 0014
    and p.proname not like 'admin\_%'       -- sanctioned, see 0013/0015
    and p.proname <> 'rls_auto_enable'      -- Supabase platform event trigger
),
-- ---------------------------------------------------------------------------
-- The read layer's guard rails (added with 0017).
--
-- The tenant analogue of admin_security.sql's admin_fn_without_guard. There are
-- now seventeen read functions in public, each of which is one forgotten
-- `perform app.require_member()` away from serving another shop's books. Nothing
-- in SQL compiles that boundary, so it is asserted mechanically instead: a new
-- list_/get_ function that omits the guard, or that never mentions
-- current_business_id, fails this suite rather than shipping.
--
-- get_my_context is the one deliberate exemption: it is callable before a
-- membership exists, because it is what the app uses to discover that it has
-- none. See 0017.
-- ---------------------------------------------------------------------------
read_fn_without_guard as (
  select 'tenant_read_function_missing_guard',
         p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind='f'
    and (p.proname like 'list\_%' or p.proname like 'get\_%')
    and p.proname not like 'admin\_%'
    and p.proname <> 'get_my_context'
    and pg_get_functiondef(p.oid) !~ 'require_member|require_role|require_platform_admin'
),
read_fn_without_tenant_scope as (
  select 'tenant_read_function_missing_business_scope',
         p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind='f'
    and (p.proname like 'list\_%' or p.proname like 'get\_%')
    and p.proname not like 'admin\_%'
    and pg_get_functiondef(p.oid) !~ 'current_business_id'
),
-- A read marked VOLATILE cannot be inlined or cached by the planner, and on a
-- 2G connection every avoidable re-plan is felt. Cheap to assert, easy to forget.
read_fn_not_stable as (
  select 'read_function_not_stable',
         p.proname||' volatility='||p.provolatile::text
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind='f'
    and (p.proname like 'list\_%' or p.proname like 'get\_%')
    and p.provolatile = 'v'
)
select * from rls_missing
union all select * from rls_not_forced
union all select * from rls_no_policy
union all select * from mutable_search_path
union all select * from secdef_view
union all select * from table_in_exposed_schema
union all select * from client_reachable
union all select * from secdef_owner
union all select * from read_fn_without_guard
union all select * from read_fn_without_tenant_scope
union all select * from read_fn_not_stable
order by 1,2;

\echo '== 3. Behavioural checks =================================================='
\echo 'Each of the following MUST raise. Run them one at a time.'

-- 3a. Cross-tenant overwrite: business B pushes business A''s raw material id.
--     Expected: 42501 new row violates row-level security policy
-- set local role authenticated;
-- set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
-- select public.sync_push('{"raw_materials":{"updated":[
--   {"id":"aaaaaaa1-0000-4000-8000-000000000001","name":"HIJACKED"}]}}'::jsonb);

-- 3b. Privilege escalation: a packer pushes a profiles row making itself OWNER.
--     Expected: 42501 table profiles is not writable from a client
-- select public.sync_push('{"profiles":{"updated":[
--   {"id":"33333333-3333-3333-3333-333333333333","role":"OWNER"}]}}'::jsonb);

-- 3c. Ledger delete through sync.
--     Expected: 42501 rows in stock_ledger cannot be deleted
-- select public.sync_push('{"stock_ledger":{"deleted":
--   ["51000cc1-0000-4000-8000-000000000001"]}}'::jsonb);

-- 3d. Ledger mutation, bypassing the API entirely (run as postgres).
--     Expected: 42501 stock_ledger is append-only
-- update app.stock_ledger set qty_base = 999999
--  where id = '51000cc1-0000-4000-8000-000000000001';

-- 3e. Role enforcement: a packer creates an order.
--     Expected: 42501 role PACKER may not perform this operation
-- set local request.jwt.claims = '{"sub":"33333333-3333-3333-3333-333333333333","role":"authenticated"}';
-- select public.create_order('0dde0001-0000-4000-8000-000000000009',
--   'ccccccc1-0000-4000-8000-000000000001',
--   '[{"packed_sku_id":"bbbbbbb1-0000-4000-8000-000000000001","qty_packets":1}]'::jsonb);

\echo 'And these MUST succeed with the stated result:'

-- 3f. A hostile payload is neutralised: business_id, created_by and created_at
--     supplied by the client are all overwritten by the server.
--     After pushing a row with business_id=00000000-...-ff and created_at=0,
--     the stored row must carry the caller''s business, the caller''s user id,
--     and a created_at within seconds of now().

-- 3g. Tenant isolation on pull: business B''s sync_pull(null) returns exactly
--     one businesses row (its own) and zero rows from business A.

-- 3h. Device A -> device B: after A pushes, B''s sync_pull(cursor) returns the
--     rows A pushed. This is the Phase 0 acceptance criterion.

-- 3i. Dispatch deducts stock exactly once. dispatch_order twice in a row must
--     leave the same quantity and report already_dispatched on the second call.

-- 3j. Partial payment leaves the order open with the right outstanding amount;
--     the balancing payment closes it and takes outstanding to zero.

-- 3k. The GSTIN toggle is free and works: with show_gstin_on_receipt false the
--     receipt''s business.gstin is null; with it true the GSTIN appears.

-- 3l. A supplier payment cannot be rewritten (run as postgres, 0026).
--     Expected: 42501 app.purchase_payments is append-only
-- update app.purchase_payments set amount = 1 where id = '<a payment id>';

-- 3m. Cancelling a received purchase reverses its stock exactly. Note the
--     on-hand figure, cancel_purchase(id), and the figure must return to what
--     it was before the bill was received -- via a NEGATIVE PURCHASE_IN row,
--     not an ADJUSTMENT, and not by rewriting the original.
