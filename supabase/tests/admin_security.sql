-- admin_security.sql
--
-- The checks the operator API must pass. Run against dev after any change to
-- migrations 0013-0015, alongside security_and_sync.sql.
--
--   psql "$DEV_DB_URL" -f supabase/tests/admin_security.sql
--
-- Section 1 is fully automatic and must return zero rows. Section 2 needs a
-- seeded operator and is written to be run as a block.

\echo '== 1. Structural assertions (every row here is a failure) ================='

with
-- ---------------------------------------------------------------------------
-- THE important one.
--
-- Every admin_* function runs with BYPASSRLS, because an operator is
-- cross-tenant and no tenant policy can match them. The ONLY thing standing
-- between that and a total tenant-isolation failure is the guard at the top of
-- each function body. This asserts it is actually there, so an admin RPC added
-- later that forgets it fails the suite instead of shipping.
-- ---------------------------------------------------------------------------
admin_fn_without_guard as (
  select 'admin_function_missing_require_platform_admin',
         p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname like 'admin\_%'
    and p.prokind = 'f'
    and pg_get_functiondef(p.oid) not like '%require_platform_admin%'
),

-- An admin function that is not SECURITY DEFINER cannot work (it would run as
-- the caller and see nothing), and one that is not postgres-owned cannot cross
-- tenants. Either means someone changed the model without meaning to.
admin_fn_not_secdef as (
  select 'admin_function_not_security_definer', p.proname
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'admin\_%'
    and p.prokind = 'f' and not p.prosecdef
),

-- The allowlist of privileged SECURITY DEFINER functions. Anything else that
-- appears here has god-mode without having been thought about.
secdef_owner as (
  select 'security_definer_owned_by_bypassrls_role',
         n.nspname || '.' || p.proname || ' owner=' || pg_get_userbyid(p.proowner)
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join pg_roles o on o.oid = p.proowner
  where n.nspname = 'public' and p.prosecdef and o.rolbypassrls
    and p.prokind = 'f'
    and p.proname <> 'bootstrap_business'   -- sanctioned, see 0007
    and p.proname <> 'claim_invite'         -- sanctioned, see 0014
    and p.proname <> 'rls_auto_enable'      -- Supabase platform event trigger
    and p.proname not like 'admin\_%'       -- sanctioned, see 0015
),

-- platform_admins must be RLS-protected like every other table, and must have
-- NO insert or update policy: an operator is created by migration or by hand,
-- never by an application.
admin_table_rls as (
  select 'platform_admins_rls_not_forced', c.relname::text
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'app' and c.relname = 'platform_admins'
    and not (c.relrowsecurity and c.relforcerowsecurity)
),
admin_table_writable as (
  select 'platform_admins_has_write_policy', pol.polname::text
  from pg_policy pol join pg_class c on c.oid = pol.polrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'app' and c.relname = 'platform_admins'
    and pol.polcmd <> 'r'
),

-- No client role may hold a privilege on either new table.
client_reachable as (
  select 'client_role_has_table_privilege',
         table_name || ' -> ' || grantee || ':' || privilege_type
  from information_schema.role_table_grants
  where grantee in ('anon', 'authenticated')
    and table_schema = 'app'
    and table_name in ('platform_admins', 'business_invites')
),

-- An invite token must never be replicated to devices.
invites_in_sync as (
  select 'business_invites_is_synced', 'business_invites'
  where 'business_invites' = any(app.synced_tables())
),

-- Every function must pin its search_path, admin ones included.
mutable_search_path as (
  select 'function_without_fixed_search_path', p.proname::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('app', 'public') and p.prokind = 'f'
    and p.prosecdef
    and not exists (
      select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%'
    )
)

select * from admin_fn_without_guard
union all select * from admin_fn_not_secdef
union all select * from secdef_owner
union all select * from admin_table_rls
union all select * from admin_table_writable
union all select * from client_reachable
union all select * from invites_in_sync
union all select * from mutable_search_path
order by 1, 2;

\echo ''
\echo '== 2. Behavioural checks ================================================='
\echo 'Needs a seeded operator. Each block states what MUST happen.'

-- Seed an operator for dev (idempotent):
--
--   insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
--     email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
--   values ('00000000-0000-0000-0000-000000000000',
--           '99999999-9999-9999-9999-999999999999',
--           'authenticated','authenticated','admin@dev.local','-',
--           now(),now(),now(),'{}','{}')
--   on conflict (id) do nothing;
--
--   insert into app.platform_admins (user_id, label)
--   values ('99999999-9999-9999-9999-999999999999','dev operator')
--   on conflict (user_id) do nothing;

-- 2a. A tenant OWNER must be refused by every admin_* function.
--     Expected: 42501 caller is not a platform administrator
-- set local role authenticated;
-- set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
-- select public.admin_list_businesses();
-- select public.admin_create_invite('af36f200-4a9a-48b9-beab-41c98ba8bd3c','OWNER','999');

-- 2b. Reachability: the same caller must not touch the table or the helper.
--     Expected (both): 42501 permission denied for schema app
-- select count(*) from app.platform_admins;
-- select app.is_platform_admin();

-- 2c. An operator has no profile, so the TENANT api must refuse them too.
--     An operator is not a super-user of any business; they administer the
--     platform. Expected: 42501 caller is not an active member of any business
-- set local request.jwt.claims = '{"sub":"99999999-9999-9999-9999-999999999999","role":"authenticated"}';
-- select public.sync_pull(null);
-- select public.get_stock_snapshot();

-- 2d. The operator sees every tenant. Expected: >= 2 businesses.
-- select jsonb_array_length(public.admin_list_businesses());

-- 2e. Onboarding is idempotent on the supplied id: the second call must
--     return created=false and must NOT mint a second invite.
-- select public.admin_create_business('<uuid>','Acme','9990001111');
-- select public.admin_create_business('<uuid>','Acme','9990001111');

-- 2f. A spent invite token must be refused, with the same message a bad token
--     gets, so the two cannot be told apart.
--     Expected: 42501 this invitation is not valid

-- 2g. The seat cap holds in three places:
--     - admin_create_invite refuses past the cap        (23514, hint seat_limit)
--     - claim_invite refuses past the cap               (23514, hint seat_limit)
--     - admin_set_seat_limit refuses shrinking below current usage (23514)

-- 2h. A business must never be left ownerless.
--     admin_set_member_role(last owner -> PACKER)   MUST raise 23514
--     admin_set_member_active(last owner, false)    MUST raise 23514

-- 2i. One user, one business: a member of business A claiming an invite to
--     business B must be refused.
--     Expected: 42501 this account already belongs to another business
