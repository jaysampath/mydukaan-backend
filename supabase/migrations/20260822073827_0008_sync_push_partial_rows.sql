-- 0008_sync_push_partial_rows
--
-- Fixes a real defect in the 0006 push path, found by the tenant-isolation test.
--
-- The batched INSERT used jsonb_populate_record(null::app.<table>, payload),
-- which returns NULL for every column absent from the payload. Those NULLs were
-- then inserted explicitly, so column DEFAULTs never applied and any row that
-- omitted a NOT NULL DEFAULT column failed with a not-null violation:
--
--   null value in column "reorder_level_base" violates not-null constraint
--
-- That is not a hypothetical. It fires whenever the device sends a partial
-- record -- a targeted update, an older app version whose local schema predates
-- a column, or any column that exists in Postgres but not in the WatermelonDB
-- schema. Offline clients are exactly the population that lags the server
-- schema, so this had to be correct rather than usually-correct.
--
-- The fix builds the INSERT column list from the keys actually present in each
-- record, so omitted columns fall through to their DEFAULT. That means one
-- statement per record instead of one per table. The volume here is a single
-- shop's changes since its last sync -- tens of rows, not thousands -- so the
-- clarity is worth more than the batching.
--
-- It also hardens the payload: keys that are not real client-writable columns
-- are now dropped rather than handed to jsonb_populate_record and ignored by
-- luck.

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
  v_rec      jsonb;
  v_payload  jsonb;
  v_deleted  jsonb;
  v_allowed  text[];
  v_cols     text[];
  v_collist  text;
  v_sellist  text;
  v_setlist  text;
  v_conflict text;
  v_soft     boolean;
  v_order    record;
  v_no       bigint;
  v_applied  integer := 0;
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
    v_allowed := app.client_writable_columns(t);

    -- created and updated are handled identically; the server does not trust
    -- the client's opinion about which is which.
    v_rows := coalesce(changes -> t -> 'created', '[]'::jsonb)
              || coalesce(changes -> t -> 'updated', '[]'::jsonb);

    for v_rec in select value from jsonb_array_elements(v_rows) loop
      v_payload := app.from_wire(v_rec, v_business, v_user);

      if not (v_payload ? 'id') then
        raise exception 'every % record must carry an id', t using errcode = '22023';
      end if;

      -- Only columns the record actually carries are named in the INSERT, so
      -- everything else takes its DEFAULT. Anything that is not a real
      -- client-writable column is discarded here.
      select array_agg(k order by k)
        into v_cols
      from jsonb_object_keys(v_payload) k
      where k = any(v_allowed);

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
        -- A record carrying only an id has nothing to update.
        v_conflict := case when v_setlist is null
                           then 'do nothing'
                           else 'do update set ' || v_setlist end;
      end if;

      execute format(
        'insert into app.%I (%s)
         select %s
           from jsonb_populate_record(null::app.%I, $1) as p
         on conflict (id) %s',
        t, v_collist, v_sellist, t, v_conflict
      ) using v_payload;

      get diagnostics v_applied = row_count;
    end loop;

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
