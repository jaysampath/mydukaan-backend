-- 0015_admin_rpcs
--
-- The operator API, consumed by the mydukaan-admin portal.
--
-- Every function here is owned by postgres and therefore runs with BYPASSRLS,
-- because an operator is cross-tenant and no tenant policy can match them.
-- That makes the guard load-bearing: EVERY function in this file opens with
-- `perform app.require_platform_admin()`, and supabase/tests/admin_security.sql
-- asserts mechanically that any admin_* function which forgets it fails the
-- suite.
--
-- The portal authenticates as an ordinary Supabase user and calls these with
-- its own JWT. There is no service_role key anywhere in the system.

create or replace function public.admin_list_businesses(
  p_search text default null,
  p_limit  integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_rows jsonb;
begin
  perform app.require_platform_admin();

  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'id', b.id,
      'name', b.name,
      'phone', b.phone,
      'gstin', b.gstin,
      'subscription_status', b.subscription_status,
      'trial_ends_at', b.trial_ends_at,
      'seat_limit', b.seat_limit,
      'seats_used', (
        select count(*) from app.profiles p
        where p.business_id = b.id and p.is_active and p.deleted_at is null
      ),
      'features', b.features,
      'created_at', b.created_at,
      'last_activity_at', greatest(
        b.updated_at,
        coalesce((select max(o.created_at) from app.orders o where o.business_id = b.id), b.created_at)
      )
    ) as x
    from app.businesses b
    where b.deleted_at is null
      and (p_search is null or btrim(p_search) = ''
           or b.name ilike '%' || btrim(p_search) || '%'
           or coalesce(b.phone,'') ilike '%' || btrim(p_search) || '%')
    order by b.name
    limit greatest(1, least(coalesce(p_limit, 50), 200))
    offset greatest(0, coalesce(p_offset, 0))
  ) s;

  return v_rows;
end
$fn$;

create or replace function public.admin_get_business(p_business_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business jsonb;
begin
  perform app.require_platform_admin();

  select jsonb_build_object(
    'id', b.id,
    'name', b.name,
    'phone', b.phone,
    'address', b.address,
    'gstin', b.gstin,
    'show_gstin_on_receipt', b.show_gstin_on_receipt,
    'currency', b.currency,
    'subscription_status', b.subscription_status,
    'trial_ends_at', b.trial_ends_at,
    'seat_limit', b.seat_limit,
    'features', b.features,
    'created_at', b.created_at,
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'user_id', p.id,
        'full_name', p.full_name,
        'phone', p.phone,
        'role', p.role,
        'is_active', p.is_active,
        'created_at', p.created_at
      ) order by p.created_at), '[]'::jsonb)
      from app.profiles p
      where p.business_id = b.id and p.deleted_at is null
    ),
    'invites', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id,
        'role', i.role,
        'phone', i.phone,
        'email', i.email,
        'token', i.token,
        'expires_at', i.expires_at,
        'claimed_at', i.claimed_at
      ) order by i.created_at desc), '[]'::jsonb)
      from app.business_invites i
      where i.business_id = b.id and i.deleted_at is null
    ),
    'counts', jsonb_build_object(
      'orders',    (select count(*) from app.orders o where o.business_id = b.id and o.deleted_at is null),
      'customers', (select count(*) from app.customers c where c.business_id = b.id and c.deleted_at is null),
      'payments',  (select count(*) from app.payments y where y.business_id = b.id)
    )
  ) into v_business
  from app.businesses b
  where b.id = p_business_id and b.deleted_at is null;

  if v_business is null then
    raise exception 'business % not found', p_business_id using errcode = 'P0002';
  end if;

  return v_business;
end
$fn$;

-- ---------------------------------------------------------------------------
-- Onboarding: create the business and the invite its first OWNER will claim.
-- Idempotent on the caller-supplied business id.
-- ---------------------------------------------------------------------------

create or replace function public.admin_create_business(
  p_business_id uuid,
  p_name        text,
  p_owner_phone text default null,
  p_owner_email text default null,
  p_gstin       text default null,
  p_trial_days  integer default 30,
  p_seat_limit  integer default 5
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_token text;
  v_invite uuid;
begin
  perform app.require_platform_admin();

  if p_name is null or btrim(p_name) = '' then
    raise exception 'business name is required' using errcode = '22023';
  end if;
  if coalesce(p_owner_phone, p_owner_email) is null then
    raise exception 'an owner phone or email is required' using errcode = '22023';
  end if;

  if exists (select 1 from app.businesses where id = p_business_id) then
    return jsonb_build_object('business_id', p_business_id, 'created', false);
  end if;

  insert into app.businesses (
    id, name, phone, gstin, subscription_status, trial_ends_at, seat_limit
  ) values (
    p_business_id, btrim(p_name), p_owner_phone, p_gstin,
    'TRIAL', now() + make_interval(days => greatest(0, coalesce(p_trial_days, 30))),
    greatest(1, coalesce(p_seat_limit, 5))
  );

  -- Order numbering starts here rather than on first push.
  insert into app.business_counters (business_id, name, value)
  values (p_business_id, 'order_no', 0)
  on conflict (business_id, name) do nothing;

  -- 256 bits from two UUIDs: no pgcrypto dependency, and not guessable.
  v_token := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');

  insert into app.business_invites (
    business_id, role, phone, email, token, expires_at, created_by
  ) values (
    p_business_id, 'OWNER', p_owner_phone, p_owner_email,
    v_token, now() + interval '30 days', app.current_user_id()
  )
  returning id into v_invite;

  return jsonb_build_object(
    'business_id', p_business_id,
    'created', true,
    'invite_id', v_invite,
    'invite_token', v_token
  );
end
$fn$;

-- ---------------------------------------------------------------------------
-- Subscription. The manual stand-in until RevenueCat, and a permanent support
-- tool after it. A lapse makes the app read-only; it never locks data away.
-- ---------------------------------------------------------------------------

create or replace function public.admin_set_subscription(
  p_business_id  uuid,
  p_status       text,
  p_trial_ends_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_row app.businesses;
begin
  perform app.require_platform_admin();

  if p_status not in ('TRIAL', 'ACTIVE', 'LAPSED') then
    raise exception 'status must be TRIAL, ACTIVE or LAPSED' using errcode = '22023';
  end if;

  update app.businesses
     set subscription_status = p_status,
         trial_ends_at = case
           when p_status = 'TRIAL' then coalesce(p_trial_ends_at, trial_ends_at, now() + interval '30 days')
           else coalesce(p_trial_ends_at, trial_ends_at)
         end
   where id = p_business_id and deleted_at is null
   returning * into v_row;

  if v_row is null then
    raise exception 'business % not found', p_business_id using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'business_id', v_row.id,
    'subscription_status', v_row.subscription_status,
    'trial_ends_at', v_row.trial_ends_at
  );
end
$fn$;

create or replace function public.admin_set_seat_limit(
  p_business_id uuid,
  p_seat_limit  integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_used integer;
  v_row  app.businesses;
begin
  perform app.require_platform_admin();

  if p_seat_limit is null or p_seat_limit < 1 then
    raise exception 'seat limit must be at least 1' using errcode = '22023';
  end if;

  select count(*) into v_used
  from app.profiles
  where business_id = p_business_id and is_active and deleted_at is null;

  -- Refuse rather than silently leaving the business over its own cap.
  if p_seat_limit < v_used then
    raise exception 'business already has % active members', v_used
      using errcode = '23514';
  end if;

  update app.businesses set seat_limit = p_seat_limit
   where id = p_business_id and deleted_at is null
   returning * into v_row;

  if v_row is null then
    raise exception 'business % not found', p_business_id using errcode = 'P0002';
  end if;

  return jsonb_build_object('business_id', v_row.id, 'seat_limit', v_row.seat_limit);
end
$fn$;

-- ---------------------------------------------------------------------------
-- Staff.
-- ---------------------------------------------------------------------------

create or replace function public.admin_set_member_role(
  p_business_id uuid,
  p_user_id     uuid,
  p_role        text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_owners integer;
  v_row    app.profiles;
begin
  perform app.require_platform_admin();

  if p_role not in ('OWNER','MANAGER','PACKER','DELIVERY') then
    raise exception 'unknown role %', p_role using errcode = '22023';
  end if;

  -- A business with no owner cannot change its own settings ever again.
  if p_role <> 'OWNER' then
    select count(*) into v_owners
    from app.profiles
    where business_id = p_business_id and role = 'OWNER'
      and is_active and deleted_at is null and id <> p_user_id;
    if v_owners = 0 then
      raise exception 'this is the last owner of the business' using errcode = '23514';
    end if;
  end if;

  update app.profiles set role = p_role
   where id = p_user_id and business_id = p_business_id and deleted_at is null
   returning * into v_row;

  if v_row is null then
    raise exception 'member % not found in business %', p_user_id, p_business_id
      using errcode = 'P0002';
  end if;

  return jsonb_build_object('user_id', v_row.id, 'role', v_row.role);
end
$fn$;

create or replace function public.admin_set_member_active(
  p_business_id uuid,
  p_user_id     uuid,
  p_is_active   boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_owners integer;
  v_seats  integer;
  v_limit  integer;
  v_row    app.profiles;
begin
  perform app.require_platform_admin();

  if p_is_active is false then
    select count(*) into v_owners
    from app.profiles
    where business_id = p_business_id and role = 'OWNER'
      and is_active and deleted_at is null and id <> p_user_id;
    if v_owners = 0 then
      raise exception 'this is the last active owner of the business' using errcode = '23514';
    end if;
  else
    -- Reactivating consumes a seat, so it has to respect the cap.
    select seat_limit into v_limit from app.businesses where id = p_business_id;
    select count(*) into v_seats
    from app.profiles
    where business_id = p_business_id and is_active and deleted_at is null and id <> p_user_id;
    if v_seats >= v_limit then
      raise exception 'this business has used all % of its seats', v_limit
        using errcode = '23514', hint = 'seat_limit';
    end if;
  end if;

  update app.profiles set is_active = p_is_active
   where id = p_user_id and business_id = p_business_id and deleted_at is null
   returning * into v_row;

  if v_row is null then
    raise exception 'member % not found in business %', p_user_id, p_business_id
      using errcode = 'P0002';
  end if;

  return jsonb_build_object('user_id', v_row.id, 'is_active', v_row.is_active);
end
$fn$;

-- ---------------------------------------------------------------------------
-- Invites.
-- ---------------------------------------------------------------------------

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
  v_token  text;
  v_id     uuid;
  v_seats  integer;
  v_limit  integer;
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

  -- Checked again in claim_invite, because seats can fill between issuing and
  -- claiming. This one exists so the operator finds out immediately.
  select seat_limit into v_limit from app.businesses where id = p_business_id;
  select count(*) into v_seats
  from app.profiles
  where business_id = p_business_id and is_active and deleted_at is null;
  if v_seats >= v_limit then
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

create or replace function public.admin_revoke_invite(p_invite_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_count integer;
begin
  perform app.require_platform_admin();

  update app.business_invites set deleted_at = now()
   where id = p_invite_id and claimed_at is null and deleted_at is null;
  get diagnostics v_count = row_count;

  return jsonb_build_object('invite_id', p_invite_id, 'revoked', v_count > 0);
end
$fn$;

-- ---------------------------------------------------------------------------
-- Grants. These are postgres-owned on purpose (see the header); `authenticated`
-- may call them, and app.require_platform_admin() is what actually decides.
-- ---------------------------------------------------------------------------

do $$
declare f text;
begin
  foreach f in array array[
    'public.admin_list_businesses(text,integer,integer)',
    'public.admin_get_business(uuid)',
    'public.admin_create_business(uuid,text,text,text,text,integer,integer)',
    'public.admin_set_subscription(uuid,text,timestamptz)',
    'public.admin_set_seat_limit(uuid,integer)',
    'public.admin_set_member_role(uuid,uuid,text)',
    'public.admin_set_member_active(uuid,uuid,boolean)',
    'public.admin_create_invite(uuid,text,text,text)',
    'public.admin_revoke_invite(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$$;
