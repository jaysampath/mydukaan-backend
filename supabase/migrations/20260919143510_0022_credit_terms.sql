-- 0022 -- credit terms and due dates.
--
-- Wholesale customers buy on credit: goods delivered today, paid within 15 or
-- 30 days, and the owner decides who gets what. Nothing recorded that, so no
-- screen could say which orders are overdue.
--
--   * customers.credit_days     -- this customer's terms (null: use the default)
--   * businesses.default_credit_days -- the shop's terms (null: no terms at all)
--   * orders.due_on             -- the date this order's balance is due
--
-- due_on is STAMPED once, when the goods have gone (the order first reaches
-- DELIVERED / PAYMENT_PENDING / CLOSED), from the terms in force at that moment.
-- Changing a customer's terms later does not move a due date that was already
-- agreed; the owner moves one order at a time with set_order_due_date.
--
-- No terms, no due date: with neither a customer nor a business figure the
-- order is never "due", so a shop is not flooded with overdue orders the day
-- this ships.
--
-- Overdue is DERIVED, never stored: an order is overdue when its derived
-- balance (app.v_order_balances, 0021) is positive and due_on has passed. So an
-- account payment that settles the oldest orders first clears their overdue
-- state by itself. Screens render due_state; they never recompute it, for the
-- same reason they render allowed_transitions.
--
-- "Today" is the Indian calendar date, not current_date: the database runs in
-- UTC, and an order delivered at 1 am IST would otherwise be dated yesterday.

-- ---------------------------------------------------------------------------
-- Columns.
-- ---------------------------------------------------------------------------

alter table app.customers
  add column if not exists credit_days integer
    check (credit_days is null or credit_days between 0 and 365);

alter table app.businesses
  add column if not exists default_credit_days integer
    check (default_credit_days is null or default_credit_days between 0 and 365);

alter table app.orders
  add column if not exists due_on date;

create index if not exists orders_due_idx
  on app.orders (business_id, due_on)
  where deleted_at is null and due_on is not null;

-- ---------------------------------------------------------------------------
-- The calendar and the due rule, each stated once.
-- ---------------------------------------------------------------------------

create or replace function app.local_date(p_at timestamptz)
returns date
language sql
stable
set search_path = ''
as $fn$
  -- India only (see CLAUDE.md, product invariants). If the product ever
  -- leaves one time zone this becomes a column on businesses.
  select (p_at at time zone 'Asia/Kolkata')::date
$fn$;

create or replace function app.local_today()
returns date
language sql
stable
set search_path = ''
as $fn$
  select app.local_date(now())
$fn$;

-- null when nothing is owed or no date was agreed.
create or replace function app.due_state(p_due_on date, p_balance numeric)
returns text
language sql
stable
set search_path = ''
as $fn$
  select case
    when p_due_on is null or coalesce(p_balance, 0) <= 0 then null
    when p_due_on < app.local_today() then 'OVERDUE'
    when p_due_on = app.local_today() then 'DUE_TODAY'
    else 'UPCOMING'
  end
$fn$;

-- Negative when overdue. null exactly when due_state is null.
create or replace function app.due_in_days(p_due_on date, p_balance numeric)
returns integer
language sql
stable
set search_path = ''
as $fn$
  select case when app.due_state(p_due_on, p_balance) is null then null
              else p_due_on - app.local_today() end
$fn$;

-- The terms that apply to a customer right now: theirs, else the shop's.
create or replace function app.credit_days_for(p_customer_id uuid)
returns integer
language sql
stable
set search_path = ''
as $fn$
  select coalesce(c.credit_days, b.default_credit_days)
  from app.customers c
  join app.businesses b on b.id = c.business_id
  where c.id = p_customer_id
$fn$;

-- Every live order that has a due date and still owes money. The Due list and
-- the home card both read this, so they cannot disagree.
create or replace function app.due_orders()
returns table (
  order_id uuid, order_no bigint, customer_id uuid, customer_name text,
  customer_phone text, status text, total_amount numeric, paid numeric,
  balance numeric, due_on date, delivered_at timestamptz,
  due_state text, due_in_days integer
)
language sql
stable
security invoker
set search_path = ''
as $fn$
  select o.id, o.order_no, o.customer_id, c.name, c.phone, o.status,
         o.total_amount, b.paid, b.balance, o.due_on, o.delivered_at,
         app.due_state(o.due_on, b.balance), app.due_in_days(o.due_on, b.balance)
  from app.orders o
  join app.customers c on c.id = o.customer_id
  join app.v_order_balances b on b.order_id = o.id and b.customer_id = o.customer_id
  where o.business_id = app.current_business_id()
    and o.deleted_at is null
    and o.due_on is not null
    and b.balance > 0
$fn$;

revoke all on function app.due_orders() from public, anon, authenticated;
grant execute on function app.due_orders() to app_api;

-- ---------------------------------------------------------------------------
-- Stamping. A trigger, not a line in each RPC, because goods leave through
-- more than one door: set_order_status('DELIVERED'), and record_payment moving
-- an OUT_FOR_DELIVERY order to PAYMENT_PENDING (or CLOSED) at the door -- a
-- path that never sets delivered_at. Never overwrites a date already set.
-- ---------------------------------------------------------------------------

create or replace function app.stamp_due_on()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $fn$
declare
  v_days integer;
begin
  if new.status in ('DELIVERED', 'PAYMENT_PENDING', 'CLOSED') then
    v_days := app.credit_days_for(new.customer_id);
    if v_days is not null then
      new.due_on := app.local_date(coalesce(new.delivered_at, now())) + v_days;
    end if;
  end if;
  return new;
end
$fn$;

drop trigger if exists orders_stamp_due_on on app.orders;
create trigger orders_stamp_due_on
  before update of status on app.orders
  for each row
  when (new.due_on is null and new.status is distinct from old.status)
  execute function app.stamp_due_on();

-- ---------------------------------------------------------------------------
-- Setting terms. Separate RPCs rather than new parameters on upsert_customer /
-- update_business_settings: no DROP-then-create (PostgREST overloads), and an
-- old build saving a customer cannot wipe the customer's terms.
--
-- Both backfill: open orders that went out with no terms get a date now, so a
-- shop that sets terms today sees its existing debts on the Due list at once.
-- A date already set is never moved.
-- ---------------------------------------------------------------------------

create or replace function public.set_customer_credit_days(
  p_customer_id uuid,
  p_credit_days integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_days     integer;
  v_dated    integer := 0;
begin
  perform app.require_role('OWNER', 'MANAGER');
  perform app.require_write_access();

  if p_credit_days is not null and (p_credit_days < 0 or p_credit_days > 365) then
    raise exception 'credit days must be between 0 and 365' using errcode = '22023';
  end if;

  update app.customers set credit_days = p_credit_days
  where id = p_customer_id and business_id = v_business and deleted_at is null;
  if not found then
    raise exception 'customer % not found', p_customer_id using errcode = 'P0002';
  end if;

  v_days := app.credit_days_for(p_customer_id);
  if v_days is not null then
    update app.orders o
       set due_on = app.local_date(coalesce(o.delivered_at, o.dispatched_at, o.updated_at)) + v_days
     where o.business_id = v_business
       and o.customer_id = p_customer_id
       and o.deleted_at is null
       and o.due_on is null
       and o.status in ('DELIVERED', 'PAYMENT_PENDING');
    get diagnostics v_dated = row_count;
  end if;

  return jsonb_build_object('customer_id', p_customer_id,
                            'credit_days', p_credit_days,
                            'orders_dated', v_dated);
end
$fn$;

create or replace function public.set_default_credit_days(p_credit_days integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_dated    integer := 0;
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();

  if p_credit_days is not null and (p_credit_days < 0 or p_credit_days > 365) then
    raise exception 'credit days must be between 0 and 365' using errcode = '22023';
  end if;

  update app.businesses set default_credit_days = p_credit_days where id = v_business;

  if p_credit_days is not null then
    update app.orders o
       set due_on = app.local_date(coalesce(o.delivered_at, o.dispatched_at, o.updated_at)) + p_credit_days
      from app.customers c
     where c.id = o.customer_id
       and c.credit_days is null
       and o.business_id = v_business
       and o.deleted_at is null
       and o.due_on is null
       and o.status in ('DELIVERED', 'PAYMENT_PENDING');
    get diagnostics v_dated = row_count;
  end if;

  return jsonb_build_object('default_credit_days', p_credit_days,
                            'orders_dated', v_dated);
end
$fn$;

-- The per-order override. Offered (allowed_transitions: set_due_date) only
-- once the goods are on their way and money is still owed; null clears it.
create or replace function public.set_order_due_date(p_order_id uuid, p_due_on date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_status   text;
begin
  perform app.require_role('OWNER', 'MANAGER');
  perform app.require_write_access();

  select status into v_status from app.orders
  where id = p_order_id and business_id = v_business and deleted_at is null;
  if not found then
    raise exception 'order % not found', p_order_id using errcode = 'P0002';
  end if;

  if v_status not in ('OUT_FOR_DELIVERY', 'DELIVERED', 'PAYMENT_PENDING') then
    raise exception 'a % order has no due date to set', v_status
      using errcode = '22023', hint = 'not_due';
  end if;

  update app.orders set due_on = p_due_on where id = p_order_id;

  return jsonb_build_object('order_id', p_order_id, 'due_on', p_due_on);
end
$fn$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.set_customer_credit_days(uuid, integer)',
    'public.set_default_credit_days(integer)',
    'public.set_order_due_date(uuid, date)'
  ] loop
    execute format('alter function %s owner to app_api', f);
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- The Due list.
-- ---------------------------------------------------------------------------

create or replace function public.list_due_orders(
  p_scope  text    default null,
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
  -- Unused below: app.due_orders() applies app.current_business_id() itself.
  -- Declared so this function states its tenant scope like every other read,
  -- which is what the tenant_read_function_missing_business_scope lint checks.
  v_business uuid := app.current_business_id();
  v_rows     jsonb;
  v_summary  jsonb;
begin
  perform app.require_role('OWNER', 'MANAGER', 'DELIVERY');
  if p_scope is not null and p_scope not in ('OVERDUE', 'DUE_TODAY', 'UPCOMING') then
    raise exception 'unknown scope %', p_scope using errcode = '22023';
  end if;
  p_limit  := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.due_on, x.order_no), '[]'::jsonb)
    into v_rows
  from (
    select d.order_id as id, d.order_no, d.customer_id, d.customer_name,
           d.customer_phone, d.status, d.total_amount, d.paid, d.balance,
           d.due_on, d.delivered_at, d.due_state, d.due_in_days
    from app.due_orders() d
    where p_scope is null or d.due_state = p_scope
    order by d.due_on, d.order_no
    limit p_limit + 1 offset p_offset
  ) x;

  select jsonb_build_object(
           'overdue',   jsonb_build_object(
             'count',  count(*) filter (where due_state = 'OVERDUE'),
             'amount', coalesce(sum(balance) filter (where due_state = 'OVERDUE'), 0)),
           'due_today', jsonb_build_object(
             'count',  count(*) filter (where due_state = 'DUE_TODAY'),
             'amount', coalesce(sum(balance) filter (where due_state = 'DUE_TODAY'), 0)),
           'upcoming',  jsonb_build_object(
             'count',  count(*) filter (where due_state = 'UPCOMING'),
             'amount', coalesce(sum(balance) filter (where due_state = 'UPCOMING'), 0)))
    into v_summary
  from app.due_orders();

  return app.page(v_rows, p_limit, p_offset) || jsonb_build_object('summary', v_summary);
end
$fn$;

alter function public.list_due_orders(text, integer, integer) owner to app_api;
revoke all on function public.list_due_orders(text, integer, integer) from public, anon;
grant execute on function public.list_due_orders(text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Existing reads, additive fields only. Same signatures, so create or replace
-- keeps owner and grants.
-- ---------------------------------------------------------------------------

-- get_order: order.due_on, top-level due_state / due_in_days, and the
-- set_due_date action.
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
    'allowed_transitions', v_next
  ) into v_out
  from app.orders o
  join app.customers c on c.id = o.customer_id
  where o.id = p_order_id and o.business_id = v_business and o.deleted_at is null;

  return v_out;
end
$fn$;

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
             where oi.order_id = o.id and oi.deleted_at is null) as item_count,
           o.due_on,
           app.due_state(o.due_on, b.balance) as due_state,
           app.due_in_days(o.due_on, b.balance) as due_in_days
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
           coalesce(bal.outstanding, 0) as outstanding,
           c.credit_days
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
             where o.customer_id = b.customer_id and o.deleted_at is null) as last_order_at,
           coalesce((select sum(d.balance) from app.due_orders() d
                      where d.customer_id = b.customer_id
                        and d.due_state = 'OVERDUE'), 0) as overdue_amount
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
begin
  perform app.require_member();
  v_day := coalesce(p_on, current_date);

  select count(*) filter (where due_state = 'OVERDUE')                       as overdue_count,
         coalesce(sum(balance) filter (where due_state = 'OVERDUE'), 0)    as overdue_amount,
         count(*) filter (where due_state = 'DUE_TODAY')                     as due_today_count,
         coalesce(sum(balance) filter (where due_state = 'DUE_TODAY'), 0)  as due_today_amount
    into v_due
  from app.due_orders();

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
    ),
    'overdue_count',    v_due.overdue_count,
    'overdue_amount',   v_due.overdue_amount,
    'due_today_count',  v_due.due_today_count,
    'due_today_amount', v_due.due_today_amount
  );
end
$fn$;

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

  -- FOUND, not `v_profile is not null`: see migration 0016.
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
             b.features, b.default_credit_days
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
    'is_read_only',     case when v_business is null then true
                        else not app.has_write_access() end,
    'seats',            case when v_business is null then 'null'::jsonb
                        else jsonb_build_object(
                               'limit', v_limit,
                               'used', v_used,
                               'available', greatest(v_limit - v_used, 0))
                        end,
    'contract',         app.schema_contract(),
    'is_platform_admin', app.is_platform_admin(),
    'server_time',       now()
  );
end
$fn$;

-- ---------------------------------------------------------------------------
-- Contract: additive fields only (due_on, due_state, due_in_days, credit_days,
-- default_credit_days, the day-summary due counts, set_due_date). Old builds
-- ignore them, so min_client stays where it is.
-- ---------------------------------------------------------------------------

create or replace function app.schema_contract()
returns jsonb
language sql
immutable
set search_path = ''
as $fn$
  select jsonb_build_object(
    'current',    3,
    'min_client', 1
  )
$fn$;
