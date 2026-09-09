-- 0009_schema_contract
--
-- The app and the schema now live in separate repos, and app builds outlive
-- schema changes regardless -- you cannot force a user to update. Both problems
-- are the same problem: an old client meeting a newer server.
--
-- The contract is two numbers:
--
--   current     bumps on ANY change to the sync wire shape. Informational; the
--               client uses it to know it is behind.
--   min_client  bumps ONLY on a change an old client cannot survive -- a column
--               removed or retyped, a table dropped from synced_tables(), a
--               semantic change to an existing field.
--
-- The client refuses to sync when min_client exceeds the version it was built
-- with, and prompts for an update. Additive changes therefore never brick an
-- installed app, which is the whole point of separating the deploy cadences.
--
-- WHEN YOU CHANGE THE SCHEMA: replace this function in your new migration.
-- Bumping `current` is nearly always right; bumping `min_client` is a decision
-- that strands every phone that has not updated, so justify it in the migration.

create or replace function app.schema_contract()
returns jsonb
language sql
immutable
set search_path = ''
as $fn$
  select jsonb_build_object(
    'current',    1,
    'min_client', 1
  )
$fn$;

comment on function app.schema_contract() is
  'Sync wire-shape compatibility contract. See 0009_schema_contract.sql before bumping min_client.';

-- ---------------------------------------------------------------------------
-- sync_pull now reports the contract. This is additive -- an older client
-- ignores the extra key -- so min_client stays at 1.
-- ---------------------------------------------------------------------------

create or replace function public.sync_pull(last_pulled_at bigint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_lag      constant interval := interval '5 seconds';
  v_business uuid := app.current_business_id();
  v_since    timestamptz;
  v_cursor   timestamptz := now() - v_lag;
  v_changes  jsonb := '{}'::jsonb;
  t          text;
  v_soft     boolean;
  v_updated  jsonb;
  v_deleted  jsonb;
begin
  if v_business is null then
    raise exception 'caller is not an active member of any business'
      using errcode = '42501';
  end if;

  v_since := case
    when last_pulled_at is null or last_pulled_at <= 0 then '-infinity'::timestamptz
    else to_timestamp(last_pulled_at / 1000.0)
  end;

  foreach t in array app.synced_tables() loop
    v_soft := exists (
      select 1 from information_schema.columns
      where table_schema = 'app' and table_name = t and column_name = 'deleted_at'
    );

    execute format(
      'select coalesce(jsonb_agg(app.to_wire(to_jsonb(x))), ''[]''::jsonb)
         from app.%I x
        where x.business_id = $1
          and x.updated_at > $2 %s',
      t,
      case when v_soft then 'and x.deleted_at is null' else '' end
    ) into v_updated using v_business, v_since;

    if v_soft then
      execute format(
        'select coalesce(jsonb_agg(x.id), ''[]''::jsonb)
           from app.%I x
          where x.business_id = $1
            and x.updated_at > $2
            and x.deleted_at is not null',
        t
      ) into v_deleted using v_business, v_since;
    else
      v_deleted := '[]'::jsonb;
    end if;

    v_changes := v_changes || jsonb_build_object(
      t, jsonb_build_object(
        'created', '[]'::jsonb,
        'updated', v_updated,
        'deleted', v_deleted
      )
    );
  end loop;

  return jsonb_build_object(
    'changes',   v_changes,
    'timestamp', (extract(epoch from v_cursor) * 1000)::bigint,
    'contract',  app.schema_contract()
  );
end
$fn$;

alter function public.sync_pull(bigint) owner to app_api;
revoke all on function public.sync_pull(bigint) from public, anon;
grant execute on function public.sync_pull(bigint) to authenticated;

-- Readable without a tenant, so a client can discover it is too old to sync
-- even when its membership lookup would fail.
create or replace function public.schema_contract()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $fn$
  select app.schema_contract()
$fn$;

alter function public.schema_contract() owner to app_api;
revoke all on function public.schema_contract() from public, anon;
grant execute on function public.schema_contract() to authenticated;
