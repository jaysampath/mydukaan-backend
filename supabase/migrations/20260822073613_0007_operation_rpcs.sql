-- 0007_operation_rpcs
-- The secured business API. One function per business operation, each with
-- validated inputs, an explicit role check, and tenant scope taken from the
-- JWT rather than the payload.
--
-- Idempotency: every operation takes the record's uuid from the caller. A
-- device that loses its connection mid-call can safely retry -- the second
-- call sees the work is already done and returns the same answer. This is a
-- requirement, not a nicety, for a client that is offline half the time.
--
-- On duplication with the client: writes that happen offline are composed on
-- the device (see src/domain) and arrive later through sync_push. These
-- functions are the online path and the authority on what the rules ARE.
-- See /docs/supabase-access.md, "Two write paths".

-- ---------------------------------------------------------------------------
-- Subscription gate.
-- A lapsed subscription is READ-ONLY, never a data lock: new work is refused
-- here, but sync_push is deliberately NOT gated, so anything the user already
-- recorded on their phone still reaches the server.
-- ---------------------------------------------------------------------------

create or replace function app.require_write_access()
returns void
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

  if b is null then
    raise exception 'no business in scope' using errcode = '42501';
  end if;

  if b.subscription_status = 'ACTIVE' then
    return;
  end if;

  if b.subscription_status = 'TRIAL'
     and (b.trial_ends_at is null or b.trial_ends_at > now()) then
    return;
  end if;

  raise exception 'subscription is not active; the app is read-only until it is renewed'
    using errcode = '42501', hint = 'read_only';
end
$fn$;

-- ---------------------------------------------------------------------------
-- Onboarding. The one privileged entry point: it runs before the caller has a
-- profile, so app.current_business_id() is still null and the tenant RLS
-- policies cannot apply. Owned by postgres for exactly that reason, and
-- guarded by the check that the caller has no profile yet.
-- ---------------------------------------------------------------------------

create or replace function public.bootstrap_business(
  p_business_name text,
  p_owner_name    text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_user     uuid := app.current_user_id();
  v_business uuid;
  v_existing uuid;
begin
  if v_user is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_business_name is null or length(btrim(p_business_name)) = 0 then
    raise exception 'business name is required' using errcode = '22023';
  end if;

  -- Idempotent: a retry after a dropped response returns the same business.
  select business_id into v_existing from app.profiles where id = v_user;
  if v_existing is not null then
    return jsonb_build_object('business_id', v_existing, 'created', false);
  end if;

  insert into app.businesses (name, trial_ends_at, created_by)
  values (btrim(p_business_name), now() + interval '30 days', v_user)
  returning id into v_business;

  insert into app.profiles (id, business_id, full_name, role, created_by)
  values (v_user, v_business, coalesce(btrim(p_owner_name), ''), 'OWNER', v_user);

  return jsonb_build_object('business_id', v_business, 'created', true);
end
$fn$;

revoke all on function public.bootstrap_business(text, text) from public, anon;
grant execute on function public.bootstrap_business(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Business settings. The GSTIN toggle lives here and is free for every plan --
-- receipts are payment confirmations, not tax invoices, so hiding the toggle
-- behind billing would be wrong.
-- ---------------------------------------------------------------------------

create or replace function public.update_business_settings(
  p_name                 text default null,
  p_phone                text default null,
  p_address              text default null,
  p_gstin                text default null,
  p_show_gstin_on_receipt boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_row      app.businesses;
begin
  perform app.require_role('OWNER');

  update app.businesses set
    name                  = coalesce(nullif(btrim(p_name), ''), name),
    phone                 = coalesce(p_phone, phone),
    address               = coalesce(p_address, address),
    gstin                 = case when p_gstin is null then gstin
                                 when btrim(p_gstin) = '' then null
                                 else upper(btrim(p_gstin)) end,
    show_gstin_on_receipt = coalesce(p_show_gstin_on_receipt, show_gstin_on_receipt)
  where id = v_business
  returning * into v_row;

  return app.to_wire(to_jsonb(v_row));
end
$fn$;

alter function public.update_business_settings(text, text, text, text, boolean) owner to app_api;
revoke all on function public.update_business_settings(text, text, text, text, boolean) from public, anon;
grant execute on function public.update_business_settings(text, text, text, text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Procurement: receiving a purchase writes the PURCHASE_IN rows.
-- ---------------------------------------------------------------------------

create or replace function public.receive_purchase(p_purchase_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_purchase app.purchases;
  v_no       bigint;
begin
  perform app.require_role('OWNER', 'MANAGER');
  perform app.require_write_access();

  select * into v_purchase from app.purchases
  where id = p_purchase_id and business_id = v_business and deleted_at is null;

  if v_purchase is null then
    raise exception 'purchase % not found', p_purchase_id using errcode = 'P0002';
  end if;
  if v_purchase.status = 'RECEIVED' then
    return jsonb_build_object('purchase_id', p_purchase_id, 'already_received', true);
  end if;
  if v_purchase.status = 'CANCELLED' then
    raise exception 'purchase % is cancelled', p_purchase_id using errcode = '22023';
  end if;

  insert into app.stock_ledger (
    business_id, entry_type, item_kind, raw_material_id, qty_base,
    ref_type, ref_id, created_by
  )
  select v_business, 'PURCHASE_IN', 'RAW', pi.raw_material_id, pi.qty_base,
         'PURCHASE', p_purchase_id, app.current_user_id()
  from app.purchase_items pi
  where pi.purchase_id = p_purchase_id
    and pi.business_id = v_business
    and pi.deleted_at is null;

  if v_purchase.purchase_no is null then
    insert into app.business_counters (business_id, name, value)
    values (v_business, 'purchase_no', 1)
    on conflict (business_id, name) do update set value = app.business_counters.value + 1
    returning value into v_no;
  else
    v_no := v_purchase.purchase_no;
  end if;

  update app.purchases
     set status = 'RECEIVED', received_at = now(), purchase_no = v_no
   where id = p_purchase_id;

  return jsonb_build_object('purchase_id', p_purchase_id, 'purchase_no', v_no, 'already_received', false);
end
$fn$;

alter function public.receive_purchase(uuid) owner to app_api;
revoke all on function public.receive_purchase(uuid) from public, anon;
grant execute on function public.receive_purchase(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Packing / conversion: bulk raw out, retail packets in, in one transaction.
-- Wastage is recorded explicitly rather than inferred, so the ledger balances
-- against what actually left the sack.
-- ---------------------------------------------------------------------------

create or replace function public.run_conversion(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_run      app.packing_runs;
  v_avail    numeric;
begin
  perform app.require_role('OWNER', 'MANAGER', 'PACKER');
  perform app.require_write_access();

  select * into v_run from app.packing_runs
  where id = p_run_id and business_id = v_business and deleted_at is null;

  if v_run is null then
    raise exception 'packing run % not found', p_run_id using errcode = 'P0002';
  end if;
  if v_run.status = 'COMPLETED' then
    return jsonb_build_object('packing_run_id', p_run_id, 'already_completed', true);
  end if;

  select coalesce(sum(qty_base), 0) into v_avail
  from app.stock_ledger
  where business_id = v_business and raw_material_id = v_run.raw_material_id;

  if v_avail < v_run.raw_consumed_base then
    raise exception 'not enough raw stock: have %, run needs %', v_avail, v_run.raw_consumed_base
      using errcode = '23514';
  end if;

  insert into app.stock_ledger (
    business_id, entry_type, item_kind, raw_material_id, qty_base,
    ref_type, ref_id, created_by
  ) values (
    v_business, 'PACK_OUT', 'RAW', v_run.raw_material_id, -v_run.raw_consumed_base,
    'PACKING_RUN', p_run_id, app.current_user_id()
  );

  insert into app.stock_ledger (
    business_id, entry_type, item_kind, packed_sku_id, qty_base,
    ref_type, ref_id, created_by
  ) values (
    v_business, 'PACK_IN', 'PACKED', v_run.packed_sku_id, v_run.packets_produced,
    'PACKING_RUN', p_run_id, app.current_user_id()
  );

  update app.packing_runs
     set status = 'COMPLETED', completed_at = now()
   where id = p_run_id;

  return jsonb_build_object('packing_run_id', p_run_id, 'already_completed', false);
end
$fn$;

alter function public.run_conversion(uuid) owner to app_api;
revoke all on function public.run_conversion(uuid) from public, anon;
grant execute on function public.run_conversion(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Orders.
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

  select * into v_existing from app.orders
  where id = p_order_id and business_id = v_business;
  if v_existing is not null then
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

-- DISPATCH is the moment stock leaves. Not order confirmation -- dispatch.
create or replace function public.dispatch_order(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_order    app.orders;
  v_short    record;
begin
  perform app.require_role('OWNER', 'MANAGER', 'DELIVERY');
  perform app.require_write_access();

  select * into v_order from app.orders
  where id = p_order_id and business_id = v_business and deleted_at is null;

  if v_order is null then
    raise exception 'order % not found', p_order_id using errcode = 'P0002';
  end if;
  if v_order.status in ('OUT_FOR_DELIVERY','DELIVERED','PAYMENT_PENDING','CLOSED') then
    return jsonb_build_object('order_id', p_order_id, 'already_dispatched', true);
  end if;
  if v_order.status = 'CANCELLED' then
    raise exception 'order % is cancelled', p_order_id using errcode = '22023';
  end if;

  -- Refuse to dispatch more than exists. The ledger is the only source of
  -- truth for what is on the shelf.
  select oi.packed_sku_id, ps.name, oi.needed, coalesce(s.on_hand, 0) as on_hand
    into v_short
  from (
    select packed_sku_id, sum(qty_packets) as needed
    from app.order_items
    where order_id = p_order_id and deleted_at is null
    group by packed_sku_id
  ) oi
  join app.packed_skus ps on ps.id = oi.packed_sku_id
  left join (
    select packed_sku_id, sum(qty_base) as on_hand
    from app.stock_ledger
    where business_id = v_business and packed_sku_id is not null
    group by packed_sku_id
  ) s on s.packed_sku_id = oi.packed_sku_id
  where coalesce(s.on_hand, 0) < oi.needed
  limit 1;

  if v_short is not null then
    raise exception 'not enough stock of %: have %, order needs %',
      v_short.name, v_short.on_hand, v_short.needed
      using errcode = '23514';
  end if;

  insert into app.stock_ledger (
    business_id, entry_type, item_kind, packed_sku_id, qty_base,
    ref_type, ref_id, created_by
  )
  select v_business, 'SALE_OUT', 'PACKED', oi.packed_sku_id, -sum(oi.qty_packets),
         'ORDER', p_order_id, app.current_user_id()
  from app.order_items oi
  where oi.order_id = p_order_id and oi.deleted_at is null
  group by oi.packed_sku_id;

  update app.orders
     set status = 'OUT_FOR_DELIVERY', dispatched_at = now()
   where id = p_order_id;

  return jsonb_build_object('order_id', p_order_id, 'already_dispatched', false);
end
$fn$;

alter function public.dispatch_order(uuid) owner to app_api;
revoke all on function public.dispatch_order(uuid) from public, anon;
grant execute on function public.dispatch_order(uuid) to authenticated;

create or replace function public.set_order_status(p_order_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_order    app.orders;
begin
  perform app.require_role('OWNER', 'MANAGER', 'DELIVERY', 'PACKER');
  perform app.require_write_access();

  if p_status not in ('PACKED','DELIVERED','PAYMENT_PENDING','CANCELLED') then
    raise exception 'status % must be reached through its own operation', p_status
      using errcode = '22023', hint = 'OUT_FOR_DELIVERY uses dispatch_order; CLOSED is set by record_payment';
  end if;

  select * into v_order from app.orders
  where id = p_order_id and business_id = v_business and deleted_at is null;
  if v_order is null then
    raise exception 'order % not found', p_order_id using errcode = 'P0002';
  end if;

  update app.orders set
    status       = p_status,
    packed_at    = case when p_status = 'PACKED'    then coalesce(packed_at, now())    else packed_at end,
    delivered_at = case when p_status = 'DELIVERED' then coalesce(delivered_at, now()) else delivered_at end,
    cancelled_at = case when p_status = 'CANCELLED' then coalesce(cancelled_at, now()) else cancelled_at end
  where id = p_order_id;

  return jsonb_build_object('order_id', p_order_id, 'status', p_status);
end
$fn$;

alter function public.set_order_status(uuid, text) owner to app_api;
revoke all on function public.set_order_status(uuid, text) from public, anon;
grant execute on function public.set_order_status(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Cash. Partial payments over several days are the normal case, so a payment
-- is an append-only row and the order closes only once the running total
-- covers it.
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
  v_paid     numeric;
  v_out      numeric;
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

  insert into app.payments (id, business_id, customer_id, order_id, amount, paid_on, note, created_by)
  values (p_payment_id, v_business, p_customer_id, p_order_id, p_amount,
          coalesce(p_paid_on, current_date), p_note, app.current_user_id());

  -- Close the order only when it is genuinely settled.
  if p_order_id is not null then
    select coalesce(sum(amount), 0) into v_paid
    from app.payments where order_id = p_order_id;

    select total_amount - v_paid into v_out
    from app.orders where id = p_order_id and business_id = v_business;

    if v_out <= 0 then
      update app.orders set status = 'CLOSED', closed_at = now()
      where id = p_order_id and status <> 'CANCELLED';
    else
      update app.orders set status = 'PAYMENT_PENDING'
      where id = p_order_id and status in ('DELIVERED','OUT_FOR_DELIVERY');
    end if;
  end if;

  select outstanding into v_out
  from app.v_customer_balances where customer_id = p_customer_id;

  return jsonb_build_object('payment_id', p_payment_id, 'created', true,
                            'customer_outstanding', v_out);
end
$fn$;

alter function public.record_payment(uuid, uuid, numeric, uuid, date, text) owner to app_api;
revoke all on function public.record_payment(uuid, uuid, numeric, uuid, date, text) from public, anon;
grant execute on function public.record_payment(uuid, uuid, numeric, uuid, date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Receipt payload. The client renders the PDF; the server decides what is on
-- it, including whether the GSTIN is shown.
-- ---------------------------------------------------------------------------

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
      -- Free toggle, never gated by plan.
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
    'paid', (select coalesce(sum(amount), 0) from app.payments where order_id = o.id),
    'balance', o.total_amount
               - (select coalesce(sum(amount), 0) from app.payments where order_id = o.id),
    'customer_outstanding', (
      select outstanding from app.v_customer_balances where customer_id = o.customer_id
    ),
    -- A receipt is a payment confirmation, not a tax invoice. Stated on the
    -- document itself so it is never mistaken for one.
    'document_type', 'PAYMENT_RECEIPT'
  )
  into v_out
  from app.orders o
  join app.customers c on c.id = o.customer_id
  cross join app.businesses b
  where o.id = p_order_id and o.business_id = v_business and b.id = v_business;

  if v_out is null then
    raise exception 'order % not found', p_order_id using errcode = 'P0002';
  end if;
  return v_out;
end
$fn$;

alter function public.get_receipt(uuid) owner to app_api;
revoke all on function public.get_receipt(uuid) from public, anon;
grant execute on function public.get_receipt(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Read models. Stock is derived from the ledger every time; there is no cached
-- quantity anywhere to drift.
-- ---------------------------------------------------------------------------

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
  if v_business is null then
    raise exception 'caller is not an active member of any business' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'raw', (
      select coalesce(jsonb_agg(to_jsonb(r) order by r.name), '[]'::jsonb)
      from app.v_raw_stock r where r.business_id = v_business
    ),
    'packed', (
      select coalesce(jsonb_agg(to_jsonb(p) order by p.name), '[]'::jsonb)
      from app.v_packed_stock p where p.business_id = v_business
    )
  );
end
$fn$;

alter function public.get_stock_snapshot() owner to app_api;
revoke all on function public.get_stock_snapshot() from public, anon;
grant execute on function public.get_stock_snapshot() to authenticated;

create or replace function public.get_customer_ledger(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
begin
  if v_business is null then
    raise exception 'caller is not an active member of any business' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'balance', (
      select to_jsonb(b) from app.v_customer_balances b
      where b.customer_id = p_customer_id and b.business_id = v_business
    ),
    'orders', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', o.id, 'order_no', o.order_no, 'status', o.status,
               'total_amount', o.total_amount, 'placed_at', o.placed_at
             ) order by o.placed_at desc), '[]'::jsonb)
      from app.orders o
      where o.customer_id = p_customer_id and o.business_id = v_business
        and o.deleted_at is null
    ),
    'payments', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'amount', p.amount, 'paid_on', p.paid_on,
               'order_id', p.order_id, 'note', p.note
             ) order by p.paid_on desc, p.created_at desc), '[]'::jsonb)
      from app.payments p
      where p.customer_id = p_customer_id and p.business_id = v_business
    )
  );
end
$fn$;

alter function public.get_customer_ledger(uuid) owner to app_api;
revoke all on function public.get_customer_ledger(uuid) from public, anon;
grant execute on function public.get_customer_ledger(uuid) to authenticated;

-- Bootstrap must stay owned by postgres: it runs before the caller has a
-- profile, so RLS has no business_id to match against.
alter function public.bootstrap_business(text, text) owner to postgres;
