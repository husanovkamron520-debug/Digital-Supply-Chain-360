-- Email-verified Telegram-first registration for SupplyChain14.
-- Bot creates pending registrations with the service-role-only RPC.
-- A signed-in user can complete linking only after Supabase confirms the same email.

create table if not exists private.telegram_registration_pending (
  token_hash bytea primary key,
  telegram_user_id bigint not null unique check (telegram_user_id > 0),
  telegram_username text,
  full_name text not null check (char_length(full_name) between 2 and 120),
  email text not null check (char_length(email) between 5 and 320),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create unique index if not exists telegram_registration_pending_email_idx
  on private.telegram_registration_pending (lower(email));
create index if not exists telegram_registration_pending_expiry_idx
  on private.telegram_registration_pending (expires_at);

alter table private.telegram_registration_pending enable row level security;
revoke all on private.telegram_registration_pending from public, anon, authenticated, service_role;

create or replace function public.create_telegram_registration_pending(
  p_token text,
  p_telegram_user_id bigint,
  p_telegram_username text,
  p_full_name text,
  p_email text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_name text := trim(coalesce(p_full_name, ''));
begin
  if p_token is null or p_token !~ '^[A-Fa-f0-9]{64}$'
     or p_telegram_user_id is null or p_telegram_user_id <= 0
     or char_length(v_name) not between 2 and 120
     or char_length(v_email) not between 5 and 320
     or position('@' in v_email) <= 1 then
    raise exception 'Invalid registration details';
  end if;

  if exists (
    select 1 from private.telegram_accounts a
    where a.telegram_user_id = p_telegram_user_id
  ) then
    raise exception 'This Telegram account is already linked';
  end if;

  if exists (
    select 1
    from auth.users u
    join private.telegram_accounts a on a.user_id = u.id
    where lower(u.email) = v_email
  ) then
    raise exception 'This email account is already linked to Telegram';
  end if;

  delete from private.telegram_registration_pending
   where expires_at <= now()
      or telegram_user_id = p_telegram_user_id;

  insert into private.telegram_registration_pending(
    token_hash, telegram_user_id, telegram_username, full_name, email, expires_at
  )
  values (
    extensions.digest(lower(p_token), 'sha256'),
    p_telegram_user_id,
    nullif(left(trim(coalesce(p_telegram_username, '')), 64), ''),
    v_name,
    v_email,
    now() + interval '30 minutes'
  );

  return jsonb_build_object('success', true, 'expires_in_seconds', 1800);
exception
  when unique_violation then
    raise exception 'An active registration already exists for this email';
end;
$$;

create or replace function public.complete_telegram_registration(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_pending private.telegram_registration_pending%rowtype;
  v_email text;
  v_existing private.telegram_accounts%rowtype;
begin
  if v_user_id is null then
    raise exception 'Sign in with the verified email first';
  end if;
  if p_token is null or p_token !~ '^[A-Fa-f0-9]{64}$' then
    raise exception 'Invalid registration token';
  end if;

  select lower(u.email) into v_email
    from auth.users u
   where u.id = v_user_id
     and u.email_confirmed_at is not null;
  if v_email is null then
    raise exception 'Email verification is required';
  end if;

  select * into v_pending
    from private.telegram_registration_pending
   where token_hash = extensions.digest(lower(p_token), 'sha256')
     and expires_at > now()
   for update;
  if not found then
    raise exception 'Registration link expired or already used; restart from Telegram';
  end if;

  if v_email <> lower(v_pending.email) then
    raise exception 'Sign in with the same email address entered in Telegram';
  end if;

  insert into private.telegram_accounts(user_id, telegram_user_id, telegram_username)
  values (
    v_user_id,
    v_pending.telegram_user_id,
    v_pending.telegram_username
  )
  on conflict (user_id) do nothing;

  if not found then
    select * into v_existing
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

revoke all on function public.create_telegram_registration_pending(text,bigint,text,text,text)
  from public, anon, authenticated, service_role;
grant execute on function public.create_telegram_registration_pending(text,bigint,text,text,text)
  to service_role;

revoke all on function public.complete_telegram_registration(text)
  from public, anon, service_role;
grant execute on function public.complete_telegram_registration(text)
  to authenticated;
