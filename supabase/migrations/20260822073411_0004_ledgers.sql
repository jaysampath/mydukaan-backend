-- 0004_ledgers
-- The two append-only ledgers. These are the correctness core of the app.
--
-- Stock is NOT a mutable quantity column anywhere. Current quantity is always
-- SUM(qty_base) over the ledger. Two devices that both add stock offline
-- produce two INSERTs, which merge without conflict. A mutable qty column
-- would produce a lost update instead.
--
-- Same for money: customer outstanding is SUM(order totals) - SUM(payments)
-- across ALL orders (running khata), never a stored balance.

create table app.stock_ledger (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references app.businesses(id),
  entry_type       text not null check (entry_type in (
                     'OPENING',      -- initial count when onboarding
                     'PURCHASE_IN',  -- bulk stock received from supplier
                     'PACK_OUT',     -- raw consumed by a packing run (negative)
                     'PACK_IN',      -- packets produced by a packing run (positive)
                     'SALE_OUT',     -- deducted ON DISPATCH (negative)
                     'RETURN_IN',    -- customer return (positive)
                     'ADJUSTMENT'    -- stock-take correction, either sign
                   )),
  item_kind        text not null check (item_kind in ('RAW','PACKED')),
  raw_material_id  uuid references app.raw_materials(id),
  packed_sku_id    uuid references app.packed_skus(id),
  -- Signed. Grams for RAW, packets for PACKED. Negative = stock leaving.
  qty_base         numeric(16,3) not null check (qty_base <> 0),
  -- What caused this row, for audit and for reversing a whole document.
  ref_type         text check (ref_type in ('PURCHASE','PACKING_RUN','ORDER','MANUAL')),
  ref_id           uuid,
  note             text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  -- Exactly one item reference, matching item_kind.
  constraint stock_ledger_item_ck check (
    (item_kind = 'RAW'    and raw_material_id is not null and packed_sku_id is null) or
    (item_kind = 'PACKED' and packed_sku_id  is not null and raw_material_id is null)
  )
);
create index stock_ledger_business_idx on app.stock_ledger (business_id, created_at desc);
create index stock_ledger_raw_idx on app.stock_ledger (business_id, raw_material_id)
  where raw_material_id is not null;
create index stock_ledger_packed_idx on app.stock_ledger (business_id, packed_sku_id)
  where packed_sku_id is not null;
create index stock_ledger_ref_idx on app.stock_ledger (ref_type, ref_id) where ref_id is not null;

create table app.payments (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references app.businesses(id),
  customer_id  uuid not null references app.customers(id),
  -- Nullable: cash can be paid against the running khata rather than one order.
  order_id     uuid references app.orders(id),
  -- Signed. Negative rows are reversals/refunds -- history is never edited.
  amount       numeric(14,2) not null check (amount <> 0),
  method       text not null default 'CASH' check (method in ('CASH')),
  paid_on      date not null default current_date,
  note         text,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index payments_business_idx on app.payments (business_id, created_at desc);
create index payments_customer_idx on app.payments (business_id, customer_id);
create index payments_order_idx on app.payments (order_id) where order_id is not null;

-- Append-only enforcement at the table level, so no future code path -- RPC,
-- sync push, or a hand-run query -- can quietly rewrite history.
create trigger stock_ledger_no_update before update on app.stock_ledger
  for each row execute function app.forbid_mutation();
create trigger stock_ledger_no_delete before delete on app.stock_ledger
  for each row execute function app.forbid_mutation();
create trigger payments_no_update before update on app.payments
  for each row execute function app.forbid_mutation();
create trigger payments_no_delete before delete on app.payments
  for each row execute function app.forbid_mutation();

-- ---------------------------------------------------------------------------
-- Derived balances. security_invoker so the caller's RLS applies rather than
-- the view owner's -- otherwise a view would be a hole straight through
-- tenant isolation.
-- ---------------------------------------------------------------------------

create view app.v_raw_stock with (security_invoker = true) as
  select rm.business_id,
         rm.id as raw_material_id,
         rm.name,
         rm.base_unit,
         coalesce(sum(sl.qty_base), 0) as qty_base
  from app.raw_materials rm
  left join app.stock_ledger sl on sl.raw_material_id = rm.id
  where rm.deleted_at is null
  group by rm.business_id, rm.id, rm.name, rm.base_unit;

create view app.v_packed_stock with (security_invoker = true) as
  select ps.business_id,
         ps.id as packed_sku_id,
         ps.name,
         ps.pack_size_base,
         coalesce(sum(sl.qty_base), 0) as qty_packets
  from app.packed_skus ps
  left join app.stock_ledger sl on sl.packed_sku_id = ps.id
  where ps.deleted_at is null
  group by ps.business_id, ps.id, ps.name, ps.pack_size_base;

-- Running khata: billed across every non-cancelled order, less every payment.
create view app.v_customer_balances with (security_invoker = true) as
  select c.business_id,
         c.id as customer_id,
         c.name,
         coalesce(o.billed, 0)  as total_billed,
         coalesce(p.paid, 0)    as total_paid,
         coalesce(o.billed, 0) - coalesce(p.paid, 0) as outstanding
  from app.customers c
  left join lateral (
    select sum(total_amount) as billed
    from app.orders
    where customer_id = c.id and deleted_at is null and status <> 'CANCELLED'
  ) o on true
  left join lateral (
    select sum(amount) as paid
    from app.payments
    where customer_id = c.id
  ) p on true
  where c.deleted_at is null;

comment on table app.stock_ledger is
  'Append-only. Current stock = SUM(qty_base). Never mutate; insert a reversing row.';
comment on table app.payments is
  'Append-only. Customer outstanding = SUM(order totals) - SUM(amount). Never mutate.';
