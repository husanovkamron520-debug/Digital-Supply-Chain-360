-- Secure one-time pairing between a signed-in SupplyChain14 account and a Telegram user.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.telegram_link_codes (
  code_hash bytea primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists telegram_link_codes_user_idx
  on private.telegram_link_codes(user_id, created_at desc);

create table if not exists private.telegram_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  telegram_user_id bigint not null unique check (telegram_user_id > 0),
  telegram_username text,
  linked_at timestamptz not null default now()
);

alter table private.telegram_link_codes enable row level security;
alter table private.telegram_accounts enable row level security;
revoke all on private.telegram_link_codes, private.telegram_accounts from public, anon, authenticated;

create or replace function public.create_telegram_link_code(p_code text)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_expires timestamptz := now() + interval '10 minutes';
begin
  if v_user_id is null then raise exception 'Sign in is required'; end if;
  if p_code is null or p_code !~ '^[A-Fa-f0-9]{48}$' then
    raise exception 'Invalid pairing code format';
  end if;
  delete from private.telegram_link_codes
   where user_id = v_user_id or expires_at <= now();
  insert into private.telegram_link_codes(code_hash,user_id,expires_at)
  values(extensions.digest(lower(p_code),'sha256'),v_user_id,v_expires);
  return v_expires;
end;
$$;

create or replace function public.complete_telegram_link(
  p_code text,
  p_telegram_user_id bigint,
  p_telegram_username text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code private.telegram_link_codes%rowtype;
begin
  if p_code is null or p_code !~ '^[A-Fa-f0-9]{48}$'
     or p_telegram_user_id is null or p_telegram_user_id <= 0 then
    raise exception 'Invalid pairing details';
  end if;

  select * into v_code
    from private.telegram_link_codes
   where code_hash = extensions.digest(lower(p_code),'sha256')
     and expires_at > now()
   for update;
  if not found then raise exception 'Pairing code is invalid or expired'; end if;

  insert into private.telegram_accounts(user_id,telegram_user_id,telegram_username)
  values(v_code.user_id,p_telegram_user_id,nullif(left(trim(coalesce(p_telegram_username,'')),64),''))
  on conflict (user_id) do nothing;

  if not found then
    raise exception 'This SupplyChain14 account is already linked. Contact the teacher to change it.';
  end if;

  delete from private.telegram_link_codes where user_id = v_code.user_id;
  return jsonb_build_object('success',true);
exception
  when unique_violation then
    raise exception 'This Telegram account is already linked to another SupplyChain14 account';
end;
$$;

revoke all on function public.create_telegram_link_code(text) from public, anon;
grant execute on function public.create_telegram_link_code(text) to authenticated;
revoke all on function public.complete_telegram_link(text,bigint,text) from public;
grant execute on function public.complete_telegram_link(text,bigint,text) to anon, authenticated;
