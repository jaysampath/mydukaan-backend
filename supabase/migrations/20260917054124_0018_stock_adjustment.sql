-- 0018_stock_adjustment
--
-- app.stock_ledger.entry_type has permitted OPENING, ADJUSTMENT and RETURN_IN
-- since 0004, and no function has ever written one. The only path was
-- sync_push, which is how dev_seed.sql posts its opening balance -- so with
-- offline sync removed (ADR 0003) there is currently NO way to:
--
--   * enter the stock a business already has when it starts using the app
--   * correct a stock-take ("the app says 12, I counted 10")
--   * take goods back from a customer
--
-- The first of those blocks onboarding a real business entirely, which makes
-- this the function the inventory phase is waiting on.
--
-- Roles: OWNER and MANAGER. A PACKER must not be able to invent stock -- the
-- whole point of the ledger is that every packet is accounted for, and an
-- unaudited adjustment is the one way to defeat that.

-- ---------------------------------------------------------------------------
-- The design decision worth explaining: p_mode.
--
-- 'SET'   the user counted the shelf. They enter "18 packets", which is what a
--         person actually knows, and the server computes the signed delta
--         against the current sum. Asking a shopkeeper to work out that they
--         need to record "-2" is asking them to do arithmetic under pressure,
--         and getting the sign wrong writes a plausible-looking wrong number
--         into an append-only ledger.
-- 'DELTA' the user knows the movement: "3 packets were damaged". Here the
--         signed number IS the thing they know, so asking for it is right.
--
-- Either way exactly one signed row is inserted. The ledger stays append-only
-- and nothing is ever overwritten; 'SET' is a convenience of input, not a
-- different storage model.
-- ---------------------------------------------------------------------------

create or replace function public.record_stock_adjustment(
  p_entry_id   uuid,
  p_item_kind  text,
  p_item_id    uuid,
  p_mode       text,
  p_qty        numeric,
  p_entry_type text default 'ADJUSTMENT',
  p_note       text default null,
  p_ref_id     uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_on_hand  numeric;
  v_delta    numeric;
  v_ref_type text := 'MANUAL';
  v_existing app.stock_ledger;
begin
  perform app.require_role('OWNER', 'MANAGER');
  perform app.require_write_access();

  -- Idempotency. A phone that loses signal mid-call retries the same call, and
  -- a stock count that gets applied twice is exactly the silent corruption the
  -- caller-minted-uuid convention exists to prevent.
  --
  -- FOUND, not `v_existing is not null`: for a rowtype variable the latter is
  -- true only when EVERY column is non-null, and note/ref_id/raw_material_id
  -- are all routinely null here. That trap already shipped one bug in this
  -- codebase and was fixed in 0016.
  select * into v_existing from app.stock_ledger where id = p_entry_id;
  if found then
    if v_existing.business_id <> v_business then
      -- Do not confirm that an id exists in someone else's tenant.
      raise exception 'entry % not found', p_entry_id using errcode = 'P0002';
    end if;
    return jsonb_build_object(
      'entry_id', p_entry_id,
      'created',  false,
      'delta',    v_existing.qty_base,
      'entry_type', v_existing.entry_type
    );
  end if;

  if p_item_kind not in ('RAW', 'PACKED') then
    raise exception 'item_kind must be RAW or PACKED, got %', p_item_kind
      using errcode = '22023';
  end if;
  if p_mode not in ('SET', 'DELTA') then
    raise exception 'mode must be SET or DELTA, got %', p_mode
      using errcode = '22023';
  end if;
  -- PURCHASE_IN, PACK_OUT, PACK_IN and SALE_OUT belong to the operations that
  -- cause them; letting a client post one by hand would put a movement in the
  -- ledger with no purchase, run or order behind it.
  if p_entry_type not in ('OPENING', 'ADJUSTMENT', 'RETURN_IN') then
    raise exception 'entry_type must be OPENING, ADJUSTMENT or RETURN_IN, got %', p_entry_type
      using errcode = '22023';
  end if;
  if p_qty is null then
    raise exception 'quantity is required' using errcode = '22023';
  end if;

  -- The FK on stock_ledger is not tenant-aware, so a valid id belonging to
  -- another business would satisfy it. Check the tenant explicitly -- the same
  -- guard upsert_packed_sku makes for raw_material_id.
  if p_item_kind = 'RAW' then
    if not exists (
      select 1 from app.raw_materials
      where id = p_item_id and business_id = v_business and deleted_at is null
    ) then
      raise exception 'raw material % not found', p_item_id using errcode = 'P0002';
    end if;
    select coalesce(sum(qty_base), 0) into v_on_hand
    from app.stock_ledger
    where business_id = v_business and raw_material_id = p_item_id;
  else
    if not exists (
      select 1 from app.packed_skus
      where id = p_item_id and business_id = v_business and deleted_at is null
    ) then
      raise exception 'packed sku % not found', p_item_id using errcode = 'P0002';
    end if;
    select coalesce(sum(qty_base), 0) into v_on_hand
    from app.stock_ledger
    where business_id = v_business and packed_sku_id = p_item_id;
  end if;

  -- One opening count per item. A second one is always a mistake -- either the
  -- user meant a correction, or they are about to double their stock.
  if p_entry_type = 'OPENING' and exists (
    select 1 from app.stock_ledger
    where business_id = v_business
      and entry_type = 'OPENING'
      and (raw_material_id = p_item_id or packed_sku_id = p_item_id)
  ) then
    raise exception 'this item already has an opening balance; record an ADJUSTMENT instead'
      using errcode = '22023', hint = 'use_adjustment';
  end if;

  if p_entry_type = 'RETURN_IN' then
    if p_ref_id is null then
      raise exception 'a return must name the order it came back from'
        using errcode = '22023';
    end if;
    if not exists (
      select 1 from app.orders
      where id = p_ref_id and business_id = v_business and deleted_at is null
    ) then
      raise exception 'order % not found', p_ref_id using errcode = 'P0002';
    end if;
    v_ref_type := 'ORDER';
  end if;

  v_delta := case when p_mode = 'SET' then p_qty - v_on_hand else p_qty end;

  -- A count that matches the books is not an error, and it must not be one:
  -- stock_ledger has check (qty_base <> 0), so there is no row to write. The
  -- user counted, the app agreed, nothing happened. Report that plainly.
  if v_delta = 0 then
    return jsonb_build_object(
      'entry_id',   p_entry_id,
      'created',    false,
      'delta',      0,
      'qty_before', v_on_hand,
      'qty_after',  v_on_hand,
      'entry_type', p_entry_type
    );
  end if;

  -- You cannot count a negative shelf. Same posture and same SQLSTATE as
  -- dispatch_order's stock check.
  if v_on_hand + v_delta < 0 then
    raise exception 'that would leave stock at %; there are only % on hand',
      v_on_hand + v_delta, v_on_hand
      using errcode = '23514';
  end if;

  insert into app.stock_ledger (
    id, business_id, entry_type, item_kind,
    raw_material_id, packed_sku_id, qty_base,
    ref_type, ref_id, note, created_by
  )
  values (
    p_entry_id, v_business, p_entry_type, p_item_kind,
    case when p_item_kind = 'RAW' then p_item_id end,
    case when p_item_kind = 'PACKED' then p_item_id end,
    v_delta,
    v_ref_type,
    coalesce(p_ref_id, p_entry_id),
    p_note,
    app.current_user_id()
  );

  return jsonb_build_object(
    'entry_id',   p_entry_id,
    'created',    true,
    'delta',      v_delta,
    'qty_before', v_on_hand,
    'qty_after',  v_on_hand + v_delta,
    'entry_type', p_entry_type
  );
end
$fn$;

comment on function public.record_stock_adjustment(uuid, text, uuid, text, numeric, text, text, uuid) is
  'Opening balances, stock-take corrections and customer returns. p_mode SET takes a counted quantity and derives the signed delta; DELTA takes the movement directly. OWNER/MANAGER only.';

alter function public.record_stock_adjustment(uuid, text, uuid, text, numeric, text, text, uuid)
  owner to app_api;
revoke all on function public.record_stock_adjustment(uuid, text, uuid, text, numeric, text, text, uuid)
  from public, anon;
grant execute on function public.record_stock_adjustment(uuid, text, uuid, text, numeric, text, text, uuid)
  to authenticated;
