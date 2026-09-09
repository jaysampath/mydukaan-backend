-- 0002_core_schema
-- Multi-tenant core. Every table carries business_id + created_by + timestamps
-- + deleted_at (soft delete). Ledger tables are append-only (see 0004).
--
-- Units policy (avoids float drift and unit ambiguity in the ledger):
--   RAW    stock is measured in GRAMS.
--   PACKED stock is measured in PACKETS (whole units of a given pack size).
-- Everything numeric is NUMERIC, never float.

-- ---------------------------------------------------------------------------
-- Tenants
-- ---------------------------------------------------------------------------

create table app.businesses (
  id                     uuid primary key default gen_random_uuid(),
  -- Mirrors id so that sync + RLS can treat every table identically.
  business_id            uuid generated always as (id) stored,
  name                   text not null check (length(btrim(name)) between 1 and 120),
  phone                  text,
  address                text,
  -- GSTIN display on receipts is a FREE toggle. Receipts are payment
  -- confirmations, not tax invoices. This must never be gated by billing.
  gstin                  text check (gstin is null or gstin ~ '^[0-9A-Z]{15}$'),
  show_gstin_on_receipt  boolean not null default false,
  currency               text not null default 'INR',
  -- Billing (Phase 7). Lapse means READ-ONLY, never data-lock.
  subscription_status    text not null default 'TRIAL'
                           check (subscription_status in ('TRIAL','ACTIVE','LAPSED')),
  trial_ends_at          timestamptz,
  seat_limit             integer not null default 5 check (seat_limit > 0),
  -- Toggleable modules. Only the spice-wholesaler config ships in V1.
  features               jsonb not null default '{"packing": true}'::jsonb,
  created_by             uuid,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  deleted_at             timestamptz
);

-- One row per app user. V1: a user belongs to exactly one business.
create table app.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  business_id  uuid not null references app.businesses(id),
  full_name    text not null default '',
  phone        text,
  role         text not null default 'PACKER'
                 check (role in ('OWNER','MANAGER','PACKER','DELIVERY')),
  is_active    boolean not null default true,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz
);
create index profiles_business_idx on app.profiles (business_id) where deleted_at is null;

-- Server-allocated, gap-free, per-business document numbers. Offline clients
-- cannot safely allocate these, so they are assigned at push time.
create table app.business_counters (
  business_id uuid not null references app.businesses(id),
  name        text not null check (name in ('order_no','purchase_no')),
  value       bigint not null default 0,
  primary key (business_id, name)
);

-- ---------------------------------------------------------------------------
-- Catalog: raw/bulk stock and packed SKUs are DISTINCT entities joined by a
-- conversion relationship (packed_skus.raw_material_id + pack_size_g).
-- ---------------------------------------------------------------------------

create table app.raw_materials (
  id                  uuid primary key default gen_random_uuid(),
  business_id         uuid not null references app.businesses(id),
  name                text not null check (length(btrim(name)) between 1 and 120),
  sku_code            text,
  -- Ledger base unit. Grams for everything weighed.
  base_unit           text not null default 'g' check (base_unit in ('g','ml','pcs')),
  reorder_level_base  numeric(16,3) not null default 0 check (reorder_level_base >= 0),
  is_active           boolean not null default true,
  created_by          uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz
);
create index raw_materials_business_idx on app.raw_materials (business_id) where deleted_at is null;

create table app.packed_skus (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references app.businesses(id),
  raw_material_id  uuid not null references app.raw_materials(id),
  name             text not null check (length(btrim(name)) between 1 and 120),
  -- 1kg / 500g / 250g / 100g / 50g are just values here, not an enum, so a
  -- business can add its own pack sizes without a migration.
  pack_size_base   numeric(16,3) not null check (pack_size_base > 0),
  sku_code         text,
  sale_price       numeric(14,2) not null default 0 check (sale_price >= 0),
  is_active        boolean not null default true,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz
);
create index packed_skus_business_idx on app.packed_skus (business_id) where deleted_at is null;
create index packed_skus_raw_idx on app.packed_skus (raw_material_id);

-- ---------------------------------------------------------------------------
-- Parties
-- ---------------------------------------------------------------------------

create table app.customers (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references app.businesses(id),
  name         text not null check (length(btrim(name)) between 1 and 120),
  phone        text,
  address      text,
  notes        text,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz
);
create index customers_business_idx on app.customers (business_id) where deleted_at is null;

create table app.suppliers (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references app.businesses(id),
  name         text not null check (length(btrim(name)) between 1 and 120),
  phone        text,
  address      text,
  notes        text,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  deleted_at   timestamptz
);
create index suppliers_business_idx on app.suppliers (business_id) where deleted_at is null;
