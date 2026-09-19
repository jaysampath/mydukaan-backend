# Supabase access pattern

How the app reaches its data, where authorization is enforced, and why it is
arranged this way. Read this before writing any feature code.

---

## The short version

```
  Device (React Native)
        |
        |  Supabase Auth  ->  JWT (sub = user id)
        |
        v
  PostgREST  ── exposed schema: public ── functions ONLY, no tables
        |
        |  SECURITY DEFINER, owned by app_api  (NOLOGIN, no BYPASSRLS)
        v
  schema app  ── every table, RLS ENABLED + FORCED, business_id policy
```

Two independent gates, either of which is sufficient on its own:

1. **Reachability.** Tables live in schema `app`, which PostgREST does not
   expose, and the `anon` / `authenticated` roles hold no privileges on it —
   not even `USAGE`. `supabase.from('orders')` cannot resolve. This is the
   requirement "never call tables directly from the client", enforced
   structurally rather than by convention.

2. **Row-level security.** Every table in `app` has RLS `ENABLED` **and**
   `FORCED`, with a `business_id = app.current_business_id()` policy. The API
   functions are `SECURITY DEFINER` owned by `app_api` — a role that is
   deliberately **not** `BYPASSRLS` — so those policies are still evaluated
   inside every function.

Gate 2 exists because gate 1 is configuration. If someone ever adds `app` to
the exposed-schemas list, tenants stay isolated anyway.

---

## Why `business_id` never appears in a client request

`app.current_business_id()` resolves the tenant from the JWT subject:

```sql
select p.business_id from app.profiles p
where p.id = app.current_user_id() and p.is_active and p.deleted_at is null
```

No RPC in this codebase takes a `business_id` argument. A client cannot name a
tenant, so it cannot name the wrong one. On the write path, `app.from_wire()`
strips any `business_id` the client sends and substitutes the resolved value —
tested: a payload claiming `business_id: 00000000-…-ff` lands in the caller's
own tenant.

`app.current_user_id()` reads the JWT claim from the request GUC rather than
calling `auth.uid()`. The `auth` schema is owned by `supabase_admin`, and the
migration role cannot grant `app_api` access to it, so an `app_api`-owned
function calling `auth.uid()` fails with *permission denied for schema auth*.
Reading the GUC has identical semantics with no dependency on Supabase's
internal ACLs.

---

## The one privileged exception

`public.bootstrap_business()` is owned by `postgres` (which does have
`BYPASSRLS`), because it runs *before* the caller has a profile — there is no
`business_id` for a policy to match on yet. It is guarded three ways: it
requires an authenticated caller, it refuses if the caller already has a
profile, and it is idempotent. Every other function in `public` is owned by
`app_api`.

`supabase/tests/security_and_sync.sql` asserts this: any *other* SECURITY
DEFINER function in `public` owned by a BYPASSRLS role is a test failure.

---

## Two write paths

This is the part worth understanding before Phase 2, because it looks like
duplication and is not.

**Path A — offline (the normal case).** The user records work on their phone.
It commits to local SQLite immediately and never waits for a network. Later,
`sync_push` carries the rows up. Validation happens at `sync_push`: tenant
scope, server-owned columns, append-only enforcement, and document-number
allocation.

**Path B — online RPCs.** `create_order`, `dispatch_order`, `record_payment`,
`run_conversion`, `receive_purchase`. These do the same work in one
transaction, with role checks and invariants (*is there enough stock to
dispatch?*) that need a consistent view of the whole ledger.

Both exist because offline-first is non-negotiable *and* the server must be the
authority. The rules are stated once in SQL (path B) and mirrored in
platform-agnostic TypeScript under `src/domain` for path A. Where they can
disagree, the server wins: it re-derives totals and refuses impossible states
on push.

What keeps this honest is the data model. The ledgers are **append-only**, so
two devices working offline produce two INSERTs, not a contested UPDATE. There
is no lost-update problem to resolve, which is why the duplicated logic stays
small.

### Known gap in the push path

`sync_push` lets a client write any column it is allowed to write, including
`orders.status` and `orders.total_amount`. It has to: a delivery worker must be
able to mark an order delivered with no signal, and that status change reaches
the server through push, not through an RPC.

The consequence is that a malicious or buggy client could push
`status: 'CLOSED'` on an order with no payments against it, or a
`total_amount` that does not match its line items. The online RPCs cannot be
fooled this way -- `record_payment` closes an order only when the payments
actually cover it, and `create_order` computes the total from the items -- but
push does not currently re-derive either.

This is not exploitable across tenants (RLS still holds) and it cannot corrupt
the ledgers (those are append-only and insert-only). It is a
within-your-own-tenant integrity gap, and the honest description is that it is
**open**.

Closing it belongs with Phase 4/5, when the order and payment flows are built:
`sync_push` should recompute `total_amount` from `order_items` and refuse a
`CLOSED` status that the payment rows do not support. Do not build the order UI
without doing this.

---

## What each RPC is for

| Function | Role(s) | Notes |
|---|---|---|
| `sync_pull(last_pulled_at)` | any member | Delta since cursor. Not subscription-gated. |
| `sync_push(changes, last_pulled_at)` | any member | Deliberately **not** subscription-gated — see below. |
| `bootstrap_business(name, owner)` | any authed user | Creates tenant + OWNER profile. Idempotent. |
| `update_business_settings(...)` | OWNER | Includes the GSTIN toggle. Never paywalled. |
| `receive_purchase(id)` | OWNER, MANAGER | Writes `PURCHASE_IN` rows. |
| `run_conversion(id)` | OWNER, MANAGER, PACKER | `PACK_OUT` + `PACK_IN` in one transaction. |
| `create_order(id, customer, items)` | OWNER, MANAGER | Prices from the SKU unless overridden. |
| `dispatch_order(id)` | OWNER, MANAGER, DELIVERY | **Stock leaves here**, not at order confirmation. |
| `set_order_status(id, status)` | any member | Cannot reach `OUT_FOR_DELIVERY` or `CLOSED`. |
| `record_payment(...)` | OWNER, MANAGER, DELIVERY | Appends. With `p_order_id` the cash is for that order (which must be this customer's); without it, it is account credit that settles the customer's oldest orders first. Closes delivered orders that are now fully covered and returns `settled_orders`. Never closes a PLACED/PACKED order. See 0021. |
| `get_receipt(id)` | any member | Server decides what is on the receipt. |
| `get_stock_snapshot()` | any member | Derived from the ledger every call. |
| `get_customer_ledger(id)` | any member | The running khata. |
| `upsert_customer/supplier/raw_material/packed_sku` | OWNER, MANAGER | 0011. Upserts: the client mints the id, so create and edit are one call. |
| `archive_master(table, id)` | OWNER, MANAGER | Soft. History keeps referencing the row. |
| `create_purchase(...)` | OWNER, MANAGER | 0011. Creates lines and posts through `receive_purchase`. |
| `create_packing_run(...)` | OWNER, MANAGER, PACKER | 0012. Derives wastage; refuses a run that would conjure stock. |
| `schema_contract()` / `describe_sync_schema()` | any / anon | 0009-0010. The client compatibility contract. |
| `claim_invite(token, name)` | any authed user | 0014. Attaches a user to a business. Enforces `seat_limit`. |
| `admin_*` (nine functions) | platform operator | 0015. Cross-tenant. See "The operator API" below. |

Every operation takes the record's UUID **from the caller**, so a phone that
loses signal mid-call can retry safely. `dispatch_order` called twice deducts
stock once and reports `already_dispatched: true` the second time.

### Why `sync_push` is not subscription-gated

A lapsed subscription makes the app **read-only, never data-locked**. The write
RPCs refuse (`app.require_write_access()` raises with `hint: 'read_only'`), so
no *new* work can be started. But `sync_push` stays open, because a user whose
subscription lapsed while their phone was offline must still be able to get the
work they already did onto the server. Holding it hostage would be a data-lock
in everything but name.

---

## The operator API

A platform operator is cross-tenant, which the tenant model has no room for:
`app.current_business_id()` reads the caller's profile, an operator has none, so
every policy denies. Migration 0013 adds `app.platform_admins` and the
`app.require_platform_admin()` guard; 0015 adds nine `admin_*` functions.

Those functions are owned by `postgres` and therefore run with `BYPASSRLS` --
the same sanctioned exception as `bootstrap_business`. **The guard is the whole
of tenant isolation for that surface.** Two things keep it honest:

1. `supabase/tests/admin_security.sql` asserts that every `admin_*` function's
   body contains `require_platform_admin`. One that forgets it fails the suite.
   The assertion is itself tested, by planting a deliberately unguarded function
   and confirming it is caught.
2. `scripts/admin-contract-test.mjs` signs in as a real tenant OWNER and calls
   all nine over HTTP, asserting `42501` on every one.

Rejected alternative: adding `or app.is_platform_admin()` to the fourteen tenant
policies. That would put the widening inside `sync_pull` too, so a defect in the
admin check would be fleet-wide tenant leakage rather than a bug in nine named
functions.

An operator is **not** a super-user of any tenant. Having no profile, they are
refused by `sync_pull`, `get_stock_snapshot` and every other tenant RPC --
asserted in the contract test. They administer the platform; they cannot read a
customer's khata.

`app.platform_admins` has a self-select policy and **no INSERT or UPDATE
policy**, so no application code path can create or promote an operator. It is
done by migration or by hand:

```sql
insert into app.platform_admins (user_id, label)
select id, 'ops: you@example.com' from auth.users where email = 'you@example.com';
```

There is still no `service_role` key anywhere in this system. The admin portal
authenticates as an ordinary Supabase user and calls these with its own JWT.

---

## The client compatibility contract

`app.schema_contract()` returns `{current, min_client}` and `sync_pull` reports
it on every pull. `min_client` is the oldest client the server still supports;
the app refuses to sync and prompts for an update when its baked-in
`SCHEMA_CONTRACT_VERSION` is below it.

This exists because app builds outlive schema changes -- you cannot force a user
to update -- and because the app now lives in a separate repo, so
`src/db/schema.ts` and these migrations are no longer one atomic commit.
`describe_sync_schema()` declares the local schema the server expects, and the
app repo's `src/db/schema.contract.test.ts` diffs its own schema against it.

**Bump `current` on any wire-shape change. Bump `min_client` only when an old
client genuinely cannot survive** -- it strands every phone that has not
updated, so justify it in the migration.

---

## A plpgsql trap worth knowing

For a rowtype variable, `rec IS NOT NULL` is true only when **every** column is
non-null. It is not the negation of `rec IS NULL`. Writing

```sql
select * into v_row from app.orders where id = p_id;
if v_row is not null then   -- WRONG: almost never true
```

silently never fires, because a found row nearly always has some nullable column
set. This shipped in `create_order` in Phase 0 and broke its retry-safety
guarantee: the idempotency check never matched, so a phone retrying after a
dropped connection got `23505` instead of `created:false`. Fixed in 0016.

Use `FOUND`. `rec IS NULL` for "no row was found" is correct and is fine to keep
-- when nothing matches, every column is null.

---

## Append-only, enforced three ways

`stock_ledger` and `payments` are history. Current stock is
`SUM(qty_base)`; customer outstanding is `Σ(order totals) − Σ(payments)`.
Neither is ever a stored, mutable number.

1. `sync_push` refuses deletes on these tables and treats a re-pushed row as a
   no-op (`ON CONFLICT DO NOTHING`), which is exactly what a retrying offline
   client needs.
2. `app_api` is granted `SELECT, INSERT, UPDATE` — never `DELETE`, on any table.
3. `BEFORE UPDATE OR DELETE` triggers raise on both tables, so even a
   privileged hand-run query is refused.

Corrections are made by inserting a row with the opposite sign.

---

## The sync protocol

`sync_pull` returns the WatermelonDB change set:

```json
{ "changes": { "<table>": { "created": [], "updated": [...], "deleted": [ids] } },
  "timestamp": 1787384345494 }
```

Three decisions worth knowing:

**Everything goes in `updated`, never `created`.** The client runs with
`sendCreatedAsUpdated: true` and treats an unknown id as a create. Splitting
created-vs-updated server-side would require per-device state, and getting it
wrong produces `Diverged from server` errors that strand a device permanently.

**The cursor lags `now()` by 5 seconds.** A transaction that stamps
`updated_at` before our snapshot but commits after it would otherwise be
invisible forever — its `updated_at` is already behind the next cursor. The lag
means the next pull's window still covers it. Rows may be delivered twice;
WatermelonDB applies them idempotently. The assumption is that a write
transaction never exceeds the lag, which holds — ours are single-statement
inserts.

**Timestamps cross the wire as epoch milliseconds.** Any column named `*_at`
is converted by `app.to_wire()` / `app.from_wire()`; columns named `*_on` are
calendar dates and stay ISO strings. `created_at` and `updated_at` are always
overwritten server-side — device clocks on budget phones are unreliable, and
the sync cursor depends on them being monotonic with respect to the database.

**`businesses` and `profiles` are pull-only.** Pushing to them raises. Changing
a role is an administrative act with its own RPC and its own role check — a
packer cannot promote itself to OWNER by pushing a profiles row. Tested.

---

## Dev / prod isolation

Two separate Supabase projects. Not two schemas, not two key sets — separate
projects, so there is no shared Postgres instance, no shared auth users, and no
credential that works on both.

| | dev | prod |
|---|---|---|
| Project ref | `upwwipwgfzqswjcmqrha` | `fwlnsatdqrtyvvnagbqn` |
| Selected by | `APP_ENV=dev` | `APP_ENV=prod` |
| Env file | `.env.dev` | `.env.prod` |
| App id | `com.launchgrid.apps.mydukaan.dev` | `com.launchgrid.apps.mydukaan` |
| App name | My Dukaan (dev) | My Dukaan |
| MCP access | read/write | **read-only** |

Selection happens at **build time** in `app.config.ts`, which reads
`.env.$APP_ENV` and bakes the URL and publishable key into the binary. There is
no runtime switch. A production build has no code path that reaches dev.

Because the ids differ, both apps install side by side on one phone and you can
never be confused about which you are looking at. And because `.env.prod` ships
empty in the repo, a prod build fails loudly until someone fills it in —
verified: `APP_ENV=prod npx expo config` errors rather than silently falling
back.

### MCP safety

`.mcp.json` points the prod server at `read_only=true`. Write-capable MCP
access is dev-only, and per-tool-call confirmation stays on. Text stored in the
database is untrusted input — a customer name or an order note is written by a
person and could contain anything, including instructions aimed at an LLM.
Never let an agent act on DB-stored text without review.

---

## Deploying schema changes

Dev is applied through the Supabase MCP server. **Prod is not** — the MCP
connection is read-only, on purpose. Prod goes through the CLI:

```bash
npx supabase link --project-ref fwlnsatdqrtyvvnagbqn
npx supabase db push
```

Migrations in `supabase/migrations/` follow the CLI convention
`<timestamp>_<nnnn>_<name>.sql`. The timestamp is what the CLI records and
compares against; the four-digit ordinal is kept in the name purely so the
files read in order and so prose can refer to "migration 0008". Dev's
`supabase_migrations.schema_migrations` already carries these exact versions,
so `db push` is a no-op there and applies the full set to prod.

They are applied in filename order and are **append-only once applied**. `0008_sync_push_partial_rows.sql` is an example:
a defect in `0006` was fixed by a new migration rather than by editing the
applied one, so dev and prod replay the same sequence.

Before considering any schema change done, run `supabase/tests/security_and_sync.sql`
against dev. It asserts RLS is enabled *and forced* with a policy on every
table, that no client role holds a table privilege, that no view is
security-definer, that every function has an immutable `search_path`, and that
no table has appeared in an exposed schema.

> The Supabase security advisor is the other half of this check. It is not
> exposed over the current MCP connection (`features=database,docs,development`
> omits it) — add `debugging` to the feature list, or read it in the dashboard
> under Advisors.

---

## Adding a table: the checklist

1. `business_id uuid not null references app.businesses(id)`, plus
   `created_by`, `created_at`, `updated_at`, and `deleted_at` unless the table
   is append-only history.
2. Create it in schema `app`. Never in `public`.
3. `enable row level security` **and** `force row level security`.
4. Add `tenant_select` / `tenant_insert` / `tenant_update` policies. No DELETE
   policy — deletion is soft.
5. Attach the `app.touch_updated_at()` trigger.
6. Add it to `app.synced_tables()`, and to `app.pushable_tables()` only if the
   client is genuinely allowed to write it.
7. If it is history, add it to `app.append_only_tables()` and attach
   `app.forbid_mutation()` on UPDATE and DELETE.
8. Mirror it in `src/db/schema.ts`, bump `SCHEMA_VERSION`, and add a migration
   step in `src/db/migrations.ts`.
9. Run the test suite.
