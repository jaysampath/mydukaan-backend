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
// Only used on the email fallback path. Supabase rejects reserved domains.
const EMAIL_DOMAIN = process.env.CONTRACT_TEST_EMAIL_DOMAIN ?? 'dukaan-contract-test.com';

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
 * Preference order:
 *  1. SUPABASE_ACCESS_TOKEN_A / _B, if you already have tokens.
 *  2. Anonymous sign-in, which needs "Allow anonymous sign-ins" enabled on the
 *     DEV project (Authentication > Sign In / Providers). This is the intended
 *     path: it costs nothing, works offline of any mail or SMS provider, and
 *     should never be enabled on prod.
 *  3. Email + password, which only works if mailer_autoconfirm is on -- without
 *     it, signup returns a user but no token, because the address is unverified.
 *
 * Phone/OTP is the real auth method for this app (Phase 1) but it needs an SMS
 * provider configured, so it is not what the contract test leans on.
 */
async function session(label) {
  const preset = process.env[`SUPABASE_ACCESS_TOKEN_${label}`];
  if (preset) return preset;

  const anon = await api('/auth/v1/signup', { body: {} });
  if (anon.ok && anon.body?.access_token) return anon.body.access_token;

  const stamp = `${Date.now()}${Math.random().toString(36).slice(2, 8)}`;
  const email = `contract-${label.toLowerCase()}-${stamp}@${EMAIL_DOMAIN}`;
  const password = `Contract-${stamp}-aA1!`;

  const up = await api('/auth/v1/signup', { body: { email, password } });
  if (up.ok && up.body?.access_token) return up.body.access_token;

  const inn = await api('/auth/v1/token?grant_type=password', { body: { email, password } });
  if (inn.ok && inn.body?.access_token) return inn.body.access_token;

  throw new Error(
    [
      `Could not open a session for user ${label}.`,
      ``,
      `  anonymous: ${anon.status} ${JSON.stringify(anon.body)}`,
      `  signup:    ${up.status} ${JSON.stringify(up.body)}`,
      `  signin:    ${inn.status} ${JSON.stringify(inn.body)}`,
      ``,
      `Fix, in order of preference:`,
      `  1. Enable "Allow anonymous sign-ins" on the DEV project only.`,
      `  2. Or enable "Confirm email = off" (mailer_autoconfirm) on DEV.`,
      `  3. Or export SUPABASE_ACCESS_TOKEN_A and SUPABASE_ACCESS_TOKEN_B.`,
      ``,
      `The same behaviours are covered at the SQL layer by`,
      `supabase/tests/security_and_sync.sql, which needs none of this.`,
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
  check(
    'first pull carries the business and profile',
    pull0.body?.changes?.businesses?.updated?.length === 1 &&
      pull0.body?.changes?.profiles?.updated?.length === 1,
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
  check('GSTIN hidden while the toggle is off', receipt.body?.business?.gstin === null, JSON.stringify(receipt.body?.business));
  await rpc('update_business_settings', { p_gstin: '36ABCDE1234F1Z5', p_show_gstin_on_receipt: true }, tokenA);
  const receipt2 = await rpc('get_receipt', { p_order_id: orderId }, tokenA);
  check('GSTIN shown once the toggle is on', receipt2.body?.business?.gstin === '36ABCDE1234F1Z5', JSON.stringify(receipt2.body?.business));

  console.log(`\n${passed} passed, ${failed} failed\n`);
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error('\nContract test aborted:', error.message);
  process.exit(1);
});
