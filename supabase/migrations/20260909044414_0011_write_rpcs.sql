-- 0011_write_rpcs
--
-- The write path SYNC_MODE=pull_only needs.
--
-- Until now most records were created by sync_push: app.pushable_tables() lists
-- eleven tables, and for four of them -- customers, suppliers, raw_materials,
-- packed_skus -- push was the ONLY way a row could come into existence. Two
-- more, purchases and packing_runs, had operation RPCs that took nothing but an
-- id and assumed the row had already arrived that way.
--
-- With the client no longer pushing (see the app repo's
-- docs/adr/0002-sync-mode-flag.md) there was no way to create a customer, a
-- supplier, a product, a purchase or a packing run at all. This closes that.
--
-- Conventions, all inherited from 0007:
--   * the caller supplies the record's uuid, so a phone that loses signal
--     mid-call retries the same call rather than creating a second row;
--   * business_id is never a parameter -- it comes from the JWT;
--   * every function checks a role and the subscription gate;
--   * deletion is soft, so the archive_* functions set deleted_at.
--
-- receive_purchase() and run_conversion() are deliberately NOT reimplemented
-- here. The new create_* functions call them, so the ledger-posting rules stay
-- stated exactly once.
--
-- NOTE: create_packing_run as defined here trusts the client's wastage figure
-- and never checks it against pack size, which lets a run conjure stock out of
-- nothing. Superseded by 0012_packing_run_conservation.sql -- do not copy this
-- version.

-- ---------------------------------------------------------------------------
-- Master data.
--
-- Upserts rather than separate create/update: the client mints the id, so
-- "create this" and "save my edit" are the same request, and a retry of either
-- is safe.
-- ---------------------------------------------------------------------------

create or replace function public.upsert_customer(
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
  perform app.require_role('OWNER', 'MANAGER');
  perform app.require_write_access();

  if p_name is null or btrim(p_name) = '' then
    raise exception 'customer name is required' using errcode = '22023';
  end if;

  select not exists (select 1 from app.customers where id = p_id) into v_created;

  insert into app.customers (id, business_id, name, phone, address, notes, created_by)
  values (p_id, v_business, btrim(p_name), p_phone, p_address, p_notes, app.current_user_id())
  on conflict (id) do update
    set name = excluded.name,
        phone = excluded.phone,
        address = excluded.address,
        notes = excluded.notes;

  return jsonb_build_object('customer_id', p_id, 'created', v_created);
exception
  when unique_violation then
    raise exception 'id % is already in use' , p_id using errcode = '23505';
end
$fn$;

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
  perform app.require_role('OWNER', 'MANAGER');
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

create or replace function public.upsert_raw_material(
  p_id                 uuid,
  p_name               text,
  p_sku_code           text default null,
  p_base_unit          text default 'g',
  p_reorder_level_base numeric default 0,
  p_is_active          boolean default true
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
  perform app.require_role('OWNER', 'MANAGER');
  perform app.require_write_access();

  if p_name is null or btrim(p_name) = '' then
    raise exception 'material name is required' using errcode = '22023';
  end if;
  if coalesce(p_reorder_level_base, 0) < 0 then
    raise exception 'reorder level cannot be negative' using errcode = '22023';
  end if;

  select not exists (select 1 from app.raw_materials where id = p_id) into v_created;

  insert into app.raw_materials (
    id, business_id, name, sku_code, base_unit, reorder_level_base, is_active, created_by
  ) values (
    p_id, v_business, btrim(p_name), p_sku_code, coalesce(p_base_unit, 'g'),
    coalesce(p_reorder_level_base, 0), coalesce(p_is_active, true), app.current_user_id()
  )
  on conflict (id) do update
    set name = excluded.name,
        sku_code = excluded.sku_code,
        base_unit = excluded.base_unit,
        reorder_level_base = excluded.reorder_level_base,
        is_active = excluded.is_active;

  return jsonb_build_object('raw_material_id', p_id, 'created', v_created);
exception
  when unique_violation then
    raise exception 'id % is already in use', p_id using errcode = '23505';
end
$fn$;

create or replace function public.upsert_packed_sku(
  p_id              uuid,
  p_raw_material_id uuid,
  p_name            text,
  p_pack_size_base  numeric,
  p_sku_code        text default null,
  p_sale_price      numeric default 0,
  p_is_active       boolean default true
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
  perform app.require_role('OWNER', 'MANAGER');
  perform app.require_write_access();

  if p_name is null or btrim(p_name) = '' then
    raise exception 'SKU name is required' using errcode = '22023';
  end if;
  if p_pack_size_base is null or p_pack_size_base <= 0 then
    raise exception 'pack size must be greater than zero' using errcode = '22023';
  end if;
  if coalesce(p_sale_price, 0) < 0 then
    raise exception 'sale price cannot be negative' using errcode = '22023';
  end if;

  -- The parent must be in the caller's tenant. Without this the FK would accept
  -- any raw_material_id the caller could guess, since the FK itself is not
  -- tenant-aware.
  if not exists (
    select 1 from app.raw_materials
    where id = p_raw_material_id and business_id = v_business and deleted_at is null
  ) then
    raise exception 'raw material % not found', p_raw_material_id using errcode = 'P0002';
  end if;

  select not exists (select 1 from app.packed_skus where id = p_id) into v_created;

  insert into app.packed_skus (
    id, business_id, raw_material_id, name, pack_size_base, sku_code,
    sale_price, is_active, created_by
  ) values (
    p_id, v_business, p_raw_material_id, btrim(p_name), p_pack_size_base, p_sku_code,
    coalesce(p_sale_price, 0), coalesce(p_is_active, true), app.current_user_id()
  )
  on conflict (id) do update
    set raw_material_id = excluded.raw_material_id,
        name = excluded.name,
        pack_size_base = excluded.pack_size_base,
        sku_code = excluded.sku_code,
        sale_price = excluded.sale_price,
        is_active = excluded.is_active;

  return jsonb_build_object('packed_sku_id', p_id, 'created', v_created);
exception
  when unique_violation then
    raise exception 'id % is already in use', p_id using errcode = '23505';
end
$fn$;

-- ---------------------------------------------------------------------------
-- Archiving. Soft, always: the ledgers reference these rows and history must
-- stay readable. An archived master simply stops appearing in pickers.
-- ---------------------------------------------------------------------------

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

  execute format(
    'update app.%I set deleted_at = now()
      where id = $1 and business_id = $2 and deleted_at is null', p_table)
  using p_id, v_business;

  get diagnostics v_count = row_count;

  return jsonb_build_object('table', p_table, 'id', p_id, 'archived', v_count > 0);
end
$fn$;

-- ---------------------------------------------------------------------------
-- Purchases.
--
-- Creates the purchase and its lines, then posts it through receive_purchase()
-- so the PURCHASE_IN ledger rows are written by the same code the two-step
-- flow uses. Pass p_receive => false to record a purchase that has not physically
-- arrived; call receive_purchase(id) when it does.
-- ---------------------------------------------------------------------------

create or replace function public.create_purchase(
  p_purchase_id  uuid,
  p_supplier_id  uuid,
  p_items        jsonb,
  p_invoice_no   text default null,
  p_purchased_on date default null,
  p_notes        text default null,
  p_receive      boolean default true
)
returns jsonb
language plpgsql
security definer
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
  perform app.require_role('OWNER', 'MANAGER');
  perform app.require_write_access();

  -- Idempotent retry: the purchase already exists, so report it rather than
  -- creating a second one or double-posting its stock.
  if exists (select 1 from app.purchases where id = p_purchase_id and business_id = v_business) then
    return jsonb_build_object('purchase_id', p_purchase_id, 'created', false);
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'a purchase needs at least one item' using errcode = '22023';
  end if;

  if p_supplier_id is not null and not exists (
    select 1 from app.suppliers
    where id = p_supplier_id and business_id = v_business and deleted_at is null
  ) then
    raise exception 'supplier % not found', p_supplier_id using errcode = 'P0002';
  end if;

  insert into app.purchases (
    id, business_id, supplier_id, invoice_no, purchased_on, notes, status, created_by
  ) values (
    p_purchase_id, v_business, p_supplier_id, p_invoice_no,
    coalesce(p_purchased_on, current_date), p_notes, 'DRAFT', app.current_user_id()
  );

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

    v_total := v_total + (v_qty * v_cost);
  end loop;

  -- Server-derived, never taken from the client.
  update app.purchases set total_amount = v_total where id = p_purchase_id;

  if p_receive then
    perform public.receive_purchase(p_purchase_id);
  end if;

  return jsonb_build_object(
    'purchase_id', p_purchase_id,
    'created', true,
    'total_amount', v_total,
    'received', p_receive
  );
end
$fn$;

-- ---------------------------------------------------------------------------
-- Packing runs.
--
-- Same shape: create the run, then let run_conversion() post PACK_OUT/PACK_IN
-- and enforce the "is there enough raw stock?" check.
-- ---------------------------------------------------------------------------

create or replace function public.create_packing_run(
  p_run_id           uuid,
  p_raw_material_id  uuid,
  p_packed_sku_id    uuid,
  p_packets_produced numeric,
  p_raw_consumed_base numeric,
  p_wastage_base     numeric default 0,
  p_run_on           date default null,
  p_notes            text default null,
  p_complete         boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
begin
  perform app.require_role('OWNER', 'MANAGER', 'PACKER');
  perform app.require_write_access();

  if exists (select 1 from app.packing_runs where id = p_run_id and business_id = v_business) then
    return jsonb_build_object('packing_run_id', p_run_id, 'created', false);
  end if;

  if p_packets_produced is null or p_packets_produced <= 0 then
    raise exception 'packets produced must be greater than zero' using errcode = '22023';
  end if;
  if p_raw_consumed_base is null or p_raw_consumed_base <= 0 then
    raise exception 'raw consumed must be greater than zero' using errcode = '22023';
  end if;
  if coalesce(p_wastage_base, 0) < 0 then
    raise exception 'wastage cannot be negative' using errcode = '22023';
  end if;

  if not exists (
    select 1 from app.raw_materials
    where id = p_raw_material_id and business_id = v_business and deleted_at is null
  ) then
    raise exception 'raw material % not found', p_raw_material_id using errcode = 'P0002';
  end if;

  -- The SKU must be packed FROM this material. Letting them differ would post a
  -- PACK_OUT against one item and a PACK_IN against something unrelated, which
  -- silently invents stock.
  if not exists (
    select 1 from app.packed_skus
    where id = p_packed_sku_id
      and business_id = v_business
      and raw_material_id = p_raw_material_id
      and deleted_at is null
  ) then
    raise exception 'packed SKU % is not packed from raw material %',
      p_packed_sku_id, p_raw_material_id using errcode = '22023';
  end if;

  insert into app.packing_runs (
    id, business_id, raw_material_id, packed_sku_id, packets_produced,
    raw_consumed_base, wastage_base, run_on, notes, status, created_by
  ) values (
    p_run_id, v_business, p_raw_material_id, p_packed_sku_id, p_packets_produced,
    p_raw_consumed_base, coalesce(p_wastage_base, 0), coalesce(p_run_on, current_date),
    p_notes, 'DRAFT', app.current_user_id()
  );

  if p_complete then
    perform public.run_conversion(p_run_id);
  end if;

  return jsonb_build_object(
    'packing_run_id', p_run_id,
    'created', true,
    'completed', p_complete
  );
end
$fn$;

-- ---------------------------------------------------------------------------
-- Ownership and grants. app_api has no BYPASSRLS, so tenant policies still
-- apply inside every one of these.
-- ---------------------------------------------------------------------------

do $$
declare f text;
begin
  foreach f in array array[
    'public.upsert_customer(uuid,text,text,text,text)',
    'public.upsert_supplier(uuid,text,text,text,text)',
    'public.upsert_raw_material(uuid,text,text,text,numeric,boolean)',
    'public.upsert_packed_sku(uuid,uuid,text,numeric,text,numeric,boolean)',
    'public.archive_master(text,uuid)',
    'public.create_purchase(uuid,uuid,jsonb,text,date,text,boolean)',
    'public.create_packing_run(uuid,uuid,uuid,numeric,numeric,numeric,date,text,boolean)'
  ] loop
    execute format('alter function %s owner to app_api', f);
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end
$$;
