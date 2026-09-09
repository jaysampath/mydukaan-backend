-- 0010_describe_sync_schema
--
-- Lets the app repo verify, mechanically, that src/db/schema.ts still matches
-- the tables it syncs. The two repos are separate now, so that mirroring is no
-- longer one atomic commit -- this is what replaces the atomicity.
--
-- The server declares the EXPECTED local schema rather than raw column types,
-- because the server owns the wire format: app.to_wire() turns any *_at column
-- into epoch milliseconds, so `updated_at` is a Watermelon `number`, not a
-- string. Deriving that on the client would duplicate the rule and let the two
-- copies disagree -- which is the exact failure this function exists to catch.
--
-- Three columns are deliberately absent, matching the header of schema.ts:
--   id          WatermelonDB owns it implicitly
--   business_id derived from the JWT; meaningless on a device
--   deleted_at  Watermelon owns deletion via the `deleted` array of a pull
--
-- Callable by anon. It returns table and column NAMES, which are already
-- present in cleartext inside every shipped app bundle, so there is no
-- marginal disclosure -- and it means the drift check runs in CI with nothing
-- but the publishable key.

create or replace function public.describe_sync_schema()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select jsonb_build_object(
    'contract', app.schema_contract(),
    'tables', coalesce(jsonb_object_agg(t.table_name, t.columns), '{}'::jsonb)
  )
  from (
    select
      c.table_name::text as table_name,
      jsonb_agg(
        jsonb_build_object(
          'name', c.column_name::text,
          'type', case
                    when c.column_name::text like '%\_at'          then 'number'
                    when c.data_type = 'boolean'                    then 'boolean'
                    when c.data_type in ('numeric','integer','bigint',
                                         'smallint','double precision','real')
                                                                    then 'number'
                    else 'string'
                  end,
          'isOptional', (c.is_nullable = 'YES')
        )
        order by c.ordinal_position
      ) as columns
    from information_schema.columns c
    where c.table_schema = 'app'
      and c.table_name::text = any(app.synced_tables())
      and c.column_name::text not in ('id', 'business_id', 'deleted_at')
    group by c.table_name
  ) t
$fn$;

comment on function public.describe_sync_schema() is
  'The local schema the server expects a client to carry. Compared against src/db/schema.ts by the app repo''s drift check.';

alter function public.describe_sync_schema() owner to app_api;
revoke all on function public.describe_sync_schema() from public;
grant execute on function public.describe_sync_schema() to anon, authenticated;
