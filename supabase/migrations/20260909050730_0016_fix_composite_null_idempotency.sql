-- 0016_fix_composite_null_idempotency
--
-- Fixes the plpgsql composite-NULL trap in two places.
--
-- For a ROWTYPE variable, `rec IS NOT NULL` is true only when EVERY column is
-- non-null -- it is not the negation of `rec IS NULL`. Both functions below
-- used it to mean "a row was found", and a row that is found almost always has
-- some nullable column set to NULL, so the test silently never fired.
--
--   public.create_order   The idempotency check never matched, so the retry a
--                         phone makes after its connection drops mid-call fell
--                         through to the INSERT and raised 23505 instead of
--                         returning created:false. This broke the retry-safety
--                         guarantee that 0007's own header promises and that
--                         docs/supabase-access.md states -- and it broke it
--                         precisely in the situation it exists for. Present
--                         since Phase 0; found by scripts/admin-contract-test.mjs
--                         hitting the same shape in claim_invite.
--
--   public.claim_invite   The "do you already belong to a business?" check
--                         never matched either, so a user with an existing
--                         profile got a duplicate-key error rather than the
--                         intended refusal, and the one-user-one-business rule
--                         was enforced only by the primary key.
--
-- Both now use `FOUND`, which is what actually reports whether SELECT INTO
-- matched a row. Note that `rec IS NULL` for "no row" is correct and is left
-- alone: when nothing is found every column is null, so it holds.

create or replace function public.create_order(
  p_order_id    uuid,
  p_customer_id uuid,
  p_items       jsonb,
  p_notes       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_user     uuid := app.current_user_id();
  v_total    numeric(14,2);
  v_no       bigint;
  v_existing app.orders;
begin
  perform app.require_role('OWNER', 'MANAGER');
  perform app.require_write_access();

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'an order needs at least one item' using errcode = '22023';
  end if;

  select * into v_existing from app.orders
  where id = p_order_id and business_id = v_business;
  if found then
    return jsonb_build_object('order_id', p_order_id, 'order_no', v_existing.order_no, 'created', false);
  end if;

  if not exists (
    select 1 from app.customers
    where id = p_customer_id and business_id = v_business and deleted_at is null
  ) then
    raise exception 'customer % not found', p_customer_id using errcode = 'P0002';
  end if;

  insert into app.orders (id, business_id, customer_id, status, notes, created_by)
  values (p_order_id, v_business, p_customer_id, 'PLACED', p_notes, v_user);

  insert into app.order_items (business_id, order_id, packed_sku_id, qty_packets, unit_price, created_by)
  select v_business,
         p_order_id,
         (e.r ->> 'packed_sku_id')::uuid,
         (e.r ->> 'qty_packets')::numeric,
         coalesce((e.r ->> 'unit_price')::numeric, ps.sale_price),
         v_user
  from jsonb_array_elements(p_items) as e(r)
  join app.packed_skus ps
    on ps.id = (e.r ->> 'packed_sku_id')::uuid
   and ps.business_id = v_business
   and ps.deleted_at is null;

  if (select count(*) from app.order_items where order_id = p_order_id)
     <> jsonb_array_length(p_items) then
    raise exception 'one or more SKUs do not belong to this business' using errcode = '22023';
  end if;

  select coalesce(sum(line_total), 0) into v_total
  from app.order_items where order_id = p_order_id and deleted_at is null;

  insert into app.business_counters (business_id, name, value)
  values (v_business, 'order_no', 1)
  on conflict (business_id, name) do update set value = app.business_counters.value + 1
  returning value into v_no;

  update app.orders set total_amount = v_total, order_no = v_no where id = p_order_id;

  return jsonb_build_object('order_id', p_order_id, 'order_no', v_no,
                            'total_amount', v_total, 'created', true);
end
$fn$;

alter function public.create_order(uuid, uuid, jsonb, text) owner to app_api;
revoke all on function public.create_order(uuid, uuid, jsonb, text) from public, anon;
grant execute on function public.create_order(uuid, uuid, jsonb, text) to authenticated;

create or replace function public.claim_invite(
  p_token     text,
  p_full_name text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_user   uuid := app.current_user_id();
  v_invite app.business_invites;
  v_seats  integer;
  v_limit  integer;
  v_existing app.profiles;
  v_has_profile boolean;
begin
  if v_user is null then
    raise exception 'sign in before claiming an invite' using errcode = '42501';
  end if;

  select * into v_invite
  from app.business_invites
  where token = p_token and deleted_at is null;

  -- One message for "no such token" and "already used", so a wrong guess
  -- cannot be told apart from a spent one.
  if not found or v_invite.claimed_at is not null then
    raise exception 'this invitation is not valid' using errcode = '42501';
  end if;
  if v_invite.expires_at <= now() then
    raise exception 'this invitation has expired' using errcode = '42501';
  end if;

  select * into v_existing from app.profiles where id = v_user;
  v_has_profile := found;

  if v_has_profile then
    if v_existing.business_id = v_invite.business_id then
      return jsonb_build_object(
        'business_id', v_invite.business_id,
        'role', v_existing.role,
        'already_member', true
      );
    end if;
    -- One user, one business in V1. Joining a second would make
    -- current_business_id() ambiguous, and every policy depends on it.
    raise exception 'this account already belongs to another business'
      using errcode = '42501';
  end if;

  select seat_limit into v_limit from app.businesses where id = v_invite.business_id;
  select count(*) into v_seats
  from app.profiles
  where business_id = v_invite.business_id and is_active and deleted_at is null;

  if v_seats >= v_limit then
    raise exception 'this business has used all % of its seats', v_limit
      using errcode = '23514', hint = 'seat_limit';
  end if;

  insert into app.profiles (id, business_id, full_name, phone, role, is_active, created_by)
  values (
    v_user, v_invite.business_id,
    coalesce(nullif(btrim(p_full_name), ''), coalesce(v_invite.phone, v_invite.email, 'Member')),
    v_invite.phone, v_invite.role, true, v_invite.created_by
  );

  update app.business_invites
     set claimed_at = now(), claimed_by = v_user
   where id = v_invite.id;

  return jsonb_build_object(
    'business_id', v_invite.business_id,
    'role', v_invite.role,
    'already_member', false
  );
end
$fn$;

revoke all on function public.claim_invite(text, text) from public, anon;
grant execute on function public.claim_invite(text, text) to authenticated;
