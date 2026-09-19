-- 0024 -- how a payment was made: CASH or UPI.
--
-- Customers now pay by UPI as well as cash. The app records which; it never
-- takes the money -- there is still no gateway, no verification and no
-- reconciliation. The owner says "he paid by UPI" and that is what is stored.
--
-- app.payments.method has existed since 0004, as `text not null default 'CASH'`
-- with a check allowing only CASH, so no column is added: the check widens and
-- record_payment learns to receive the method.
--
-- Old builds keep working. record_payment gains p_method with a default of
-- 'CASH', so a call without it records cash exactly as before. Every read
-- change is an added field.

-- ---------------------------------------------------------------------------
-- The column's allowed values. DDL, so the append-only triggers on payments
-- are not involved; every existing row is CASH and validates.
-- ---------------------------------------------------------------------------

alter table app.payments drop constraint if exists payments_method_check;
alter table app.payments
  add constraint payments_method_check check (method in ('CASH', 'UPI'));

-- ---------------------------------------------------------------------------
-- record_payment: the 0021 body plus p_method.
--
-- DROP, then create -- not an overload. PostgREST resolves overloaded
-- functions by the key names in the request body, so two record_payment
-- signatures would be a runtime ambiguity error (0012 and 0017 both hit this).
-- A call without p_method still matches the new signature through the default.
-- ---------------------------------------------------------------------------

drop function if exists public.record_payment(uuid, uuid, numeric, uuid, date, text);

create function public.record_payment(
  p_payment_id  uuid,
  p_customer_id uuid,
  p_amount      numeric,
  p_order_id    uuid default null,
  p_paid_on     date default null,
  p_note        text default null,
  p_method      text default 'CASH'
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
  v_method   text := coalesce(upper(btrim(p_method)), 'CASH');
begin
  perform app.require_role('OWNER', 'MANAGER', 'DELIVERY');
  perform app.require_write_access();

  if p_amount is null or p_amount = 0 then
    raise exception 'payment amount must be non-zero' using errcode = '22023';
  end if;

  if v_method not in ('CASH', 'UPI') then
    raise exception 'payment method must be CASH or UPI, got %', p_method using errcode = '22023';
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

  insert into app.payments
    (id, business_id, customer_id, order_id, amount, method, paid_on, note, created_by)
  values
    (p_payment_id, v_business, p_customer_id, p_order_id, p_amount, v_method,
     coalesce(p_paid_on, current_date), p_note, app.current_user_id());

  -- Cash handed over for one order that does not settle it: that order is now
  -- waiting on the rest.
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
                            'method', v_method,
                            'customer_outstanding', v_out,
                            'settled_orders', to_jsonb(v_closed));
end
$fn$;

alter function public.record_payment(uuid, uuid, numeric, uuid, date, text, text) owner to app_api;
revoke all on function public.record_payment(uuid, uuid, numeric, uuid, date, text, text) from public, anon;
grant execute on function public.record_payment(uuid, uuid, numeric, uuid, date, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Reads: the method wherever a payment is shown. Same signatures.
-- ---------------------------------------------------------------------------

-- Vouchers (0023) gain the method of the payment they were taken with, for the
-- caption ("₹500 UPI").
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
             'payment_amount', p.amount, 'payment_method', p.method,
             'paid_on', p.paid_on,
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
               'id', p.id, 'amount', p.amount, 'method', p.method,
               'paid_on', p.paid_on, 'note', p.note
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
    select p.id, p.amount, p.method, p.paid_on, p.order_id, p.note, p.created_at,
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

-- The home card splits the day's collection by method. `cash_collected` keeps
-- its name and now means everything collected, by any method: old builds
-- render it under "Cash today", and a total that silently dropped UPI would be
-- the worse lie of the two.
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
  v_due      record;
  v_took     record;
begin
  perform app.require_member();
  v_day := coalesce(p_on, current_date);

  select count(*) filter (where due_state = 'OVERDUE')                       as overdue_count,
         coalesce(sum(balance) filter (where due_state = 'OVERDUE'), 0)    as overdue_amount,
         count(*) filter (where due_state = 'DUE_TODAY')                     as due_today_count,
         coalesce(sum(balance) filter (where due_state = 'DUE_TODAY'), 0)  as due_today_amount
    into v_due
  from app.due_orders();

  select coalesce(sum(amount), 0)                                  as total,
         coalesce(sum(amount) filter (where method = 'CASH'), 0)  as cash,
         coalesce(sum(amount) filter (where method = 'UPI'), 0)   as upi
    into v_took
  from app.payments
  where business_id = v_business and paid_on = v_day;

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
    'cash_collected', v_took.total,
    'collected_cash', v_took.cash,
    'collected_upi',  v_took.upi,
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
    ),
    'overdue_count',    v_due.overdue_count,
    'overdue_amount',   v_due.overdue_amount,
    'due_today_count',  v_due.due_today_count,
    'due_today_amount', v_due.due_today_amount
  );
end
$fn$;

-- ---------------------------------------------------------------------------
-- Contract: additive (method on payments, collected_cash / collected_upi,
-- payment_method on vouchers). min_client stays at 1.
-- ---------------------------------------------------------------------------

create or replace function app.schema_contract()
returns jsonb
language sql
immutable
set search_path = ''
as $fn$
  select jsonb_build_object(
    'current',    4,
    'min_client', 1
  )
$fn$;
