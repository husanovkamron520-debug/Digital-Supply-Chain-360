-- Deployable migration for the SupplyChain14 Telegram notification queue.
-- Idempotent against projects where the original standalone SQL was already applied.
-- Private notification queue for Telegram-linked competition participants.
create schema if not exists private;
create table if not exists private.telegram_notification_queue (
  id uuid primary key default gen_random_uuid(),
  telegram_user_id bigint not null,
  message text not null check (length(message) between 1 and 3500),
  created_at timestamptz not null default now(),
  delivered_at timestamptz,
  claimed_until timestamptz
);
alter table private.telegram_notification_queue add column if not exists claimed_until timestamptz;
create index if not exists telegram_notification_queue_pending_idx on private.telegram_notification_queue(created_at) where delivered_at is null;
create table if not exists private.telegram_notification_config (
  singleton boolean primary key default true check (singleton),
  secret_hash bytea not null,
  updated_at timestamptz not null default now()
);
insert into private.telegram_notification_config(singleton,secret_hash) values(true,extensions.digest('migration-placeholder-not-a-live-secret','sha256'))
on conflict(singleton) do nothing;
alter table private.telegram_notification_queue enable row level security;
alter table private.telegram_notification_config enable row level security;
revoke all on private.telegram_notification_queue,private.telegram_notification_config from public,anon,authenticated;

create or replace function private.enqueue_competition_notice(p_competition_id uuid,p_message text,p_student_id uuid default null,p_team_id uuid default null)
returns integer language plpgsql security definer set search_path=''
as $$
declare v_count integer;
begin
 insert into private.telegram_notification_queue(telegram_user_id,message)
 select distinct a.telegram_user_id,left(p_message,3500)
 from public.competition_team_members tm join private.telegram_accounts a on a.user_id=tm.student_id
 where tm.competition_id=p_competition_id and (p_student_id is null or tm.student_id=p_student_id)
 and (p_team_id is null or tm.team_id=p_team_id);
 get diagnostics v_count=row_count; return v_count;
end; $$;
revoke all on function private.enqueue_competition_notice(uuid,text,uuid,uuid) from public,anon,authenticated;

create or replace function private.notify_competition_status()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_message text;
begin
 if new.status is not distinct from old.status then return new; end if;
 v_message:=case new.status
 when 'active' then '🏁 Musobaqa boshlandi: '||new.title||E'\nSupplyChain14 saytida jamoangiz va topshiriqlaringizni tekshiring.'
 when 'paused' then '⏸ Musobaqa vaqtincha to‘xtatildi: '||new.title
 when 'completed' then '🏆 Musobaqa yakunlandi: '||new.title||E'\nYakuniy natijalar platformada mavjud.' else null end;
 if v_message is not null then perform private.enqueue_competition_notice(new.id,v_message); end if;
 return new;
end; $$;
drop trigger if exists competition_telegram_status_notice on public.competitions;
create trigger competition_telegram_status_notice after update of status on public.competitions for each row execute function private.notify_competition_status();

create or replace function private.notify_competition_task()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_message text; v_comp_title text;
begin
 if tg_op='INSERT' then
  select title into v_comp_title from public.competitions where id=new.competition_id and status='active';
  if v_comp_title is null then return new; end if;
  v_message:='📋 Yangi topshiriq: '||new.title||E'\nMusobaqa: '||v_comp_title||
    E'\nMuddat: '||coalesce(to_char(new.due_at,'DD Mon HH24:MI'),'belgilanmagan')||
    E'\nSupplyChain14 saytida topshiriqni oching.';
  perform private.enqueue_competition_notice(new.competition_id,v_message,new.assigned_to,case when new.assigned_to is null then new.team_id else null end);
 elsif new.status is distinct from old.status and new.status in ('approved','rejected') then
  v_message:=case when new.status='approved' then '✅ Topshiriq tasdiqlandi: ' else '⚠️ Topshiriq qayta ishlashga qaytarildi: ' end
    ||new.title||E'\n'||coalesce(nullif(new.review_note,''),'Natija va izohni platformadan ko‘ring.');
  perform private.enqueue_competition_notice(new.competition_id,v_message,new.assigned_to,case when new.assigned_to is null then new.team_id else null end);
 end if;
 return new;
end; $$;
drop trigger if exists competition_telegram_task_notice on public.competition_tasks;
create trigger competition_telegram_task_notice after insert or update of status on public.competition_tasks for each row execute function private.notify_competition_task();

create or replace function private.notify_competition_round()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_comp_title text;
begin
 if new.status='active' and (tg_op='INSERT' or old.status is distinct from new.status) then
  select title into v_comp_title from public.competitions where id=new.competition_id;
  perform private.enqueue_competition_notice(new.competition_id,'🔔 Yangi raund boshlandi: '||coalesce(v_comp_title,'Musobaqa')||
    E'\nRaund '||new.round_number||': '||new.title||E'\nSupplyChain14 saytida jamoangiz vazifalarini tekshiring.');
 end if;
 return new;
end; $$;
drop trigger if exists competition_telegram_round_notice on public.competition_rounds;
create trigger competition_telegram_round_notice after insert or update of status on public.competition_rounds for each row execute function private.notify_competition_round();

create or replace function public.fetch_telegram_competition_notifications(p_secret text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_hash bytea; v_rows jsonb;
begin
 select secret_hash into v_hash from private.telegram_notification_config where singleton=true;
 if v_hash is null or p_secret is null or extensions.digest(p_secret,'sha256')<>v_hash then raise exception 'Unauthorized notification poll'; end if;

 -- Claim a batch atomically. SKIP LOCKED prevents two bot instances from
 -- delivering the same pending row at the same time. Expired claims are retried.
 with picked as materialized (
   select id
   from private.telegram_notification_queue
   where delivered_at is null and (claimed_until is null or claimed_until <= now())
   order by created_at
   for update skip locked
   limit 25
 ), claimed as (
   update private.telegram_notification_queue q
      set claimed_until = now() + interval '5 minutes'
     from picked
    where q.id = picked.id
   returning q.id, q.telegram_user_id, q.message, q.created_at
 )
 select coalesce(
   jsonb_agg(jsonb_build_object('id',id,'telegram_user_id',telegram_user_id,'message',message) order by created_at),
   '[]'::jsonb
 ) into v_rows from claimed;
 return v_rows;
end; $$;
create or replace function public.ack_telegram_competition_notification(p_secret text,p_notification_id uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_hash bytea; v_count integer;
begin
 select secret_hash into v_hash from private.telegram_notification_config where singleton=true;
 if v_hash is null or p_secret is null or extensions.digest(p_secret,'sha256')<>v_hash then raise exception 'Unauthorized notification acknowledgement'; end if;
 update private.telegram_notification_queue set delivered_at=now(),claimed_until=null where id=p_notification_id and delivered_at is null;
 get diagnostics v_count=row_count; return v_count=1;
end; $$;
revoke all on function public.fetch_telegram_competition_notifications(text) from public,authenticated;
revoke all on function public.ack_telegram_competition_notification(text,uuid) from public,authenticated;
grant execute on function public.fetch_telegram_competition_notifications(text) to anon;
grant execute on function public.ack_telegram_competition_notification(text,uuid) to anon;
