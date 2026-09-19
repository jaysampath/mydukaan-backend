-- 0020_ledger_no_business_id
--
-- get_customer_ledger leaked business_id.
--
-- Its `balance` field was built with to_jsonb(b) over app.v_customer_balances,
-- and that view carries business_id as its first column -- so every call
-- returned the caller's tenant key. Inherited from 0007 and carried into the
-- 0017 rewrite unchanged.
--
-- Not a breach: it is the caller's OWN business_id, and knowing it grants
-- nothing, because no RPC in this system accepts a business_id and
-- app.from_wire() strips any that is sent. But the invariant is worth holding
-- exactly rather than approximately -- "a client never sees a tenant key" is a
-- much easier property to keep true than "a client sees only its own", and it
-- leaves nothing for a future bug to pick up and pass back.
--
-- Found by the new business_id key-walk in scripts/sync-contract-test.mjs,
-- which recurses through every read payload looking for the key. Worth noting
-- that the structural lint in supabase/tests/security_and_sync.sql could NOT
-- have found this: the function does scope to the tenant correctly and does
-- carry its guard. Only looking at the actual response caught it. The two
-- checks are complementary, not redundant.
--
-- The fix is to name the columns instead of splatting the view. Every other
-- read in 0017 already does this; this was the one place a view row went out
-- whole.

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
  v_orders   jsonb;
  v_pays     jsonb;
begin
  perform app.require_role('OWNER', 'MANAGER', 'DELIVERY');
  p_limit  := least(greatest(coalesce(p_limit, 50), 1), 200);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  if not exists (
    select 1 from app.customers
    where id = p_customer_id and business_id = v_business and deleted_at is null
  ) then
    raise exception 'customer % not found', p_customer_id using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.placed_at desc), '[]'::jsonb)
    into v_orders
  from (
    select o.id, o.order_no, o.status, o.total_amount, o.placed_at,
           coalesce((select sum(amount) from app.payments where order_id = o.id), 0) as paid
    from app.orders o
    where o.customer_id = p_customer_id and o.business_id = v_business
      and o.deleted_at is null
    order by o.placed_at desc
    limit p_limit + 1 offset p_offset
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.paid_on desc), '[]'::jsonb)
    into v_pays
  from (
    select p.id, p.amount, p.paid_on, p.order_id, p.note, p.created_at
    from app.payments p
    where p.customer_id = p_customer_id and p.business_id = v_business
    order by p.paid_on desc, p.created_at desc
    limit p_limit + 1 offset p_offset
  ) x;

  return jsonb_build_object(
    -- Named columns, not to_jsonb(b): the view's first column is business_id.
    'balance', (
      select jsonb_build_object(
               'customer_id',  b.customer_id,
               'name',         b.name,
               'total_billed', b.total_billed,
               'total_paid',   b.total_paid,
               'outstanding',  b.outstanding)
      from app.v_customer_balances b
      where b.customer_id = p_customer_id and b.business_id = v_business
    ),
    'orders',   app.page(v_orders, p_limit, p_offset),
    'payments', app.page(v_pays, p_limit, p_offset)
  );
end
$fn$;

alter function public.get_customer_ledger(uuid, integer, integer) owner to app_api;
revoke all on function public.get_customer_ledger(uuid, integer, integer) from public, anon;
grant execute on function public.get_customer_ledger(uuid, integer, integer) to authenticated;
