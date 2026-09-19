-- 0017_read_rpcs
--
-- The read layer. This exists because offline sync was removed (see
-- mydukaan-mobile/docs/adr/0003-remove-offline-sync.md): every read used to come
-- from a local SQLite replica fed by sync_pull, and there were only three
-- server-side read models. With the replica gone the app needs a real read API.
--
-- Nothing here is new capability -- every row returned was already reachable
-- through sync_pull. What changes is the shape: one function per screen instead
-- of one bulk replication endpoint.
--
-- Four rules hold throughout, and the first is asserted mechanically by
-- supabase/tests/security_and_sync.sql (tenant_read_fn_without_guard):
--
--   1. Every function calls app.require_member() or app.require_role(), and
--      filters on app.current_business_id(). That filter is the ONLY thing
--      standing between one shop and another's books, now repeated seventeen
--      times -- which is exactly why it is asserted rather than trusted.
--   2. No function takes business_id. The tenant comes from the JWT.
--   3. Reads are NOT subscription-gated. A lapse is read-only, never a data
--      lock -- an owner who has not paid can still see their own books.
--   4. Timestamps cross the wire as ISO 8601 strings, via to_jsonb(). The
--      epoch-millisecond convention died with app.to_wire(); it existed for
--      WatermelonDB's @date fields and nothing else. JS new Date() parses ISO.
--
-- Pagination is clamped rather than trusted, matching admin_list_businesses in
-- 0015: an unbounded limit from a client is a memory incident waiting to happen.

-- ---------------------------------------------------------------------------
-- Guards.
--
-- app.require_member() replaces the enumeration require_role('OWNER','MANAGER',
-- 'PACKER','DELIVERY'), which is how "any member may read this" was expressed
-- in 0007. The enumeration is a latent bug: adding a fifth role silently denies
-- it every read it should have. Saying "must be a member" says what is meant.
-- ---------------------------------------------------------------------------

create or replace function app.require_member()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if app.current_business_id() is null then
    raise exception 'caller is not an active member of any business'
      using errcode = '42501';
  end if;
end
$fn$;

comment on function app.require_member() is
  'Any active member of any business. Use instead of enumerating every role when a read is open to the whole team.';

-- Extracted from app.require_write_access() so the subscription rule is stated
-- exactly once. get_my_context reports it to the app, which is what lets the
-- read-only banner exist without a TypeScript reimplementation of the
-- TRIAL/trial_ends_at/ACTIVE logic. src/db/models.ts carried such a copy
-- (Business.isReadOnly); it is being deleted and must not come back.
create or replace function app.has_write_access()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  b record;
begin
  select subscription_status, trial_ends_at into b
  from app.businesses
  where id = app.current_business_id();

  if not found then
    return false;
  end if;
  if b.subscription_status = 'ACTIVE' then
    return true;
  end if;
  if b.subscription_status = 'TRIAL'
     and (b.trial_ends_at is null or b.trial_ends_at > now()) then
    return true;
  end if;
  return false;
end
$fn$;

-- Re-stated in terms of the predicate. Behaviour and error are unchanged; the
-- 'no business in scope' case now also reports read_only, which is correct --
-- a caller with no business cannot write either.
create or replace function app.require_write_access()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if not app.has_write_access() then
    raise exception 'subscription is not active; the app is read-only until it is renewed'
      using errcode = '42501', hint = 'read_only';
  end if;
end
$fn$;

-- Shared pagination envelope. Callers select p_limit + 1 rows; this trims the
-- extra one and reports that it existed. has_more is deliberately not a
-- count(*) -- counting every order on every page load is the thing that gets
-- slow first, and "is there another page" is all the UI needs to know.
create or replace function app.page(p_rows jsonb, p_limit integer, p_offset integer)
returns jsonb
language sql
immutable
set search_path = ''
as $fn$
  select jsonb_build_object(
    'rows',     case when jsonb_array_length(p_rows) > p_limit
                     then p_rows - p_limit
                     else p_rows end,
    'has_more', jsonb_array_length(p_rows) > p_limit,
    'limit',    p_limit,
    'offset',   p_offset
  )
$fn$;

-- ---------------------------------------------------------------------------
-- One new RLS policy on app.profiles.
--
-- Without this, get_my_context cannot distinguish "you were deactivated" from
-- "you never joined a business". Both look identical: app.current_business_id()
-- filters on is_active, so a deactivated user gets null, the tenant_select
-- policy from 0005 then evaluates business_id = null, and the user's own row is
-- invisible to them.
--
-- Leaks nothing -- it is the caller's own row, keyed on app.current_user_id().
-- sync_pull never relied on policy alone here; it filtered by business_id
-- explicitly, which is why this gap went unnoticed.
-- ---------------------------------------------------------------------------

drop policy if exists profiles_self_select on app.profiles;
create policy profiles_self_select on app.profiles for select
  using (id = app.current_user_id());

-- ---------------------------------------------------------------------------
-- The launch call.
--
-- Deliberately does NOT call app.require_member(): this is the function the app
-- uses to discover whether it has a membership at all. A user who has signed in
-- but not yet claimed an invite, or who has been deactivated, must get a usable
-- answer so the app can route them. Raising 42501 would force the app to infer
-- onboarding state from an error message -- which is precisely what the Phase 0
-- screen did, by string-matching 'not an active member', and it was every bit as
-- brittle as it sounds.
--
-- Safe without a membership check because it reads only the caller's own
-- profile (by app.current_user_id(), via profiles_self_select) and the business
-- that profile points at.
-- ---------------------------------------------------------------------------

create or replace function public.get_my_context()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_user     uuid := app.current_user_id();
  v_business uuid := app.current_business_id();
  v_profile  record;
  v_biz      jsonb;
  v_state    text;
  v_used     integer;
  v_limit    integer;
begin
  if v_user is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  select p.id, p.full_name, p.phone, p.role, p.is_active, p.business_id
    into v_profile
  from app.profiles p
  where p.id = v_user and p.deleted_at is null;

  -- FOUND, not `v_profile is not null`: for a rowtype variable the latter is
  -- true only when EVERY column is non-null, and p.phone is routinely null.
  -- This trap already shipped one bug in this codebase; see migration 0016.
  if not found then
    v_state := 'NONE';
  elsif not v_profile.is_active then
    v_state := 'INACTIVE';
  else
    v_state := 'ACTIVE';
  end if;

  if v_business is not null then
    select b.seat_limit into v_limit from app.businesses b where b.id = v_business;

    select count(*) into v_used
    from app.profiles
    where business_id = v_business and is_active and deleted_at is null;

    select to_jsonb(x) into v_biz
    from (
      select b.id, b.name, b.phone, b.address, b.gstin, b.show_gstin_on_receipt,
             b.currency, b.subscription_status, b.trial_ends_at, b.seat_limit,
             b.features
      from app.businesses b
      where b.id = v_business and b.deleted_at is null
    ) x;
  end if;

  return jsonb_build_object(
    'user_id',          v_user,
    'membership_state', v_state,
    'profile',          case when v_state = 'NONE' then 'null'::jsonb
                        else jsonb_build_object(
                               'user_id',   v_profile.id,
                               'full_name', v_profile.full_name,
                               'phone',     v_profile.phone,
                               'role',      v_profile.role,
                               'is_active', v_profile.is_active)
                        end,
    'business',         coalesce(v_biz, 'null'::jsonb),
    -- Derived from app.has_write_access(), so there is exactly one copy of the
    -- subscription rule in the system and the client never re-derives it.
    'is_read_only',     case when v_business is null then true
                        else not app.has_write_access() end,
    'seats',            case when v_business is null then 'null'::jsonb
                        else jsonb_build_object(
                               'limit', v_limit,
                               'used', v_used,
                               'available', greatest(v_limit - v_used, 0))
                        end,
    -- The app checks this on launch. The local schema mirror is gone, but an
    -- old APK meeting a changed RPC return shape is still a real failure and
    -- users cannot be forced to update. See 0009, and 0020 which renames the
    -- concept to api_contract.
    'contract',         app.schema_contract(),
    'is_platform_admin', app.is_platform_admin(),
    'server_time',       now()
  );
end
$fn$;

comment on function public.get_my_context() is
  'Everything the app needs on launch: membership state, own profile, own business, read-only status, seats, API contract. Callable before membership exists -- do NOT add a membership check.';

alter function public.get_my_context() owner to app_api;
revoke all on function public.get_my_context() from public, anon;
grant execute on function public.get_my_context() to authenticated;

-- ---------------------------------------------------------------------------
-- Masters.
--
-- The two product lists carry current quantity, joined from the stock views.
-- That is deliberate: the order-entry picker needs id, price, pack size and
-- what is actually on the shelf, and making that two round trips on a 2G
-- connection to save a join is the wrong trade. LEFT JOIN because an item with
-- no ledger rows yet is absent from the view and must still be listable.
-- ---------------------------------------------------------------------------

create or replace function public.list_customers(
  p_search  text default null,
  p_limit   integer default 50,
  p_offset  integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_q        text;
  v_rows     jsonb;
begin
  perform app.require_member();
  v_q      := nullif(btrim(coalesce(p_search, '')), '');
  p_limit  := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb) into v_rows
  from (
    select c.id, c.name, c.phone, c.address, c.notes, c.created_at,
           coalesce(bal.outstanding, 0) as outstanding
    from app.customers c
    left join app.v_customer_balances bal
           on bal.customer_id = c.id and bal.business_id = c.business_id
    where c.business_id = v_business
      and c.deleted_at is null
      and (v_q is null or c.name ilike '%' || v_q || '%'
                       or c.phone ilike '%' || v_q || '%')
    order by c.name
    limit p_limit + 1 offset p_offset
  ) x;

  return app.page(v_rows, p_limit, p_offset);
end
$fn$;

alter function public.list_customers(text, integer, integer) owner to app_api;
revoke all on function public.list_customers(text, integer, integer) from public, anon;
grant execute on function public.list_customers(text, integer, integer) to authenticated;

create or replace function public.list_suppliers(
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
  v_business uuid := app.current_business_id();
  v_q        text;
  v_rows     jsonb;
begin
  -- Suppliers sit next to purchase costs; see the note on list_purchases.
  perform app.require_role('OWNER', 'MANAGER');
  v_q      := nullif(btrim(coalesce(p_search, '')), '');
  p_limit  := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb) into v_rows
  from (
    select s.id, s.name, s.phone, s.address, s.notes
    from app.suppliers s
    where s.business_id = v_business
      and s.deleted_at is null
      and (v_q is null or s.name ilike '%' || v_q || '%'
                       or s.phone ilike '%' || v_q || '%')
    order by s.name
    limit p_limit + 1 offset p_offset
  ) x;

  return app.page(v_rows, p_limit, p_offset);
end
$fn$;

alter function public.list_suppliers(text, integer, integer) owner to app_api;
revoke all on function public.list_suppliers(text, integer, integer) from public, anon;
grant execute on function public.list_suppliers(text, integer, integer) to authenticated;

-- Not paginated: a spice wholesaler has tens of raw materials, not thousands,
-- and the order and packing screens need the whole list in one picker.
create or replace function public.list_raw_materials(
  p_include_inactive boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
begin
  perform app.require_member();

  return (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb)
    from (
      select m.id, m.name, m.sku_code, m.base_unit, m.reorder_level_base, m.is_active,
             coalesce(st.qty_base, 0) as qty_base,
             -- reorder_level_base has been stored since 0002 and read by
             -- nothing. This is the first thing that looks at it.
             (coalesce(st.qty_base, 0) <= m.reorder_level_base) as below_reorder
      from app.raw_materials m
      left join app.v_raw_stock st
             on st.raw_material_id = m.id and st.business_id = m.business_id
      where m.business_id = v_business
        and m.deleted_at is null
        and (p_include_inactive or m.is_active)
      order by m.name
    ) x
  );
end
$fn$;

alter function public.list_raw_materials(boolean) owner to app_api;
revoke all on function public.list_raw_materials(boolean) from public, anon;
grant execute on function public.list_raw_materials(boolean) to authenticated;

create or replace function public.list_packed_skus(
  p_include_inactive boolean default false,
  p_raw_material_id  uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
begin
  perform app.require_member();

  return (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb)
    from (
      select s.id, s.raw_material_id, m.name as raw_material_name,
             s.name, s.pack_size_base, s.sku_code, s.sale_price, s.is_active,
             coalesce(st.qty_packets, 0) as qty_packets
      from app.packed_skus s
      join app.raw_materials m on m.id = s.raw_material_id
      left join app.v_packed_stock st
             on st.packed_sku_id = s.id and st.business_id = s.business_id
      where s.business_id = v_business
        and s.deleted_at is null
        and (p_include_inactive or s.is_active)
        and (p_raw_material_id is null or s.raw_material_id = p_raw_material_id)
      order by s.name
    ) x
  );
end
$fn$;

alter function public.list_packed_skus(boolean, uuid) owner to app_api;
revoke all on function public.list_packed_skus(boolean, uuid) from public, anon;
grant execute on function public.list_packed_skus(boolean, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Orders.
--
-- p_statuses is an array so one function serves the packing queue (PLACED), the
-- delivery run (OUT_FOR_DELIVERY) and the owner's full list. All members may
-- READ orders: a packer who cannot see the queue cannot pack, and a delivery
-- person who cannot see their run cannot deliver. Writing is what the role
-- checks in 0007 restrict.
-- ---------------------------------------------------------------------------

create or replace function public.list_orders(
  p_statuses    text[]  default null,
  p_customer_id uuid    default null,
  p_from        date    default null,
  p_to          date    default null,
  p_limit       integer default 50,
  p_offset      integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_rows     jsonb;
begin
  perform app.require_member();
  p_limit  := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.placed_at desc), '[]'::jsonb)
    into v_rows
  from (
    select o.id, o.order_no, o.customer_id,
           c.name as customer_name, c.phone as customer_phone,
           o.status, o.total_amount, o.notes,
           o.placed_at, o.packed_at, o.dispatched_at, o.delivered_at,
           o.closed_at, o.cancelled_at,
           coalesce(pay.paid, 0) as paid,
           o.total_amount - coalesce(pay.paid, 0) as balance,
           (select count(*) from app.order_items oi
             where oi.order_id = o.id and oi.deleted_at is null) as item_count
    from app.orders o
    join app.customers c on c.id = o.customer_id
    left join (
      select order_id, sum(amount) as paid
      from app.payments
      where business_id = v_business and order_id is not null
      group by order_id
    ) pay on pay.order_id = o.id
    where o.business_id = v_business
      and o.deleted_at is null
      and (p_statuses is null or o.status = any(p_statuses))
      and (p_customer_id is null or o.customer_id = p_customer_id)
      and (p_from is null or o.placed_at >= p_from::timestamptz)
      and (p_to is null or o.placed_at < (p_to + 1)::timestamptz)
    order by o.placed_at desc
    limit p_limit + 1 offset p_offset
  ) x;

  return app.page(v_rows, p_limit, p_offset);
end
$fn$;

alter function public.list_orders(text[], uuid, date, date, integer, integer) owner to app_api;
revoke all on function public.list_orders(text[], uuid, date, date, integer, integer) from public, anon;
grant execute on function public.list_orders(text[], uuid, date, date, integer, integer) to authenticated;

-- get_order returns allowed_transitions: the legal next actions for THIS order
-- in its current state.
--
-- The lifecycle rule currently lives in three places on the server --
-- set_order_status's PACKED|DELIVERED|PAYMENT_PENDING|CANCELLED allowlist,
-- dispatch_order's status guard, and record_payment's close condition. Handing
-- the client the resolved answer means it cannot render a button the server
-- will refuse, and the rule is still stated once, in SQL. The alternative is
-- every screen re-deriving the state machine in TypeScript, which is exactly
-- the duplication ADR 0002 was written to avoid and ADR 0003 finally removes.
--
-- Note what is deliberately ABSENT: 'cancel' once dispatched_at is set. There
-- is no reversal RPC yet, so set_order_status(...,'CANCELLED') on a dispatched
-- order flips the status while the SALE_OUT ledger rows stand -- the stock
-- never comes back. Withholding the action here is what keeps the app from
-- offering it, structurally rather than by convention. Add 'cancel' back when a
-- cancel_order RPC exists that writes the reversing rows.
create or replace function public.get_order(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_out      jsonb;
  v_status   text;
  v_disp     timestamptz;
  v_balance  numeric;
  v_next     jsonb := '[]'::jsonb;
begin
  perform app.require_member();

  select o.status, o.dispatched_at,
         o.total_amount - (select coalesce(sum(amount), 0)
                             from app.payments where order_id = o.id)
    into v_status, v_disp, v_balance
  from app.orders o
  where o.id = p_order_id and o.business_id = v_business and o.deleted_at is null;

  if not found then
    raise exception 'order % not found', p_order_id using errcode = 'P0002';
  end if;

  if v_status = 'PLACED' then
    v_next := v_next || jsonb_build_array('mark_packed');
  elsif v_status = 'PACKED' then
    v_next := v_next || jsonb_build_array('dispatch');
  elsif v_status = 'OUT_FOR_DELIVERY' then
    v_next := v_next || jsonb_build_array('mark_delivered');
  elsif v_status = 'DELIVERED' then
    v_next := v_next || jsonb_build_array('mark_payment_pending');
  end if;

  -- Cash can be taken at any live stage; record_payment closes the order when
  -- the balance reaches zero.
  if v_status not in ('CANCELLED', 'CLOSED') and v_balance > 0 then
    v_next := v_next || jsonb_build_array('record_payment');
  end if;

  -- Cancellable only while nothing has left the shelf. See the header.
  if v_disp is null and v_status not in ('CANCELLED', 'CLOSED') then
    v_next := v_next || jsonb_build_array('cancel');
  end if;

  select jsonb_build_object(
    'order', jsonb_build_object(
      'id', o.id, 'order_no', o.order_no, 'status', o.status,
      'total_amount', o.total_amount, 'notes', o.notes,
      'placed_at', o.placed_at, 'packed_at', o.packed_at,
      'dispatched_at', o.dispatched_at, 'delivered_at', o.delivered_at,
      'closed_at', o.closed_at, 'cancelled_at', o.cancelled_at
    ),
    'customer', jsonb_build_object(
      'id', c.id, 'name', c.name, 'phone', c.phone, 'address', c.address
    ),
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', oi.id,
               'packed_sku_id', oi.packed_sku_id,
               'name', ps.name,
               'pack_size_base', ps.pack_size_base,
               'qty_packets', oi.qty_packets,
               'unit_price', oi.unit_price,
               'line_total', oi.line_total,
               -- What is on the shelf right now, so the dispatch screen can
               -- show "4 needed, 20 on hand" without a second call.
               'qty_on_hand', coalesce(
                 (select st.qty_packets from app.v_packed_stock st
                   where st.packed_sku_id = ps.id and st.business_id = v_business), 0)
             ) order by ps.name), '[]'::jsonb)
      from app.order_items oi
      join app.packed_skus ps on ps.id = oi.packed_sku_id
      where oi.order_id = o.id and oi.deleted_at is null
    ),
    'payments', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'amount', p.amount, 'paid_on', p.paid_on, 'note', p.note
             ) order by p.paid_on desc, p.created_at desc), '[]'::jsonb)
      from app.payments p
      where p.order_id = o.id
    ),
    'paid', (select coalesce(sum(amount), 0) from app.payments where order_id = o.id),
    'balance', v_balance,
    'customer_outstanding', (
      select outstanding from app.v_customer_balances
      where customer_id = o.customer_id and business_id = v_business
    ),
    'allowed_transitions', v_next
  )
  into v_out
  from app.orders o
  join app.customers c on c.id = o.customer_id
  where o.id = p_order_id and o.business_id = v_business and o.deleted_at is null;

  return v_out;
end
$fn$;

alter function public.get_order(uuid) owner to app_api;
revoke all on function public.get_order(uuid) from public, anon;
grant execute on function public.get_order(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Purchases and packing.
--
-- Purchases are OWNER/MANAGER only, and this is the one genuine commercial
-- restriction in the read surface: purchase_items.unit_cost_base is what you
-- pay your supplier, and therefore your margin. A packer has no need for it.
-- ---------------------------------------------------------------------------

create or replace function public.list_purchases(
  p_supplier_id uuid    default null,
  p_status      text    default null,
  p_from        date    default null,
  p_to          date    default null,
  p_limit       integer default 50,
  p_offset      integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_rows     jsonb;
begin
  perform app.require_role('OWNER', 'MANAGER');
  p_limit  := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.purchased_on desc), '[]'::jsonb)
    into v_rows
  from (
    select pu.id, pu.purchase_no, pu.supplier_id, s.name as supplier_name,
           pu.invoice_no, pu.purchased_on, pu.total_amount, pu.notes,
           pu.status, pu.received_at,
           (select count(*) from app.purchase_items pi
             where pi.purchase_id = pu.id and pi.deleted_at is null) as item_count
    from app.purchases pu
    left join app.suppliers s on s.id = pu.supplier_id
    where pu.business_id = v_business
      and pu.deleted_at is null
      and (p_supplier_id is null or pu.supplier_id = p_supplier_id)
      and (p_status is null or pu.status = p_status)
      and (p_from is null or pu.purchased_on >= p_from)
      and (p_to is null or pu.purchased_on <= p_to)
    order by pu.purchased_on desc, pu.created_at desc
    limit p_limit + 1 offset p_offset
  ) x;

  return app.page(v_rows, p_limit, p_offset);
end
$fn$;

alter function public.list_purchases(uuid, text, date, date, integer, integer) owner to app_api;
revoke all on function public.list_purchases(uuid, text, date, date, integer, integer) from public, anon;
grant execute on function public.list_purchases(uuid, text, date, date, integer, integer) to authenticated;

create or replace function public.get_purchase(p_purchase_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_out      jsonb;
begin
  perform app.require_role('OWNER', 'MANAGER');

  select jsonb_build_object(
    'purchase', jsonb_build_object(
      'id', pu.id, 'purchase_no', pu.purchase_no, 'invoice_no', pu.invoice_no,
      'purchased_on', pu.purchased_on, 'total_amount', pu.total_amount,
      'notes', pu.notes, 'status', pu.status, 'received_at', pu.received_at
    ),
    'supplier', case when s.id is null then 'null'::jsonb else jsonb_build_object(
      'id', s.id, 'name', s.name, 'phone', s.phone
    ) end,
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', pi.id,
               'raw_material_id', pi.raw_material_id,
               'name', m.name,
               'base_unit', m.base_unit,
               'qty_base', pi.qty_base,
               'unit_cost_base', pi.unit_cost_base,
               'line_total', pi.line_total
             ) order by m.name), '[]'::jsonb)
      from app.purchase_items pi
      join app.raw_materials m on m.id = pi.raw_material_id
      where pi.purchase_id = pu.id and pi.deleted_at is null
    )
  )
  into v_out
  from app.purchases pu
  left join app.suppliers s on s.id = pu.supplier_id
  where pu.id = p_purchase_id and pu.business_id = v_business and pu.deleted_at is null;

  if v_out is null then
    raise exception 'purchase % not found', p_purchase_id using errcode = 'P0002';
  end if;
  return v_out;
end
$fn$;

alter function public.get_purchase(uuid) owner to app_api;
revoke all on function public.get_purchase(uuid) from public, anon;
grant execute on function public.get_purchase(uuid) to authenticated;

create or replace function public.list_packing_runs(
  p_status text    default null,
  p_from   date    default null,
  p_to     date    default null,
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
  v_business uuid := app.current_business_id();
  v_rows     jsonb;
begin
  perform app.require_role('OWNER', 'MANAGER', 'PACKER');
  p_limit  := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.run_on desc), '[]'::jsonb)
    into v_rows
  from (
    select r.id, r.raw_material_id, m.name as raw_material_name,
           r.packed_sku_id, s.name as packed_sku_name, s.pack_size_base,
           r.packets_produced, r.raw_consumed_base, r.wastage_base,
           r.run_on, r.notes, r.status, r.completed_at
    from app.packing_runs r
    join app.raw_materials m on m.id = r.raw_material_id
    join app.packed_skus  s on s.id = r.packed_sku_id
    where r.business_id = v_business
      and r.deleted_at is null
      and (p_status is null or r.status = p_status)
      and (p_from is null or r.run_on >= p_from)
      and (p_to is null or r.run_on <= p_to)
    order by r.run_on desc, r.created_at desc
    limit p_limit + 1 offset p_offset
  ) x;

  return app.page(v_rows, p_limit, p_offset);
end
$fn$;

alter function public.list_packing_runs(text, date, date, integer, integer) owner to app_api;
revoke all on function public.list_packing_runs(text, date, date, integer, integer) from public, anon;
grant execute on function public.list_packing_runs(text, date, date, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Cash and the khata.
--
-- DELIVERY is included throughout: a delivery person collects cash, needs the
-- outstanding balance to know what to ask for, and needs to see what they have
-- already recorded on this run. A PACKER does not.
-- ---------------------------------------------------------------------------

create or replace function public.list_payments(
  p_customer_id uuid    default null,
  p_order_id    uuid    default null,
  p_from        date    default null,
  p_to          date    default null,
  p_limit       integer default 50,
  p_offset      integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_rows     jsonb;
  v_total    numeric;
begin
  perform app.require_role('OWNER', 'MANAGER', 'DELIVERY');
  p_limit  := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  -- The total is over the whole filtered range, not the page: "how much came in
  -- today" must not change when you scroll.
  select coalesce(sum(p.amount), 0) into v_total
  from app.payments p
  where p.business_id = v_business
    and (p_customer_id is null or p.customer_id = p_customer_id)
    and (p_order_id is null or p.order_id = p_order_id)
    and (p_from is null or p.paid_on >= p_from)
    and (p_to is null or p.paid_on <= p_to);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.paid_on desc, x.created_at desc), '[]'::jsonb)
    into v_rows
  from (
    select p.id, p.customer_id, c.name as customer_name,
           p.order_id, o.order_no, p.amount, p.method, p.paid_on, p.note,
           p.created_at
    from app.payments p
    join app.customers c on c.id = p.customer_id
    left join app.orders o on o.id = p.order_id
    where p.business_id = v_business
      and (p_customer_id is null or p.customer_id = p_customer_id)
      and (p_order_id is null or p.order_id = p_order_id)
      and (p_from is null or p.paid_on >= p_from)
      and (p_to is null or p.paid_on <= p_to)
    order by p.paid_on desc, p.created_at desc
    limit p_limit + 1 offset p_offset
  ) x;

  return app.page(v_rows, p_limit, p_offset)
         || jsonb_build_object('range_total', v_total);
end
$fn$;

alter function public.list_payments(uuid, uuid, date, date, integer, integer) owner to app_api;
revoke all on function public.list_payments(uuid, uuid, date, date, integer, integer) from public, anon;
grant execute on function public.list_payments(uuid, uuid, date, date, integer, integer) to authenticated;

-- The khata screen: who owes what. p_only_outstanding defaults true because
-- that is the question the owner actually has.
create or replace function public.list_customer_balances(
  p_search            text    default null,
  p_only_outstanding  boolean default true,
  p_limit             integer default 50,
  p_offset            integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_q        text;
  v_rows     jsonb;
  v_total    numeric;
begin
  perform app.require_role('OWNER', 'MANAGER', 'DELIVERY');
  v_q      := nullif(btrim(coalesce(p_search, '')), '');
  p_limit  := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  select coalesce(sum(b.outstanding), 0) into v_total
  from app.v_customer_balances b
  where b.business_id = v_business
    and (not p_only_outstanding or b.outstanding > 0);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.outstanding desc, x.name), '[]'::jsonb)
    into v_rows
  from (
    select b.customer_id, b.name, c.phone,
           b.total_billed, b.total_paid, b.outstanding,
           (select max(p.paid_on) from app.payments p
             where p.customer_id = b.customer_id) as last_payment_on,
           (select max(o.placed_at) from app.orders o
             where o.customer_id = b.customer_id and o.deleted_at is null) as last_order_at
    from app.v_customer_balances b
    join app.customers c on c.id = b.customer_id
    where b.business_id = v_business
      and c.deleted_at is null
      and (not p_only_outstanding or b.outstanding > 0)
      and (v_q is null or b.name ilike '%' || v_q || '%'
                       or c.phone ilike '%' || v_q || '%')
    order by b.outstanding desc, b.name
    limit p_limit + 1 offset p_offset
  ) x;

  return app.page(v_rows, p_limit, p_offset)
         || jsonb_build_object('outstanding_total', v_total);
end
$fn$;

alter function public.list_customer_balances(text, boolean, integer, integer) owner to app_api;
revoke all on function public.list_customer_balances(text, boolean, integer, integer) from public, anon;
grant execute on function public.list_customer_balances(text, boolean, integer, integer) to authenticated;

-- get_customer_ledger gains pagination.
--
-- The 0007 version returned EVERY order and EVERY payment for a customer in one
-- jsonb. For a customer two years into a running khata that is unbounded, and
-- it is the read most likely to be opened on the worst connection.
--
-- DROP first, do not overload: PostgREST resolves overloaded RPCs by the key
-- names in the request body, so get_customer_ledger(uuid) and
-- get_customer_ledger(uuid,integer,integer) coexisting is a runtime ambiguity
-- error. Migration 0012 hit exactly this and dropped create_packing_run rather
-- than overloading it. Safe to change the signature now only because nothing
-- calls it yet -- the app is one screen.
drop function if exists public.get_customer_ledger(uuid);

create or replace function public.get_customer_ledger(
  p_customer_id uuid,
  p_limit       integer default 50,
  p_offset      integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_orders   jsonb;
  v_pays     jsonb;
begin
  perform app.require_role('OWNER', 'MANAGER', 'DELIVERY');
  p_limit  := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  if not exists (
    select 1 from app.customers
    where id = p_customer_id and business_id = v_business and deleted_at is null
  ) then
    raise exception 'customer % not found', p_customer_id using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.placed_at desc), '[]'::jsonb)
    into v_orders
  from (
    select o.id, o.order_no, o.status, o.total_amount, o.placed_at,
           coalesce((select sum(amount) from app.payments where order_id = o.id), 0) as paid
    from app.orders o
    where o.customer_id = p_customer_id and o.business_id = v_business
      and o.deleted_at is null
    order by o.placed_at desc
    limit p_limit + 1 offset p_offset
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.paid_on desc), '[]'::jsonb)
    into v_pays
  from (
    select p.id, p.amount, p.paid_on, p.order_id, p.note, p.created_at
    from app.payments p
    where p.customer_id = p_customer_id and p.business_id = v_business
    order by p.paid_on desc, p.created_at desc
    limit p_limit + 1 offset p_offset
  ) x;

  return jsonb_build_object(
    'balance', (
      select to_jsonb(b) from app.v_customer_balances b
      where b.customer_id = p_customer_id and b.business_id = v_business
    ),
    'orders',   app.page(v_orders, p_limit, p_offset),
    'payments', app.page(v_pays, p_limit, p_offset)
  );
end
$fn$;

alter function public.get_customer_ledger(uuid, integer, integer) owner to app_api;
revoke all on function public.get_customer_ledger(uuid, integer, integer) from public, anon;
grant execute on function public.get_customer_ledger(uuid, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Stock history and the home screen.
-- ---------------------------------------------------------------------------

-- The audit trail for one item. This is the answer to "why does the app say I
-- have 12 packets when I count 10". Without it a disagreement about stock has
-- no evidence behind it, and the ledger model's main advantage stays invisible
-- to the person who needs it most.
create or replace function public.list_stock_ledger(
  p_raw_material_id uuid    default null,
  p_packed_sku_id   uuid    default null,
  p_entry_types     text[]  default null,
  p_limit           integer default 50,
  p_offset          integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_rows     jsonb;
begin
  perform app.require_role('OWNER', 'MANAGER');
  p_limit  := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
    into v_rows
  from (
    select l.id, l.entry_type, l.item_kind,
           l.raw_material_id, l.packed_sku_id,
           coalesce(m.name, s.name) as item_name,
           l.qty_base, l.ref_type, l.ref_id, l.note, l.created_at,
           pr.full_name as created_by_name
    from app.stock_ledger l
    left join app.raw_materials m on m.id = l.raw_material_id
    left join app.packed_skus   s on s.id = l.packed_sku_id
    left join app.profiles     pr on pr.id = l.created_by
    where l.business_id = v_business
      and (p_raw_material_id is null or l.raw_material_id = p_raw_material_id)
      and (p_packed_sku_id is null or l.packed_sku_id = p_packed_sku_id)
      and (p_entry_types is null or l.entry_type = any(p_entry_types))
    order by l.created_at desc
    limit p_limit + 1 offset p_offset
  ) x;

  return app.page(v_rows, p_limit, p_offset);
end
$fn$;

alter function public.list_stock_ledger(uuid, uuid, text[], integer, integer) owner to app_api;
revoke all on function public.list_stock_ledger(uuid, uuid, text[], integer, integer) from public, anon;
grant execute on function public.list_stock_ledger(uuid, uuid, text[], integer, integer) to authenticated;

-- The home screen in one round trip. Six separate calls on a 2G connection to
-- render one screen is the difference between an app that opens and one that
-- people stop opening.
create or replace function public.get_day_summary(p_on date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_day      date;
begin
  perform app.require_member();
  v_day := coalesce(p_on, current_date);

  return jsonb_build_object(
    'on', v_day,
    'orders_placed', (
      select count(*) from app.orders
      where business_id = v_business and deleted_at is null
        and placed_at >= v_day::timestamptz and placed_at < (v_day + 1)::timestamptz
    ),
    'orders_to_pack', (
      select count(*) from app.orders
      where business_id = v_business and deleted_at is null and status = 'PLACED'
    ),
    'orders_to_dispatch', (
      select count(*) from app.orders
      where business_id = v_business and deleted_at is null and status = 'PACKED'
    ),
    'orders_out', (
      select count(*) from app.orders
      where business_id = v_business and deleted_at is null
        and status = 'OUT_FOR_DELIVERY'
    ),
    'cash_collected', (
      select coalesce(sum(amount), 0) from app.payments
      where business_id = v_business and paid_on = v_day
    ),
    'outstanding_total', (
      select coalesce(sum(outstanding), 0) from app.v_customer_balances
      where business_id = v_business and outstanding > 0
    ),
    'low_stock_count', (
      select count(*)
      from app.raw_materials m
      left join app.v_raw_stock st
             on st.raw_material_id = m.id and st.business_id = m.business_id
      where m.business_id = v_business and m.deleted_at is null and m.is_active
        and coalesce(st.qty_base, 0) <= m.reorder_level_base
    )
  );
end
$fn$;

alter function public.get_day_summary(date) owner to app_api;
revoke all on function public.get_day_summary(date) from public, anon;
grant execute on function public.get_day_summary(date) to authenticated;

-- get_stock_snapshot gains reorder information, so the stock screen can flag a
-- low item without a second call. Signature unchanged, so no overload problem.
create or replace function public.get_stock_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
begin
  perform app.require_member();

  return jsonb_build_object(
    'raw', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb)
      from (
        select m.id as raw_material_id, m.name, m.base_unit,
               coalesce(st.qty_base, 0) as qty_base,
               m.reorder_level_base,
               (coalesce(st.qty_base, 0) <= m.reorder_level_base) as below_reorder
        from app.raw_materials m
        left join app.v_raw_stock st
               on st.raw_material_id = m.id and st.business_id = m.business_id
        where m.business_id = v_business and m.deleted_at is null and m.is_active
      ) x
    ),
    'packed', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb)
      from (
        select s.id as packed_sku_id, s.name, s.pack_size_base, s.sale_price,
               coalesce(st.qty_packets, 0) as qty_packets
        from app.packed_skus s
        left join app.v_packed_stock st
               on st.packed_sku_id = s.id and st.business_id = s.business_id
        where s.business_id = v_business and s.deleted_at is null and s.is_active
      ) x
    )
  );
end
$fn$;

alter function public.get_stock_snapshot() owner to app_api;
revoke all on function public.get_stock_snapshot() from public, anon;
grant execute on function public.get_stock_snapshot() to authenticated;
