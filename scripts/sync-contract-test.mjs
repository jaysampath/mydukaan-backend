#!/usr/bin/env node
/**
 * Sync contract test -- runs against the real HTTP API, not the database.
 *
 * The SQL suite in supabase/tests/ proves the logic. This proves the wire:
 * PostgREST routing, the publishable key, JWT propagation, and the exact JSON
 * shapes WatermelonDB will send and receive. Those are the parts that a
 * database-level test cannot reach and that break silently.
 *
 * It is also the Phase 0 acceptance test in miniature: two independent
 * sessions, a write on one, a read on the other.
 *
 *   node --env-file=.env.dev scripts/sync-contract-test.mjs
 *
 * DEV ONLY. It refuses to run against anything but the dev project.
 */

import { randomUUID } from 'node:crypto';

const URL_BASE = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_PUBLISHABLE_KEY;
const APP_ENV = process.env.APP_ENV;

if (!URL_BASE || !KEY) {
  console.error('Missing SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY.');
  console.error('Run with:  node --env-file=.env.dev scripts/sync-contract-test.mjs');
  process.exit(1);
}
if (APP_ENV !== 'dev') {
  console.error(`Refusing to run against APP_ENV=${APP_ENV}. This test writes data; dev only.`);
  process.exit(1);
}

let passed = 0;
let failed = 0;

function check(name, condition, detail) {
  if (condition) {
    passed += 1;
    console.log(`  PASS  ${name}`);
  } else {
    failed += 1;
    console.log(`  FAIL  ${name}${detail ? `\n        ${detail}` : ''}`);
  }
}

async function api(path, { method = 'POST', token, body } = {}) {
  const res = await fetch(`${URL_BASE}${path}`, {
    method,
    headers: {
      apikey: KEY,
      Authorization: `Bearer ${token ?? KEY}`,
      'Content-Type': 'application/json',
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = text;
  }
  return { status: res.status, ok: res.ok, body: json };
}

const rpc = (fn, args, token) => api(`/rest/v1/rpc/${fn}`, { token, body: args });

/**
 * Gets two independent sessions.
 *
 * These are the two SEEDED users, signed in with a password. That matters for
 * what this test can prove: they belong to DIFFERENT businesses, so "A writes,
 * B must not see it" is a real cross-tenant assertion rather than two anonymous
 * users who share no data either way.
 *
 * It used to try anonymous sign-in first, which is disabled on this project, so
 * the test could not run at all. supabase/seed/dev_seed.sql now gives these
 * accounts a real bcrypt password and an auth.identities row, which is what
 * GoTrue actually resolves a password grant through.
 *
 * Phone/OTP is the real auth method for the app (Phase 1) but it needs an SMS
 * provider, so it is not what the contract test leans on.
 */
const SEEDED = {
  A: {
    email: process.env.TEST_OWNER_EMAIL ?? 'owner.a@dev.local',
    password: process.env.TEST_OWNER_PASSWORD ?? 'devpassword123',
  },
  B: {
    email: process.env.TEST_OWNER_B_EMAIL ?? 'owner.b@dev.local',
    password: process.env.TEST_OWNER_B_PASSWORD ?? 'devpassword123',
  },
  // A non-owner in business A. Role refusals used to live only in commented-out
  // SQL, so nothing checked them over the wire -- which is exactly where a
  // missing require_role would bite.
  P: {
    email: process.env.TEST_PACKER_EMAIL ?? 'packer.a@dev.local',
    password: process.env.TEST_PACKER_PASSWORD ?? 'devpassword123',
  },
};

async function session(label) {
  const preset = process.env[`SUPABASE_ACCESS_TOKEN_${label}`];
  if (preset) return preset;

  const who = SEEDED[label];
  const res = await api('/auth/v1/token?grant_type=password', {
    body: { email: who.email, password: who.password },
  });
  if (res.ok && res.body?.access_token) return res.body.access_token;

  throw new Error(
    [
      `Could not sign in as ${who.email} (user ${label}).`,
      ``,
      `  ${res.status} ${JSON.stringify(res.body)}`,
      ``,
      `Has supabase/seed/dev_seed.sql been applied to this project?`,
      `It is what gives the seeded accounts a usable password.`,
      ``,
      `Or export SUPABASE_ACCESS_TOKEN_A and SUPABASE_ACCESS_TOKEN_B.`,
    ].join('\n'),
  );
}

async function main() {
  console.log(`\nSync contract test -> ${URL_BASE}\n`);


  console.log('1. Direct table access must be impossible');
  {
    const anon = await api('/rest/v1/businesses?select=*', { method: 'GET' });
    check(
      'anon GET /businesses is refused',
      anon.status === 401 || anon.status === 404 || anon.status === 403,
      `got ${anon.status} ${JSON.stringify(anon.body)}`,
    );
  }

  const tokenA = await session('A');
  console.log('   (signed in as owner A)');

  {
    const direct = await api('/rest/v1/businesses?select=*', { method: 'GET', token: tokenA });
    check(
      'authenticated GET /businesses is refused',
      !direct.ok,
      `got ${direct.status} ${JSON.stringify(direct.body)}`,
    );
    const ledger = await api('/rest/v1/stock_ledger?select=*', { method: 'GET', token: tokenA });
    check(
      'authenticated GET /stock_ledger is refused',
      !ledger.ok,
      `got ${ledger.status} ${JSON.stringify(ledger.body)}`,
    );
  }

  console.log('\n2. Onboarding');
  const boot = await rpc('bootstrap_business', { p_business_name: 'Contract Test Co', p_owner_name: 'A' }, tokenA);
  check('bootstrap_business succeeds', boot.ok && !!boot.body?.business_id, JSON.stringify(boot.body));
  const bootAgain = await rpc('bootstrap_business', { p_business_name: 'Contract Test Co' }, tokenA);
  check(
    'bootstrap_business is idempotent',
    bootAgain.ok && bootAgain.body?.created === false && bootAgain.body.business_id === boot.body.business_id,
    JSON.stringify(bootAgain.body),
  );

  console.log('\n3. Pull / push round trip');
  const pull0 = await rpc('sync_pull', { last_pulled_at: null }, tokenA);
  check('sync_pull returns changes + timestamp', pull0.ok && !!pull0.body?.changes && typeof pull0.body?.timestamp === 'number', JSON.stringify(pull0.body).slice(0, 300));
  // Exactly one business is the tenant-isolation assertion: one user belongs to
  // one business, so a second row here would mean a leak. The profile count is
  // deliberately NOT pinned to one -- the seeded tenant has an owner and a
  // packer, and a colleague appearing in your pull is correct, not a fault.
  check(
    'first pull carries exactly one business -- the callers own',
    pull0.body?.changes?.businesses?.updated?.length === 1,
    `got ${pull0.body?.changes?.businesses?.updated?.length} businesses`,
  );
  check(
    'first pull carries the callers own profile',
    (pull0.body?.changes?.profiles?.updated ?? []).length >= 1,
    `got ${pull0.body?.changes?.profiles?.updated?.length} profiles`,
  );
  check(
    'timestamps cross the wire as epoch-ms numbers',
    typeof pull0.body?.changes?.businesses?.updated?.[0]?.created_at === 'number',
    `got ${typeof pull0.body?.changes?.businesses?.updated?.[0]?.created_at}`,
  );

  const cursor0 = pull0.body.timestamp;
  const rawId = randomUUID();
  const custId = randomUUID();
  const ledgerId = randomUUID();

  // The payload includes the fields a hostile client would try to control, plus
  // the _status/_changed keys WatermelonDB attaches to every raw record.
  const push = await rpc(
    'sync_push',
    {
      changes: {
        raw_materials: {
          created: [
            {
              id: rawId,
              name: 'Cumin (bulk)',
              base_unit: 'g',
              is_active: true,
              business_id: '00000000-0000-0000-0000-0000000000ff',
              created_by: '00000000-0000-0000-0000-0000000000ff',
              created_at: 0,
              _status: 'created',
              _changed: '',
            },
          ],
          updated: [],
          deleted: [],
        },
        customers: {
          created: [{ id: custId, name: 'Contract Test Customer', phone: '9000000000' }],
          updated: [],
          deleted: [],
        },
        stock_ledger: {
          created: [
            {
              id: ledgerId,
              entry_type: 'OPENING',
              item_kind: 'RAW',
              raw_material_id: rawId,
              qty_base: 25000,
              ref_type: 'MANUAL',
            },
          ],
          updated: [],
          deleted: [],
        },
      },
      last_pulled_at: cursor0,
    },
    tokenA,
  );
  check('sync_push accepts a WatermelonDB changeset', push.ok, JSON.stringify(push.body));
  check(
    'reorder_level_base defaulted (partial record, no not-null violation)',
    push.ok,
    'this is the regression from migration 0008',
  );

  const pull1 = await rpc('sync_pull', { last_pulled_at: cursor0 }, tokenA);
  const rawBack = pull1.body?.changes?.raw_materials?.updated?.[0];
  check('pushed rows come back on the next pull', !!rawBack, JSON.stringify(pull1.body?.changes?.raw_materials));
  check('server overwrote the spoofed created_at', rawBack && rawBack.created_at > 1_600_000_000_000, `got ${rawBack?.created_at}`);
  check('server applied the column default', rawBack && Number(rawBack.reorder_level_base) === 0, `got ${rawBack?.reorder_level_base}`);
  check('_status / _changed never reached the database', rawBack && !('_status' in rawBack) && !('_changed' in rawBack));

  console.log('\n4. Append-only');
  const del = await rpc('sync_push', { changes: { stock_ledger: { created: [], updated: [], deleted: [ledgerId] } }, last_pulled_at: null }, tokenA);
  check('deleting a ledger row is refused', !del.ok, JSON.stringify(del.body));

  const prof = await rpc('sync_push', { changes: { profiles: { created: [], updated: [{ id: randomUUID(), role: 'OWNER' }], deleted: [] } }, last_pulled_at: null }, tokenA);
  check('pushing to profiles is refused', !prof.ok, JSON.stringify(prof.body));

  console.log('\n5. Tenant isolation (second business, second session)');
  const tokenB = await session('B');
  await rpc('bootstrap_business', { p_business_name: 'Other Traders', p_owner_name: 'B' }, tokenB);

  const pullB = await rpc('sync_pull', { last_pulled_at: null }, tokenB);
  check('B sees exactly one business (its own)', pullB.body?.changes?.businesses?.updated?.length === 1);
  check('B sees none of A raw materials', pullB.body?.changes?.raw_materials?.updated?.length === 0);
  check('B sees none of A customers', pullB.body?.changes?.customers?.updated?.length === 0);
  check('B sees none of A ledger rows', pullB.body?.changes?.stock_ledger?.updated?.length === 0);

  const hijack = await rpc('sync_push', { changes: { raw_materials: { created: [], updated: [{ id: rawId, name: 'HIJACKED' }], deleted: [] } }, last_pulled_at: null }, tokenB);
  check('B cannot overwrite A row by id', !hijack.ok, JSON.stringify(hijack.body));

  const stillMine = await rpc('sync_pull', { last_pulled_at: cursor0 }, tokenA);
  check(
    'A row is untouched after the attempt',
    stillMine.body?.changes?.raw_materials?.updated?.[0]?.name === 'Cumin (bulk)',
    `got ${stillMine.body?.changes?.raw_materials?.updated?.[0]?.name}`,
  );

  console.log('\n6. Business operations');
  const skuId = randomUUID();
  await rpc('sync_push', { changes: { packed_skus: { created: [{ id: skuId, raw_material_id: rawId, name: 'Cumin 250g', pack_size_base: 250, sale_price: 60 }], updated: [], deleted: [] }, stock_ledger: { created: [{ id: randomUUID(), entry_type: 'PACK_IN', item_kind: 'PACKED', packed_sku_id: skuId, qty_base: 10, ref_type: 'PACKING_RUN' }], updated: [], deleted: [] } }, last_pulled_at: null }, tokenA);

  const orderId = randomUUID();
  const order = await rpc('create_order', { p_order_id: orderId, p_customer_id: custId, p_items: [{ packed_sku_id: skuId, qty_packets: 4 }] }, tokenA);
  check('create_order prices from the SKU', order.ok && order.body?.total_amount === 240, JSON.stringify(order.body));

  const before = await rpc('get_stock_snapshot', {}, tokenA);
  const packedBefore = Number(before.body?.packed?.find((p) => p.packed_sku_id === skuId)?.qty_packets);

  const disp = await rpc('dispatch_order', { p_order_id: orderId }, tokenA);
  check('dispatch_order succeeds', disp.ok && disp.body?.already_dispatched === false, JSON.stringify(disp.body));

  const after = await rpc('get_stock_snapshot', {}, tokenA);
  const packedAfter = Number(after.body?.packed?.find((p) => p.packed_sku_id === skuId)?.qty_packets);
  check('stock is deducted ON DISPATCH', packedBefore - packedAfter === 4, `${packedBefore} -> ${packedAfter}`);

  const disp2 = await rpc('dispatch_order', { p_order_id: orderId }, tokenA);
  const after2 = await rpc('get_stock_snapshot', {}, tokenA);
  const packedAfter2 = Number(after2.body?.packed?.find((p) => p.packed_sku_id === skuId)?.qty_packets);
  check('re-dispatch does not deduct twice', disp2.body?.already_dispatched === true && packedAfter2 === packedAfter, `${packedAfter} -> ${packedAfter2}`);

  console.log('\n7. Cash and the running khata');
  const pay1 = await rpc('record_payment', { p_payment_id: randomUUID(), p_customer_id: custId, p_amount: 100, p_order_id: orderId }, tokenA);
  check('partial payment leaves 140 outstanding', Number(pay1.body?.customer_outstanding) === 140, JSON.stringify(pay1.body));

  const pay2 = await rpc('record_payment', { p_payment_id: randomUUID(), p_customer_id: custId, p_amount: 140, p_order_id: orderId }, tokenA);
  check('balancing payment clears the khata', Number(pay2.body?.customer_outstanding) === 0, JSON.stringify(pay2.body));

  const receipt = await rpc('get_receipt', { p_order_id: orderId }, tokenA);
  check('order closed once fully paid', receipt.body?.order?.status === 'CLOSED', JSON.stringify(receipt.body?.order));
  check('receipt is a payment receipt, not a tax invoice', receipt.body?.document_type === 'PAYMENT_RECEIPT');

  console.log('\n8. GSTIN toggle is free and functional');
  // Set the precondition rather than assuming it. The test signs in as a
  // persistent seeded user now, so state survives between runs -- an earlier
  // run leaving the toggle on used to fail this.
  await rpc('update_business_settings', { p_gstin: '36ABCDE1234F1Z5', p_show_gstin_on_receipt: false }, tokenA);
  const receiptOff = await rpc('get_receipt', { p_order_id: orderId }, tokenA);
  check('GSTIN hidden while the toggle is off', receiptOff.body?.business?.gstin === null, JSON.stringify(receiptOff.body?.business));
  await rpc('update_business_settings', { p_gstin: '36ABCDE1234F1Z5', p_show_gstin_on_receipt: true }, tokenA);
  const receipt2 = await rpc('get_receipt', { p_order_id: orderId }, tokenA);
  check('GSTIN shown once the toggle is on', receipt2.body?.business?.gstin === '36ABCDE1234F1Z5', JSON.stringify(receipt2.body?.business));


  // =========================================================================
  // The read layer (migration 0017). Added when offline sync was removed: the
  // app no longer has a local replica, so these functions ARE the data path.
  // =========================================================================
  console.log('\n9. The read layer');

  const ctx = await rpc('get_my_context', {}, tokenA);
  check('get_my_context reports an active membership',
    ctx.body?.membership_state === 'ACTIVE' && ctx.body?.profile?.role === 'OWNER',
    JSON.stringify(ctx.body?.membership_state));
  check('get_my_context carries the business, seats and contract',
    !!ctx.body?.business?.id && typeof ctx.body?.seats?.limit === 'number'
      && typeof ctx.body?.contract?.min_client === 'number',
    JSON.stringify({ seats: ctx.body?.seats, contract: ctx.body?.contract }));
  check('get_my_context decides read-only server-side',
    typeof ctx.body?.is_read_only === 'boolean',
    `got ${typeof ctx.body?.is_read_only}`);
  check('the packing feature flag is readable',
    typeof ctx.body?.business?.features?.packing === 'boolean',
    JSON.stringify(ctx.body?.business?.features));

  // A signed-in user with no profile must get an answer, not an error. The app
  // routes to the claim-invite screen on this value; the Phase 0 screen used to
  // string-match a server error message to decide the same thing.
  const strangerEmail = `stranger-${Date.now()}@dukaan-contract-test.com`;
  await api('/auth/v1/signup', { body: { email: strangerEmail, password: 'devpassword123' } });
  const strangerAuth = await api('/auth/v1/token?grant_type=password',
    { body: { email: strangerEmail, password: 'devpassword123' } });
  const strangerToken = strangerAuth.body?.access_token;
  if (strangerToken) {
    const sCtx = await rpc('get_my_context', {}, strangerToken);
    check('a user with no membership gets NONE, not an error',
      sCtx.ok && sCtx.body?.membership_state === 'NONE' && sCtx.body?.profile === null,
      `${sCtx.status} ${JSON.stringify(sCtx.body?.membership_state)}`);
    const sList = await rpc('list_orders', {}, strangerToken);
    check('...but cannot read any tenant data', !sList.ok, `got ${sList.status}`);
  } else {
    check('a user with no membership gets NONE, not an error', false,
      `could not create a throwaway user: ${JSON.stringify(strangerAuth.body)}`);
    check('...but cannot read any tenant data', false, 'skipped');
  }

  const READS = [
    ['list_customers', {}], ['list_suppliers', {}],
    ['list_raw_materials', {}], ['list_packed_skus', {}],
    ['list_orders', {}], ['list_purchases', {}], ['list_packing_runs', {}],
    ['list_payments', {}], ['list_customer_balances', { p_only_outstanding: false }],
    ['list_stock_ledger', {}], ['list_members', {}],
    ['get_stock_snapshot', {}], ['get_day_summary', {}],
    ['get_order', { p_order_id: orderId }],
    ['get_customer_ledger', { p_customer_id: custId }],
  ];
  let readsOk = true;
  const readFailures = [];
  for (const [fn, args] of READS) {
    const r = await rpc(fn, args, tokenA);
    if (!r.ok) { readsOk = false; readFailures.push(`${fn}: ${r.status} ${JSON.stringify(r.body)}`); }
  }
  check('every read RPC answers an owner', readsOk, readFailures.join('\n        '));

  const paged = await rpc('list_orders', { p_limit: 1 }, tokenA);
  check('paginated reads return a {rows, has_more, limit, offset} envelope',
    Array.isArray(paged.body?.rows) && typeof paged.body?.has_more === 'boolean'
      && paged.body?.limit === 1,
    JSON.stringify(paged.body?.limit));

  const clampHi = await rpc('list_orders', { p_limit: 9999 }, tokenA);
  const clampLo = await rpc('list_orders', { p_limit: -5, p_offset: -9 }, tokenA);
  check('a hostile limit is clamped, not obeyed',
    clampHi.body?.limit === 200 && clampLo.body?.limit === 1 && clampLo.body?.offset === 0,
    JSON.stringify({ hi: clampHi.body?.limit, lo: clampLo.body?.limit, off: clampLo.body?.offset }));

  // Timestamps stopped being epoch-ms when app.to_wire() left the read path.
  // A build that still did new Date(number) would silently render 1970.
  const ordersRows = (await rpc('list_orders', {}, tokenA)).body?.rows ?? [];
  check('timestamps cross the wire as ISO strings, not epoch-ms',
    ordersRows.length > 0 && typeof ordersRows[0].placed_at === 'string'
      && !Number.isNaN(Date.parse(ordersRows[0].placed_at)),
    `got ${typeof ordersRows[0]?.placed_at}: ${ordersRows[0]?.placed_at}`);

  // The invariant the whole security model rests on: the tenant key is never in
  // a payload, so a client can neither read it nor learn another one exists.
  function findKey(node, key) {
    if (Array.isArray(node)) return node.some((n) => findKey(n, key));
    if (node && typeof node === 'object') {
      return Object.keys(node).some((k) => k === key || findKey(node[k], key));
    }
    return false;
  }
  const leaked = [];
  for (const [fn, args] of READS) {
    const r = await rpc(fn, args, tokenA);
    if (r.ok && findKey(r.body, 'business_id')) leaked.push(fn);
  }
  check('no read payload anywhere contains business_id', leaked.length === 0, leaked.join(', '));

  // get_order hands the client the legal next actions, so no screen re-derives
  // the state machine. The order is CLOSED by section 7.
  const closedOrder = await rpc('get_order', { p_order_id: orderId }, tokenA);
  check('get_order returns allowed_transitions',
    Array.isArray(closedOrder.body?.allowed_transitions),
    JSON.stringify(closedOrder.body?.allowed_transitions));
  check('a closed order offers no further transitions',
    closedOrder.body?.allowed_transitions?.length === 0,
    JSON.stringify(closedOrder.body?.allowed_transitions));
  // Cancel is withheld once stock has left, because no reversal RPC exists yet
  // and set_order_status(CANCELLED) would strand the SALE_OUT ledger rows.
  check('a dispatched order never offers cancel',
    !closedOrder.body?.allowed_transitions?.includes('cancel'),
    JSON.stringify(closedOrder.body?.allowed_transitions));

  // =========================================================================
  console.log('\n10. Role enforcement over the wire');
  const tokenP = await session('P');

  const packerCtx = await rpc('get_my_context', {}, tokenP);
  check('the packer is a PACKER in business A',
    packerCtx.body?.profile?.role === 'PACKER' && packerCtx.body?.membership_state === 'ACTIVE',
    JSON.stringify(packerCtx.body?.profile));

  const PACKER_ALLOWED = [
    ['list_orders', {}], ['get_stock_snapshot', {}],
    ['list_raw_materials', {}], ['list_packed_skus', {}],
    ['list_packing_runs', {}], ['get_day_summary', {}],
  ];
  const PACKER_REFUSED = [
    ['list_purchases', {}], ['list_suppliers', {}], ['list_payments', {}],
    ['list_customer_balances', {}], ['list_stock_ledger', {}], ['list_members', {}],
    ['create_order', { p_order_id: randomUUID(), p_customer_id: custId, p_items: [] }],
    ['upsert_raw_material', { p_id: randomUUID(), p_name: 'Nope' }],
    ['invite_member', { p_invite_id: randomUUID(), p_role: 'OWNER', p_phone: '9000000000' }],
    ['record_stock_adjustment', { p_entry_id: randomUUID(), p_item_kind: 'RAW', p_item_id: rawId, p_mode: 'SET', p_qty: 1 }],
  ];
  const wronglyRefused = [];
  for (const [fn, args] of PACKER_ALLOWED) {
    const r = await rpc(fn, args, tokenP);
    if (!r.ok) wronglyRefused.push(`${fn} -> ${r.status}`);
  }
  check('a packer can read what the job needs', wronglyRefused.length === 0, wronglyRefused.join(', '));

  const wronglyAllowed = [];
  for (const [fn, args] of PACKER_REFUSED) {
    const r = await rpc(fn, args, tokenP);
    if (r.ok) wronglyAllowed.push(fn);
  }
  check('a packer is refused costs, cash, the khata and the roster',
    wronglyAllowed.length === 0, `allowed: ${wronglyAllowed.join(', ')}`);

  // =========================================================================
  console.log('\n11. Staff management and the seat cap');
  const roster = await rpc('list_members', {}, tokenA);
  check('list_members returns members, invites and seats',
    Array.isArray(roster.body?.members) && Array.isArray(roster.body?.invites)
      && typeof roster.body?.seats?.limit === 'number',
    JSON.stringify(roster.body?.seats));

  const inviteId = randomUUID();
  const seatsBefore = roster.body?.seats?.used;
  const inv = await rpc('invite_member',
    { p_invite_id: inviteId, p_role: 'DELIVERY', p_phone: '9000012345' }, tokenA);
  check('invite_member issues a 64-char token',
    inv.ok && typeof inv.body?.invite_token === 'string' && inv.body.invite_token.length === 64,
    JSON.stringify(inv.body));

  const invRetry = await rpc('invite_member',
    { p_invite_id: inviteId, p_role: 'DELIVERY', p_phone: '9000012345' }, tokenA);
  check('re-issuing the same invite id is idempotent',
    invRetry.body?.created === false && invRetry.body?.invite_token === inv.body?.invite_token,
    JSON.stringify(invRetry.body));

  // The bug this fixes: seats were counted against active profiles only, so a
  // pending invite reserved nothing and an owner could over-issue. The failure
  // then landed on the new hire's phone, at the worst possible moment.
  const rosterAfter = await rpc('list_members', {}, tokenA);
  check('a pending invite reserves a seat',
    rosterAfter.body?.seats?.used === seatsBefore + 1,
    `${seatsBefore} -> ${rosterAfter.body?.seats?.used}`);

  const spare = rosterAfter.body?.seats?.available ?? 0;
  const filler = [];
  for (let i = 0; i < spare; i += 1) {
    const id = randomUUID();
    const r = await rpc('invite_member', { p_invite_id: id, p_role: 'PACKER', p_phone: `90000999${i}` }, tokenA);
    if (r.ok) filler.push(id);
  }
  const overCap = await rpc('invite_member',
    { p_invite_id: randomUUID(), p_role: 'PACKER', p_phone: '9000099999' }, tokenA);
  check('inviting past the seat cap is refused',
    !overCap.ok && overCap.body?.hint === 'seat_limit',
    `${overCap.status} ${JSON.stringify(overCap.body)}`);

  const rev = await rpc('revoke_member_invite', { p_invite_id: inviteId }, tokenA);
  check('revoke_member_invite frees the seat again', rev.ok && rev.body?.revoked === true,
    JSON.stringify(rev.body));
  for (const id of filler) await rpc('revoke_member_invite', { p_invite_id: id }, tokenA);

  const selfId = ctx.body?.profile?.user_id;
  const demote = await rpc('set_member_role', { p_user_id: selfId, p_role: 'PACKER' }, tokenA);
  check('the last owner cannot be demoted',
    !demote.ok && demote.body?.hint === 'last_owner', JSON.stringify(demote.body));
  const deact = await rpc('set_member_active', { p_user_id: selfId, p_is_active: false }, tokenA);
  check('you cannot deactivate your own account',
    !deact.ok && deact.body?.hint === 'self_deactivate', JSON.stringify(deact.body));

  // =========================================================================
  console.log('\n12. Opening stock and adjustments');
  const onHandOf = async (id) => {
    const r = await rpc('list_raw_materials', {}, tokenA);
    return Number(r.body?.find((m) => m.id === id)?.qty_base ?? 0);
  };
  const adjRaw = randomUUID();
  await rpc('upsert_raw_material', { p_id: adjRaw, p_name: `Adj Test ${Date.now()}` }, tokenA);

  const openId = randomUUID();
  const opened = await rpc('record_stock_adjustment',
    { p_entry_id: openId, p_item_kind: 'RAW', p_item_id: adjRaw,
      p_mode: 'SET', p_qty: 5000, p_entry_type: 'OPENING', p_note: 'opening count' }, tokenA);
  check('opening stock can be entered at all',
    opened.ok && Number(opened.body?.qty_after) === 5000 && opened.body?.created === true,
    JSON.stringify(opened.body));
  check('opening stock reaches the stock read', (await onHandOf(adjRaw)) === 5000);

  const openRetry = await rpc('record_stock_adjustment',
    { p_entry_id: openId, p_item_kind: 'RAW', p_item_id: adjRaw,
      p_mode: 'SET', p_qty: 5000, p_entry_type: 'OPENING' }, tokenA);
  check('a retried adjustment does not double-count',
    openRetry.body?.created === false && (await onHandOf(adjRaw)) === 5000,
    JSON.stringify(openRetry.body));

  // SET is how a person records a stock-take: they type what they counted and
  // the server works out the signed delta.
  const counted = await rpc('record_stock_adjustment',
    { p_entry_id: randomUUID(), p_item_kind: 'RAW', p_item_id: adjRaw,
      p_mode: 'SET', p_qty: 4850, p_note: 'counted' }, tokenA);
  check('SET mode derives the delta from a counted quantity',
    Number(counted.body?.delta) === -150 && Number(counted.body?.qty_after) === 4850,
    JSON.stringify(counted.body));

  const noop = await rpc('record_stock_adjustment',
    { p_entry_id: randomUUID(), p_item_kind: 'RAW', p_item_id: adjRaw, p_mode: 'SET', p_qty: 4850 }, tokenA);
  check('a count that matches the books is a no-op, not an error',
    noop.ok && Number(noop.body?.delta) === 0 && noop.body?.created === false,
    JSON.stringify(noop.body));

  const tooFar = await rpc('record_stock_adjustment',
    { p_entry_id: randomUUID(), p_item_kind: 'RAW', p_item_id: adjRaw, p_mode: 'DELTA', p_qty: -99999 }, tokenA);
  check('stock cannot be driven negative', !tooFar.ok, JSON.stringify(tooFar.body));

  const twice = await rpc('record_stock_adjustment',
    { p_entry_id: randomUUID(), p_item_kind: 'RAW', p_item_id: adjRaw,
      p_mode: 'SET', p_qty: 10, p_entry_type: 'OPENING' }, tokenA);
  check('a second opening balance is refused', !twice.ok && twice.body?.hint === 'use_adjustment',
    JSON.stringify(twice.body));

  const smuggle = await rpc('record_stock_adjustment',
    { p_entry_id: randomUUID(), p_item_kind: 'RAW', p_item_id: adjRaw,
      p_mode: 'DELTA', p_qty: 500, p_entry_type: 'PURCHASE_IN' }, tokenA);
  check('a movement that belongs to an operation cannot be hand-posted', !smuggle.ok,
    JSON.stringify(smuggle.body));

  const crossTenant = await rpc('record_stock_adjustment',
    { p_entry_id: randomUUID(), p_item_kind: 'RAW', p_item_id: adjRaw, p_mode: 'SET', p_qty: 1 }, tokenB);
  check('B cannot adjust A stock', !crossTenant.ok, `${crossTenant.status} ${JSON.stringify(crossTenant.body)}`);

  const audit = await rpc('list_stock_ledger', { p_raw_material_id: adjRaw }, tokenA);
  check('every adjustment is visible in the ledger audit trail',
    audit.body?.rows?.length === 2
      && audit.body.rows.some((r) => r.entry_type === 'OPENING')
      && audit.body.rows.some((r) => r.entry_type === 'ADJUSTMENT'),
    JSON.stringify(audit.body?.rows?.map((r) => `${r.entry_type}:${r.qty_base}`)));
  await rpc('archive_master', { p_table: 'raw_materials', p_id: adjRaw }, tokenA);


  // =========================================================================
  // Cleanup.
  //
  // This suite signs in as a PERSISTENT seeded user, so anything it creates
  // stays in the dev tenant after it exits. Thirteen runs left thirteen
  // "Cumin (bulk)" rows, thirteen "Cumin 250g" SKUs and thirteen "Contract
  // Test Customer" rows, which made the stock screen unreadable on a device
  // and the seeded state impossible to recognise.
  //
  // Archiving is soft, which is the only kind of delete this system has: the
  // append-only ledger rows behind these fixtures stay, and the orders that
  // reference them still render, because the read RPCs join packed_skus and
  // customers without filtering deleted_at. They just stop appearing in
  // pickers and lists -- exactly what archiving is for.
  //
  // The orders and payments themselves cannot be removed and are not meant to
  // be; they are history, and a handful of them makes the dev tenant more
  // useful to test against rather than less.
  // =========================================================================
  console.log('\n13. Cleanup');
  {
    const archived = [];
    const failed = [];
    for (const [table, id] of [
      ['packed_skus', skuId],
      ['raw_materials', rawId],
      ['customers', custId],
    ]) {
      const res = await rpc('archive_master', { p_table: table, p_id: id }, tokenA);
      if (res.ok && res.body?.archived) archived.push(table);
      else failed.push(`${table}: ${res.status} ${JSON.stringify(res.body)}`);
    }
    check(
      'the fixtures this run created are archived, not left behind',
      failed.length === 0,
      failed.join('; '),
    );
    console.log(`  note  archived ${archived.join(', ')}`);
  }

  console.log(`\n${passed} passed, ${failed} failed\n`);
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error('\nContract test aborted:', error.message);
  process.exit(1);
});
