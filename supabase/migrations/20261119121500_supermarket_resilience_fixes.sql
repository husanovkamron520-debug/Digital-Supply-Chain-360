-- Resilience fixes for the six-role Supermarket Crisis.
-- Existing draft competitions and their data are not modified.

begin;
do $migration$
declare v_def text; v_old text; v_new text;
begin
  -- Initialize the first Supermarket round with its configured real-time deadline.
  select pg_get_functiondef('public.initialize_competition_rounds()'::regprocedure) into v_def;
  if position('return new;' in v_def)=0 then raise exception 'initialize_competition_rounds source did not match expected shape'; end if;
  v_new := $insert$
if new.settings->>'case_code'='supermarket-crisis-7day' then
   update public.competition_rounds set
    title=case round_number when 1 then 'Round 1 · Source & plan' when 2 then 'Round 2 · Replenish & prepare' else 'Round 3 · Deliver & recover' end,
    starts_at=case when round_number=1 then now() else null end,
    ends_at=case when round_number=1 then now()+make_interval(mins=>greatest(1,least(60,coalesce(nullif(new.settings->>'round_duration_minutes','')::integer,8)))) else null end
   where competition_id=new.id;
  end if;
  return new;
$insert$;
  v_def := replace(v_def,'return new;',v_new);
  execute v_def;

  -- Enforce the Supermarket round deadline server-side and start the next timer.
  select pg_get_functiondef('public.competition_advance_round(uuid)'::regprocedure) into v_def;
  v_old := $old$if v_clock.current_round>=v_clock.round_limit then raise exception 'Final round reached. Review scores and complete the competition'; end if;$old$;
  v_new := $new$if v_clock.current_round>=v_clock.round_limit then raise exception 'Final round reached. Review scores and complete the competition'; end if;
 if exists(
  select 1 from public.competitions c
  join public.competition_rounds r on r.competition_id=c.id and r.round_number=v_clock.current_round
  where c.id=p_competition_id and c.settings->>'case_code'='supermarket-crisis-7day'
    and r.status='active' and r.ends_at is not null and r.ends_at>now()
 ) then
  raise exception 'The 8-minute round timer has not expired yet';
 end if;$new$;
  if position(v_old in v_def)=0 then raise exception 'competition_advance_round deadline guard anchor missing'; end if;
  v_def := replace(v_def,v_old,v_new);
  v_old := $old$update public.competition_rounds set status='active',starts_at=now() where competition_id=p_competition_id and round_number=v_clock.current_round;$old$;
  v_new := $new$update public.competition_rounds set status='active',starts_at=now(),
  ends_at=case when exists(select 1 from public.competitions where id=p_competition_id and settings->>'case_code'='supermarket-crisis-7day')
    then now()+make_interval(mins=>greatest(1,least(60,coalesce((select nullif(settings->>'round_duration_minutes','')::integer from public.competitions where id=p_competition_id),8))))
    else null end
  where competition_id=p_competition_id and round_number=v_clock.current_round;$new$;
  if position(v_old in v_def)=0 then raise exception 'competition_advance_round next timer anchor missing'; end if;
  v_def := replace(v_def,v_old,v_new);
  execute v_def;

  -- Preserve remaining timer time when teachers pause and resume either timed case.
  select pg_get_functiondef('public.set_competition_status(uuid,text)'::regprocedure) into v_def;
  v_old := $old$and exists(select 1 from public.competitions where id=p_competition_id and settings->>'case_code'='amazon-global-combined-crisis') then$old$;
  v_new := $new$and exists(select 1 from public.competitions where id=p_competition_id and settings->>'case_code' in ('amazon-global-combined-crisis','supermarket-crisis-7day')) then$new$;
  if position(v_old in v_def)=0 then raise exception 'set_competition_status pause/resume anchor missing'; end if;
  v_def := replace(v_def,v_old,v_new);
  v_old := $old$if exists(select 1 from public.competition_decisions where competition_id=p_competition_id and score is null) then$old$;
  v_new := $new$if exists(select 1 from public.competitions where id=p_competition_id and settings->>'case_code'='supermarket-crisis-7day')
   and exists(select 1 from public.competition_rounds where competition_id=p_competition_id
    and round_number=v_round and status='active' and ends_at>now()) then
   raise exception 'Final round timer must expire before completing the Supermarket Crisis';
  end if;
  if exists(select 1 from public.competition_decisions where competition_id=p_competition_id and score is null) then$new$;
  if position(v_old in v_def)=0 then raise exception 'set_competition_status final timer anchor missing'; end if;
  v_def := replace(v_def,v_old,v_new);
  execute v_def;

  -- Align all store forecasts and Procurement's stock inputs.
  select pg_get_functiondef('public.create_supermarket_role_tasks(uuid)'::regprocedure) into v_def;
  v_old := $old$3,000 dona bo‘lsa, 35% oshgan talabni hisoblang.$old$;
  v_new := $new$So‘nggi 7 kunlik savdo jami 3,000 dona: Markaz 1,200, Yangiobod 1,000, Siyob 800. Omborda 1,800 dona, 120 dona karantinda va 900 dona filiallar uchun ajratilgan; erkin foydalanish mumkin bo‘lgan zaxira 780 dona. 35% oshgan talabni, mavjud erkin zaxiradan keyingi xarid ehtiyojini va kamida 1 kunlik safety stockni hisoblang.$new$;
  if position(v_old in v_def)=0 then raise exception 'Procurement case data anchor missing'; end if;
  v_def := replace(v_def,v_old,v_new);
  v_old := $old$Markaz 1,200 dona, Yangiobod 900 dona, Siyob 600 dona.$old$;
  v_new := $new$Markaz 1,200 dona, Yangiobod 1,000 dona, Siyob 800 dona.$new$;
  if position(v_old in v_def)=0 then raise exception 'Store & Demand baseline anchor missing'; end if;
  v_def := replace(v_def,v_old,v_new);
  execute v_def;
end;
$migration$;
commit;
