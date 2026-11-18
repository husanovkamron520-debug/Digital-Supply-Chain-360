
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.amazon_advance_round(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' select * into v_clock from public.competition_simulation_clock where competition_id=p_competition_id for update;
 if v_clock.current_round>=3 then',
  ' select * into v_clock from public.competition_simulation_clock where competition_id=p_competition_id for update;
 if exists(select 1 from public.competition_rounds r where r.competition_id=p_competition_id and r.round_number=v_clock.current_round and r.ends_at>now()) then
  raise exception ''Current round closes at %. The 10-minute round must finish before advancing'',
   (select ends_at from public.competition_rounds r where r.competition_id=p_competition_id and r.round_number=v_clock.current_round);
 end if;
 if v_clock.current_round>=3 then');
 execute v_def;
end $migration$;
