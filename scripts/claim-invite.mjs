#!/usr/bin/env node
/**
 * Claims an invitation, standing in for the screen the app does not have yet.
 *
 * The onboarding path is: an operator creates a business in the portal and gets
 * an invitation code; the person installs the app, signs in, and enters that
 * code. The middle step needs a Phase 1 screen that does not exist, so without
 * this the loop cannot be closed end to end locally.
 *
 * It does exactly what that screen will do -- register the account, then call
 * public.claim_invite with the code -- and nothing privileged: no service_role,
 * just signup and one RPC, the same two calls the app will make.
 *
 *   node --env-file=.env.dev scripts/claim-invite.mjs <invite-code>
 *   node --env-file=.env.dev scripts/claim-invite.mjs <code> --email me@x.com --password secret123
 *   node --env-file=.env.dev scripts/claim-invite.mjs <code> --name "Ravi Kumar"
 *
 * Prints credentials you can then sign into the app with. DEV ONLY.
 */

const URL_BASE = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_PUBLISHABLE_KEY;
const APP_ENV = process.env.APP_ENV;

if (!URL_BASE || !KEY) {
  console.error('Missing SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY.');
  console.error('Run with:  node --env-file=.env.dev scripts/claim-invite.mjs <code>');
  process.exit(1);
}
if (APP_ENV !== 'dev') {
  console.error(`Refusing to run against APP_ENV=${APP_ENV}. This creates accounts; dev only.`);
  process.exit(1);
}

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i === -1 ? fallback : argv[i + 1];
};

const token = argv.find((a) => !a.startsWith('--') && argv[argv.indexOf(a) - 1]?.startsWith('--') !== true);

if (!token) {
  console.error('Usage: node --env-file=.env.dev scripts/claim-invite.mjs <invite-code> [--email x] [--password y] [--name "Full Name"]');
  console.error('\nGet the code from the operator portal: Businesses -> a business -> Invitations -> Show code.');
  process.exit(1);
}

const email = flag('email', `joiner-${Date.now()}@dukaan-contract-test.com`);
const password = flag('password', 'devpassword123');
const fullName = flag('name', 'Test Joiner');

async function post(path, body, bearer) {
  const res = await fetch(`${URL_BASE}${path}`, {
    method: 'POST',
    headers: {
      apikey: KEY,
      Authorization: `Bearer ${bearer ?? KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = text;
  }
  return { ok: res.ok, status: res.status, body: json };
}

console.log(`\nClaiming an invitation on ${URL_BASE}\n`);

// 1. Get an account. Sign up, falling back to sign-in if it already exists --
//    so re-running with the same --email is not an error.
let session = await post('/auth/v1/signup', { email, password });
if (!session.body?.access_token) {
  session = await post('/auth/v1/token?grant_type=password', { email, password });
}
if (!session.body?.access_token) {
  console.error(`Could not create or sign in to ${email}:`);
  console.error(`  ${session.status} ${JSON.stringify(session.body)}`);
  process.exit(1);
}
console.log(`  account   ${email}`);

// 2. Claim. This is the only RPC involved, and it is the one the Phase 1 screen
//    will call.
const claim = await post(
  '/rest/v1/rpc/claim_invite',
  { p_token: token, p_full_name: fullName },
  session.body.access_token,
);

if (!claim.ok) {
  console.error(`\n  REFUSED  ${claim.status} ${claim.body?.message ?? JSON.stringify(claim.body)}`);
  if (claim.body?.hint === 'seat_limit') {
    console.error('  The business has used all its seats. Add one in the portal first.');
  }
  process.exit(1);
}

console.log(`  business  ${claim.body.business_id}`);
console.log(`  role      ${claim.body.role}${claim.body.already_member ? '  (already a member)' : ''}`);
console.log(`\nSign in to the app with:\n  ${email}\n  ${password}\n`);
