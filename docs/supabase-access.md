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
| `record_payment(...)` | OWNER, MANAGER, DELIVERY | Appends; closes the order when fully paid. |
| `get_receipt(id)` | any member | Server decides what is on the receipt. |
| `get_stock_snapshot()` | any member | Derived from the ledger every call. |
| `get_customer_ledger(id)` | any member | The running khata. |

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
