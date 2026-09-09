-- 0014_business_invites
--
-- How a person joins a business.
--
-- Postgres cannot create a Supabase auth user, and doing it from the admin
-- portal would mean a service_role key -- the one credential that bypasses
-- every policy in this system. There is currently no service_role usage
-- anywhere and this keeps it that way: the operator creates a business and an
-- invite, the invitee signs up through the app on their own, and claim_invite
-- attaches them.
--
-- The same mechanism carries the 5-seat cap, which until now was a column that
-- nothing enforced.

create table if not exists app.business_invites (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references app.businesses(id),
  role        text not null check (role in ('OWNER','MANAGER','PACKER','DELIVERY')),
  phone       text,
  email       text,
  token       text not null unique,
  expires_at  timestamptz not null,
  claimed_at  timestamptz,
  claimed_by  uuid references auth.users(id),
  created_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);

create index if not exists business_invites_business_idx
  on app.business_invites (business_id) where deleted_at is null;

alter table app.business_invites enable row level security;
alter table app.business_invites force row level security;

create policy tenant_select on app.business_invites for select
  using (business_id = app.current_business_id());
create policy tenant_insert on app.business_invites for insert
  with check (business_id = app.current_business_id());
create policy tenant_update on app.business_invites for update
  using (business_id = app.current_business_id())
  with check (business_id = app.current_business_id());

create trigger business_invites_touch
  before insert or update on app.business_invites
  for each row execute function app.touch_updated_at();

grant select, insert, update on app.business_invites to app_api;

-- Deliberately NOT added to app.synced_tables(): an invite is an administrative
-- artefact, not device data, and replicating its token onto every phone in the
-- business would hand every staff member the means to add another.

-- ---------------------------------------------------------------------------
-- Claiming.
--
-- Runs before the caller has a profile, so app.current_business_id() is still
-- null and no tenant policy can match. postgres-owned for exactly that reason
-- -- the same sanctioned exception as bootstrap_business -- and guarded by the
-- token, the expiry, and the seat count.
-- ---------------------------------------------------------------------------

create or replace function public.claim_invite(
  p_token     text,
  p_full_name text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_user   uuid := app.current_user_id();
  v_invite app.business_invites;
  v_seats  integer;
  v_limit  integer;
  v_existing app.profiles;
begin
  if v_user is null then
    raise exception 'sign in before claiming an invite' using errcode = '42501';
  end if;

  select * into v_invite
  from app.business_invites
  where token = p_token and deleted_at is null;

  -- One message for "no such token" and "already used", so a wrong guess
  -- cannot be told apart from a spent one.
  if v_invite is null or v_invite.claimed_at is not null then
    raise exception 'this invitation is not valid' using errcode = '42501';
  end if;
  if v_invite.expires_at <= now() then
    raise exception 'this invitation has expired' using errcode = '42501';
  end if;

  select * into v_existing from app.profiles where id = v_user;

  if v_existing is not null then
    if v_existing.business_id = v_invite.business_id then
      return jsonb_build_object(
        'business_id', v_invite.business_id,
        'role', v_existing.role,
        'already_member', true
      );
    end if;
    -- One user, one business in V1. Joining a second would make
    -- current_business_id() ambiguous, and every policy depends on it.
    raise exception 'this account already belongs to another business'
      using errcode = '42501';
  end if;

  select seat_limit into v_limit from app.businesses where id = v_invite.business_id;
  select count(*) into v_seats
  from app.profiles
  where business_id = v_invite.business_id and is_active and deleted_at is null;

  if v_seats >= v_limit then
    raise exception 'this business has used all % of its seats', v_limit
      using errcode = '23514', hint = 'seat_limit';
  end if;

  insert into app.profiles (id, business_id, full_name, phone, role, is_active, created_by)
  values (
    v_user, v_invite.business_id,
    coalesce(nullif(btrim(p_full_name), ''), coalesce(v_invite.phone, v_invite.email, 'Member')),
    v_invite.phone, v_invite.role, true, v_invite.created_by
  );

  update app.business_invites
     set claimed_at = now(), claimed_by = v_user
   where id = v_invite.id;

  return jsonb_build_object(
    'business_id', v_invite.business_id,
    'role', v_invite.role,
    'already_member', false
  );
end
$fn$;

revoke all on function public.claim_invite(text, text) from public, anon;
grant execute on function public.claim_invite(text, text) to authenticated;
