-- 0012_packing_run_conservation
--
-- Fixes an integrity hole in create_packing_run as shipped in 0011.
--
-- The ledger model is: raw_consumed_base is everything that left the sack,
-- INCLUDING what was spilled; wastage_base records how much of that did not
-- become packets. run_conversion() posts PACK_OUT of -raw_consumed_base and
-- PACK_IN of +packets_produced, which is correct under that reading.
--
-- 0011 took both numbers from the client and checked neither against the
-- other. A run claiming 60 packets of a 500 g SKU from 100 g of raw would be
-- accepted: PACK_OUT deducts 100 g, PACK_IN adds 60 packets, and 29,900 g of
-- stock is conjured out of nothing. run_conversion's stock check does not catch
-- it -- it only asks whether the consumed amount is available, and 100 g was.
--
-- The fix is to stop accepting wastage at all and derive it:
--
--     wastage = raw_consumed - (packets_produced * pack_size_base)
--
-- with the run refused when that is negative. The client says what left the
-- sack and how many packets came out; the arithmetic between them belongs to
-- the server, and two numbers that cannot disagree are better than two numbers
-- that must be checked against each other.
--
-- The old signature is dropped rather than left alongside: PostgREST resolves
-- overloads by the key names in the request body, and two create_packing_run
-- functions differing by one optional numeric is exactly the ambiguity that
-- produces a confusing 300-level error at runtime.

drop function if exists public.create_packing_run(
  uuid, uuid, uuid, numeric, numeric, numeric, date, text, boolean
);

create or replace function public.create_packing_run(
  p_run_id            uuid,
  p_raw_material_id   uuid,
  p_packed_sku_id     uuid,
  p_packets_produced  numeric,
  p_raw_consumed_base numeric,
  p_run_on            date default null,
  p_notes             text default null,
  p_complete          boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business  uuid := app.current_business_id();
  v_pack_size numeric;
  v_packed    numeric;
  v_wastage   numeric;
begin
  perform app.require_role('OWNER', 'MANAGER', 'PACKER');
  perform app.require_write_access();

  -- Idempotent retry.
  if exists (select 1 from app.packing_runs where id = p_run_id and business_id = v_business) then
    return jsonb_build_object('packing_run_id', p_run_id, 'created', false);
  end if;

  if p_packets_produced is null or p_packets_produced <= 0 then
    raise exception 'packets produced must be greater than zero' using errcode = '22023';
  end if;
  if p_raw_consumed_base is null or p_raw_consumed_base <= 0 then
    raise exception 'raw consumed must be greater than zero' using errcode = '22023';
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
  select pack_size_base into v_pack_size
  from app.packed_skus
  where id = p_packed_sku_id
    and business_id = v_business
    and raw_material_id = p_raw_material_id
    and deleted_at is null;

  if v_pack_size is null then
    raise exception 'packed SKU % is not packed from raw material %',
      p_packed_sku_id, p_raw_material_id using errcode = '22023';
  end if;

  -- Conservation of matter. You cannot pack more than you took out of the sack.
  v_packed  := p_packets_produced * v_pack_size;
  v_wastage := p_raw_consumed_base - v_packed;

  if v_wastage < 0 then
    raise exception
      'cannot pack % packets (% base units) from % base units of raw material',
      p_packets_produced, v_packed, p_raw_consumed_base
      using errcode = '23514';
  end if;

  insert into app.packing_runs (
    id, business_id, raw_material_id, packed_sku_id, packets_produced,
    raw_consumed_base, wastage_base, run_on, notes, status, created_by
  ) values (
    p_run_id, v_business, p_raw_material_id, p_packed_sku_id, p_packets_produced,
    p_raw_consumed_base, v_wastage, coalesce(p_run_on, current_date),
    p_notes, 'DRAFT', app.current_user_id()
  );

  if p_complete then
    perform public.run_conversion(p_run_id);
  end if;

  return jsonb_build_object(
    'packing_run_id', p_run_id,
    'created', true,
    'completed', p_complete,
    'packed_base', v_packed,
    'wastage_base', v_wastage
  );
end
$fn$;

alter function public.create_packing_run(uuid,uuid,uuid,numeric,numeric,date,text,boolean)
  owner to app_api;
revoke all on function public.create_packing_run(uuid,uuid,uuid,numeric,numeric,date,text,boolean)
  from public, anon;
grant execute on function public.create_packing_run(uuid,uuid,uuid,numeric,numeric,date,text,boolean)
  to authenticated;
