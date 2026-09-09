-- dev_seed.sql
--
-- Fixtures for the DEV project only. Creates two businesses so tenant isolation
-- has something to isolate, and three users so role checks have something to
-- refuse.
--
-- NEVER run this against prod. It inserts directly into auth.users, which is
-- only acceptable because dev has no real accounts.
--
-- The data is a small slice of the real workflow: bulk turmeric arrives, gets
-- packed into 500g retail packets, one packet leaves on an order, and the
-- customer pays in two instalments.

do $$
begin
  if current_database() not in ('postgres') then
    raise exception 'refusing to seed: unexpected database %', current_database();
  end if;
end
$$;

-- --------------------------------------------------------------------------
-- Users. Passwords are unusable on purpose -- these accounts exist to be
-- impersonated from SQL via request.jwt.claims, not to be signed into.
-- --------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
values
  ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111',
   'authenticated','authenticated','owner.a@dev.local','-',now(),now(),now(),'{}','{}'),
  ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222',
   'authenticated','authenticated','owner.b@dev.local','-',now(),now(),now(),'{}','{}'),
  ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333',
   'authenticated','authenticated','packer.a@dev.local','-',now(),now(),now(),'{}','{}')
on conflict (id) do nothing;

-- --------------------------------------------------------------------------
-- Business A, seeded through the real API surface so the seed exercises the
-- same code path the app does.
-- --------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';

select public.bootstrap_business('Test Spice Co', 'Owner A');

select public.sync_push(jsonb_build_object(
  'raw_materials', jsonb_build_object('created', jsonb_build_array(
    jsonb_build_object(
      'id','aaaaaaa1-0000-4000-8000-000000000001',
      'name','Turmeric (bulk)', 'base_unit','g',
      'reorder_level_base', 5000, 'is_active', true))),
  'customers', jsonb_build_object('created', jsonb_build_array(
    jsonb_build_object(
      'id','ccccccc1-0000-4000-8000-000000000001',
      'name','Ravi Kirana Store', 'phone','9000000001'))),
  'stock_ledger', jsonb_build_object('created', jsonb_build_array(
    jsonb_build_object(
      'id','51000cc1-0000-4000-8000-000000000001',
      'entry_type','OPENING', 'item_kind','RAW',
      'raw_material_id','aaaaaaa1-0000-4000-8000-000000000001',
      'qty_base', 50000, 'ref_type','MANUAL', 'note','opening count')))
), null);

-- A packing run: 10kg of bulk turmeric becomes 20 x 500g packets.
select public.sync_push(jsonb_build_object(
  'packed_skus', jsonb_build_object('created', jsonb_build_array(
    jsonb_build_object(
      'id','bbbbbbb1-0000-4000-8000-000000000001',
      'raw_material_id','aaaaaaa1-0000-4000-8000-000000000001',
      'name','Turmeric 500g', 'pack_size_base', 500, 'sale_price', 90))),
  'stock_ledger', jsonb_build_object('created', jsonb_build_array(
    jsonb_build_object(
      'id','51000cc1-0000-4000-8000-000000000002',
      'entry_type','PACK_OUT','item_kind','RAW',
      'raw_material_id','aaaaaaa1-0000-4000-8000-000000000001',
      'qty_base', -10000, 'ref_type','PACKING_RUN'),
    jsonb_build_object(
      'id','51000cc1-0000-4000-8000-000000000003',
      'entry_type','PACK_IN','item_kind','PACKED',
      'packed_sku_id','bbbbbbb1-0000-4000-8000-000000000001',
      'qty_base', 20, 'ref_type','PACKING_RUN')))
), null);

reset role;

-- Second seat in business A, so role refusals can be tested. Seat invites are
-- Phase 1; until then the profile is inserted directly.
insert into app.profiles (id, business_id, full_name, role, created_by)
select '33333333-3333-3333-3333-333333333333', b.id, 'Packer A', 'PACKER',
       '11111111-1111-1111-1111-111111111111'
from app.businesses b where b.name = 'Test Spice Co'
on conflict (id) do nothing;

-- --------------------------------------------------------------------------
-- Business B. Exists purely so "B must not see A's data" has a B.
-- --------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222","role":"authenticated"}';
select public.bootstrap_business('Rival Traders', 'Owner B');
reset role;

-- --------------------------------------------------------------------------
-- Expected end state for business A:
--   raw   Turmeric (bulk)   40000 g   (50000 opening - 10000 packed)
--   packed Turmeric 500g       20 packets
-- --------------------------------------------------------------------------
