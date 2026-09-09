-- 0013_platform_admin
--
-- A platform operator is cross-tenant, which the existing model has no room
-- for: app.current_business_id() reads the caller's profile, an operator has no
-- profile, so every tenant policy denies and every RPC raises. This adds that
-- concept without loosening anything that already exists.
--
-- Note what is NOT here: a new database role. The first draft created an
-- `app_admin` role with BYPASSRLS to own the admin functions, which would have
-- made "who has god-mode" a property of the catalog. It is not worth minting a
-- second superuser-adjacent role for: public.bootstrap_business already
-- established postgres-owned SECURITY DEFINER as the sanctioned exception, and
-- the admin functions in 0015 follow it. What replaces the catalog check is an
-- assertion in supabase/tests/admin_security.sql: every admin_* function must
-- contain app.require_platform_admin(), so one that forgets the guard fails the
-- suite rather than shipping.

create table if not exists app.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  label      text not null default '',
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table app.platform_admins is
  'Cross-tenant operators. Deliberately has no business_id and no INSERT/UPDATE policy: membership is granted by migration or by hand in SQL, never through any application.';

alter table app.platform_admins enable row level security;
alter table app.platform_admins force row level security;

-- Self-select only. An admin can confirm their own row; nobody -- admin or not
-- -- can enumerate the others. There is deliberately no INSERT or UPDATE
-- policy, so no application code path can create or promote an operator.
create policy self_select on app.platform_admins for select
  using (user_id = app.current_user_id());

create trigger platform_admins_touch
  before insert or update on app.platform_admins
  for each row execute function app.touch_updated_at();

grant select on app.platform_admins to app_api;

create or replace function app.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select exists (
    select 1 from app.platform_admins
    where user_id = app.current_user_id()
      and is_active
  )
$fn$;

comment on function app.is_platform_admin() is
  'Cross-tenant operator check. postgres-owned and SECURITY DEFINER for the same reason as app.current_business_id(): a policy on app.platform_admins that called it would otherwise recurse through the table it protects.';

create or replace function app.require_platform_admin()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if not app.is_platform_admin() then
    raise exception 'caller is not a platform administrator'
      using errcode = '42501';
  end if;
end
$fn$;

-- Granting operator access, for reference. There is no RPC for this on purpose:
--
--   insert into app.platform_admins (user_id, label)
--   select id, 'ops: you@example.com' from auth.users where email = 'you@example.com';
