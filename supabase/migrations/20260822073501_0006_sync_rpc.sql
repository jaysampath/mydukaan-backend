-- 0006_sync_rpc
-- The WatermelonDB sync endpoints. These are the ONLY way bulk data moves
-- between device and server.
--
-- Both are SECURITY DEFINER owned by app_api (no BYPASSRLS), so every
-- statement inside them is still filtered by the RLS policies from 0005.
-- business_id is taken from app.current_business_id(), never from the payload.

-- postgres must be a member of app_api to hand ownership over.
grant app_api to postgres;

-- app_api owns the API functions, so it needs to be able to hold objects in
-- the exposed schema. It still has no privileges on any table there -- schema
-- public contains functions only.
grant usage, create on schema public to app_api;

-- ---------------------------------------------------------------------------
-- Wire-format helpers.
-- Convention: any column named *_at is a timestamp and crosses the wire as
-- epoch milliseconds (what WatermelonDB's @date fields expect). Columns named
-- *_on are calendar dates and stay ISO strings.
-- ---------------------------------------------------------------------------

create or replace function app.to_wire(rec jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $fn$
  select coalesce(
    jsonb_object_agg(
      key,
      case
        when key like '%\_at' and jsonb_typeof(value) = 'string'
          then to_jsonb((extract(epoch from (value #>> '{}')::timestamptz) * 1000)::bigint)
        else value
      end
    ),
    '{}'::jsonb)
  from jsonb_each(rec)
$fn$;

-- Strips everything the client is not allowed to set, converts epoch-ms back to
-- timestamps, and stamps the server-controlled columns. This is the choke point
-- that makes a hostile payload harmless.
create or replace function app.from_wire(rec jsonb, p_business uuid, p_user uuid)
returns jsonb
language sql
stable
set search_path = ''
as $fn$
  select coalesce(
    jsonb_object_agg(
      key,
      case
        when key like '%\_at' and jsonb_typeof(value) = 'number'
          then to_jsonb(to_timestamp((value #>> '{}')::numeric / 1000.0))
        else value
      end
    ),
    '{}'::jsonb)
    || jsonb_build_object('business_id', p_business, 'created_by', p_user)
  from jsonb_each(rec)
  where key not in (
      -- server-owned: never accepted from a device
      'business_id', 'created_by', 'created_at', 'updated_at',
      'order_no', 'purchase_no', 'line_total'
    )
    -- WatermelonDB internals (_status, _changed) never reach the database
    and key not like '\_%'
$fn$;

-- Tables the client may pull, in FK-safe order.
create or replace function app.synced_tables()
returns text[]
language sql
immutable
set search_path = ''
as $fn$
  select array[
    'businesses','profiles','raw_materials','packed_skus','customers','suppliers',
    'purchases','purchase_items','packing_runs','orders','order_items',
    'stock_ledger','payments'
  ]
$fn$;

-- Tables the client may push. businesses/profiles are pull-only: changing them
-- is an administrative act with its own RPC and its own role check.
create or replace function app.pushable_tables()
returns text[]
language sql
immutable
set search_path = ''
as $fn$
  select array[
    'raw_materials','packed_skus','customers','suppliers',
    'purchases','purchase_items','packing_runs','orders','order_items',
    'stock_ledger','payments'
  ]
$fn$;

-- Append-only tables: re-pushing an existing row is a no-op, and a delete is
-- refused outright.
create or replace function app.append_only_tables()
returns text[]
language sql
immutable
set search_path = ''
as $fn$
  select array['stock_ledger','payments']
$fn$;

create or replace function app.client_writable_columns(p_table text)
returns text[]
language sql
stable
set search_path = ''
as $fn$
  select array_agg(column_name::text order by ordinal_position)
  from information_schema.columns
  where table_schema = 'app'
    and table_name = p_table
    and is_generated = 'NEVER'
    and is_identity = 'NO'
$fn$;

-- ---------------------------------------------------------------------------
-- PULL
--
-- Cursor safety: the returned cursor lags now() by a fixed window. A write
-- transaction that stamped updated_at before our snapshot but committed after
-- it would otherwise be invisible forever. With the lag, the next pull's
-- window still covers it. Rows may be delivered twice; WatermelonDB applies
-- them idempotently. The assumption is that a write transaction never takes
-- longer than the lag -- ours are single-statement inserts.
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

    -- Everything changed since the cursor goes into `updated`. The client runs
    -- with sendCreatedAsUpdated so it treats an unknown id as a create. This
    -- removes the created/updated split, which is the usual source of
    -- "Diverged from server" errors after a partial sync.
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
    'timestamp', (extract(epoch from v_cursor) * 1000)::bigint
  );
end
$fn$;

alter function public.sync_pull(bigint) owner to app_api;
revoke all on function public.sync_pull(bigint) from public, anon;
grant execute on function public.sync_pull(bigint) to authenticated;

-- ---------------------------------------------------------------------------
-- PUSH
-- ---------------------------------------------------------------------------

create or replace function public.sync_push(changes jsonb, last_pulled_at bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_business uuid := app.current_business_id();
  v_user     uuid := app.current_user_id();
  t          text;
  v_rows     jsonb;
  v_deleted  jsonb;
  v_cols     text[];
  v_collist  text;
  v_sellist  text;
  v_setlist  text;
  v_conflict text;
  v_soft     boolean;
  v_order    record;
  v_no       bigint;
begin
  if v_business is null then
    raise exception 'caller is not an active member of any business'
      using errcode = '42501';
  end if;
  if changes is null or jsonb_typeof(changes) <> 'object' then
    raise exception 'changes must be a JSON object' using errcode = '22023';
  end if;

  -- Reject unknown or pull-only tables loudly rather than dropping writes.
  for t in select jsonb_object_keys(changes) loop
    if not (t = any(app.pushable_tables())) then
      raise exception 'table % is not writable from a client', t
        using errcode = '42501';
    end if;
  end loop;

  -- FK-safe order: parents before children.
  foreach t in array app.pushable_tables() loop
    continue when not (changes ? t);

    v_soft := exists (
      select 1 from information_schema.columns
      where table_schema = 'app' and table_name = t and column_name = 'deleted_at'
    );

    -- created and updated are handled identically; the server does not trust
    -- the client's opinion about which is which.
    v_rows := coalesce(changes -> t -> 'created', '[]'::jsonb)
              || coalesce(changes -> t -> 'updated', '[]'::jsonb);

    if jsonb_array_length(v_rows) > 0 then
      v_cols    := app.client_writable_columns(t);
      v_collist := (select string_agg(format('%I', c), ', ') from unnest(v_cols) c);
      v_sellist := (select string_agg(format('p.%I', c), ', ') from unnest(v_cols) c);

      if t = any(app.append_only_tables()) then
        -- History is immutable. A re-push of a row we already have is a no-op,
        -- which is exactly what an offline client retrying needs.
        v_conflict := 'do nothing';
      else
        v_setlist := (
          select string_agg(format('%I = excluded.%I', c, c), ', ')
          from unnest(v_cols) c
          where c <> 'id'
        );
        v_conflict := 'do update set ' || v_setlist;
      end if;

      execute format(
        'insert into app.%I (%s)
         select %s
           from jsonb_array_elements($1) as e(r),
                lateral jsonb_populate_record(
                  null::app.%I, app.from_wire(e.r, $2, $3)
                ) as p
         on conflict (id) %s',
        t, v_collist, v_sellist, t, v_conflict
      ) using v_rows, v_business, v_user;
    end if;

    -- Deletes are soft, and refused entirely on append-only tables.
    v_deleted := coalesce(changes -> t -> 'deleted', '[]'::jsonb);
    if jsonb_array_length(v_deleted) > 0 then
      if not v_soft then
        raise exception 'rows in % cannot be deleted; insert a reversing row', t
          using errcode = '42501';
      end if;
      execute format(
        'update app.%I
            set deleted_at = now()
          where business_id = $1
            and deleted_at is null
            and id in (select (jsonb_array_elements_text($2))::uuid)',
        t
      ) using v_business, v_deleted;
    end if;
  end loop;

  -- Document numbers are allocated here, not on the device: an offline client
  -- cannot know what the next number is without risking a duplicate. Orders
  -- carry a null order_no until their first successful push.
  for v_order in
    select id from app.orders
    where business_id = v_business and order_no is null and deleted_at is null
    order by created_at, id
  loop
    insert into app.business_counters (business_id, name, value)
    values (v_business, 'order_no', 1)
    on conflict (business_id, name)
      do update set value = app.business_counters.value + 1
    returning value into v_no;

    update app.orders set order_no = v_no where id = v_order.id;
  end loop;

  return jsonb_build_object('ok', true);
end
$fn$;

alter function public.sync_push(jsonb, bigint) owner to app_api;
revoke all on function public.sync_push(jsonb, bigint) from public, anon;
grant execute on function public.sync_push(jsonb, bigint) to authenticated;
