#!/usr/bin/env node
/**
 * Admin contract test -- runs against the real HTTP API, not the database.
 *
 * supabase/tests/admin_security.sql proves the structure: every admin_*
 * function carries the guard, platform_admins has no write policy, no client
 * role can reach either new table. This proves the wire, and one thing the SQL
 * suite structurally cannot: that a REAL JWT from a REAL sign-in is refused.
 *
 * The most important assertions here are the negative ones. Every admin_*
 * function runs with BYPASSRLS, so "an ordinary user gets 42501" is the whole
 * of tenant isolation for this API surface.
 *
 *   node --env-file=.env.dev scripts/admin-contract-test.mjs
 *
 * DEV ONLY, and it needs supabase/seed/dev_seed.sql to have been applied.
 */

import { randomUUID } from 'node:crypto';

const URL_BASE = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_PUBLISHABLE_KEY;
const APP_ENV = process.env.APP_ENV;

const ADMIN_EMAIL = process.env.TEST_ADMIN_EMAIL ?? 'admin@dev.local';
const ADMIN_PASSWORD = process.env.TEST_ADMIN_PASSWORD ?? 'devpassword123';
const OWNER_EMAIL = process.env.TEST_OWNER_EMAIL ?? 'owner.a@dev.local';
const OWNER_PASSWORD = process.env.TEST_OWNER_PASSWORD ?? 'devpassword123';

if (!URL_BASE || !KEY) {
  console.error('Missing SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY.');
  console.error('Run with:  node --env-file=.env.dev scripts/admin-contract-test.mjs');
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

async function signIn(email, password) {
  const res = await fetch(`${URL_BASE}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  const json = await res.json();
  if (!res.ok) {
    console.error(`\nCould not sign in as ${email}: ${res.status} ${JSON.stringify(json)}`);
    console.error('Has supabase/seed/dev_seed.sql been applied to this project?');
    process.exit(1);
  }
  return json.access_token;
}

async function rpc(token, fn, args = {}) {
  const res = await fetch(`${URL_BASE}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  let body;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  return { status: res.status, body };
}

/** Every admin_* RPC, with arguments valid enough to get past parsing. */
const ADMIN_SURFACE = [
  ['admin_list_businesses', {}],
  ['admin_get_business', { p_business_id: '00000000-0000-4000-8000-000000000000' }],
  [
    'admin_create_business',
    { p_business_id: '00000000-0000-4000-8000-000000000000', p_name: 'X', p_owner_phone: '9' },
  ],
  ['admin_set_subscription', { p_business_id: '00000000-0000-4000-8000-000000000000', p_status: 'ACTIVE' }],
  ['admin_set_seat_limit', { p_business_id: '00000000-0000-4000-8000-000000000000', p_seat_limit: 9 }],
  [
    'admin_set_member_role',
    {
      p_business_id: '00000000-0000-4000-8000-000000000000',
      p_user_id: '00000000-0000-4000-8000-000000000001',
      p_role: 'OWNER',
    },
  ],
  [
    'admin_set_member_active',
    {
      p_business_id: '00000000-0000-4000-8000-000000000000',
      p_user_id: '00000000-0000-4000-8000-000000000001',
      p_is_active: true,
    },
  ],
  [
    'admin_create_invite',
    { p_business_id: '00000000-0000-4000-8000-000000000000', p_role: 'PACKER', p_phone: '9' },
  ],
  ['admin_revoke_invite', { p_invite_id: '00000000-0000-4000-8000-000000000000' }],
];

console.log('\n=== Admin contract test =================================================');
console.log(`Project: ${URL_BASE}\n`);

const admin = await signIn(ADMIN_EMAIL, ADMIN_PASSWORD);
const owner = await signIn(OWNER_EMAIL, OWNER_PASSWORD);
console.log(`Signed in: ${ADMIN_EMAIL} (operator), ${OWNER_EMAIL} (tenant OWNER)\n`);

// --------------------------------------------------------------------------
console.log('1. An ordinary tenant user is refused by the ENTIRE admin surface');
console.log('   (these run with BYPASSRLS, so this is the whole of the isolation)');

for (const [fn, args] of ADMIN_SURFACE) {
  const r = await rpc(owner, fn, args);
  check(
    `${fn} refuses a tenant OWNER`,
    r.status === 403 && r.body?.code === '42501',
    `got ${r.status} ${JSON.stringify(r.body)}`,
  );
}

// --------------------------------------------------------------------------
console.log('\n2. An anonymous caller is refused too');

for (const [fn, args] of ADMIN_SURFACE.slice(0, 3)) {
  const r = await rpc(KEY, fn, args);
  check(`${fn} refuses the anon key`, r.status === 401 || r.status === 403, `got ${r.status}`);
}

// --------------------------------------------------------------------------
console.log('\n3. The operator is NOT a super-user of any tenant');

for (const fn of ['sync_pull', 'get_stock_snapshot']) {
  const r = await rpc(admin, fn, fn === 'sync_pull' ? { last_pulled_at: null } : {});
  check(
    `${fn} refuses the operator (no profile, no business)`,
    r.status === 403 && r.body?.code === '42501',
    `got ${r.status} ${JSON.stringify(r.body)}`,
  );
}

// --------------------------------------------------------------------------
console.log('\n4. The operator can actually do the job');

let r = await rpc(admin, 'admin_list_businesses');
check('admin_list_businesses returns an array', r.status === 200 && Array.isArray(r.body));
const before = Array.isArray(r.body) ? r.body.length : 0;
check('sees more than one tenant', before >= 2, `saw ${before}`);

const businessId = randomUUID();
const name = `Contract Test ${new Date().toISOString().slice(0, 19)}`;

r = await rpc(admin, 'admin_create_business', {
  p_business_id: businessId,
  p_name: name,
  p_owner_phone: '9990000000',
  p_seat_limit: 2,
});
check('admin_create_business succeeds', r.status === 200 && r.body?.created === true);
const token = r.body?.invite_token;
check('returns a 64-char invite token', typeof token === 'string' && token.length === 64);

r = await rpc(admin, 'admin_create_business', {
  p_business_id: businessId,
  p_name: name,
  p_owner_phone: '9990000000',
});
check('is idempotent on the supplied id', r.status === 200 && r.body?.created === false);

r = await rpc(admin, 'admin_get_business', { p_business_id: businessId });
check('admin_get_business finds it', r.status === 200 && r.body?.id === businessId);
check('starts on TRIAL', r.body?.subscription_status === 'TRIAL');
check('has one unclaimed OWNER invite', r.body?.invites?.length === 1);
check('has no members yet', r.body?.members?.length === 0);

r = await rpc(admin, 'admin_set_subscription', { p_business_id: businessId, p_status: 'ACTIVE' });
check('admin_set_subscription activates', r.body?.subscription_status === 'ACTIVE');

r = await rpc(admin, 'admin_set_subscription', { p_business_id: businessId, p_status: 'NONSENSE' });
check('rejects an unknown status', r.status >= 400, `got ${r.status}`);

r = await rpc(admin, 'admin_set_seat_limit', { p_business_id: businessId, p_seat_limit: 0 });
check('rejects a seat limit below 1', r.status >= 400, `got ${r.status}`);

// --------------------------------------------------------------------------
console.log('\n5. Invites');

r = await rpc(owner, 'claim_invite', { p_token: 'not-a-real-token', p_full_name: 'X' });
check('a bogus token is refused', r.status === 403 && r.body?.code === '42501');

r = await rpc(owner, 'claim_invite', { p_token: token, p_full_name: 'X' });
check(
  'a user who already belongs to a business cannot claim',
  r.status === 403 && r.body?.code === '42501',
  `got ${r.status} ${JSON.stringify(r.body)}`,
);

r = await rpc(admin, 'admin_get_business', { p_business_id: businessId });
const inviteId = r.body?.invites?.[0]?.id;
r = await rpc(admin, 'admin_revoke_invite', { p_invite_id: inviteId });
check('admin_revoke_invite revokes', r.status === 200 && r.body?.revoked === true);
r = await rpc(admin, 'admin_revoke_invite', { p_invite_id: inviteId });
check('revoking twice is a no-op, not an error', r.status === 200 && r.body?.revoked === false);

// --------------------------------------------------------------------------
console.log('\n6. Cleanup');
// Soft-delete the test business so repeated runs do not pile up. There is no
// admin_delete_business by design -- deletion is soft everywhere -- so this is
// left for the operator to tidy in the portal.
console.log(`  note  test business ${businessId} left in place (soft delete is the only kind)`);

console.log('\n=========================================================================');
console.log(`${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
