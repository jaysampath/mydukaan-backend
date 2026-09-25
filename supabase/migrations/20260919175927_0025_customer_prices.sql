-- 0025 -- per-customer prices, and price corrections on an order.
--
-- In a wholesale market every customer has their own price for each product,
-- and the owner decides it. Until now there was one price per SKU
-- (packed_skus.sale_price) and create_order billed everyone at it.
--
--   * app.customer_prices is the RATE CARD: one price per customer per SKU.
--     Anything without a rate falls back to sale_price.
--   * create_order resolves each line as: the price the caller sent (OWNER
--     only), else the customer's rate, else sale_price. The line keeps that
--     price (order_items.unit_price, 0003), so a rate changed later never
--     reprices an old order.
--   * set_order_item_price corrects the price of a line on an order that has
--     not been fully paid yet, and logs the change in app.order_price_changes,
--     append-only. Balances are derived (v_order_balances, 0021), so the
--     order's balance and the khata move by themselves; a cut that clears a
--     delivered order closes it through app.settle_customer_orders.
--
-- The OWNER decides prices. Before this, create_order accepted a unit_price
-- from any caller who could take an order, so a MANAGER could bill at any
-- figure; that is now refused. Old builds never send unit_price, so they keep
-- working and simply start billing at the customer's rate.
--
-- A CLOSED order's prices are final: correcting one would reopen a settled
-- bill, and the owner chose to lock it instead.

-- ---------------------------------------------------------------------------
-- The rate card.
-- ---------------------------------------------------------------------------

create table if not exists app.customer_prices (
  business_id    uuid not null references app.businesses(id),
  customer_id    uuid not null references app.customers(id),
  packed_sku_id  uuid not null references app.packed_skus(id),
  price          numeric(14,2) not null check (price >= 0),
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_by     uuid,
  updated_at     timestamptz not null default now(),
  -- A cleared rate. app_api holds no DELETE; the row is revived by the next set.
  deleted_at     timestamptz,
  -- The natural key: setting the same rate twice is the same row, so the call
  -- is retry-safe without a device-minted id.
  primary key (business_id, customer_id, packed_sku_id)
);

create index if not exists customer_prices_customer_idx
  on app.customer_prices (customer_id) where deleted_at is null;

alter table app.customer_prices enable row level security;
alter table app.customer_prices force row level security;

drop policy if exists tenant_select on app.customer_prices;
drop policy if exists tenant_insert on app.customer_prices;
drop policy if exists tenant_update on app.customer_prices;
create policy tenant_select on app.customer_prices for select
  using (business_id = app.current_business_id());
create policy tenant_insert on app.customer_prices for insert
  with check (business_id = app.current_business_id());
create policy tenant_update on app.customer_prices for update
  using (business_id = app.current_business_id())
  with check (business_id = app.current_business_id());

drop trigger if exists customer_prices_touch on app.customer_prices;
create trigger customer_prices_touch before insert or update on app.customer_prices
  for each row execute function app.touch_updated_at();

grant select, insert, update on app.customer_prices to app_api;
revoke all on app.customer_prices from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The correction log. Append-only, like payments and stock_ledger: a price
-- change on a bill is evidence, so it is never rewritten.
-- ---------------------------------------------------------------------------

create table if not exists app.order_price_changes (
  id              uuid primary key,          -- minted on the device
  business_id     uuid not null references app.businesses(id),
  order_id        uuid not null references app.orders(id),
  order_item_id   uuid not null references app.order_items(id),
  old_unit_price  numeric(14,2) not null,
  new_unit_price  numeric(14,2) not null check (new_unit_price >= 0),
  note            text,
  created_by      uuid,
  created_at      timestamptz not null default now()
);

create index if not exists order_price_changes_order_idx
  on app.order_price_changes (order_id);

alter table app.order_price_changes enable row level security;
alter table app.order_price_changes force row level security;

drop policy if exists tenant_select on app.order_price_changes;
drop policy if exists tenant_insert on app.order_price_changes;
create policy tenant_select on app.order_price_changes for select
  using (business_id = app.current_business_id());
create policy tenant_insert on app.order_price_changes for insert
  with check (business_id = app.current_business_id());

drop trigger if exists order_price_changes_no_update on app.order_price_changes;
drop trigger if exists order_price_changes_no_delete on app.order_price_changes;
create trigger order_price_changes_no_update before update on app.order_price_changes
  for each row execute function app.forbid_mutation();
create trigger order_price_changes_no_delete before delete on app.order_price_changes
  for each row execute function app.forbid_mutation();

-- The default privileges in 0005 hand app_api UPDATE on every new table; this
-- one is insert-only, so take it back. The trigger refuses it regardless.
revoke all on app.order_price_changes from public, anon, authenticated, app_api;
grant select, insert on app.order_price_changes to app_api;

-- ---------------------------------------------------------------------------
-- The statuses whose prices may still be corrected, stated once. get_order
-- offers 'edit_prices' and set_order_item_price enforces it from here.
-- ---------------------------------------------------------------------------

create or replace function app.prices_editable(p_status text)
returns boolean
language sql
immutable
set search_path = ''
as $fn$
  select p_status in ('PLACED', 'PACKED', 'OUT_FOR_DELIVERY', 'DELIVERED', 'PAYMENT_PENDING')
$fn$;

revoke all on function app.prices_editable(text) from public, anon, authenticated;
grant execute on function app.prices_editable(text) to app_api;

-- ---------------------------------------------------------------------------
-- set_customer_price: OWNER only. p_price null clears the rate.
-- ---------------------------------------------------------------------------

create or replace function public.set_customer_price(
  p_customer_id   uuid,
  p_packed_sku_id uuid,
  p_price         numeric
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_user     uuid := app.current_user_id();
  v_default  numeric;
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();

  if p_price is not null and p_price < 0 then
    raise exception 'a price cannot be negative' using errcode = '22023';
  end if;

  if not exists (
    select 1 from app.customers
    where id = p_customer_id and business_id = v_business and deleted_at is null
  ) then
    raise exception 'customer % not found', p_customer_id using errcode = 'P0002';
  end if;

  select sale_price into v_default from app.packed_skus
  where id = p_packed_sku_id and business_id = v_business and deleted_at is null;
  if not found then
    raise exception 'SKU % not found', p_packed_sku_id using errcode = 'P0002';
  end if;

  if p_price is null then
    update app.customer_prices
       set deleted_at = now(), updated_by = v_user
     where business_id = v_business and customer_id = p_customer_id
       and packed_sku_id = p_packed_sku_id and deleted_at is null;
  else
    insert into app.customer_prices
      (business_id, customer_id, packed_sku_id, price, created_by, updated_by)
    values
      (v_business, p_customer_id, p_packed_sku_id, p_price, v_user, v_user)
    on conflict (business_id, customer_id, packed_sku_id) do update
      set price = excluded.price, updated_by = excluded.updated_by, deleted_at = null;
  end if;

  return jsonb_build_object(
    'customer_id', p_customer_id,
    'packed_sku_id', p_packed_sku_id,
    'customer_price', p_price,
    'default_price', v_default,
    'price', coalesce(p_price, v_default)
  );
end
$fn$;

alter function public.set_customer_price(uuid, uuid, numeric) owner to app_api;
revoke all on function public.set_customer_price(uuid, uuid, numeric) from public, anon;
grant execute on function public.set_customer_price(uuid, uuid, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- list_customer_prices: every active SKU with the price this customer pays.
-- A new function rather than a parameter on list_packed_skus -- adding a
-- parameter to a live function means DROP-then-create (0012, 0017).
--
-- OWNER and MANAGER: the manager takes orders and must see what they bill.
-- Packers and delivery staff never see the rate card.
-- ---------------------------------------------------------------------------

create or replace function public.list_customer_prices(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
begin
  perform app.require_role('OWNER', 'MANAGER');

  if not exists (
    select 1 from app.customers
    where id = p_customer_id and business_id = v_business and deleted_at is null
  ) then
    raise exception 'customer % not found', p_customer_id using errcode = 'P0002';
  end if;

  return (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb)
    from (
      select s.id as packed_sku_id, s.name, s.pack_size_base, s.sku_code,
             coalesce(st.qty_packets, 0) as qty_packets,
             s.sale_price as default_price,
             cp.price as customer_price,
             coalesce(cp.price, s.sale_price) as price
      from app.packed_skus s
      left join app.v_packed_stock st
             on st.packed_sku_id = s.id and st.business_id = s.business_id
      left join app.customer_prices cp
             on cp.business_id = s.business_id
            and cp.customer_id = p_customer_id
            and cp.packed_sku_id = s.id
            and cp.deleted_at is null
      where s.business_id = v_business
        and s.deleted_at is null
        and s.is_active
    ) x
  );
end
$fn$;

alter function public.list_customer_prices(uuid) owner to app_api;
revoke all on function public.list_customer_prices(uuid) from public, anon;
grant execute on function public.list_customer_prices(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- create_order: the 0016 body, with the price resolved from the rate card and
-- a caller-supplied unit_price accepted from the OWNER only. Same signature.
-- ---------------------------------------------------------------------------

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

  -- The owner decides prices. Anyone else bills at the customer's rate.
  if app.current_member_role() <> 'OWNER' and exists (
    select 1 from jsonb_array_elements(p_items) as e(r)
    where e.r ? 'unit_price' and e.r -> 'unit_price' <> 'null'::jsonb
  ) then
    raise exception 'only the owner can change a price' using errcode = '42501';
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
         coalesce((e.r ->> 'unit_price')::numeric, cp.price, ps.sale_price),
         v_user
  from jsonb_array_elements(p_items) as e(r)
  join app.packed_skus ps
    on ps.id = (e.r ->> 'packed_sku_id')::uuid
   and ps.business_id = v_business
   and ps.deleted_at is null
  left join app.customer_prices cp
    on cp.business_id = v_business
   and cp.customer_id = p_customer_id
   and cp.packed_sku_id = ps.id
   and cp.deleted_at is null;

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

-- ---------------------------------------------------------------------------
-- set_order_item_price: correct one line's price. OWNER only, until CLOSED.
--
-- Retry-safe on the device-minted p_change_id: a second call with the same id
-- returns what the first did, with changed:false. Stock, payments and the due
-- date are untouched; only the line, the order total and the derived balances
-- move.
-- ---------------------------------------------------------------------------

create or replace function public.set_order_item_price(
  p_change_id     uuid,
  p_order_item_id uuid,
  p_unit_price    numeric,
  p_note          text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_prev     app.order_price_changes;
  v_item     app.order_items;
  v_order    app.orders;
  v_total    numeric;
  v_closed   bigint[];
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();

  select * into v_prev from app.order_price_changes
  where id = p_change_id and business_id = v_business;
  if found then
    return jsonb_build_object(
      'order_id', v_prev.order_id, 'order_item_id', v_prev.order_item_id,
      'old_unit_price', v_prev.old_unit_price, 'new_unit_price', v_prev.new_unit_price,
      'total_amount', (select total_amount from app.orders where id = v_prev.order_id),
      'settled_orders', '[]'::jsonb, 'changed', false);
  end if;

  if p_unit_price is null or p_unit_price < 0 then
    raise exception 'a price must be zero or more' using errcode = '22023';
  end if;

  select * into v_item from app.order_items
  where id = p_order_item_id and business_id = v_business and deleted_at is null;
  if not found then
    raise exception 'order line % not found', p_order_item_id using errcode = 'P0002';
  end if;

  select * into v_order from app.orders
  where id = v_item.order_id and business_id = v_business and deleted_at is null
  for update;
  if not found then
    raise exception 'order % not found', v_item.order_id using errcode = 'P0002';
  end if;

  if not app.prices_editable(v_order.status) then
    raise exception 'a % order''s prices can no longer be changed', v_order.status
      using errcode = '22023', hint = 'price_locked';
  end if;

  if v_item.unit_price = p_unit_price then
    return jsonb_build_object(
      'order_id', v_order.id, 'order_item_id', v_item.id,
      'old_unit_price', v_item.unit_price, 'new_unit_price', p_unit_price,
      'total_amount', v_order.total_amount,
      'settled_orders', '[]'::jsonb, 'changed', false);
  end if;

  insert into app.order_price_changes
    (id, business_id, order_id, order_item_id, old_unit_price, new_unit_price, note, created_by)
  values
    (p_change_id, v_business, v_order.id, v_item.id, v_item.unit_price, p_unit_price,
     nullif(btrim(p_note), ''), app.current_user_id());

  update app.order_items set unit_price = p_unit_price where id = v_item.id;

  update app.orders
     set total_amount = (select coalesce(sum(line_total), 0) from app.order_items
                          where order_id = v_order.id and deleted_at is null)
   where id = v_order.id
  returning total_amount into v_total;

  -- A cut can clear a delivered order, or free credit that clears an older one.
  v_closed := app.settle_customer_orders(v_order.customer_id);

  return jsonb_build_object(
    'order_id', v_order.id, 'order_item_id', v_item.id,
    'old_unit_price', v_item.unit_price, 'new_unit_price', p_unit_price,
    'total_amount', v_total,
    'settled_orders', to_jsonb(v_closed), 'changed', true);
end
$fn$;

alter function public.set_order_item_price(uuid, uuid, numeric, text) owner to app_api;
revoke all on function public.set_order_item_price(uuid, uuid, numeric, text) from public, anon;
grant execute on function public.set_order_item_price(uuid, uuid, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- get_order: the 0024 body plus 'edit_prices' in allowed_transitions and the
-- price_changes log. Same signature.
-- ---------------------------------------------------------------------------

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

  -- Same rule set_order_item_price enforces.
  if app.prices_editable(v_status) then
    v_next := v_next || jsonb_build_array('edit_prices');
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
               'id', p.id, 'amount', p.amount, 'method', p.method,
               'paid_on', p.paid_on, 'note', p.note
             ) order by p.paid_on desc, p.created_at desc), '[]'::jsonb)
      from app.payments p where p.order_id = o.id),
    -- Price corrections, newest first (0025).
    'price_changes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', pc.id, 'order_item_id', pc.order_item_id, 'name', ps.name,
               'old_unit_price', pc.old_unit_price, 'new_unit_price', pc.new_unit_price,
               'note', pc.note, 'changed_at', pc.created_at,
               'changed_by_name', pr.full_name
             ) order by pc.created_at desc), '[]'::jsonb)
      from app.order_price_changes pc
      join app.order_items oi on oi.id = pc.order_item_id
      join app.packed_skus ps on ps.id = oi.packed_sku_id
      left join app.profiles pr on pr.id = pc.created_by
      where pc.order_id = o.id and pc.business_id = v_business),
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

-- ---------------------------------------------------------------------------
-- Contract: additive (list_customer_prices, set_customer_price,
-- set_order_item_price, get_order.price_changes, the 'edit_prices'
-- transition). min_client stays at 1.
-- ---------------------------------------------------------------------------

create or replace function app.schema_contract()
returns jsonb
language sql
immutable
set search_path = ''
as $fn$
  select jsonb_build_object(
    'current',    5,
    'min_client', 1
  )
$fn$;
