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
  // Shared by section 9 (get_supplier must answer an owner) and section 18.
  const supId = randomUUID();

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

  // get_supplier needs a supplier to answer about. Created here so the read
  // registry below can exercise it; section 18 then buys from it.
  await rpc('upsert_supplier',
    { p_id: supId, p_name: 'Contract Test Spice Traders', p_phone: '9800000011' }, tokenA);

  const READS = [
    ['list_customers', {}], ['list_suppliers', {}],
    ['list_raw_materials', {}], ['list_packed_skus', {}],
    ['list_orders', {}], ['list_purchases', {}], ['list_packing_runs', {}],
    ['list_payments', {}], ['list_customer_balances', { p_only_outstanding: false }],
    ['list_stock_ledger', {}], ['list_members', {}],
    ['get_stock_snapshot', {}], ['get_day_summary', {}],
    ['get_order', { p_order_id: orderId }],
    ['get_customer_ledger', { p_customer_id: custId }],
    ['list_due_orders', {}],
    ['list_customer_prices', { p_customer_id: custId }],
    ['get_supplier', { p_supplier_id: supId }],
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
    ['list_due_orders', {}],
    ['set_order_due_date', { p_order_id: orderId, p_due_on: null }],
    ['set_customer_credit_days', { p_customer_id: custId, p_credit_days: 30 }],
    ['set_default_credit_days', { p_credit_days: 30 }],
    ['list_customer_prices', { p_customer_id: custId }],
    ['set_customer_price', { p_customer_id: custId, p_packed_sku_id: skuId, p_price: 1 }],
    // The buying side, all OWNER-only since 0026.
    ['get_supplier', { p_supplier_id: supId }],
    ['upsert_supplier', { p_id: randomUUID(), p_name: 'Nope' }],
    ['create_purchase', { p_purchase_id: randomUUID(), p_supplier_id: supId, p_items: [] }],
    ['update_purchase', { p_purchase_id: randomUUID(), p_supplier_id: supId, p_items: [] }],
    ['record_purchase_payment', { p_payment_id: randomUUID(), p_purchase_id: randomUUID(), p_amount: 1 }],
    ['cancel_purchase', { p_purchase_id: randomUUID() }],
    ['set_purchase_due_date', { p_purchase_id: randomUUID(), p_due_on: null }],
    ['archive_master', { p_table: 'suppliers', p_id: supId }],
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
  // =========================================================================
  // 12b. Account payments settle orders, oldest first (migration 0021).
  //
  // Cash taken on the khata carries no order_id. Before 0021 it lowered the
  // outstanding and counted against nothing, so an owner who was paid in full
  // still saw every order "unpaid". Each order's paid/balance is now derived:
  // account credit covers the oldest live orders first.
  //
  // A fresh customer, so the arithmetic below starts from zero.
  // =========================================================================
  console.log('\n12b. Account payments settle orders, oldest first');
  const allocCust = randomUUID();
  {
    await rpc('upsert_customer', { p_id: allocCust, p_name: `Alloc Test ${Date.now()}` }, tokenA);
    // Packets to sell. Section 6 left only a few.
    await rpc('record_stock_adjustment',
      { p_entry_id: randomUUID(), p_item_kind: 'PACKED', p_item_id: skuId,
        p_mode: 'DELTA', p_qty: 20, p_note: 'allocation test stock' }, tokenA);

    const mkOrder = async (packets) => {
      const id = randomUUID();
      const r = await rpc('create_order',
        { p_order_id: id, p_customer_id: allocCust, p_items: [{ packed_sku_id: skuId, qty_packets: packets }] }, tokenA);
      return { id, no: r.body?.order_no, total: Number(r.body?.total_amount) };
    };
    const deliver = async (id) => {
      await rpc('dispatch_order', { p_order_id: id }, tokenA);
      return rpc('set_order_status', { p_order_id: id, p_status: 'DELIVERED' }, tokenA);
    };
    const pay = (amount, orderId = null) => rpc('record_payment',
      { p_payment_id: randomUUID(), p_customer_id: allocCust, p_amount: amount, p_order_id: orderId }, tokenA);
    const orders = async () => {
      const r = await rpc('list_orders', { p_customer_id: allocCust, p_limit: 200 }, tokenA);
      return new Map((r.body?.rows ?? []).map((o) => [o.id, o]));
    };
    const outstanding = async () => {
      const r = await rpc('get_customer_ledger', { p_customer_id: allocCust }, tokenA);
      return Number(r.body?.balance?.outstanding);
    };
    // The invariant the whole design rests on.
    const balancesMatchKhata = async (label) => {
      const sum = [...(await orders()).values()].reduce((s, o) => s + Number(o.balance), 0);
      const out = await outstanding();
      check(`order balances add up to the khata (${label})`, sum === Math.max(out, 0), `Σ=${sum} khata=${out}`);
    };

    // A (₹120) is older than B (₹180). Both delivered, both unpaid.
    const A = await mkOrder(2);
    const B = await mkOrder(3);
    await deliver(A.id);
    await deliver(B.id);

    const p1 = await pay(200);
    let o = await orders();
    check('an account payment closes the oldest order it covers',
      o.get(A.id)?.status === 'CLOSED' && Number(o.get(A.id)?.balance) === 0,
      JSON.stringify(o.get(A.id)));
    check('the rest of it part-pays the next order, which stays DELIVERED',
      o.get(B.id)?.status === 'DELIVERED' && Number(o.get(B.id)?.balance) === 100
        && Number(o.get(B.id)?.paid_from_account) === 80,
      JSON.stringify(o.get(B.id)));
    check('record_payment reports which orders it settled',
      JSON.stringify(p1.body?.settled_orders) === JSON.stringify([A.no]), JSON.stringify(p1.body));
    await balancesMatchKhata('after a part payment');

    const p2 = await pay(100);
    o = await orders();
    check('a second account payment settles the next order',
      o.get(B.id)?.status === 'CLOSED' && JSON.stringify(p2.body?.settled_orders) === JSON.stringify([B.no]),
      JSON.stringify({ b: o.get(B.id), p2: p2.body }));

    // The bug 0021 fixed: paying up front used to CLOSE a PLACED order, so it
    // skipped packing and dispatch entirely.
    const C = await mkOrder(1);
    await pay(60, C.id);
    const cAfterPay = await rpc('get_order', { p_order_id: C.id }, tokenA);
    check('a prepaid order stays PLACED -- money does not skip packing',
      cAfterPay.body?.order?.status === 'PLACED' && Number(cAfterPay.body?.balance) === 0,
      JSON.stringify(cAfterPay.body?.order));
    check('a fully prepaid order does not offer record_payment',
      !(cAfterPay.body?.allowed_transitions ?? []).includes('record_payment'),
      JSON.stringify(cAfterPay.body?.allowed_transitions));
    await rpc('set_order_status', { p_order_id: C.id, p_status: 'PACKED' }, tokenA);
    const cDelivered = await deliver(C.id);
    check('a prepaid order closes when it is delivered',
      cDelivered.body?.status === 'CLOSED', JSON.stringify(cDelivered.body));

    // Overpaying one order carries the excess to the next oldest.
    const D = await mkOrder(1);
    const E = await mkOrder(1);
    await deliver(D.id);
    await deliver(E.id);
    await pay(100, D.id);
    o = await orders();
    check('overpayment on one order flows to the next oldest',
      o.get(D.id)?.status === 'CLOSED' && Number(o.get(E.id)?.balance) === 20
        && Number(o.get(E.id)?.paid_from_account) === 40,
      JSON.stringify({ d: o.get(D.id), e: o.get(E.id) }));
    await balancesMatchKhata('after an overpayment');

    // Cancelling a prepaid order hands its money back to the account, where
    // it settles E.
    const F = await mkOrder(1);
    await pay(60, F.id);
    const cancelled = await rpc('set_order_status', { p_order_id: F.id, p_status: 'CANCELLED' }, tokenA);
    o = await orders();
    check('cancelling returns its payment to the account, settling an older order',
      o.get(E.id)?.status === 'CLOSED'
        && JSON.stringify(cancelled.body?.settled_orders) === JSON.stringify([E.no]),
      JSON.stringify({ e: o.get(E.id), cancel: cancelled.body }));
    check('the leftover is credit on the khata', (await outstanding()) === -40, String(await outstanding()));

    const wrong = await rpc('record_payment',
      { p_payment_id: randomUUID(), p_customer_id: allocCust, p_amount: 10, p_order_id: orderId }, tokenA);
    check("a payment cannot be linked to another customer's order",
      wrong.status >= 400 && wrong.body?.code === '22023', JSON.stringify(wrong.body));
  }

  // =========================================================================
  // 14. Credit terms and due dates (migration 0022).
  //
  // due_on is stamped from the customer's terms (else the shop's) when the
  // goods have gone; overdue is derived from the order's balance, so settling
  // an order clears it. "Today" is the Indian calendar date.
  // =========================================================================
  console.log('\n14. Credit terms and due dates');
  // app.local_today() is Asia/Kolkata, not UTC, so the dates these sections
  // expect have to be too. Declared out here rather than inside section 14
  // because section 18 needs the same calendar for purchase due dates.
  const istDay = (offsetDays = 0) => {
    const d = new Date(Date.now() + 5.5 * 3600 * 1000);
    d.setUTCDate(d.getUTCDate() + offsetDays);
    return d.toISOString().slice(0, 10);
  };
  const dueCust = randomUUID();
  const plainCust = randomUUID();
  const defaultCust = randomUUID();
  // Shared with section 15.
  let dueX = null;
  let dueY = null;
  let yPaymentId = null;
  {
    await rpc('record_stock_adjustment',
      { p_entry_id: randomUUID(), p_item_kind: 'PACKED', p_item_id: skuId,
        p_mode: 'DELTA', p_qty: 20, p_note: 'due-date test stock' }, tokenA);
    const mk = async (customer) => {
      const id = randomUUID();
      await rpc('create_order',
        { p_order_id: id, p_customer_id: customer, p_items: [{ packed_sku_id: skuId, qty_packets: 1 }] }, tokenA);
      await rpc('dispatch_order', { p_order_id: id }, tokenA);
      return id;
    };
    const getOrder = async (id, token = tokenA) => (await rpc('get_order', { p_order_id: id }, token)).body;
    const dueList = async (scope) =>
      (await rpc('list_due_orders', { p_scope: scope, p_limit: 200 }, tokenA)).body;

    await rpc('upsert_customer', { p_id: dueCust, p_name: `Due Test ${Date.now()}` }, tokenA);
    const terms = await rpc('set_customer_credit_days', { p_customer_id: dueCust, p_credit_days: 30 }, tokenA);
    check('an owner can give a customer 30 days credit',
      terms.ok && terms.body?.credit_days === 30, JSON.stringify(terms.body));

    const badTerms = await rpc('set_customer_credit_days', { p_customer_id: dueCust, p_credit_days: 400 }, tokenA);
    check('credit days outside 0..365 are refused', badTerms.body?.code === '22023', JSON.stringify(badTerms.body));

    dueX = await mk(dueCust);
    await rpc('set_order_status', { p_order_id: dueX, p_status: 'DELIVERED' }, tokenA);
    let x = await getOrder(dueX);
    check('delivery stamps due_on = delivery date + the customer\'s terms',
      x?.order?.due_on === istDay(30), `${x?.order?.due_on} vs ${istDay(30)}`);
    check('a future due date reads UPCOMING, with days to go',
      x?.due_state === 'UPCOMING' && x?.due_in_days === 30, JSON.stringify([x?.due_state, x?.due_in_days]));
    check('a delivered unpaid order offers set_due_date',
      (x?.allowed_transitions ?? []).includes('set_due_date'), JSON.stringify(x?.allowed_transitions));

    // The door path: cash at the door moves OUT_FOR_DELIVERY -> PAYMENT_PENDING
    // without ever setting delivered_at. The trigger still has to date it.
    dueY = await mk(dueCust);
    yPaymentId = randomUUID();
    await rpc('record_payment',
      { p_payment_id: yPaymentId, p_customer_id: dueCust, p_amount: 10, p_order_id: dueY }, tokenA);
    const y = await getOrder(dueY);
    check('a part payment at the door also stamps the due date',
      y?.order?.status === 'PAYMENT_PENDING' && y?.order?.due_on === istDay(30),
      JSON.stringify(y?.order));

    const moved = await rpc('set_order_due_date', { p_order_id: dueX, p_due_on: istDay(-3) }, tokenA);
    x = await getOrder(dueX);
    check('the owner can move one order\'s due date',
      moved.ok && x?.order?.due_on === istDay(-3), JSON.stringify(moved.body));
    check('a passed due date reads OVERDUE, with negative days',
      x?.due_state === 'OVERDUE' && x?.due_in_days === -3, JSON.stringify([x?.due_state, x?.due_in_days]));

    await rpc('set_order_due_date', { p_order_id: dueY, p_due_on: istDay(0) }, tokenA);
    check('a due date of today reads DUE_TODAY', (await getOrder(dueY))?.due_state === 'DUE_TODAY');

    const overdue = await dueList('OVERDUE');
    const today = await dueList('DUE_TODAY');
    check('list_due_orders scopes overdue and due-today orders',
      overdue?.rows?.some((r) => r.id === dueX) && !overdue?.rows?.some((r) => r.id === dueY)
        && today?.rows?.some((r) => r.id === dueY),
      JSON.stringify({ overdue: overdue?.rows?.length, today: today?.rows?.length }));
    check('list_due_orders carries a summary for the chips',
      overdue?.summary?.overdue?.count >= 1 && overdue?.summary?.due_today?.count >= 1,
      JSON.stringify(overdue?.summary));
    const unknownScope = await rpc('list_due_orders', { p_scope: 'LATE' }, tokenA);
    check('an unknown scope is refused', unknownScope.body?.code === '22023', JSON.stringify(unknownScope.body));

    const day = (await rpc('get_day_summary', {}, tokenA)).body;
    check('the home summary counts overdue and due-today',
      day?.overdue_count >= 1 && Number(day?.overdue_amount) > 0 && day?.due_today_count >= 1,
      JSON.stringify(day));

    const bal = (await rpc('list_customer_balances', { p_search: 'Due Test', p_limit: 200 }, tokenA)).body;
    const xBalance = Number(x?.balance);
    check('the khata list shows each customer\'s overdue amount',
      Number(bal?.rows?.find((r) => r.customer_id === dueCust)?.overdue_amount) === xBalance,
      JSON.stringify(bal?.rows?.find((r) => r.customer_id === dueCust)));

    const bSees = await rpc('list_due_orders', { p_limit: 200 }, tokenB);
    check('B never sees A\'s due orders',
      bSees.ok && !bSees.body?.rows?.some((r) => r.id === dueX || r.id === dueY), `${bSees.status}`);
    const bMoves = await rpc('set_order_due_date', { p_order_id: dueX, p_due_on: istDay(90) }, tokenB);
    check('B cannot move A\'s due date', !bMoves.ok && (await getOrder(dueX))?.order?.due_on === istDay(-3),
      JSON.stringify(bMoves.body));

    // Overdue is derived: account cash settles the oldest order (X) first,
    // and X stops being overdue without anyone touching its date.
    await rpc('record_payment',
      { p_payment_id: randomUUID(), p_customer_id: dueCust, p_amount: xBalance }, tokenA);
    x = await getOrder(dueX);
    check('settling an overdue order clears its overdue state',
      x?.order?.status === 'CLOSED' && x?.due_state === null && x?.order?.due_on === istDay(-3),
      JSON.stringify({ status: x?.order?.status, state: x?.due_state }));
    check('...and it leaves the Due list', !(await dueList('OVERDUE'))?.rows?.some((r) => r.id === dueX));

    const closedMove = await rpc('set_order_due_date', { p_order_id: dueX, p_due_on: istDay(5) }, tokenA);
    check('a closed order has no due date to move',
      closedMove.body?.code === '22023' && closedMove.body?.hint === 'not_due', JSON.stringify(closedMove.body));

    await rpc('set_order_due_date', { p_order_id: dueY, p_due_on: null }, tokenA);
    const yCleared = await getOrder(dueY);
    check('clearing a due date takes the order off the Due list',
      yCleared?.order?.due_on === null && yCleared?.due_state === null
        && !(await dueList(null))?.rows?.some((r) => r.id === dueY),
      JSON.stringify(yCleared?.order));

    // No terms, no date -- then terms arrive and the open debt is dated.
    await rpc('upsert_customer', { p_id: plainCust, p_name: `No Terms ${Date.now()}` }, tokenA);
    const z = await mk(plainCust);
    await rpc('set_order_status', { p_order_id: z, p_status: 'DELIVERED' }, tokenA);
    check('with no terms anywhere, delivery sets no due date',
      (await getOrder(z))?.order?.due_on === null);
    const late = await rpc('set_customer_credit_days', { p_customer_id: plainCust, p_credit_days: 15 }, tokenA);
    check('setting terms later dates the customer\'s open orders',
      late.body?.orders_dated === 1 && (await getOrder(z))?.order?.due_on === istDay(15),
      JSON.stringify(late.body));

    // The shop default, for customers with no terms of their own.
    const before = (await rpc('get_my_context', {}, tokenA)).body?.business?.default_credit_days ?? null;
    await rpc('upsert_customer', { p_id: defaultCust, p_name: `Default Terms ${Date.now()}` }, tokenA);
    const setDefault = await rpc('set_default_credit_days', { p_credit_days: 7 }, tokenA);
    const ctxAfter = (await rpc('get_my_context', {}, tokenA)).body;
    check('the owner can set a shop-wide default',
      setDefault.ok && ctxAfter?.business?.default_credit_days === 7, JSON.stringify(setDefault.body));
    const w = await mk(defaultCust);
    await rpc('set_order_status', { p_order_id: w, p_status: 'DELIVERED' }, tokenA);
    check('a customer without terms gets the shop default',
      (await getOrder(w))?.order?.due_on === istDay(7));
    check('...while a customer with terms keeps theirs',
      (await getOrder(z))?.order?.due_on === istDay(15));
    await rpc('set_default_credit_days', { p_credit_days: before }, tokenA);
  }

  // =========================================================================
  // 15. Voucher photo RPCs (migration 0023). OWNER only, for everything.
  //
  // These are the database half. The bytes go through the Worker in
  // mydukaan-cloudflare, which has its own HTTP test.
  // =========================================================================
  console.log('\n15. Voucher photo RPCs');
  {
    const photo = randomUUID();
    const auth = await rpc('authorize_voucher_upload', { p_photo_id: photo, p_order_id: dueY }, tokenA);
    check('authorize_voucher_upload returns a key scoped to the order',
      auth.ok && auth.body?.object_key === `v1/${dueY}/${photo}.jpg` && auth.body?.already_uploaded === false,
      JSON.stringify(auth.body));

    const attach = (args, token = tokenA) => rpc('attach_voucher_photo',
      { p_photo_id: photo, p_order_id: dueY, p_payment_id: yPaymentId, p_size_bytes: 1234,
        p_width: 1200, p_height: 1600, ...args }, token);
    const first = await attach({});
    const again = await attach({});
    check('attach_voucher_photo is idempotent on the photo id',
      first.body?.created === true && again.body?.created === false,
      JSON.stringify([first.body, again.body]));
    const reauth = await rpc('authorize_voucher_upload', { p_photo_id: photo, p_order_id: dueY }, tokenA);
    check('a retried upload is told the photo is already there',
      reauth.body?.already_uploaded === true, JSON.stringify(reauth.body));

    const y = (await rpc('get_order', { p_order_id: dueY }, tokenA)).body;
    check('get_order lists the voucher for the owner, with its payment',
      y?.vouchers?.length === 1 && y.vouchers[0].id === photo && Number(y.vouchers[0].payment_amount) === 10,
      JSON.stringify(y?.vouchers));
    const ledger = (await rpc('get_customer_ledger', { p_customer_id: dueCust }, tokenA)).body;
    check('the khata counts vouchers per payment',
      ledger?.payments?.rows?.find((p) => p.id === yPaymentId)?.voucher_count === 1);
    const view = await rpc('get_voucher_photo', { p_photo_id: photo }, tokenA);
    check('get_voucher_photo answers the owner with the object key',
      view.ok && view.body?.object_key === auth.body?.object_key, JSON.stringify(view.body));

    const wrongPay = await rpc('attach_voucher_photo',
      { p_photo_id: randomUUID(), p_order_id: dueX, p_payment_id: yPaymentId, p_size_bytes: 10 }, tokenA);
    check('a payment from a different order is refused', wrongPay.body?.code === '22023', JSON.stringify(wrongPay.body));
    const empty = await rpc('attach_voucher_photo',
      { p_photo_id: randomUUID(), p_order_id: dueY, p_size_bytes: 0 }, tokenA);
    check('an empty photo is refused', empty.body?.code === '22023', JSON.stringify(empty.body));

    // Staff never see the feature: the packer is refused all four calls, with
    // real ids, and its get_order shows no vouchers.
    const packerCalls = [
      ['authorize_voucher_upload', { p_photo_id: randomUUID(), p_order_id: dueY }],
      ['attach_voucher_photo', { p_photo_id: randomUUID(), p_order_id: dueY, p_size_bytes: 10 }],
      ['get_voucher_photo', { p_photo_id: photo }],
      ['hide_voucher_photo', { p_photo_id: photo }],
    ];
    const packerGot = [];
    for (const [fn, args] of packerCalls) {
      const r = await rpc(fn, args, tokenP);
      if (r.body?.code !== '42501') packerGot.push(`${fn} -> ${r.status} ${r.body?.code}`);
    }
    check('a packer is refused every voucher call', packerGot.length === 0, packerGot.join(', '));
    const packerOrder = (await rpc('get_order', { p_order_id: dueY }, tokenP)).body;
    check('...and sees no vouchers on the order', Array.isArray(packerOrder?.vouchers) && packerOrder.vouchers.length === 0,
      JSON.stringify(packerOrder?.vouchers));

    const bAuth = await rpc('authorize_voucher_upload', { p_photo_id: randomUUID(), p_order_id: dueY }, tokenB);
    const bView = await rpc('get_voucher_photo', { p_photo_id: photo }, tokenB);
    check('B can neither upload to nor view A\'s vouchers',
      bAuth.body?.code === 'P0002' && bView.body?.code === 'P0002',
      JSON.stringify([bAuth.body?.code, bView.body?.code]));

    const hide = await rpc('hide_voucher_photo', { p_photo_id: photo }, tokenA);
    const hideAgain = await rpc('hide_voucher_photo', { p_photo_id: photo }, tokenA);
    const hiddenView = await rpc('get_voucher_photo', { p_photo_id: photo }, tokenA);
    const hiddenOrder = (await rpc('get_order', { p_order_id: dueY }, tokenA)).body;
    check('a hidden voucher is gone from the order and cannot be fetched',
      hide.ok && hideAgain.ok && hiddenView.body?.code === 'P0002' && hiddenOrder?.vouchers?.length === 0,
      JSON.stringify({ hide: hide.body, view: hiddenView.body?.code }));

    const cancelledId = randomUUID();
    await rpc('create_order',
      { p_order_id: cancelledId, p_customer_id: dueCust, p_items: [{ packed_sku_id: skuId, qty_packets: 1 }] }, tokenA);
    await rpc('set_order_status', { p_order_id: cancelledId, p_status: 'CANCELLED' }, tokenA);
    const onCancelled = await rpc('authorize_voucher_upload',
      { p_photo_id: randomUUID(), p_order_id: cancelledId }, tokenA);
    check('a cancelled order takes no vouchers', onCancelled.body?.code === '22023', JSON.stringify(onCancelled.body));
  }

  // =========================================================================
  // 16. How a payment was made: CASH or UPI (migration 0024).
  //
  // The app only records what the owner says; nothing is verified. Old builds
  // send no p_method and must keep recording cash.
  // =========================================================================
  console.log('\n16. Payment method');
  {
    const today = (await rpc('get_day_summary', {}, tokenA)).body;
    const upiBefore = Number(today?.collected_upi ?? 0);
    const totalBefore = Number(today?.cash_collected ?? 0);

    const upiId = randomUUID();
    const upi = await rpc('record_payment',
      { p_payment_id: upiId, p_customer_id: dueCust, p_amount: 25, p_order_id: dueY, p_method: 'UPI' }, tokenA);
    check('a payment can be recorded as UPI', upi.ok && upi.body?.method === 'UPI', JSON.stringify(upi.body));

    const legacyId = randomUUID();
    const legacy = await rpc('record_payment',
      { p_payment_id: legacyId, p_customer_id: dueCust, p_amount: 5 }, tokenA);
    check('a call without p_method (an old build) still records CASH',
      legacy.ok && legacy.body?.method === 'CASH', JSON.stringify(legacy.body));

    const lower = await rpc('record_payment',
      { p_payment_id: randomUUID(), p_customer_id: dueCust, p_amount: 1, p_method: ' upi ' }, tokenA);
    check('the method is normalised', lower.body?.method === 'UPI', JSON.stringify(lower.body));

    const card = await rpc('record_payment',
      { p_payment_id: randomUUID(), p_customer_id: dueCust, p_amount: 1, p_method: 'CARD' }, tokenA);
    check('anything but CASH or UPI is refused', card.body?.code === '22023', JSON.stringify(card.body));

    const listed = (await rpc('list_payments', { p_customer_id: dueCust, p_limit: 200 }, tokenA)).body;
    const byId = new Map((listed?.rows ?? []).map((p) => [p.id, p.method]));
    check('list_payments reports each method',
      byId.get(upiId) === 'UPI' && byId.get(legacyId) === 'CASH', JSON.stringify([...byId.entries()].slice(0, 5)));

    const order = (await rpc('get_order', { p_order_id: dueY }, tokenA)).body;
    check('get_order reports the method of each payment',
      order?.payments?.find((p) => p.id === upiId)?.method === 'UPI', JSON.stringify(order?.payments));
    const ledger = (await rpc('get_customer_ledger', { p_customer_id: dueCust }, tokenA)).body;
    check('the khata reports the method of each payment',
      ledger?.payments?.rows?.find((p) => p.id === upiId)?.method === 'UPI');

    const after = (await rpc('get_day_summary', {}, tokenA)).body;
    check('the home summary splits the day by method, and the total still counts both',
      Number(after?.collected_upi) === upiBefore + 26
        && Number(after?.cash_collected) === totalBefore + 31
        && Number(after?.collected_cash) + Number(after?.collected_upi) === Number(after?.cash_collected),
      JSON.stringify({ upiBefore, totalBefore, after }));
  }

  // =========================================================================
  // 17. Per-customer prices and price corrections (migration 0025).
  //
  // The owner keeps a rate per customer per SKU; create_order bills at it and
  // falls back to the SKU's sale_price. A line's price can be corrected until
  // the order is CLOSED, and every correction is logged. OWNER only.
  // =========================================================================
  console.log('\n17. Customer prices');
  const priceCust = randomUUID();
  const editCust = randomUUID();
  {
    await rpc('upsert_customer', { p_id: priceCust, p_name: `Rate Card ${Date.now()}` }, tokenA);
    await rpc('upsert_customer', { p_id: editCust, p_name: `Price Edit ${Date.now()}` }, tokenA);
    await rpc('record_stock_adjustment',
      { p_entry_id: randomUUID(), p_item_kind: 'PACKED', p_item_id: skuId,
        p_mode: 'DELTA', p_qty: 10, p_note: 'price test stock' }, tokenA);

    const priceRow = async (customer) =>
      (await rpc('list_customer_prices', { p_customer_id: customer }, tokenA)).body
        ?.find((r) => r.packed_sku_id === skuId);
    const getOrder = async (id, token = tokenA) => (await rpc('get_order', { p_order_id: id }, token)).body;
    const place = async (customer, item) => {
      const id = randomUUID();
      const r = await rpc('create_order',
        { p_order_id: id, p_customer_id: customer, p_items: [{ packed_sku_id: skuId, qty_packets: 2, ...item }] }, tokenA);
      return { id, r };
    };

    let row = await priceRow(priceCust);
    check('with no rate, a customer pays the SKU default',
      Number(row?.price) === 60 && row?.customer_price === null && Number(row?.default_price) === 60,
      JSON.stringify(row));

    const set = await rpc('set_customer_price',
      { p_customer_id: priceCust, p_packed_sku_id: skuId, p_price: 52 }, tokenA);
    row = await priceRow(priceCust);
    check('the owner can set a customer\'s rate',
      set.ok && Number(row?.customer_price) === 52 && Number(row?.price) === 52, JSON.stringify([set.body, row]));
    const setAgain = await rpc('set_customer_price',
      { p_customer_id: priceCust, p_packed_sku_id: skuId, p_price: 52 }, tokenA);
    check('setting the same rate again is harmless', setAgain.ok, JSON.stringify(setAgain.body));

    const atRate = await place(priceCust, {});
    let o = await getOrder(atRate.id);
    check('an order without unit_price bills at the customer\'s rate',
      Number(o?.items?.[0]?.unit_price) === 52 && Number(o?.order?.total_amount) === 104,
      JSON.stringify(o?.items));

    const override = await place(priceCust, { unit_price: 50 });
    check('the owner can price a line by hand',
      Number((await getOrder(override.id))?.items?.[0]?.unit_price) === 50, JSON.stringify(override.r.body));

    await rpc('set_customer_price', { p_customer_id: priceCust, p_packed_sku_id: skuId, p_price: 55 }, tokenA);
    check('changing a rate never reprices an order already taken',
      Number((await getOrder(atRate.id))?.items?.[0]?.unit_price) === 52);

    const cleared = await rpc('set_customer_price',
      { p_customer_id: priceCust, p_packed_sku_id: skuId, p_price: null }, tokenA);
    row = await priceRow(priceCust);
    const afterClear = await place(priceCust, {});
    check('clearing a rate falls back to the SKU default',
      cleared.ok && row?.customer_price === null && Number(row?.price) === 60
        && Number((await getOrder(afterClear.id))?.items?.[0]?.unit_price) === 60,
      JSON.stringify([cleared.body, row]));

    const negative = await rpc('set_customer_price',
      { p_customer_id: priceCust, p_packed_sku_id: skuId, p_price: -1 }, tokenA);
    check('a negative rate is refused', negative.body?.code === '22023', JSON.stringify(negative.body));

    const bSet = await rpc('set_customer_price',
      { p_customer_id: priceCust, p_packed_sku_id: skuId, p_price: 1 }, tokenB);
    const bList = await rpc('list_customer_prices', { p_customer_id: priceCust }, tokenB);
    check('B can neither set nor read A\'s rates',
      bSet.body?.code === 'P0002' && bList.body?.code === 'P0002',
      JSON.stringify([bSet.body?.code, bList.body?.code]));

    // --- Corrections on an order that has gone out. ---
    const e = await place(editCust, {});
    await rpc('dispatch_order', { p_order_id: e.id }, tokenA);
    await rpc('set_order_status', { p_order_id: e.id, p_status: 'DELIVERED' }, tokenA);
    o = await getOrder(e.id);
    const itemId = o?.items?.[0]?.id;
    const outstanding = async () =>
      Number((await rpc('get_customer_ledger', { p_customer_id: editCust }, tokenA)).body?.balance?.outstanding);
    const owedBefore = await outstanding();
    check('a delivered order offers edit_prices',
      (o?.allowed_transitions ?? []).includes('edit_prices') && Number(o?.order?.total_amount) === 120,
      JSON.stringify(o?.allowed_transitions));

    const changeId = randomUUID();
    const edit = await rpc('set_order_item_price',
      { p_change_id: changeId, p_order_item_id: itemId, p_unit_price: 50, p_note: 'agreed discount' }, tokenA);
    o = await getOrder(e.id);
    check('the owner can correct a delivered line\'s price',
      edit.ok && edit.body?.changed === true && Number(edit.body?.total_amount) === 100
        && Number(o?.items?.[0]?.unit_price) === 50 && Number(o?.order?.total_amount) === 100
        && Number(o?.balance) === 100,
      JSON.stringify(edit.body));
    check('...the khata moves with it', (await outstanding()) === owedBefore - 20,
      `${owedBefore} -> ${await outstanding()}`);
    check('...and the change is logged with its note',
      o?.price_changes?.length === 1 && Number(o.price_changes[0].old_unit_price) === 60
        && Number(o.price_changes[0].new_unit_price) === 50 && o.price_changes[0].note === 'agreed discount'
        && typeof o.price_changes[0].changed_at === 'string',
      JSON.stringify(o?.price_changes));

    const retry = await rpc('set_order_item_price',
      { p_change_id: changeId, p_order_item_id: itemId, p_unit_price: 50, p_note: 'agreed discount' }, tokenA);
    const same = await rpc('set_order_item_price',
      { p_change_id: randomUUID(), p_order_item_id: itemId, p_unit_price: 50 }, tokenA);
    check('a retried or no-op correction changes nothing and logs nothing',
      retry.body?.changed === false && same.body?.changed === false
        && (await getOrder(e.id))?.price_changes?.length === 1,
      JSON.stringify([retry.body, same.body]));

    const badPrice = await rpc('set_order_item_price',
      { p_change_id: randomUUID(), p_order_item_id: itemId, p_unit_price: -5 }, tokenA);
    check('a negative price is refused', badPrice.body?.code === '22023', JSON.stringify(badPrice.body));

    const pEdit = await rpc('set_order_item_price',
      { p_change_id: randomUUID(), p_order_item_id: itemId, p_unit_price: 1 }, tokenP);
    const bEdit = await rpc('set_order_item_price',
      { p_change_id: randomUUID(), p_order_item_id: itemId, p_unit_price: 1 }, tokenB);
    check('only A\'s owner can correct a price (packer 42501, B P0002)',
      pEdit.body?.code === '42501' && bEdit.body?.code === 'P0002',
      JSON.stringify([pEdit.body?.code, bEdit.body?.code]));

    // A cut that clears the balance closes the order, like a payment would.
    await rpc('record_payment',
      { p_payment_id: randomUUID(), p_customer_id: editCust, p_amount: 90 }, tokenA);
    const cut = await rpc('set_order_item_price',
      { p_change_id: randomUUID(), p_order_item_id: itemId, p_unit_price: 45 }, tokenA);
    o = await getOrder(e.id);
    check('a cut that clears the balance closes the order',
      cut.ok && o?.order?.status === 'CLOSED' && (cut.body?.settled_orders ?? []).includes(o?.order?.order_no),
      JSON.stringify({ cut: cut.body, status: o?.order?.status }));

    const locked = await rpc('set_order_item_price',
      { p_change_id: randomUUID(), p_order_item_id: itemId, p_unit_price: 60 }, tokenA);
    check('a closed order\'s prices are locked',
      locked.body?.code === '22023' && locked.body?.hint === 'price_locked'
        && !(o?.allowed_transitions ?? []).includes('edit_prices'),
      JSON.stringify([locked.body, o?.allowed_transitions]));

    const c = await place(editCust, {});
    await rpc('set_order_status', { p_order_id: c.id, p_status: 'CANCELLED' }, tokenA);
    const cItem = (await getOrder(c.id))?.items?.[0]?.id;
    const onCancelled = await rpc('set_order_item_price',
      { p_change_id: randomUUID(), p_order_item_id: cItem, p_unit_price: 1 }, tokenA);
    check('a cancelled order\'s prices are locked',
      onCancelled.body?.hint === 'price_locked', JSON.stringify(onCancelled.body));
  }

  // =========================================================================
  // 18. Suppliers, purchases and what is owed to them (migration 0026).
  //
  // The buying side. Three things this section is really defending:
  //   * stock moves by exactly the purchased quantity, once, and comes back
  //     by exactly the same amount when the bill is cancelled;
  //   * paid/balance are DERIVED, so the arithmetic has to hold after every
  //     write without anything being stored;
  //   * money paid OUT to a supplier never leaks into the customer books.
  // =========================================================================
  console.log('\n18. Suppliers, purchases and what is owed to them');
  {
    const purRaw = randomUUID();
    await rpc('upsert_raw_material',
      { p_id: purRaw, p_name: `Purchase Test Chilli ${Date.now()}` }, tokenA);

    const getPurchase = async (id, token = tokenA) =>
      (await rpc('get_purchase', { p_purchase_id: id }, token)).body;

    const sup = await rpc('list_suppliers', {}, tokenA);
    const supRow = (sup.body?.rows ?? []).find((r) => r.id === supId);
    check('a new supplier starts owing nothing',
      supRow?.purchase_count === 0 && Number(supRow?.outstanding) === 0,
      JSON.stringify(supRow));

    // 50 kg at 180/kg + 100 kg at 120/kg = 9,000 + 12,000 = 21,000.
    // Grams and per-gram cost, which is what the wire carries.
    const ITEMS = [
      { raw_material_id: purRaw, qty_base: 50000, unit_cost_base: 0.18 },
      { raw_material_id: rawId, qty_base: 100000, unit_cost_base: 0.12 },
    ];
    const EXPECTED_TOTAL = 21000;

    const stockBefore = await onHandOf(purRaw);
    const purId = randomUUID();
    const made = await rpc('create_purchase',
      { p_purchase_id: purId, p_supplier_id: supId, p_items: ITEMS,
        p_invoice_no: 'INV-0026-1', p_due_on: istDay(15), p_receive: true }, tokenA);
    check('a purchase totals qty x rate, server-side',
      made.ok && Number(made.body?.total_amount) === EXPECTED_TOTAL,
      JSON.stringify(made.body));

    const p1 = await getPurchase(purId);
    check('a received purchase is unpaid, numbered, and due when the bill says',
      p1?.purchase?.status === 'RECEIVED' && typeof p1?.purchase?.purchase_no === 'number'
        && p1?.payment_state === 'UNPAID' && Number(p1?.paid) === 0
        && Number(p1?.balance) === EXPECTED_TOTAL
        && p1?.purchase?.due_on === istDay(15)
        && p1?.due_state === 'UPCOMING' && p1?.due_in_days === 15,
      JSON.stringify({ status: p1?.purchase?.status, state: p1?.payment_state,
        balance: p1?.balance, due: p1?.purchase?.due_on, ds: p1?.due_state }));

    check('receiving a purchase raises raw stock by exactly what was bought',
      (await onHandOf(purRaw)) === stockBefore + 50000,
      `${await onHandOf(purRaw)} vs ${stockBefore + 50000}`);

    const retry = await rpc('create_purchase',
      { p_purchase_id: purId, p_supplier_id: supId, p_items: ITEMS, p_receive: true }, tokenA);
    check('a retried purchase does not double-post its stock',
      retry.body?.created === false && (await onHandOf(purRaw)) === stockBefore + 50000,
      JSON.stringify(retry.body));

    // ---- Paying for it, a bit at a time -------------------------------------
    const payId = randomUUID();
    const part = await rpc('record_purchase_payment',
      { p_payment_id: payId, p_purchase_id: purId, p_amount: 10000,
        p_method: 'UPI', p_reference: 'TXN-1234', p_note: 'first instalment' }, tokenA);
    check('a partial payment leaves the bill part paid, with the arithmetic right',
      part.ok && part.body?.payment_state === 'PARTIALLY_PAID'
        && Number(part.body?.paid) === 10000
        && Number(part.body?.balance) === EXPECTED_TOTAL - 10000,
      JSON.stringify(part.body));

    const p2 = await getPurchase(purId);
    const first = (p2?.payments ?? [])[0];
    check('the payment is in the history, with how it was paid and its reference',
      (p2?.payments ?? []).length === 1 && first?.method === 'UPI'
        && first?.reference === 'TXN-1234' && Number(first?.amount) === 10000
        && typeof first?.paid_on === 'string',
      JSON.stringify(p2?.payments));

    const payRetry = await rpc('record_purchase_payment',
      { p_payment_id: payId, p_purchase_id: purId, p_amount: 10000 }, tokenA);
    const p3 = await getPurchase(purId);
    check('a retried payment is not counted twice',
      payRetry.body?.created === false && Number(payRetry.body?.paid) === 10000
        && (p3?.payments ?? []).length === 1,
      JSON.stringify({ retry: payRetry.body, n: (p3?.payments ?? []).length }));

    const rest = await rpc('record_purchase_payment',
      { p_payment_id: randomUUID(), p_purchase_id: purId,
        p_amount: EXPECTED_TOTAL - 10000, p_method: 'CASH' }, tokenA);
    check('settling the bill clears the balance and the due state together',
      rest.ok && rest.body?.payment_state === 'PAID'
        && Number(rest.body?.balance) === 0 && rest.body?.due_state === null,
      JSON.stringify(rest.body));

    // ---- Overdue is a date, not a payment level -----------------------------
    const backId = randomUUID();
    await rpc('record_purchase_payment',
      { p_payment_id: backId, p_purchase_id: purId, p_amount: -5000,
        p_note: 'supplier refunded a short delivery' }, tokenA);
    const late = await rpc('set_purchase_due_date',
      { p_purchase_id: purId, p_due_on: istDay(-3) }, tokenA);
    const p4 = await getPurchase(purId);
    check('a part-paid bill past its date is overdue AND still part paid',
      late.ok && p4?.due_state === 'OVERDUE' && p4?.due_in_days === -3
        && p4?.payment_state === 'PARTIALLY_PAID' && Number(p4?.balance) === 5000,
      JSON.stringify({ ds: p4?.due_state, d: p4?.due_in_days,
        ps: p4?.payment_state, bal: p4?.balance }));

    check('a reversal is a new row, not an edit',
      (p4?.payments ?? []).length === 3
        && (p4?.payments ?? []).some((x) => Number(x.amount) === -5000),
      JSON.stringify((p4?.payments ?? []).map((x) => x.amount)));

    const tooMuch = await rpc('record_purchase_payment',
      { p_payment_id: randomUUID(), p_purchase_id: purId, p_amount: -999999 }, tokenA);
    check('you cannot reverse more than was ever paid',
      tooMuch.body?.code === '23514', JSON.stringify(tooMuch.body));

    // ---- Cancelling ---------------------------------------------------------
    const blocked = await rpc('cancel_purchase', { p_purchase_id: purId }, tokenA);
    check('a bill with money against it cannot be cancelled',
      blocked.body?.code === '23514' && blocked.body?.hint === 'payments_exist'
        && !(p4?.allowed_actions ?? []).includes('cancel'),
      JSON.stringify({ body: blocked.body, actions: p4?.allowed_actions }));

    // ---- Cancelling reverses the stock, exactly -----------------------------
    const cancelRaw = randomUUID();
    await rpc('upsert_raw_material',
      { p_id: cancelRaw, p_name: `Cancel Test Jeera ${Date.now()}` }, tokenA);
    const cancelBefore = await onHandOf(cancelRaw);
    const cancelId = randomUUID();
    await rpc('create_purchase',
      { p_purchase_id: cancelId, p_supplier_id: supId,
        p_items: [{ raw_material_id: cancelRaw, qty_base: 25000, unit_cost_base: 0.2 }],
        p_receive: true }, tokenA);
    check('the bill to be cancelled landed in stock first',
      (await onHandOf(cancelRaw)) === cancelBefore + 25000);

    const killed = await rpc('cancel_purchase',
      { p_purchase_id: cancelId, p_reason: 'wrong goods delivered' }, tokenA);
    const pc = await getPurchase(cancelId);
    check('cancelling a received bill puts the stock back exactly',
      killed.ok && killed.body?.cancelled === true && killed.body?.reversed_items === 1
        && (await onHandOf(cancelRaw)) === cancelBefore
        && pc?.purchase?.status === 'CANCELLED'
        && typeof pc?.purchase?.cancelled_at === 'string'
        && pc?.purchase?.cancel_reason === 'wrong goods delivered',
      JSON.stringify({ body: killed.body, status: pc?.purchase?.status }));

    const ledger = await rpc('list_stock_ledger', { p_raw_material_id: cancelRaw }, tokenA);
    const reversal = (ledger.body?.rows ?? [])
      .find((r) => r.ref_id === cancelId && Number(r.qty_base) < 0);
    check('the reversal is a negative PURCHASE_IN still pointing at the bill',
      reversal?.entry_type === 'PURCHASE_IN' && Number(reversal?.qty_base) === -25000
        && reversal?.ref_type === 'PURCHASE',
      JSON.stringify(reversal));

    const again = await rpc('cancel_purchase', { p_purchase_id: cancelId }, tokenA);
    check('cancelling twice does not take the stock out twice',
      again.body?.already_cancelled === true && (await onHandOf(cancelRaw)) === cancelBefore,
      JSON.stringify(again.body));

    const onDead = await rpc('record_purchase_payment',
      { p_payment_id: randomUUID(), p_purchase_id: cancelId, p_amount: 1 }, tokenA);
    check('a cancelled bill takes no more money',
      onDead.body?.hint === 'purchase_cancelled', JSON.stringify(onDead.body));

    // Stock that has since left cannot be un-bought.
    const goneRaw = randomUUID();
    await rpc('upsert_raw_material',
      { p_id: goneRaw, p_name: `Consumed Test ${Date.now()}` }, tokenA);
    const goneId = randomUUID();
    await rpc('create_purchase',
      { p_purchase_id: goneId, p_supplier_id: supId,
        p_items: [{ raw_material_id: goneRaw, qty_base: 5000, unit_cost_base: 0.1 }],
        p_receive: true }, tokenA);
    await rpc('record_stock_adjustment',
      { p_entry_id: randomUUID(), p_item_kind: 'RAW', p_item_id: goneRaw,
        p_mode: 'DELTA', p_qty: -4000, p_note: 'used in packing' }, tokenA);
    const short = await rpc('cancel_purchase', { p_purchase_id: goneId }, tokenA);
    check('a bill cannot be cancelled once its stock has been used',
      short.body?.code === '23514' && (await onHandOf(goneRaw)) === 1000,
      JSON.stringify(short.body));

    // ---- A draft is a document; a received bill is frozen -------------------
    const draftRaw = randomUUID();
    await rpc('upsert_raw_material',
      { p_id: draftRaw, p_name: `Draft Test Haldi ${Date.now()}` }, tokenA);
    const draftBefore = await onHandOf(draftRaw);
    const draftId = randomUUID();
    await rpc('create_purchase',
      { p_purchase_id: draftId, p_supplier_id: supId,
        p_items: [{ raw_material_id: draftRaw, qty_base: 50000, unit_cost_base: 0.18 }],
        p_receive: false }, tokenA);
    const d1 = await getPurchase(draftId);
    check('a draft posts nothing to stock and offers edit and receive',
      d1?.purchase?.status === 'DRAFT' && (await onHandOf(draftRaw)) === draftBefore
        && (d1?.allowed_actions ?? []).includes('edit')
        && (d1?.allowed_actions ?? []).includes('receive'),
      JSON.stringify({ status: d1?.purchase?.status, actions: d1?.allowed_actions }));

    const edited = await rpc('update_purchase',
      { p_purchase_id: draftId, p_supplier_id: supId,
        p_items: [{ raw_material_id: draftRaw, qty_base: 40000, unit_cost_base: 0.18 }],
        p_notes: 'corrected before it arrived' }, tokenA);
    check('a draft can be corrected, and its total follows',
      edited.ok && Number(edited.body?.total_amount) === 7200
        && edited.body?.item_count === 1,
      JSON.stringify(edited.body));

    await rpc('receive_purchase', { p_purchase_id: draftId }, tokenA);
    check('receiving posts the CORRECTED quantity, not the original',
      (await onHandOf(draftRaw)) === draftBefore + 40000,
      `${await onHandOf(draftRaw)} vs ${draftBefore + 40000}`);

    const frozen = await rpc('update_purchase',
      { p_purchase_id: draftId, p_supplier_id: supId,
        p_items: [{ raw_material_id: draftRaw, qty_base: 1, unit_cost_base: 1 }] }, tokenA);
    check('a received bill cannot be edited',
      frozen.body?.code === '22023' && frozen.body?.hint === 'purchase_locked',
      JSON.stringify(frozen.body));

    // An advance on a draft is real money; the bill cannot be cut under it.
    const advId = randomUUID();
    await rpc('create_purchase',
      { p_purchase_id: advId, p_supplier_id: supId,
        p_items: [{ raw_material_id: draftRaw, qty_base: 10000, unit_cost_base: 1 }],
        p_receive: false }, tokenA);
    await rpc('record_purchase_payment',
      { p_payment_id: randomUUID(), p_purchase_id: advId, p_amount: 6000,
        p_note: 'advance' }, tokenA);
    const cutUnder = await rpc('update_purchase',
      { p_purchase_id: advId, p_supplier_id: supId,
        p_items: [{ raw_material_id: draftRaw, qty_base: 1000, unit_cost_base: 1 }] }, tokenA);
    check('a draft cannot be cut below what has already been paid on it',
      cutUnder.body?.code === '23514' && cutUnder.body?.hint === 'below_paid',
      JSON.stringify(cutUnder.body));

    // ---- The supplier relationship adds up ---------------------------------
    const detail = await rpc('get_supplier', { p_supplier_id: supId }, tokenA);
    const t = detail.body?.totals;
    const listed = ((await rpc('list_suppliers', {}, tokenA)).body?.rows ?? [])
      .find((r) => r.id === supId);
    check('get_supplier and list_suppliers agree on what is owed',
      detail.ok && Number(t?.outstanding) === Number(listed?.outstanding)
        && Number(t?.total_billed) === Number(listed?.total_billed)
        && Number(t?.total_paid) === Number(listed?.total_paid),
      JSON.stringify({ totals: t, row: listed }));

    check('a supplier is owed exactly what was billed less what was paid',
      Math.abs(Number(t?.total_billed) - Number(t?.total_paid) - Number(t?.outstanding)) < 0.005,
      JSON.stringify(t));

    check('the supplier carries a page of their own bills',
      Array.isArray(detail.body?.purchases?.rows)
        && typeof detail.body?.purchases?.has_more === 'boolean'
        && detail.body.purchases.rows.every((r) => r.supplier_id === supId),
      JSON.stringify(detail.body?.purchases?.limit));

    check('an overdue bill is counted as overdue on the supplier',
      Number(t?.overdue_count) >= 1 && Number(t?.overdue_amount) >= 5000,
      JSON.stringify({ n: t?.overdue_count, amount: t?.overdue_amount }));

    // A cancelled bill is neither owed nor settled -- it must not read as PAID.
    const cancelledRow = (await rpc('list_purchases', {}, tokenA)).body?.rows
      ?.find((r) => r.id === cancelId);
    check('a cancelled bill reports no payment state rather than looking paid',
      cancelledRow?.payment_state === null && Number(cancelledRow?.balance) === 0
        && cancelledRow?.status === 'CANCELLED',
      JSON.stringify(cancelledRow));

    // ---- Money paid OUT is not money taken IN ------------------------------
    // get_day_summary is require_member(), so a packer reads it. Supplier
    // payables must never appear there, and this is the assertion that stops
    // someone later "helpfully" merging the two ledgers.
    const dayBefore = (await rpc('get_day_summary', {}, tokenA)).body;
    const outId = randomUUID();
    await rpc('record_purchase_payment',
      { p_payment_id: outId, p_purchase_id: purId, p_amount: 1000, p_method: 'CASH' }, tokenA);
    const dayAfter = (await rpc('get_day_summary', {}, tokenA)).body;
    const dayBook = (await rpc('list_payments', {}, tokenA)).body?.rows ?? [];
    check('paying a supplier does not touch the day\'s collections',
      Number(dayBefore?.cash_collected) === Number(dayAfter?.cash_collected)
        && Number(dayBefore?.collected_cash) === Number(dayAfter?.collected_cash)
        && !dayBook.some((p) => p.id === outId),
      JSON.stringify({ before: dayBefore?.cash_collected, after: dayAfter?.cash_collected }));

    // ---- Another shop cannot see or touch any of it ------------------------
    const crossRefused = [];
    for (const [fn, args] of [
      ['get_supplier', { p_supplier_id: supId }],
      ['get_purchase', { p_purchase_id: purId }],
      ['record_purchase_payment', { p_payment_id: randomUUID(), p_purchase_id: purId, p_amount: 1 }],
      ['cancel_purchase', { p_purchase_id: draftId }],
      ['set_purchase_due_date', { p_purchase_id: purId, p_due_on: null }],
      ['update_purchase', { p_purchase_id: purId, p_supplier_id: null,
        p_items: [{ raw_material_id: purRaw, qty_base: 1, unit_cost_base: 1 }] }],
      ['archive_master', { p_table: 'suppliers', p_id: supId }],
    ]) {
      const r = await rpc(fn, args, tokenB);
      // archive_master answers rather than raising; it must simply match nothing.
      const refused = fn === 'archive_master' ? r.body?.archived === false : !r.ok;
      if (!refused) crossRefused.push(`${fn} -> ${r.status} ${JSON.stringify(r.body)}`);
    }
    check('another shop cannot read or move any of this',
      crossRefused.length === 0, crossRefused.join('; '));

    const bSees = await rpc('list_purchases', {}, tokenB);
    const bSups = await rpc('list_suppliers', {}, tokenB);
    check('another shop sees none of these bills or suppliers',
      !(bSees.body?.rows ?? []).some((r) => r.supplier_id === supId)
        && !(bSups.body?.rows ?? []).some((r) => r.id === supId),
      JSON.stringify({ p: bSees.body?.rows?.length, s: bSups.body?.rows?.length }));

    // The append-only rule, from the outside: there is no RPC that edits or
    // deletes a payment, so the only way to correct one is another row.
    check('nothing in the API can rewrite a supplier payment',
      (await getPurchase(purId))?.payments?.length === 4,
      JSON.stringify((await getPurchase(purId))?.payments?.map((x) => x.amount)));

    for (const id of [purRaw, cancelRaw, goneRaw, draftRaw]) {
      await rpc('archive_master', { p_table: 'raw_materials', p_id: id }, tokenA);
    }
  }

  console.log('\n13. Cleanup');
  {
    const archived = [];
    const failed = [];
    for (const [table, id] of [
      ['packed_skus', skuId],
      ['raw_materials', rawId],
      ['customers', custId],
      ['customers', allocCust],
      ['customers', dueCust],
      ['customers', plainCust],
      ['customers', defaultCust],
      ['customers', priceCust],
      ['customers', editCust],
      ['suppliers', supId],
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
