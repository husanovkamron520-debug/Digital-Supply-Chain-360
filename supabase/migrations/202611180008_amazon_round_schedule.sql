
do $migration$
declare v_def text;
begin
 select pg_get_functiondef('public.initialize_competition_rounds()'::regprocedure) into v_def;
 v_def:=replace(v_def,
  '  on conflict(competition_id,round_number) do nothing;',
  '  on conflict(competition_id,round_number) do nothing;
  if new.settings->>''case_code''=''amazon-global-combined-crisis'' then
   update public.competition_rounds set
    title=case round_number when 1 then ''Round 1 · Source & secure'' when 2 then ''Round 2 · Disruption & recover'' else ''Round 3 · Fulfil & optimise'' end,
    starts_at=case when round_number=1 then now() else null end,
    ends_at=case when round_number=1 then now()+interval ''10 minutes'' else null end,
    brief=jsonb_build_object(''round'',round_number,''simulation_days'',10,''real_duration_minutes'',10,
     ''focus'',case round_number when 1 then ''Supplier allocation, initial procurement and inventory positioning''
      when 2 then ''China supplier delay, alternative sourcing, receiving and fulfilment recovery''
      else ''Final sourcing, pick-pack waves, dispatch, delivery and financial reconciliation'' end)
   where competition_id=new.id;
  end if;');
 execute v_def;
 select pg_get_functiondef('public.amazon_advance_round(uuid)'::regprocedure) into v_def;
 v_def:=replace(v_def,
  ' update public.competition_rounds set status=''active'',starts_at=now() where competition_id=p_competition_id and round_number=v_clock.current_round;',
  ' update public.competition_rounds set status=''active'',starts_at=now(),ends_at=now()+interval ''10 minutes'' where competition_id=p_competition_id and round_number=v_clock.current_round;');
 execute v_def;
end $migration$;
