-- 0026 -- what you buy, and what you still owe the supplier.
--
-- The selling side of this business has been modelled end to end since 0021:
-- an order is billed, paid against, allocated and settled, and every figure is
-- derived. The buying side has been half-built since 0003 -- app.suppliers,
-- app.purchases and app.purchase_items exist, create_purchase posts PURCHASE_IN
-- rows through receive_purchase -- but nothing recorded what was PAID for a
-- bill, when it was due, or what a supplier is owed in total.
--
-- This migration closes that, and makes five decisions worth stating:
--
--   * PAYMENTS NAME A BILL. app.purchase_payments.purchase_id is NOT NULL.
--     There is no supplier "on account" payment and no oldest-first
--     allocation. That machinery exists on the customer side (v_order_balances,
--     0021) only because a khata payment carries no order; a supplier is always
--     paid against an invoice, so `paid` is a plain sum and `balance` is
--     total_amount - paid. app.payments cannot host these rows at all --
--     its customer_id is NOT NULL (0004).
--
--   * A DRAFT IS A DOCUMENT; A RECEIVED PURCHASE IS FROZEN. Before receiving,
--     nothing has been posted to the ledger, so update_purchase replaces the
--     line set freely. After receiving, PURCHASE_IN rows stand, and the only
--     correction is cancel_purchase, which posts the opposite sign -- the same
--     rule the stock ledger and the customer ledger have always kept. There is
--     no edit-a-received-purchase RPC and no delete: app_api holds no DELETE on
--     any table in this schema.
--
--   * THE WHOLE SURFACE IS OWNER-ONLY. purchase_items.unit_cost_base is what
--     you pay your supplier and therefore your margin; 0017 already withheld it
--     from a packer for that reason. It is now withheld from a manager too, so
--     upsert_supplier, list_suppliers, create_purchase, receive_purchase,
--     list_purchases and get_purchase all tighten from OWNER+MANAGER to OWNER,
--     and archive_master refuses 'suppliers' to anyone but an owner.
--
--     THIS IS A BEHAVIOUR CHANGE TO SHIPPED RPCS. The mobile Stock screen's
--     "New stock arrived" mode for bulk calls create_purchase and shows a
--     supplier picker from list_suppliers; for a MANAGER both now refuse. The
--     app hides that mode from a manager at contract 6. There is no backend
--     server here, so "the same deploy" means THIS db push and THAT app build
--     are coupled -- do not push this without shipping the build.
--
--   * A DUE DATE IS TYPED, NOT DERIVED. Unlike orders (0022), a purchase's
--     due_on is entered by the owner from the supplier's bill, because the bill
--     states it. No suppliers.credit_days, no stamping trigger. 0022's calendar
--     helpers -- app.local_today(), app.due_state(), app.due_in_days() -- are
--     generic in (date, balance) and are reused here unchanged, so "overdue"
--     means the same thing on both sides of the business and is decided against
--     the Indian calendar date in exactly one place.
--
--   * OVERDUE IS NOT A PAYMENT STATE. The spec this implements asked for four
--     values -- Unpaid / Partially Paid / Paid / Overdue -- but overdue is a
--     DATE condition, not a payment level, and the most important row on the
--     screen is the half-paid bill that was due last week. Collapsing them
--     loses the half the owner acts on. So payment_state is UNPAID |
--     PARTIALLY_PAID | PAID and every read returns due_state / due_in_days
--     beside it. app.due_state already answers null at a balance <= 0, so a
--     paid bill can never read overdue: the precedence the spec wanted falls
--     out, with no second definition of "today".
--
-- Not done here, deliberately: no purchase <-> order link of any kind (they are
-- different flows and always will be); no supplier payables in
-- get_day_summary, which is require_member() and therefore packer-readable;
-- no BANK / CHEQUE / CARD method yet (the column is text + CHECK like
-- payments.method, so that is a one-line constraint swap when it is wanted).
--
-- app.purchase_payments is NOT added to app.synced_tables() /
-- pushable_tables() / append_only_tables(). The "Adding a table" checklist in
-- docs/supabase-access.md still lists those steps, but sync died with ADR 0003
-- and 0025 did not register app.order_price_changes either.

-- ---------------------------------------------------------------------------
-- Columns. purchases.status has permitted 'CANCELLED' since 0003 but there was
-- never anywhere to record when, or why.
-- ---------------------------------------------------------------------------

alter table app.purchases
  add column if not exists due_on        date,
  add column if not exists cancelled_at  timestamptz,
  add column if not exists cancel_reason text;

create index if not exists purchases_due_idx
  on app.purchases (business_id, due_on)
  where deleted_at is null and due_on is not null;

create index if not exists purchases_supplier_idx
  on app.purchases (business_id, supplier_id)
  where deleted_at is null and supplier_id is not null;

-- ---------------------------------------------------------------------------
-- What was paid. Append-only, like app.payments and app.stock_ledger: money
-- that left the shop is evidence, so it is never rewritten.
-- ---------------------------------------------------------------------------

create table if not exists app.purchase_payments (
  id           uuid primary key,          -- minted on the device
  business_id  uuid not null references app.businesses(id),
  purchase_id  uuid not null references app.purchases(id),
  -- Signed, exactly like app.payments.amount (0004). A payment entered by
  -- mistake, or money the supplier refunded, is corrected by a NEGATIVE row --
  -- never by editing history. It is also what lets cancel_purchase ask a clean
  -- question: a bill whose payments net to zero is a bill with no money
  -- against it, which is true both for "never paid" and "paid then refunded".
  amount       numeric(14,2) not null check (amount <> 0),
  -- Recorded, never verified. There is no payment gateway in this product and
  -- there will not be one: the owner says how they paid, and the app writes it
  -- down. PhonePe/GPay/any UPI app is 'UPI'.
  method       text not null default 'CASH' check (method in ('CASH', 'UPI')),
  paid_on      date not null default current_date,
  -- A UPI transaction id or a cheque number. Bookkeeping only; nothing in this
  -- system reads it, matches on it or checks it against anything.
  reference    text,
  note         text,
  created_by   uuid,
  created_at   timestamptz not null default now()
);

create index if not exists purchase_payments_purchase_idx
  on app.purchase_payments (purchase_id);
create index if not exists purchase_payments_business_idx
  on app.purchase_payments (business_id, paid_on desc);

alter table app.purchase_payments enable row level security;
alter table app.purchase_payments force row level security;

drop policy if exists tenant_select on app.purchase_payments;
drop policy if exists tenant_insert on app.purchase_payments;
create policy tenant_select on app.purchase_payments for select
  using (business_id = app.current_business_id());
create policy tenant_insert on app.purchase_payments for insert
  with check (business_id = app.current_business_id());
-- No tenant_update policy, no deleted_at, no touch_updated_at trigger.

drop trigger if exists purchase_payments_no_update on app.purchase_payments;
drop trigger if exists purchase_payments_no_delete on app.purchase_payments;
create trigger purchase_payments_no_update before update on app.purchase_payments
  for each row execute function app.forbid_mutation();
create trigger purchase_payments_no_delete before delete on app.purchase_payments
  for each row execute function app.forbid_mutation();

-- The default privileges in 0005 hand app_api UPDATE on every new table; this
-- one is insert-only, so take it back. The trigger refuses it regardless.
revoke all on app.purchase_payments from public, anon, authenticated, app_api;
grant select, insert on app.purchase_payments to app_api;

-- ---------------------------------------------------------------------------
-- Derived balances. Nothing here is stored: paid is a sum and balance is
-- arithmetic, so recording a payment moves every figure that depends on it
-- without a single UPDATE.
--
-- CANCELLED purchases are excluded. A cancelled bill is not owed and was not
-- billed; its reversing ledger rows have already taken the stock back out. The
-- reads special-case a cancelled row rather than letting this view's absence
-- read as "fully paid" -- see the note in list_purchases.
-- ---------------------------------------------------------------------------

create or replace view app.v_purchase_balances with (security_invoker = true) as
  select pu.business_id,
         pu.id          as purchase_id,
         pu.supplier_id,
         pu.purchased_on,
         pu.due_on,
         pu.total_amount,
         coalesce(pp.paid, 0)                   as paid,
         pu.total_amount - coalesce(pp.paid, 0) as balance
  from app.purchases pu
  left join lateral (
    select sum(amount) as paid
    from app.purchase_payments where purchase_id = pu.id
  ) pp on true
  where pu.deleted_at is null and pu.status <> 'CANCELLED';

comment on view app.v_purchase_balances is
  'Derived per-purchase paid/balance. Every payment names a bill, so this is a '
  'plain sum -- there is no account-credit allocation here, unlike '
  'v_order_balances. Excludes CANCELLED purchases.';

create or replace view app.v_supplier_balances with (security_invoker = true) as
  select s.business_id,
         s.id as supplier_id,
         coalesce(b.purchase_count, 0) as purchase_count,
         coalesce(b.total_billed, 0)   as total_billed,
         coalesce(b.total_paid, 0)     as total_paid,
         coalesce(b.total_billed, 0) - coalesce(b.total_paid, 0) as outstanding
  from app.suppliers s
  left join lateral (
    select count(*)          as purchase_count,
           sum(total_amount) as total_billed,
           sum(paid)         as total_paid
    from app.v_purchase_balances vb
    where vb.supplier_id = s.id and vb.business_id = s.business_id
  ) b on true
  where s.deleted_at is null;

comment on view app.v_supplier_balances is
  'What each supplier has billed, been paid and is still owed. Exact, because '
  'every payment names a bill.';

grant select on app.v_purchase_balances to app_api;
grant select on app.v_supplier_balances to app_api;
revoke all on app.v_purchase_balances from public, anon, authenticated;
revoke all on app.v_supplier_balances from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The payment-state rule, stated once. See the header on why OVERDUE is not
-- one of these values.
-- ---------------------------------------------------------------------------

create or replace function app.purchase_payment_state(p_total numeric, p_paid numeric)
returns text
language sql
immutable
set search_path = ''
as $fn$
  select case
    when coalesce(p_paid, 0) >= coalesce(p_total, 0) then 'PAID'
    when coalesce(p_paid, 0) >  0                    then 'PARTIALLY_PAID'
    else 'UNPAID'
  end
$fn$;

revoke all on function app.purchase_payment_state(numeric, numeric) from public, anon, authenticated;
grant execute on function app.purchase_payment_state(numeric, numeric) to app_api;

-- ---------------------------------------------------------------------------
-- The line-set writer, shared by create_purchase and update_purchase so the
-- two cannot drift in what they validate or how they total. Returns the total.
--
-- security invoker: it runs inside a definer RPC and inherits app_api, whose
-- RLS still applies -- the same posture as app.settle_customer_orders (0021).
-- ---------------------------------------------------------------------------

create or replace function app.replace_purchase_items(p_purchase_id uuid, p_items jsonb)
returns numeric
language plpgsql
security invoker
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_total    numeric := 0;
  v_item     jsonb;
  v_raw      uuid;
  v_qty      numeric;
  v_cost     numeric;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'a purchase needs at least one item' using errcode = '22023';
  end if;

  -- Soft, like every removal in this schema: app_api holds no DELETE, and
  -- receive_purchase already reads only the live lines.
  update app.purchase_items
     set deleted_at = now()
   where purchase_id = p_purchase_id
     and business_id = v_business
     and deleted_at is null;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_raw  := (v_item ->> 'raw_material_id')::uuid;
    v_qty  := (v_item ->> 'qty_base')::numeric;
    v_cost := coalesce((v_item ->> 'unit_cost_base')::numeric, 0);

    if v_qty is null or v_qty <= 0 then
      raise exception 'each item needs a qty_base greater than zero' using errcode = '22023';
    end if;
    if v_cost < 0 then
      raise exception 'unit cost cannot be negative' using errcode = '22023';
    end if;
    if not exists (
      select 1 from app.raw_materials
      where id = v_raw and business_id = v_business and deleted_at is null
    ) then
      raise exception 'raw material % not found', v_raw using errcode = 'P0002';
    end if;

    insert into app.purchase_items (
      business_id, purchase_id, raw_material_id, qty_base, unit_cost_base, line_total, created_by
    ) values (
      v_business, p_purchase_id, v_raw, v_qty, v_cost, v_qty * v_cost, app.current_user_id()
    );

    -- Summed unrounded and rounded once by the column, so a three-line bill
    -- does not drift a paise from the figure the screen previewed.
    v_total := v_total + (v_qty * v_cost);
  end loop;

  return v_total;
end
$fn$;

revoke all on function app.replace_purchase_items(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.replace_purchase_items(uuid, jsonb) to app_api;

-- ---------------------------------------------------------------------------
-- The role tightening. Bodies unchanged except the guard, and the signatures
-- are identical, so `create or replace` keeps the owner and the grants.
-- ---------------------------------------------------------------------------

create or replace function public.upsert_supplier(
  p_id      uuid,
  p_name    text,
  p_phone   text default null,
  p_address text default null,
  p_notes   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_created  boolean;
begin
  -- OWNER only since 0026: a supplier is the other end of a cost.
  perform app.require_role('OWNER');
  perform app.require_write_access();

  if p_name is null or btrim(p_name) = '' then
    raise exception 'supplier name is required' using errcode = '22023';
  end if;

  select not exists (select 1 from app.suppliers where id = p_id) into v_created;

  insert into app.suppliers (id, business_id, name, phone, address, notes, created_by)
  values (p_id, v_business, btrim(p_name), p_phone, p_address, p_notes, app.current_user_id())
  on conflict (id) do update
    set name = excluded.name,
        phone = excluded.phone,
        address = excluded.address,
        notes = excluded.notes;

  return jsonb_build_object('supplier_id', p_id, 'created', v_created);
exception
  when unique_violation then
    raise exception 'id % is already in use', p_id using errcode = '23505';
end
$fn$;

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
  perform app.require_role('OWNER');
  perform app.require_write_access();

  select * into v_purchase from app.purchases
  where id = p_purchase_id and business_id = v_business and deleted_at is null;

  -- FOUND, not `v_purchase is null`: the 0007 body happened to be safe, but
  -- the rowtype trap is one edit away in either direction (see 0016).
  if not found then
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

  return jsonb_build_object('purchase_id', p_purchase_id, 'purchase_no', v_no,
                            'already_received', false);
end
$fn$;

-- archive_master stays OWNER+MANAGER: it also archives customers, raw
-- materials and SKUs, and none of those changed hands. Only the supplier arm
-- tightens -- otherwise a manager could archive a supplier they can no longer
-- see in list_suppliers.
create or replace function public.archive_master(p_table text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_count    integer;
begin
  perform app.require_role('OWNER', 'MANAGER');
  perform app.require_write_access();

  if p_table not in ('customers', 'suppliers', 'raw_materials', 'packed_skus') then
    raise exception 'archive_master does not handle %', p_table using errcode = '22023';
  end if;

  if p_table = 'suppliers' then
    perform app.require_role('OWNER');
  end if;

  execute format(
    'update app.%I set deleted_at = now()
      where id = $1 and business_id = $2 and deleted_at is null', p_table)
  using p_id, v_business;

  get diagnostics v_count = row_count;

  return jsonb_build_object('table', p_table, 'id', p_id, 'archived', v_count > 0);
end
$fn$;

-- ---------------------------------------------------------------------------
-- create_purchase: the 0011 body plus p_due_on, the shared item writer, and
-- the OWNER guard.
--
-- DROP, then create -- not an overload. PostgREST resolves overloaded
-- functions by the key names in the request body, so two create_purchase
-- signatures would be a runtime ambiguity error (0012 and 0017 both hit this).
-- A call without p_due_on still matches through the default, which is the only
-- reason a parameter can be added to a live function at all.
--
-- THE DROP TAKES THE OWNER AND THE GRANTS WITH IT. They are re-issued at the
-- end of this section against the NEW eight-argument signature; aim them at
-- the old seven-argument one and every caller gets
-- `permission denied for function create_purchase`.
-- ---------------------------------------------------------------------------

drop function if exists public.create_purchase(uuid, uuid, jsonb, text, date, text, boolean);

create function public.create_purchase(
  p_purchase_id  uuid,
  p_supplier_id  uuid,
  p_items        jsonb,
  p_invoice_no   text    default null,
  p_purchased_on date    default null,
  p_notes        text    default null,
  p_receive      boolean default true,
  p_due_on       date    default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_total    numeric;
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();

  -- Idempotent retry: the purchase already exists, so report it rather than
  -- creating a second one or double-posting its stock.
  if exists (select 1 from app.purchases where id = p_purchase_id and business_id = v_business) then
    return jsonb_build_object('purchase_id', p_purchase_id, 'created', false);
  end if;

  if p_supplier_id is not null and not exists (
    select 1 from app.suppliers
    where id = p_supplier_id and business_id = v_business and deleted_at is null
  ) then
    raise exception 'supplier % not found', p_supplier_id using errcode = 'P0002';
  end if;

  insert into app.purchases (
    id, business_id, supplier_id, invoice_no, purchased_on, due_on, notes, status, created_by
  ) values (
    p_purchase_id, v_business, p_supplier_id, p_invoice_no,
    coalesce(p_purchased_on, current_date), p_due_on, p_notes, 'DRAFT', app.current_user_id()
  );

  v_total := app.replace_purchase_items(p_purchase_id, p_items);

  -- Server-derived, never taken from the client.
  update app.purchases set total_amount = v_total where id = p_purchase_id;

  if p_receive then
    perform public.receive_purchase(p_purchase_id);
  end if;

  return jsonb_build_object(
    'purchase_id',  p_purchase_id,
    'created',      true,
    'total_amount', v_total,
    'due_on',       p_due_on,
    'received',     p_receive
  );
end
$fn$;

-- ---------------------------------------------------------------------------
-- update_purchase: correcting a bill that has not arrived yet.
--
-- DRAFT only. A RECEIVED purchase has PURCHASE_IN rows standing in the ledger;
-- editing its quantities would mean a partial reversal with its own
-- negative-stock check and its own audit row, for a case the owner can already
-- express as cancel + re-enter. Naturally idempotent -- the same payload twice
-- is the same end state.
-- ---------------------------------------------------------------------------

create or replace function public.update_purchase(
  p_purchase_id  uuid,
  p_supplier_id  uuid,
  p_items        jsonb,
  p_invoice_no   text default null,
  p_purchased_on date default null,
  p_notes        text default null,
  p_due_on       date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_status   text;
  v_total    numeric;
  v_paid     numeric;
  v_count    integer;
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();

  select status into v_status from app.purchases
  where id = p_purchase_id and business_id = v_business and deleted_at is null
  for update;
  if not found then
    raise exception 'purchase % not found', p_purchase_id using errcode = 'P0002';
  end if;

  if v_status <> 'DRAFT' then
    raise exception 'a % purchase cannot be edited; cancel it instead', v_status
      using errcode = '22023', hint = 'purchase_locked';
  end if;

  if p_supplier_id is not null and not exists (
    select 1 from app.suppliers
    where id = p_supplier_id and business_id = v_business and deleted_at is null
  ) then
    raise exception 'supplier % not found', p_supplier_id using errcode = 'P0002';
  end if;

  v_total := app.replace_purchase_items(p_purchase_id, p_items);

  -- An advance can legitimately sit on a draft bill. Cutting the bill below it
  -- would derive a negative balance -- the one way editing a draft can produce
  -- an inconsistent total.
  select coalesce(sum(amount), 0) into v_paid
  from app.purchase_payments where purchase_id = p_purchase_id;

  if v_total < v_paid then
    raise exception 'that bill comes to %, but % has already been paid against it',
      v_total, v_paid using errcode = '23514', hint = 'below_paid';
  end if;

  update app.purchases
     set supplier_id  = p_supplier_id,
         invoice_no   = p_invoice_no,
         purchased_on = coalesce(p_purchased_on, purchased_on),
         due_on       = p_due_on,
         notes        = p_notes,
         total_amount = v_total
   where id = p_purchase_id;

  select count(*) into v_count from app.purchase_items
  where purchase_id = p_purchase_id and deleted_at is null;

  return jsonb_build_object(
    'purchase_id',   p_purchase_id,
    'total_amount',  v_total,
    'item_count',    v_count,
    'due_on',        p_due_on,
    'paid',          v_paid,
    'balance',       v_total - v_paid,
    'payment_state', app.purchase_payment_state(v_total, v_paid)
  );
end
$fn$;

-- ---------------------------------------------------------------------------
-- record_purchase_payment.
--
-- Bookkeeping, and nothing else. No money moves through this app, nothing is
-- verified and no gateway is involved -- the owner is telling us what they
-- did. Partial and repeated payments are the norm in this trade, not the
-- exception, so this is one row per payment rather than a figure on the bill.
-- ---------------------------------------------------------------------------

create or replace function public.record_purchase_payment(
  p_payment_id  uuid,
  p_purchase_id uuid,
  p_amount      numeric,
  p_method      text default 'CASH',
  p_paid_on     date default null,
  p_reference   text default null,
  p_note        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_method   text := coalesce(upper(btrim(p_method)), 'CASH');
  v_existing app.purchase_payments;
  v_purchase app.purchases;
  v_paid     numeric;
  v_balance  numeric;
  v_sup_out  numeric;
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();

  -- Idempotency first, before anything is validated or written: a phone that
  -- lost signal mid-call is retrying, and cash counted twice is exactly what
  -- the caller-minted-uuid convention exists to prevent.
  --
  -- FOUND, not `v_existing is not null`: for a rowtype variable the latter is
  -- true only when EVERY column is non-null, and reference/note/created_by are
  -- routinely null here. That trap already shipped one bug (fixed in 0016).
  select * into v_existing from app.purchase_payments where id = p_payment_id;
  if found then
    if v_existing.business_id <> v_business then
      -- Do not confirm that an id exists in someone else's tenant.
      raise exception 'payment % not found', p_payment_id using errcode = 'P0002';
    end if;
    select coalesce(sum(amount), 0) into v_paid
    from app.purchase_payments where purchase_id = v_existing.purchase_id;
    select * into v_purchase from app.purchases where id = v_existing.purchase_id;
    return jsonb_build_object(
      'payment_id',    p_payment_id,
      'purchase_id',   v_existing.purchase_id,
      'created',       false,
      'amount',        v_existing.amount,
      'method',        v_existing.method,
      'paid',          v_paid,
      'balance',       v_purchase.total_amount - v_paid,
      'payment_state', app.purchase_payment_state(v_purchase.total_amount, v_paid)
    );
  end if;

  if p_amount is null or p_amount = 0 then
    raise exception 'payment amount must be non-zero' using errcode = '22023';
  end if;
  -- Validated here rather than left to the CHECK, so the client sees 22023
  -- (a bad argument) and not 23514 (an invariant it cannot interpret).
  if v_method not in ('CASH', 'UPI') then
    raise exception 'payment method must be CASH or UPI, got %', p_method using errcode = '22023';
  end if;

  select * into v_purchase from app.purchases
  where id = p_purchase_id and business_id = v_business and deleted_at is null
  for update;
  if not found then
    raise exception 'purchase % not found', p_purchase_id using errcode = 'P0002';
  end if;
  if v_purchase.status = 'CANCELLED' then
    raise exception 'purchase % is cancelled', p_purchase_id
      using errcode = '22023', hint = 'purchase_cancelled';
  end if;

  select coalesce(sum(amount), 0) into v_paid
  from app.purchase_payments where purchase_id = p_purchase_id;

  -- A reversal cannot take back more than was ever paid.
  if v_paid + p_amount < 0 then
    raise exception 'only % has been paid against this bill; % cannot be reversed',
      v_paid, abs(p_amount) using errcode = '23514';
  end if;

  insert into app.purchase_payments
    (id, business_id, purchase_id, amount, method, paid_on, reference, note, created_by)
  values
    (p_payment_id, v_business, p_purchase_id, p_amount, v_method,
     coalesce(p_paid_on, current_date), nullif(btrim(coalesce(p_reference, '')), ''),
     p_note, app.current_user_id());

  v_paid    := v_paid + p_amount;
  v_balance := v_purchase.total_amount - v_paid;

  -- Overpayment is allowed and the balance is left unclamped. A wholesaler who
  -- pays 25,000 against a 24,200 bill and carries the rest is describing what
  -- happened; refusing it would force a false entry somewhere else.
  select outstanding into v_sup_out
  from app.v_supplier_balances
  where supplier_id = v_purchase.supplier_id and business_id = v_business;

  return jsonb_build_object(
    'payment_id',           p_payment_id,
    'purchase_id',          p_purchase_id,
    'created',              true,
    'amount',               p_amount,
    'method',               v_method,
    'paid',                 v_paid,
    'balance',              v_balance,
    'payment_state',        app.purchase_payment_state(v_purchase.total_amount, v_paid),
    'due_state',            app.due_state(v_purchase.due_on, v_balance),
    'due_in_days',          app.due_in_days(v_purchase.due_on, v_balance),
    'supplier_outstanding', v_sup_out
  );
end
$fn$;

-- ---------------------------------------------------------------------------
-- cancel_purchase: the reversal RPC.
--
-- Stock is SUM(qty_base) over an append-only ledger, so "undo" is not an
-- option and never was: the only way to take 50 kg back out is to write -50 kg
-- in. PURCHASE_IN with a negative quantity, not ADJUSTMENT -- the signed column
-- IS the correction model, and keeping ref_type/ref_id on the purchase groups
-- the posting and its reversal in list_stock_ledger. An ADJUSTMENT would read
-- as a stock-take in the audit trail and would lose the link.
--
-- Refuses while money stands against the bill. Auto-inserting a compensating
-- negative payment would record a refund that may never have happened; leaving
-- the payments in place would hide them, since v_purchase_balances excludes
-- cancelled bills and those rupees would vanish from the supplier's totals
-- while still sitting in the table. So the owner reverses the payment first,
-- deliberately, and there is one append-only trail of what was agreed.
-- ---------------------------------------------------------------------------

create or replace function public.cancel_purchase(
  p_purchase_id uuid,
  p_reason      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_purchase app.purchases;
  v_paid     numeric;
  v_short    record;
  v_reversed integer := 0;
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();

  select * into v_purchase from app.purchases
  where id = p_purchase_id and business_id = v_business and deleted_at is null
  for update;
  if not found then
    raise exception 'purchase % not found', p_purchase_id using errcode = 'P0002';
  end if;

  -- Idempotent, and this is also what prevents a double reversal: a retry
  -- after a timeout must not take the stock out twice.
  if v_purchase.status = 'CANCELLED' then
    return jsonb_build_object('purchase_id', p_purchase_id,
                              'cancelled', false, 'already_cancelled', true,
                              'reversed_items', 0, 'status', 'CANCELLED');
  end if;

  select coalesce(sum(amount), 0) into v_paid
  from app.purchase_payments where purchase_id = p_purchase_id;

  -- Nets to zero, not "no rows": a bill that was paid and then refunded has
  -- history against it but no money, and can still be cancelled.
  if v_paid <> 0 then
    raise exception '% has been paid against this bill; reverse it before cancelling', v_paid
      using errcode = '23514', hint = 'payments_exist';
  end if;

  if v_purchase.status = 'RECEIVED' then
    -- One pre-check over every line BEFORE any insert, so a multi-line bill
    -- never half-reverses. Same posture and same SQLSTATE as dispatch_order.
    select m.name as name, oh.on_hand as on_hand, pi.qty_base as brought_in
      into v_short
    from app.purchase_items pi
    join app.raw_materials m on m.id = pi.raw_material_id
    cross join lateral (
      select coalesce(sum(sl.qty_base), 0) as on_hand
      from app.stock_ledger sl
      where sl.business_id = v_business and sl.raw_material_id = pi.raw_material_id
    ) oh
    where pi.purchase_id = p_purchase_id
      and pi.business_id = v_business
      and pi.deleted_at is null
      and oh.on_hand - pi.qty_base < 0
    limit 1;

    if found then
      raise exception
        'cancelling would leave % at %; this bill brought in % and only % is on hand',
        v_short.name, v_short.on_hand - v_short.brought_in,
        v_short.brought_in, v_short.on_hand
        using errcode = '23514';
    end if;

    insert into app.stock_ledger (
      business_id, entry_type, item_kind, raw_material_id, qty_base,
      ref_type, ref_id, note, created_by
    )
    select v_business, 'PURCHASE_IN', 'RAW', pi.raw_material_id, -pi.qty_base,
           'PURCHASE', p_purchase_id, 'purchase cancelled', app.current_user_id()
    from app.purchase_items pi
    where pi.purchase_id = p_purchase_id
      and pi.business_id = v_business
      and pi.deleted_at is null;

    get diagnostics v_reversed = row_count;
  end if;

  update app.purchases
     set status        = 'CANCELLED',
         cancelled_at  = now(),
         cancel_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = p_purchase_id;

  return jsonb_build_object(
    'purchase_id',       p_purchase_id,
    'cancelled',         true,
    'already_cancelled', false,
    'reversed_items',    v_reversed,
    'status',            'CANCELLED'
  );
end
$fn$;

-- ---------------------------------------------------------------------------
-- set_purchase_due_date. null clears. Allowed on a draft as well as a received
-- bill -- the terms are printed on the paper either way.
-- ---------------------------------------------------------------------------

create or replace function public.set_purchase_due_date(p_purchase_id uuid, p_due_on date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_status   text;
  v_total    numeric;
  v_paid     numeric;
  v_balance  numeric;
begin
  perform app.require_role('OWNER');
  perform app.require_write_access();

  select status, total_amount into v_status, v_total from app.purchases
  where id = p_purchase_id and business_id = v_business and deleted_at is null;
  if not found then
    raise exception 'purchase % not found', p_purchase_id using errcode = 'P0002';
  end if;

  if v_status = 'CANCELLED' then
    raise exception 'a cancelled purchase has no due date to set'
      using errcode = '22023', hint = 'not_due';
  end if;

  update app.purchases set due_on = p_due_on where id = p_purchase_id;

  select coalesce(sum(amount), 0) into v_paid
  from app.purchase_payments where purchase_id = p_purchase_id;
  v_balance := v_total - v_paid;

  return jsonb_build_object(
    'purchase_id', p_purchase_id,
    'due_on',      p_due_on,
    'balance',     v_balance,
    'due_state',   app.due_state(p_due_on, v_balance),
    'due_in_days', app.due_in_days(p_due_on, v_balance)
  );
end
$fn$;

-- The grants for everything created new above. create_purchase is in this list
-- because its DROP took its owner and grants with it; the other four are new
-- functions and have never had any.
do $$
declare f text;
begin
  foreach f in array array[
    'public.create_purchase(uuid, uuid, jsonb, text, date, text, boolean, date)',
    'public.update_purchase(uuid, uuid, jsonb, text, date, text, date)',
    'public.record_purchase_payment(uuid, uuid, numeric, text, date, text, text)',
    'public.cancel_purchase(uuid, text)',
    'public.set_purchase_due_date(uuid, date)'
  ] loop
    execute format('alter function %s owner to app_api', f);
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- Reads. All stable, all guarded, all tenant-scoped -- the three lints in
-- supabase/tests/security_and_sync.sql check for exactly those strings in the
-- body of every public list_* / get_* function.
-- ---------------------------------------------------------------------------

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
  -- OWNER only since 0026. A supplier row now carries what is owed to them.
  perform app.require_role('OWNER');
  v_q      := nullif(btrim(coalesce(p_search, '')), '');
  p_limit  := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb) into v_rows
  from (
    -- Column list, never to_jsonb(view_row): v_supplier_balances leads with
    -- business_id, and spreading a view row is how 0020's leak happened.
    select s.id, s.name, s.phone, s.address, s.notes,
           coalesce(vb.purchase_count, 0) as purchase_count,
           coalesce(vb.total_billed, 0)   as total_billed,
           coalesce(vb.total_paid, 0)     as total_paid,
           coalesce(vb.outstanding, 0)    as outstanding
    from app.suppliers s
    left join app.v_supplier_balances vb
      on vb.supplier_id = s.id and vb.business_id = s.business_id
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

-- The signature is deliberately unchanged: no p_payment_state / p_due_state
-- filter. Adding one would mean DROP-then-create for a filter the screen can
-- apply itself over a page of at most 200 rows. A 0027 candidate if a shop
-- ever has enough bills for it to matter.
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
  perform app.require_role('OWNER');
  p_limit  := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.purchased_on desc), '[]'::jsonb)
    into v_rows
  from (
    select pu.id, pu.purchase_no, pu.supplier_id, s.name as supplier_name,
           pu.invoice_no, pu.purchased_on, pu.total_amount, pu.notes,
           pu.status, pu.received_at, pu.due_on, pu.cancelled_at,
           -- v_purchase_balances excludes CANCELLED, so a cancelled bill joins
           -- to nothing. Left as coalesce(..., 0) it would read "PAID, nothing
           -- due" for a bill that was never paid at all, so say nothing
           -- instead: a cancelled bill is neither owed nor settled.
           case when pu.status = 'CANCELLED' then 0 else coalesce(vb.paid, 0) end as paid,
           case when pu.status = 'CANCELLED' then 0
                else coalesce(vb.balance, pu.total_amount) end as balance,
           case when pu.status = 'CANCELLED' then null
                else app.purchase_payment_state(pu.total_amount, coalesce(vb.paid, 0))
           end as payment_state,
           app.due_state(pu.due_on, coalesce(vb.balance, 0))   as due_state,
           app.due_in_days(pu.due_on, coalesce(vb.balance, 0)) as due_in_days,
           (select count(*) from app.purchase_items pi
             where pi.purchase_id = pu.id and pi.deleted_at is null) as item_count
    from app.purchases pu
    left join app.suppliers s on s.id = pu.supplier_id
    left join app.v_purchase_balances vb
      on vb.purchase_id = pu.id and vb.business_id = pu.business_id
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

-- get_purchase. Every key the 0017 shape returned is still returned; this is
-- additive, which is why min_client stays at 1.
create or replace function public.get_purchase(p_purchase_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_status   text;
  v_total    numeric;
  v_paid     numeric;
  v_balance  numeric;
  v_actions  text[] := '{}';
  v_out      jsonb;
begin
  perform app.require_role('OWNER');

  select status, total_amount into v_status, v_total
  from app.purchases
  where id = p_purchase_id and business_id = v_business and deleted_at is null;
  if not found then
    raise exception 'purchase % not found', p_purchase_id using errcode = 'P0002';
  end if;

  select coalesce(sum(amount), 0) into v_paid
  from app.purchase_payments where purchase_id = p_purchase_id;

  -- A cancelled bill is neither owed nor settled; see the note in
  -- list_purchases on why this is not just coalesce(balance, 0).
  v_balance := case when v_status = 'CANCELLED' then 0 else v_total - v_paid end;

  -- The legal next actions, resolved here so no screen re-derives them -- the
  -- same contract get_order.allowed_transitions keeps.
  if v_status = 'DRAFT' then
    v_actions := v_actions || array['edit', 'receive'];
  end if;
  if v_status <> 'CANCELLED' then
    if v_balance > 0 then
      v_actions := v_actions || array['record_payment'];
    end if;
    v_actions := v_actions || array['set_due_date'];
    -- Withheld while money stands against the bill: cancel_purchase refuses it
    -- (hint payments_exist), and offering an action that will be refused is
    -- worse than not offering it. Nets to zero, so a paid-then-refunded bill
    -- can still be cancelled.
    if v_paid = 0 then
      v_actions := v_actions || array['cancel'];
    end if;
  end if;

  select jsonb_build_object(
    'purchase', jsonb_build_object(
      'id', pu.id, 'purchase_no', pu.purchase_no, 'invoice_no', pu.invoice_no,
      'purchased_on', pu.purchased_on, 'total_amount', pu.total_amount,
      'notes', pu.notes, 'status', pu.status, 'received_at', pu.received_at,
      'due_on', pu.due_on, 'cancelled_at', pu.cancelled_at,
      'cancel_reason', pu.cancel_reason
    ),
    'supplier', case when s.id is null then 'null'::jsonb else jsonb_build_object(
      'id', s.id, 'name', s.name, 'phone', s.phone,
      'address', s.address, 'notes', s.notes
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
    ),
    -- Newest first, the way the owner reads a payment history.
    'payments', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', pp.id, 'amount', pp.amount, 'method', pp.method,
               'paid_on', pp.paid_on, 'reference', pp.reference, 'note', pp.note,
               'recorded_by_name', pr.full_name
             ) order by pp.paid_on desc, pp.created_at desc), '[]'::jsonb)
      from app.purchase_payments pp
      left join app.profiles pr on pr.id = pp.created_by
      where pp.purchase_id = pu.id and pp.business_id = v_business
    ),
    'paid',          case when pu.status = 'CANCELLED' then 0 else v_paid end,
    'balance',       v_balance,
    'payment_state', case when pu.status = 'CANCELLED' then null
                          else app.purchase_payment_state(pu.total_amount, v_paid) end,
    'due_state',     app.due_state(pu.due_on, v_balance),
    'due_in_days',   app.due_in_days(pu.due_on, v_balance),
    'supplier_outstanding', (
      select vb.outstanding from app.v_supplier_balances vb
      where vb.supplier_id = pu.supplier_id and vb.business_id = v_business
    ),
    'allowed_actions', to_jsonb(v_actions)
  )
  into v_out
  from app.purchases pu
  left join app.suppliers s on s.id = pu.supplier_id
  where pu.id = p_purchase_id and pu.business_id = v_business and pu.deleted_at is null;

  return v_out;
end
$fn$;

-- get_supplier: who they are, what the relationship comes to, and the bills.
-- The purchases page uses app.page() so it matches get_customer_ledger's
-- orders envelope and the client can reuse its "Load more".
create or replace function public.get_supplier(
  p_supplier_id uuid,
  p_limit       integer default 20,
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
  v_supplier jsonb;
  v_totals   jsonb;
  v_rows     jsonb;
begin
  perform app.require_role('OWNER');
  p_limit  := least(greatest(coalesce(p_limit, 20), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  select jsonb_build_object(
           'id', s.id, 'name', s.name, 'phone', s.phone,
           'address', s.address, 'notes', s.notes)
    into v_supplier
  from app.suppliers s
  where s.id = p_supplier_id and s.business_id = v_business and s.deleted_at is null;

  -- P0002 for an id in another tenant too, not a distinguishable error: an id
  -- that answers differently is an id someone can probe for.
  if v_supplier is null then
    raise exception 'supplier % not found', p_supplier_id using errcode = 'P0002';
  end if;

  select jsonb_build_object(
           'purchase_count', coalesce(vb.purchase_count, 0),
           'total_billed',   coalesce(vb.total_billed, 0),
           'total_paid',     coalesce(vb.total_paid, 0),
           'outstanding',    coalesce(vb.outstanding, 0),
           'overdue_count',  coalesce(od.n, 0),
           'overdue_amount', coalesce(od.amount, 0))
    into v_totals
  from app.v_supplier_balances vb
  cross join lateral (
    select count(*) as n, sum(pb.balance) as amount
    from app.v_purchase_balances pb
    where pb.supplier_id = p_supplier_id
      and pb.business_id = v_business
      and app.due_state(pb.due_on, pb.balance) = 'OVERDUE'
  ) od
  where vb.supplier_id = p_supplier_id and vb.business_id = v_business;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.purchased_on desc), '[]'::jsonb)
    into v_rows
  from (
    select pu.id, pu.purchase_no, pu.supplier_id, s.name as supplier_name,
           pu.invoice_no, pu.purchased_on, pu.total_amount, pu.notes,
           pu.status, pu.received_at, pu.due_on, pu.cancelled_at,
           case when pu.status = 'CANCELLED' then 0 else coalesce(vb.paid, 0) end as paid,
           case when pu.status = 'CANCELLED' then 0
                else coalesce(vb.balance, pu.total_amount) end as balance,
           case when pu.status = 'CANCELLED' then null
                else app.purchase_payment_state(pu.total_amount, coalesce(vb.paid, 0))
           end as payment_state,
           app.due_state(pu.due_on, coalesce(vb.balance, 0))   as due_state,
           app.due_in_days(pu.due_on, coalesce(vb.balance, 0)) as due_in_days,
           (select count(*) from app.purchase_items pi
             where pi.purchase_id = pu.id and pi.deleted_at is null) as item_count
    from app.purchases pu
    join app.suppliers s on s.id = pu.supplier_id
    left join app.v_purchase_balances vb
      on vb.purchase_id = pu.id and vb.business_id = pu.business_id
    where pu.business_id = v_business
      and pu.supplier_id = p_supplier_id
      and pu.deleted_at is null
    order by pu.purchased_on desc, pu.created_at desc
    limit p_limit + 1 offset p_offset
  ) x;

  return jsonb_build_object(
    'supplier',  v_supplier,
    'totals',    v_totals,
    'purchases', app.page(v_rows, p_limit, p_offset)
  );
end
$fn$;

alter function public.get_supplier(uuid, integer, integer) owner to app_api;
revoke all on function public.get_supplier(uuid, integer, integer) from public, anon;
grant execute on function public.get_supplier(uuid, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- The contract. Additive throughout -- an old build reading list_purchases
-- simply ignores paid/balance/payment_state and keeps working -- so min_client
-- stays at 1. Bumping it would strand every phone that has not updated.
-- ---------------------------------------------------------------------------

create or replace function app.schema_contract()
returns jsonb
language sql
immutable
set search_path = ''
as $fn$
  select jsonb_build_object(
    'current',    6,
    'min_client', 1
  )
$fn$;
