# My Dukaan — backend

The database, the API, and the tests that keep them honest. Consumed by two
clients:

| Repo | Talks to |
|---|---|
| `mydukaan-mobile` | the Expo app — `sync_pull` + the tenant RPCs |
| `mydukaan-admin` | the operator portal — the `admin_*` RPCs |

All three sit side by side under a `mydukaan/` parent folder; each is its own
git repository.

There is **no server here**. The API is a set of Postgres functions in the
exposed `public` schema; the tables live in `app`, which PostgREST does not
expose. See [docs/supabase-access.md](docs/supabase-access.md) — read it before
changing anything.

---

## Why this is a separate repo

Backend changes ship without an App Store review. That was already true when
this lived in the app repo (nothing under `supabase/` is bundled — Metro only
bundles what `index.ts` imports), but keeping it separate makes the boundary
explicit and lets the schema be reviewed without the app.

The cost is that `src/db/schema.ts` in the app repo must mirror these
migrations, and that mirroring is no longer one atomic commit. Two things guard
it:

1. **`describe_sync_schema()`** declares the local schema the server expects.
   The app repo diffs its own `src/db/schema.ts` against it in
   `src/db/schema.contract.test.ts`, which fails on any drift. The schema stays
   hand-written — generating it would throw away the index choices and comments
   that carry real judgment — but it can no longer drift silently.
2. **`app.schema_contract()`** returns `{current, min_client}`. The app compares
   its baked-in version on every sync and refuses to sync — with an update
   prompt — if the server requires a newer client. Additive changes bump
   `current` only, so they never brick an old install; only a breaking change
   bumps `min_client`.

---

## Deploying

```bash
npm run db:link:dev && npm run db:push     # dev
npm run db:link:prod && npm run db:push    # prod
```

Migrations are applied in filename order and are **append-only once applied** —
fix a defect with a new migration, never by editing one that has run. Dev is
also reachable through the Supabase MCP server; prod's MCP connection is
read-only on purpose.

After any schema change:

```bash
npm run verify                      # both HTTP contract suites
cd ../mydukaan-mobile && npm test    # the schema drift check
# plus supabase/tests/*.sql against dev
```

---

## Layout

```
supabase/
  migrations/   append-only once applied
  tests/        the checks a schema change must pass
  seed/         dev fixtures (dev project only, guarded)
  functions/    Edge Functions — empty until Phase 7's RevenueCat webhook
scripts/
  sync-contract-test.mjs   exercises the tenant API over real HTTP
  admin-contract-test.mjs  exercises the admin API, both allowed and refused
docs/
  supabase-access.md       the security model
```
