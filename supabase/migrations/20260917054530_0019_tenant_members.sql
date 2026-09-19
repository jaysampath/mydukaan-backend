-- 0019_tenant_members
--
-- Owner-side staff management. Until now the only way to add a colleague was
-- for a platform operator to issue an invite from the admin portal, so an owner
-- who hired a packer had to phone support. These are the tenant-scoped
-- equivalents of the admin_set_member_* / admin_create_invite functions from
-- 0015.
--
-- Owned by app_api, NOT postgres. The caller has a profile, so
-- app.current_business_id() resolves and RLS applies normally -- there is no
-- reason to reach for the BYPASSRLS exception that bootstrap_business and the
-- admin_* set need. The allowlist in supabase/tests/admin_security.sql is
-- therefore unchanged.
--
-- Guard discipline mirrors 0015: OWNER-only for anything that changes the
-- roster, the last-OWNER protections, and the seat cap.

-- ---------------------------------------------------------------------------
-- Seat accounting, and a bug fix.
--
-- admin_create_invite (0015) and claim_invite (0016) both count the seat cap
-- against ACTIVE PROFILES ONLY. Pending unclaimed invites reserve nothing, so a
-- business with a 5-seat cap and 1 member can mint 10 valid tokens. The first
-- four claims succeed and the fifth fails -- on the new hire's phone, at the
-- worst possible moment, with a message about seats they cannot act on.
--
-- The fix belongs at the ISSUE path, not the claim path:
--
--   issuing  counts active profiles + live pending invites, so a seat is
--            reserved from the moment it is promised. Over-issuing becomes
--            impossible.
--   claiming keeps counting active profiles only, which is correct: the
--            pending invite is about to BECOME a profile, so counting both
--            would double-count and refuse a legitimate claim. It stays the
--            final backstop for the case where seats filled in between.
--
-- claim_invite is therefore deliberately NOT modified here.
-- ---------------------------------------------------------------------------

create or replace function app.seats_used(p_business uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $fn$
  select
    (select count(*) from app.profiles
      where business_id = p_business and is_active and deleted_at is null)
  + (select count(*) from app.business_invites
      where business_id = p_business
        and claimed_at is null
        and deleted_at is null
        and expires_at > now())
$fn$;

comment on function app.seats_used(uuid) is
  'Active members plus live unclaimed invites. Use at the point an invite is ISSUED so a promised seat is reserved. claim_invite deliberately counts active profiles only, or it would double-count the invite being claimed.';

-- Re-stated to reserve seats for pending invites. Body is otherwise identical
-- to 0015; only the seat count changes.
create or replace function public.admin_create_invite(
  p_business_id uuid,
  p_role        text,
  p_phone       text default null,
  p_email       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_token text;
  v_id    uuid;
  v_limit integer;
begin
  perform app.require_platform_admin();

  if p_role not in ('OWNER','MANAGER','PACKER','DELIVERY') then
    raise exception 'unknown role %', p_role using errcode = '22023';
  end if;
  if coalesce(p_phone, p_email) is null then
    raise exception 'a phone or email is required' using errcode = '22023';
  end if;
  if not exists (select 1 from app.businesses where id = p_business_id and deleted_at is null) then
    raise exception 'business % not found', p_business_id using errcode = 'P0002';
  end if;

  select seat_limit into v_limit from app.businesses where id = p_business_id;
  if app.seats_used(p_business_id) >= v_limit then
    raise exception 'this business has used all % of its seats', v_limit
      using errcode = '23514', hint = 'seat_limit';
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');

  insert into app.business_invites (
    business_id, role, phone, email, token, expires_at, created_by
  ) values (
    p_business_id, p_role, p_phone, p_email, v_token,
    now() + interval '30 days', app.current_user_id()
  )
  returning id into v_id;

  return jsonb_build_object('invite_id', v_id, 'invite_token', v_token, 'role', p_role);
end
$fn$;

alter function public.admin_create_invite(uuid, text, text, text) owner to postgres;

-- ---------------------------------------------------------------------------
-- The roster.
--
-- OWNER only, because it returns live invite tokens. A token readable by a
-- PACKER is a seat-stealing primitive: they could claim it on a second account,
-- or pass it on. A MANAGER does not need the roster in V1.
-- ---------------------------------------------------------------------------

create or replace function public.list_members()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_limit    integer;
begin
  perform app.require_role('OWNER');
  select seat_limit into v_limit from app.businesses where id = v_business;

  return jsonb_build_object(
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'user_id', p.id, 'full_name', p.full_name, 'phone', p.phone,
               'role', p.role, 'is_active', p.is_active, 'created_at', p.created_at,
               'is_self', (p.id = app.current_user_id())
             ) order by p.is_active desc, p.full_name), '[]'::jsonb)
      from app.profiles p
      where p.business_id = v_business and p.deleted_at is null
    ),
    'invites', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', i.id, 'role', i.role, 'phone', i.phone, 'email', i.email,
               'token', i.token, 'expires_at', i.expires_at, 'created_at', i.created_at
             ) order by i.created_at desc), '[]'::jsonb)
      from app.business_invites i
      where i.business_id = v_business
        and i.claimed_at is null
        and i.deleted_at is null
        and i.expires_at > now()
    ),
    'seats', jsonb_build_object(
      'limit', v_limit,
      'used', app.seats_used(v_business),
      'available', greatest(v_limit - app.seats_used(v_business), 0)
    )
  );
end
$fn$;

alter function public.list_members() owner to app_api;
revoke all on function public.list_members() from public, anon;
grant execute on function public.list_members() to authenticated;

-- ---------------------------------------------------------------------------
-- Issuing and revoking invites.
--
-- Takes the invite id FROM THE CALLER, unlike admin_create_invite which mints
-- one server-side. That divergence is deliberate, not an oversight to be
-- "harmonised": admin_create_invite is not retry-safe, so an operator whose
-- request times out and retries creates a second orphan invite holding a
-- second seat. The tenant version follows the caller-minted-uuid convention
-- that every other operation RPC in this codebase uses.
-- ---------------------------------------------------------------------------

create or replace function public.invite_member(
  p_invite_id uuid,
  p_role      text,
  p_phone     text default null,
  p_email     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_limit    integer;
  v_token    text;
  v_existing app.business_invites;
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();

  -- Idempotent retry. FOUND, not `v_existing is not null` -- phone, email and
  -- claimed_at are all routinely null. See 0016.
  select * into v_existing from app.business_invites where id = p_invite_id;
  if found then
    if v_existing.business_id <> v_business then
      raise exception 'invite % not found', p_invite_id using errcode = 'P0002';
    end if;
    return jsonb_build_object(
      'invite_id', p_invite_id, 'invite_token', v_existing.token,
      'role', v_existing.role, 'created', false);
  end if;

  if p_role not in ('OWNER','MANAGER','PACKER','DELIVERY') then
    raise exception 'unknown role %', p_role using errcode = '22023';
  end if;
  if coalesce(nullif(btrim(coalesce(p_phone,'')),''),
              nullif(btrim(coalesce(p_email,'')),'')) is null then
    raise exception 'a phone or email is required' using errcode = '22023';
  end if;

  select seat_limit into v_limit from app.businesses where id = v_business;
  if app.seats_used(v_business) >= v_limit then
    raise exception 'all % seats are in use; free one before inviting someone else', v_limit
      using errcode = '23514', hint = 'seat_limit';
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');

  insert into app.business_invites (
    id, business_id, role, phone, email, token, expires_at, created_by
  ) values (
    p_invite_id, v_business, p_role,
    nullif(btrim(coalesce(p_phone,'')),''), nullif(btrim(coalesce(p_email,'')),''),
    v_token, now() + interval '30 days', app.current_user_id()
  );

  return jsonb_build_object(
    'invite_id', p_invite_id, 'invite_token', v_token,
    'role', p_role, 'created', true);
end
$fn$;

alter function public.invite_member(uuid, text, text, text) owner to app_api;
revoke all on function public.invite_member(uuid, text, text, text) from public, anon;
grant execute on function public.invite_member(uuid, text, text, text) to authenticated;

-- An owner who typos a phone number has minted a live token that now holds a
-- seat. Without this there is no way to kill it short of waiting 30 days.
create or replace function public.revoke_member_invite(p_invite_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_invite   app.business_invites;
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();

  select * into v_invite from app.business_invites
  where id = p_invite_id and business_id = v_business and deleted_at is null;

  if not found then
    raise exception 'invite % not found', p_invite_id using errcode = 'P0002';
  end if;
  if v_invite.claimed_at is not null then
    raise exception 'that invitation has already been used; deactivate the member instead'
      using errcode = '22023';
  end if;

  update app.business_invites set deleted_at = now() where id = p_invite_id;
  return jsonb_build_object('invite_id', p_invite_id, 'revoked', true);
end
$fn$;

alter function public.revoke_member_invite(uuid) owner to app_api;
revoke all on function public.revoke_member_invite(uuid) from public, anon;
grant execute on function public.revoke_member_invite(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Changing a colleague's role or access.
--
-- The last-OWNER guards are the important part. A business with no active owner
-- cannot manage its own staff, cannot change its settings, and cannot recover
-- without a platform operator -- so both paths refuse rather than letting an
-- owner lock themselves out. Mirrors admin_set_member_role /
-- admin_set_member_active (0015:293-386).
-- ---------------------------------------------------------------------------

create or replace function public.set_member_role(p_user_id uuid, p_role text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_current  text;
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();

  if p_role not in ('OWNER','MANAGER','PACKER','DELIVERY') then
    raise exception 'unknown role %', p_role using errcode = '22023';
  end if;

  select role into v_current from app.profiles
  where id = p_user_id and business_id = v_business and deleted_at is null;

  if not found then
    raise exception 'member % not found', p_user_id using errcode = 'P0002';
  end if;

  -- Demoting the last active owner would leave the business ownerless.
  if v_current = 'OWNER' and p_role <> 'OWNER' then
    if (select count(*) from app.profiles
          where business_id = v_business and role = 'OWNER'
            and is_active and deleted_at is null and id <> p_user_id) = 0 then
      raise exception 'this is the only owner; make someone else an owner first'
        using errcode = '23514', hint = 'last_owner';
    end if;
  end if;

  update app.profiles set role = p_role where id = p_user_id;
  return jsonb_build_object('user_id', p_user_id, 'role', p_role);
end
$fn$;

alter function public.set_member_role(uuid, text) owner to app_api;
revoke all on function public.set_member_role(uuid, text) from public, anon;
grant execute on function public.set_member_role(uuid, text) to authenticated;

-- One function, two client verbs (deactivateMember / reactivateMember), because
-- reactivation has to pass the seat cap and that rule should not be stated
-- twice.
create or replace function public.set_member_active(p_user_id uuid, p_is_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_member   record;
  v_limit    integer;
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();

  select p.role, p.is_active into v_member from app.profiles p
  where p.id = p_user_id and p.business_id = v_business and p.deleted_at is null;

  if not found then
    raise exception 'member % not found', p_user_id using errcode = 'P0002';
  end if;

  if not p_is_active then
    -- Locking yourself out is never what you meant.
    if p_user_id = app.current_user_id() then
      raise exception 'you cannot deactivate your own account'
        using errcode = '23514', hint = 'self_deactivate';
    end if;
    if v_member.role = 'OWNER'
       and (select count(*) from app.profiles
              where business_id = v_business and role = 'OWNER'
                and is_active and deleted_at is null and id <> p_user_id) = 0 then
      raise exception 'this is the only owner; make someone else an owner first'
        using errcode = '23514', hint = 'last_owner';
    end if;
  else
    -- Reactivation takes a seat, so it has to pass the cap. seats_used already
    -- excludes this member (they are inactive), so no adjustment is needed.
    select seat_limit into v_limit from app.businesses where id = v_business;
    if not v_member.is_active and app.seats_used(v_business) >= v_limit then
      raise exception 'all % seats are in use; free one before reactivating', v_limit
        using errcode = '23514', hint = 'seat_limit';
    end if;
  end if;

  update app.profiles set is_active = p_is_active where id = p_user_id;
  return jsonb_build_object('user_id', p_user_id, 'is_active', p_is_active);
end
$fn$;

alter function public.set_member_active(uuid, boolean) owner to app_api;
revoke all on function public.set_member_active(uuid, boolean) from public, anon;
grant execute on function public.set_member_active(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Your own name and number.
--
-- claim_invite sets full_name once, at claim time, and until now nothing could
-- change it -- profiles was pull-only in sync and there is no upsert_profile.
-- Deliberately does NOT accept role or is_active: this is the one member-facing
-- write on profiles, and letting it touch role would make every member their
-- own administrator.
-- ---------------------------------------------------------------------------

create or replace function public.update_my_profile(
  p_full_name text default null,
  p_phone     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_user uuid := app.current_user_id();
  v_name text := nullif(btrim(coalesce(p_full_name, '')), '');
begin
  perform app.require_member();
  perform app.require_write_access();

  if v_name is null and p_phone is null then
    raise exception 'nothing to update' using errcode = '22023';
  end if;
  if v_name is not null and length(v_name) > 120 then
    raise exception 'name is too long' using errcode = '22023';
  end if;

  update app.profiles
     set full_name = coalesce(v_name, full_name),
         phone     = coalesce(nullif(btrim(coalesce(p_phone,'')),''), phone)
   where id = v_user;

  return (
    select jsonb_build_object(
      'user_id', p.id, 'full_name', p.full_name, 'phone', p.phone, 'role', p.role)
    from app.profiles p where p.id = v_user
  );
end
$fn$;

alter function public.update_my_profile(text, text) owner to app_api;
revoke all on function public.update_my_profile(text, text) from public, anon;
grant execute on function public.update_my_profile(text, text) to authenticated;
