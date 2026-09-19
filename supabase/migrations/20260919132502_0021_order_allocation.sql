-- 0021 -- account payments settle orders, oldest first.
--
-- Before this, a payment recorded against the khata (order_id null) lowered the
-- customer's outstanding but counted against no order. Ravi pays ₹1,000 for two
-- ₹500 orders: the khata says ₹0 owed while both orders still say ₹500 due, sit
-- in the "Unpaid" filter and stay on the delivery person's collect list.
--
-- The fix derives each order's paid/balance from the ledger, the same way stock
-- and outstanding already are, instead of storing an allocation:
--
--   * a live order (not cancelled, not deleted) NEEDS total - its own payments;
--   * the customer's CREDIT is every payment no live order carries -- account
--     payments, payments on cancelled/deleted orders -- plus any overpayment
--     on a live order;
--   * credit covers needs oldest order first (placed_at, id).
--
-- Nothing is written to record the allocation, so it stays append-only, needs
-- no backfill, and reflows by itself when an order is cancelled or a refund is
-- recorded. Invariant: the balances of a customer's live orders sum to their
-- khata outstanding, whenever that outstanding is not negative. (A net-negative
-- account -- refunds beyond the credit -- is the one case it cannot hold; the
-- khata is still right, the orders simply show no allocation.)
--
-- Also fixed, because the new rule would trigger it: record_payment used to
-- CLOSE an order the moment its balance reached zero at any stage, so paying up
-- front for a PLACED order skipped packing and dispatch. Money now closes an
-- order only once the goods have gone.

-- ---------------------------------------------------------------------------
-- The derivation.
-- ---------------------------------------------------------------------------

create view app.v_order_balances with (security_invoker = true) as
with live as (
  -- Exactly the orders v_customer_balances bills. Keep the two in step or the
  -- invariant above breaks.
  select o.id, o.business_id, o.customer_id, o.placed_at, o.total_amount,
         coalesce(d.paid, 0) as direct_paid
  from app.orders o
  left join (
    select order_id, sum(amount) as paid
    from app.payments
    where order_id is not null
    group by order_id
  ) d on d.order_id = o.id
  where o.deleted_at is null and o.status <> 'CANCELLED'
),
credit as (
  select p.customer_id, sum(p.amount) as amount
  from app.payments p
  where p.order_id is null
     or not exists (select 1 from live l where l.id = p.order_id)
  group by p.customer_id
),
overpaid as (
  select customer_id, sum(greatest(direct_paid - total_amount, 0)) as amount
  from live
  group by customer_id
),
queued as (
  select l.*,
         greatest(l.total_amount - l.direct_paid, 0) as need,
         coalesce(sum(greatest(l.total_amount - l.direct_paid, 0)) over (
           partition by l.customer_id
           order by l.placed_at, l.id
           rows between unbounded preceding and 1 preceding
         ), 0) as need_before,
         coalesce(c.amount, 0) + coalesce(ov.amount, 0) as pool
  from live l
  left join credit c on c.customer_id = l.customer_id
  left join overpaid ov on ov.customer_id = l.customer_id
)
select q.business_id,
       q.id as order_id,
       q.customer_id,
       q.total_amount,
       q.direct_paid,
       a.from_account,
       q.need - a.from_account as balance,
       q.total_amount - (q.need - a.from_account) as paid
from queued q
cross join lateral (
  select least(q.need, greatest(q.pool - q.need_before, 0)) as from_account
) a;

comment on view app.v_order_balances is
  'Derived per-order paid/balance: account credit covers the oldest live orders first. '
  'Filter by customer_id as well as order_id -- the window is per customer, so that '
  'predicate is the one Postgres can push down.';

grant select on app.v_order_balances to app_api;
revoke all on app.v_order_balances from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The status rule, in one place.
--
-- Closes a customer's orders whose derived balance is settled AND whose goods
-- have gone (DELIVERED, PAYMENT_PENDING). OUT_FOR_DELIVERY closes only for the
-- order the cash was handed over for (p_door_order_id): full cash at the door
-- means it was delivered, but an account payment elsewhere says nothing about
-- whether a van has arrived. PLACED and PACKED never close on money -- a
-- prepaid order closes when it is delivered.
--
-- Returns the order numbers it closed, for "this settled orders #41, #42".
-- Never reopens a CLOSED order; a reversal payment leaves status alone.
-- ---------------------------------------------------------------------------

create or replace function app.settle_customer_orders(
  p_customer_id   uuid,
  p_door_order_id uuid default null
)
returns bigint[]
language plpgsql
security invoker
set search_path = ''
as $fn$
declare
  v_closed bigint[];
begin
  with closed as (
    update app.orders o
       set status = 'CLOSED', closed_at = coalesce(o.closed_at, now())
      from app.v_order_balances b
     where b.order_id = o.id
       and b.customer_id = p_customer_id
       and o.customer_id = p_customer_id
       and o.business_id = app.current_business_id()
       and b.balance <= 0
       and (o.status in ('DELIVERED', 'PAYMENT_PENDING')
            or (o.status = 'OUT_FOR_DELIVERY' and o.id = p_door_order_id))
    returning o.order_no
  )
  select coalesce(array_agg(order_no order by order_no), '{}') into v_closed from closed;
  return v_closed;
end
$fn$;

revoke all on function app.settle_customer_orders(uuid, uuid) from public, anon, authenticated;
grant execute on function app.settle_customer_orders(uuid, uuid) to app_api;

-- ---------------------------------------------------------------------------
-- record_payment: same signature, three changes.
--   1. An order_id must belong to this customer in this business. It was
--      never checked, and a payment linked to another customer's order would
--      now move that customer's balances.
--   2. Status goes through app.settle_customer_orders, so an account payment
--      can close orders and a prepaid order no longer skips packing.
--   3. Returns settled_orders.
-- ---------------------------------------------------------------------------

create or replace function public.record_payment(
  p_payment_id  uuid,
  p_customer_id uuid,
  p_amount      numeric,
  p_order_id    uuid default null,
  p_paid_on     date default null,
  p_note        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_order_customer uuid;
  v_out      numeric;
  v_closed   bigint[];
begin
  perform app.require_role('OWNER', 'MANAGER', 'DELIVERY');
  perform app.require_write_access();

  if p_amount is null or p_amount = 0 then
    raise exception 'payment amount must be non-zero' using errcode = '22023';
  end if;

  if exists (select 1 from app.payments where id = p_payment_id) then
    return jsonb_build_object('payment_id', p_payment_id, 'created', false);
  end if;

  if not exists (
    select 1 from app.customers
    where id = p_customer_id and business_id = v_business and deleted_at is null
  ) then
    raise exception 'customer % not found', p_customer_id using errcode = 'P0002';
  end if;

  if p_order_id is not null then
    select customer_id into v_order_customer
    from app.orders
    where id = p_order_id and business_id = v_business and deleted_at is null;
    if not found then
      raise exception 'order % not found', p_order_id using errcode = 'P0002';
    end if;
    if v_order_customer <> p_customer_id then
      raise exception 'order % belongs to a different customer', p_order_id
        using errcode = '22023';
    end if;
  end if;

  insert into app.payments (id, business_id, customer_id, order_id, amount, paid_on, note, created_by)
  values (p_payment_id, v_business, p_customer_id, p_order_id, p_amount,
          coalesce(p_paid_on, current_date), p_note, app.current_user_id());

  -- Cash handed over for one order that does not settle it: that order is now
  -- waiting on the rest. (Unchanged rule; the balance is now the derived one.)
  if p_order_id is not null then
    update app.orders o set status = 'PAYMENT_PENDING'
    where o.id = p_order_id
      and o.status in ('DELIVERED', 'OUT_FOR_DELIVERY')
      and (select b.balance from app.v_order_balances b
            where b.order_id = p_order_id and b.customer_id = p_customer_id) > 0;
  end if;

  v_closed := app.settle_customer_orders(p_customer_id, p_order_id);

  select outstanding into v_out
  from app.v_customer_balances where customer_id = p_customer_id;

  return jsonb_build_object('payment_id', p_payment_id, 'created', true,
                            'customer_outstanding', v_out,
                            'settled_orders', to_jsonb(v_closed));
end
$fn$;

-- ---------------------------------------------------------------------------
-- set_order_status: same signature. Settles afterwards, because delivering a
-- prepaid order makes it closable and cancelling one returns its payments to
-- the customer's credit. Returns the status the order actually ended in.
-- (Also moves off `v_order is null` to FOUND -- see docs/supabase-access.md.)
-- ---------------------------------------------------------------------------

create or replace function public.set_order_status(p_order_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_customer uuid;
  v_closed   bigint[];
  v_status   text;
begin
  perform app.require_role('OWNER', 'MANAGER', 'DELIVERY', 'PACKER');
  perform app.require_write_access();

  if p_status not in ('PACKED','DELIVERED','PAYMENT_PENDING','CANCELLED') then
    raise exception 'status % must be reached through its own operation', p_status
      using errcode = '22023', hint = 'OUT_FOR_DELIVERY uses dispatch_order; CLOSED is set by record_payment';
  end if;

  select customer_id into v_customer from app.orders
  where id = p_order_id and business_id = v_business and deleted_at is null;
  if not found then
    raise exception 'order % not found', p_order_id using errcode = 'P0002';
  end if;

  update app.orders set
    status       = p_status,
    packed_at    = case when p_status = 'PACKED'    then coalesce(packed_at, now())    else packed_at end,
    delivered_at = case when p_status = 'DELIVERED' then coalesce(delivered_at, now()) else delivered_at end,
    cancelled_at = case when p_status = 'CANCELLED' then coalesce(cancelled_at, now()) else cancelled_at end
  where id = p_order_id;

  v_closed := app.settle_customer_orders(v_customer);

  select status into v_status from app.orders where id = p_order_id;

  return jsonb_build_object('order_id', p_order_id, 'status', v_status,
                            'settled_orders', to_jsonb(v_closed));
end
$fn$;

-- ---------------------------------------------------------------------------
-- Reads: paid/balance come from the view. Additive field: paid_from_account.
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
  v_rows jsonb;
begin
  perform app.require_member();
  p_limit := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.placed_at desc), '[]'::jsonb) into v_rows
  from (
    select o.id, o.order_no, o.customer_id,
           c.name as customer_name, c.phone as customer_phone,
           o.status, o.total_amount, o.notes,
           o.placed_at, o.packed_at, o.dispatched_at, o.delivered_at,
           o.closed_at, o.cancelled_at,
           -- A cancelled order has no row in the view: nothing is owed on it.
           coalesce(b.paid, 0) as paid,
           coalesce(b.balance, 0) as balance,
           coalesce(b.from_account, 0) as paid_from_account,
           (select count(*) from app.order_items oi
             where oi.order_id = o.id and oi.deleted_at is null) as item_count
    from app.orders o
    join app.customers c on c.id = o.customer_id
    left join app.v_order_balances b on b.order_id = o.id
    where o.business_id = v_business and o.deleted_at is null
      and (p_statuses is null or o.status = any(p_statuses))
      and (p_customer_id is null or o.customer_id = p_customer_id)
      and (p_from is null or o.placed_at >= p_from::timestamptz)
      and (p_to is null or o.placed_at < (p_to + 1)::timestamptz)
    order by o.placed_at desc limit p_limit + 1 offset p_offset
  ) x;
  return app.page(v_rows, p_limit, p_offset);
end
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

  if v_disp is null and v_status not in ('CANCELLED', 'CLOSED') then
    v_next := v_next || jsonb_build_array('cancel');
  end if;

  select jsonb_build_object(
    'order', jsonb_build_object(
      'id', o.id, 'order_no', o.order_no, 'status', o.status,
      'total_amount', o.total_amount, 'notes', o.notes,
      'placed_at', o.placed_at, 'packed_at', o.packed_at,
      'dispatched_at', o.dispatched_at, 'delivered_at', o.delivered_at,
      'closed_at', o.closed_at, 'cancelled_at', o.cancelled_at),
    'customer', jsonb_build_object(
      'id', c.id, 'name', c.name, 'phone', c.phone, 'address', c.address),
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
    'allowed_transitions', v_next
  ) into v_out
  from app.orders o
  join app.customers c on c.id = o.customer_id
  where o.id = p_order_id and o.business_id = v_business and o.deleted_at is null;

  return v_out;
end
$fn$;

create or replace function public.get_receipt(p_order_id uuid)
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
  perform app.require_role('OWNER', 'MANAGER', 'DELIVERY', 'PACKER');

  select jsonb_build_object(
    'business', jsonb_build_object(
      'name', b.name,
      'phone', b.phone,
      'address', b.address,
      'gstin', case when b.show_gstin_on_receipt then b.gstin else null end
    ),
    'order', jsonb_build_object(
      'id', o.id, 'order_no', o.order_no, 'status', o.status,
      'placed_at', o.placed_at, 'total_amount', o.total_amount
    ),
    'customer', jsonb_build_object('name', c.name, 'phone', c.phone, 'address', c.address),
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'name', ps.name,
               'pack_size_base', ps.pack_size_base,
               'qty_packets', oi.qty_packets,
               'unit_price', oi.unit_price,
               'line_total', oi.line_total
             ) order by ps.name), '[]'::jsonb)
      from app.order_items oi
      join app.packed_skus ps on ps.id = oi.packed_sku_id
      where oi.order_id = o.id and oi.deleted_at is null
    ),
    'paid', coalesce(ob.paid, 0),
    'paid_from_account', coalesce(ob.from_account, 0),
    'balance', coalesce(ob.balance, 0),
    'customer_outstanding', (
      select outstanding from app.v_customer_balances where customer_id = o.customer_id
    ),
    'document_type', 'PAYMENT_RECEIPT'
  )
  into v_out
  from app.orders o
  join app.customers c on c.id = o.customer_id
  cross join app.businesses b
  left join app.v_order_balances ob
    on ob.order_id = o.id and ob.customer_id = o.customer_id
  where o.id = p_order_id and o.business_id = v_business and b.id = v_business;

  if v_out is null then
    raise exception 'order % not found', p_order_id using errcode = 'P0002';
  end if;
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
           coalesce(b.from_account, 0) as paid_from_account
    from app.orders o
    left join app.v_order_balances b
      on b.order_id = o.id and b.customer_id = p_customer_id
    where o.customer_id = p_customer_id and o.business_id = v_business
      and o.deleted_at is null
    order by o.placed_at desc limit p_limit + 1 offset p_offset
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.paid_on desc), '[]'::jsonb) into v_pays
  from (
    select p.id, p.amount, p.paid_on, p.order_id, p.note, p.created_at
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
               'outstanding', b.outstanding)
      from app.v_customer_balances b
      where b.customer_id = p_customer_id and b.business_id = v_business),
    'orders', app.page(v_orders, p_limit, p_offset),
    'payments', app.page(v_pays, p_limit, p_offset)
  );
end
$fn$;

-- ---------------------------------------------------------------------------
-- Contract: paid/balance changed meaning and paid_from_account was added.
-- Old builds still read valid numbers, so min_client stays where it is.
-- ---------------------------------------------------------------------------

create or replace function app.schema_contract()
returns jsonb
language sql
immutable
set search_path = ''
as $fn$
  select jsonb_build_object(
    'current',    2,
    'min_client', 1
  )
$fn$;

-- ---------------------------------------------------------------------------
-- Bring existing data into line once: delivered orders that account credit
-- already covers are closed now, rather than on that customer's next payment.
-- Runs as the migration owner, so it is not scoped by current_business_id();
-- it is the same rule settle_customer_orders applies, minus the door case.
-- ---------------------------------------------------------------------------

update app.orders o
   set status = 'CLOSED', closed_at = coalesce(o.closed_at, now())
  from app.v_order_balances b
 where b.order_id = o.id
   and b.balance <= 0
   and o.status in ('DELIVERED', 'PAYMENT_PENDING');
