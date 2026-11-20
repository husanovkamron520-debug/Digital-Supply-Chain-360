-- Telegram-first SupplyChain14 registration without collecting email or sending email.
-- The bot creates pending intents with its server-side service-role credential.
-- A signed-in Supabase Auth user explicitly confirms the Telegram link on the website.

-- This migration is intentionally self-contained for fresh CI/local databases.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.telegram_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  telegram_user_id bigint not null unique check (telegram_user_id > 0),
  telegram_username text,
  linked_at timestamptz not null default now()
);
alter table private.telegram_accounts enable row level security;
revoke all on private.telegram_accounts from public, anon, authenticated;

create table if not exists private.telegram_registration_pending (
  token_hash bytea primary key,
  telegram_user_id bigint not null unique check (telegram_user_id > 0),
  telegram_username text,
  full_name text not null check (char_length(full_name) between 2 and 120),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index if not exists telegram_registration_pending_expiry_idx
  on private.telegram_registration_pending (expires_at);

alter table private.telegram_registration_pending enable row level security;
revoke all on private.telegram_registration_pending from public, anon, authenticated, service_role;

-- The bearer token is required to read this one identity value.
create or replace function public.get_telegram_registration_user_id(p_token text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_telegram_user_id bigint;
begin
  if p_token is null or p_token !~ '^[A-Fa-f0-9]{64}$' then
    raise exception 'Invalid registration token';
  end if;

  select telegram_user_id
    into v_telegram_user_id
    from private.telegram_registration_pending
   where token_hash = extensions.digest(lower(p_token), 'sha256')
     and expires_at > now();

  if v_telegram_user_id is null then
    raise exception 'Registration link expired or already used; restart from Telegram';
  end if;

  return v_telegram_user_id::text;
end;
$$;

create or replace function public.create_telegram_registration_pending(
  p_token text,
  p_telegram_user_id bigint,
  p_telegram_username text,
  p_full_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := trim(coalesce(p_full_name, ''));
begin
  if p_token is null or p_token !~ '^[A-Fa-f0-9]{64}$'
     or p_telegram_user_id is null or p_telegram_user_id <= 0
     or char_length(v_name) not between 2 and 120 then
    raise exception 'Invalid registration details';
  end if;

  if exists (
    select 1
      from private.telegram_accounts a
     where a.telegram_user_id = p_telegram_user_id
  ) then
    raise exception 'This Telegram account is already linked';
  end if;

  delete from private.telegram_registration_pending
   where expires_at <= now()
      or telegram_user_id = p_telegram_user_id;

  insert into private.telegram_registration_pending(
    token_hash, telegram_user_id, telegram_username, full_name, expires_at
  )
  values (
    extensions.digest(lower(p_token), 'sha256'),
    p_telegram_user_id,
    nullif(left(trim(coalesce(p_telegram_username, '')), 64), ''),
    v_name,
    now() + interval '30 minutes'
  );

  return jsonb_build_object('success', true, 'expires_in_seconds', 1800);
exception
  when unique_violation then
    raise exception 'An active registration already exists for this Telegram account';
end;
$$;

create or replace function public.complete_telegram_registration(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_pending private.telegram_registration_pending%rowtype;
  v_existing private.telegram_accounts%rowtype;
begin
  if v_user_id is null then
    raise exception 'Sign in to your SupplyChain14 account first';
  end if;

  if p_token is null or p_token !~ '^[A-Fa-f0-9]{64}$' then
    raise exception 'Invalid registration token';
  end if;

  select *
    into v_pending
    from private.telegram_registration_pending
   where token_hash = extensions.digest(lower(p_token), 'sha256')
     and expires_at > now()
   for update;

  if not found then
    raise exception 'Registration link expired or already used; restart from Telegram';
  end if;

  insert into private.telegram_accounts(user_id, telegram_user_id, telegram_username)
  values (
    v_user_id,
    v_pending.telegram_user_id,
    v_pending.telegram_username
  )
  on conflict (user_id) do nothing;

  if not found then
    select *
      into v_existing
      from private.telegram_accounts
     where user_id = v_user_id;

    if v_existing.telegram_user_id is distinct from v_pending.telegram_user_id then
      raise exception 'This SupplyChain14 account is already linked to another Telegram account';
    end if;
  end if;

  update public.profiles
     set full_name = v_pending.full_name
   where id = v_user_id
     and (full_name is null or btrim(full_name) = '');

  delete from private.telegram_registration_pending
   where token_hash = v_pending.token_hash;

  return jsonb_build_object('success', true, 'telegram_linked', true);
exception
  when unique_violation then
    raise exception 'This Telegram account is already linked to another SupplyChain14 account';
end;
$$;

-- Remove the earlier draft signature if present.
drop function if exists public.create_telegram_registration_pending(text,bigint,text,text,text);

revoke all on function public.get_telegram_registration_user_id(text)
  from public, anon, authenticated, service_role;
grant execute on function public.get_telegram_registration_user_id(text)
  to anon, authenticated;

revoke all on function public.create_telegram_registration_pending(text,bigint,text,text)
  from public, anon, authenticated, service_role;
grant execute on function public.create_telegram_registration_pending(text,bigint,text,text)
  to service_role;

revoke all on function public.complete_telegram_registration(text)
  from public, anon, service_role;
grant execute on function public.complete_telegram_registration(text)
  to authenticated;


-- Telegram-only password recovery. No real email address is stored or sent.
create table if not exists private.telegram_password_recovery_pending (
  token_hash bytea primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  telegram_user_id bigint not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists telegram_password_recovery_expiry_idx
  on private.telegram_password_recovery_pending (expires_at);
alter table private.telegram_password_recovery_pending enable row level security;
revoke all on private.telegram_password_recovery_pending from public, anon, authenticated, service_role;

create or replace function public.create_telegram_password_recovery_pending(
  p_token text,
  p_telegram_user_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  if p_token is null or p_token !~ '^[A-Fa-f0-9]{64}$'
     or p_telegram_user_id is null or p_telegram_user_id <= 0 then
    raise exception 'Invalid recovery request';
  end if;

  select user_id into v_user_id
    from private.telegram_accounts
   where telegram_user_id = p_telegram_user_id;

  if v_user_id is null then
    raise exception 'No SupplyChain14 account is linked to this Telegram account';
  end if;

  delete from private.telegram_password_recovery_pending
   where expires_at <= now()
      or telegram_user_id = p_telegram_user_id;

  insert into private.telegram_password_recovery_pending(
    token_hash, user_id, telegram_user_id, expires_at
  )
  values (
    extensions.digest(lower(p_token), 'sha256'),
    v_user_id,
    p_telegram_user_id,
    now() + interval '15 minutes'
  );

  return jsonb_build_object('success', true, 'expires_in_seconds', 900);
end;
$$;

-- Service-role-only atomic consume. The one-time token is deleted before the admin
-- password update is attempted; users can request a fresh token if that update fails.
create or replace function public.consume_telegram_password_recovery(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pending private.telegram_password_recovery_pending%rowtype;
begin
  if p_token is null or p_token !~ '^[A-Fa-f0-9]{64}$' then
    raise exception 'Invalid recovery token';
  end if;

  delete from private.telegram_password_recovery_pending
   where token_hash = extensions.digest(lower(p_token), 'sha256')
     and expires_at > now()
  returning * into v_pending;

  if not found then
    raise exception 'Recovery link expired or already used. Request a new one from Telegram.';
  end if;

  return jsonb_build_object(
    'user_id', v_pending.user_id,
    'telegram_user_id', v_pending.telegram_user_id
  );
end;
$$;

revoke all on function public.create_telegram_password_recovery_pending(text,bigint)
  from public, anon, authenticated, service_role;
grant execute on function public.create_telegram_password_recovery_pending(text,bigint)
  to service_role;
revoke all on function public.consume_telegram_password_recovery(text)
  from public, anon, authenticated, service_role;
grant execute on function public.consume_telegram_password_recovery(text)
  to service_role;
