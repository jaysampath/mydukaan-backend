-- 0003_operations
-- Procurement, packing (conversion), and the order lifecycle.
--
-- Order lifecycle:
--   PLACED -> PACKED -> OUT_FOR_DELIVERY -> DELIVERED -> PAYMENT_PENDING -> CLOSED
-- Stock is deducted at OUT_FOR_DELIVERY (DISPATCH), not at PLACED. The
-- SALE_OUT ledger rows are written by app.dispatch_order() in 0007.

create table app.purchases (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references app.businesses(id),
  supplier_id   uuid references app.suppliers(id),
  purchase_no   bigint,
  invoice_no    text,
  purchased_on  date not null default current_date,
  total_amount  numeric(14,2) not null default 0 check (total_amount >= 0),
  notes         text,
  -- Once RECEIVED, PURCHASE_IN rows exist in the ledger.
  status        text not null default 'DRAFT'
                  check (status in ('DRAFT','RECEIVED','CANCELLED')),
  received_at   timestamptz,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz
);
create index purchases_business_idx on app.purchases (business_id) where deleted_at is null;
create unique index purchases_no_uq on app.purchases (business_id, purchase_no)
  where purchase_no is not null;

create table app.purchase_items (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references app.businesses(id),
  purchase_id      uuid not null references app.purchases(id),
  raw_material_id  uuid not null references app.raw_materials(id),
  qty_base         numeric(16,3) not null check (qty_base > 0),
  unit_cost_base   numeric(16,6) not null default 0 check (unit_cost_base >= 0),
  line_total       numeric(14,2) not null default 0 check (line_total >= 0),
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz
);
create index purchase_items_purchase_idx on app.purchase_items (purchase_id);
create index purchase_items_business_idx on app.purchase_items (business_id) where deleted_at is null;

-- Conversion: consume raw bulk, produce retail packets.
-- raw_consumed_base should equal packets_produced * pack_size_base + wastage,
-- but real packing has spillage, so wastage_base is explicit rather than implied.
create table app.packing_runs (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references app.businesses(id),
  raw_material_id    uuid not null references app.raw_materials(id),
  packed_sku_id      uuid not null references app.packed_skus(id),
  packets_produced   numeric(16,3) not null check (packets_produced > 0),
  raw_consumed_base  numeric(16,3) not null check (raw_consumed_base > 0),
  wastage_base       numeric(16,3) not null default 0 check (wastage_base >= 0),
  run_on             date not null default current_date,
  notes              text,
  status             text not null default 'DRAFT'
                       check (status in ('DRAFT','COMPLETED','CANCELLED')),
  completed_at       timestamptz,
  created_by         uuid,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  deleted_at         timestamptz
);
create index packing_runs_business_idx on app.packing_runs (business_id) where deleted_at is null;

create table app.orders (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references app.businesses(id),
  customer_id       uuid not null references app.customers(id),
  -- Assigned server-side at push time; null while the order is only local.
  order_no          bigint,
  status            text not null default 'PLACED'
                      check (status in ('PLACED','PACKED','OUT_FOR_DELIVERY',
                                        'DELIVERED','PAYMENT_PENDING','CLOSED','CANCELLED')),
  total_amount      numeric(14,2) not null default 0 check (total_amount >= 0),
  notes             text,
  placed_at         timestamptz not null default now(),
  packed_at         timestamptz,
  dispatched_at     timestamptz,
  delivered_at      timestamptz,
  closed_at         timestamptz,
  cancelled_at      timestamptz,
  created_by        uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz
);
create index orders_business_idx on app.orders (business_id) where deleted_at is null;
create index orders_customer_idx on app.orders (customer_id);
create index orders_status_idx on app.orders (business_id, status) where deleted_at is null;
create unique index orders_no_uq on app.orders (business_id, order_no)
  where order_no is not null;

create table app.order_items (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references app.businesses(id),
  order_id       uuid not null references app.orders(id),
  packed_sku_id  uuid not null references app.packed_skus(id),
  qty_packets    numeric(16,3) not null check (qty_packets > 0),
  unit_price     numeric(14,2) not null default 0 check (unit_price >= 0),
  line_total     numeric(16,2) generated always as (qty_packets * unit_price) stored,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  deleted_at     timestamptz
);
create index order_items_order_idx on app.order_items (order_id);
create index order_items_business_idx on app.order_items (business_id) where deleted_at is null;
