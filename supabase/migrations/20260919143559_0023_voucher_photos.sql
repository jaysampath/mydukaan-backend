-- 0023 -- voucher photos.
--
-- At delivery the customer signs a paper voucher (items, prices, total); every
-- time cash is collected the owner writes the date and amount on it. The owner
-- wants a photo of that paper at delivery and after each partial payment, kept
-- against the order.
--
-- The image bytes live in Cloudflare R2, behind a Worker (repo
-- mydukaan-cloudflare). The Worker holds no secret: it forwards the caller's
-- own JWT to the functions below, and the database decides. Upload is
--
--   authorize_voucher_upload  -> Worker puts the bytes -> attach_voucher_photo
--
-- and a view is get_voucher_photo -> Worker streams the bytes. The bucket has
-- no public URL, so this table is the only index into it and these functions
-- are the only door.
--
-- OWNER only, in V1, for everything: upload, view, hide. Staff never see the
-- feature. get_order returns an empty `vouchers` list to anyone else.
--
-- Known, accepted gap: an OWNER could call attach_voucher_photo directly
-- without uploading anything. The result is a broken thumbnail in their own
-- shop -- the same class of within-tenant risk as the rest of the model.

-- ---------------------------------------------------------------------------
-- The table. The checklist in docs/supabase-access.md, minus sync: this table
-- is not in app.synced_tables(), like business_invites.
-- ---------------------------------------------------------------------------

create table if not exists app.voucher_photos (
  id           uuid primary key,          -- minted on the device
  business_id  uuid not null references app.businesses(id),
  order_id     uuid not null references app.orders(id),
  payment_id   uuid references app.payments(id),
  object_key   text not null unique,
  content_type text not null default 'image/jpeg' check (content_type = 'image/jpeg'),
  size_bytes   integer not null check (size_bytes between 1 and 5242880),
  width        integer check (width is null or width > 0),
  height       integer check (height is null or height > 0),
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  -- The soft delete. A wrong or blurry photo is hidden, never destroyed: the
  -- voucher is evidence of a debt.
  hidden_at    timestamptz,
  hidden_by    uuid
);

create index if not exists voucher_photos_order_idx
  on app.voucher_photos (order_id) where hidden_at is null;
create index if not exists voucher_photos_payment_idx
  on app.voucher_photos (payment_id) where payment_id is not null and hidden_at is null;

alter table app.voucher_photos enable row level security;
alter table app.voucher_photos force row level security;

drop policy if exists tenant_select on app.voucher_photos;
drop policy if exists tenant_insert on app.voucher_photos;
drop policy if exists tenant_update on app.voucher_photos;
create policy tenant_select on app.voucher_photos for select
  using (business_id = app.current_business_id());
create policy tenant_insert on app.voucher_photos for insert
  with check (business_id = app.current_business_id());
create policy tenant_update on app.voucher_photos for update
  using (business_id = app.current_business_id())
  with check (business_id = app.current_business_id());

drop trigger if exists voucher_photos_touch on app.voucher_photos;
create trigger voucher_photos_touch before insert or update on app.voucher_photos
  for each row execute function app.touch_updated_at();

grant select, insert, update on app.voucher_photos to app_api;
revoke all on app.voucher_photos from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Shared checks for the two upload steps.
-- ---------------------------------------------------------------------------

-- The order must be this shop's and not cancelled; a payment, if given, must
-- be one handed over for THIS order.
create or replace function app.assert_voucher_target(p_order_id uuid, p_payment_id uuid)
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $fn$
declare
  v_status text;
begin
  select status into v_status from app.orders
  where id = p_order_id and business_id = app.current_business_id() and deleted_at is null;
  if not found then
    raise exception 'order % not found', p_order_id using errcode = 'P0002';
  end if;
  if v_status = 'CANCELLED' then
    raise exception 'order % is cancelled', p_order_id using errcode = '22023';
  end if;

  if p_payment_id is not null and not exists (
    select 1 from app.payments
    where id = p_payment_id and order_id = p_order_id
      and business_id = app.current_business_id()
  ) then
    raise exception 'payment % was not made against order %', p_payment_id, p_order_id
      using errcode = '22023';
  end if;
end
$fn$;

-- Where the bytes go. Scoped by an order the caller has just been proven to
-- own, so no key this can produce belongs to another shop.
create or replace function app.voucher_object_key(p_order_id uuid, p_photo_id uuid)
returns text
language sql
immutable
set search_path = ''
as $fn$
  select 'v1/' || p_order_id::text || '/' || p_photo_id::text || '.jpg'
$fn$;

-- ---------------------------------------------------------------------------
-- The four RPCs.
-- ---------------------------------------------------------------------------

-- Step 1 of an upload. Writes nothing; answers "may this caller put a photo
-- with this id on this order, and where". Not named get_* because it is a
-- write-path check, gated on write access.
create or replace function public.authorize_voucher_upload(
  p_photo_id   uuid,
  p_order_id   uuid,
  p_payment_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_existing record;
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();
  perform app.assert_voucher_target(p_order_id, p_payment_id);

  select order_id, object_key into v_existing
  from app.voucher_photos where id = p_photo_id and business_id = v_business;
  if found then
    if v_existing.order_id <> p_order_id then
      raise exception 'photo % belongs to a different order', p_photo_id using errcode = '22023';
    end if;
    -- A retry after the attach already landed: nothing left to upload.
    return jsonb_build_object('object_key', v_existing.object_key, 'already_uploaded', true);
  end if;

  return jsonb_build_object('object_key', app.voucher_object_key(p_order_id, p_photo_id),
                            'already_uploaded', false);
end
$fn$;

-- Step 3 of an upload, after the bytes are in R2. Idempotent on the photo id.
create or replace function public.attach_voucher_photo(
  p_photo_id   uuid,
  p_order_id   uuid,
  p_payment_id uuid    default null,
  p_size_bytes integer default null,
  p_width      integer default null,
  p_height     integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_existing record;
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();
  perform app.assert_voucher_target(p_order_id, p_payment_id);

  if p_size_bytes is null or p_size_bytes < 1 or p_size_bytes > 5242880 then
    raise exception 'photo size must be between 1 byte and 5 MB' using errcode = '22023';
  end if;

  select order_id into v_existing
  from app.voucher_photos where id = p_photo_id and business_id = v_business;
  if found then
    if v_existing.order_id <> p_order_id then
      raise exception 'photo % belongs to a different order', p_photo_id using errcode = '22023';
    end if;
    return jsonb_build_object('photo_id', p_photo_id, 'created', false);
  end if;

  insert into app.voucher_photos
    (id, business_id, order_id, payment_id, object_key, size_bytes, width, height, created_by)
  values
    (p_photo_id, v_business, p_order_id, p_payment_id,
     app.voucher_object_key(p_order_id, p_photo_id),
     p_size_bytes, p_width, p_height, app.current_user_id());

  return jsonb_build_object('photo_id', p_photo_id, 'created', true);
exception
  when unique_violation then
    raise exception 'id % is already in use', p_photo_id using errcode = '23505';
end
$fn$;

create or replace function public.hide_voucher_photo(p_photo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();

  update app.voucher_photos
     set hidden_at = coalesce(hidden_at, now()),
         hidden_by = coalesce(hidden_by, app.current_user_id())
   where id = p_photo_id and business_id = v_business;
  if not found then
    raise exception 'photo % not found', p_photo_id using errcode = 'P0002';
  end if;

  return jsonb_build_object('photo_id', p_photo_id, 'hidden', true);
end
$fn$;

-- The Worker's read authorisation. Not subscription-gated: a lapse is
-- read-only, and seeing your own voucher is a read.
create or replace function public.get_voucher_photo(p_photo_id uuid)
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
  perform app.require_role('OWNER');

  select jsonb_build_object('photo_id', v.id, 'object_key', v.object_key,
                            'content_type', v.content_type)
    into v_out
  from app.voucher_photos v
  where v.id = p_photo_id and v.business_id = v_business and v.hidden_at is null;

  if v_out is null then
    raise exception 'photo % not found', p_photo_id using errcode = 'P0002';
  end if;
  return v_out;
end
$fn$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.authorize_voucher_upload(uuid, uuid, uuid)',
    'public.attach_voucher_photo(uuid, uuid, uuid, integer, integer, integer)',
    'public.hide_voucher_photo(uuid)',
    'public.get_voucher_photo(uuid)'
  ] loop
    execute format('alter function %s owner to app_api', f);
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- Reads. Same signatures as 0022.
-- ---------------------------------------------------------------------------

-- The OWNER-only rule for listing, stated once.
create or replace function app.order_vouchers(p_order_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $fn$
  select case when app.current_member_role() = 'OWNER' then (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', v.id, 'payment_id', v.payment_id,
             'payment_amount', p.amount, 'paid_on', p.paid_on,
             'width', v.width, 'height', v.height,
             'created_at', v.created_at
           ) order by v.created_at desc), '[]'::jsonb)
    from app.voucher_photos v
    left join app.payments p on p.id = v.payment_id
    where v.order_id = p_order_id
      and v.business_id = app.current_business_id()
      and v.hidden_at is null)
  else '[]'::jsonb end
$fn$;

create or replace function public.get_order(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_out jsonb; v_status text; v_disp timestamptz; v_customer uuid;
  v_balance numeric; v_paid numeric; v_from_account numeric;
  v_next jsonb := '[]'::jsonb;
begin
  perform app.require_member();

  select o.status, o.dispatched_at, o.customer_id
    into v_status, v_disp, v_customer
  from app.orders o
  where o.id = p_order_id and o.business_id = v_business and o.deleted_at is null;

  if not found then
    raise exception 'order % not found', p_order_id using errcode = 'P0002';
  end if;

  select b.balance, b.paid, b.from_account
    into v_balance, v_paid, v_from_account
  from app.v_order_balances b
  where b.customer_id = v_customer and b.order_id = p_order_id;
  -- Cancelled: not in the view, nothing owed.
  v_balance := coalesce(v_balance, 0);
  v_paid := coalesce(v_paid, 0);
  v_from_account := coalesce(v_from_account, 0);

  if v_status = 'PLACED' then
    v_next := v_next || jsonb_build_array('mark_packed');
  elsif v_status = 'PACKED' then
    v_next := v_next || jsonb_build_array('dispatch');
  elsif v_status = 'OUT_FOR_DELIVERY' then
    v_next := v_next || jsonb_build_array('mark_delivered');
  elsif v_status = 'DELIVERED' then
    v_next := v_next || jsonb_build_array('mark_payment_pending');
  end if;

  if v_status not in ('CANCELLED', 'CLOSED') and v_balance > 0 then
    v_next := v_next || jsonb_build_array('record_payment');
  end if;

  -- Same rule set_order_due_date enforces.
  if v_status in ('OUT_FOR_DELIVERY', 'DELIVERED', 'PAYMENT_PENDING') and v_balance > 0 then
    v_next := v_next || jsonb_build_array('set_due_date');
  end if;

  if v_disp is null and v_status not in ('CANCELLED', 'CLOSED') then
    v_next := v_next || jsonb_build_array('cancel');
  end if;

  select jsonb_build_object(
    'order', jsonb_build_object(
      'id', o.id, 'order_no', o.order_no, 'status', o.status,
      'total_amount', o.total_amount, 'notes', o.notes,
      'placed_at', o.placed_at, 'packed_at', o.packed_at,
      'dispatched_at', o.dispatched_at, 'delivered_at', o.delivered_at,
      'closed_at', o.closed_at, 'cancelled_at', o.cancelled_at,
      'due_on', o.due_on),
    'customer', jsonb_build_object(
      'id', c.id, 'name', c.name, 'phone', c.phone, 'address', c.address,
      'credit_days', app.credit_days_for(c.id)),
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', oi.id, 'packed_sku_id', oi.packed_sku_id, 'name', ps.name,
               'pack_size_base', ps.pack_size_base, 'qty_packets', oi.qty_packets,
               'unit_price', oi.unit_price, 'line_total', oi.line_total,
               'qty_on_hand', coalesce(
                 (select st.qty_packets from app.v_packed_stock st
                   where st.packed_sku_id = ps.id and st.business_id = v_business), 0)
             ) order by ps.name), '[]'::jsonb)
      from app.order_items oi
      join app.packed_skus ps on ps.id = oi.packed_sku_id
      where oi.order_id = o.id and oi.deleted_at is null),
    -- Only the payments handed over for THIS order. paid_from_account is the
    -- rest of `paid`: the share of the customer's account credit covering it.
    'payments', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'amount', p.amount, 'paid_on', p.paid_on, 'note', p.note
             ) order by p.paid_on desc, p.created_at desc), '[]'::jsonb)
      from app.payments p where p.order_id = o.id),
    'paid', v_paid,
    'paid_from_account', v_from_account,
    'balance', v_balance,
    'customer_outstanding', (
      select outstanding from app.v_customer_balances
      where customer_id = o.customer_id and business_id = v_business),
    'due_state', app.due_state(o.due_on, v_balance),
    'due_in_days', app.due_in_days(o.due_on, v_balance),
    -- Empty for every role but OWNER; see app.order_vouchers.
    'vouchers', app.order_vouchers(o.id),
    'allowed_transitions', v_next
  ) into v_out
  from app.orders o
  join app.customers c on c.id = o.customer_id
  where o.id = p_order_id and o.business_id = v_business and o.deleted_at is null;

  return v_out;
end
$fn$;

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
  v_owner    boolean := app.current_member_role() = 'OWNER';
  v_orders jsonb; v_pays jsonb;
begin
  perform app.require_role('OWNER', 'MANAGER', 'DELIVERY');
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  if not exists (select 1 from app.customers
                 where id = p_customer_id and business_id = v_business and deleted_at is null) then
    raise exception 'customer % not found', p_customer_id using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.placed_at desc), '[]'::jsonb) into v_orders
  from (
    select o.id, o.order_no, o.status, o.total_amount, o.placed_at,
           coalesce(b.paid, 0) as paid,
           coalesce(b.balance, 0) as balance,
           coalesce(b.from_account, 0) as paid_from_account,
           o.due_on,
           app.due_state(o.due_on, b.balance) as due_state,
           app.due_in_days(o.due_on, b.balance) as due_in_days
    from app.orders o
    left join app.v_order_balances b
      on b.order_id = o.id and b.customer_id = p_customer_id
    where o.customer_id = p_customer_id and o.business_id = v_business
      and o.deleted_at is null
    order by o.placed_at desc limit p_limit + 1 offset p_offset
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.paid_on desc), '[]'::jsonb) into v_pays
  from (
    select p.id, p.amount, p.paid_on, p.order_id, p.note, p.created_at,
           case when v_owner then
             (select count(*) from app.voucher_photos v
               where v.payment_id = p.id and v.hidden_at is null)
           else 0 end as voucher_count
    from app.payments p
    where p.customer_id = p_customer_id and p.business_id = v_business
    order by p.paid_on desc, p.created_at desc limit p_limit + 1 offset p_offset
  ) x;

  return jsonb_build_object(
    -- Named columns, not to_jsonb(b): the view's first column is business_id.
    'balance', (
      select jsonb_build_object(
               'customer_id', b.customer_id, 'name', b.name,
               'total_billed', b.total_billed, 'total_paid', b.total_paid,
               'outstanding', b.outstanding,
               'credit_days', c.credit_days,
               'effective_credit_days', app.credit_days_for(b.customer_id))
      from app.v_customer_balances b
      join app.customers c on c.id = b.customer_id
      where b.customer_id = p_customer_id and b.business_id = v_business),
    'orders', app.page(v_orders, p_limit, p_offset),
    'payments', app.page(v_pays, p_limit, p_offset)
  );
end
$fn$;

-- Contract: stays at 3. 0022 and 0023 ship as one release (one db push, one
-- app build); the fields added here -- vouchers, voucher_count -- are additive.
